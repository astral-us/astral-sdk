import Foundation

/// Detects a commanded drive that is no longer reducing its distance to the goal.
public struct DriveProgressWatchdog: Sendable {
    public let timeout: TimeInterval
    public let minimumProgress: Double

    private var bestDistance: Double?
    private var lastProgressAt: Date?

    public init(timeout: TimeInterval, minimumProgress: Double) {
        self.timeout = timeout
        self.minimumProgress = minimumProgress
    }

    public mutating func observe(distanceToGoal: Double,
                                 now: Date = Date(),
                                 commanded: Bool) -> Bool {
        guard commanded else {
            reset()
            return false
        }

        guard let bestDistance, let lastProgressAt else {
            self.bestDistance = distanceToGoal
            self.lastProgressAt = now
            return false
        }

        if bestDistance - distanceToGoal >= minimumProgress {
            self.bestDistance = distanceToGoal
            self.lastProgressAt = now
            return false
        }

        return now.timeIntervalSince(lastProgressAt) >= timeout
    }

    public mutating func reset() {
        bestDistance = nil
        lastProgressAt = nil
    }
}
