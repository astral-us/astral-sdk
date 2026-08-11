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
    public private(set) var targetConfirmation: TargetConfirmation?

    @ObservationIgnored private let dependencies: SilentSearchDependencies
    @ObservationIgnored private var missionTask: Task<Void, Never>?
    @ObservationIgnored private var safetyListenerTask: Task<Void, Never>?
    @ObservationIgnored private var searchDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var protocolSession: OpticalProtocolSession?
    @ObservationIgnored private var lastIncomingPayload: Data?
    @ObservationIgnored private var retryAction: OpticalAction?
    @ObservationIgnored private var trackingRecovery: TrackingRecovery?

    private enum OpticalAction {
        case present(Data)
        case scan
    }

    private struct TrackingRecovery {
        let phase: SilentSearchPhase
        let deadline: SilentSearchInstant
        let goal: MissionPoint?
    }

    private struct OpticalTimeout: Error {}

    public init(dependencies: SilentSearchDependencies) {
        self.dependencies = dependencies
        readiness = dependencies.readiness.snapshot
        startSafetyListener()
    }

    deinit {
        missionTask?.cancel()
        safetyListenerTask?.cancel()
        searchDeadlineTask?.cancel()
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

    @discardableResult
    public func startHandshake() -> Bool {
        guard phase == .handshake(.ready), let mission, sharedFrame != nil else { return false }
        protocolSession = OpticalProtocolSession(context: OpticalProtocolContext(
            missionID: mission.id,
            markerID: mission.markerID,
            localRole: mission.role
        ))
        lastIncomingPayload = nil
        retryAction = nil
        diagnostic = nil
        launchHandshake()
        return true
    }

    @discardableResult
    public func retryOpticalExchange() -> Bool {
        guard case .handshake = phase, diagnostic == .opticalTimedOut, retryAction != nil else {
            return false
        }
        diagnostic = nil
        launchHandshake()
        return true
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
        protocolSession = nil
        retryAction = nil
        trackingRecovery = nil
        targetConfirmation = nil
        searchDeadlineTask?.cancel()
        searchDeadlineTask = nil
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

    private func launchHandshake() {
        missionTask?.cancel()
        missionTask = Task { [weak self] in
            await self?.runHandshake()
        }
    }

    private func runHandshake() async {
        guard var session = protocolSession else { return }
        do {
            if let retryAction {
                switch retryAction {
                case .present:
                    try await perform(retryAction)
                case .scan:
                    let payload = try await scan()
                    try session.receive(payload, at: dependencies.clock.wallNowMilliseconds)
                    lastIncomingPayload = payload
                    protocolSession = session
                }
                self.retryAction = nil
            }

            while !Task.isCancelled {
                switch session.phase {
                case .readyToSendOffer:
                    guard let mission,
                          let duration = UInt16(exactly: mission.searchDurationSeconds) else {
                        throw OpticalProtocolRejection.codec(.invalidBody)
                    }
                    let rendezvousA = SilentSearchGeometry.rendezvousPoint(for: .a)
                    let rendezvousB = SilentSearchGeometry.rendezvousPoint(for: .b)
                    let payload = try session.prepareOutgoing(body: .offer(OfferBody(
                        searchDurationSeconds: duration,
                        centerHalfWidthMillimeters: 250,
                        targetLabel: mission.targetLabel,
                        markerWidthMillimeters: 200,
                        roverARendezvous: OpticalPose(x: Int32(rendezvousA.x * 1_000),
                                                     y: Int32(rendezvousA.y * 1_000), headingMillidegrees: 0),
                        roverBRendezvous: OpticalPose(x: Int32(rendezvousB.x * 1_000),
                                                     y: Int32(rendezvousB.y * 1_000), headingMillidegrees: 0)
                    )), at: dependencies.clock.wallNowMilliseconds)
                    protocolSession = session
                    try await perform(.present(payload))
                case .awaitingOffer, .awaitingAccept, .awaitingSearchCommit, .awaitingSearchAck:
                    let payload = try await scan()
                    do {
                        try session.receive(payload, at: dependencies.clock.wallNowMilliseconds)
                        lastIncomingPayload = payload
                        protocolSession = session
                    } catch OpticalProtocolRejection.invalidSchedule
                                where session.context.localRole == .a && session.phase == .awaitingSearchAck {
                        let replacement = try makeSearchCommit(session: &session)
                        protocolSession = session
                        try await perform(.present(replacement))
                    }
                case .readyToSendAccept:
                    let payload = try session.prepareOutgoing(body: .accept(AcceptBody(
                        offerHash: linkHashOfLastIncoming(),
                        roverBWallTimeMilliseconds: dependencies.clock.wallNowMilliseconds
                    )), at: dependencies.clock.wallNowMilliseconds)
                    protocolSession = session
                    try await perform(.present(payload))
                case .readyToSendSearchCommit:
                    let payload = try makeSearchCommit(session: &session)
                    protocolSession = session
                    try await perform(.present(payload))
                case .readyToSendSearchAck:
                    let payload = try session.prepareOutgoing(body: .searchAck(HashAcknowledgementBody(
                        hash: linkHashOfLastIncoming()
                    )), at: dependencies.clock.wallNowMilliseconds)
                    protocolSession = session
                    try await perform(.present(payload))
                case let .searchScheduled(start, deadline):
                    protocolSession = session
                    try transition(to: .waitingForSearch)
                    let startInstant = try monotonicInstant(forWallMilliseconds: start)
                    let deadlineInstant = try monotonicInstant(forWallMilliseconds: deadline)
                    try await dependencies.clock.sleep(until: startInstant)
                    guard !Task.isCancelled, phase == .waitingForSearch else { return }
                    try transition(to: .searching)
                    startSearch(until: deadlineInstant)
                    return
                default:
                    throw OpticalProtocolRejection.unexpectedPhase
                }
            }
        } catch is CancellationError {
            return
        } catch is OpticalTimeout {
            protocolSession = session
            diagnostic = .opticalTimedOut
        } catch let rejection as OpticalProtocolRejection {
            protocolSession = session
            await finish(with: .protocolFailure(rejection))
        } catch {
            if !Task.isCancelled { await finish(with: .safetyFailure(.transport)) }
        }
    }

    private func makeSearchCommit(session: inout OpticalProtocolSession) throws -> Data {
        guard let mission else { throw OpticalProtocolRejection.unexpectedPhase }
        let now = dependencies.clock.wallNowMilliseconds
        let start = now.addingReportingOverflow(30_000)
        guard !start.overflow else { throw OpticalProtocolRejection.invalidSchedule }
        let duration = Int64(mission.searchDurationSeconds).multipliedReportingOverflow(by: 1_000)
        let deadline = start.partialValue.addingReportingOverflow(duration.partialValue)
        guard !duration.overflow, !deadline.overflow else { throw OpticalProtocolRejection.invalidSchedule }
        return try session.prepareOutgoing(body: .searchCommit(SearchCommitBody(
            deadlineMilliseconds: deadline.partialValue,
            acceptanceHash: linkHashOfLastIncoming(),
            startMilliseconds: start.partialValue
        )), at: now)
    }

    private func linkHashOfLastIncoming() -> String {
        OpticalMessageCodec().messageLinkHash(for: lastIncomingPayload ?? Data())
    }

    private func scan() async throws -> Data {
        let action = OpticalAction.scan
        return try await timed(action) {
            try await self.dependencies.opticalExchange.scan(until: self.opticalDeadline())
        }
    }

    private func perform(_ action: OpticalAction) async throws {
        switch action {
        case let .present(payload):
            try await timed(action) { try await self.dependencies.opticalExchange.present(payload: payload) }
        case .scan:
            _ = try await scan()
        }
    }

    private func timed<T: Sendable>(
        _ action: OpticalAction,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        retryAction = action
        switch action {
        case .present:
            try? transition(to: .handshake(.presenting))
        case .scan:
            try? transition(to: .handshake(.scanning))
        }
        let deadline = opticalDeadline()
        let timeoutTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.dependencies.clock.sleep(until: deadline) }
            catch { return }
            guard self.retryAction != nil else { return }
            self.diagnostic = .opticalTimedOut
            self.dependencies.opticalExchange.cancel()
        }
        do {
            let result = try await operation()
            timeoutTask.cancel()
            retryAction = nil
            return result
        } catch {
            timeoutTask.cancel()
            if diagnostic == .opticalTimedOut { throw OpticalTimeout() }
            throw error
        }
    }

    private func opticalDeadline() -> SilentSearchInstant {
        let result = dependencies.clock.monotonicNow.addingReportingOverflow(30_000_000_000)
        return result.overflow ? Int64.max : result.partialValue
    }

    func startSearch(until deadline: SilentSearchInstant) {
        guard phase == .searching else { return }
        searchDeadlineTask?.cancel()
        searchDeadlineTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.dependencies.clock.sleep(until: deadline) }
            catch { return }
            await self.searchDeadlineReached()
        }
        missionTask = Task { [weak self] in
            await self?.runSearch(until: deadline)
        }
    }

    private func runSearch(until deadline: SilentSearchInstant) async {
        guard await settledTargetObservation(until: deadline) else { return }

        while !Task.isCancelled, phase == .searching {
            if dependencies.clock.monotonicNow >= deadline { return }
            switch await dependencies.explorer.nextCandidate() {
            case .exhausted:
                await returnToRendezvous()
                return
            case let .candidate(candidate):
                let result = await dependencies.motion.navigate(
                    to: candidate.missionCentroid,
                    policy: .sectorConstrained(sector)
                )
                guard !Task.isCancelled, phase == .searching else { return }
                switch result {
                case .arrived:
                    let shouldContinue = await settledTargetObservation(
                        until: deadline,
                        visitedCandidateID: candidate.stableID
                    )
                    if !shouldContinue { return }
                case .failed(.noPath):
                    dependencies.explorer.markRejected(candidate.stableID, reason: .unreachable)
                case let .failed(failure):
                    await finish(with: .motionFailure(failure))
                    return
                case .cancelled:
                    return
                }
            }
        }
    }

    private func settledTargetObservation(
        until deadline: SilentSearchInstant,
        visitedCandidateID: String? = nil
    ) async -> Bool {
        await dependencies.motion.stop()
        guard !Task.isCancelled, phase == .searching else { return false }
        let settle = dependencies.clock.monotonicNow.addingReportingOverflow(750_000_000)
        let settleDeadline = settle.overflow ? deadline : min(deadline, settle.partialValue)
        do { try await dependencies.clock.sleep(until: settleDeadline) }
        catch { return false }
        guard !Task.isCancelled, phase == .searching,
              dependencies.clock.monotonicNow < deadline else { return false }
        switch await dependencies.targetObserver.observeNextFrame(until: deadline) {
        case .pending:
            if let visitedCandidateID { dependencies.explorer.markVisited(visitedCandidateID) }
            return true
        case let .confirmed(confirmation):
            if let visitedCandidateID { dependencies.explorer.markVisited(visitedCandidateID) }
            targetConfirmation = confirmation
            await returnToRendezvous()
            return false
        }
    }

    private func searchDeadlineReached() async {
        guard phase == .searching else { return }
        missionTask?.cancel()
        missionTask = nil
        await dependencies.motion.stop()
        guard phase == .searching else { return }
        await returnToRendezvous(alreadyStopped: true)
    }

    private func returnToRendezvous(alreadyStopped: Bool = false) async {
        guard phase == .searching, let mission else { return }
        if !alreadyStopped { searchDeadlineTask?.cancel() }
        searchDeadlineTask = nil
        if !alreadyStopped { await dependencies.motion.stop() }
        guard phase == .searching else { return }
        do { try transition(to: .returning) }
        catch { return }
        let result = await dependencies.motion.navigate(
            to: SilentSearchGeometry.rendezvousPoint(for: mission.role),
            policy: .sectorConstrained(mission.role.searchSector)
        )
        guard phase == .returning else { return }
        switch result {
        case .arrived:
            await dependencies.motion.stop()
            guard phase == .returning else { return }
            try? transition(to: .rendezvous(.waiting))
        case let .failed(failure):
            await finish(with: .motionFailure(failure))
        case .cancelled:
            return
        }
    }

    private var sector: SearchSector {
        mission?.role.searchSector ?? .west
    }

    private func monotonicInstant(forWallMilliseconds wall: Int64) throws -> SilentSearchInstant {
        let remaining = wall.subtractingReportingOverflow(dependencies.clock.wallNowMilliseconds)
        guard !remaining.overflow else { throw OpticalProtocolRejection.invalidSchedule }
        let nanoseconds = remaining.partialValue.multipliedReportingOverflow(by: 1_000_000)
        guard !nanoseconds.overflow else { throw OpticalProtocolRejection.invalidSchedule }
        let instant = dependencies.clock.monotonicNow.addingReportingOverflow(max(0, nanoseconds.partialValue))
        guard !instant.overflow else { throw OpticalProtocolRejection.invalidSchedule }
        return instant.partialValue
    }

    private func finish(with result: SilentSearchTerminalResult) async {
        guard case .terminal = phase else {
            missionTask?.cancel()
            missionTask = nil
            searchDeadlineTask?.cancel()
            searchDeadlineTask = nil
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
                switch event {
                case .operatorStop:
                    await self.finish(with: .operatorStopped)
                    return
                case .generationChanged:
                    await self.invalidateCalibration()
                    return
                case .transportFailed:
                    await self.finish(with: .safetyFailure(.transport))
                    return
                case .reactiveSafetyFailed:
                    await self.finish(with: .safetyFailure(.reactiveSafety))
                    return
                case let .trackingLimited(generation):
                    await self.suspendForLimitedTracking(generation: generation)
                case let .trackingNormal(generation):
                    self.recoverTracking(generation: generation)
                }
            }
        }
    }

    private func suspendForLimitedTracking(generation: UInt64) async {
        guard let frame = sharedFrame, frame.sessionGeneration == generation,
              trackingRecovery == nil else { return }
        missionTask?.cancel()
        dependencies.opticalExchange.cancel()
        await dependencies.motion.stop()
        let deadline = dependencies.clock.monotonicNow.addingReportingOverflow(5_000_000_000)
        let goal = dependencies.motion.currentMissionPath.last
        trackingRecovery = TrackingRecovery(
            phase: phase,
            deadline: deadline.overflow ? Int64.max : deadline.partialValue,
            goal: goal
        )
        missionTask = Task { [weak self] in
            guard let self, let recovery = self.trackingRecovery else { return }
            do { try await self.dependencies.clock.sleep(until: recovery.deadline) }
            catch { return }
            guard self.trackingRecovery != nil else { return }
            await self.invalidateCalibration()
        }
    }

    private func recoverTracking(generation: UInt64) {
        guard let recovery = trackingRecovery,
              dependencies.clock.monotonicNow < recovery.deadline,
              sharedFrame?.sessionGeneration == generation else { return }
        missionTask?.cancel()
        trackingRecovery = nil
        guard let goal = recovery.goal, let mission,
              recovery.phase == .searching || recovery.phase == .returning else {
            if case .handshake = recovery.phase { launchHandshake() }
            return
        }
        missionTask = Task { [weak self] in
            guard let self else { return }
            let sector: SearchSector = mission.role == .a ? .west : .east
            let result = await self.dependencies.motion.navigate(
                to: goal,
                policy: .sectorConstrained(sector)
            )
            guard case let .failed(failure) = result else { return }
            await self.finish(with: .motionFailure(failure))
        }
    }

    private func invalidateCalibration() async {
        sharedFrame = nil
        trackingRecovery = nil
        await finish(with: .calibrationInvalidated)
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
