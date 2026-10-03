import Foundation
import ARKit
import RoverNav

/// Only detections and depth belonging to a single rear-camera AR snapshot may be combined.
@MainActor
public final class ARFollowMePerceptionSource: FollowMePerception {
    private let ar: ARSessionManager
    private let detector: Detector

    public var detectorReady: Bool { detector.isLoaded }
    public var personLabelAvailable: Bool { detector.supportedCanonicalLabels.contains("person") }

    public init(ar: ARSessionManager, detector: Detector) {
        self.ar = ar
        self.detector = detector
    }

    public func events() -> AsyncStream<FollowPerceptionEvent> {
        let frames = ar.snapshots()
        let lifecycle = ar.lifecycleEvents()
        // Never discard a safety event when a newer camera frame arrives. The upstream
        // AR snapshot stream already bounds frame production to its newest sample.
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let frameTask = Task { [detector, ar] in
                for await snapshot in frames {
                    guard !Task.isCancelled else { break }
                    // The live frame may differ from the snapshot. This reason is diagnostic
                    // only; all perception eligibility and projection use the snapshot.
                    let reason = ar.session.currentFrame.map { Self.trackingReason(from: $0.camera.trackingState) } ?? nil
                    if snapshot.trackingQuality != .normal {
                        continuation.yield(.frame(Self.batch(from: snapshot, detections: [],
                                                            trackingReason: reason)))
                        continue
                    }
                    let started = ProcessInfo.processInfo.systemUptime
                    let receipt = detector.evaluateForFollow(snapshot)
                    let duration = ProcessInfo.processInfo.systemUptime - started
                    continuation.yield(.frame(Self.batch(from: snapshot, detections: receipt.frame.detections,
                                                        trackingReason: reason, inferenceDuration: duration,
                                                        inferenceStatus: receipt.status == .executed ? .executed : .failed,
                                                        inferenceFailureReason: receipt.failureReason)))
                }
            }
            let lifecycleTask = Task {
                for await event in lifecycle {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .reset, .interrupted: continuation.yield(.interrupted)
                    case .failed(_, let description): continuation.yield(.failed(description))
                    case .interruptionEnded: break
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in
                frameTask.cancel()
                lifecycleTask.cancel()
            }
        }
    }

    public static func batch(from snapshot: ARFrameSnapshot,
                             detections: [Detector.Detection],
                             trackingReason: FollowTrackingReason? = nil,
                             inferenceDuration: TimeInterval? = nil,
                              inferenceStatus: FollowInferenceStatus = .executed,
                              inferenceFailureReason: Detector.FailureReason? = nil) -> FollowFrameBatch {
        let rawPeople = detections.filter { $0.label.lowercased() == "person" }
        let status: FollowInferenceStatus = snapshot.trackingQuality == .normal ? inferenceStatus : .skippedTracking
        let evaluated = status != .skippedTracking && status != .failed
        let detectorCountsKnown = status == .executed
        let candidates = evaluated ? rawPeople.enumerated().map { id, detection in
            FollowPersonProjection.evaluate(box: detection.boundingBox, detectorConfidence: detection.confidence,
                                            rawPersonID: id, in: snapshot)
        } : []
        let people: [FollowPersonObservation] = candidates.compactMap { candidate in
            guard let position = candidate.position, candidate.rejection == nil,
                  position.x.isFinite, position.y.isFinite else { return nil }
            return FollowPersonObservation(frameID: snapshot.id, timestamp: snapshot.timestamp,
                                           confidence: candidate.detectorConfidence, boundingBox: candidate.box,
                                           position: position, pose: snapshot.pose, rawPersonID: candidate.rawPersonID)
        }
        let diagnostics = FollowPerceptionDiagnostics(frameID: snapshot.id, timestamp: snapshot.timestamp,
            inferenceStatus: status, inferenceFailureReason: inferenceFailureReason,
            rawDetectorCount: detectorCountsKnown ? detections.count : nil, rawPersonCount: detectorCountsKnown ? rawPeople.count : nil,
            projectionAttemptedCount: evaluated ? candidates.count : nil,
            projectionAcceptedCount: evaluated ? people.count : nil,
            projectionRejectedCount: evaluated ? candidates.count - people.count : nil,
            projectedPersonCount: evaluated ? people.count : nil, candidates: candidates)
        return FollowFrameBatch(frameID: snapshot.id, timestamp: snapshot.timestamp,
                                pose: snapshot.trackingQuality == .normal ? snapshot.pose : nil,
                                depthAvailable: snapshot.depthMap != nil, people: people,
                                trackingQuality: snapshot.trackingQuality, trackingReason: trackingReason,
                                inferenceDuration: inferenceDuration, perceptionDiagnostics: diagnostics)
    }

    public static func trackingReason(from state: ARCamera.TrackingState) -> FollowTrackingReason? {
        switch state {
        case .normal: return nil
        case .notAvailable: return .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: return .initializing
            case .excessiveMotion: return .excessiveMotion
            case .insufficientFeatures: return .insufficientFeatures
            case .relocalizing: return .relocalizing
            @unknown default: return .unknown
            }
        }
    }
}

@MainActor
public final class SystemFollowClock: FollowMeClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
}
