import Foundation
import CoreGraphics
import UIKit
import RoverNav

public struct NavigationGoalAssessment: Equatable, Sendable {
    public let goal: Vec2
    public let isReachable: Bool
    public let pathDistance: Double

    public init(goal: Vec2, isReachable: Bool, pathDistance: Double) {
        self.goal = goal
        self.isReachable = isReachable
        self.pathDistance = pathDistance
    }
}

/// Motion surface `MissionAgent` drives. A separate protocol from the concrete
/// `NavigationController` (rather than depending on it directly) so the mission loop can be
/// tested without a live ARKit session.
@MainActor
public protocol RoverMotion: AnyObject {
    var state: NavigationController.State { get }
    func navigate(to goal: Vec2)
    func navigate(to goal: Vec2, stoppingAtForwardClearance clearance: Double)
    func rotate(by angle: Double) async
    func rotateForScan(by angle: Double) async
    func assessGoal(_ goal: Vec2) -> NavigationGoalAssessment
    func stopAndWait() async
    func cancel()
}

extension RoverMotion {
    public func navigate(to goal: Vec2, stoppingAtForwardClearance clearance: Double) {
        navigate(to: goal)
    }

    public func rotateForScan(by angle: Double) async {
        await rotate(by: angle)
    }

    public func assessGoal(_ goal: Vec2) -> NavigationGoalAssessment {
        NavigationGoalAssessment(goal: goal, isReachable: true, pathDistance: 0)
    }

    public func stopAndWait() async {
        cancel()
    }
}

extension NavigationController: RoverMotion {}

/// Perception surface `MissionAgent` reads. A separate protocol from `ARSessionManager` +
/// `Detector` so the mission loop can be tested by scripting what's "visible" without a
/// live ARKit session or the bundled CoreML model.
@MainActor
public protocol RoverPerception: AnyObject {
    var pose: Pose2D? { get }
    var latestObservation: PoseObservation? { get }
    /// Monotonic camera-frame sequence, when the perception source can provide one.
    /// `nil` keeps non-camera and test implementations backward compatible.
    var frameSequence: UInt64? { get }
    func detectObjects() -> [PerceivedObject]
    func unproject(normalizedPoint: CGPoint) -> Vec2?
    func capturedFrameJPEG() -> Data?
    /// Resolve a free-text description ("the green chair") to a normalized point in the
    /// current view, or `nil` if nothing matches. Has a default (substring-match)
    /// implementation below; conform your own for open-vocabulary/attribute grounding.
    func groundObject(query: String) -> CGPoint?
    /// Openings into unexplored space (frontier detection over the scene mesh). Default
    /// implementation returns [] for perception sources with no mapping capability.
    func explorationFrontiers() -> [Frontier]
}

extension RoverPerception {
    public var latestObservation: PoseObservation? { nil }
    public var frameSequence: UInt64? { nil }

    /// Default grounding: case-insensitive substring match against `detectObjects()`
    /// labels, picking the highest-confidence match. No attribute/color understanding —
    /// "green chair" matches the same as "chair". Override for anything smarter.
    public func groundObject(query: String) -> CGPoint? {
        let q = query.lowercased()
        return detectObjects()
            .filter { q.contains($0.label.lowercased()) || $0.label.lowercased().contains(q) }
            .max { $0.confidence < $1.confidence }?
            .normalizedPoint
    }

    public func explorationFrontiers() -> [Frontier] { [] }
}

/// Default `RoverPerception`: on-device COCO detection over the live ARKit frame.
@MainActor
public final class ARPerceptionSource: RoverPerception {
    private let ar: ARSessionManager
    private let detector: Detector?
    private let colorAnalyzer = LocalObjectColorAnalyzer()

    public init(ar: ARSessionManager, detector: Detector?) {
        self.ar = ar
        self.detector = detector
    }

    public var pose: Pose2D? { ar.pose }
    public var latestObservation: PoseObservation? { ar.latestObservation }
    public var frameSequence: UInt64? { ar.frameSequence }

    public func detectObjects() -> [PerceivedObject] {
        guard let detector, let buffer = ar.latestPixelBuffer else { return [] }
        return detector.detect(buffer).map { detection in
            PerceivedObject(
                label: detection.label,
                confidence: detection.confidence,
                normalizedPoint: CGPoint(
                    x: detection.boundingBox.midX,
                    y: detection.boundingBox.midY
                ),
                normalizedBoundingBox: detection.boundingBox,
                colorEvidence: colorAnalyzer.analyze(
                    pixelBuffer: buffer,
                    normalizedBoundingBox: detection.boundingBox
                )
            )
        }
    }

    public func unproject(normalizedPoint: CGPoint) -> Vec2? {
        ar.unproject(normalizedPoint: normalizedPoint)
    }

    public func capturedFrameJPEG() -> Data? {
        FrameEncoder.jpeg(ar.latestPixelBuffer)
    }

    public func explorationFrontiers() -> [Frontier] {
        guard let center = ar.pose?.position else { return [] }
        let (map, observed) = CostmapBuilder.buildWithObserved(from: ar.meshAnchors, center: center)
        return FrontierFinder.candidates(costmap: map, observed: observed)
    }
}

/// Voice surface `MissionAgent` drives. A separate protocol from `SpeechOut`/`SpeechIn` so
/// the mission loop can be tested by scripting operator replies without real audio I/O.
@MainActor
public protocol RoverVoice: AnyObject {
    func speak(_ text: String)
    /// Ask a question and wait for a reply, honoring `timeout`. `nil` on timeout or no
    /// usable reply — the caller proceeds best-effort.
    func ask(_ question: String, timeout: TimeInterval) async -> String?
}

/// Battery surface `MissionAgent` reads — optional (nil if the platform doesn't expose
/// one). A separate protocol from `RoverPerception` since it's orthogonal to vision/nav:
/// self-model ("how much runway do I have left") doesn't need ARKit/detector plumbing to
/// fake, and a brain that ignores battery entirely still works with `percent` always nil.
@MainActor
public protocol RoverBattery: AnyObject {
    var percent: Double? { get }
}

/// Default `RoverBattery`: the iPhone's own battery level — the phone is the rover's
/// brain, so its battery is what capability "self-model and calibrated uncertainty"
/// reasons about (the WAVE ROVER chassis itself exposes no battery telemetry today).
@MainActor
public final class DeviceBattery: RoverBattery {
    public init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    public var percent: Double? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Double(level) * 100.0
    }
}

/// Team-mesh surface `MissionAgent` reads/writes — optional (nil for a solo mission). A
/// separate protocol from the others since it's about *other rovers*, not this one's own
/// sensing/motion/speech: capability "collaboration" (shared intent, market allocation,
/// survivor robustness) is the brain's own reasoning over `currentTeamContext()`, using
/// `broadcastClaim` to act on it — `MissionAgent` only relays, same as `RoverBattery`.
@MainActor
public protocol RoverTeamRadio: AnyObject {
    /// Current known team state (rooms + who's claimed/alive), or `nil` if unavailable
    /// this tick (e.g. mesh not yet joined).
    func currentTeamContext() -> TeamContext?
    /// Announce a claim on a room/area to the rest of the team.
    func broadcastClaim(_ roomId: String)
}

/// Default `RoverVoice`: on-device TTS/STT.
@MainActor
public final class SpeechRoverVoice: RoverVoice {
    private let out: SpeechOut
    private let speechIn: SpeechIn?

    public init(out: SpeechOut = SpeechOut(), speechIn: SpeechIn? = nil) {
        self.out = out
        self.speechIn = speechIn
    }

    public func speak(_ text: String) { out.speak(text) }

    public func ask(_ question: String, timeout: TimeInterval) async -> String? {
        out.speak(question)
        guard let speechIn else { return nil }
        return await speechIn.listenOnce(timeout: timeout)
    }
}

/// The mission loop: gather context, ask the current `RoverBrain` for the next action,
/// execute it, and repeat — until the brain says `.stop`/`.done`, or it asks a question
/// that goes unanswered and has nothing left to try.
///
/// There is deliberately no special-cased command grammar here (no "and back" parsing, no
/// place-naming syntax). The operator's words and the rover's `MissionMemory` are just
/// inputs to whichever `RoverBrain` is current; behaviors like returning to a remembered
/// pose emerge from the brain reading that memory, not from code in this class.
@Observable
@MainActor
public final class MissionAgent {
    public enum Phase: Equatable { case idle, thinking, acting, waitingForAnswer }
    private enum VisualTargetScanResult {
        case found(Vec2)
        case notFound
        case cancelled
    }

    private enum ReturnLegOutcome {
        case arrived
        case failed
        case cancelled
    }

    private enum BlockedHeadingRecoveryOutcome: Equatable {
        case completed
        case cancelled
    }

    private enum RoomTraversalOutcome {
        case crossed(DoorwayRouteStep)
        case exhausted(String)
        case cancelled
    }

