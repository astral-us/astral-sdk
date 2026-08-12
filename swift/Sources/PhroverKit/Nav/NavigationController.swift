import Foundation
import RoverNav

public enum NavigationSafetyState: Equatable, Sendable {
    case idle
    case moving
    case failed(NavigationFailure)
}

/// Autonomy orchestrator. Runs the closed loop:
///
///   ARKit pose ─┐
///   LiDAR mesh ─┼─► CostmapBuilder ─► AStarPlanner ─► path
///               │                                      │
///   depth ──► ObstacleGuard ──(safe?)──► PursuitController.step(pose, path) ─► WheelCommand ─► RoverControl
///
/// The loop is closed on ARKit visual-inertial pose (no wheel encoders). Replans
/// periodically so newly-seen obstacles (from the growing mesh) are respected.
@Observable
@MainActor
public final class NavigationController {
    public enum State: Equatable, Sendable { case idle, planning, driving, arrived, failed(String) }
    enum VisualTargetApproachDecision: Equatable { case inactive, approach, arrived }
    private enum RotationMode { case continuous, scan }

    public private(set) var state: State = .idle
    public private(set) var path: [Vec2] = []
    public private(set) var safetyState: NavigationSafetyState = .idle

    private let currentPose: () -> Pose2D?
    private let currentForwardClearance: () -> Double
    private let makePlan: (Vec2, Vec2) -> [Vec2]?
    private let currentLastAck: () async -> Date?
    private let sendCommand: (WheelCommand) async throws -> Void
    private let stopRover: () async throws -> Void
    private let sleep: (Duration) async -> Void
    private let now: () -> Date
    private let pursuit = PursuitController(params: .init(
        wheelBase: RoverConfig.wheelBase,
        goalTolerance: 0.2,
        minimumRotateWheelSpeed: RoverConfig.minimumRotateWheelSpeed))
    private let guardLayer = ObstacleGuard()
    private static let obstacleArrivalDistance = 0.65

    private var loop: Task<NavigationResult, Never>?
    private var operationGeneration: UInt = 0
    private var replanCounter = 0
    private var activePolicy: (any PathAdmissibilityPolicy)?
    private var safetyStateContinuations: [UUID: AsyncStream<NavigationSafetyState>.Continuation] = [:]

