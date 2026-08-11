import Foundation
import ARKit
import RoverNav

public struct ARFrameID: Hashable, Sendable {
    public let generation: UInt64
    public let sequence: UInt64

    public init(generation: UInt64, sequence: UInt64) {
        self.generation = generation
        self.sequence = sequence
    }
}

public enum ARTrackingQuality: Equatable, Sendable {
    case unavailable
    case limited
    case normal
}

public struct ARFrameSnapshot: @unchecked Sendable {
    public let id: ARFrameID
    public let timestamp: TimeInterval
    public let image: CVPixelBuffer
    public let cameraTransform: simd_float4x4
    public let cameraIntrinsics: simd_float3x3
    public let imageResolution: CGSize
    public let depthMap: CVPixelBuffer?
    public let pose: Pose2D
    public let trackingQuality: ARTrackingQuality

    public init(id: ARFrameID, timestamp: TimeInterval, image: CVPixelBuffer,
                cameraTransform: simd_float4x4, cameraIntrinsics: simd_float3x3,
                imageResolution: CGSize, depthMap: CVPixelBuffer?, pose: Pose2D,
                trackingQuality: ARTrackingQuality) {
        self.id = id
        self.timestamp = timestamp
        self.image = image
        self.cameraTransform = cameraTransform
        self.cameraIntrinsics = cameraIntrinsics
        self.imageResolution = imageResolution
        self.depthMap = depthMap
        self.pose = pose
        self.trackingQuality = trackingQuality
    }
}

public enum ARSessionLifecycleEvent: Equatable, Sendable {
    case reset(generation: UInt64)
    case interrupted(generation: UInt64)
    case interruptionEnded(generation: UInt64)
    case failed(generation: UInt64, description: String)
}

/// Owns the ARKit session and is the rover's **primary odometry + mapping** source
/// (the WAVE ROVER base has no wheel encoders). Provides:
///   • 6DoF pose flattened to the nav ground plane (`Pose2D`)
///   • LiDAR scene mesh anchors → obstacles for the costmap
///   • live LiDAR depth → reactive obstacle avoidance
///
/// Nav frame convention (matches RoverNav.Geometry): x = ARKit world X, y = ARKit world Z.
@Observable
@MainActor
public final class ARSessionManager: NSObject, @preconcurrency ARSessionDelegate {
    public let session = ARSession()

    public private(set) var pose: Pose2D?
    public private(set) var meshAnchors: [ARMeshAnchor] = []
    /// Nearest obstacle distance (m) in a forward cone from the latest depth frame.
    public private(set) var forwardClearance: Double = .infinity
    public private(set) var trackingState: ARCamera.TrackingState = .notAvailable
    public private(set) var trackingQuality: ARTrackingQuality = .unavailable
    public private(set) var sessionGeneration: UInt64 = 0
    public private(set) var latestSnapshot: ARFrameSnapshot?

    /// Latest RGB frame, for `Detector` to run inference on.
    public private(set) var latestPixelBuffer: CVPixelBuffer?
    /// Latest camera (intrinsics + transform + raw sensor `imageResolution`), retained so
    /// `unproject(normalizedPoint:)` can back-project a detection into the world.
    public private(set) var latestCamera: ARCamera?
    /// Latest LiDAR depth map (meters, aligned to `latestCamera.imageResolution`'s aspect).
    public private(set) var latestDepthMap: CVPixelBuffer?
    private var lastClearanceLogAt = Date.distantPast
    private var frameSequence: UInt64 = 0
    private var snapshotContinuations: [UUID: AsyncStream<ARFrameSnapshot>.Continuation] = [:]
    private var lifecycleContinuations: [UUID: AsyncStream<ARSessionLifecycleEvent>.Continuation] = [:]

    public override init() {
        super.init()
        session.delegate = self
    }

    public func start() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        prepareForReset()
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    public func pause() { session.pause() }