    public private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            phaseDidChange?(phase)
        }
    }
    public private(set) var memory = MissionMemory()
    /// The mission plan as last written by a brain (see `BrainOutput.updatedPlan`).
    public private(set) var plan: String?
    /// Openings into unexplored space, with stable ids and visited status maintained
    /// across ticks. Visited candidates are kept (they're memory — "already checked, it
    /// was a hallway"); unexplored ones that stop being frontiers (e.g. seen through
    /// without visiting) are dropped so the brain isn't offered stale openings.
    public private(set) var explorationCandidates: [ExplorationCandidate] = []

    private let motion: RoverMotion
    private let perception: RoverPerception
    private let voice: RoverVoice
    private let battery: RoverBattery?
    private let teamRadio: RoverTeamRadio?
    private let roomTopology: RoomTopologyManaging?
    private let doorwayEvidenceProvider: DoorwayEvidenceProviding?
    private let roomTransitionPollInterval: TimeInterval
    private let askTimeout: TimeInterval
    private let brainDecisionTimeout: TimeInterval
    private let blockedHeadingRecoveryAngle: Double
    private let blockedHeadingRecoveryTimeout: TimeInterval
    private let visualTargetConfidenceThreshold: Float
    private let visualTargetScanAngle: Double
    private let visualTargetScanDelay: TimeInterval
    private let maxVisualTargetScanSteps: Int
    private let phaseDidChange: ((Phase) -> Void)?
    private let roomTransitionStateDidChange: ((RoomTransitionDebugState) -> Void)?
    private let roomTransitionTelemetry: RoomTopologyTelemetrySink
    private let commandStatusDidChange: ((MissionCommandStatus) -> Void)?
    private let currentBrain: () -> RoverBrain?
    private let brainErrorLogger: (Error, MissionContext) -> Void
    private let missionTelemetry: MissionTelemetrySink

    private var roomTransitionDebugState: RoomTransitionDebugState = .idle
    private var roomTraversalExhaustionFields: [String: String] = [:]
    private var lastAnswerWasInconclusive = false
    private var nextCandidateNumber = 1
    private var isHandlingMission = false
    private var missionGeneration = 0
    private var nextCommandID: MissionCommandID = 0
    private var commandByMissionID: [Int: (id: MissionCommandID, text: String)] = [:]
    private var terminalCommandIDs: Set<MissionCommandID> = []
    /// Ring buffer of "action → outcome" lines fed to the brain as `recentActions` (see
    /// `makeContext`) so it can notice it's repeating itself — persists across `handle()`
    /// calls within one mission agent, same as `memory`, so a multi-turn mission ("search,
    /// then go back to the ladder") keeps continuity.
    private var recentActionLines: [String] = []
    private let recentActionsLimit = 8
    private var lastDecision: RoverDecision?
    /// Consecutive ticks where the decision matched the previous one, pose barely moved,
    /// and nothing new was remembered — the signal a scripted loop (not the brain) would
    /// catch instantly but an LLM given only the current frame cannot.
    private var consecutiveNoOpTicks = 0
    /// A frontier within this distance of a known candidate is the same opening.
    private let candidateMatchRadius = 1.0
    /// Getting this close to a candidate marks it visited.
    private let visitedRadius = 1.0

    /// Hard cap on think-ticks per utterance so a brain that never emits `.stop`/`.done`
    /// can't loop forever (matters most for scripted/fake brains in tests).
    private let maxTicksPerUtterance: Int

    public init(motion: RoverMotion,
                perception: RoverPerception,
                voice: RoverVoice,
                battery: RoverBattery? = nil,
                teamRadio: RoverTeamRadio? = nil,
                askTimeout: TimeInterval = 8,
                brainDecisionTimeout: TimeInterval = 12,
                maxTicksPerUtterance: Int = 25,
                blockedHeadingRecoveryAngle: Double = .pi / 6,
                blockedHeadingRecoveryTimeout: TimeInterval = RoverConfig.blockedHeadingRecoveryTimeout,
                visualTargetConfidenceThreshold: Float = 0.90,
                visualTargetScanAngle: Double = .pi / 6,
                visualTargetScanDelay: TimeInterval = 1,
                maxVisualTargetScanSteps: Int = 12,
                roomTopology: RoomTopologyManaging? = nil,
                doorwayEvidenceProvider: DoorwayEvidenceProviding? = nil,
                roomTransitionPollInterval: TimeInterval = 0.05,
                phaseDidChange: ((Phase) -> Void)? = nil,
                roomTransitionStateDidChange: ((RoomTransitionDebugState) -> Void)? = nil,
                roomTransitionTelemetry: @escaping RoomTopologyTelemetrySink = { event, fields in
                    RuntimeFileLog.append(event, fields: fields)
                },
                commandStatusDidChange: ((MissionCommandStatus) -> Void)? = nil,
                brainErrorLogger: @escaping (Error, MissionContext) -> Void = { error, context in
                    BrainErrorFileLog.append(error: error, context: context)
                },
                missionTelemetry: @escaping MissionTelemetrySink = { event, fields in
                    RuntimeFileLog.append(event, fields: fields)
                },
                currentBrain: @escaping () -> RoverBrain?) {
        self.motion = motion
        self.perception = perception
        self.voice = voice
        self.battery = battery
        self.teamRadio = teamRadio
        self.roomTopology = roomTopology
        self.doorwayEvidenceProvider = doorwayEvidenceProvider
        self.roomTransitionPollInterval = roomTransitionPollInterval
        self.askTimeout = askTimeout
        self.brainDecisionTimeout = brainDecisionTimeout
        self.maxTicksPerUtterance = maxTicksPerUtterance
        self.blockedHeadingRecoveryAngle = blockedHeadingRecoveryAngle
        self.blockedHeadingRecoveryTimeout = blockedHeadingRecoveryTimeout
        self.visualTargetConfidenceThreshold = visualTargetConfidenceThreshold
        self.visualTargetScanAngle = visualTargetScanAngle
        self.visualTargetScanDelay = visualTargetScanDelay
        self.maxVisualTargetScanSteps = maxVisualTargetScanSteps
        self.phaseDidChange = phaseDidChange
        self.roomTransitionStateDidChange = roomTransitionStateDidChange
        self.roomTransitionTelemetry = roomTransitionTelemetry
        self.commandStatusDidChange = commandStatusDidChange
        self.brainErrorLogger = brainErrorLogger
        self.missionTelemetry = missionTelemetry
        self.currentBrain = currentBrain
    }

    /// Handle one operator utterance end-to-end.
    public func handle(_ utterance: String) async {
        let trimmedUtterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUtterance.isEmpty else {
            phase = .idle
            RuntimeFileLog.append("voice_command_ignored", fields: ["reason": "blank_utterance"])
            return
        }

        nextCommandID += 1
        let commandID = nextCommandID
        commandStatusDidChange?(.recognized(id: commandID, command: trimmedUtterance))

        RuntimeFileLog.append("voice_command_received", fields: ["utterance": trimmedUtterance])
        if isEmergencyStopUtterance(trimmedUtterance) {
            commandStatusDidChange?(.working(id: commandID, command: trimmedUtterance))
            missionGeneration += 1
            isHandlingMission = false
            phase = .acting
            await motion.stopAndWait()
            roomTopology?.abandonTransition()
            publishRoomTransitionState(.idle)
            phase = .idle
            RuntimeFileLog.append("voice_command_stop", fields: ["utterance": trimmedUtterance])
            publishTerminal(.cancelled(id: commandID, command: trimmedUtterance))
            return
        }

        guard !isHandlingMission else {
            voice.speak("I'm still working on the previous command. Say stop if you want me to cancel it.")
            RuntimeFileLog.append("voice_command_busy", fields: ["utterance": trimmedUtterance])
            publishTerminal(
                .failed(
                    id: commandID,
                    command: trimmedUtterance,
                    message: "I’m still working on the previous command."
                )
            )
            return
        }
        if motion.state != .idle {
            RuntimeFileLog.append("mission_motion_state_reset", fields: [
                "previous_state": motion.state.description
            ])
            await motion.stopAndWait()
        }
        guard let pose = perception.pose else {
            voice.speak("I don't have my bearings yet — give me a moment to look around.")
            RuntimeFileLog.append("voice_command_rejected", fields: [
                "utterance": trimmedUtterance,
                "reason": "missing_pose"
            ])
            publishTerminal(
                .failed(id: commandID, command: trimmedUtterance, message: "I don’t have my bearings yet.")
            )
            return
        }

        isHandlingMission = true
        missionGeneration += 1
        let missionID = missionGeneration
        commandByMissionID[missionID] = (commandID, trimmedUtterance)
        commandStatusDidChange?(.working(id: commandID, command: trimmedUtterance))
        defer {
            if missionGeneration == missionID {
                isHandlingMission = false
            }
        }

        plan = nil
        recentActionLines.removeAll(keepingCapacity: true)
        lastDecision = nil
        consecutiveNoOpTicks = 0
        memory.beginMission(utterance: trimmedUtterance, at: pose)
        lastAnswerWasInconclusive = false
        RuntimeFileLog.append("mission_started", fields: [
            "mission": "\(missionID)",
            "start_x": String(format: "%.2f", pose.position.x),
            "start_y": String(format: "%.2f", pose.position.y),
            "return_requested": Self.hasReturnIntent(trimmedUtterance) ? "true" : "false"
        ])
        publishRoomTransitionState(.idle)
        if RoomTransitionIntent.matches(trimmedUtterance) {
            await runRoomTransitionMission(missionID: missionID)
        } else {
            await runLoop(firstUtterance: trimmedUtterance, missionID: missionID)
        }
        if !terminalCommandIDs.contains(commandID) {
            if !isCurrentMission(missionID) || Task.isCancelled {
                publishTerminal(.cancelled(id: commandID, command: trimmedUtterance))
            } else if case .failed(let reason) = motion.state {
                publishTerminal(
                    .failed(id: commandID, command: trimmedUtterance, message: reason)
                )
            } else {
                publishTerminal(
                    .succeeded(
                        id: commandID,
                        command: trimmedUtterance,
                        message: "Command completed."
                    )
                )
            }
        }
        commandByMissionID[missionID] = nil
    }

    private func publishTerminal(_ status: MissionCommandStatus) {
        guard status.isTerminal, terminalCommandIDs.insert(status.id).inserted else { return }
        commandStatusDidChange?(status)
    }

    private func publishMissionTerminal(
        _ makeStatus: (MissionCommandID, String) -> MissionCommandStatus,
        missionID: Int
    ) {
        guard let command = commandByMissionID[missionID] else { return }
        publishTerminal(makeStatus(command.id, command.text))
    }

    private func publishRoomTransitionState(_ state: RoomTransitionDebugState) {
        guard state != roomTransitionDebugState else { return }
        roomTransitionDebugState = state
        roomTransitionStateDidChange?(state)
    }

    private func runRoomTransitionMission(missionID: Int) async {
        let sessionGeneration = roomTopology?.snapshot.sessionGeneration
        switch await traverseNextDoorway(missionID: missionID) {
        case .crossed(let step):
            let candidateID = roomTopology?.snapshot.doorways.first {
                $0.id == step.doorwayID
            }?.candidateID
            roomTransitionTelemetry("room_transition_mission_completed", [
                "candidate_id": candidateID?.rawValue ?? "unknown",
                "doorway_id": step.doorwayID.rawValue,
                "room_id": step.toRoomID.rawValue,
                "mission_id": String(missionID),
                "session_generation": sessionGeneration.map(String.init) ?? "none",
            ])
            publishRoomTransitionState(.completed(
                doorwayID: step.doorwayID,
                roomID: step.toRoomID
            ))
            publishMissionTerminal(
                { .succeeded(id: $0, command: $1, message: "Entered another room.") },
                missionID: missionID
            )
            phase = .idle
        case .exhausted(let reason):
            let fields = roomTraversalExhaustionFields
            roomTraversalExhaustionFields = [:]
            if reason == "search_exhausted" || reason == "missing_topology" {
                finishRoomTransitionExhausted(
                    missionID: missionID,
                    sessionGeneration: sessionGeneration,
                    fields: fields
                )
            } else {
                let message = reason == "missing_pose"
                    ? "I don’t have my bearings yet."
                    : reason
                finishRoomTransitionFailed(
                    reason,
                    message: message,
                    missionID: missionID,
                    sessionGeneration: sessionGeneration,
                    fields: fields
                )
            }
        case .cancelled:
            phase = .idle
        }
    }

    private func traverseNextDoorway(
        preferredDoorwayID: DoorwayID? = nil,
        excluding initiallyExcludedCandidateIDs: Set<DoorwayCandidateID> = [],
        missionID: Int
    ) async -> RoomTraversalOutcome {
        guard let roomTopology else {
            return .exhausted("missing_topology")
        }

        let totalScanSteps = 12
        let sessionGeneration = roomTopology.snapshot.sessionGeneration
        let missionFields: [String: String] = [
            "mission_id": String(missionID),
            "session_generation": sessionGeneration.map(String.init) ?? "none",
        ]
        var excludedCandidateIDs = initiallyExcludedCandidateIDs
        var remainingScanSteps = totalScanSteps
        var candidateAttempts = 0
        roomTraversalExhaustionFields = [:]

        while isCurrentMission(missionID), !Task.isCancelled, candidateAttempts < 3 {
            guard roomTopology.snapshot.sessionGeneration == sessionGeneration else {
                await motion.stopAndWait()
                roomTopology.abandonTransition()
                return .exhausted("session_generation_changed")
            }
            let scanStep = totalScanSteps - remainingScanSteps
            let frontiers = perception.explorationFrontiers()
            guard let referencePose = perception.pose else {
                return .exhausted("missing_pose")
            }
            let candidates = roomTopology.refreshCandidates(
                from: frontiers,
                referencePose: referencePose
            )
            roomTransitionTelemetry("room_transition_scan_step", missionFields.merging([
                "scan_step": String(scanStep),
                "total_scan_steps": String(totalScanSteps),
                "frontier_count": String(frontiers.count),
                "candidate_count": String(candidates.count),
                "excluded_candidate_count": String(excludedCandidateIDs.count),
            ]) { _, new in new })
            publishRoomTransitionState(.scanning(
                step: scanStep,
                total: totalScanSteps,
                openingCount: frontiers.count,
                candidateCount: candidates.count
            ))
            let assessments = candidates.map { candidate in
                let goal = candidate.beyondPlaneGoal()
                let assessment = motion.assessGoal(goal)
                return DoorwayCandidateAssessment(
                    candidateID: candidate.id,
                    isReachable: assessment.isReachable,
                    beyondPlaneGoal: assessment.goal,
                    pathDistance: assessment.pathDistance
                )
            }
            var visualBoosts: [DoorwayCandidateID: Double] = [:]
            if let doorwayEvidenceProvider,
               let frame = perception.capturedFrameJPEG(),
               !candidates.isEmpty {
                visualBoosts = await doorwayEvidenceProvider.boostValues(
                    forFrame: frame,
                    candidates: candidates
                )
            }
            let ranked = roomTopology.rankedCandidates(
                assessments: assessments,
                visualBoosts: visualBoosts,
                excluding: excludedCandidateIDs
            )
            for (rank, item) in ranked.enumerated() {
                roomTransitionTelemetry("doorway_candidate_assessed", missionFields.merging([
                    "scan_step": String(scanStep),
                    "candidate_id": item.candidate.id.rawValue,
                    "goal_x": String(format: "%.2f", item.assessment.beyondPlaneGoal.x),
                    "goal_y": String(format: "%.2f", item.assessment.beyondPlaneGoal.y),
                    "reachable": String(item.assessment.isReachable),
                    "path_distance": String(format: "%.2f", item.assessment.pathDistance),
                    "rank": String(rank + 1),
                ]) { _, new in new })
            }

            let selected: RankedDoorwayCandidate?
            if let preferredDoorwayID {
                selected = ranked.first {
                    $0.assessment.isReachable
                        && $0.candidate.doorwayID == preferredDoorwayID
                }
            } else {
                selected = ranked.first { $0.assessment.isReachable }
            }
            if selected == nil {
                for item in ranked where !item.assessment.isReachable {
                    excludedCandidateIDs.insert(item.candidate.id)
                    roomTransitionTelemetry("doorway_candidate_unreachable", missionFields.merging([
                        "scan_step": String(scanStep),
                        "candidate_id": item.candidate.id.rawValue,
                    ]) { _, new in new })
                    publishRoomTransitionState(.candidateFound(
                        id: item.candidate.id,
                        reachable: false
                    ))
                    publishRoomTransitionState(.unreachable(id: item.candidate.id))
                }
            }
            guard var selected else {
                let reason: String
                if frontiers.isEmpty {
                    reason = "no_openings"
                } else if candidates.isEmpty {
                    reason = "no_admitted_candidates"
                } else if !ranked.isEmpty {
                    reason = preferredDoorwayID == nil
                        ? "no_reachable_candidates"
                        : "preferred_doorway_unavailable"
                } else {
                    reason = "no_ranked_candidates"
                }
                roomTransitionTelemetry("room_transition_scan_continued", missionFields.merging([
                    "scan_step": String(scanStep),
                    "reason": reason,
                    "remaining_scan_steps": String(remainingScanSteps),
                ]) { _, new in new })
                guard remainingScanSteps > 0 else { break }
                remainingScanSteps -= 1
                phase = .acting
                await motion.rotateForScan(by: .pi / 6)
                if case .failed(let reason) = motion.state {
                    roomTraversalExhaustionFields = ["scan_step": String(scanStep)]
                    return .exhausted(reason)
                }
                continue
            }

            candidateAttempts += 1
            excludedCandidateIDs.insert(selected.candidate.id)
            roomTransitionTelemetry("doorway_candidate_selected", missionFields.merging([
                "scan_step": String(scanStep),
                "candidate_id": selected.candidate.id.rawValue,
                "reachable": "true",
                "goal_x": String(format: "%.2f", selected.assessment.beyondPlaneGoal.x),
                "goal_y": String(format: "%.2f", selected.assessment.beyondPlaneGoal.y),
            ]) { _, new in new })
            publishRoomTransitionState(.candidateFound(
                id: selected.candidate.id,
                reachable: true
            ))
            guard let approachPose = perception.pose else {
                roomTraversalExhaustionFields = [
                    "candidate_id": selected.candidate.id.rawValue,
                ]
                return .exhausted("missing_pose")
            }
            var startResult = roomTopology.beginTransition(
                candidateID: selected.candidate.id,
                approachPose: approachPose
            )
            if case .correctedOrientation(let correctedCandidate) = startResult {
                let correctedGoal = correctedCandidate.beyondPlaneGoal()
                let correctedAssessment = motion.assessGoal(correctedGoal)
                roomTransitionTelemetry("room_transition_goal_reassessed", missionFields.merging([
                    "candidate_id": correctedCandidate.id.rawValue,
                    "goal_x": String(format: "%.2f", correctedGoal.x),
                    "goal_y": String(format: "%.2f", correctedGoal.y),
                    "reachable": String(correctedAssessment.isReachable),
                ]) { _, new in new })
                guard correctedAssessment.isReachable else {
                    publishRoomTransitionFailure(
                        "corrected_goal_unreachable",
                        missionID: missionID,
                        sessionGeneration: sessionGeneration,
                        fields: ["candidate_id": correctedCandidate.id.rawValue]
                    )
                    continue
                }
                selected = RankedDoorwayCandidate(
                    candidate: correctedCandidate,
                    assessment: DoorwayCandidateAssessment(
                        candidateID: correctedCandidate.id,
                        isReachable: true,
                        beyondPlaneGoal: correctedAssessment.goal,
                        pathDistance: correctedAssessment.pathDistance
                    ),
                    visualBoost: selected.visualBoost
                )
                startResult = roomTopology.beginTransition(
                    candidateID: correctedCandidate.id,
                    approachPose: approachPose
                )
            }
            guard startResult == .started else {
                let reason: String
                if case .rejected(let rejection) = startResult {
                    reason = rejection.rawValue
                } else {
                    reason = "orientation_changed_repeatedly"
                }
                publishRoomTransitionFailure(
                    reason,
                    missionID: missionID,
                    sessionGeneration: sessionGeneration,
                    fields: ["candidate_id": selected.candidate.id.rawValue]
                )
                continue
            }

            roomTransitionTelemetry("room_transition_approach_started", missionFields.merging([
                "candidate_id": selected.candidate.id.rawValue,
                "goal_x": String(format: "%.2f", selected.assessment.beyondPlaneGoal.x),
                "goal_y": String(format: "%.2f", selected.assessment.beyondPlaneGoal.y),
            ]) { _, new in new })
            publishRoomTransitionState(.approaching(id: selected.candidate.id))
            phase = .acting
            motion.navigate(to: selected.assessment.beyondPlaneGoal)
            var lastFrameSequence: UInt64?
            var trackingRecoveryDeadline: Date?
            while isCurrentMission(missionID), !Task.isCancelled {
                guard roomTopology.snapshot.sessionGeneration == sessionGeneration else {
                    await motion.stopAndWait()
                    roomTopology.abandonTransition()
                    return .exhausted("session_generation_changed")
                }
                if let observation = perception.latestObservation,
                   observation.sessionGeneration == roomTopology.snapshot.sessionGeneration,
                   lastFrameSequence.map({ observation.frameSequence > $0 }) ?? true {
                    lastFrameSequence = observation.frameSequence
                    if observation.trackingQuality != .normal {
                        if trackingRecoveryDeadline == nil {
                            await motion.stopAndWait()
                            trackingRecoveryDeadline = Date().addingTimeInterval(
                                RoverConfig.scanFrameFreshnessTimeout
                            )
                        }
                        continue
                    }
                    if trackingRecoveryDeadline != nil {
                        trackingRecoveryDeadline = nil
                        publishRoomTransitionState(.approaching(id: selected.candidate.id))
                        motion.navigate(to: selected.assessment.beyondPlaneGoal)
                    }
                    if roomTopology.observeTransition(observation.transitionObservation)
                        == .readyForConfirmation {
                        roomTransitionTelemetry(
                            "room_transition_crossing_confirmation_started",
                            missionFields.merging([
                                "candidate_id": selected.candidate.id.rawValue,
                                "frame_sequence": String(observation.frameSequence),
                            ]) { _, new in new }
                        )
                        publishRoomTransitionState(.confirmingCrossing(id: selected.candidate.id))
                        await motion.stopAndWait()
                        guard isCurrentMission(missionID), !Task.isCancelled else {
                            roomTopology.abandonTransition()
                            publishRoomTransitionState(.idle)
                            return .cancelled
                        }
                        if let roomID = roomTopology.confirmTransition(),
                           let doorwayID = roomTopology.snapshot.doorways.first(where: {
                               $0.candidateID == selected.candidate.id
                           })?.id {
                            guard let fromRoomID = roomTopology.snapshot.doorways.first(where: {
                                $0.id == doorwayID
                            }).flatMap({ doorway in
                                doorway.firstRoomID == roomID
                                    ? doorway.secondRoomID
                                    : doorway.firstRoomID
                            }) else {
                                publishRoomTransitionFailure(
                                    "crossing_route_step_failed",
                                    missionID: missionID,
                                    sessionGeneration: sessionGeneration,
                                    fields: ["candidate_id": selected.candidate.id.rawValue]
                                )
                                break
                            }
                            return .crossed(
                                DoorwayRouteStep(
                                    doorwayID: doorwayID,
                                    fromRoomID: fromRoomID,
                                    toRoomID: roomID
                                )
                            )
                        }
                        publishRoomTransitionFailure(
                            "crossing_confirmation_failed",
                            missionID: missionID,
                            sessionGeneration: sessionGeneration,
                            fields: ["candidate_id": selected.candidate.id.rawValue]
                        )
                        break
                    }
                }

                if let trackingRecoveryDeadline {
                    if Date() >= trackingRecoveryDeadline {
                        roomTopology.rejectTransition(reason: "tracking_unavailable")
                        publishRoomTransitionFailure(
                            "tracking_unavailable",
                            missionID: missionID,
                            sessionGeneration: sessionGeneration,
                            fields: ["candidate_id": selected.candidate.id.rawValue]
                        )
                        break
                    }
                    if roomTransitionPollInterval > 0 {
                        try? await Task.sleep(for: .seconds(roomTransitionPollInterval))
                    } else {
                        await Task.yield()
                    }
                    continue
                }
                if case .failed(let reason) = motion.state {
                    await motion.stopAndWait()
                    roomTopology.rejectTransition(reason: reason)
                    publishRoomTransitionFailure(
                        reason,
                        missionID: missionID,
                        sessionGeneration: sessionGeneration,
                        fields: ["candidate_id": selected.candidate.id.rawValue]
                    )
                    break
                }
                if motion.state == .arrived || motion.state == .idle {
                    roomTopology.rejectTransition(reason: "crossing_not_confirmed")
                    publishRoomTransitionFailure(
                        "crossing_not_confirmed",
                        missionID: missionID,
                        sessionGeneration: sessionGeneration,
                        fields: ["candidate_id": selected.candidate.id.rawValue]
                    )
                    break
                }
                if roomTransitionPollInterval > 0 {
                    try? await Task.sleep(for: .seconds(roomTransitionPollInterval))
                } else {
                    await Task.yield()
                }
            }
        }

        if !isCurrentMission(missionID) || Task.isCancelled {
            motion.cancel()
            roomTopology.abandonTransition()
            publishRoomTransitionState(.idle)
            phase = .idle
            return .cancelled
        }
        await motion.stopAndWait()
        roomTopology.abandonTransition()
        roomTraversalExhaustionFields = [
            "candidate_attempts": String(candidateAttempts),
            "scan_steps_used": String(totalScanSteps - remainingScanSteps),
        ]
        return .exhausted("search_exhausted")
    }

    private func publishRoomTransitionFailure(
        _ reason: String,
        missionID: Int,
        sessionGeneration: UInt64? = nil,
        fields: [String: String] = [:]
    ) {
        publishRoomTransitionState(.failed(reason: reason))
        roomTransitionTelemetry("room_transition_failed", fields.merging([
            "reason": reason,
            "mission_id": String(missionID),
            "session_generation": sessionGeneration.map(String.init) ?? "none",
        ]) { _, new in new })
    }

    private func finishRoomTransitionFailed(
        _ reason: String,
        message: String,
        missionID: Int,
        sessionGeneration: UInt64? = nil,
        fields: [String: String] = [:]
    ) {
        publishRoomTransitionFailure(
            reason,
            missionID: missionID,
            sessionGeneration: sessionGeneration,
            fields: fields
        )
        publishMissionTerminal(
            { .failed(id: $0, command: $1, message: message) },
            missionID: missionID
        )
        phase = .idle
    }

    private func finishRoomTransitionExhausted(
        missionID: Int,
        sessionGeneration: UInt64? = nil,
        fields: [String: String] = [:]
    ) {
        publishRoomTransitionState(.exhausted)
        roomTransitionTelemetry("room_transition_exhausted", fields.merging([
            "mission_id": String(missionID),
            "session_generation": sessionGeneration.map(String.init) ?? "none",
        ]) { _, new in new })
        voice.speak("I couldn’t find a safe route into another room.")
        publishMissionTerminal(
            { .failed(id: $0, command: $1, message: "I couldn’t find a safe route into another room.") },
            missionID: missionID
        )
        phase = .idle
    }

    // MARK: - Loop

    private func runLoop(firstUtterance: String?, missionID: Int) async {
        var nextUtterance = firstUtterance
        let missionUtterance = firstUtterance ?? ""
        let missionVisualIntent = OfflineObjectMissionIntentParser.parse(missionUtterance)
        var lockedVisualQuery = missionVisualIntent?.objectQuery
        var visualTargetScanSteps = 0
        if let missionVisualIntent {
            RuntimeFileLog.append("mission_target_locked", fields: [
                "mission": "\(missionID)",
                "target": missionVisualIntent.objectQuery,
                "target_label": missionVisualIntent.targetLabel,
                "requested_colors": Self.requestedColorsDescription(missionVisualIntent.requestedColors),
                "source": "operator_command",
                "threshold": String(format: "%.2f", visualTargetConfidenceThreshold)
            ])
        }
        // Distinguishes "the brain itself failed" (missing/timed out/errored) from
        // genuinely exhausting every tick without the brain ever stopping — only the
        // latter should get the "used up my time" wrap-up; the brain-failure paths
        // already spoke their own message and shouldn't pile a second one on top.
        var brainFailed = false
        var hasUsableBrainOutput = false

        for tick in 0..<maxTicksPerUtterance {
            guard !missionCancellationDetected(missionID) else {
                phase = .idle
                RuntimeFileLog.append("mission_cancelled", fields: ["mission": "\(missionID)"])
                return
            }
            guard let brain = currentBrain() else {
                RuntimeFileLog.append("mission_failed", fields: [
                    "mission": "\(missionID)",
                    "reason": "missing_brain"
                ])
                if !hasUsableBrainOutput {
                    await attemptOfflineObjectFallback(
                        utterance: missionUtterance,
                        missionID: missionID,
                        brainFailureReason: "missing_brain",
                        failureMessage: "Sorry, I can’t think right now."
                    )
                    return
                }
                voice.speak("Sorry, I can't think right now.")
                publishMissionTerminal(
                    { .failed(id: $0, command: $1, message: "Sorry, I can’t think right now.") },
                    missionID: missionID
                )
                RuntimeFileLog.append("mission_offline_fallback_skipped", fields: [
                    "mission": "\(missionID)",
                    "reason": "brain_output_already_produced"
                ])
                brainFailed = true
                break
            }

            phase = .thinking
            let rememberedCountBefore = memory.rememberedObjects.count
            updateWorldModel()
            let newObjects = memory.rememberedObjects.count - rememberedCountBefore
            let ctx = makeContext(utterance: nextUtterance, missionID: missionID)
            RuntimeFileLog.append("mission_thinking", fields: [
                "mission": "\(missionID)",
                "tick": "\(tick)",
                "nav": ctx.navState.description,
                "visible": "\(ctx.visibleObjects.count)",
                "objects": visibleObjectsLogSummary(ctx.visibleObjects),
                "openings": "\(ctx.explorationCandidates.count)"
            ])
            nextUtterance = nil

            let output: BrainOutput
            do {
                output = try await nextBrainAction(brain, context: ctx)
            } catch let error as CancellationError {
                if missionCancellationDetected(missionID) {
                    cancelActiveMotion(missionID: missionID, reason: "brain_decision_cancelled")
                    return
                }
                brainErrorLogger(error, ctx)
                RuntimeFileLog.append("mission_brain_error", fields: [
                    "mission": "\(missionID)",
                    "error": error.localizedDescription
                ])
                if !hasUsableBrainOutput {
                    await attemptOfflineObjectFallback(
                        utterance: missionUtterance,
                        missionID: missionID,
                        brainFailureReason: "brain_cancellation_error",
                        failureMessage: "Sorry, I’m having trouble thinking right now."
                    )
                    return
                }
                voice.speak("Sorry, I'm having trouble thinking right now.")
                publishMissionTerminal(
                    { .failed(id: $0, command: $1, message: "Sorry, I’m having trouble thinking right now.") },
                    missionID: missionID
                )
                RuntimeFileLog.append("mission_offline_fallback_skipped", fields: [
                    "mission": "\(missionID)",
                    "reason": "brain_output_already_produced"
                ])
                brainFailed = true
                break
            } catch is BrainDecisionTimeoutError {
                guard isCurrentMission(missionID) else {
                    phase = .idle
                    RuntimeFileLog.append("mission_cancelled", fields: ["mission": "\(missionID)"])
                    return
                }
                RuntimeFileLog.append("mission_brain_timeout", fields: [
                    "mission": "\(missionID)",
                    "timeout": String(format: "%.2f", brainDecisionTimeout)
                ])
                if !hasUsableBrainOutput {
                    await attemptOfflineObjectFallback(
                        utterance: missionUtterance,
                        missionID: missionID,
                        brainFailureReason: "brain_timeout",
                        failureMessage: "Sorry, I’m having trouble thinking right now."
                    )
                    return
                }
                voice.speak("Sorry, I'm having trouble thinking right now.")
                publishMissionTerminal(
                    { .failed(id: $0, command: $1, message: "Sorry, I’m having trouble thinking right now.") },
                    missionID: missionID
                )
                RuntimeFileLog.append("mission_offline_fallback_skipped", fields: [
                    "mission": "\(missionID)",
                    "reason": "brain_output_already_produced"
                ])
                brainFailed = true
                break
            } catch {
                guard isCurrentMission(missionID) else {
                    phase = .idle
                    RuntimeFileLog.append("mission_cancelled", fields: ["mission": "\(missionID)"])
                    return
                }
                brainErrorLogger(error, ctx)
                RuntimeFileLog.append("mission_brain_error", fields: [
                    "mission": "\(missionID)",
                    "error": error.localizedDescription
                ])
                if !hasUsableBrainOutput {
                    await attemptOfflineObjectFallback(
                        utterance: missionUtterance,
                        missionID: missionID,
                        brainFailureReason: "brain_error",
                        failureMessage: "Sorry, I’m having trouble thinking right now."
                    )
                    return
                }
                voice.speak("Sorry, I'm having trouble thinking right now.")
                publishMissionTerminal(
                    { .failed(id: $0, command: $1, message: "Sorry, I’m having trouble thinking right now.") },
                    missionID: missionID
                )
                RuntimeFileLog.append("mission_offline_fallback_skipped", fields: [
                    "mission": "\(missionID)",
                    "reason": "brain_output_already_produced"
                ])
                brainFailed = true
                break
            }
            guard !missionCancellationDetected(missionID) else {
                cancelActiveMotion(missionID: missionID, reason: "cancelled_after_brain_decision")
                return
            }
            hasUsableBrainOutput = true
            if let updated = output.updatedPlan, !updated.isEmpty {
                plan = updated
                RuntimeFileLog.append("mission_plan_updated", fields: [
                    "mission": "\(missionID)",
                    "plan": updated
                ])
            }
            RuntimeFileLog.append("mission_decision", fields: [
                "mission": "\(missionID)",
                "tick": "\(tick)",
                "decision": decisionDescription(output.decision)
            ])

            phase = .acting
            let decision = output.decision
            let poseBefore = perception.pose?.position
            var outcome = ""

            switch decision {
            case .navigate(let target):
                let effectiveTarget = effectiveNavigationTarget(target,
                                                                lockedVisualQuery: &lockedVisualQuery,
                                                                missionID: missionID)
                guard let goal = resolve(effectiveTarget, missionID: missionID) else {
                    switch await scanForUnresolvedVisualTarget(effectiveTarget,
                                                               missionID: missionID,
                                                               scanSteps: &visualTargetScanSteps) {
                    case .found(let scannedGoal):
                        visualTargetScanSteps = 0
                        navigate(to: scannedGoal, for: effectiveTarget)
                        await waitForMotionToSettle()
                        guard isCurrentMission(missionID) else {
                            phase = .idle
                            RuntimeFileLog.append("mission_cancelled", fields: ["mission": "\(missionID)"])
                            return
                        }
                        if await recoverVisualNavigation(effectiveTarget,
                                                         missionID: missionID,
                                                         scanSteps: &visualTargetScanSteps,
                                                         missionUtterance: missionUtterance) {
                            return
                        }
                        if await recoverOrStopMissionIfMotionFailed(missionID: missionID,
                                                                    recoverFromBlockedHeading: true) { return }
                        if await completeReturnLegIfNeeded(after: effectiveTarget,
                                                           missionID: missionID,
                                                           missionUtterance: missionUtterance,
                                                           lockedVisualQuery: &lockedVisualQuery) {
                            return
                        }
                        if finishMissionIfVisualTargetArrived(effectiveTarget,
                                                              missionID: missionID,
                                                              missionUtterance: missionUtterance) {
                            return
                        }
                        outcome = describeMotionOutcome(label: "navigate", poseBefore: poseBefore)
                        if recordTick(decision: decision,
                                      poseBefore: poseBefore,
                                      newObjects: newObjects,
                                      outcome: outcome) {
                            phase = .idle
                            return
                        }
                        continue
                    case .cancelled:
                        phase = .idle
                        RuntimeFileLog.append("mission_cancelled", fields: ["mission": "\(missionID)"])
                        return
                    case .notFound:
                        updateWorldModel()
                        if let candidate = nextUnexploredCandidate() {
                            RuntimeFileLog.append("mission_target_frontier_selected", fields: [
                                "mission": "\(missionID)",
                                "target": lockedVisualQuery ?? missionUtterance,
                                "candidate": candidate.id,
                                "width": String(format: "%.2f", candidate.widthMeters),
                                "goal_x": String(format: "%.2f", candidate.worldPoint.x),
                                "goal_y": String(format: "%.2f", candidate.worldPoint.y),
                            ])
                            visualTargetScanSteps = 0
                            motion.navigate(to: candidate.worldPoint)
                            await waitForMotionToSettle()
                            let reachedCandidate = motion.state == .arrived
                            if await recoverOrStopMissionIfMotionFailed(
                                missionID: missionID,
                                recoverFromBlockedHeading: true,
                                blockedCandidateId: candidate.id
                            ) {
                                return
                            }
                            if reachedCandidate {
                                markExplorationCandidateVisited(
                                    candidate.id,
                                    reason: "searched frontier for \(lockedVisualQuery ?? missionUtterance)",
                                    event: "mission_exploration_candidate_visited"
                                )
                            }
                            outcome = describeMotionOutcome(
                                label: "search(\(candidate.id))",
                                poseBefore: poseBefore
                            )
                            if recordTick(decision: decision,
                                          poseBefore: poseBefore,
                                          newObjects: newObjects,
                                          outcome: outcome) {
                                phase = .idle
                                return
                            }
                            continue
                        }
                    }
                    guard isCurrentMission(missionID) else {
                        phase = .idle
                        RuntimeFileLog.append("mission_cancelled", fields: ["mission": "\(missionID)"])
                        return
                    }
                    voice.speak("I couldn't quite figure out where that is.")
                    if recordTick(decision: decision, poseBefore: poseBefore, newObjects: newObjects,
                                   outcome: "navigate → couldn't resolve target") {
                        phase = .idle
                        return
                    }
                    continue
                }
                visualTargetScanSteps = 0
                navigate(to: goal, for: effectiveTarget)
                await waitForMotionToSettle()
                if await recoverVisualNavigation(effectiveTarget,
                                                  missionID: missionID,
                                                  scanSteps: &visualTargetScanSteps,
                                                  missionUtterance: missionUtterance) {
                    return
                }
                if await recoverOrStopMissionIfMotionFailed(missionID: missionID,
                                                            recoverFromBlockedHeading: true) { return }
                if await completeReturnLegIfNeeded(after: effectiveTarget,
                                                   missionID: missionID,
                                                   missionUtterance: missionUtterance,
                                                   lockedVisualQuery: &lockedVisualQuery) {
                    return
                }
                if finishMissionIfVisualTargetArrived(effectiveTarget,
                                                       missionID: missionID,
                                                       missionUtterance: missionUtterance) {
                    return
                }
                outcome = describeMotionOutcome(label: "navigate", poseBefore: poseBefore)

            case .explore(let candidateId):
                guard let requestedCandidate = explorationCandidates.first(where: { $0.id == candidateId }) else {
                    voice.speak("I'm not sure which opening that is anymore.")
                    if recordTick(decision: decision, poseBefore: poseBefore, newObjects: newObjects,
                                   outcome: "explore(\(candidateId)) → unknown opening id") {
                        phase = .idle
                        return
                    }
                    continue
                }
                let candidate: ExplorationCandidate
                if requestedCandidate.status == .visited {
                    guard let unexplored = nextUnexploredCandidate() else {
                        RuntimeFileLog.append("mission_exploration_candidate_rejected", fields: [
                            "candidate": candidateId,
                            "reason": "already_visited",
                            "fallback": "scan_30deg",
                        ])
                        await motion.rotateForScan(by: blockedHeadingRecoveryAngle)
                        if await recoverOrStopMissionIfMotionFailed(missionID: missionID) { return }
                        outcome = "explore(\(candidateId)) → already visited; scanned instead"
                        break
                    }
                    candidate = unexplored
                    RuntimeFileLog.append("mission_exploration_candidate_rerouted", fields: [
                        "requested": candidateId,
                        "selected": candidate.id,
                        "reason": "requested_candidate_visited",
                    ])
                } else {
                    candidate = requestedCandidate
                }
                motion.navigate(to: candidate.worldPoint)
                await waitForMotionToSettle()
                if await recoverOrStopMissionIfMotionFailed(missionID: missionID,
                                                            recoverFromBlockedHeading: true,
                                                            blockedCandidateId: candidate.id) { return }
                outcome = describeMotionOutcome(label: "explore(\(candidate.id))", poseBefore: poseBefore)

            case .lookAround(let angle):
                await motion.rotate(by: angle)
                if await recoverOrStopMissionIfMotionFailed(missionID: missionID) { return }
                let poseAfter = perception.pose?.position
                let stayedPut = distance(poseBefore, poseAfter) < 0.05
                outcome = "lookAround(\(fmt(angle))) → " + (stayedPut
                    ? (newObjects > 0 ? "pose unchanged, saw \(newObjects) new thing(s)" : "pose unchanged, nothing new seen")
                    : "pose changed")

            case .ask(let question):
                phase = .waitingForAnswer
                if let reply = await voice.ask(question, timeout: askTimeout) {
                    lastAnswerWasInconclusive = false
                    if let pose = perception.pose { memory.record(utterance: reply, at: pose) }
                    nextUtterance = reply
                    outcome = "ask(\"\(question)\") → replied: \"\(reply)\""
                } else {
                    lastAnswerWasInconclusive = true
                    outcome = "ask(\"\(question)\") → no reply"
                }

            case .say(let text):
                voice.speak(text)
                outcome = "say(\"\(text)\") → (no motion)"

            case .claimRoom(let roomId):
                teamRadio?.broadcastClaim(roomId)
                outcome = "claimRoom(\(roomId)) → broadcast"

            case .stop:
                motion.cancel()
                phase = .idle
                return

            case .done:
                phase = .idle
                RuntimeFileLog.append("mission_done", fields: ["mission": "\(missionID)"])
                return
            }

            if recordTick(decision: decision, poseBefore: poseBefore, newObjects: newObjects, outcome: outcome) {
                phase = .idle
                return
            }
        }

        if !brainFailed {
            voice.speak("I've used up the time I had for this and want to check in rather than keep going. "
                + wrapUpFindings())
        }
        phase = .idle
        RuntimeFileLog.append("mission_finished", fields: ["mission": "\(missionID)"])
    }

    private func attemptOfflineObjectFallback(
        utterance: String,
        missionID: Int,
        brainFailureReason: String,
        failureMessage: String
    ) async {
        guard isCurrentMission(missionID), !Task.isCancelled else {
            phase = .idle
            RuntimeFileLog.append("mission_offline_fallback_cancelled", fields: [
                "mission": "\(missionID)",
                "reason": "mission_cancelled_before_start"
            ])
            return
        }
        guard let intent = OfflineObjectMissionIntentParser.parse(utterance) else {
            RuntimeFileLog.append("mission_offline_fallback_rejected", fields: [
                "mission": "\(missionID)",
                "reason": "unsupported_command",
                "brain_failure": brainFailureReason
            ])
            failOfflineObjectMission(
                missionID: missionID,
                message: failureMessage,
                reason: "unsupported_command"
            )
            return
        }

        missionTelemetry("mission_offline_fallback_started", [
            "mission": "\(missionID)",
            "target": intent.objectQuery,
            "target_label": intent.targetLabel,
            "requested_colors": Self.requestedColorsDescription(intent.requestedColors),
            "return_requested": intent.shouldReturn ? "true" : "false",
            "brain_failure": brainFailureReason,
            "reason": brainFailureReason,
        ])
        await runOfflineObjectMission(
            intent,
            missionID: missionID,
            failureMessage: failureMessage
        )
    }

    private func runOfflineObjectMission(
        _ intent: OfflineObjectMissionIntent,
        missionID: Int,
        failureMessage: String
    ) async {
        let target = NavigationTarget.visualQuery(intent.objectQuery)
        let topology = roomTopology
        let sessionGeneration = topology?.snapshot.sessionGeneration
        let startRoomID = topology?.snapshot.currentRoomID
        let maximumRoomSearches = 3
        let maximumDoorwayCrossings = 2
        var searchedCandidateIDs: Set<DoorwayCandidateID> = []
        var crossedDoorwaySteps: [DoorwayRouteStep] = []
        var roomsSearched = 0
        var requiresFreshScanTurn = false
        var resolvedGoal: Vec2?

        while resolvedGoal == nil {
            guard !missionCancellationDetected(missionID) else {
                cancelActiveMotion(missionID: missionID, reason: "cancelled_while_scanning")
                RuntimeFileLog.append("mission_offline_fallback_cancelled", fields: [
                    "mission": "\(missionID)",
                    "reason": "cancelled_while_scanning"
                ])
                return
            }
            if intent.searchOtherRooms,
               topology?.snapshot.sessionGeneration != sessionGeneration {
                failOfflineObjectMission(
                    missionID: missionID,
                    message: failureMessage,
                    reason: "session_generation_changed"
                )
                return
            }

            var scanSteps = 0
            if !requiresFreshScanTurn,
               let visibleGoal = resolve(target, missionID: missionID) {
                resolvedGoal = visibleGoal
            } else {
                switch await scanForUnresolvedVisualTarget(
                    target,
                    missionID: missionID,
                    scanSteps: &scanSteps,
                    requireNewFrameAfterInitialTurn: requiresFreshScanTurn
                ) {
                case .found(let scannedGoal):
                    resolvedGoal = scannedGoal
                case .notFound:
                    break
                case .cancelled:
                    cancelActiveMotion(missionID: missionID, reason: "cancelled_while_scanning")
                    RuntimeFileLog.append("mission_offline_fallback_cancelled", fields: [
                        "mission": "\(missionID)",
                        "reason": "cancelled_while_scanning"
                    ])
                    return
                }
            }

            roomsSearched += 1
            RuntimeFileLog.append("mission_offline_room_searched", fields: [
                "mission": "\(missionID)",
                "room_id": topology?.snapshot.currentRoomID?.rawValue ?? "unavailable",
                "room_number": String(roomsSearched),
                "scan_steps": String(scanSteps),
                "target": intent.objectQuery,
                "target_found": resolvedGoal == nil ? "false" : "true",
            ])
            guard resolvedGoal == nil else { break }
            guard intent.searchOtherRooms else {
                failOfflineObjectMission(
                    missionID: missionID,
                    message: failureMessage,
                    reason: "target_not_found"
                )
                return
            }
            guard let topology,
                  sessionGeneration != nil,
                  startRoomID != nil,
                  roomsSearched < maximumRoomSearches,
                  crossedDoorwaySteps.count < maximumDoorwayCrossings else {
                failOfflineObjectMission(
                    missionID: missionID,
                    message: failureMessage,
                    reason: "search_exhausted"
                )
                return
            }

            switch await traverseNextDoorway(
                excluding: searchedCandidateIDs,
                missionID: missionID
            ) {
            case .crossed(let step):
                guard topology.snapshot.sessionGeneration == sessionGeneration else {
                    failOfflineObjectMission(
                        missionID: missionID,
                        message: failureMessage,
                        reason: "session_generation_changed"
                    )
                    return
                }
                crossedDoorwaySteps.append(step)
                let candidateID = topology.snapshot.doorways.first {
                    $0.id == step.doorwayID
                }?.candidateID
                if let candidateID {
                    searchedCandidateIDs.insert(candidateID)
                    RuntimeFileLog.append("mission_offline_doorway_marked_searched", fields: [
                        "mission": "\(missionID)",
                        "candidate_id": candidateID.rawValue,
                        "doorway_id": step.doorwayID.rawValue,
                    ])
                }
                RuntimeFileLog.append("mission_offline_doorway_crossed", fields: [
                    "mission": "\(missionID)",
                    "doorway_id": step.doorwayID.rawValue,
                    "from_room_id": step.fromRoomID.rawValue,
                    "to_room_id": step.toRoomID.rawValue,
                ])
                publishRoomTransitionState(.completed(
                    doorwayID: step.doorwayID,
                    roomID: step.toRoomID
                ))
                requiresFreshScanTurn = true
            case .exhausted(let reason):
                failOfflineObjectMission(
                    missionID: missionID,
                    message: failureMessage,
                    reason: reason == "session_generation_changed"
                        ? reason
                        : "search_exhausted"
                )
                return
            case .cancelled:
                cancelActiveMotion(missionID: missionID, reason: "cancelled_during_room_traversal")
                RuntimeFileLog.append("mission_offline_fallback_cancelled", fields: [
                    "mission": "\(missionID)",
                    "reason": "cancelled_during_room_traversal"
                ])
                return
            }
        }

        guard let goal = resolvedGoal else {
            failOfflineObjectMission(
                missionID: missionID,
                message: failureMessage,
                reason: "search_exhausted"
            )
            return
        }

        guard !missionCancellationDetected(missionID) else {
            cancelActiveMotion(missionID: missionID, reason: "cancelled_before_navigation")
            RuntimeFileLog.append("mission_offline_fallback_cancelled", fields: [
                "mission": "\(missionID)",
                "reason": "cancelled_before_navigation"
            ])
            return
        }

        phase = .acting
        navigate(to: goal, for: target)
        guard await waitForMotionToSettle(missionID: missionID) else {
            RuntimeFileLog.append("mission_offline_fallback_cancelled", fields: [
                "mission": "\(missionID)",
                "reason": "cancelled_during_navigation"
            ])
            return
        }

        if case .failed(let reason) = motion.state {
            failOfflineObjectMission(
                missionID: missionID,
                message: reason,
                reason: "target_navigation_failed"
            )
            return
        }
        guard case .arrived = motion.state else {
            failOfflineObjectMission(
                missionID: missionID,
                message: failureMessage,
                reason: "target_navigation_incomplete"
            )
            return
        }

        RuntimeFileLog.append("mission_offline_fallback_target_arrived", fields: [
            "mission": "\(missionID)",
            "target": intent.objectQuery,
            "goal_x": String(format: "%.2f", goal.x),
            "goal_y": String(format: "%.2f", goal.y),
            "stop_distance": String(format: "%.2f", RoverConfig.visualTargetStopDistance)
        ])

        if intent.searchOtherRooms,
           topology?.snapshot.sessionGeneration != sessionGeneration {
            failOfflineObjectMission(
                missionID: missionID,
                message: failureMessage,
                reason: "session_generation_changed"
            )
            return
        }

        if intent.shouldReturn {
            guard let start = memory.missionStartPose else {
                failOfflineObjectMission(
                    missionID: missionID,
                    message: failureMessage,
                    reason: "missing_start_pose"
                )
                return
            }
            if !crossedDoorwaySteps.isEmpty {
                guard let topology,
                      let startRoomID,
                      topology.snapshot.sessionGeneration == sessionGeneration,
                      let currentRoomID = topology.snapshot.currentRoomID,
                      let returnRoute = topology.shortestDoorwayPath(
                          from: currentRoomID,
                          to: startRoomID
                      ) else {
                    failOfflineObjectMission(
                        missionID: missionID,
                        message: failureMessage,
                        reason: "return_route_unavailable"
                    )
                    return
                }
                RuntimeFileLog.append("mission_offline_return_route_started", fields: [
                    "mission": "\(missionID)",
                    "from_room_id": currentRoomID.rawValue,
                    "to_room_id": startRoomID.rawValue,
                    "step_count": String(returnRoute.count),
                    "outbound_step_count": String(crossedDoorwaySteps.count),
                ])
                for (index, expectedStep) in returnRoute.enumerated() {
                    guard topology.snapshot.sessionGeneration == sessionGeneration else {
                        failOfflineObjectMission(
                            missionID: missionID,
                            message: failureMessage,
                            reason: "session_generation_changed"
                        )
                        return
                    }
                    switch await traverseNextDoorway(
                        preferredDoorwayID: expectedStep.doorwayID,
                        missionID: missionID
                    ) {
                    case .crossed(let actualStep):
                        guard actualStep == expectedStep else {
                            failOfflineObjectMission(
                                missionID: missionID,
                                message: failureMessage,
                                reason: "return_route_changed"
                            )
                            return
                        }
                        RuntimeFileLog.append("mission_offline_return_route_step", fields: [
                            "mission": "\(missionID)",
                            "step": String(index + 1),
                            "doorway_id": actualStep.doorwayID.rawValue,
                            "from_room_id": actualStep.fromRoomID.rawValue,
                            "to_room_id": actualStep.toRoomID.rawValue,
                        ])
                        publishRoomTransitionState(.completed(
                            doorwayID: actualStep.doorwayID,
                            roomID: actualStep.toRoomID
                        ))
                    case .exhausted(let reason):
                        failOfflineObjectMission(
                            missionID: missionID,
                            message: failureMessage,
                            reason: reason == "session_generation_changed"
                                ? reason
                                : "return_route_failed"
                        )
                        return
                    case .cancelled:
                        cancelActiveMotion(
                            missionID: missionID,
                            reason: "cancelled_during_return_route"
                        )
                        RuntimeFileLog.append("mission_offline_fallback_cancelled", fields: [
                            "mission": "\(missionID)",
                            "reason": "cancelled_during_return_route"
                        ])
                        return
                    }
                }
                RuntimeFileLog.append("mission_offline_return_route_completed", fields: [
                    "mission": "\(missionID)",
                    "room_id": startRoomID.rawValue,
                    "step_count": String(returnRoute.count),
                ])
            }
            RuntimeFileLog.append("mission_offline_fallback_return_started", fields: [
                "mission": "\(missionID)",
                "goal_x": String(format: "%.2f", start.position.x),
                "goal_y": String(format: "%.2f", start.position.y)
            ])
            switch await alignHeadingForReturn(to: start.position, missionID: missionID) {
            case .cancelled:
                RuntimeFileLog.append("mission_offline_fallback_cancelled", fields: [
                    "mission": "\(missionID)",
                    "reason": "cancelled_during_return_alignment"
                ])
                return
            case .failed:
                publishMissionTerminal(
                    { .failed(id: $0, command: $1, message: failureMessage) },
                    missionID: missionID
                )
                RuntimeFileLog.append("mission_offline_fallback_failed", fields: [
                    "mission": "\(missionID)",
                    "reason": "return_failed"
                ])
                return
            case .arrived:
                break
            }
            switch await navigateReturn(to: start.position, missionID: missionID) {
            case .cancelled:
                RuntimeFileLog.append("mission_offline_fallback_cancelled", fields: [
                    "mission": "\(missionID)",
                    "reason": "cancelled_during_return_navigation"
                ])
                return
            case .failed:
                publishMissionTerminal(
                    { .failed(id: $0, command: $1, message: failureMessage) },
                    missionID: missionID
                )
                RuntimeFileLog.append("mission_offline_fallback_failed", fields: [
                    "mission": "\(missionID)",
                    "reason": "return_failed"
                ])
                return
            case .arrived:
                break
            }
            guard !missionCancellationDetected(missionID) else {
                cancelActiveMotion(missionID: missionID, reason: "cancelled_before_return_completion")
                RuntimeFileLog.append("mission_offline_fallback_cancelled", fields: [
                    "mission": "\(missionID)",
                    "reason": "cancelled_before_return_completion"
                ])
                return
            }
            RuntimeFileLog.append("mission_offline_fallback_return_completed", fields: [
                "mission": "\(missionID)"
            ])
        }

        phase = .idle
        guard !missionCancellationDetected(missionID) else {
            cancelActiveMotion(missionID: missionID, reason: "cancelled_before_success")
            RuntimeFileLog.append("mission_offline_fallback_cancelled", fields: [
                "mission": "\(missionID)",
                "reason": "cancelled_before_success"
            ])
            return
        }
        publishMissionTerminal(
            { .succeeded(id: $0, command: $1, message: "Command completed.") },
            missionID: missionID
        )
        RuntimeFileLog.append("mission_offline_fallback_completed", fields: [
            "mission": "\(missionID)",
            "target": intent.objectQuery,
            "returned": intent.shouldReturn ? "true" : "false"
        ])
    }

    private func failOfflineObjectMission(
        missionID: Int,
        message: String,
        reason: String
    ) {
        motion.cancel()
        voice.speak(message.replacingOccurrences(of: "I’m", with: "I'm"))
        phase = .idle
        publishMissionTerminal(
            { .failed(id: $0, command: $1, message: message) },
            missionID: missionID
        )
        RuntimeFileLog.append("mission_offline_fallback_failed", fields: [
            "mission": "\(missionID)",
            "reason": reason
        ])
    }

    private func nextBrainAction(_ brain: RoverBrain, context: MissionContext) async throws -> BrainOutput {
        let race = BrainDecisionRace()
        let output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(
                    brain: brain,
                    context: context,
                    timeout: brainDecisionTimeout,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor in race.cancel() }
        }
        try Task.checkCancellation()
        return output
    }

    private func isCurrentMission(_ missionID: Int) -> Bool {
        missionGeneration == missionID
    }

    private func missionCancellationDetected(_ missionID: Int) -> Bool {
        Task.isCancelled || !isCurrentMission(missionID)
    }

    private func cancelActiveMotion(missionID: Int, reason: String) {
        motion.cancel()
        phase = .idle
        RuntimeFileLog.append("mission_cancelled", fields: [
            "mission": "\(missionID)",
            "reason": reason
        ])
    }

    private func isEmergencyStopUtterance(_ utterance: String) -> Bool {
        let tokens = Set(utterance
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        return tokens.contains("stop")
            || tokens.contains("halt")
            || tokens.contains("cancel")
    }

    /// Updates action-history/no-op bookkeeping for one executed tick. Returns `true` if
    /// the bounded fallback fired and the mission loop should end now.
    @discardableResult
    private func recordTick(decision: RoverDecision, poseBefore: Vec2?, newObjects: Int, outcome: String) -> Bool {
        let poseAfter = perception.pose?.position
        let isNoOp = decision == lastDecision && distance(poseBefore, poseAfter) < 0.05 && newObjects == 0
        consecutiveNoOpTicks = isNoOp ? consecutiveNoOpTicks + 1 : 0
        lastDecision = decision
        appendRecentAction(outcome)
        if consecutiveNoOpTicks >= 2 {
            appendRecentAction(noOpWarningLine(consecutiveNoOpTicks))
        }
        if consecutiveNoOpTicks >= 5 {
            fireHeuristicFallback()
            return true
        }
        return false
    }

    private func appendRecentAction(_ line: String) {
        recentActionLines.append(line)
        if recentActionLines.count > recentActionsLimit {
            recentActionLines.removeFirst(recentActionLines.count - recentActionsLimit)
        }
    }

    private func noOpWarningLine(_ count: Int) -> String {
        "WARNING: your last \(count) actions were identical and produced no new information — " +
        "repeating again will not help. Pick a different action: explore an unexplored opening, " +
        "navigate somewhere new, or report your findings and finish with done."
    }

    /// Bounded fallback for a brain that keeps looping despite the escalating warnings —
    /// this is also the real IRL battery-preservation behavior (end the search rather than
    /// drain the pack for nothing), not just a test guard. Logged loudly (a plain stdout
    /// marker, not `EventLog` — that class lives in the test target only) so takes where it
    /// fired are identifiable; prefer retakes where the model exits on its own.
    private func fireHeuristicFallback() {
        print("HEURISTIC_FALLBACK_FIRED")
        voice.speak("I'm not finding anything new — ending the search. " + wrapUpFindings())
    }

    private func wrapUpFindings() -> String {
        let labels = memory.rememberedObjects.map { $0.label }
        return labels.isEmpty ? "I didn't find anything notable." : "Found: \(labels.joined(separator: ", "))."
    }

    private func distance(_ a: Vec2?, _ b: Vec2?) -> Double {
        guard let a, let b else { return .greatestFiniteMagnitude }
        return a.distance(to: b)
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    private func describeMotionOutcome(label: String, poseBefore: Vec2?) -> String {
        let poseAfter = perception.pose?.position
        if case .failed(let reason) = motion.state {
            return "\(label) → FAILED: \(reason)"
        }
        if motion.state == .arrived, let p = poseAfter {
            return "\(label) → arrived at (\(fmt(p.x)), \(fmt(p.y)))"
        }
        if distance(poseBefore, poseAfter) < 0.05 {
            return "\(label) → pose unchanged, no progress"
        }
        if let p = poseAfter {
            return "\(label) → moved to (\(fmt(p.x)), \(fmt(p.y)))"
        }
        return "\(label) → moved"
    }

    /// Once per tick, before thinking: fold what perception sees *right now* into
    /// persistent world memory, so the brain reasons over more than the current frame.
    private func updateWorldModel() {
        // Object permanence: pin every current detection to the nav plane.
        for object in perception.detectObjects() {
            if let world = perception.unproject(normalizedPoint: object.normalizedPoint) {
                memory.rememberObject(label: object.label, at: world)
            }
        }

        // Exploration candidates: match fresh frontiers to known openings by proximity so
        // ids (and visited status) stay stable across ticks; unmatched frontiers become
        // new candidates. Visited ones are kept even after their frontier disappears
        // (they're memory: "already checked, it was a hallway"); stale *unexplored* ones
        // are dropped so the brain isn't offered openings that no longer exist.
        var refreshed: [ExplorationCandidate] = []
        var matchedIds = Set<String>()
        for frontier in perception.explorationFrontiers() {
            if let existing = explorationCandidates.first(where: {
                !matchedIds.contains($0.id) &&
                $0.worldPoint.distance(to: frontier.centroid) < candidateMatchRadius
            }) {
                var updated = existing
                updated.worldPoint = frontier.centroid
                updated.widthMeters = frontier.widthMeters
                refreshed.append(updated)
                matchedIds.insert(existing.id)
            } else {
                refreshed.append(ExplorationCandidate(id: "opening_\(nextCandidateNumber)",
                                                      worldPoint: frontier.centroid,
                                                      widthMeters: frontier.widthMeters))
                nextCandidateNumber += 1
            }
        }
        let rememberedVisited = explorationCandidates.filter {
            $0.status == .visited && !matchedIds.contains($0.id)
        }
        explorationCandidates = refreshed + rememberedVisited

        // Being at (or driving right up to) an opening counts as having checked it.
        if let here = perception.pose?.position {
            for i in explorationCandidates.indices
            where explorationCandidates[i].worldPoint.distance(to: here) < visitedRadius {
                explorationCandidates[i].status = .visited
            }
        }
    }

    private func resolve(_ target: NavigationTarget, missionID: Int) -> Vec2? {
        switch target {
        case .worldPoint(let p): return p
        case .imagePoint(let p): return perception.unproject(normalizedPoint: p)
        case .visualQuery(let q):
            guard let point = lockedVisualTargetPoint(query: q, missionID: missionID) else { return nil }
            return perception.unproject(normalizedPoint: point)
        }
    }

    private func effectiveNavigationTarget(_ target: NavigationTarget,
                                           lockedVisualQuery: inout String?,
                                           missionID: Int) -> NavigationTarget {
        guard case .visualQuery(let query) = target else { return target }
        let normalized = Self.normalizedVisualQuery(query)
        guard !normalized.isEmpty else { return target }
        if let locked = lockedVisualQuery {
            if normalized != Self.normalizedVisualQuery(locked) {
                RuntimeFileLog.append("mission_target_lock_kept", fields: [
                    "mission": "\(missionID)",
                    "target": locked,
                    "ignored": query
                ])
            }
            return .visualQuery(locked)
        }
        lockedVisualQuery = query
        RuntimeFileLog.append("mission_target_locked", fields: [
            "mission": "\(missionID)",
            "target": query,
            "threshold": String(format: "%.2f", visualTargetConfidenceThreshold)
        ])
        return target
    }

    private func lockedVisualTargetPoint(query: String, missionID: Int) -> CGPoint? {
        let objects = perception.detectObjects()
        guard let match = Self.bestVisualTargetMatch(
            query: query,
            objects: objects,
            minimumConfidence: visualTargetConfidenceThreshold,
            missionID: missionID,
            telemetry: missionTelemetry
        ) else {
            RuntimeFileLog.append("mission_target_not_locked", fields: [
                "mission": "\(missionID)",
                "target": query,
                "visible": visibleObjectsLogSummary(objects),
                "threshold": String(format: "%.2f", visualTargetConfidenceThreshold)
            ])
            return nil
        }
        RuntimeFileLog.append("mission_target_match", fields: [
            "mission": "\(missionID)",
            "target": query,
            "label": match.label,
            "confidence": String(format: "%.2f", match.confidence),
            "direction": Self.visualTargetDirection(for: match.normalizedPoint),
            "x": String(format: "%.2f", match.normalizedPoint.x)
        ])
        return match.normalizedPoint
    }

    static func bestVisualTargetMatch(query: String,
                                      objects: [PerceivedObject],
                                      minimumConfidence: Float,
                                      missionID: Int? = nil,
                                      telemetry: @escaping MissionTelemetrySink = { event, fields in
                                          RuntimeFileLog.append(event, fields: fields)
                                      }) -> PerceivedObject? {
        guard let intent = visualTargetIntent(for: query) else { return nil }
        return bestVisualTargetMatch(intent: intent,
                                     objects: objects,
                                     minimumConfidence: minimumConfidence,
                                     missionID: missionID,
                                     telemetry: telemetry)
    }

    static func bestVisualTargetMatch(
        intent: OfflineObjectMissionIntent,
        objects: [PerceivedObject],
        minimumConfidence: Float = 0.90,
        minimumColorConfidence: Float = 0.70,
        missionID: Int? = nil,
        telemetry: @escaping MissionTelemetrySink = { event, fields in
            RuntimeFileLog.append(event, fields: fields)
        }
    ) -> PerceivedObject? {
        let requestedColors = requestedColorsDescription(intent.requestedColors)
        let targetLabel = canonicalVisualLabel(intent.targetLabel)
        var matches: [PerceivedObject] = []

        for object in objects {
            let labelMatches = canonicalVisualLabel(object.label) == targetLabel
            let objectConfidenceMatches = object.confidence >= minimumConfidence
            let requestedEvidence = intent.requestedColors.map { requestedColor in
                object.colorEvidence
                    .filter { $0.color == requestedColor }
                    .map(\.confidence)
                    .max() ?? 0
            }
            let colorConfidence = requestedEvidence.min()
            let colorMatches = requestedEvidence.allSatisfy { $0 >= minimumColorConfidence }
            let fields = [
                "mission": missionID.map(String.init) ?? "none",
                "target_label": targetLabel,
                "requested_colors": requestedColors,
                "label": object.label,
                "object_confidence": String(format: "%.2f", object.confidence),
                "color_confidence": colorConfidence.map { String(format: "%.2f", $0) }
                    ?? "not_required",
                "object_threshold": String(format: "%.2f", minimumConfidence),
                "color_threshold": String(format: "%.2f", minimumColorConfidence),
                "reason": labelMatches && objectConfidenceMatches && colorMatches
                    ? "matched_required_attributes"
                    : "attributes_below_threshold",
            ]

            guard labelMatches, objectConfidenceMatches, colorMatches else {
                telemetry("mission_attribute_rejected", fields)
                continue
            }
            telemetry("mission_attribute_match", fields)
            matches.append(object)
        }

        return matches.max { $0.confidence < $1.confidence }
    }

    private static func visualTargetIntent(for query: String) -> OfflineObjectMissionIntent? {
        OfflineObjectMissionIntentParser.parse(query)
            ?? OfflineObjectMissionIntentParser.parse("go to \(query)")
    }

    private static func requestedColorsDescription(_ colors: Set<LocalObjectColor>) -> String {
        colors.map(\.rawValue).sorted().joined(separator: ",")
    }

    private static func canonicalVisualLabel(_ value: String) -> String {
        let tokens = normalizedVisualQueryTokens(value)
        guard !tokens.isEmpty else { return "" }
        return tokens.joined(separator: " ")
    }

    private static func normalizedVisualQuery(_ value: String) -> String {
        normalizedVisualQueryTokens(value).joined(separator: " ")
    }

    private static func normalizedVisualQueryTokens(_ value: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "at", "find", "for", "go", "in", "look", "of", "on",
            "please", "see", "the", "to", "toward", "towards"
        ]
        return value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
            .map(canonicalVisualToken)
    }

    private static func canonicalVisualToken(_ token: String) -> String {
        switch token {
        case "fridge", "fridges":
            return "refrigerator"
        case "refrigerators":
            return "refrigerator"
        case "couch", "couches":
            return "sofa"
        case "sofas":
            return "sofa"
        case "tvs", "television", "televisions":
            return "tv"
        default:
            return token
        }
    }

    static func visualTargetDirection(for normalizedPoint: CGPoint) -> String {
        switch normalizedPoint.x {
        case ..<0.42:
            return "left"
        case 0.58...:
            return "right"
        default:
            return "ahead"
        }
    }

    private func scanForUnresolvedVisualTarget(_ target: NavigationTarget,
                                               missionID: Int,
                                               scanSteps: inout Int,
                                               requireNewFrameAfterInitialTurn: Bool = false) async
        -> VisualTargetScanResult {
        guard case .visualQuery(let query) = target else { return .notFound }
        var shouldEvaluateBeforeTurn = !requireNewFrameAfterInitialTurn
        while scanSteps < maxVisualTargetScanSteps {
            if shouldEvaluateBeforeTurn {
                switch await waitForVisualTarget(query: query, missionID: missionID) {
                case .found(let goal):
                    return .found(goal)
                case .noVisibleObjects:
                    break
                case .cancelled:
                    return .cancelled
                case .timedOut:
                    break
                }
            }
            shouldEvaluateBeforeTurn = true
            guard !missionCancellationDetected(missionID) else {
                cancelActiveMotion(missionID: missionID, reason: "cancelled_before_scan_turn")
                return .cancelled
            }

            scanSteps += 1
            let angle = visualTargetScanAngle(forScanStep: scanSteps)
            RuntimeFileLog.append("mission_target_scan_step", fields: [
                "mission": "\(missionID)",
                "target": query,
                "step": "\(scanSteps)",
                "max": "\(maxVisualTargetScanSteps)",
                "angle": String(format: "%.0fdeg", angle * 180 / .pi)
            ])
            let frameBeforeTurn = perception.frameSequence
            await rotateForScanRespectingCancellation(by: angle)
            guard !missionCancellationDetected(missionID) else {
                cancelActiveMotion(missionID: missionID, reason: "cancelled_during_scan_turn")
                return .cancelled
            }

            switch await waitForVisualTarget(query: query,
                                             missionID: missionID,
                                             newerThanFrame: frameBeforeTurn) {
            case .found(let goal):
                return .found(goal)
            case .cancelled:
                return .cancelled
            case .noVisibleObjects, .timedOut:
                break
            }
        }

        RuntimeFileLog.append("mission_target_scan_exhausted", fields: [
            "mission": "\(missionID)",
            "target": query,
            "steps": "\(scanSteps)"
        ])
        return .notFound
    }

    private enum VisualTargetWaitResult {
        case found(Vec2)
        case timedOut
        case noVisibleObjects
        case cancelled
    }

    private func waitForVisualTarget(query: String,
                                     missionID: Int,
                                     newerThanFrame frameBaseline: UInt64? = nil) async -> VisualTargetWaitResult {
        if visualTargetScanDelay <= 0 {
            guard !missionCancellationDetected(missionID) else { return .cancelled }
            guard hasFreshPerceptionFrame(newerThan: frameBaseline) else { return .timedOut }
            let objects = perception.detectObjects()
            guard !objects.isEmpty else { return .timedOut }
            if let point = lockedVisualTargetPoint(query: query, objects: objects, missionID: missionID),
               let goal = perception.unproject(normalizedPoint: point) {
                return .found(goal)
            }
            return .timedOut
        }

        let deadline = Date().addingTimeInterval(visualTargetScanDelay)
        var sawVisibleObjects = false
        var didLogFreshFrameWait = false
        while Date() < deadline {
            guard !missionCancellationDetected(missionID) else { return .cancelled }
            guard hasFreshPerceptionFrame(newerThan: frameBaseline) else {
                if !didLogFreshFrameWait {
                    RuntimeFileLog.append("mission_target_scan_wait_fresh_frame", fields: [
                        "mission": "\(missionID)",
                        "target": query,
                        "baseline": frameBaseline.map(String.init) ?? "none",
                        "current": perception.frameSequence.map(String.init) ?? "unavailable"
                    ])
                    didLogFreshFrameWait = true
                }
                do {
                    try await Task.sleep(for: .seconds(visualTargetPollInterval()))
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .cancelled
                }
                continue
            }
            let objects = perception.detectObjects()
            guard !objects.isEmpty else {
                do {
                    try await Task.sleep(for: .seconds(visualTargetPollInterval()))
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .cancelled
                }
                continue
            }
            sawVisibleObjects = true
            if let point = lockedVisualTargetPoint(query: query, objects: objects, missionID: missionID),
               let goal = perception.unproject(normalizedPoint: point) {
                RuntimeFileLog.append("mission_target_scan_wait_match", fields: [
                    "mission": "\(missionID)",
                    "target": query
                ])
                return .found(goal)
            }
            do {
                try await Task.sleep(for: .seconds(visualTargetPollInterval()))
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .cancelled
            }
        }

        if !sawVisibleObjects {
            RuntimeFileLog.append("mission_target_scan_wait_no_visible", fields: [
                "mission": "\(missionID)",
                "target": query,
                "seconds": String(format: "%.2f", visualTargetScanDelay)
            ])
            return .noVisibleObjects
        }
        RuntimeFileLog.append("mission_target_scan_wait_timeout", fields: [
            "mission": "\(missionID)",
            "target": query,
            "seconds": String(format: "%.2f", visualTargetScanDelay)
        ])
        return .timedOut
    }

    private func hasFreshPerceptionFrame(newerThan baseline: UInt64?) -> Bool {
        guard let baseline, let current = perception.frameSequence else { return true }
        return current > baseline
    }

    private func visualTargetPollInterval() -> TimeInterval {
        min(0.2, max(0.01, visualTargetScanDelay / 5))
    }

    private func lockedVisualTargetPoint(query: String,
                                         objects: [PerceivedObject],
                                         missionID: Int) -> CGPoint? {
        guard let match = Self.bestVisualTargetMatch(
            query: query,
            objects: objects,
            minimumConfidence: visualTargetConfidenceThreshold,
            missionID: missionID,
            telemetry: missionTelemetry
        ) else {
            RuntimeFileLog.append("mission_target_not_locked", fields: [
                "mission": "\(missionID)",
                "target": query,
                "visible": visibleObjectsLogSummary(objects),
                "threshold": String(format: "%.2f", visualTargetConfidenceThreshold)
            ])
            return nil
        }
        RuntimeFileLog.append("mission_target_match", fields: [
            "mission": "\(missionID)",
            "target": query,
            "label": match.label,
            "confidence": String(format: "%.2f", match.confidence),
            "direction": Self.visualTargetDirection(for: match.normalizedPoint),
            "x": String(format: "%.2f", match.normalizedPoint.x)
        ])
        return match.normalizedPoint
    }

    private func visualTargetScanAngle(forScanStep step: Int) -> Double {
        guard step > 0 else { return 0 }
        return visualTargetScanAngle
    }

    private func nextUnexploredCandidate() -> ExplorationCandidate? {
        explorationCandidates
            .filter { $0.status == .unexplored }
            .max { $0.widthMeters < $1.widthMeters }
    }

    private func navigate(to goal: Vec2, for target: NavigationTarget) {
        if case .visualQuery = target {
            motion.navigate(to: goal,
                            stoppingAtForwardClearance: RoverConfig.visualTargetStopDistance)
        } else {
            motion.navigate(to: goal)
        }
    }

    private func finishMissionIfVisualTargetArrived(_ target: NavigationTarget,
                                                    missionID: Int,
                                                    missionUtterance: String) -> Bool {
        guard case .arrived = motion.state, case .visualQuery = target else { return false }
        guard !Self.hasFollowUpIntent(missionUtterance), !Self.hasFollowUpIntent(plan ?? "") else {
            return false
        }
        phase = .idle
        RuntimeFileLog.append("mission_target_navigation_done", fields: [
            "mission": "\(missionID)",
            "target": targetDescription(target)
        ])
        return true
    }

    private func completeReturnLegIfNeeded(after target: NavigationTarget,
                                           missionID: Int,
                                           missionUtterance: String,
                                           lockedVisualQuery: inout String?) async -> Bool {
        guard case .arrived = motion.state,
              case .visualQuery = target,
              Self.hasReturnIntent(missionUtterance),
              let start = memory.missionStartPose else {
            return false
        }

        lockedVisualQuery = nil
        RuntimeFileLog.append("mission_leg_completed", fields: [
            "mission": "\(missionID)",
            "leg": "primary_target",
            "target": targetDescription(target)
        ])
        RuntimeFileLog.append("mission_return_started", fields: [
            "mission": "\(missionID)",
            "goal_x": String(format: "%.2f", start.position.x),
            "goal_y": String(format: "%.2f", start.position.y)
        ])

        guard case .arrived = await alignHeadingForReturn(to: start.position, missionID: missionID) else {
            return true
        }
        guard case .arrived = await navigateReturn(to: start.position, missionID: missionID) else {
            return true
        }

        phase = .idle
        plan = "Primary target reached; returned to mission start."
        RuntimeFileLog.append("mission_return_completed", fields: [
            "mission": "\(missionID)",
            "goal_x": String(format: "%.2f", start.position.x),
            "goal_y": String(format: "%.2f", start.position.y)
        ])
        return true
    }

    private func alignHeadingForReturn(to goal: Vec2, missionID: Int) async -> ReturnLegOutcome {
        guard !missionCancellationDetected(missionID) else {
            cancelActiveMotion(missionID: missionID, reason: "cancelled_before_return_alignment")
            return .cancelled
        }
        guard let pose = perception.pose else {
            failReturnMission(missionID: missionID,
                              reason: "I lost my position before I could return.")
            return .failed
        }

        let offset = goal - pose.position
        guard offset.length > 0.05 else { return .arrived }

        let targetYaw = atan2(offset.y, offset.x)
        var remaining = normalizeAngle(targetYaw - pose.yaw)
        let maximumStep = max(abs(blockedHeadingRecoveryAngle), .pi / 180)
        var step = 0

        RuntimeFileLog.append("mission_return_alignment_started", fields: [
            "mission": "\(missionID)",
            "current_yaw_deg": String(format: "%.0f", pose.yaw * 180 / .pi),
            "target_yaw_deg": String(format: "%.0f", targetYaw * 180 / .pi),
            "turn_deg": String(format: "%.0f", remaining * 180 / .pi)
        ])

        while abs(remaining) > .pi / 180 {
            guard !missionCancellationDetected(missionID) else {
                cancelActiveMotion(missionID: missionID, reason: "cancelled_during_return_alignment")
                return .cancelled
            }

            let angle = min(abs(remaining), maximumStep) * (remaining < 0 ? -1 : 1)
            step += 1
            RuntimeFileLog.append("mission_return_alignment_step", fields: [
                "mission": "\(missionID)",
                "step": "\(step)",
                "angle_deg": String(format: "%.0f", angle * 180 / .pi)
            ])
            await rotateForScanRespectingCancellation(by: angle)

            guard !missionCancellationDetected(missionID) else {
                cancelActiveMotion(missionID: missionID, reason: "cancelled_during_return_alignment")
                return .cancelled
            }

            if case .failed(let reason) = motion.state {
                failReturnMission(missionID: missionID, reason: reason)
                return .failed
            }
            remaining -= angle
        }

        RuntimeFileLog.append("mission_return_alignment_completed", fields: [
            "mission": "\(missionID)",
            "steps": "\(step)"
        ])
        return .arrived
    }

    private func rotateForScanRespectingCancellation(by angle: Double) async {
        await withTaskCancellationHandler {
            await motion.rotateForScan(by: angle)
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.motion.cancel()
            }
        }
    }

    private func navigateReturn(to goal: Vec2, missionID: Int) async -> ReturnLegOutcome {
        let maximumAttempts = 2

        for attempt in 1...maximumAttempts {
            guard !missionCancellationDetected(missionID) else {
                cancelActiveMotion(missionID: missionID, reason: "cancelled_before_return_navigation")
                return .cancelled
            }
            RuntimeFileLog.append("mission_return_navigation_attempt", fields: [
                "mission": "\(missionID)",
                "attempt": "\(attempt)",
                "max": "\(maximumAttempts)"
            ])
            motion.navigate(to: goal)
            guard await waitForMotionToSettle(missionID: missionID) else {
                return .cancelled
            }

            if case .arrived = motion.state { return .arrived }

            if case .failed(let reason) = motion.state,
               Self.isBlockedHeading(reason),
               attempt < maximumAttempts {
                RuntimeFileLog.append("mission_return_recovery", fields: [
                    "mission": "\(missionID)",
                    "attempt": "\(attempt)",
                    "reason": reason,
                    "recovery": recoveryDescription
                ])
                guard await rotateForBlockedHeadingRecovery(missionID: missionID) == .completed else {
                    cancelActiveMotion(missionID: missionID, reason: "cancelled_during_return_recovery")
                    return .cancelled
                }
                guard !missionCancellationDetected(missionID) else {
                    cancelActiveMotion(missionID: missionID, reason: "cancelled_during_return_recovery")
                    return .cancelled
                }
                if case .failed(let recoveryReason) = motion.state {
                    failReturnMission(missionID: missionID, reason: recoveryReason)
                    return .failed
                }
                continue
            }

            let reason: String
            if case .failed(let failureReason) = motion.state {
                reason = failureReason
            } else {
                reason = "Return navigation stopped before reaching the start."
            }
            failReturnMission(missionID: missionID, reason: reason)
            return .failed
        }

        failReturnMission(missionID: missionID,
                          reason: "I couldn't find a clear route back to the start.")
        return .failed
    }

    private func failReturnMission(missionID: Int, reason: String) {
        motion.cancel()
        voice.speak(reason)
        phase = .idle
        RuntimeFileLog.append("mission_motion_failed", fields: [
            "mission": "\(missionID)",
            "reason": reason
        ])
        RuntimeFileLog.append("mission_return_failed", fields: [
            "mission": "\(missionID)",
            "reason": reason
        ])
    }

    private func recoverVisualNavigation(_ target: NavigationTarget,
                                         missionID: Int,
                                         scanSteps: inout Int,
                                         missionUtterance: String) async -> Bool {
        guard case .visualQuery(let query) = target,
              case .failed(let reason) = motion.state,
              Self.isNavigationStalled(reason) || Self.isBlockedHeading(reason) else {
            return false
        }

        RuntimeFileLog.append("mission_visual_navigation_recovery", fields: [
            "mission": "\(missionID)",
            "target": query,
            "reason": reason,
            "recovery": "scan_30deg"
        ])

        switch await scanForUnresolvedVisualTarget(target,
                                                   missionID: missionID,
                                                   scanSteps: &scanSteps) {
        case .found(let freshGoal):
            scanSteps = 0
            RuntimeFileLog.append("mission_target_reacquired", fields: [
                "mission": "\(missionID)",
                "target": query,
                "goal_x": String(format: "%.2f", freshGoal.x),
                "goal_y": String(format: "%.2f", freshGoal.y)
            ])
            navigate(to: freshGoal, for: target)
            await waitForMotionToSettle()
            guard isCurrentMission(missionID) else {
                phase = .idle
                RuntimeFileLog.append("mission_cancelled", fields: ["mission": "\(missionID)"])
                return true
            }
            if await recoverOrStopMissionIfMotionFailed(missionID: missionID,
                                                        recoverFromBlockedHeading: true) {
                return true
            }
            return finishMissionIfVisualTargetArrived(target,
                                                       missionID: missionID,
                                                       missionUtterance: missionUtterance)

        case .notFound:
            motion.cancel()
            voice.speak("I couldn't find the target after looking around.")
            phase = .idle
            RuntimeFileLog.append("mission_target_recovery_exhausted", fields: [
                "mission": "\(missionID)",
                "target": query
            ])
            return true

        case .cancelled:
            phase = .idle
            RuntimeFileLog.append("mission_cancelled", fields: ["mission": "\(missionID)"])
            return true
        }
    }

    private static func hasFollowUpIntent(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return hasReturnIntent(lowercased)
            || lowercased.contains(" then ")
            || lowercased.hasPrefix("then ")
    }

    private static func hasReturnIntent(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let trimmed = lowercased.trimmingCharacters(in: .whitespacesAndNewlines)
        return lowercased.contains("come back")
            || lowercased.contains("and back")
            || lowercased.contains("then go back")
            || lowercased.contains("and go back")
            || lowercased.contains("then return")
            || lowercased.contains("and return")
            || lowercased.contains("return to start")
            || lowercased.contains("return to the start")
            || lowercased.contains("return here")
            || lowercased.contains("return home")
            || trimmed == "go back"
            || trimmed == "return"
    }

    @discardableResult
    private func waitForMotionToSettle(missionID: Int? = nil) async -> Bool {
        while motion.state == .driving {
            if let missionID, missionCancellationDetected(missionID) {
                cancelActiveMotion(missionID: missionID, reason: "cancelled_while_motion_active")
                return false
            }
            do {
                try await Task.sleep(for: .seconds(RoverConfig.commandInterval))
            } catch is CancellationError {
                if let missionID {
                    cancelActiveMotion(missionID: missionID, reason: "cancelled_while_waiting_for_motion")
                } else {
                    motion.cancel()
                }
                return false
            } catch {
                if let missionID {
                    cancelActiveMotion(missionID: missionID, reason: "motion_wait_interrupted")
                } else {
                    motion.cancel()
                }
                return false
            }
        }
        if let missionID, missionCancellationDetected(missionID) {
            cancelActiveMotion(missionID: missionID, reason: "cancelled_after_motion_settled")
            return false
        }
        RuntimeFileLog.append("motion_settled", fields: ["state": motion.state.description])
        return true
    }

    private func recoverOrStopMissionIfMotionFailed(missionID: Int,
                                                    recoverFromBlockedHeading: Bool = false,
                                                    blockedCandidateId: String? = nil) async -> Bool {
        guard case .failed(let reason) = motion.state else { return false }
        if recoverFromBlockedHeading, Self.isBlockedHeading(reason) {
            if let blockedCandidateId {
                markExplorationCandidateVisited(blockedCandidateId, reason: reason)
            }
            RuntimeFileLog.append("mission_blocked_heading", fields: [
                "mission": "\(missionID)",
                "reason": reason,
                "recovery": recoveryDescription
            ])
            guard await rotateForBlockedHeadingRecovery(missionID: missionID) == .completed else {
                cancelActiveMotion(missionID: missionID, reason: "cancelled_during_blocked_recovery")
                return true
            }
            guard case .failed(let recoveryReason) = motion.state else { return false }
            voice.speak(recoveryReason)
            phase = .idle
            RuntimeFileLog.append("mission_motion_failed", fields: [
                "mission": "\(missionID)",
                "reason": recoveryReason
            ])
            return true
        }
        voice.speak(reason)
        phase = .idle
        RuntimeFileLog.append("mission_motion_failed", fields: [
            "mission": "\(missionID)",
            "reason": reason
        ])
        return true
    }

    private func markExplorationCandidateVisited(
        _ id: String,
        reason: String,
        event: String = "mission_exploration_candidate_blocked"
    ) {
        guard let index = explorationCandidates.firstIndex(where: { $0.id == id }) else { return }
        explorationCandidates[index].status = .visited
        RuntimeFileLog.append(event, fields: [
            "candidate": id,
            "reason": reason,
            "status": ExplorationCandidate.Status.visited.rawValue
        ])
    }

    private var recoveryDescription: String {
        String(format: "rotate_%.0fdeg", blockedHeadingRecoveryAngle * 180 / .pi)
    }

    private func rotateForBlockedHeadingRecovery(
        missionID: Int
    ) async -> BlockedHeadingRecoveryOutcome {
        guard !missionCancellationDetected(missionID) else {
            cancelActiveMotion(missionID: missionID, reason: "cancelled_before_blocked_recovery")
            return .cancelled
        }
        let angle = blockedHeadingRecoveryAngle
        let timeout = blockedHeadingRecoveryTimeout
        let initialState = motion.state
        let rotation = Task { @MainActor in
            await motion.rotateForScan(by: angle)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var sawDriving = false
        while Date() < deadline {
            guard !missionCancellationDetected(missionID) else {
                return await cancelBlockedHeadingRecovery(
                    rotation,
                    missionID: missionID,
                    reason: "cancelled_during_blocked_recovery"
                )
            }
            let currentState = motion.state
            if currentState == .driving {
                sawDriving = true
            } else if currentState == .arrived
                        || (sawDriving && currentState == .idle)
                        || (currentState != initialState && currentState != .idle) {
                break
            }
            do {
                try await Task.sleep(for: .seconds(RoverConfig.commandInterval))
            } catch is CancellationError {
                return await cancelBlockedHeadingRecovery(
                    rotation,
                    missionID: missionID,
                    reason: "cancelled_while_waiting_for_blocked_recovery"
                )
            } catch {
                return await cancelBlockedHeadingRecovery(
                    rotation,
                    missionID: missionID,
                    reason: "blocked_recovery_wait_interrupted"
                )
            }
        }

        guard !missionCancellationDetected(missionID) else {
            return await cancelBlockedHeadingRecovery(
                rotation,
                missionID: missionID,
                reason: "cancelled_after_blocked_recovery"
            )
        }
        if motion.state == .driving || motion.state == initialState {
            RuntimeFileLog.append("mission_blocked_heading_recovery_timeout", fields: [
                "mission": "\(missionID)",
                "recovery": recoveryDescription,
                "timeout": String(format: "%.2f", timeout)
            ])
            motion.cancel()
            rotation.cancel()
        } else {
            RuntimeFileLog.append("mission_blocked_heading_recovery_settled", fields: [
                "mission": "\(missionID)",
                "recovery": recoveryDescription
            ])
        }
        await rotation.value
        guard !missionCancellationDetected(missionID) else {
            cancelActiveMotion(missionID: missionID, reason: "cancelled_after_blocked_recovery_settled")
            return .cancelled
        }
        return .completed
    }

    private func cancelBlockedHeadingRecovery(
        _ rotation: Task<Void, Never>,
        missionID: Int,
        reason: String
    ) async -> BlockedHeadingRecoveryOutcome {
        cancelActiveMotion(missionID: missionID, reason: reason)
        rotation.cancel()
        await rotation.value
        return .cancelled
    }

    private static func isBlockedHeading(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("Obstacle ahead")
    }

    private static func isNavigationStalled(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("Navigation stalled")
    }

    private func makeContext(utterance: String?, missionID: Int) -> MissionContext {
        MissionContext(missionID: missionID,
                       utterance: utterance,
                       frameJPEG: perception.capturedFrameJPEG(),
                       visibleObjects: perception.detectObjects(),
                       pose: perception.pose,
                       navState: motion.state,
                       memory: memory,
                       explorationCandidates: explorationCandidates,
                       plan: plan,
                       lastAnswerWasInconclusive: lastAnswerWasInconclusive,
                       batteryPercent: battery?.percent,
                       teamContext: teamRadio?.currentTeamContext(),
                       recentActions: recentActionLines)
    }

    private func visibleObjectsLogSummary(_ objects: [PerceivedObject]) -> String {
        guard !objects.isEmpty else { return "none" }
        return objects
            .prefix(8)
            .map { object in
                "\(object.label.replacingOccurrences(of: " ", with: "_")):\(String(format: "%.2f", object.confidence))"
            }
            .joined(separator: ",")
    }

    private func decisionDescription(_ decision: RoverDecision) -> String {
        switch decision {
        case .navigate(let target): return "navigate(\(targetDescription(target)))"
        case .explore(let candidateId): return "explore(\(candidateId))"
        case .lookAround(let angle): return String(format: "lookAround(%.2f)", angle)
        case .ask: return "ask"
        case .say: return "say"
        case .claimRoom(let roomId): return "claimRoom(\(roomId))"
        case .stop: return "stop"
        case .done: return "done"
        }
    }

    private func targetDescription(_ target: NavigationTarget) -> String {
        switch target {
        case .imagePoint(let p): return String(format: "imagePoint(%.2f,%.2f)", p.x, p.y)
        case .worldPoint(let p): return String(format: "worldPoint(%.2f,%.2f)", p.x, p.y)
        case .visualQuery(let query): return "visualQuery(\(query))"
        }
    }
}

