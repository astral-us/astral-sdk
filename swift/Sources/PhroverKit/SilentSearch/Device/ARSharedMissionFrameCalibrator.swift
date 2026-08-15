import Foundation
import RoverNav

@MainActor
public final class ARSharedMissionFrameCalibrator: SilentSearchCalibrating {
    public typealias Scanner = @Sendable (OpticalFrame) throws -> [OpticalObservation]

    private let sessionManager: ARSessionManager
    private let scanner: Scanner
    private let eventSink: (any SilentSearchEventSink)?
    private var task: Task<Void, Never>?

    public init(sessionManager: ARSessionManager, scanner: OpticalQRCodeScanner = OpticalQRCodeScanner(),
                events: (any SilentSearchEventSink)? = nil) {
        self.sessionManager = sessionManager
        self.scanner = { try scanner.scan($0) }
        self.eventSink = events
    }

    init(sessionManager: ARSessionManager, events: (any SilentSearchEventSink)? = nil,
         scanner: @escaping Scanner) {
        self.sessionManager = sessionManager
        self.scanner = scanner
        self.eventSink = events
    }

    public func events(markerID: String, sessionGeneration: UInt64) -> AsyncStream<SilentSearchCalibrationEvent> {
        cancel()
        return AsyncStream { continuation in
            task = Task { @MainActor [sessionManager, scanner, eventSink] in
                guard let configuration = SharedMissionCalibrationConfiguration(markerID: markerID) else {
                    continuation.yield(.rejected(.invalidMarkerID))
                    continuation.finish()
                    return
                }
                var calibrator = SharedMissionCalibrator(
                    configuration: configuration, sessionGeneration: sessionGeneration, events: eventSink
                )
                var lastFailure: SilentSearchCalibrationIssue?
                var lastExpectedDetectionTimestamp: TimeInterval?
                var markerVisible = false
                for await snapshot in sessionManager.snapshots() {
                    guard !Task.isCancelled else { break }
                    guard snapshot.trackingQuality == .normal else { continue }
                    guard snapshot.id.generation == sessionGeneration else {
                        continuation.yield(.feedback(.groundingFailed(
                            frameID: snapshot.id, monotonicTimestamp: snapshot.timestamp,
                            reason: .generationMismatch
                        )))
                        continuation.yield(.rejected(.generationMismatch))
                        break
                    }
                    let opticalFrame = OpticalFrame(pixelBuffer: snapshot.image,
                        arFrameID: snapshot.id, monotonicTimestamp: snapshot.timestamp)
                    let scans: [OpticalObservation]
                    do {
                        scans = try scanner(opticalFrame)
                    } catch {
                        if lastFailure != .scannerFailure {
                            continuation.yield(.feedback(.scannerFailed(
                                frameID: snapshot.id, monotonicTimestamp: snapshot.timestamp
                            )))
                            lastFailure = .scannerFailure
                        }
                        scans = []
                    }
                    var detectedExpectedMarker = false
                    for scan in scans {
                        let result = Self.ground(
                            observation: scan, in: snapshot, expectedMarkerID: markerID,
                            sessionGeneration: sessionGeneration
                        )
                        let expectedMarkerWasValidated: Bool
                        switch result {
                        case .success:
                            expectedMarkerWasValidated = true
                        case let .failure(reason):
                            switch reason {
                            case .missingDepthMap, .cornerUnavailable:
                                expectedMarkerWasValidated = true
                            default:
                                expectedMarkerWasValidated = false
                            }
                        }
                        if expectedMarkerWasValidated {
                            detectedExpectedMarker = true
                            markerVisible = true
                            lastExpectedDetectionTimestamp = snapshot.timestamp
                            continuation.yield(.feedback(.expectedMarkerDetected(
                                frameID: snapshot.id, monotonicTimestamp: snapshot.timestamp,
                                markerID: markerID, corners: scan.corners
                            )))
                        }
                        guard case let .success(observation) = result else {
                            guard case let .failure(reason) = result else { continue }
                            let issue = SilentSearchCalibrationIssue.groundingFailure(reason)
                            if issue != lastFailure {
                                continuation.yield(.feedback(.groundingFailed(
                                    frameID: snapshot.id, monotonicTimestamp: snapshot.timestamp,
                                    reason: reason
                                )))
                                lastFailure = issue
                            }
                            continue
                        }
                        continuation.yield(.feedback(.allCornersGrounded(
                            frameID: snapshot.id, monotonicTimestamp: snapshot.timestamp
                        )))
                        lastFailure = nil
                        switch calibrator.observe(observation) {
                        case let .collecting(frameCount):
                            continuation.yield(.progress(acceptedFrameCount: frameCount))
                        case let .rejected(diagnostic):
                            continuation.yield(.rejected(diagnostic))
                        case let .accepted(frame):
                            continuation.yield(.accepted(frame))
                            continuation.finish()
                            return
                        }
                    }
                    if !detectedExpectedMarker, markerVisible,
                       let lastExpectedDetectionTimestamp,
                       snapshot.timestamp - lastExpectedDetectionTimestamp >= 0.5 {
                        continuation.yield(.feedback(.qrLost(
                            frameID: snapshot.id, monotonicTimestamp: snapshot.timestamp
                        )))
                        markerVisible = false
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.cancel() }
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    nonisolated static func ground(
        observation: OpticalObservation,
        in snapshot: ARFrameSnapshot,
        expectedMarkerID: String,
        sessionGeneration: UInt64
    ) -> Result<SharedMissionCalibrationObservation, SilentSearchCalibrationGroundingFailure> {
        guard snapshot.trackingQuality == .normal else { return .failure(.trackingNotNormal) }
        guard snapshot.id.generation == sessionGeneration else { return .failure(.generationMismatch) }
        guard observation.frameID == snapshot.id.sequence else { return .failure(.frameMismatch) }
        guard observation.monotonicTimestamp == snapshot.timestamp else { return .failure(.timestampMismatch) }
        guard let payload = String(data: observation.payload, encoding: .utf8),
              let markerID = SharedMissionCalibrator.markerID(fromPayload: payload) else {
            return .failure(.invalidPayload)
        }
        guard markerID == expectedMarkerID else { return .failure(.wrongMarkerID) }
        guard snapshot.depthMap != nil else { return .failure(.missingDepthMap) }
        func point(_ normalized: Vec2) -> Vec2? {
            ARSessionManager.unproject(
                normalizedPoint: CGPoint(x: normalized.x, y: normalized.y), in: snapshot
            )
        }
        guard let topLeft = point(observation.corners.topLeft) else {
            return .failure(.cornerUnavailable(.topLeft))
        }
        guard let topRight = point(observation.corners.topRight) else {
            return .failure(.cornerUnavailable(.topRight))
        }
        guard let bottomLeft = point(observation.corners.bottomLeft) else {
            return .failure(.cornerUnavailable(.bottomLeft))
        }
        guard let bottomRight = point(observation.corners.bottomRight) else {
            return .failure(.cornerUnavailable(.bottomRight))
        }
        return .success(SharedMissionCalibrationObservation(
            markerID: expectedMarkerID, sessionGeneration: snapshot.id.generation,
            frameID: snapshot.id.sequence, monotonicTimestamp: snapshot.timestamp,
            corners: OrientedMarkerCorners(topLeft: topLeft, topRight: topRight,
                                           bottomLeft: bottomLeft, bottomRight: bottomRight)
        ))
    }
}
