import Foundation

@MainActor
public protocol OperatorMission: AnyObject {
    func handle(_ text: String) async
    func cancelCurrentMissionAndWait() async throws
}

@MainActor
public protocol OperatorFollow: AnyObject {
    var state: FollowMeState { get }
    func start() async -> Bool
    func stop() async -> Bool
}

extension MissionAgent: OperatorMission {}
extension FollowMeCoordinator: OperatorFollow {}

public enum OperatorSubmission: Equatable, Sendable {
    case accepted
    case rejected(String)
}

/// Reserves motion ownership before suspension so delayed starts cannot outrun stop.
@MainActor
public final class OperatorCommandRouter {
    private enum Owner: Equatable { case idle, mission, transitioning, follow, stopping, blocked }
    private let mission: any OperatorMission
    private let follow: any OperatorFollow
    private let mayStartFollow: @MainActor () -> Bool
    private var owner: Owner = .idle
    private var generation: UInt64 = 0
    private var missionTask: Task<Void, Never>?
    private var pendingMissionStop: Task<Bool, Never>?
    private var stopTask: Task<OperatorSubmission, Never>?

    public init(mission: any OperatorMission, follow: any OperatorFollow,
                mayStartFollow: @escaping @MainActor () -> Bool = { true }) {
        self.mission = mission
        self.follow = follow
        self.mayStartFollow = mayStartFollow
    }

    public func submit(_ text: String) async -> OperatorSubmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("Enter a request first.") }
        let phrase = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ["stop", "stop following", "stop following me"].contains(phrase) { return await stop() }
        if ["follow me", "start following", "start following me"].contains(phrase) {
            guard owner != .blocked && owner != .stopping else {
                return .rejected("Rover stop could not be confirmed.")
            }
            if owner == .follow || owner == .transitioning || follow.state.isActive { return .accepted }
            guard owner == .mission || mayStartFollow() else {
                return .rejected("Stop the other rover activity before following.")
            }
            generation &+= 1
            let token = generation
            owner = .transitioning
            missionTask?.cancel()
            let stopping = Task { [mission] in
                do { try await mission.cancelCurrentMissionAndWait(); return true }
                catch { return false }
            }
            pendingMissionStop = stopping
            let confirmed = await stopping.value
            guard generation == token else { return .rejected("Follow request cancelled.") }
            pendingMissionStop = nil
            guard confirmed else {
                owner = .blocked
                return .rejected("Rover stop could not be confirmed.")
            }
            guard await follow.start(), generation == token else {
                owner = .idle
                return .rejected("Could not start following.")
            }
            owner = .follow
            return .accepted
        }
        guard owner == .idle && !follow.state.isActive else {
            return .rejected("Stop following before sending another request.")
        }
        generation &+= 1
        let token = generation
        owner = .mission
        missionTask = Task { [weak self, mission] in
            await mission.handle(text)
            if let self, self.generation == token, self.owner == .mission { self.owner = .idle }
        }
        return .accepted
    }

    public func stop() async -> OperatorSubmission {
        if let stopTask { return await stopTask.value }
        generation &+= 1
        let previous = owner
        owner = .stopping
        missionTask?.cancel()
        let pending = pendingMissionStop
        let task = Task { [mission, follow] () -> OperatorSubmission in
            if let pending {
                guard await pending.value else { return .rejected("Rover stop could not be confirmed.") }
            } else if previous == .mission || previous == .transitioning || previous == .blocked {
                do { try await mission.cancelCurrentMissionAndWait() }
                catch { return .rejected("Rover stop could not be confirmed.") }
            }
            guard await follow.stop() else { return .rejected("Rover stop could not be confirmed.") }
            return .accepted
        }
        stopTask = task
        let result = await task.value
        stopTask = nil
        pendingMissionStop = nil
        owner = result == .accepted ? .idle : .blocked
        return result
    }
}
