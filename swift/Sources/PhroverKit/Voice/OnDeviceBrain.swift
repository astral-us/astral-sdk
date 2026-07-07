import Foundation
import FoundationModels
import RoverNav

/// Raw schema the on-device Foundation Model fills — only what a small on-device model can
/// reliably produce (closed-set object labels already in `MissionContext.visibleObjects`,
/// a loose phrase to match against `MissionMemory`, or plain dialog). `OnDeviceBrain` maps
/// this into the shared `RoverDecision`.
@Generable
struct OnDeviceDecision {
    @Guide(description: "What the rover should do next")
    var action: OnDeviceAction

    @Guide(description: "When action is navigateToObject: the object label to drive toward, matching one of the currently visible objects. Empty otherwise.")
    var objectLabel: String

    @Guide(description: "When action is navigateToMemory: a short phrase describing which past location to return to (e.g. 'home', 'where we started', 'the kitchen'), matched loosely against recent conversation. Empty otherwise.")
    var memoryQuery: String

    @Guide(description: "When action is ask: the clarifying question to ask the operator. Empty otherwise.")
    var question: String

    @Guide(description: "When action is say: a short spoken response. Empty otherwise.")
    var spokenText: String

    @Guide(description: "When action is lookAround: degrees to rotate, counterclockwise positive. 90 to 360 is typical for a scan.")
    var lookAroundDegrees: Double
}

@Generable
enum OnDeviceAction: String, CaseIterable {
    case navigateToObject
    case navigateToMemory
    case lookAround
    case ask
    case say
    case stop
    case done
}

/// Fallback brain: Apple's on-device Foundation Model, reasoning over a *text* summary of
/// what's visible (closed-set COCO labels only — no color/attribute grounding, no
/// open-vocabulary pointing). Keeps the rover responsive with no network at all, at the
/// cost of the richer understanding `CloudBrain` provides when online.
@MainActor
public final class OnDeviceBrain: RoverBrain {
    private var session: LanguageModelSession?

    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func nextAction(_ context: MissionContext) async throws -> RoverDecision {
        guard isAvailable else { throw RoverBrainError.unavailable }
        let prompt = promptText(context)
        let result = try await currentSession().respond(to: prompt, generating: OnDeviceDecision.self)
        return map(result.content, context: context)
    }

    private func currentSession() -> LanguageModelSession {
        if let session { return session }
        let s = LanguageModelSession(instructions: """
            You are the on-device brain of a small autonomous ground rover. Decide the \
            single next action given what the operator said, what's currently visible, and \
            recent memory. Only choose navigateToObject when the named object appears in \
            the visible-objects list; if the operator names something not currently \
            visible, choose lookAround to scan for it instead, or ask if you genuinely need \
            clarification and haven't already asked. If a previous question went \
            unanswered, do your best with what you have rather than asking again. Choose \
            done once the operator's request is satisfied.
            """)
        session = s
        return s
    }

    private func promptText(_ context: MissionContext) -> String {
        var lines: [String] = []
        if let utterance = context.utterance { lines.append("Operator just said: \"\(utterance)\"") }
        lines.append(context.visibleObjects.isEmpty
            ? "Nothing recognized nearby right now."
            : "Visible now: " + context.visibleObjects
                .map { "\($0.label) (\(Int($0.confidence * 100))% confidence)" }
                .joined(separator: ", "))
        if !context.memory.turns.isEmpty {
            lines.append("Recent conversation: " + context.memory.turns.suffix(5)
                .map { "\"\($0.utterance)\"" }.joined(separator: "; "))
        }
        if context.lastAnswerWasInconclusive {
            lines.append("Your last question went unanswered — proceed with your best guess instead of asking again.")
        }
        return lines.joined(separator: "\n")
    }

    private func map(_ raw: OnDeviceDecision, context: MissionContext) -> RoverDecision {
        switch raw.action {
        case .navigateToObject:
            let match = context.visibleObjects.first { $0.label.caseInsensitiveCompare(raw.objectLabel) == .orderedSame }
                ?? context.visibleObjects.first
            guard let match else { return .lookAround(angle: .pi / 2) }
            return .navigate(.imagePoint(match.normalizedPoint))

        case .navigateToMemory:
            guard let pose = bestMemoryMatch(raw.memoryQuery, in: context.memory) else {
                return .say("I don't remember where that is.")
            }
            return .navigate(.worldPoint(pose.position))

        case .lookAround:
            let degrees = raw.lookAroundDegrees == 0 ? 90 : raw.lookAroundDegrees
            return .lookAround(angle: degrees * .pi / 180)

        case .ask:
            return .ask(raw.question.isEmpty ? "Could you say more about where you'd like me to go?" : raw.question)

        case .say:
            return .say(raw.spokenText)

        case .stop:
            return .stop

        case .done:
            return .done
        }
    }

    /// Best-effort text matching only — no semantic understanding offline. "home"/"start"/
    /// "back" resolve to the mission's starting pose; anything else is matched against past
    /// utterances by substring containment.
    private func bestMemoryMatch(_ query: String, in memory: MissionMemory) -> Pose2D? {
        let q = query.lowercased()
        if ["home", "start", "began", "back"].contains(where: q.contains) {
            return memory.missionStartPose
        }
        return memory.turns.last { $0.utterance.lowercased().contains(q) || q.contains($0.utterance.lowercased()) }?.pose
    }
}
