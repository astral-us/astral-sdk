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
                for await snapshot in sessionManager.snapshots() {
                    guard !Task.isCancelled else { break }
                    guard snapshot.trackingQuality == .normal else { continue }
                    guard snapshot.id.generation == sessionGeneration else {
                        continuation.yield(.rejected(.generationMismatch))
                        break
                    }
                    let opticalFrame = OpticalFrame(pixelBuffer: snapshot.image,
                        arFrameID: snapshot.id, monotonicTimestamp: snapshot.timestamp)
                    guard let scans = try? scanner(opticalFrame) else { continue }
                    for scan in scans {
                        guard let observation = Self.ground(
                            observation: scan, in: snapshot, expectedMarkerID: markerID
                        ) else { continue }
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

    nonisolated static func ground(observation: OpticalObservation, in snapshot: ARFrameSnapshot,
                                  expectedMarkerID: String) -> SharedMissionCalibrationObservation? {
        guard snapshot.trackingQuality == .normal,
              observation.frameID == snapshot.id.sequence,
              observation.monotonicTimestamp == snapshot.timestamp,
              let payload = String(data: observation.payload, encoding: .utf8),
              SharedMissionCalibrator.markerID(fromPayload: payload) == expectedMarkerID else {
            return nil
        }
        func point(_ normalized: Vec2) -> Vec2? {
            ARSessionManager.unproject(
                normalizedPoint: CGPoint(x: normalized.x, y: normalized.y), in: snapshot
            )
        }
        guard let topLeft = point(observation.corners.topLeft),
              let topRight = point(observation.corners.topRight),
              let bottomLeft = point(observation.corners.bottomLeft),
              let bottomRight = point(observation.corners.bottomRight) else {
            return nil
        }
        return SharedMissionCalibrationObservation(
            markerID: expectedMarkerID, sessionGeneration: snapshot.id.generation,
            frameID: snapshot.id.sequence, monotonicTimestamp: snapshot.timestamp,
            corners: OrientedMarkerCorners(topLeft: topLeft, topRight: topRight,
                                           bottomLeft: bottomLeft, bottomRight: bottomRight)
        )
    }
}
