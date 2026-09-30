import Foundation
import RoverNav

public enum FollowMeState: Equatable {
    case idle, searching, following, holdingDistance, reacquiring, stopped
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .searching, .following, .holdingDistance, .reacquiring: true
        default: false
        }
    }
}

@Observable
@MainActor
public final class FollowMeCoordinator {
    public private(set) var state: FollowMeState = .idle
    public var isActive: Bool { state.isActive }

    private let perception: any FollowMePerception
    private let motion: any FollowMeMotion
    private let clock: any FollowMeClock
    private let tracker: FollowTargetTracker
    private let config: FollowMeConfiguration
    private var generation: UInt64 = 0
    private var operation: UInt64 = 0
    private var framesTask: Task<Void, Never>?
    private var safetyTask: Task<Void, Never>?
    private var movementTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var poseTask: Task<Void, Never>?
    private var frameWatchdogTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var stopTask: Task<Bool, Never>?
    private var confirmationTask: Task<Bool, Never>?
    private var stopBlocked = false
    private var locked: FollowPersonObservation?
    private var lastPosition: Vec2?
    private var reacquireDeadline: TimeInterval?
    private var poseDeadline: TimeInterval?
    private var scanCount = 0
    private var scanning = false
    private var lastGoal: Vec2?
    private var lastGoalTime: TimeInterval?
    private var latestFrame: ARFrameID?

    public init(perception: any FollowMePerception, motion: any FollowMeMotion,
                clock: any FollowMeClock, configuration: FollowMeConfiguration = .init()) {
        self.perception = perception
        self.motion = motion
        self.clock = clock
        self.config = configuration
        self.tracker = FollowTargetTracker(configuration: configuration)
    }

