import Foundation
import ARKit
import CoreMotion
import RoverNav

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
    private let motionManager = CMMotionManager()
    private let relativeHeadingOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "us.astral.phrover.relative-heading"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    public private(set) var pose: Pose2D?
    public private(set) var meshAnchors: [ARMeshAnchor] = []
    /// Nearest obstacle distance (m) in a forward cone from the latest depth frame.
    public private(set) var forwardClearance: Double = .infinity
    private(set) var latestDepthSafetySnapshot: DepthSafetySnapshot?
    public private(set) var depthSnapshotVersion: UInt64 = 0
    public var depthSnapshotTimestamp: TimeInterval? { latestDepthSafetySnapshot?.timestamp }
    public private(set) var trackingState: ARCamera.TrackingState = .notAvailable

    /// Latest RGB frame, for `Detector` to run inference on.
    public private(set) var latestPixelBuffer: CVPixelBuffer?
    /// Monotonic camera-frame counter used to prevent perception from reusing a frame
    /// captured before a scan turn completed.
    public private(set) var frameSequence: UInt64 = 0
    public private(set) var latestObservation: PoseObservation?
    public private(set) var sessionGeneration: UInt64 = 0
    public var observationHandler: ((PoseObservation) -> Void)?
    public var onReset: ((UInt64) -> Void)?
    private var acceptsObservations = false
    private var lastObservationTimestamp: TimeInterval?
    nonisolated private let relativeHeadingStore = RelativeHeadingTrackerStore()
    private var loggedRelativeHeadingReliability: RelativeHeadingReliability = .unreliable(.notStarted)
    private let relativeHeadingTelemetry: RoomTopologyTelemetrySink
    /// Gyroscope-fused rover heading. Unlike ARKit world yaw, this does not jump when
    /// visual tracking relocalizes, so scan turns use it for relative-angle completion.
    func beginRelativeHeadingMeasurement() {
        relativeHeadingStore.beginMeasurement()
        loggedRelativeHeadingReliability = .unreliable(.notStarted)
        relativeHeadingTelemetry("relative_heading_measurement_started", [:])
    }

    func endRelativeHeadingMeasurement() {
        relativeHeadingStore.endMeasurement()
        loggedRelativeHeadingReliability = .unreliable(.notStarted)
        relativeHeadingTelemetry("relative_heading_measurement_ended", [:])
    }

    @discardableResult
    func ingestRelativeHeadingSample(_ sample: RelativeHeadingSample) -> Bool {
        guard let result = relativeHeadingStore.ingest(sample) else { return false }
        reportRelativeHeadingIngest(result, timestamp: sample.timestamp)
        return result.accepted
    }

    func relativeHeadingMeasurement(
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> RelativeHeadingMeasurement {
        let measurement = relativeHeadingStore.measurement(at: timestamp)
        if measurement.reliability != loggedRelativeHeadingReliability {
            reportRelativeHeadingReliabilityTransition(to: measurement.reliability)
        }
        return measurement
    }

    /// Scan turns only consume pose samples while ARKit has a reliable world transform.
    public var isTrackingNormal: Bool {
        latestObservation?.trackingQuality == .normal
    }
    /// Latest camera (intrinsics + transform + raw sensor `imageResolution`), retained so
    /// `unproject(normalizedPoint:)` can back-project a detection into the world.
    public private(set) var latestCamera: ARCamera?
    /// Latest LiDAR depth map (meters, aligned to `latestCamera.imageResolution`'s aspect).
    public private(set) var latestDepthMap: CVPixelBuffer?
    private var lastClearanceLogAt = Date.distantPast

    public override init() {
        relativeHeadingTelemetry = { event, fields in
            RuntimeFileLog.append(event, fields: fields)
        }
        super.init()
        session.delegate = self
    }

    init(relativeHeadingTelemetry: @escaping RoomTopologyTelemetrySink) {
        self.relativeHeadingTelemetry = relativeHeadingTelemetry
        super.init()
        session.delegate = self
    }

    private func invalidateRelativeHeadingMeasurement(
        reason: RelativeHeadingReliability.UnreliableReason
    ) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let result = relativeHeadingStore.invalidate(reason: reason, at: timestamp)
        guard result.wasActive else {
            loggedRelativeHeadingReliability = .unreliable(.notStarted)
            return
        }
        relativeHeadingTelemetry(
            "relative_heading_measurement_invalidated",
            fieldsForRelativeHeading(
                result.measurement,
                timestamp: timestamp
            )
        )
        reportRelativeHeadingReliabilityTransition(to: result.measurement.reliability)
    }

    private func reportRelativeHeadingIngest(
        _ result: RelativeHeadingIngestResult,
        timestamp: TimeInterval
    ) {
        let measurement = result.measurement
        guard measurement.reliability != loggedRelativeHeadingReliability else { return }
        relativeHeadingTelemetry(
            result.accepted ? "relative_heading_sample_accepted" : "relative_heading_sample_rejected",
            fieldsForRelativeHeading(measurement, timestamp: timestamp)
        )
        reportRelativeHeadingReliabilityTransition(to: measurement.reliability)
    }

    nonisolated private func ingestRelativeHeadingMotionSample(_ sample: RelativeHeadingSample) {
        guard let result = relativeHeadingStore.ingest(sample) else { return }
        Task { @MainActor [weak self] in
            self?.reportRelativeHeadingIngest(result, timestamp: sample.timestamp)
        }
    }

    private func reportRelativeHeadingReliabilityTransition(
        to reliability: RelativeHeadingReliability
    ) {
        let previous = Self.relativeHeadingReliabilityDescription(loggedRelativeHeadingReliability)
        let current = Self.relativeHeadingReliabilityDescription(reliability)
        loggedRelativeHeadingReliability = reliability
        relativeHeadingTelemetry("relative_heading_reliability_changed", [
            "from": previous,
            "to": current,
        ])
    }

    private func fieldsForRelativeHeading(
        _ measurement: RelativeHeadingMeasurement,
        timestamp: TimeInterval
    ) -> [String: String] {
        [
            "timestamp": String(format: "%.3f", timestamp),
            "accumulated_angle": String(format: "%.4f", measurement.accumulatedAngle),
            "sample_age": measurement.sampleAge.map { String(format: "%.3f", $0) } ?? "none",
            "reliability": Self.relativeHeadingReliabilityDescription(measurement.reliability),
        ]
    }

    private static func relativeHeadingReliabilityDescription(
        _ reliability: RelativeHeadingReliability
    ) -> String {
        switch reliability {
        case .reliable:
            return "reliable"
        case .unreliable(let reason):
            return reason.rawValue
        }
    }

    public func start() {
        resetTracking(generation: sessionGeneration + 1)
    }

    public func resetTracking(generation: UInt64) {
        resetTracking(generation: generation, runSession: true)
    }

    func resetTracking(generation: UInt64, runSession: Bool) {
        acceptsObservations = false
        sessionGeneration = generation
        pose = nil
        meshAnchors.removeAll()
        forwardClearance = .infinity
        latestDepthSafetySnapshot = nil
        trackingState = .notAvailable
        latestPixelBuffer = nil
        frameSequence = 0
        latestObservation = nil
        lastObservationTimestamp = nil
        invalidateRelativeHeadingMeasurement(reason: .sessionGenerationChanged)
        latestCamera = nil
        latestDepthMap = nil
        onReset?(generation)

        if motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive {
            motionManager.deviceMotionUpdateInterval = RoverConfig.relativeHeadingUpdateInterval
            motionManager.startDeviceMotionUpdates(
                using: .xArbitraryZVertical,
                to: relativeHeadingOperationQueue
            ) { [weak self] motion, _ in
                guard let motion else { return }
                self?.ingestRelativeHeadingMotionSample(RelativeHeadingSample(
                    timestamp: motion.timestamp,
                    rotationRate: SIMD3(
                        motion.rotationRate.x,
                        motion.rotationRate.y,
                        motion.rotationRate.z
                    ),
                    gravity: SIMD3(
                        motion.gravity.x,
                        motion.gravity.y,
                        motion.gravity.z
                    )
                ))
            }
        }
        guard runSession else {
            acceptsObservations = true
            return
        }
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
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        acceptsObservations = true
    }

    public func pause() {
        session.pause()
        motionManager.stopDeviceMotionUpdates()
    }

    // MARK: - ARSessionDelegate

    func ingestDepthSafety(rawDepthMap: CVPixelBuffer,
                           intrinsics: simd_float3x3,
                           intrinsicsImageSize: CGSize? = nil,
                           cameraTransform: simd_float4x4,
                           timestamp: TimeInterval) {
        latestDepthSafetySnapshot = DepthSafetyEvaluator.ingest(
            rawDepthMap: rawDepthMap,
            intrinsics: intrinsics,
            intrinsicsImageSize: intrinsicsImageSize,
            cameraTransform: cameraTransform,
            timestamp: timestamp,
            calibration: RoverConfig.cameraMountCalibration,
            geometry: RoverConfig.collisionGeometry
        )
        depthSnapshotVersion &+= 1
    }

    func depthSafetyObservation(
        for command: WheelCommand,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> DepthSafetyObservation {
        guard let latestDepthSafetySnapshot else {
            return .unavailable(
                .missingRawDepth,
                sampleAge: .infinity,
                motionClass: DepthSafetyMotionClass.classify(command)
            )
        }
        return DepthSafetyEvaluator.evaluate(
            latestDepthSafetySnapshot,
            command: command,
            now: timestamp
        )
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let trackingQuality = Self.trackingQuality(frame.camera.trackingState)
        let observation = PoseObservation(
            pose: Self.groundPose(from: frame.camera.transform),
            frameSequence: frameSequence &+ 1,
            timestamp: frame.timestamp,
            trackingQuality: trackingQuality,
            sessionGeneration: sessionGeneration
        )
        guard ingest(observation) else { return }
        trackingState = frame.camera.trackingState
        latestPixelBuffer = frame.capturedImage
        latestCamera = frame.camera
        if let rawDepth = frame.sceneDepth {
            ingestDepthSafety(
                rawDepthMap: rawDepth.depthMap,
                intrinsics: frame.camera.intrinsics,
                intrinsicsImageSize: frame.camera.imageResolution,
                cameraTransform: frame.camera.transform,
                timestamp: frame.timestamp
            )
        } else {
            latestDepthSafetySnapshot = nil
        }
        if let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
            forwardClearance = Self.forwardClearance(from: depth)
            latestDepthMap = depth.depthMap
        }
        logForwardClearanceIfNeeded()
    }

    @discardableResult
    func ingest(_ observation: PoseObservation) -> Bool {
        guard acceptsObservations,
              observation.sessionGeneration == sessionGeneration,
              observation.frameSequence > frameSequence,
              lastObservationTimestamp.map({ observation.timestamp > $0 }) ?? true else {
            return false
        }
        latestObservation = observation
        lastObservationTimestamp = observation.timestamp
        pose = observation.pose
        frameSequence = observation.frameSequence
        observationHandler?(observation)
        return true
    }

    private func suspendObservations() {
        acceptsObservations = false
        pose = nil
        forwardClearance = .infinity
        latestDepthSafetySnapshot = nil
        trackingState = .notAvailable
        latestPixelBuffer = nil
        latestObservation = nil
        invalidateRelativeHeadingMeasurement(reason: .trackingInterrupted)
        latestCamera = nil
        latestDepthMap = nil
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        suspendObservations()
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        acceptsObservations = true
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        suspendObservations()
    }

    private static func trackingQuality(_ state: ARCamera.TrackingState) -> PoseTrackingQuality {
        switch state {
        case .normal: .normal
        case .limited: .limited
        case .notAvailable: .unavailable
        }
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
        guard let camera = latestCamera, let depthMap = latestDepthMap else { return nil }
        let imageSize = camera.imageResolution // raw (landscape) sensor pixel space, matches `intrinsics`
        guard let depth = Self.sampleDepth(depthMap, atVisionNormalizedPoint: normalizedPoint, imageSize: imageSize) else {
            return nil
        }
        return Self.unprojectPoint(normalizedPoint, imageSize: imageSize,
                                   intrinsics: camera.intrinsics, cameraTransform: camera.transform, depth: depth)
    }

    /// Undoes the `.right` (90° clockwise) rotation `Detector`'s Vision request handler
    /// applied, landing back in the raw sensor pixel space `intrinsics`/depth are
    /// calibrated against.
    static func sensorPixel(forVisionNormalizedPoint p: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(x: (1 - p.y) * imageSize.width, y: (1 - p.x) * imageSize.height)
    }

    /// Samples the LiDAR depth map (meters) at the raw-sensor-space point corresponding to
    /// a Vision-normalized point. The depth map is lower-res than the color camera but
    /// aligned to the same field of view, so the fractional position carries over directly.
    static func sampleDepth(_ depthMap: CVPixelBuffer, atVisionNormalizedPoint p: CGPoint, imageSize: CGSize) -> Float? {
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
    static func unprojectPoint(_ visionNormalizedPoint: CGPoint, imageSize: CGSize,
                               intrinsics: simd_float3x3, cameraTransform: simd_float4x4, depth: Float) -> Vec2 {
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

extension ARSessionManager: RoomSessionARManaging {}
