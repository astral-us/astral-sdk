import Foundation
import RoverNav

enum FollowTurnSourceScope {
    @TaskLocal static var required = false
}

/// Cancellation reaches a queued timer synchronously, before the actor hop
/// that resumes its source waiter. A cancelled timer must not invoke sleep.
final class FollowTurnSourceWaitToken: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func cancel() { lock.withLock { active = false } }
}

enum FollowTurnSourceResult {
    case sample(NavigationPoseSample)
    case failed(NavigationFailure)
    case cancelled
}

/// The executor passes its existing checkpoint; settle/source waits never reset it.
struct FollowTurnWaitingProgress {
    var watchdog = DriveProgressWatchdog(timeout: 2.5, minimumProgress: 0.05)
    var distanceToGoal: Double = 0
    var hasSentCommand = false

    func remaining(at date: Date) -> TimeInterval? {
        let snapshot = watchdog.diagnosticSnapshot(distanceToGoal: distanceToGoal, now: date)
        return snapshot.elapsed.map { max(0, snapshot.interval - $0) }
    }

    func expired(at date: Date) -> Bool { remaining(at: date).map { $0 <= 0 } ?? false }
}

/// One Date-based progress epoch for the entire frozen-target operation.
/// Only distinct healthy source observations can move its 0.05-rad checkpoint.
@MainActor
final class FollowTurnRuntimeState {
    let targetYaw: Double
    let generation: UInt64
    var progress = FollowTurnWaitingProgress()
    var lastAck: Date?
    private(set) var failure: NavigationFailure?
    private var previous: NavigationPoseSample

    init(targetYaw: Double, initial: NavigationPoseSample, tolerance: Double, date: Date) {
        self.targetYaw = targetYaw
        generation = initial.frameID!.generation
        previous = initial
        progress.distanceToGoal = abs(FollowReacquisitionPlanner.wrap(targetYaw - initial.pose!.yaw))
        if progress.distanceToGoal > tolerance {
            _ = progress.watchdog.observe(distanceToGoal: progress.distanceToGoal, now: date, commanded: true)
        }
    }

    func expire(at date: Date) {
        if failure == nil, progress.expired(at: date) { failure = .stalled }
    }

    func fail(_ reason: NavigationFailure) { if failure == nil { failure = reason } }

    func observe(_ sample: NavigationPoseSample, uptime: Double, date: Date) {
        guard failure == nil else { return }
        guard sample.rejection(at: uptime, expectedGeneration: generation, requireEnriched: true) == nil else {
            failure = .trackingLost
            return
        }
        guard sample.frameID!.sequence > previous.frameID!.sequence,
              sample.sourceTimestamp! > previous.sourceTimestamp! else { expire(at: date); return }
        previous = sample
        progress.distanceToGoal = abs(FollowReacquisitionPlanner.wrap(targetYaw - sample.pose!.yaw))
        if progress.watchdog.observe(distanceToGoal: progress.distanceToGoal, now: date, commanded: true) {
            failure = .stalled
        }
    }
}

/// Immutable confirmation facts in the AR/system-uptime domain.
struct FollowTurnStopFence: Sendable {
    let identity: UUID
    let operationGeneration: UInt
    let context: FollowMotionOperationContext
    let acknowledgementUptime: TimeInterval
    let sourceGeneration: UInt64?
    let highestSequence: UInt64?
    let highestSourceTimestamp: TimeInterval?
}

struct FollowTurnSourceHighWater: Sendable {
    let frameID: ARFrameID
    let sourceTimestamp: TimeInterval?
}

struct FollowTurnSourceHealth: Sendable {
    let generation: UInt64
    let trackingQuality: ARTrackingQuality
}

/// Operation-local bounded ingress, independent of source-provider reads.
struct FollowTurnSourceGate {
    private(set) var latest: NavigationPoseSample?
    private(set) var highestSequence: UInt64?
    private(set) var highestTimestamp: TimeInterval?
    private(set) var generation: UInt64?
    private var lastConsumed: NavigationPoseSample?

    mutating func include(_ highWater: FollowTurnSourceHighWater) {
        if generation != highWater.frameID.generation {
            generation = highWater.frameID.generation
            highestSequence = nil
            highestTimestamp = nil
        }
        highestSequence = max(highestSequence ?? 0, highWater.frameID.sequence)
        if let timestamp = highWater.sourceTimestamp, timestamp.isFinite {
            highestTimestamp = max(highestTimestamp ?? timestamp, timestamp)
        }
    }

    mutating func ingest(_ sample: NavigationPoseSample) {
        latest = sample
        if let id = sample.frameID {
            if generation != id.generation {
                generation = id.generation
                highestSequence = nil
                highestTimestamp = nil
            }
            highestSequence = max(highestSequence ?? 0, id.sequence)
        }
        if let time = sample.sourceTimestamp, time.isFinite {
            highestTimestamp = max(highestTimestamp ?? time, time)
        }
    }

    func fence(at uptime: TimeInterval, operationGeneration: UInt,
               context: FollowMotionOperationContext = .unknown) -> FollowTurnStopFence {
        .init(identity: UUID(), operationGeneration: operationGeneration, context: context,
              acknowledgementUptime: uptime, sourceGeneration: generation,
              highestSequence: highestSequence, highestSourceTimestamp: highestTimestamp)
    }

    mutating func consume(after fence: FollowTurnStopFence, at uptime: TimeInterval) -> NavigationPoseSample? {
        guard uptime >= fence.acknowledgementUptime + 0.300,
              let sample = latest, let id = sample.frameID, let timestamp = sample.sourceTimestamp,
              sample.rejection(at: uptime, expectedGeneration: fence.sourceGeneration, requireEnriched: true) == nil,
              timestamp > fence.acknowledgementUptime,
              id.sequence > (fence.highestSequence ?? 0),
              timestamp > (fence.highestSourceTimestamp ?? -.infinity) else { return nil }
        if let consumed = lastConsumed, consumed.frameID?.generation == id.generation {
            guard id.sequence > (consumed.frameID?.sequence ?? 0),
                  timestamp > (consumed.sourceTimestamp ?? -.infinity) else { return nil }
        }
        lastConsumed = sample
        return sample
    }

    /// Read-only explanation of the current stopped admission fence.
    func diagnosticRejection(after fence: FollowTurnStopFence, at uptime: Double) -> String? {
        guard let sample = latest else { return "missing_source" }
        if let reason = sample.rejection(at: uptime, expectedGeneration: fence.sourceGeneration, requireEnriched: true) { return reason }
        if uptime < fence.acknowledgementUptime + 0.300 { return "settle_pending" }
        if sample.sourceTimestamp! <= fence.acknowledgementUptime { return "not_strictly_post_ack" }
        if sample.frameID!.sequence <= (fence.highestSequence ?? 0) { return "below_stop_frame_fence" }
        if sample.sourceTimestamp! <= (fence.highestSourceTimestamp ?? -.infinity) { return "below_stop_time_fence" }
        if let consumed = lastConsumed, consumed.frameID?.generation == sample.frameID!.generation,
           sample.frameID!.sequence <= (consumed.frameID?.sequence ?? 0) || sample.sourceTimestamp! <= (consumed.sourceTimestamp ?? -.infinity) {
            return "not_advancing_consumed_source"
        }
        return nil
    }
}