private struct BrainDecisionTimeoutError: LocalizedError {
    let timeout: TimeInterval

    var errorDescription: String? {
        "Brain decision timed out after \(String(format: "%.2f", timeout)) seconds."
    }
}

@MainActor
private final class BrainDecisionRace {
    private var continuation: CheckedContinuation<BrainOutput, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var cancellationRequested = false

    func start(
        brain: RoverBrain,
        context: MissionContext,
        timeout: TimeInterval,
        continuation: CheckedContinuation<BrainOutput, Error>
    ) {
        self.continuation = continuation
        guard !cancellationRequested, !Task.isCancelled else {
            finish(.failure(CancellationError()))
            return
        }

        tasks = [
            Task { @MainActor in
                do {
                    self.finish(.success(try await brain.nextAction(context)))
                } catch {
                    self.finish(.failure(error))
                }
            },
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch {
                    return
                }
                self.finish(.failure(BrainDecisionTimeoutError(timeout: timeout)))
            }
        ]
    }

    func cancel() {
        cancellationRequested = true
        finish(.failure(CancellationError()))
    }

    func finish(_ result: Result<BrainOutput, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let runningTasks = tasks
        tasks.removeAll()
        runningTasks.forEach { $0.cancel() }
        continuation.resume(with: result)
    }
}
