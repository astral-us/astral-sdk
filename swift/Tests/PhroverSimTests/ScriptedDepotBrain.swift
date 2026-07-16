import Foundation
import RoverNav
import PhroverKit

/// Deterministic brain for the Depot capstone ("Sweep and Report"): find the red toolbox,
/// report anything out of place, come back. Exercises capabilities #1 (situational
/// awareness is handled by the sim's own reactive guard, not this brain — see
/// GodotMotion's doc comment), #2 (memory-based return, tested separately in
/// CapstoneTests), #3 (replan on a blocked door), #4 (battery self-model), #5
/// (frontier-based exploration), #7 (ask on genuine ambiguity), #8 (unprompted anomaly
/// report).
///
/// Deliberately colour-blind about toolboxes: it tracks candidates by generic "*_toolbox"
/// match, not by reading the red_/blue_ prefix, mirroring a real on-device detector's lack
/// of attribute understanding (see PHROVER_SETUP.md's documented on-device limitation). It
/// only reads the true label to *confirm* an answer once the operator (or a forced
/// best-effort fallback) has resolved which one to check — never to front-run perception.
@MainActor
final class ScriptedDepotBrain: RoverBrain {
    private enum Phase { case searching, goingToTarget, returning, recalling, done }

    private var phase: Phase = .searching
    private var askedWhichToolbox = false
    private var confirmedTarget: MissionMemory.RememberedObject?
    private var recallTarget: Vec2?
    private var reportedAnomalies: Set<String> = []
    /// True once the returning phase has actually issued its drive-home `.navigate` this
    /// phase. Needed because `context.navState` is stale on the tick a phase transition
    /// happens via `.say(...)` (no navigate issued yet) — without this, `returning()`
    /// would misread a leftover `.arrived` from reaching the toolbox as "already home".
    private var returnNavStarted = false
    private let lowBatteryThreshold: Double
    private let anomalyLabels: Set<String>
    /// World-space rects the brain must not explore into (e.g. "stay out of the paint
    /// room"). A real product brain would need to *ground* which room that refers to —
    /// from vision, a floorplan the operator shared, or asking — none of which this
    /// text/label-only scripted brain can do on its own; this stands in for that prior
    /// grounding rather than inventing room-name semantics from nothing. `ExplorationCandidate`
    /// only carries a world point, no room identity, so this is the one place that
    /// knowledge can be injected.
    private let keepOutRects: [(min: Vec2, max: Vec2)]
    /// The candidate id we most recently issued `.explore` for, so a `.failed` navState on
    /// the next tick can be attributed to it.
    private var lastExploreCandidateId: String?
    /// Candidates whose `.explore` attempt came back `.failed` (goal became structurally
    /// unreachable — e.g. a door closed right at the frontier point). `MissionAgent` only
    /// marks a candidate `.visited` by bodily *proximity*, so an unreachable one is never
    /// visited and — without this — would be re-picked as "nearest unvisited" forever,
    /// fast-looping the exact same doomed explore decision. Confirmed live.
    private var abandonedCandidateIds: Set<String> = []
    /// Already-visited candidates re-tried as a fresh vantage point once no unexplored
    /// frontier remains anywhere (see keepSearching's recovery step).
    private var recoveryAttempted: Set<String> = []

    init(lowBatteryThreshold: Double = 30.0,
         anomalyLabels: Set<String> = ["spill"],
         keepOutRects: [(min: Vec2, max: Vec2)] = []) {
        self.lowBatteryThreshold = lowBatteryThreshold
        self.anomalyLabels = anomalyLabels
        self.keepOutRects = keepOutRects
    }

    private func isKeptOut(_ p: Vec2) -> Bool {
        keepOutRects.contains { p.x >= $0.min.x && p.x <= $0.max.x && p.y >= $0.min.y && p.y <= $0.max.y }
    }

    func nextAction(_ context: MissionContext) async throws -> BrainOutput {
        // Cross-cutting: low battery interrupts whatever phase we're in (self-model).
        if phase != .returning, phase != .done,
           let battery = context.batteryPercent, battery < lowBatteryThreshold {
            phase = .returning
            returnNavStarted = false
            return BrainOutput(decision: .say("Battery's getting low — heading back."))
        }
        // Cross-cutting: report a newly-seen anomaly the moment it's known, regardless
        // of phase (capability #8 is "unprompted", not "batched at the end").
        if let report = pendingAnomalyReport(context) {
            return report
        }

        switch phase {
        case .searching:      return search(context)
        case .goingToTarget:  return goingToTarget(context)
        case .returning:      return returning(context)
        case .recalling:      return recalling(context)
        case .done:           return recallStep(context)
        }
    }

