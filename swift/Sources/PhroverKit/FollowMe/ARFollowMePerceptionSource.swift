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
            let frameTask = Task { [detector] in
                for await snapshot in frames {
                    guard !Task.isCancelled else { break }
                    if snapshot.trackingQuality != .normal {
                        continuation.yield(.frame(Self.batch(from: snapshot, detections: [])))
                        continue
                    }
                    continuation.yield(.frame(Self.batch(from: snapshot, detections: detector.detect(snapshot).detections)))
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
                             detections: [Detector.Detection]) -> FollowFrameBatch {
        let people: [FollowPersonObservation] = snapshot.trackingQuality == .normal ? detections.compactMap { detection in
            guard detection.label.lowercased() == "person", snapshot.depthMap != nil else { return nil }
            let foot = CGPoint(x: detection.boundingBox.midX, y: detection.boundingBox.minY)
            guard let position = ARSessionManager.unproject(normalizedPoint: foot, in: snapshot),
                  position.x.isFinite, position.y.isFinite else { return nil }
            return FollowPersonObservation(frameID: snapshot.id, timestamp: snapshot.timestamp,
                                           confidence: detection.confidence, boundingBox: detection.boundingBox,
                                           position: position, pose: snapshot.pose)
        } : []
        return FollowFrameBatch(frameID: snapshot.id, timestamp: snapshot.timestamp,
                                pose: snapshot.trackingQuality == .normal ? snapshot.pose : nil,
                                depthAvailable: snapshot.depthMap != nil, people: people)
    }
}

@MainActor
public final class SystemFollowClock: FollowMeClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
}
