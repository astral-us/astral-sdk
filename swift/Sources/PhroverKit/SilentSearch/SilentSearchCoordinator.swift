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
    @ObservationIgnored private var partnerDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var protocolSession: OpticalProtocolSession?
    @ObservationIgnored private var lastIncomingPayload: Data?
    @ObservationIgnored private var retryAction: OpticalAction?
    @ObservationIgnored private var retryHeading: Double?
    @ObservationIgnored private var trackingRecovery: TrackingRecovery?
    @ObservationIgnored private var searchDeadline: SilentSearchInstant?
    @ObservationIgnored private var rendezvousTimedOut = false
    @ObservationIgnored private var localStatus: StatusBody?
    @ObservationIgnored private var rendezvousDecision: DecisionBody?
    @ObservationIgnored private var lastPresentedPayload: Data?
    @ObservationIgnored private var currentSearchCandidateID: String?
    @ObservationIgnored private var convergenceTarget: MissionPoint?

    private enum OpticalAction {
        case present(Data)
        case scan
    }

    private struct TrackingRecovery {
        let phase: SilentSearchPhase
        let deadline: SilentSearchInstant
        let goal: MissionPoint?
        let candidateID: String?
    }

    private struct OpticalTimeout: Error {}
    private struct PartnerTimeout: Error {}
    private struct RendezvousMotionError: Error {
        let failure: SilentSearchMotionFailure
    }

    public init(dependencies: SilentSearchDependencies) {
        self.dependencies = dependencies
        readiness = dependencies.readiness.snapshot
        startSafetyListener()
    }

    deinit {
        missionTask?.cancel()
        safetyListenerTask?.cancel()
        searchDeadlineTask?.cancel()
        partnerDeadlineTask?.cancel()
    }

    public func configure(_ mission: SilentSearchMission) {
        guard phase == .setup else { return }
        self.mission = mission
        diagnostic = nil
        record("silent_search_mission")
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
        ), events: dependencies.events)
        lastIncomingPayload = nil
        retryAction = nil
        diagnostic = nil
        launchHandshake()
        return true
    }

    @discardableResult
    public func retryOpticalExchange() -> Bool {
        guard diagnostic == .opticalTimedOut, retryAction != nil else {
            return false
        }
        diagnostic = nil
        switch phase {
        case .handshake: launchHandshake()
        case .rendezvous: startRendezvous()
        default: return false
        }
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
        retryHeading = nil
        trackingRecovery = nil
        targetConfirmation = nil
        searchDeadline = nil
        rendezvousTimedOut = false
        localStatus = nil
        rendezvousDecision = nil
        lastPresentedPayload = nil
        searchDeadlineTask?.cancel()
        searchDeadlineTask = nil
        partnerDeadlineTask?.cancel()
        partnerDeadlineTask = nil
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
        record("silent_search_phase_transition", fields: [
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
            record("silent_search_calibration_progress", fields: ["sample_count": "\(count)"])
            return false
        case let .rejected(reason):
            diagnostic = .calibrationRejected(reason)
            record("silent_search_calibration_rejected", fields: ["reason": String(describing: reason)])
            return false
        case let .accepted(frame):
            guard frame.sessionGeneration == readiness.sessionGeneration else {
                diagnostic = .calibrationRejected(.generationMismatch)
                record("silent_search_calibration_rejected", fields: ["reason": "generationMismatch"])
                return false
            }
            sharedFrame = frame
            calibrationProgress = 3
            diagnostic = nil
            record("silent_search_calibration_accepted", fields: [
                "generation": "\(frame.sessionGeneration)",
                "sample_count": "\(calibrationProgress)",
            ])
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
                        if session.phase == .awaitingOffer,
                           session.context.localRole == .b,
                           let localMission = mission {
                            let incoming = try OpticalMessageCodec().decode(payload)
                            if incoming.missionID != session.context.missionID {
                                var bound = OpticalProtocolSession(context: OpticalProtocolContext(
                                    missionID: incoming.missionID,
                                    markerID: session.context.markerID,
                                    localRole: session.context.localRole
                                ), events: dependencies.events)
                                try bound.receive(payload, at: dependencies.clock.wallNowMilliseconds)
                                session = bound
                                mission = SilentSearchMission(
                                    id: incoming.missionID, role: localMission.role,
                                    targetLabel: localMission.targetLabel,
                                    searchDurationSeconds: localMission.searchDurationSeconds,
                                    markerID: localMission.markerID
                                )
                            } else {
                                try session.receive(payload, at: dependencies.clock.wallNowMilliseconds)
                            }
                        } else {
                            try session.receive(payload, at: dependencies.clock.wallNowMilliseconds)
                        }
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
        searchDeadline = deadline
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
                record("silent_search_frontier_exhausted")
                await returnToRendezvous()
                return
            case let .candidate(candidate):
                record("silent_search_frontier_selected", fields: ["frontier_id": candidate.stableID])
                currentSearchCandidateID = candidate.stableID
                let result = await dependencies.motion.navigate(
                    to: candidate.missionCentroid,
                    policy: .sectorConstrained(sector)
                )
                guard !Task.isCancelled, phase == .searching else { return }
                switch result {
                case .arrived:
                    currentSearchCandidateID = nil
                    let shouldContinue = await settledTargetObservation(
                        until: deadline,
                        visitedCandidateID: candidate.stableID
                    )
                    if !shouldContinue { return }
                case .failed(.noPath):
                    currentSearchCandidateID = nil
                    dependencies.explorer.markRejected(candidate.stableID, reason: .unreachable)
                    record("silent_search_frontier_rejected", fields: [
                        "frontier_id": candidate.stableID,
                        "reason": "unreachable",
                    ])
                case let .failed(failure):
                    currentSearchCandidateID = nil
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
        let window = dependencies.clock.monotonicNow.addingReportingOverflow(2_000_000_000)
        let scanDeadline = window.overflow ? deadline : min(deadline, window.partialValue)
        var consumedFrames = 0
        while !Task.isCancelled, phase == .searching,
              dependencies.clock.monotonicNow < scanDeadline, consumedFrames < 3 {
            consumedFrames += 1
            switch await dependencies.targetObserver.observeNextFrame(until: scanDeadline) {
            case .pending:
                record("silent_search_target_evidence", fields: ["outcome": "pending"])
            case let .confirmed(confirmation):
                if let visitedCandidateID { dependencies.explorer.markVisited(visitedCandidateID) }
                targetConfirmation = confirmation
                record("silent_search_target_confirmed", fields: [
                    "confidence_basis_points": "\(Int((confirmation.meanConfidence * 10_000).rounded()))",
                    "label": confirmation.label,
                    "sample_count": "\(confirmation.sampleCount)",
                    "x_mm": "\(Int((confirmation.coordinate.x * 1_000).rounded()))",
                    "y_mm": "\(Int((confirmation.coordinate.y * 1_000).rounded()))",
                ])
                await returnToRendezvous()
                return false
            }
        }
        if let visitedCandidateID { dependencies.explorer.markVisited(visitedCandidateID) }
        return !Task.isCancelled && phase == .searching
    }

    private func searchDeadlineReached() async {
        guard phase == .searching else { return }
        record("silent_search_deadline", fields: ["outcome": "reached"])
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
        record("silent_search_return", fields: ["stage": "started"])
        let result = await dependencies.motion.navigate(
            to: SilentSearchGeometry.rendezvousPoint(for: mission.role),
            policy: .sectorConstrained(mission.role.searchSector)
        )
        await completeReturn(result)
    }

    private func completeReturn(_ result: SilentSearchMotionResult) async {
        guard phase == .returning else { return }
        switch result {
        case .arrived:
            await dependencies.motion.stop()
            guard phase == .returning else { return }
            try? transition(to: .rendezvous(.waiting))
            record("silent_search_rendezvous", fields: ["stage": "arrived"])
            startRendezvous()
        case let .failed(failure):
            await finish(with: .motionFailure(failure))
        case .cancelled:
            return
        }
    }

    private var sector: SearchSector {
        mission?.role.searchSector ?? .west
    }

    private func startRendezvous() {
        if partnerDeadlineTask == nil {
            let deadline = partnerDeadline()
            partnerDeadlineTask = Task { [weak self] in
                guard let self else { return }
                do { try await self.dependencies.clock.sleep(until: deadline) }
                catch { return }
                guard case .rendezvous = self.phase else { return }
                await self.finish(with: .partnerTimeout)
            }
        }
        missionTask = Task { [weak self] in await self?.runRendezvous() }
    }

    private func runRendezvous() async {
        guard var session = protocolSession else { return }
        do {
            if case .searchScheduled = session.phase {
                try session.beginRendezvous()
                protocolSession = session
            }
            if let retryAction, let retryHeading {
                switch retryAction {
                case let .present(payload):
                    try await rendezvousPresent(payload, heading: retryHeading)
                case .scan:
                    let payload = try await rendezvousScan(heading: retryHeading)
                    try session.receive(payload, at: dependencies.clock.wallNowMilliseconds)
                    lastIncomingPayload = payload
                    protocolSession = session
                }
            }
            localStatus = try makeStatus()

            while !Task.isCancelled {
                switch session.phase {
                case .readyToSendStatus:
                    guard let localStatus else { throw OpticalProtocolRejection.invalidDecision }
                    let payload = try session.prepareOutgoing(body: .status(localStatus),
                                                              at: dependencies.clock.wallNowMilliseconds)
                    protocolSession = session
                    try await rendezvousPresent(payload, heading: .pi / 2)
                case .awaitingAStatus:
                    let payload = try await rendezvousScan(heading: .pi / 2)
                    try session.receive(payload, at: dependencies.clock.wallNowMilliseconds)
                    lastIncomingPayload = payload
                    protocolSession = session
                case .readyToSendBStatus:
                    let status = try status(linkedTo: linkHashOfLastIncoming())
                    localStatus = status
                    let payload = try session.prepareOutgoing(body: .status(status),
                                                              at: dependencies.clock.wallNowMilliseconds)
                    protocolSession = session
                    try await rendezvousPresent(payload, heading: -.pi / 2)
                case .awaitingBStatus:
                    let payload = try await rendezvousScan(heading: -.pi / 2)
                    try session.receive(payload, at: dependencies.clock.wallNowMilliseconds)
                    lastIncomingPayload = payload
                    protocolSession = session
                case .readyToSendDecision:
                    guard let aStatus = localStatus,
                          let bStatus = try decodedBody(lastIncomingPayload, as: StatusBody.self),
                          let aPayload = lastPresentedPayload else {
                        throw OpticalProtocolRejection.invalidDecision
                    }
                    let decision = OpticalProtocolSession.decision(
                        roverA: aStatus,
                        roverB: bStatus,
                        roverAHash: OpticalMessageCodec().messageLinkHash(for: aPayload),
                        roverBHash: linkHashOfLastIncoming()
                    )
                    rendezvousDecision = decision
                    let payload = try session.prepareOutgoing(body: .decision(decision),
                                                              at: dependencies.clock.wallNowMilliseconds)
                    protocolSession = session
                    try await rendezvousPresent(payload, heading: .pi / 2)
                case .awaitingDecision:
                    let payload = try await rendezvousScan(heading: .pi / 2)
                    try session.receive(payload, at: dependencies.clock.wallNowMilliseconds)
                    rendezvousDecision = try decodedBody(payload, as: DecisionBody.self)
                    lastIncomingPayload = payload
                    protocolSession = session
                case .readyToSendConverge:
                    guard let decision = rendezvousDecision,
                          let decisionPayload = lastPresentedPayload else {
                        throw OpticalProtocolRejection.invalidDecision
                    }
                    let release = dependencies.clock.wallNowMilliseconds.addingReportingOverflow(30_000)
                    guard !release.overflow else { throw OpticalProtocolRejection.invalidSchedule }
                    let payload = try session.prepareOutgoing(body: .converge(ConvergeBody(
                        decisionHash: OpticalMessageCodec().messageLinkHash(for: decisionPayload),
                        releaseMilliseconds: release.partialValue,
                        x: decision.x,
                        y: decision.y
                    )), at: dependencies.clock.wallNowMilliseconds)
                    protocolSession = session
                    try await rendezvousPresent(payload, heading: .pi / 2)
                case .awaitingConverge:
                    let payload = try await rendezvousScan(heading: .pi / 2)
                    try session.receive(payload, at: dependencies.clock.wallNowMilliseconds)
                    lastIncomingPayload = payload
                    protocolSession = session
                case .readyToSendConvergeAck:
                    let payload = try session.prepareOutgoing(body: .convergeAck(HashAcknowledgementBody(
                        hash: linkHashOfLastIncoming()
                    )), at: dependencies.clock.wallNowMilliseconds)
                    protocolSession = session
                    try await rendezvousPresent(payload, heading: -.pi / 2)
                case .awaitingConvergeAck:
                    let payload = try await rendezvousScan(heading: -.pi / 2)
                    try session.receive(payload, at: dependencies.clock.wallNowMilliseconds)
                    lastIncomingPayload = payload
                    protocolSession = session
                case .terminalConflict:
                    await finish(with: .protocolFailure(.convergenceAfterConflict))
                    return
                case .terminalNotFound:
                    await finish(with: .notFound)
                    return
                case let .convergenceScheduled(_, release, x?, y?):
                    record("silent_search_convergence", fields: [
                        "release_epoch_ms": "\(release)",
                        "stage": "scheduled",
                    ])
                    try transition(to: .waitingForConvergence)
                    try await dependencies.clock.sleep(until: monotonicInstant(forWallMilliseconds: release))
                    guard !Task.isCancelled, phase == .waitingForConvergence else { return }
                    try transition(to: .converging)
                    await converge(to: MissionPoint(x: Double(x) / 1_000, y: Double(y) / 1_000)!)
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
        } catch is PartnerTimeout {
            await finish(with: .partnerTimeout)
        } catch let error as RendezvousMotionError {
            await finish(with: .motionFailure(error.failure))
        } catch let rejection as OpticalProtocolRejection {
            await finish(with: .protocolFailure(rejection))
        } catch {
            if !Task.isCancelled { await finish(with: .safetyFailure(.transport)) }
        }
    }

    private func makeStatus() throws -> StatusBody {
        try status(linkedTo: nil)
    }

    private func status(linkedTo previousHash: String?) throws -> StatusBody {
        guard let confirmation = targetConfirmation else {
            return StatusBody(found: false, previousStatusHash: previousHash)
        }
        guard let x = Int32(exactly: (confirmation.coordinate.x * 1_000).rounded()),
              let y = Int32(exactly: (confirmation.coordinate.y * 1_000).rounded()),
              let confidence = UInt16(exactly: (confirmation.meanConfidence * 10_000).rounded()),
              let sampleCount = UInt16(exactly: confirmation.sampleCount),
              confidence <= 10_000, sampleCount > 0 else {
            throw OpticalProtocolRejection.codec(.invalidBody)
        }
        return StatusBody(
            found: true,
            previousStatusHash: previousHash,
            label: confirmation.label,
            x: x,
            y: y,
            confidenceBasisPoints: confidence,
            sampleCount: sampleCount
        )
    }

    private func rendezvousPresent(_ payload: Data, heading: Double) async throws {
        retryAction = .present(payload)
        retryHeading = heading
        try await prepareRendezvousExchange(heading: heading, phase: .presenting)
        try await rendezvousTimed { try await self.dependencies.opticalExchange.present(payload: payload) }
        lastPresentedPayload = payload
    }

    private func rendezvousScan(heading: Double) async throws -> Data {
        retryAction = .scan
        retryHeading = heading
        try await prepareRendezvousExchange(heading: heading, phase: .scanning)
        return try await rendezvousTimed {
            try await self.dependencies.opticalExchange.scan(until: self.rendezvousOpticalDeadline())
        }
    }

    private func prepareRendezvousExchange(heading: Double, phase step: SilentSearchRendezvousStep) async throws {
        try transition(to: .rendezvous(.rotating))
        let result = await dependencies.motion.rotate(to: heading, tolerance: SilentSearchGeometry.headingTolerance)
        switch result {
        case .arrived:
            try transition(to: .rendezvous(step))
        case let .failed(failure):
            throw RendezvousMotionError(failure: failure)
        case .cancelled:
            throw CancellationError()
        }
    }

    private func rendezvousTimed<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let partnerDeadline = partnerDeadline()
        if dependencies.clock.monotonicNow >= partnerDeadline { throw PartnerTimeout() }
        let deadline = rendezvousOpticalDeadline()
        rendezvousTimedOut = false
        let timeoutTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.dependencies.clock.sleep(until: deadline) } catch { return }
            self.rendezvousTimedOut = true
            self.dependencies.opticalExchange.cancel()
        }
        do {
            let result = try await operation()
            timeoutTask.cancel()
            retryAction = nil
            retryHeading = nil
            return result
        } catch {
            timeoutTask.cancel()
            if rendezvousTimedOut {
                diagnostic = .opticalTimedOut
                if deadline == partnerDeadline { throw PartnerTimeout() }
                throw OpticalTimeout()
            }
            throw error
        }
    }

    private func rendezvousOpticalDeadline() -> SilentSearchInstant {
        min(opticalDeadline(), partnerDeadline())
    }

    private func partnerDeadline() -> SilentSearchInstant {
        guard let searchDeadline else { return dependencies.clock.monotonicNow }
        let deadline = searchDeadline.addingReportingOverflow(60_000_000_000)
        return deadline.overflow ? Int64.max : deadline.partialValue
    }

    private func decodedBody<T>(_ payload: Data?, as type: T.Type) throws -> T? {
        guard let payload else { return nil }
        let body = try OpticalMessageCodec().decode(payload).body
        return switch body {
        case let .status(value): value as? T
        case let .decision(value): value as? T
        default: nil
        }
    }

    private func converge(to target: MissionPoint) async {
        guard let mission else { return }
        convergenceTarget = target
        record("silent_search_convergence", fields: ["stage": "started"])
        let xOffset = mission.role == .a ? -SilentSearchGeometry.targetOffset : SilentSearchGeometry.targetOffset
        let standOff = MissionPoint(x: target.x + xOffset, y: target.y)!
        let navigation = await dependencies.motion.navigate(to: standOff, policy: .unrestrictedConvergence)
        guard phase == .converging else { return }
        switch navigation {
        case let .failed(failure):
            await finish(with: .motionFailure(failure))
            return
        case .cancelled:
            return
        case .arrived:
            break
        }
        let heading = atan2(-(target.x - standOff.x), target.y - standOff.y)
        let rotation = await dependencies.motion.rotate(to: heading, tolerance: SilentSearchGeometry.headingTolerance)
        guard phase == .converging else { return }
        switch rotation {
        case let .failed(failure):
            await finish(with: .motionFailure(failure))
        case .cancelled:
            return
        case .arrived:
            guard poseIsAtStandOff(standOff, heading: heading) else {
                await finish(with: .motionFailure(.noPose))
                return
            }
            record("silent_search_convergence", fields: ["stage": "arrived"])
            await finish(with: .success)
        }
    }

    private func poseIsAtStandOff(_ point: MissionPoint, heading: Double) -> Bool {
        guard let pose = dependencies.motion.currentMissionPose else { return false }
        return hypot(pose.position.x - point.x, pose.position.y - point.y) <= SilentSearchGeometry.positionTolerance &&
            abs(atan2(sin(pose.heading - heading), cos(pose.heading - heading))) <=
                SilentSearchGeometry.headingTolerance
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
            partnerDeadlineTask?.cancel()
            partnerDeadlineTask = nil
            dependencies.calibration.cancel()
            dependencies.opticalExchange.cancel()
            await dependencies.motion.stop()
            safetyListenerTask?.cancel()
            safetyListenerTask = nil
            record("silent_search_terminal", fields: ["result": Self.terminalName(result)])
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
                self.record("silent_search_safety", fields: ["reason": Self.safetyName(event)])
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
            goal: goal,
            candidateID: currentSearchCandidateID
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
        missionTask = Task { [weak self] in
            guard let self else { return }
            await self.resume(recovery)
        }
    }

    private func resume(_ recovery: TrackingRecovery) async {
        switch recovery.phase {
        case .searching:
            if let goal = recovery.goal, let mission {
                let result = await dependencies.motion.navigate(
                    to: goal, policy: .sectorConstrained(mission.role.searchSector)
                )
                switch result {
                case .arrived:
                    currentSearchCandidateID = nil
                    guard let deadline = searchDeadline else { return }
                    guard await settledTargetObservation(
                        until: deadline, visitedCandidateID: recovery.candidateID
                    ) else { return }
                case let .failed(failure):
                    await finish(with: .motionFailure(failure))
                    return
                case .cancelled: return
                }
            }
            guard let deadline = searchDeadline else { return }
            await runSearch(until: deadline)
        case .returning:
            guard let goal = recovery.goal, let mission else { return }
            let result = await dependencies.motion.navigate(
                to: goal, policy: .sectorConstrained(mission.role.searchSector)
            )
            await completeReturn(result)
        case .handshake:
            launchHandshake()
        case .rendezvous:
            startRendezvous()
        case .converging:
            if let convergenceTarget { await converge(to: convergenceTarget) }
        default:
            break
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

    private func record(_ event: String, fields: [String: String] = [:]) {
        var contextual = fields
        if let mission {
            contextual["mission"] = mission.id.uuidString.lowercased()
            contextual["marker"] = mission.markerID
            contextual["role"] = mission.role.rawValue
        }
        dependencies.events.record(event: event, fields: contextual)
    }

    private static func safetyName(_ event: SilentSearchSafetyEvent) -> String {
        switch event {
        case .trackingNormal: "tracking_normal"
        case .trackingLimited: "tracking_limited"
        case .generationChanged: "generation_changed"
        case .transportFailed: "transport_failed"
        case .reactiveSafetyFailed: "reactive_safety_failed"
        case .operatorStop: "operator_stop"
        }
    }

    private static func terminalName(_ result: SilentSearchTerminalResult) -> String {
        switch result {
        case .success: "success"
        case .notFound: "not_found"
        case .operatorStopped: "operator_stopped"
        case .operatorAborted: "operator_aborted"
        case .partnerTimeout: "partner_timeout"
        case let .protocolFailure(reason): "protocol_\(String(describing: reason))"
        case .calibrationInvalidated: "calibration_invalidated"
        case let .motionFailure(reason): "motion_\(String(describing: reason))"
        case .safetyFailure(.transport): "safety_transport"
        case .safetyFailure(.reactiveSafety): "safety_reactive_safety"
        }
    }
}
