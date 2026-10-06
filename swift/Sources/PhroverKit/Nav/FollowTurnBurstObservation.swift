import Foundation

/// Operation-local source observation. A trigger ends a burst, never establishes
/// arrival or owns motors. Source timestamps remain the actual capture times.
struct FollowTurnBurstObservation {
    let targetYaw: Double
    let tolerance: Double
    let generation: UInt64
    private let direction: Double
    private let distance: Double
    private var directedTravel = 0.0
    private var previous: NavigationPoseSample
    private(set) var triggerReason: String?

    init?(targetYaw: Double, tolerance: Double, start: NavigationPoseSample, uptime: Double) {
        guard targetYaw.isFinite, tolerance.isFinite, tolerance >= 0,
              start.rejection(at: uptime, requireEnriched: true) == nil,
              let generation = start.frameID?.generation else { return nil }
        self.targetYaw = targetYaw
        self.tolerance = tolerance
        self.generation = generation
        let error = FollowReacquisitionPlanner.wrap(targetYaw - start.pose!.yaw)
        direction = error < 0 ? -1 : 1
        distance = abs(error)
        previous = start
    }

    mutating func observe(_ sample: NavigationPoseSample, at uptime: Double) -> Bool {
        guard sample.rejection(at: uptime, expectedGeneration: generation, requireEnriched: true) == nil,
              let frame = sample.frameID, let timestamp = sample.sourceTimestamp,
              frame.sequence > previous.frameID!.sequence,
              timestamp > previous.sourceTimestamp! else { return false }
        directedTravel += direction * FollowReacquisitionPlanner.wrap(sample.pose!.yaw - previous.pose!.yaw)
        previous = sample
        if directedTravel >= distance { triggerReason = "crossing"; return true }
        if abs(FollowReacquisitionPlanner.wrap(targetYaw - sample.pose!.yaw)) <= tolerance {
            triggerReason = "tolerance"; return true
        }
        return false
    }
}

/// Bounded immutable collection facts, retained across send, stop/drain and
/// stopped-source admission. Missing events cannot be turned into a rate bound.
struct FollowTurnResponseBracket {
    private(set) var samples: [FollowTurnBurstPlanner.Sample] = []
    private(set) var unambiguous = true
    let generation: UInt64

    init(start: NavigationPoseSample, at uptime: Double, generation: UInt64,
         boundary: FollowTurnBurstPlanner.Sample?) {
        self.generation = generation
        let captured = Self.capture(start, at: uptime, generation: generation, healthy: true)
        if let boundary, Self.sameSource(boundary, captured), boundary.healthy {
            samples = [boundary] // Exact immutable boundary shared by adjacent bursts.
        } else { samples = [captured] }
    }

    mutating func collect(_ source: NavigationPoseSample, at uptime: Double, healthy: Bool,
                          settled: Bool = false) {
        let captured = Self.capture(source, at: uptime, generation: generation, healthy: healthy)
        if let previous = samples.last, Self.sameSource(previous, captured) {
            if !captured.healthy { unambiguous = false }
            // A strict stopped evaluation is a real collection, not a fabricated
            // frame advance. It can replace the same ingress endpoint only.
            if settled, previous.healthy, captured.healthy { samples[samples.count - 1] = captured }
            return
        }
        if let previous = samples.last {
            if previous.sequence == UInt64.max || captured.sequence != previous.sequence.map({ $0 + 1 }) {
                unambiguous = false // Coalesced/dropped, reordered or replayed source.
            }
        }
        guard samples.count < 128 else { unambiguous = false; return }
        samples.append(captured)
    }

    private static func capture(_ source: NavigationPoseSample, at uptime: Double,
                                generation: UInt64, healthy: Bool) -> FollowTurnBurstPlanner.Sample {
        .init(yaw: source.pose?.yaw ?? .nan, sequence: source.frameID?.sequence,
            generation: source.frameID?.generation, sourceTimestamp: source.sourceTimestamp,
            collectedUptime: uptime, clockDomain: "ar_system_uptime",
            healthy: healthy && source.rejection(at: uptime, expectedGeneration: generation, requireEnriched: true) == nil,
            sourceIdentity: source.source, trackingState: source.trackingQuality.map { String(describing: $0) })
    }

    private static func sameSource(_ lhs: FollowTurnBurstPlanner.Sample,
                                   _ rhs: FollowTurnBurstPlanner.Sample) -> Bool {
        lhs.sequence == rhs.sequence && lhs.generation == rhs.generation &&
            lhs.sourceTimestamp == rhs.sourceTimestamp && lhs.yaw == rhs.yaw
    }
}
