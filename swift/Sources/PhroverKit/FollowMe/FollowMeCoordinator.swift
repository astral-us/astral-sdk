import Foundation
import RoverNav

public enum FollowMeState: Equatable {
    case idle, pausing, searching, aligning, signalingReady, waitingForMovement, following, holdingDistance, reacquiring, stopped
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .pausing, .searching, .aligning, .signalingReady, .waitingForMovement, .following, .holdingDistance, .reacquiring: true
        default: false
        }
    }
}

@Observable
@MainActor
public final class FollowMeCoordinator {
    public private(set) var state: FollowMeState = .idle {
        didSet {
            if state != oldValue { log("follow_state") }
        }
    }
    public private(set) var perceptionIssue: FollowPerceptionIssue?
    public var isActive: Bool { state.isActive }

    private let perception: any FollowMePerception
    private let motion: any FollowMeMotion
    private let clock: any FollowMeClock
    private let tracker: FollowTargetTracker
    private let config: FollowMeConfiguration
    private let eventSink: @MainActor (String, [String: String]) -> Void
    private let failureEmitter: FollowDiagnosticEmitter
    // At most one terminal delivery window; prune after stream/result/cleanup drain.
    private var failureResolution: FollowMotionFailureResolution?
    private var activeRequest: FollowMotionRequestContext?
    private var summaryBudget = FollowSummaryBudget()
    private var loggedIssue: FollowPerceptionIssue?
    private var loggedTrackingReason: FollowTrackingReason?
    private var generation: UInt64 = 0
    private var operation: UInt64 = 0
    private var framesTask: Task<Void, Never>?
    private var frameProcessorTask: Task<Void, Never>?
    private var pendingFrame: FollowFrameBatch?
    private var safetyTask: Task<Void, Never>?
    private var movementTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var poseTask: Task<Void, Never>?
    private var frameWatchdogTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var alignmentTask: Task<Void, Never>?
    private var alignmentSerial: UInt64 = 0
    private var alignmentConfirmedAfter: ARFrameID?
    private var alignmentCompletionTime: TimeInterval?
    private var departureBaseline: Double?
    private var readySignalAttempted = false
    private var readySignalSucceeded = false
    private var readySignalConfirmedAfter: ARFrameID?
    private var readySignalCompletionTime: TimeInterval?
    private var departurePending = true
    private var perceptionReady = false
    private var readinessDeadline: TimeInterval?
    private var stopTask: Task<Bool, Never>?
    private var confirmationTask: Task<Bool, Never>?
    private var confirmationID: UInt64 = 0
    private var stopBlocked = false
    private var locked: FollowPersonObservation?
    private var lastPosition: Vec2?
    private var reacquireDeadline: TimeInterval?
    private var poseDeadline: TimeInterval?
    private var scanRotation: Double = 0
    private var scanning = false
    private var lastGoal: Vec2?
    private var lastGoalTime: TimeInterval?
    private var latestFrame: ARFrameID?
    private var latestBatch: FollowFrameBatch?

    private var perceptionFailureMessage: String {
        let issue = perceptionIssue ?? .noFrames
        if issue == .trackingLimited, let reason = latestBatch?.trackingReason {
            return "AR tracking limited (\(reason.rawValue)). \(reason.action)"
        }
        return issue.message
    }

    public init(perception: any FollowMePerception, motion: any FollowMeMotion,
                clock: any FollowMeClock, configuration: FollowMeConfiguration = .init(),
                eventSink: @escaping @MainActor (String, [String: String]) -> Void = {
                    RuntimeFileLog.append($0, fields: $1)
                }) {
        self.perception = perception
        self.motion = motion
        self.clock = clock
        self.config = configuration
        self.tracker = FollowTargetTracker(configuration: configuration)
        self.eventSink = eventSink
        self.failureEmitter = FollowDiagnosticEmitter(streamID: "follow-coordinator-\(UUID().uuidString)",
            monotonic: { clock.now }, utc: { Date() }, sink: eventSink)
    }