    // MARK: - Post-mission recall (#2): "go to the X" for something only in memory now.

    private func recallStep(_ context: MissionContext) -> BrainOutput {
        guard let utterance = context.utterance else { return BrainOutput(decision: .done) }
        let lower = utterance.lowercased()
        guard let match = context.memory.rememberedObjects.first(where: {
            lower.contains($0.label.replacingOccurrences(of: "_", with: " ")) || lower.contains($0.label)
        }) else {
            return BrainOutput(decision: .done)
        }
        recallTarget = match.worldPoint
        phase = .recalling
        return BrainOutput(decision: .navigate(.worldPoint(match.worldPoint)),
                            updatedPlan: "Recalling \(match.label) from memory (not currently visible).")
    }

    private func recalling(_ context: MissionContext) -> BrainOutput {
        switch context.navState {
        case .arrived, .failed:
            phase = .done
            return BrainOutput(decision: .done)
        default:
            guard let target = recallTarget else {
                phase = .done
                return BrainOutput(decision: .done)
            }
            return BrainOutput(decision: .navigate(.worldPoint(target)))
        }
    }

    // MARK: - Anomaly reporting (#8)

    private func pendingAnomalyReport(_ context: MissionContext) -> BrainOutput? {
        for anomaly in context.memory.rememberedObjects where anomalyLabels.contains(anomaly.label) {
            guard !reportedAnomalies.contains(anomaly.label) else { continue }
            reportedAnomalies.insert(anomaly.label)
            return BrainOutput(decision: .say("Heads up — there's a \(anomaly.label.replacingOccurrences(of: "_", with: " ")) I wasn't expecting."))
        }
        return nil
    }

    // MARK: - Search phase (#5 exploration, #7 ambiguity)

    private func search(_ context: MissionContext) -> BrainOutput {
        if let failedId = lastExploreCandidateId, case .failed = context.navState {
            abandonedCandidateIds.insert(failedId)
        }
        lastExploreCandidateId = nil

        let toolboxes = context.memory.rememberedObjects.filter { $0.label.hasSuffix("toolbox") }

        // The operator just answered our disambiguating question.
        if askedWhichToolbox, confirmedTarget == nil, let reply = context.utterance {
            if reply.lowercased().contains("red"), let red = toolboxes.first(where: { $0.label == "red_toolbox" }) {
                return commit(to: red)
            }
            if reply.lowercased().contains("blue") {
                // Confirmed NOT the target — keep searching, but don't re-ask.
                return keepSearching(context)
            }
        }
        // No usable reply came back — proceed best-effort (don't ask again).
        if askedWhichToolbox, confirmedTarget == nil, context.lastAnswerWasInconclusive {
            if let red = toolboxes.first(where: { $0.label == "red_toolbox" }) {
                return commit(to: red)
            }
        }

        if toolboxes.count >= 2, !askedWhichToolbox {
            askedWhichToolbox = true
            return BrainOutput(decision: .ask("I see two toolboxes now — which one is the red one?"),
                                updatedPlan: "1. Find the red toolbox (two candidates seen, asked operator to disambiguate).")
        }

        if toolboxes.count == 1, toolboxes[0].label == "red_toolbox" {
            return commit(to: toolboxes[0])
        }

        return keepSearching(context)
    }

    private func commit(to target: MissionMemory.RememberedObject) -> BrainOutput {
        confirmedTarget = target
        phase = .goingToTarget
        return BrainOutput(decision: .navigate(.worldPoint(target.worldPoint)),
                            updatedPlan: "1. Go to the confirmed red toolbox. 2. Report anything out of place. 3. Return.")
    }

