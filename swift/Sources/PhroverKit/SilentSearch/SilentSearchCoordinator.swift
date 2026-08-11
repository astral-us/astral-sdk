import Foundation
import Observation

@MainActor
@Observable
public final class SilentSearchCoordinator {
    public private(set) var phase: SilentSearchPhase = .setup
    public private(set) var mission: SilentSearchMission?
    public private(set) var readiness: SilentSearchReadiness
    public private(set) var sharedFrame: SharedMissionFrame?
    public private(set) var calibrationProgress = 0
    public private(set) var diagnostic: SilentSearchCoordinatorDiagnostic?

    @ObservationIgnored private let dependencies: SilentSearchDependencies
    @ObservationIgnored private var missionTask: Task<Void, Never>?
    @ObservationIgnored private var safetyListenerTask: Task<Void, Never>?

    public init(dependencies: SilentSearchDependencies) {
        self.dependencies = dependencies
        readiness = dependencies.readiness.snapshot
        startSafetyListener()
    }

    deinit {
        missionTask?.cancel()
        safetyListenerTask?.cancel()
    }

    public func configure(_ mission: SilentSearchMission) {
        guard phase == .setup else { return }
        self.mission = mission
        diagnostic = nil
    }

    public func refreshReadiness() {
        readiness = dependencies.readiness.snapshot
        if readiness.missingRequirements.isEmpty,
           case .notReady = diagnostic {
            diagnostic = nil
        }
    }

    @discardableResult
    public func startCalibration() -> Bool {
        guard phase == .setup, let mission else { return false }
        refreshReadiness()
        let missing = readiness.missingRequirements
        guard missing.isEmpty, let generation = readiness.sessionGeneration else {
            diagnostic = .notReady(missing)
            return false
        }

        do { try transition(to: .calibrating) }
        catch { return false }
        calibrationProgress = 0
        sharedFrame = nil
        diagnostic = nil
        let events = dependencies.calibration.events(
            markerID: mission.markerID,
            sessionGeneration: generation
        )
        missionTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                if self.receiveCalibration(event) { return }
            }
        }
        return true
    }

    public func stop() async {
        await finish(with: .operatorStopped)
    }

    public func abort() async {
        await finish(with: .operatorAborted)
    }

    public func reset() async {
        guard case .terminal = phase else { return }
        missionTask?.cancel()
        missionTask = nil
        dependencies.calibration.cancel()
        dependencies.opticalExchange.cancel()
        safetyListenerTask?.cancel()
        safetyListenerTask = nil
        mission = nil
        sharedFrame = nil
        calibrationProgress = 0
        diagnostic = nil
        readiness = dependencies.readiness.snapshot
        try? transition(to: .setup)
        startSafetyListener()
    }

    func transition(to next: SilentSearchPhase) throws {
        guard Self.isLegalTransition(from: phase, to: next) else {
            throw SilentSearchTransitionError.illegal(from: phase, to: next)
        }
        let previous = phase
        phase = next
        dependencies.events.record(event: "silent_search_phase_transition", fields: [
            "from": previous.telemetryName,
            "to": next.telemetryName,
        ])
    }

    private func receiveCalibration(_ event: SilentSearchCalibrationEvent) -> Bool {
        guard phase == .calibrating else { return false }
        switch event {
        case let .progress(count):
            calibrationProgress = count
            diagnostic = nil
            return false
        case let .rejected(reason):
            diagnostic = .calibrationRejected(reason)
            return false
        case let .accepted(frame):
            guard frame.sessionGeneration == readiness.sessionGeneration else {
                diagnostic = .calibrationRejected(.generationMismatch)
                return false
            }
            sharedFrame = frame
            diagnostic = nil
            try? transition(to: .handshake(.ready))
            return true
        }
    }

    private func finish(with result: SilentSearchTerminalResult) async {
        guard case .terminal = phase else {
            missionTask?.cancel()
            missionTask = nil
            dependencies.calibration.cancel()
            dependencies.opticalExchange.cancel()
            await dependencies.motion.stop()
            safetyListenerTask?.cancel()
            safetyListenerTask = nil
            try? transition(to: .terminal(result))
            return
        }
    }

    private func startSafetyListener() {
        guard safetyListenerTask == nil else { return }
        let events = dependencies.safety.events()
        safetyListenerTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                if event == .operatorStop {
                    await self.finish(with: .operatorStopped)
                    return
                }
            }
        }
    }

    private static func isLegalTransition(from: SilentSearchPhase, to: SilentSearchPhase) -> Bool {
        if case .terminal = to {
            if case .terminal = from { return false }
            return true
        }
        return switch (from, to) {
        case (.setup, .calibrating),
             (.calibrating, .handshake),
             (.handshake, .handshake),
             (.handshake, .waitingForSearch),
             (.waitingForSearch, .searching),
             (.searching, .returning),
             (.returning, .rendezvous),
             (.rendezvous, .rendezvous),
             (.rendezvous, .waitingForConvergence),
             (.waitingForConvergence, .converging),
             (.terminal, .setup):
            true
        default:
            false
        }
    }
}