    @discardableResult
    public func start() async -> Bool {
        guard !isActive, stopTask == nil, !stopBlocked else { return isActive }
        guard perception.detectorReady, perception.personLabelAvailable else {
            state = .failed("Person detector unavailable.")
            return false
        }
        generation &+= 1
        safetyTask?.cancel()
        failureResolution = nil
        activeRequest = nil
        let token = generation
        locked = nil
        alignmentConfirmedAfter = nil
        departureBaseline = nil
        readySignalAttempted = false
        readySignalSucceeded = false
        readySignalConfirmedAfter = nil
        readySignalCompletionTime = nil
        departurePending = config.departureRangeIncrease > 0
        lastPosition = nil
        reacquireDeadline = nil
        poseDeadline = nil
        perceptionReady = false
        scanRotation = 0
        scanning = false
        lastGoal = nil
        lastGoalTime = nil
        latestFrame = nil
        latestBatch = nil
        summaryBudget = FollowSummaryBudget()
        loggedIssue = nil
        loggedTrackingReason = nil
        perceptionIssue = .noFrames
        state = config.stationaryPauseSeconds > 0 ? .pausing : .searching
        updatePerceptionIssue(.noFrames)
        let events = perception.events()
        framesTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self, self.generation == token, self.isActive else { break }
                await self.receive(event, generation: token)
            }
            if !Task.isCancelled, let self, self.generation == token, self.isActive {
                _ = await self.finish(.failed("Perception ended."))
            }
        }
        if let contextual = motion as? any FollowMeContextualMotion {
            let failures = contextual.motionFailures()
            safetyTask = Task { [weak self] in
                for await failure in failures {
                    guard !Task.isCancelled, let self else { break }
                    await self.resolveFailure(failure, subscriptionGeneration: token)
                }
            }
        } else {
            let safety = motion.safetyStates()
            safetyTask = Task { [weak self] in
                for await value in safety {
                    guard let self, self.generation == token else { break }
                    if case .failed(let reason) = value {
                        await self.resolveFailure(.init(context: .unknown, reason: reason,
                            stopOutcome: .unknown, source: .stream), subscriptionGeneration: token)
                    }
                }
            }
        }
        let pauseDeadline = clock.now + config.stationaryPauseSeconds
        let startupDeadline = pauseDeadline + config.startupReadinessSeconds
        readinessDeadline = startupDeadline
        startupTask = Task { [weak self, clock] in
            await clock.sleep(seconds: max(0, startupDeadline - clock.now))
            guard !Task.isCancelled, let self, self.generation == token, !self.perceptionReady else { return }
            _ = await self.finish(.failed(self.perceptionFailureMessage))
        }
        if state == .pausing {
            pauseTask = Task { [weak self, clock] in
                await clock.sleep(seconds: max(0, pauseDeadline - clock.now))
                guard !Task.isCancelled, let self, self.generation == token, self.state == .pausing else { return }
                self.state = .searching
                self.perceptionReady = false
                // Revalidate the latest pause frame against the clock at pause completion.
                if let batch = self.latestBatch {
                    self.latestFrame = nil
                    await self.receive(batch, generation: token)
                }
            }
        }
        return true
    }

    @discardableResult
    public func stop() async -> Bool { await finish(.stopped) }

    /// Synchronously fence observations and goals when the app is leaving the foreground
    /// or Talk. The caller must subsequently await stop() before handing off motion.
    public func inhibitMotion() {
        guard isActive, stopTask == nil else { return }
        generation &+= 1
        operation &+= 1
        state = .stopped
        framesTask?.cancel()
        frameProcessorTask?.cancel()
        frameProcessorTask = nil
        pendingFrame = nil
        safetyTask?.cancel()
        movementTask?.cancel()
        deadlineTask?.cancel()
        poseTask?.cancel()
        frameWatchdogTask?.cancel()
        startupTask?.cancel()
        pauseTask?.cancel()
        cancelAlignment()
        let pending = confirmationTask
        stopTask = Task { [motion] in
            if let pending, !(await pending.value) { return false }
            do { try await motion.stopAndConfirm(); return true }
            catch { return false }
        }
    }

    private func finish(_ result: FollowMeState, resolvingFailure: Bool = false) async -> Bool {
        if let stopTask {
            let confirmed = await stopTask.value
            if !confirmed {
                stopBlocked = true
                state = .failed("Rover stop could not be confirmed.")
            }
            self.stopTask = nil
            return confirmed
        }
        if !isActive {
            guard stopBlocked else { return true }
            let retry = Task { [motion] in
                do { try await motion.stopAndConfirm(); return true }
                catch { return false }
            }
            stopTask = retry
            let confirmed = await retry.value
            if confirmed {
                stopBlocked = false
                failureResolution = nil
                activeRequest = nil
                state = .stopped
            }
            stopTask = nil
            return confirmed
        }
        generation &+= 1 // Inhibit callbacks and new goals before the first suspension.
        operation &+= 1
        state = result
        framesTask?.cancel()
        frameProcessorTask?.cancel()
        frameProcessorTask = nil
        pendingFrame = nil
        if !resolvingFailure { safetyTask?.cancel() }
        movementTask?.cancel()
        deadlineTask?.cancel()
        poseTask?.cancel()
        frameWatchdogTask?.cancel()
        startupTask?.cancel()
        pauseTask?.cancel()
        cancelAlignment()
        framesTask = nil
        if !resolvingFailure { safetyTask = nil }
        movementTask = nil
        deadlineTask = nil
        poseTask = nil
        let pendingConfirmation = confirmationTask
        let task = Task { [motion] in
            if let pendingConfirmation {
                guard await pendingConfirmation.value else { return false }
            }
            do { try await motion.stopAndConfirm(); return true }
            catch { return false }
        }
        stopTask = task
        let confirmed = await task.value
        if !confirmed {
            stopBlocked = true
            state = .failed("Rover stop could not be confirmed.")
        }
        if resolvingFailure, let record = failureResolution {
            let acknowledgement = FollowMotionFailureDelivery(context: record.context, reason: record.primaryReason,
                stopOutcome: confirmed ? .confirmed : .failed, source: .confirmation)
            var updated = record
            updated.consume(acknowledgement)
            failureResolution = updated
            emitFailureResolution(updated, delivery: acknowledgement, stale: false)
            state = .failed(updated.message)
            if updated.stopOutcome == .failed { stopBlocked = true }
        }
        stopTask = nil
        pruneFailureResolution()
        return confirmed
    }

    private func matches(_ context: FollowMotionOperationContext, _ other: FollowMotionOperationContext) -> Bool {
        guard context.request?.sessionGeneration == other.request?.sessionGeneration else { return false }
        if let id = context.controllerOperationID, let otherID = other.controllerOperationID { return id == otherID }
        return context.request?.requestToken == other.request?.requestToken
    }

    private func resolveFailure(_ supplied: FollowMotionFailureDelivery, subscriptionGeneration: UInt64? = nil) async {
        // Legacy streams expose no operation facts. Attach only the request we actually own,
        // leaving controller purpose/profile/ID unknown rather than inferring scan/stall context.
        let context: FollowMotionOperationContext
        if supplied.context.request == nil, supplied.context.controllerOperationID == nil,
           subscriptionGeneration == generation {
            context = .init(request: activeRequest, controllerOperationID: nil, purpose: nil, profile: nil)
        } else { context = supplied.context }
        let delivery = FollowMotionFailureDelivery(context: context, reason: supplied.reason,
            stopOutcome: supplied.stopOutcome, source: supplied.source, stale: supplied.stale,
            commandReceipt: supplied.commandReceipt, stopReceipt: supplied.stopReceipt)
        let retained = failureResolution.map { matches(context, $0.context) } ?? false
        let current = !delivery.stale && (context.request.map {
            $0.sessionGeneration == generation && $0.requestToken == activeRequest?.requestToken
        } ?? (subscriptionGeneration == generation && isActive))
        var record = retained ? failureResolution! : FollowMotionFailureResolution(delivery)
        if retained { record.consume(delivery) }
        let stale = delivery.stale || !current
        emitFailureResolution(record, delivery: delivery, stale: stale)
        guard retained || current else { return }
        failureResolution = record
        if retained {
            // An in-flight terminal result can enrich evidence after fencing. Explicit stale
            // callbacks never publish UI, and no second delivery creates another stop owner.
            if !delivery.stale {
                state = .failed(record.message)
                if record.stopOutcome == .failed { stopBlocked = true }
            }
            pruneFailureResolution()
            return
        }
        guard isActive else { return }
        _ = await finish(.failed(record.message), resolvingFailure: true)
    }

    private func pruneFailureResolution() {
        guard stopTask == nil, failureResolution?.deliveriesDrained == true else { return }
        failureResolution = nil
        activeRequest = nil
    }

    private func consumeResult(_ result: FollowMotionResult) async -> Bool {
        if let failure = result.failure {
            await resolveFailure(failure)
            return true
        }
        if case .failed(let reason) = result.result {
            await resolveFailure(.init(context: result.context, reason: reason,
                stopOutcome: result.stopOutcome, source: .result))
            return true
        }
        // Cancellation/success can carry terminal stop evidence, but cannot invent a failure.
        if let record = failureResolution, matches(result.context, record.context) {
            await resolveFailure(.init(context: result.context, reason: record.primaryReason,
                stopOutcome: result.stopOutcome, source: .result,
                stale: result.context.request?.sessionGeneration != generation))
        }
        return false
    }

    private func emitFailureResolution(_ record: FollowMotionFailureResolution,
                                       delivery: FollowMotionFailureDelivery, stale: Bool) {
        failureEmitter.emit(.init(event: "follow_motion.failure_resolution", context: .init(
            sessionGeneration: record.context.request?.sessionGeneration,
            operationID: record.context.controllerOperationID, purpose: record.context.purpose?.rawValue,
            phase: record.context.request?.phase, stale: stale, outcome: "failed", reason: record.diagnosticReason),
            payload: ["source": .string(delivery.source.rawValue),
                "request_token": record.context.request.map { .number(Double($0.requestToken)) } ?? .null,
                "primary_typed_reason": .string(String(describing: record.primaryReason)),
                "delivered_typed_reason": .string(String(describing: delivery.reason)),
                "stop_outcome": .string(record.stopOutcome.rawValue),
                "formatter_message": .string(record.message), "priority": .number(Double(record.priority)),
                "deduplicated": .bool(record.deduplicated)]))
    }

    private func receive(_ event: FollowPerceptionEvent, generation token: UInt64) async {
        switch event {
        case .interrupted: _ = await finish(.failed("AR session interrupted."))
        case .failed(let message): _ = await finish(.failed(message))
        case .frame(let batch):
            guard generation == token, isActive, !stopBlocked else { return }
            if let previous = pendingFrame?.frameID ?? latestFrame,
               batch.frameID.generation == previous.generation,
               batch.frameID.sequence <= previous.sequence { return }
            pendingFrame = batch
            guard frameProcessorTask == nil else { return }
            frameProcessorTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    // An old processor must never clear a newer generation's task.
                    if self.generation == token { self.frameProcessorTask = nil }
                }
                while !Task.isCancelled, self.generation == token, self.isActive,
                      let frame = self.pendingFrame {
                    self.pendingFrame = nil
                    await self.receive(frame, generation: token)
                }
            }
        }
    }

    private func receive(_ batch: FollowFrameBatch, generation token: UInt64) async {
        guard generation == token, isActive, !stopBlocked else { return }
        if state != .pausing, !perceptionReady, let deadline = readinessDeadline, clock.now >= deadline {
            _ = await finish(.failed(perceptionFailureMessage))
            return
        }
        // A timer and frame processor can resume in either order at the boundary.
        // Never let a late frame clear an outage whose recovery window has ended.
        if let deadline = poseDeadline, clock.now >= deadline {
            _ = await finish(.failed(perceptionFailureMessage))
            return
        }
        if let latestFrame, batch.frameID.generation == latestFrame.generation,
           batch.frameID.sequence <= latestFrame.sequence { return }
        latestFrame = batch.frameID
        latestBatch = batch
        let now = clock.now
        frameWatchdogTask?.cancel()
        let issue: FollowPerceptionIssue?
        if !batch.timestamp.isFinite || now - batch.timestamp < 0 || now - batch.timestamp > config.maximumObservationAge {
            issue = .staleFrame
        } else if batch.trackingQuality == .unavailable || (!perceptionReady && batch.trackingQuality == nil) {
            issue = .trackingUnavailable
        } else if batch.trackingQuality == .limited {
            issue = .trackingLimited
        } else if batch.pose == nil {
            issue = .poseUnavailable
        } else if !batch.depthAvailable {
            issue = .depthUnavailable
        } else {
            issue = nil
        }
        updatePerceptionIssue(issue)
        var associationAvailable = false
        let frameContext = FollowDiagnosticContext(sessionGeneration: token, phase: String(describing: state),
            outcome: issue?.rawValue ?? "healthy")
        let framePayload = FollowAssociationEvaluation.healthPayload(batch: batch, now: now)
        defer {
            // An evaluated association owns the combined summary, including when
            // its periodic allowance is exhausted. No deferred frame history.
            if !associationAvailable, generation == token, isActive, summaryBudget.takeHealthy(now: now) {
                failureEmitter.emit(.init(event: "follow_frame", context: frameContext, payload: framePayload))
            }
        }
        // Observe diagnostics throughout the mandatory stationary interval. Readiness
        // and the post-readiness outage watchdog begin only after that interval.
        if state == .pausing { return }
        if !perceptionReady {
            guard issue == nil else { return }
            perceptionReady = true
            startupTask?.cancel()
            pauseTask?.cancel()
            startupTask = nil
        }
        let frameID = batch.frameID
        frameWatchdogTask = Task { [weak self, clock, config] in
            guard batch.timestamp.isFinite else { return }
            let expiry = batch.timestamp + config.maximumObservationAge + 0.001
            await clock.sleep(seconds: max(0, expiry - clock.now))
            guard !Task.isCancelled, let self, self.generation == token, self.latestFrame == frameID,
                   self.clock.now - batch.timestamp > config.maximumObservationAge else { return }
            await self.perceptionUnavailable(self.perceptionIssue ?? .staleFrame, generation: token)
        }
        if let issue {
            await perceptionUnavailable(issue, generation: token)
            return
        }
        poseDeadline = nil
        poseTask?.cancel()
        poseTask = nil
        // Alignment owns its pre/post-stop waits. Keep healthy frame association
        // flowing during those acknowledgements without launching other motion.
        if confirmationTask != nil, !(state == .aligning && alignmentTask != nil) {
            guard await confirmStop(generation: token) else { return }
            scanning = false
            lastGoal = nil
            guard clock.now - batch.timestamp <= config.maximumObservationAge else {
                await perceptionUnavailable(.staleFrame, generation: token)
                return
            }
        }
        switch state {
        case .searching:
            let evaluated = tracker.selectInitialEvaluated(batch.people, now: now)
            associationAvailable = true
            emitAssociation(evaluated.evaluation, batch: batch, now: now)
            if let selected = evaluated.decision {
                if scanning {
                    (motion as? any FollowMeContextualMotion)?.inhibitScanContinuation(origin: .detection)
                    movementTask?.cancel()
                }
                locked = selected
                lastPosition = selected.position
                if config.departureRangeIncrease > 0 {
                    state = .aligning
                    align(generation: token)
                } else {
                    if scanning { guard await confirmStop(generation: token, origin: .detection) else { return }; scanning = false }
                    await follow(selected, rover: batch.pose!.position, generation: token)
                }
            } else if !scanning { scan(generation: token) }
        case .aligning, .signalingReady, .waitingForMovement:
            guard let locked else { return }
            let evaluated = tracker.continueTrackEvaluated(batch.people, previous: locked, predictedPosition: locked.position, now: now)
            associationAvailable = true
            emitAssociation(evaluated.evaluation, batch: batch, now: now)
            switch evaluated.decision {
            case .matched(let selected):
                self.locked = selected
                lastPosition = selected.position
                if state == .waitingForMovement {
                    if let baseline = departureBaseline,
                       batch.pose!.position.distance(to: selected.position) >= baseline + config.departureRangeIncrease {
                        await follow(selected, rover: batch.pose!.position, generation: token)
                    }
                } else if state == .signalingReady {
                    if !readySignalSucceeded,
                       batch.pose!.position.distance(to: selected.position) < config.minimumHoldDistance + 0.12 {
                        _ = await finish(.failed("Person too close during ready signal. Step back and start following again."))
                        return
                    }
                    if readySignalSucceeded, let confirmed = readySignalConfirmedAfter,
                       confirmed != batch.frameID, let completed = readySignalCompletionTime,
                       batch.timestamp >= completed {
                        departureBaseline = batch.pose!.position.distance(to: selected.position)
                        state = .waitingForMovement
                    }
                } else if alignmentTask == nil {
                    if let completed = alignmentCompletionTime, batch.timestamp < completed { return }
                    let heading = atan2(selected.position.y - batch.pose!.position.y,
                                        selected.position.x - batch.pose!.position.x)
                    if let confirmed = alignmentConfirmedAfter, confirmed != batch.frameID,
                       abs(normalizeAngle(heading - batch.pose!.yaw)) <= config.alignmentAngularTolerance {
                        if !readySignalAttempted {
                            signalReady(generation: token)
                        } else if readySignalSucceeded {
                            if departureBaseline == nil {
                                // The one move finished, but loss preceded its post-stop baseline.
                                departureBaseline = batch.pose!.position.distance(to: selected.position)
                            }
                            state = .waitingForMovement
                        } else {
                            _ = await finish(.failed("Ready signal interrupted. Stop and start following again."))
                        }
                    } else {
                        align(generation: token)
                    }
                }
            case .lost, .ambiguous: await loseTarget(generation: token)
            }
        case .following, .holdingDistance:
            guard let locked else { return }
            let evaluated = tracker.continueTrackEvaluated(batch.people, previous: locked,
                                                           predictedPosition: locked.position, now: now)
            associationAvailable = true
            emitAssociation(evaluated.evaluation, batch: batch, now: now)
            switch evaluated.decision {
            case .matched(let selected):
                self.locked = selected
                lastPosition = selected.position
                await follow(selected, rover: batch.pose!.position, generation: token)
            case .lost, .ambiguous: await loseTarget(generation: token)
            }
        case .reacquiring:
            guard let deadline = reacquireDeadline, now < deadline, let lastPosition else { return }
            let evaluated = tracker.reacquireEvaluated(batch.people, lastPosition: lastPosition, now: now)
            associationAvailable = true
            emitAssociation(evaluated.evaluation, batch: batch, now: now)
            if case .matched(let selected) = evaluated.decision {
                if scanning {
                    (motion as? any FollowMeContextualMotion)?.inhibitScanContinuation(origin: .detection)
                    movementTask?.cancel()
                }
                if scanning { guard await confirmStop(generation: token, origin: .detection) else { return }; scanning = false }
                guard generation == token, clock.now < deadline else { return }
                reacquireDeadline = nil
                deadlineTask?.cancel()
                locked = selected
                self.lastPosition = selected.position
                if departurePending {
                    state = .aligning
                    align(generation: token)
                } else {
                    await follow(selected, rover: batch.pose!.position, generation: token)
                }
            } else if !scanning { scan(generation: token) }
        default: break
        }
    }

    private func follow(_ selected: FollowPersonObservation, rover: Vec2, generation token: UInt64) async {
        guard generation == token else { return }
        departurePending = false
        let distance = rover.distance(to: selected.position)
        guard distance.isFinite else { await loseTarget(generation: token); return }
        guard distance > config.maximumHoldDistance else {
            state = .holdingDistance
            if lastGoal != nil { _ = await confirmStop(generation: token) }
            lastGoal = nil
            return
        }
        guard let goal = tracker.standOffGoal(rover: rover, person: selected.position) else { return }
        state = .following
        if let lastGoal, let lastGoalTime {
            guard goal.distance(to: lastGoal) >= config.minimumGoalChange,
                  clock.now - lastGoalTime >= 1 / config.maximumGoalUpdatesPerSecond else { return }
        }
        guard await confirmStop(generation: token), generation == token else { return }
        guard latestFrame == selected.frameID,
              clock.now - selected.timestamp >= 0,
              clock.now - selected.timestamp <= config.maximumObservationAge,
              poseDeadline == nil else {
            await perceptionUnavailable(perceptionIssue ?? .staleFrame, generation: token)
            return
        }
        lastGoal = goal
        lastGoalTime = clock.now
        launchMovement(generation: token, purpose: .followGoal) { [motion] context in
            await motion.performContextual(.following(goal, self.config.minimumHoldDistance), context: context)
        }
    }

    private func align(generation token: UInt64) {
        guard alignmentTask == nil else { return }
        alignmentSerial &+= 1
        let serial = alignmentSerial
        let capturedPhase = String(describing: state)
        let capturedStopOrigin: FollowMotionStopOrigin = scanning ? .detection : .independent
        alignmentConfirmedAfter = nil
        alignmentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token, self.alignmentSerial == serial { self.alignmentTask = nil }
            }
            guard await self.confirmStop(generation: token, origin: capturedStopOrigin), self.alignmentSerial == serial,
                  self.state == .aligning else { return }
            self.scanning = false
            // A frame already ingested but not yet processed is newer than the
            // last batch. Run it through the normal health/association gates first.
            if let pending = self.pendingFrame {
                self.pendingFrame = nil
                await self.receive(pending, generation: token)
            }
            guard self.generation == token, self.alignmentSerial == serial,
                  self.state == .aligning, self.canScan,
                  let batch = self.latestBatch, let pose = batch.pose, let locked = self.locked,
                  case .matched(let selected) = self.tracker.continueTrack(
                    batch.people, previous: locked, predictedPosition: locked.position, now: self.clock.now)
            else { return }
            let heading = atan2(selected.position.y - pose.position.y, selected.position.x - pose.position.x)
            let angle = normalizeAngle(heading - pose.yaw)
            guard angle.isFinite else { return }
            let id = self.operation
            let context = FollowMotionRequestContext(sessionGeneration: token, requestToken: id,
                purpose: .followAlignment, phase: capturedPhase)
            self.activeRequest = context
            let contextualResult = await self.motion.performContextual(.alignment(angle), context: context)
            if await self.consumeResult(contextualResult) { return }
            let result = contextualResult.result
            guard self.generation == token, self.operation == id, self.alignmentSerial == serial,
                  self.state == .aligning else { return }
            guard await self.confirmStop(generation: token), self.alignmentSerial == serial,
                  self.state == .aligning, self.canScan else { return }
            guard result == .arrived else { return }
            self.alignmentConfirmedAfter = self.latestFrame
            self.alignmentCompletionTime = self.clock.now
        }
    }

    private func cancelAlignment() {
        alignmentSerial &+= 1
        alignmentTask?.cancel()
        alignmentTask = nil
        alignmentConfirmedAfter = nil
        alignmentCompletionTime = nil
    }

    private func signalReady(generation token: UInt64) {
        guard generation == token, canScan, !readySignalAttempted else { return }
        guard let pose = latestBatch?.pose, let locked,
              pose.position.distance(to: locked.position) >= config.minimumHoldDistance + 0.12 else {
            Task {
                guard generation == token else { return }
                _ = await finish(.failed("Not enough person clearance for the 10 cm ready signal. Step back and start following again."))
            }
            return
        }
        readySignalAttempted = true
        state = .signalingReady
        operation &+= 1
        let id = operation
        let context = FollowMotionRequestContext(sessionGeneration: token, requestToken: id,
            purpose: .followReady, phase: String(describing: state))
        activeRequest = context
        movementTask = Task { [weak self, motion] in
            let contextualResult = await motion.performContextual(.ready, context: context)
            guard let self else { return }
            if await self.consumeResult(contextualResult) { return }
            let result = contextualResult.result
            guard self.generation == token, self.operation == id,
                  self.state == .signalingReady else { return }
            guard result == .arrived else {
                _ = await self.finish(.failed("Ready signal could not complete safely. Stop and start following again."))
                return
            }
            guard await self.confirmStop(generation: token), self.state == .signalingReady,
                  self.canScan else { return }
            self.readySignalSucceeded = true
            self.readySignalConfirmedAfter = self.latestFrame
            self.readySignalCompletionTime = self.clock.now
        }
    }

    private func confirmStop(generation token: UInt64, origin: FollowMotionStopOrigin = .independent) async -> Bool {
        guard generation == token, !stopBlocked, stopTask == nil else { return false }
        operation &+= 1
        movementTask?.cancel()
        movementTask = nil
        if let confirmationTask {
            let id = confirmationID
            let confirmed = await confirmationTask.value
            if confirmed, confirmationID == id { self.confirmationTask = nil }
            return confirmed && generation == token && !stopBlocked && stopTask == nil
        }
        confirmationID &+= 1
        let id = confirmationID
        let task = Task { [motion] in
            do {
                try await FollowMotionTaskScope.$stopOrigin.withValue(origin) { try await motion.stopAndConfirm() }
                return true
            }
            catch { return false }
        }
        confirmationTask = task
        let confirmed = await task.value
        if confirmationID == id { confirmationTask = nil }
        if !confirmed {
            generation &+= 1
            operation &+= 1
            stopBlocked = true
            state = .failed("Rover stop could not be confirmed.")
            framesTask?.cancel()
            frameProcessorTask?.cancel()
            frameProcessorTask = nil
            pendingFrame = nil
            safetyTask?.cancel()
            movementTask?.cancel()
            deadlineTask?.cancel()
            poseTask?.cancel()
            frameWatchdogTask?.cancel()
            startupTask?.cancel()
            pauseTask?.cancel()
            cancelAlignment()
            return false
        }
        return generation == token && !stopBlocked && stopTask == nil
    }

    private func launchMovement(generation token: UInt64, purpose: FollowMotionPurpose,
                                scanUsed: Double? = nil, scanRemaining: Double? = nil,
                                action: @escaping @MainActor (FollowMotionRequestContext) async -> FollowMotionResult) {
        operation &+= 1
        let id = operation
        let context = FollowMotionRequestContext(sessionGeneration: token, requestToken: id, purpose: purpose,
            phase: String(describing: state), scanUsed: scanUsed, scanRemaining: scanRemaining)
        activeRequest = context
        movementTask = Task { [weak self] in
            let result = await action(context)
            guard let self else { return }
            _ = await self.consumeResult(result)
        }
    }

    private var canScan: Bool {
        guard isActive, perceptionReady, !stopBlocked, stopTask == nil, confirmationTask == nil,
              perceptionIssue == nil, poseDeadline == nil, let batch = latestBatch,
              batch.pose != nil, batch.depthAvailable,
              batch.trackingQuality != .limited, batch.trackingQuality != .unavailable,
              batch.timestamp.isFinite else { return false }
        let age = clock.now - batch.timestamp
        return age >= 0 && age <= config.maximumObservationAge
    }

    private func scan(generation token: UInt64) {
        guard generation == token, !scanning, canScan else { return }
        let limit = min(2 * .pi, config.maximumScanRotation)
        if state == .searching && scanRotation >= limit - 0.0001 {
            Task { _ = await finish(.failed("No person found.")) }
            return
        }
        if state == .reacquiring, let deadline = reacquireDeadline, clock.now >= deadline { return }
        scanning = true
        let angle = state == .searching ? min(config.scanIncrement, limit - scanRotation) : config.scanIncrement
        scanRotation += angle
        launchMovement(generation: token, purpose: .followScan, scanUsed: scanRotation,
                       scanRemaining: state == .searching ? max(0, limit - scanRotation) : nil) { [motion] context in
            guard self.generation == token, self.canScan else {
                return .init(result: .cancelled, context: .init(request: context, controllerOperationID: nil,
                    purpose: nil, profile: nil), failure: nil)
            }
            return await motion.performContextual(.scan(angle), context: context)
        }
        // The scan completion schedules the next increment only after this one has finished.
        let id = operation
        let rotation = movementTask
        Task { [weak self] in
            await rotation?.value
            guard let self, self.generation == token, self.operation == id else { return }
            self.scanning = false
            if self.state == .searching || self.state == .reacquiring { self.scan(generation: token) }
        }
    }

    private func loseTarget(generation token: UInt64) async {
        guard generation == token, state != .reacquiring else { return }
        cancelAlignment()
        state = .reacquiring
        reacquireDeadline = clock.now + config.reacquisitionSeconds
        guard await confirmStop(generation: token) else { return }
        guard generation == token else { return }
        lastGoal = nil
        let deadline = reacquireDeadline!
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self, clock] in
            await clock.sleep(seconds: max(0, deadline - clock.now))
            guard let self, self.generation == token, self.state == .reacquiring,
                  self.clock.now >= deadline else { return }
            _ = await self.finish(.failed("Person lost."))
        }
        scan(generation: token)
    }

    private func perceptionUnavailable(_ issue: FollowPerceptionIssue, generation token: UInt64) async {
        guard generation == token else { return }
        updatePerceptionIssue(issue)
        // The deadline also marks an outage whose stop has already been requested.
        // Subsequent unhealthy frames update diagnostics without stopping again.
        guard poseDeadline == nil else { return }
        cancelAlignment()
        if state == .signalingReady { state = .aligning }
        let deadline = clock.now + config.perceptionRecoverySeconds
        poseDeadline = deadline
        poseTask?.cancel()
        poseTask = Task { [weak self, clock] in
            await clock.sleep(seconds: max(0, deadline - clock.now))
            guard !Task.isCancelled, let self, self.generation == token, self.poseDeadline == deadline,
                  self.clock.now >= deadline else { return }
            _ = await self.finish(.failed(self.perceptionFailureMessage))
        }
        // Enforce recovery independently of the duration of motor acknowledgement.
        guard await confirmStop(generation: token) else { return }
        guard generation == token, poseDeadline == deadline,
              perceptionIssue != nil else { return }
        lastGoal = nil
        scanning = false
    }

    private func emitAssociation(_ evaluation: FollowAssociationEvaluation, batch: FollowFrameBatch, now: Double) {
        let previous = summaryBudget.previousOutcome
        guard summaryBudget.takeAssociation(outcome: evaluation.outcome, now: now) else { return }
        failureEmitter.emit(.init(event: "follow_person.association",
            context: .init(sessionGeneration: generation, phase: String(describing: state), outcome: evaluation.outcome),
            payload: evaluation.payload(batch: batch, now: now, previousOutcome: previous)))
    }

    private func updatePerceptionIssue(_ issue: FollowPerceptionIssue?) {
        perceptionIssue = issue
        let reason = issue == .trackingLimited ? latestBatch?.trackingReason : nil
        guard issue != loggedIssue || reason != loggedTrackingReason else { return }
        let previous = loggedIssue
        loggedIssue = issue
        loggedTrackingReason = reason
        if issue != nil {
            log("follow_perception_unavailable")
        } else if previous != nil {
            log("follow_perception_recovered", extra: ["previous_issue": previous!.rawValue])
        }
    }

    private func log(_ event: String, extra: [String: String] = [:]) {
        let batch = latestBatch
        var fields: [String: String] = [
            "state": String(describing: state),
            "issue": perceptionIssue?.rawValue ?? "none",
            "frame_id": batch.map { "\($0.frameID.generation):\($0.frameID.sequence)" } ?? "none",
            "frame_timestamp": batch.map { String($0.timestamp) } ?? "unknown",
            "frame_age_seconds": batch.map { String(clock.now - $0.timestamp) } ?? "unknown",
            "tracking_quality": batch?.trackingQuality.map { String(describing: $0) } ?? "unknown",
            "tracking_reason": batch?.trackingReason?.rawValue ?? "unknown",
            "tracking_reason_source": "live_ar_diagnostic_only",
            "pose_available": batch.map { String($0.pose != nil) } ?? "unknown",
            "depth_available": batch.map { String($0.depthAvailable) } ?? "unknown",
            "inference_duration_seconds": batch?.inferenceDuration.map { String($0) } ?? "unknown"
        ]
        fields.merge(extra) { _, new in new }
        eventSink(event, fields)
    }
}