    public func snapshots() -> AsyncStream<ARFrameSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            snapshotContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.snapshotContinuations.removeValue(forKey: id) }
            }
        }
    }

    public func lifecycleEvents() -> AsyncStream<ARSessionLifecycleEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lifecycleContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.lifecycleContinuations.removeValue(forKey: id) }
            }
        }
    }

    // MARK: - ARSessionDelegate

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let depthMap = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap
        ingest(image: frame.capturedImage, timestamp: frame.timestamp,
               cameraTransform: frame.camera.transform, intrinsics: frame.camera.intrinsics,
               imageResolution: frame.camera.imageResolution, depthMap: depthMap,
               trackingQuality: Self.trackingQuality(from: frame.camera.trackingState),
               compatibilityCamera: frame.camera, compatibilityTrackingState: frame.camera.trackingState)
    }

    public func sessionWasInterrupted(_ session: ARSession) { interruptionBegan() }

    public func sessionInterruptionEnded(_ session: ARSession) {
        publishLifecycle(.interruptionEnded(generation: sessionGeneration))
    }

    public func session(_ session: ARSession, didFailWithError error: any Error) {
        failure(description: error.localizedDescription)
    }

    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { collectMesh(anchors) }
    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { collectMesh(anchors) }

    private func collectMesh(_ anchors: [ARAnchor]) {
        let mesh = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !mesh.isEmpty else { return }
        var map = Dictionary(meshAnchors.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        for m in mesh { map[m.identifier] = m }
        meshAnchors = Array(map.values)
    }

    private func prepareForReset() {
        sessionGeneration &+= 1
        frameSequence = 0
        meshAnchors = []
        clearCurrentFrame()
        publishLifecycle(.reset(generation: sessionGeneration))
    }

    private func ingest(image: CVPixelBuffer, timestamp: TimeInterval,
                        cameraTransform: simd_float4x4, intrinsics: simd_float3x3,
                        imageResolution: CGSize, depthMap: CVPixelBuffer?,
                        trackingQuality: ARTrackingQuality, compatibilityCamera: ARCamera? = nil,
                        compatibilityTrackingState: ARCamera.TrackingState? = nil) {
        frameSequence &+= 1
        let currentPose = Self.groundPose(from: cameraTransform)
        let snapshot = ARFrameSnapshot(
            id: ARFrameID(generation: sessionGeneration, sequence: frameSequence), timestamp: timestamp,
            image: image, cameraTransform: cameraTransform, cameraIntrinsics: intrinsics,
            imageResolution: imageResolution, depthMap: depthMap, pose: currentPose,
            trackingQuality: trackingQuality
        )
        latestSnapshot = snapshot
        latestPixelBuffer = snapshot.image
        latestCamera = compatibilityCamera
        latestDepthMap = snapshot.depthMap
        pose = snapshot.pose
        self.trackingQuality = snapshot.trackingQuality
        trackingState = compatibilityTrackingState ?? Self.compatibilityTrackingState(from: trackingQuality)
        forwardClearance = depthMap.map(Self.forwardClearance(fromDepthMap:)) ?? .infinity
        if depthMap != nil { logForwardClearanceIfNeeded() }
        for continuation in snapshotContinuations.values { continuation.yield(snapshot) }
    }

    private func interruptionBegan() {
        clearCurrentFrame()
        publishLifecycle(.interrupted(generation: sessionGeneration))
    }

    private func failure(description: String) {
        clearCurrentFrame()
        publishLifecycle(.failed(generation: sessionGeneration, description: description))
    }

    private func clearCurrentFrame() {
        latestSnapshot = nil
        latestPixelBuffer = nil
        latestCamera = nil
        latestDepthMap = nil
        pose = nil
        forwardClearance = .infinity
        trackingState = .notAvailable
        trackingQuality = .unavailable
    }

    private func publishLifecycle(_ event: ARSessionLifecycleEvent) {
        for continuation in lifecycleContinuations.values { continuation.yield(event) }
    }

    private static func trackingQuality(from state: ARCamera.TrackingState) -> ARTrackingQuality {
        switch state {
        case .normal: .normal
        case .limited: .limited
        case .notAvailable: .unavailable
        @unknown default: .unavailable
        }
    }

    private static func compatibilityTrackingState(from quality: ARTrackingQuality) -> ARCamera.TrackingState {
        switch quality {
        case .normal: .normal
        case .limited: .limited(.initializing)
        case .unavailable: .notAvailable
        }
    }

    func resetForTesting() { prepareForReset() }

    func ingestForTesting(image: CVPixelBuffer, timestamp: TimeInterval,
                          cameraTransform: simd_float4x4, intrinsics: simd_float3x3,
                          imageResolution: CGSize, depthMap: CVPixelBuffer?,
                          trackingQuality: ARTrackingQuality) {
        ingest(image: image, timestamp: timestamp, cameraTransform: cameraTransform,
               intrinsics: intrinsics, imageResolution: imageResolution, depthMap: depthMap,
               trackingQuality: trackingQuality)
    }

    func interruptionBeganForTesting() { interruptionBegan() }
    func interruptionEndedForTesting() { publishLifecycle(.interruptionEnded(generation: sessionGeneration)) }
    func failureForTesting(description: String) { failure(description: description) }

    private func logForwardClearanceIfNeeded(now: Date = Date()) {
        guard now.timeIntervalSince(lastClearanceLogAt) >= 1 else { return }
        lastClearanceLogAt = now
        RuntimeFileLog.append("forward_clearance", fields: [
            "meters": forwardClearance.isFinite ? String(format: "%.2f", forwardClearance) : "inf",
            "tracking": trackingStateDescription(trackingState)
        ], now: now)
    }

    private func trackingStateDescription(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .limited: return "limited"
        case .notAvailable: return "notAvailable"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Object grounding

    /// Back-projects a point in `Detector`'s normalized Vision coordinates (bottom-left
    /// origin, y-up, in the upright/portrait frame Vision produces because `Detector` hands
    /// it the buffer with `orientation: .right`) to a world point on the nav plane, by
    /// sampling the aligned LiDAR depth map and unprojecting through the camera intrinsics.
    /// Returns `nil` if there's no camera/depth yet or the sampled depth is invalid.
    ///
    /// The `.right`-rotation inverse assumes the phone is held in the same portrait
    /// orientation `Detector` was tuned for; this is the one piece of the perception path
    /// that can only be validated on a real LiDAR device (see rover/README.md status notes)
    /// — `ARCamera` has no public initializer, so the math below is split into the static
    /// helpers `sensorPixel`/`sampleDepth`/`unprojectPoint` specifically so it can still be
    /// exercised in tests against synthetic intrinsics/transforms/depth.
    public func unproject(normalizedPoint: CGPoint) -> Vec2? {
        guard let snapshot = latestSnapshot else { return nil }
        return Self.unproject(normalizedPoint: normalizedPoint, in: snapshot)
    }

    nonisolated public static func unproject(normalizedPoint: CGPoint, in snapshot: ARFrameSnapshot) -> Vec2? {
        guard let depthMap = snapshot.depthMap,
              let depth = sampleDepth(depthMap, atVisionNormalizedPoint: normalizedPoint,
                                      imageSize: snapshot.imageResolution) else {
            return nil
        }
        return unprojectPoint(normalizedPoint, imageSize: snapshot.imageResolution,
                              intrinsics: snapshot.cameraIntrinsics,
                              cameraTransform: snapshot.cameraTransform, depth: depth)
    }

    /// Undoes the `.right` (90° clockwise) rotation `Detector`'s Vision request handler
    /// applied, landing back in the raw sensor pixel space `intrinsics`/depth are
    /// calibrated against.
    nonisolated static func sensorPixel(forVisionNormalizedPoint p: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(x: (1 - p.y) * imageSize.width, y: (1 - p.x) * imageSize.height)
    }

    /// Samples the LiDAR depth map (meters) at the raw-sensor-space point corresponding to
    /// a Vision-normalized point. The depth map is lower-res than the color camera but
    /// aligned to the same field of view, so the fractional position carries over directly.
    nonisolated static func sampleDepth(_ depthMap: CVPixelBuffer, atVisionNormalizedPoint p: CGPoint, imageSize: CGSize) -> Float? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let sensor = sensorPixel(forVisionNormalizedPoint: p, imageSize: imageSize)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let dw = CVPixelBufferGetWidth(depthMap), dh = CVPixelBufferGetHeight(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap), dw > 0, dh > 0 else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let dx = min(dw - 1, max(0, Int((sensor.x / imageSize.width) * Double(dw))))
        let dy = min(dh - 1, max(0, Int((sensor.y / imageSize.height) * Double(dh))))
        let depth = base.assumingMemoryBound(to: Float32.self)[dy * stride + dx]
        guard depth > 0.05, depth.isFinite else { return nil }
        return depth
    }

    /// Back-projects a raw-sensor-space point at a known depth through the camera
    /// intrinsics and pose into a world-plane point (matches `groundPose`'s x/world-x,
    /// y/world-z convention). Pure math — testable with synthetic intrinsics/transform.
    nonisolated static func unprojectPoint(_ visionNormalizedPoint: CGPoint, imageSize: CGSize,
                                           intrinsics: simd_float3x3, cameraTransform: simd_float4x4,
                                           depth: Float) -> Vec2 {
        let sensor = sensorPixel(forVisionNormalizedPoint: visionNormalizedPoint, imageSize: imageSize)
        let fx = Double(intrinsics[0][0]), fy = Double(intrinsics[1][1])
        let cx = Double(intrinsics[2][0]), cy = Double(intrinsics[2][1])
        let d = Double(depth)

        // Camera space: +X right, +Y up, camera looks down -Z (same convention as groundPose).
        let xCam = (sensor.x - cx) / fx * d
        let yCam = -(sensor.y - cy) / fy * d
        let zCam = -d

        let world = cameraTransform * SIMD4<Float>(Float(xCam), Float(yCam), Float(zCam), 1)
        return Vec2(Double(world.x), Double(world.z))
    }

    // MARK: - Geometry helpers

    /// Flatten an ARKit camera transform to a ground-plane pose. Camera looks down -Z.
    static func groundPose(from t: simd_float4x4) -> Pose2D {
        let p = t.columns.3
        // Device forward in world = -(third basis column).
        let fwd = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let yaw = atan2(Double(fwd.z), Double(fwd.x))
        return Pose2D(position: Vec2(Double(p.x), Double(p.z)), yaw: yaw)
    }

    /// Robust near depth (m) sampled from the center region of the LiDAR depth map.
    static func forwardClearance(from depth: ARDepthData) -> Double {
        forwardClearance(fromDepthMap: depth.depthMap)
    }

    /// Robust near depth (m) sampled from the driving corridor of the LiDAR depth map.
    static func forwardClearance(fromDepthMap map: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map), w > 0, h > 0 else { return .infinity }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let ptr = base.assumingMemoryBound(to: Float32.self)
        let stride = rowBytes / MemoryLayout<Float32>.size

        var depths: [Float] = []
        depths.reserveCapacity((h / 3) * (w / 2))
        // Sample a wider central driving corridor. A wall slightly off-center in the
        // mounted phone's view still needs to stop the rover before contact.
        for y in (h / 3)..<(h * 2 / 3) {
            for x in (w / 4)..<(w * 3 / 4) {
                let d = ptr[y * stride + x]
                if d > 0.05 && d.isFinite { depths.append(d) }
            }
        }
        guard !depths.isEmpty else { return .infinity }
        depths.sort()
        let index = min(depths.count - 1, max(0, Int(Double(depths.count - 1) * 0.10)))
        return Double(depths[index])
    }
}
