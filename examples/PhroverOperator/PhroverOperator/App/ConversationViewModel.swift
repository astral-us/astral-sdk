import Foundation
import PhroverKit

@Observable
@MainActor
final class ConversationViewModel {
    private(set) var errorMessage: String?
    private(set) var missionPhase: MissionAgent.Phase = .idle
    private var acceptsMissionPhase = true
    private var submissionGeneration: UInt64 = 0
    private var submit: (String) async -> OperatorSubmission
    private var stop: () async -> OperatorSubmission
    private var followState: () -> FollowMeState
    private var inhibit: () -> Void

    init(submit: @escaping (String) async -> OperatorSubmission = { _ in .rejected("Rover is starting. Try again.") },
         stop: @escaping () async -> OperatorSubmission = { .accepted },
         followState: @escaping () -> FollowMeState = { .idle },
         inhibit: @escaping () -> Void = {}) {
        self.submit = submit
        self.stop = stop
        self.followState = followState
        self.inhibit = inhibit
    }

    func configure(submit: @escaping (String) async -> OperatorSubmission,
                   stop: @escaping () async -> OperatorSubmission,
                   followState: @escaping () -> FollowMeState,
                   inhibit: @escaping () -> Void = {}) {
        self.submit = submit
        self.stop = stop
        self.followState = followState
        self.inhibit = inhibit
    }

    var showsStopFollowing: Bool {
        if followState().isActive { return true }
        if case .failed("Rover stop could not be confirmed.") = followState() { return true }
        return errorMessage == "Rover stop could not be confirmed."
    }
    var status: String {
        switch followState() {
        case .idle: return ""
        case .pausing: return "Pausing — five seconds"
        case .aligning: return "Aligning toward you…"
        case .signalingReady: return "Signaling ready — moving 10 cm…"
        case .waitingForMovement: return "Ready — walk away to begin following"
        case .searching: return "Searching for you…"
        case .following: return "Following — 1.5 m"
        case .holdingDistance: return "Holding distance"
        case .reacquiring: return "Person lost — searching…"
        case .stopped: return "Stopped"
        case .failed(let message): return message
        }
    }

    func submitFinalSpeech(_ text: String) async {
        submissionGeneration &+= 1
        let generation = submissionGeneration
        let kind = OperatorCommandKind.classify(text)
        acceptsMissionPhase = kind == .mission
        missionPhase = kind == .mission ? .thinking : .idle
        if kind == .localStop { inhibit() }
        let result = await submit(text)
        guard generation == submissionGeneration else { return }
        switch result {
        case .accepted:
            errorMessage = nil
            if kind != .mission { missionPhase = .idle }
        case .rejected(let message):
            errorMessage = message
            missionPhase = .idle
            acceptsMissionPhase = false
        }
    }

    func stopFollowing() async {
        submissionGeneration &+= 1
        acceptsMissionPhase = false
        missionPhase = .idle
        inhibit()
        switch await stop() {
        case .accepted: errorMessage = nil
        case .rejected(let message): errorMessage = message
        }
    }

    func receiveMissionPhase(_ phase: MissionAgent.Phase) {
        if acceptsMissionPhase { missionPhase = phase }
    }

    func prepareToLeave() { inhibit() }

    @discardableResult
    func leaveTalk() async -> Bool {
        prepareToLeave()
        switch await stop() {
        case .accepted: return true
        case .rejected(let message):
            errorMessage = message
            return false
        }
    }
}