    private func keepSearching(_ context: MissionContext) -> BrainOutput {
        var candidates = context.explorationCandidates.filter {
            $0.status == .unexplored && !isKeptOut($0.worldPoint) && !abandonedCandidateIds.contains($0.id)
        }
        if candidates.isEmpty {
            // Nothing new and nothing untried — reconsider ones given up on earlier
            // rather than spin looking around forever (confirmed live: that fallback has
            // no exit condition and just burns the whole tick budget). The rover has
            // since moved and replanned; a candidate abandoned from a stale vantage/path
            // may be reachable now, and retrying is strictly better than never trying.
            candidates = context.explorationCandidates.filter {
                $0.status == .unexplored && !isKeptOut($0.worldPoint)
            }
        }
        // Nearest-first, not "first in whatever order FrontierFinder returned them"
        // (big-openings-first — not distance-ordered). Greedy-nearest is a standard
        // frontier-exploration heuristic; without it the brain ping-pongs between distant
        // openings across rooms it's already passed by, burning real mission time and
        // battery without covering new ground — confirmed live: one run took 12+ frontier
        // hops and 260+ seconds without finding the target.
        let chosen = candidates.min(by: { $0.worldPoint.distance(to: context.pose?.position ?? .zero)
                                            < $1.worldPoint.distance(to: context.pose?.position ?? .zero) })
            ?? candidates.first
        if let next = chosen {
            lastExploreCandidateId = next.id
            return BrainOutput(decision: .explore(candidateId: next.id),
                                updatedPlan: "1. Search rooms for the red toolbox (staying out of the paint room).")
        }

        // No frontier left anywhere (the observed-grid sweep, which ignores props, can
        // fully cover an area from a raycast angle that never lined up with the target
        // object's exact camera FOV/occlusion — confirmed live: the grid reports "fully
        // observed" while the object was still never actually detected). Spinning in
        // place only helps if the miss was "wrong heading", not "occluded from here" —
        // get a genuinely different vantage instead: revisit the largest known opening
        // not yet tried as a recovery point.
        let recoveryPool = context.explorationCandidates
            .filter { $0.status == .visited && !isKeptOut($0.worldPoint) && !recoveryAttempted.contains($0.id) }
            .sorted { $0.widthMeters > $1.widthMeters }
        if let recovery = recoveryPool.first {
            recoveryAttempted.insert(recovery.id)
            return BrainOutput(decision: .explore(candidateId: recovery.id),
                                updatedPlan: "1. Re-checking \(recovery.id) from a different angle — couldn't get a clear look last time.")
        }

        return BrainOutput(decision: .lookAround(angle: .pi / 2))
    }

    // MARK: - Driving to the target (#3 replan on blocked door)

    private func goingToTarget(_ context: MissionContext) -> BrainOutput {
        switch context.navState {
        case .arrived:
            phase = .returning
            returnNavStarted = false
            return BrainOutput(decision: .say("Found the red toolbox."))
        case .failed:
            // Re-issue navigate: GodotMotion rebuilds the costmap from the *current*
            // occupancy grid each time, so a newly-closed door is reflected and A* will
            // route via whatever alternate path exists (never the same blocked door).
            guard let target = confirmedTarget else {
                phase = .searching
                return keepSearching(context)
            }
            return BrainOutput(decision: .navigate(.worldPoint(target.worldPoint)))
        default:
            // MissionAgent only calls back in once motion.state has left .driving
            // (waitForMotionToSettle), so this is a defensive fallback, not the expected path.
            guard let target = confirmedTarget else { return BrainOutput(decision: .lookAround(angle: 0.1)) }
            return BrainOutput(decision: .navigate(.worldPoint(target.worldPoint)))
        }
    }

    // MARK: - Returning home (#4 battery self-model, #2 memory-based nav)

    private func returning(_ context: MissionContext) -> BrainOutput {
        guard let start = context.memory.missionStartPose else {
            phase = .done
            return BrainOutput(decision: .done)
        }
        guard returnNavStarted else {
            returnNavStarted = true
            return BrainOutput(decision: .navigate(.worldPoint(start.position)))
        }
        switch context.navState {
        case .arrived:
            phase = .done
            return BrainOutput(decision: .done)
        case .failed:
            // Retry — the sim guarantees a route home exists (topology has no dead-end
            // cutting off the hallway itself).
            return BrainOutput(decision: .navigate(.worldPoint(start.position)))
        default:
            return BrainOutput(decision: .navigate(.worldPoint(start.position)))
        }
    }
}