    @discardableResult
    public func start() async -> Bool {
        guard !isActive, stopTask == nil, !stopBlocked else { return isActive }
        guard perception.detectorReady, perception.personLabelAvailable else {
            state = .failed("Person detector unavailable.")
            return false
        }
        generation &+= 1
        let token = generation
        locked = nil
        lastPosition = nil
        reacquireDeadline = nil
        poseDeadline = nil
        scanCount = 0
        scanning = false
        lastGoal = nil
        lastGoalTime = nil
        latestFrame = nil
        state = .searching
        let events = perception.events()
        let safety = motion.safetyStates()
        framesTask = Task { [weak self] in
            for await event in events {
                guard let self, self.generation == token else { break }
                await self.receive(event, generation: token)
            }
            if let self, self.generation == token { _ = await self.finish(.failed("Perception ended.")) }
        }
        safetyTask = Task { [weak self] in
            for await value in safety {
                guard let self, self.generation == token else { break }
                if case .failed = value { _ = await self.finish(.failed("Navigation safety failure.")); break }
            }
        }
        startupTask = Task { [weak self, clock, config] in
            await clock.sleep(seconds: config.perceptionRecoverySeconds)
            guard let self, self.generation == token, self.latestFrame == nil else { return }
            _ = await self.finish(.failed("Pose or depth unavailable."))
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
        safetyTask?.cancel()
        movementTask?.cancel()
        deadlineTask?.cancel()
        poseTask?.cancel()
        frameWatchdogTask?.cancel()
        startupTask?.cancel()
        let pending = confirmationTask
        stopTask = Task { [motion] in
            if let pending, !(await pending.value) { return false }
            do { try await motion.stopAndConfirm(); return true }
            catch { return false }
        }
    }

    private func finish(_ result: FollowMeState) async -> Bool {
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
                state = .stopped
            }
            stopTask = nil
            return confirmed
        }
        generation &+= 1 // Inhibit callbacks and new goals before the first suspension.
        operation &+= 1
        state = result
        framesTask?.cancel()
        safetyTask?.cancel()
        movementTask?.cancel()
        deadlineTask?.cancel()
        poseTask?.cancel()
        frameWatchdogTask?.cancel()
        startupTask?.cancel()
        framesTask = nil
        safetyTask = nil
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
        stopTask = nil
        return confirmed
    }

    private func receive(_ event: FollowPerceptionEvent, generation token: UInt64) async {
        switch event {
        case .interrupted: _ = await finish(.failed("AR session interrupted."))
        case .failed(let message): _ = await finish(.failed(message))
        case .frame(let batch): await receive(batch, generation: token)
        }
    }

    private func receive(_ batch: FollowFrameBatch, generation token: UInt64) async {
        guard generation == token, isActive, !stopBlocked else { return }
        if let latestFrame, batch.frameID.generation == latestFrame.generation,
           batch.frameID.sequence <= latestFrame.sequence { return }
        latestFrame = batch.frameID
        startupTask?.cancel()
        startupTask = nil
        let now = clock.now
        frameWatchdogTask?.cancel()
        let frameID = batch.frameID
        frameWatchdogTask = Task { [weak self, clock, config] in
            await clock.sleep(seconds: config.maximumObservationAge + 0.001)
            guard let self, self.generation == token, self.latestFrame == frameID,
                  self.state != .reacquiring,
                  self.clock.now - batch.timestamp > config.maximumObservationAge else { return }
            await self.perceptionUnavailable(generation: token)
        }
        guard batch.pose != nil, batch.depthAvailable,
              batch.timestamp.isFinite, now - batch.timestamp >= 0,
              now - batch.timestamp <= config.maximumObservationAge else {
            await perceptionUnavailable(generation: token)
            return
        }
        poseDeadline = nil
        poseTask?.cancel()
        poseTask = nil
        switch state {
        case .searching:
            if let selected = tracker.selectInitial(batch.people, now: now) {
                locked = selected
                lastPosition = selected.position
                if scanning { guard await confirmStop(generation: token) else { return }; scanning = false }
                await follow(selected, rover: batch.pose!.position, generation: token)
            } else if !scanning { scan(generation: token) }
        case .following, .holdingDistance:
            guard let locked else { return }
            switch tracker.continueTrack(batch.people, previous: locked,
                                         predictedPosition: locked.position, now: now) {
            case .matched(let selected):
                self.locked = selected
                lastPosition = selected.position
                await follow(selected, rover: batch.pose!.position, generation: token)
            case .lost, .ambiguous: await loseTarget(generation: token)
            }
        case .reacquiring:
            guard let deadline = reacquireDeadline, now < deadline, let lastPosition else { return }
            if case .matched(let selected) = tracker.reacquire(batch.people, lastPosition: lastPosition, now: now) {
                if scanning { guard await confirmStop(generation: token) else { return }; scanning = false }
                guard generation == token, clock.now < deadline else { return }
                reacquireDeadline = nil
                deadlineTask?.cancel()
                locked = selected
                self.lastPosition = selected.position
                await follow(selected, rover: batch.pose!.position, generation: token)
            } else if !scanning { scan(generation: token) }
        default: break
        }
    }

    private func follow(_ selected: FollowPersonObservation, rover: Vec2, generation token: UInt64) async {
        guard generation == token else { return }
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
            await perceptionUnavailable(generation: token)
            return
        }
        lastGoal = goal
        lastGoalTime = clock.now
        launchMovement(generation: token) { [motion] in
            await motion.navigate(to: goal, stoppingAtForwardClearance: self.config.minimumHoldDistance)
        }
    }

    private func confirmStop(generation token: UInt64) async -> Bool {
        guard generation == token, !stopBlocked, stopTask == nil else { return false }
        operation &+= 1
        movementTask?.cancel()
        movementTask = nil
        if let confirmationTask {
            let confirmed = await confirmationTask.value
            return confirmed && generation == token && !stopBlocked && stopTask == nil
        }
        let task = Task { [motion] in
            do { try await motion.stopAndConfirm(); return true }
            catch { return false }
        }
        confirmationTask = task
        let confirmed = await task.value
        confirmationTask = nil
        if !confirmed {
            generation &+= 1
            operation &+= 1
            stopBlocked = true
            state = .failed("Rover stop could not be confirmed.")
            framesTask?.cancel()
            safetyTask?.cancel()
            movementTask?.cancel()
            deadlineTask?.cancel()
            poseTask?.cancel()
            return false
        }
        return generation == token && !stopBlocked && stopTask == nil
    }

    private func launchMovement(generation token: UInt64,
                                action: @escaping @MainActor () async -> NavigationResult) {
        operation &+= 1
        let id = operation
        movementTask = Task { [weak self] in
            let result = await action()
            guard let self, self.generation == token, self.operation == id else { return }
            if case .failed = result { _ = await self.finish(.failed("Navigation failed.")) }
        }
    }

    private func scan(generation token: UInt64) {
        guard generation == token, !scanning, !stopBlocked else { return }
        if state == .searching && Double(scanCount) * config.scanIncrement >= config.maximumScanRotation - 0.0001 {
            Task { _ = await finish(.failed("No person found.")) }
            return
        }
        if state == .reacquiring, let deadline = reacquireDeadline, clock.now >= deadline { return }
        scanning = true
        scanCount += 1
        launchMovement(generation: token) { [motion, config] in
            await motion.rotateForScan(by: config.scanIncrement)
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

    private func perceptionUnavailable(generation token: UInt64) async {
        guard generation == token else { return }
        if poseDeadline == nil { poseDeadline = clock.now + config.perceptionRecoverySeconds }
        guard await confirmStop(generation: token) else { return }
        lastGoal = nil
        scanning = false
        let deadline = poseDeadline!
        poseTask?.cancel()
        poseTask = Task { [weak self, clock] in
            await clock.sleep(seconds: max(0, deadline - clock.now))
            guard let self, self.generation == token, self.poseDeadline == deadline,
                  self.clock.now >= deadline else { return }
            _ = await self.finish(.failed("Pose or depth unavailable."))
        }
    }
}