    public func safetyStates() -> AsyncStream<NavigationSafetyState> {
        let id = UUID()
        return AsyncStream { continuation in
            safetyStateContinuations[id] = continuation
            continuation.yield(safetyState)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.safetyStateContinuations[id] = nil }
            }
        }
    }

    public init(ar: ARSessionManager, control: RoverControl) {
        let planner = AStarPlanner()
        currentPose = { ar.pose }
        currentForwardClearance = { ar.forwardClearance }
        makePlan = { start, goal in
            let costmap = CostmapBuilder.build(from: ar.meshAnchors, center: start)
            return planner.plan(from: start, to: goal, in: costmap)
        }
        currentLastAck = { await control.lastAckAt }
        sendCommand = { try await control.sendNavigation($0) }
        stopRover = { try await control.stop() }
        sleep = { try? await Task.sleep(for: $0) }
        now = Date.init
    }

    init(currentPose: @escaping () -> Pose2D?,
         forwardClearance: @escaping () -> Double,
         plan: @escaping (Vec2, Vec2) -> [Vec2]?,
         lastAckAt: @escaping () async -> Date?,
         sendCommand: @escaping (WheelCommand) async throws -> Void,
         stopRover: @escaping () async throws -> Void,
         sleep: @escaping (Duration) async -> Void,
         now: @escaping () -> Date = Date.init) {
        self.currentPose = currentPose
        self.currentForwardClearance = forwardClearance
        self.makePlan = plan
        self.currentLastAck = lastAckAt
        self.sendCommand = sendCommand
        self.stopRover = stopRover
        self.sleep = sleep
        self.now = now
    }

    /// Begin autonomously driving to a nav-plane goal.
    public func navigate(to goal: Vec2) {
        startNavigation(to: goal, stoppingAtForwardClearance: nil, policy: nil)
    }

    /// Drive toward a locked visual target and stop at the requested LiDAR stand-off.
    public func navigate(to goal: Vec2, stoppingAtForwardClearance clearance: Double) {
        startNavigation(to: goal, stoppingAtForwardClearance: clearance, policy: nil)
    }

    public func navigateAndWait(
        to goal: Vec2,
        stoppingAtForwardClearance clearance: Double? = nil,
        policy: (any PathAdmissibilityPolicy)? = nil
    ) async -> NavigationResult {
        operationGeneration &+= 1
        let reservation = operationGeneration
        await cancelAndWait()
        guard operationGeneration == reservation else { return .cancelled }
        return await startNavigation(
            to: goal, stoppingAtForwardClearance: clearance, policy: policy, cancellingCurrent: false
        ).value
    }

    @discardableResult
    private func startNavigation(
        to goal: Vec2,
        stoppingAtForwardClearance: Double?,
        policy: (any PathAdmissibilityPolicy)?,
        cancellingCurrent: Bool = true
    ) -> Task<NavigationResult, Never> {
        if cancellingCurrent { cancel() }
        operationGeneration &+= 1
        replanCounter = 0
        activePolicy = policy
        guard let start = currentPose()?.position else {
            let result = NavigationResult.failed(.noPose)
            finish(result)
            return Task { result }
        }
        if let failure = planAndStore(from: start, to: goal, policy: policy) {
            let result = NavigationResult.failed(failure)
            finish(result)
            return Task { result }
        }
        RuntimeFileLog.append("nav_goal_start", fields: [
            "goal_x": Self.formatMeters(goal.x),
            "goal_y": Self.formatMeters(goal.y),
            "pose_x": Self.formatMeters(start.x),
            "pose_y": Self.formatMeters(start.y),
            "distance_to_goal": Self.formatMeters(start.distance(to: goal)),
            "target_stop_clearance": stoppingAtForwardClearance.map(Self.formatMeters) ?? "none"
        ])
        state = .driving
        publishSafetyState(.moving)
        let task = Task { await drive(to: goal, stoppingAtForwardClearance: stoppingAtForwardClearance) }
        loop = task
        return task
    }

    /// Rotate in place by `angle` radians (CCW positive, matching `Pose2D.yaw`) and wait
    /// for it to finish. A pure turn, no path planning — used by the mission agent to scan
    /// for something not currently in view (e.g. up to a full `2 * .pi` look-around).
    /// Uses the same command cadence/watchdog as `drive()`, but does not treat forward
    /// clearance as a hard stop because this is an in-place search turn, not forward motion.
    public func rotate(by angle: Double) async {
        _ = await rotateAndWait(by: angle)
    }

    public func rotateAndWait(by angle: Double) async -> NavigationResult {
        operationGeneration &+= 1
        let reservation = operationGeneration
        await cancelAndWait()
        guard operationGeneration == reservation else { return .cancelled }
        operationGeneration &+= 1
        guard let startYaw = currentPose()?.yaw else {
            let result = NavigationResult.failed(.noPose)
            finish(result)
            return result
        }
        let targetYaw = normalizeAngle(startYaw + angle)
        state = .driving
        publishSafetyState(.moving)
        let task = Task { await performRotate(to: targetYaw, mode: .continuous) }
        loop = task
        return await task.value
    }

    /// Rotate in short pulses for camera-based target search. Stopping between pulses
    /// prevents a 30-degree scan step from sweeping past the object before detection can
    /// process a stable frame.
    public func rotateForScan(by angle: Double) async {
        cancel()
        operationGeneration &+= 1
        guard let startYaw = currentPose()?.yaw else {
            state = .failed("No ARKit pose yet — move the device to establish tracking.")
            publishSafetyState(.failed(.noPose))
            return
        }
        let targetYaw = normalizeAngle(startYaw + angle)
        state = .driving
        publishSafetyState(.moving)
        let task = Task { await performRotate(to: targetYaw, mode: .scan) }
        loop = task
        _ = await task.value
    }

    /// Stop and clear the current goal.
    public func cancel() {
        operationGeneration &+= 1
        loop?.cancel()
        loop = nil
        activePolicy = nil
        path = []
        Task { try? await stopRover() }
        // Without this, an external cancel (e.g. a hard-stop bypassing the brain) leaves
        // `state` at `.driving` forever, so anything polling `state == .driving` to know
        // when motion has settled never returns.
        state = .idle
        publishSafetyState(.idle)
    }

    public func cancelAndWait() async {
        let generation = operationGeneration
        let task = loop
        task?.cancel()
        _ = await task?.value
        guard operationGeneration == generation else { return }
        try? await stopRover()
        guard operationGeneration == generation else { return }
        loop = nil
        activePolicy = nil
        path = []
        state = .idle
        publishSafetyState(.idle)
    }

    // MARK: - Loop

    private func drive(to goal: Vec2, stoppingAtForwardClearance targetStopDistance: Double?) async -> NavigationResult {
        var hasSentCommand = false
        var consecutiveCommandFailures = 0
        var progressWatchdog = DriveProgressWatchdog(timeout: 2.5, minimumProgress: 0.05)
        while !Task.isCancelled {
            guard let pose = currentPose() else {
                try? await stopRover()
                path = []
                let result = NavigationResult.failed(.trackingLost)
                finish(result)
                return result
            }
            let distanceToGoal = pose.position.distance(to: goal)
            let targetApproachDecision = targetStopDistance.map {
                Self.visualTargetApproachDecision(distanceToGoal: distanceToGoal,
                                                  forwardClearance: currentForwardClearance(),
                                                  stopDistance: $0)
            } ?? .inactive

            if case .arrived = targetApproachDecision, let targetStopDistance {
                try? await stopRover()
                let result = NavigationResult.arrived
                finish(result)
                RuntimeFileLog.append("nav_target_reached", fields: [
                    "brake_trigger_distance": Self.formatMeters(
                        targetStopDistance + RoverConfig.visualTargetBrakeLeadDistance
                    ),
                    "clearance": Self.formatMeters(currentForwardClearance()),
                    "distance_to_goal": Self.formatMeters(distanceToGoal),
                    "stop_distance": Self.formatMeters(targetStopDistance)
                ])
                return result
            }

            // Replan every ~1s to fold in newly meshed obstacles.
            replanCounter += 1
            if replanCounter % 10 == 0,
               let failure = planAndStore(from: pose.position, to: goal, policy: activePolicy) {
                try? await stopRover()
                path = []
                let result = NavigationResult.failed(failure)
                finish(result)
                return result
            }

            // Safety gate.
            let lastAck = await currentLastAck()
            let now = Date()
            let decision = guardLayer.evaluate(forwardClearance: currentForwardClearance(),
                                               lastAckAt: lastAck,
                                               now: now,
                                               feedback: nil,
                                               requireFreshAck: hasSentCommand,
                                               checkForwardObstacle: targetApproachDecision == .inactive)
            switch decision {
            case .go:
                break
            case .stopObstacle(let clearance):
                try? await stopRover()
                state = Self.stateAfterObstacleStop(pose: pose, goal: goal, clearance: clearance)
                if case .failed = state { publishSafetyState(.failed(.obstacle)) }
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "obstacle",
                    "clearance": String(format: "%.2f", clearance),
                    "state": state.description
                ])
                activePolicy = nil
                return state == .arrived ? .arrived : .failed(.obstacle)
            case .stopCommsLost:
                try? await stopRover()
                let result = NavigationResult.failed(.commsLost)
                finish(result)
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "comms_lost",
                    "ack_age": Self.ackAgeField(lastAckAt: lastAck, now: now)
                ])
                return result
            case .stopTipping:
                try? await stopRover()
                let result = NavigationResult.failed(.tipping)
                finish(result)
                RuntimeFileLog.append("nav_safety_stop", fields: ["reason": "tipping"])
                return result
            }

            let out = pursuit.step(pose: pose, path: path)
            if out.reachedGoal {
                try? await stopRover()
                let result = NavigationResult.arrived
                finish(result)
                return result
            }
            let command = targetApproachDecision == .approach
                ? Self.visualTargetApproachCommand(out.command,
                                                   forwardClearance: currentForwardClearance(),
                                                   stopDistance: targetStopDistance ?? 0)
                : out.command
            let isCommanded = abs(command.left) > 0.01 || abs(command.right) > 0.01
            if progressWatchdog.observe(distanceToGoal: distanceToGoal,
                                        now: now,
                                        commanded: isCommanded) {
                try? await stopRover()
                let result = NavigationResult.failed(.stalled)
                finish(result)
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "no_goal_progress",
                    "distance_to_goal": Self.formatMeters(distanceToGoal),
                    "timeout": "2.50"
                ])
                return result
            }
            var telemetry = Self.driveTelemetryFields(pose: pose,
                                                       goal: goal,
                                                       command: command,
                                                       consecutiveCommandFailures: consecutiveCommandFailures)
            telemetry["forward_clearance"] = Self.formatMeters(currentForwardClearance())
            telemetry["path_points"] = "\(path.count)"
            telemetry["target_approach_slowed"] = command == out.command ? "false" : "true"
            RuntimeFileLog.append("nav_drive_tick", fields: telemetry)
            do {
                try await sendCommand(command)
                consecutiveCommandFailures = 0
                hasSentCommand = true
            } catch {
                consecutiveCommandFailures += 1
                RuntimeFileLog.append("nav_command_send_failed", fields: Self.driveTelemetryFields(
                    pose: pose,
                    goal: goal,
                    command: command,
                    consecutiveCommandFailures: consecutiveCommandFailures
                ).merging([
                    "error": error.localizedDescription,
                    "max_failures": "1"
                ]) { current, _ in current })
                try? await stopRover()
                state = Self.stateAfterCommandFailure(error)
                publishSafetyState(.failed(.commandFailed))
                RuntimeFileLog.append("nav_command_failed", fields: [
                    "error": error.localizedDescription,
                    "state": state.description
                ])
                activePolicy = nil
                return .failed(.commandFailed)
            }
            await sleep(.seconds(RoverConfig.commandInterval))
        }
        try? await stopRover()
        activePolicy = nil
        return .cancelled
    }

    private func planAndStore(
        from: Vec2,
        to: Vec2,
        policy: (any PathAdmissibilityPolicy)?
    ) -> NavigationFailure? {
        guard let p = makePlan(from, to) else { return .noPath }
        if let policy,
           case .rejected(let violation) = policy.evaluate(path: [from] + p + [to]) {
            return .pathRejected(violation)
        }
        path = p
        return nil
    }

    private func performRotate(to targetYaw: Double, mode: RotationMode) async -> NavigationResult {
        let angularTolerance = mode == .scan ? RoverConfig.scanTurnYawTolerance : 0.05
        var hasSentCommand = false
        var progressWatchdog = DriveProgressWatchdog(timeout: 2.5, minimumProgress: 0.05)
        while !Task.isCancelled {
            guard let pose = currentPose() else {
                try? await stopRover()
                let result = NavigationResult.failed(.trackingLost)
                finish(result)
                return result
            }
            let error = normalizeAngle(targetYaw - pose.yaw)
            if abs(error) <= angularTolerance {
                try? await stopRover()
                let result = NavigationResult.arrived
                finish(result)
                return result
            }

            let lastAck = await currentLastAck()
            let now = now()
            let decision = guardLayer.evaluate(forwardClearance: currentForwardClearance(),
                                               lastAckAt: lastAck,
                                               now: now,
                                               feedback: nil,
                                               requireFreshAck: hasSentCommand,
                                               checkForwardObstacle: false)
            switch decision {
            case .go:
                break
            case .stopObstacle(let clearance):
                try? await stopRover()
                state = .failed(Self.obstacleMessage(clearance: clearance))
                publishSafetyState(.failed(.obstacle))
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "obstacle_while_rotating",
                    "clearance": String(format: "%.2f", clearance)
                ])
                return .failed(.obstacle)
            case .stopCommsLost:
                try? await stopRover()
                let result = NavigationResult.failed(.commsLost)
                finish(result)
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "comms_lost_while_rotating",
                    "ack_age": Self.ackAgeField(lastAckAt: lastAck, now: now)
                ])
                return result
            case .stopTipping:
                try? await stopRover()
                let result = NavigationResult.failed(.tipping)
                finish(result)
                RuntimeFileLog.append("nav_safety_stop", fields: ["reason": "tipping_while_rotating"])
                return result
            }

            let cmd = RotationCommand.command(forYawError: error)
            if progressWatchdog.observe(distanceToGoal: abs(error), now: now, commanded: true) {
                try? await stopRover()
                let result = NavigationResult.failed(.stalled)
                finish(result)
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "no_yaw_progress",
                    "target_yaw_deg": Self.formatDegrees(targetYaw),
                    "yaw_error_deg": Self.formatDegrees(error),
                    "timeout": "2.50"
                ])
                return result
            }
            RuntimeFileLog.append("nav_rotate_tick", fields: [
                "pose_x": Self.formatMeters(pose.position.x),
                "pose_y": Self.formatMeters(pose.position.y),
                "pose_yaw_deg": Self.formatDegrees(pose.yaw),
                "target_yaw_deg": Self.formatDegrees(targetYaw),
                "yaw_error_deg": Self.formatDegrees(error),
                "mode": mode == .scan ? "scan_pulse" : "continuous",
                "wheel_left": Self.formatMeters(cmd.left),
                "wheel_right": Self.formatMeters(cmd.right)
            ])
            do {
                try await sendCommand(cmd)
                hasSentCommand = true
            } catch {
                try? await stopRover()
                state = Self.stateAfterCommandFailure(error)
                publishSafetyState(.failed(.commandFailed))
                RuntimeFileLog.append("nav_command_failed", fields: [
                    "error": error.localizedDescription,
                    "state": state.description
                ])
                return .failed(.commandFailed)
            }
            if mode == .scan {
                await sleep(.seconds(RoverConfig.scanTurnPulseDuration))
                try? await stopRover()
                RuntimeFileLog.append("nav_scan_turn_settle", fields: [
                    "settle_seconds": String(format: "%.2f", RoverConfig.scanTurnSettleDuration)
                ])
                await sleep(.seconds(RoverConfig.scanTurnSettleDuration))
            } else {
                await sleep(.seconds(RoverConfig.commandInterval))
            }
        }
        try? await stopRover()
        return .cancelled
    }

    private func finish(_ result: NavigationResult) {
        activePolicy = nil
        switch result {
        case .arrived:
            state = .arrived
            publishSafetyState(.idle)
        case .cancelled:
            state = .idle
            publishSafetyState(.idle)
        case .failed(let failure):
            state = .failed(Self.message(for: failure))
            publishSafetyState(.failed(failure))
        }
    }

    private func publishSafetyState(_ newState: NavigationSafetyState) {
        guard safetyState != newState else { return }
        safetyState = newState
        for continuation in safetyStateContinuations.values { continuation.yield(newState) }
    }

    private static func message(for failure: NavigationFailure) -> String {
        switch failure {
        case .noPose: "No ARKit pose yet — move the device to establish tracking."
        case .noPath: "No path to goal."
        case .pathRejected: "Path rejected by navigation policy."
        case .obstacle: "Obstacle ahead."
        case .commsLost: "Rover command link lost."
        case .tipping: "Rover may be tipping."
        case .stalled: "Navigation stalled."
        case .commandFailed: "Rover command failed."
        case .trackingLost: "ARKit tracking lost."
        case .cancelled: "Navigation cancelled."
        }
    }

    static func stateAfterObstacleStop(pose: Pose2D, goal: Vec2, clearance: Double) -> State {
        if pose.position.distance(to: goal) <= obstacleArrivalDistance {
            return .arrived
        }
        return .failed(obstacleMessage(clearance: clearance))
    }

    static func visualTargetApproachDecision(distanceToGoal: Double,
                                             forwardClearance: Double,
                                             stopDistance: Double) -> VisualTargetApproachDecision {
        guard distanceToGoal <= RoverConfig.visualTargetApproachDistance else { return .inactive }
        let brakeTriggerDistance = stopDistance + RoverConfig.visualTargetBrakeLeadDistance
        guard forwardClearance.isFinite,
              forwardClearance <= brakeTriggerDistance else {
            return .approach
        }
        return .arrived
    }

    static func visualTargetApproachCommand(_ command: WheelCommand,
                                            forwardClearance: Double,
                                            stopDistance: Double) -> WheelCommand {
        guard forwardClearance.isFinite,
              forwardClearance > stopDistance + RoverConfig.visualTargetBrakeLeadDistance,
              forwardClearance <= RoverConfig.visualTargetSlowdownDistance,
              command.left >= 0,
              command.right >= 0 else {
            return command
        }

        let peak = max(command.left, command.right)
        guard peak > RoverConfig.visualTargetApproachMaxWheelSpeed else { return command }
        let scale = RoverConfig.visualTargetApproachMaxWheelSpeed / peak
        return WheelCommand(left: command.left * scale, right: command.right * scale)
    }

    static func stateAfterCommandFailure(_ error: Error) -> State {
        .failed("Rover command failed: \(error.localizedDescription)")
    }

    static func driveTelemetryFields(pose: Pose2D,
                                     goal: Vec2,
                                     command: WheelCommand,
                                     consecutiveCommandFailures: Int) -> [String: String] {
        [
            "goal_x": formatMeters(goal.x),
            "goal_y": formatMeters(goal.y),
            "pose_x": formatMeters(pose.position.x),
            "pose_y": formatMeters(pose.position.y),
            "pose_yaw_deg": formatDegrees(pose.yaw),
            "distance_to_goal": formatMeters(pose.position.distance(to: goal)),
            "wheel_left": formatMeters(command.left),
            "wheel_right": formatMeters(command.right),
            "command_failures": "\(consecutiveCommandFailures)"
        ]
    }

    static func ackAgeField(lastAckAt: Date?, now: Date = Date()) -> String {
        guard let lastAckAt else { return "none" }
        return String(format: "%.2f", now.timeIntervalSince(lastAckAt))
    }

    private static func obstacleMessage(clearance: Double) -> String {
        String(format: "Obstacle ahead at %.2f m.", clearance)
    }

    private static func formatMeters(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func formatDegrees(_ radians: Double) -> String {
        String(format: "%.0f", radians * 180 / .pi)
    }
}

extension NavigationController.State: CustomStringConvertible {
    public var description: String {
        switch self {
        case .idle: return "idle"
        case .planning: return "planning"
        case .driving: return "driving"
        case .arrived: return "arrived"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}
