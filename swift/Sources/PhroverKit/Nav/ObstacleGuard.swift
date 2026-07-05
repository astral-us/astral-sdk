import Foundation

/// Safety layer sitting between the planner and the motors. Independent of the global
/// costmap so it reacts to *dynamic* obstacles (ground crew or a cart crossing its path)
/// and to link loss. Returns whether it is safe to keep driving; if not, the caller must stop.
public struct ObstacleGuard: Sendable {
    public var stopDistance: Double      // m — hard stop if forward clearance drops below
    public var watchdogTimeout: Double

    public init(stopDistance: Double = 0.45, watchdogTimeout: Double = RoverConfig.commsWatchdogTimeout) {
        self.stopDistance = stopDistance
        self.watchdogTimeout = watchdogTimeout
    }

    public enum Decision: Equatable {
        case go
        case stopObstacle(clearance: Double)
        case stopCommsLost
        case stopTipping
    }

    public func evaluate(forwardClearance: Double,
                          lastAckAt: Date?,
                          now: Date = Date(),
                          feedback: RoverFeedback?) -> Decision {
        if let fb = feedback, fb.isTipping() { return .stopTipping }
        if forwardClearance < stopDistance { return .stopObstacle(clearance: forwardClearance) }
        if let last = lastAckAt {
            if now.timeIntervalSince(last) > watchdogTimeout { return .stopCommsLost }
        }
        return .go
    }
}
