import Foundation
import RoverNav

public struct FollowFrameBatch: @unchecked Sendable {
    public let frameID: ARFrameID
    public let timestamp: TimeInterval
    public let pose: Pose2D?
    public let depthAvailable: Bool
    public let people: [FollowPersonObservation]

    public init(frameID: ARFrameID, timestamp: TimeInterval, pose: Pose2D?,
                depthAvailable: Bool, people: [FollowPersonObservation]) {
        self.frameID = frameID
        self.timestamp = timestamp
        self.pose = pose
        self.depthAvailable = depthAvailable
        self.people = people
    }
}

public enum FollowPerceptionEvent: Sendable {
    case frame(FollowFrameBatch)
    case interrupted
    case failed(String)
}

@MainActor
public protocol FollowMePerception {
    var detectorReady: Bool { get }
    var personLabelAvailable: Bool { get }
    func events() -> AsyncStream<FollowPerceptionEvent>
}

@MainActor
public protocol FollowMeMotion {
    func rotateForScan(by angle: Double) async -> NavigationResult
    func navigate(to goal: Vec2, stoppingAtForwardClearance clearance: Double) async -> NavigationResult
    func stopAndConfirm() async throws
    func safetyStates() -> AsyncStream<NavigationSafetyState>
}

@MainActor
public protocol FollowMeClock {
    var now: TimeInterval { get }
    func sleep(seconds: Double) async
}
