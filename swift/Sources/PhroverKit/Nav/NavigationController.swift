import Foundation
import RoverNav

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

    private let ar: ARSessionManager
    private let control: RoverControl
    private let planner = AStarPlanner()
    private let pursuit = PursuitController(params: .init(
        wheelBase: RoverConfig.wheelBase,
        goalTolerance: 0.2,
        minimumRotateWheelSpeed: RoverConfig.minimumRotateWheelSpeed))
    private let guardLayer = ObstacleGuard()
    private static let obstacleArrivalDistance = 0.65

    private var loop: Task<Void, Never>?
    private var replanCounter = 0

    public init(ar: ARSessionManager, control: RoverControl) {
        self.ar = ar
        self.control = control
    }

    /// Begin autonomously driving to a nav-plane goal.
    public func navigate(to goal: Vec2) {
        startNavigation(to: goal, stoppingAtForwardClearance: nil)
    }

    /// Drive toward a locked visual target and stop at the requested LiDAR stand-off.
    public func navigate(to goal: Vec2, stoppingAtForwardClearance clearance: Double) {
        startNavigation(to: goal, stoppingAtForwardClearance: clearance)
    }

    private func startNavigation(to goal: Vec2, stoppingAtForwardClearance: Double?) {
        cancel()
        guard let start = ar.pose?.position else {
            state = .failed("No ARKit pose yet — move the device to establish tracking.")
            return
        }
        guard planAndStore(from: start, to: goal) else {
            state = .failed("No path to goal.")
            return
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
        loop = Task {
            await drive(to: goal, stoppingAtForwardClearance: stoppingAtForwardClearance)
        }
    }

    /// Rotate in place by `angle` radians (CCW positive, matching `Pose2D.yaw`) and wait
    /// for it to finish. A pure turn, no path planning — used by the mission agent to scan
    /// for something not currently in view (e.g. up to a full `2 * .pi` look-around).
    /// Uses the same command cadence/watchdog as `drive()`, but does not treat forward
    /// clearance as a hard stop because this is an in-place search turn, not forward motion.
    public func rotate(by angle: Double) async {
        cancel()
        guard let startYaw = ar.pose?.yaw else {
            state = .failed("No ARKit pose yet — move the device to establish tracking.")
            return
        }
        let targetYaw = normalizeAngle(startYaw + angle)
        state = .driving
        let task = Task { await performRotate(to: targetYaw, mode: .continuous) }
        loop = task
        await task.value
    }

    /// Rotate in short pulses for camera-based target search. Stopping between pulses
    /// prevents a 30-degree scan step from sweeping past the object before detection can
    /// process a stable frame.
    public func rotateForScan(by angle: Double) async {
        cancel()
        guard let startYaw = ar.pose?.yaw else {
            state = .failed("No ARKit pose yet — move the device to establish tracking.")
            return
        }
        let targetYaw = normalizeAngle(startYaw + angle)
        state = .driving
        let task = Task { await performRotate(to: targetYaw, mode: .scan) }
        loop = task
        await task.value
    }

    /// Stop and clear the current goal.
    public func cancel() {
        loop?.cancel()
        loop = nil
        Task { try? await control.stop() }
        state = .idle
    }

    // MARK: - Loop

    private func drive(to goal: Vec2, stoppingAtForwardClearance targetStopDistance: Double?) async {
        var hasSentCommand = false
        var consecutiveCommandFailures = 0
        var progressWatchdog = DriveProgressWatchdog(timeout: 2.5, minimumProgress: 0.05)
        while !Task.isCancelled {
            guard let pose = ar.pose else {
                try? await control.stop()
                state = .failed("AR tracking lost during navigation.")
                RuntimeFileLog.append("nav_safety_stop", fields: ["reason": "tracking_lost"])
                return
            }
            let distanceToGoal = pose.position.distance(to: goal)
            let targetApproachDecision = targetStopDistance.map {
                Self.visualTargetApproachDecision(distanceToGoal: distanceToGoal,
                                                  forwardClearance: ar.forwardClearance,
                                                  stopDistance: $0)
            } ?? .inactive

            if case .arrived = targetApproachDecision, let targetStopDistance {
                try? await control.stop()
                state = .arrived
                RuntimeFileLog.append("nav_target_reached", fields: [
                    "brake_trigger_distance": Self.formatMeters(
                        targetStopDistance + RoverConfig.visualTargetBrakeLeadDistance
                    ),
                    "clearance": Self.formatMeters(ar.forwardClearance),
                    "distance_to_goal": Self.formatMeters(distanceToGoal),
                    "stop_distance": Self.formatMeters(targetStopDistance)
                ])
                return
            }

            // Replan every ~1s to fold in newly meshed obstacles.
            replanCounter += 1
            if replanCounter % 10 == 0 { _ = planAndStore(from: pose.position, to: goal) }

            // Safety gate.
            let lastAck = await control.lastAckAt
            let now = Date()
            let decision = guardLayer.evaluate(forwardClearance: ar.forwardClearance,
                                               lastAckAt: lastAck,
                                               now: now,
                                               feedback: nil,
                                               requireFreshAck: hasSentCommand,
                                               checkForwardObstacle: targetApproachDecision == .inactive)
            switch decision {
            case .go:
                break
            case .stopObstacle(let clearance):
                try? await control.stop()
                state = Self.stateAfterObstacleStop(pose: pose, goal: goal, clearance: clearance)
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "obstacle",
                    "clearance": String(format: "%.2f", clearance),
                    "state": state.description
                ])
                return
            case .stopCommsLost:
                try? await control.stop()
                state = .failed("Rover command link lost.")
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "comms_lost",
                    "ack_age": Self.ackAgeField(lastAckAt: lastAck, now: now)
                ])
                return
            case .stopTipping:
                try? await control.stop()
                state = .failed("Rover may be tipping.")
                RuntimeFileLog.append("nav_safety_stop", fields: ["reason": "tipping"])
                return
            }

            let out = pursuit.step(pose: pose, path: path)
            if out.reachedGoal {
                try? await control.stop()
                state = .arrived
                return
            }
            let command = targetApproachDecision == .approach
                ? Self.visualTargetApproachCommand(out.command,
                                                   forwardClearance: ar.forwardClearance,
                                                   stopDistance: targetStopDistance ?? 0)
                : out.command
            let isCommanded = abs(command.left) > 0.01 || abs(command.right) > 0.01
            if progressWatchdog.observe(distanceToGoal: distanceToGoal,
                                        now: now,
                                        commanded: isCommanded) {
                try? await control.stop()
                state = .failed("Navigation stalled.")
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "no_goal_progress",
                    "distance_to_goal": Self.formatMeters(distanceToGoal),
                    "timeout": "2.50"
                ])
                return
            }
            var telemetry = Self.driveTelemetryFields(pose: pose,
                                                       goal: goal,
                                                       command: command,
                                                       consecutiveCommandFailures: consecutiveCommandFailures)
            telemetry["forward_clearance"] = Self.formatMeters(ar.forwardClearance)
            telemetry["path_points"] = "\(path.count)"
            telemetry["target_approach_slowed"] = command == out.command ? "false" : "true"
            RuntimeFileLog.append("nav_drive_tick", fields: telemetry)
            do {
                try await control.sendNavigation(command)
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
                try? await control.stop()
                state = Self.stateAfterCommandFailure(error)
                RuntimeFileLog.append("nav_command_failed", fields: [
                    "error": error.localizedDescription,
                    "state": state.description
                ])
                return
            }
            try? await Task.sleep(for: .seconds(RoverConfig.commandInterval))
        }
        try? await control.stop()
    }

    @discardableResult
    private func planAndStore(from: Vec2, to: Vec2) -> Bool {
        let costmap = CostmapBuilder.build(from: ar.meshAnchors, center: from)
        guard let p = planner.plan(from: from, to: to, in: costmap) else { return false }
        path = p
        return true
    }

    private func performRotate(to targetYaw: Double, mode: RotationMode) async {
        let angularTolerance = mode == .scan ? RoverConfig.scanTurnYawTolerance : 0.05
        var hasSentCommand = false
        while !Task.isCancelled {
            guard let pose = ar.pose else {
                try? await control.stop()
                state = .failed("AR tracking lost during rotation.")
                RuntimeFileLog.append("nav_safety_stop", fields: ["reason": "tracking_lost_while_rotating"])
                return
            }
            let error = normalizeAngle(targetYaw - pose.yaw)
            if abs(error) <= angularTolerance {
                try? await control.stop()
                state = .arrived
                return
            }

            let lastAck = await control.lastAckAt
            let now = Date()
            let decision = guardLayer.evaluate(forwardClearance: ar.forwardClearance,
                                               lastAckAt: lastAck,
                                               now: now,
                                               feedback: nil,
                                               requireFreshAck: hasSentCommand,
                                               checkForwardObstacle: false)
            switch decision {
            case .go:
                break
            case .stopObstacle(let clearance):
                try? await control.stop()
                state = .failed(Self.obstacleMessage(clearance: clearance))
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "obstacle_while_rotating",
                    "clearance": String(format: "%.2f", clearance)
                ])
                return
            case .stopCommsLost:
                try? await control.stop()
                state = .failed("Rover command link lost.")
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "comms_lost_while_rotating",
                    "ack_age": Self.ackAgeField(lastAckAt: lastAck, now: now)
                ])
                return
            case .stopTipping:
                try? await control.stop()
                state = .failed("Rover may be tipping.")
                RuntimeFileLog.append("nav_safety_stop", fields: ["reason": "tipping_while_rotating"])
                return
            }

            let cmd = RotationCommand.command(forYawError: error)
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
                try await control.sendNavigation(cmd)
                hasSentCommand = true
            } catch {
                try? await control.stop()
                state = Self.stateAfterCommandFailure(error)
                RuntimeFileLog.append("nav_command_failed", fields: [
                    "error": error.localizedDescription,
                    "state": state.description
                ])
                return
            }
            if mode == .scan {
                try? await Task.sleep(for: .seconds(RoverConfig.scanTurnPulseDuration))
                try? await control.stop()
                RuntimeFileLog.append("nav_scan_turn_settle", fields: [
                    "settle_seconds": String(format: "%.2f", RoverConfig.scanTurnSettleDuration)
                ])
                try? await Task.sleep(for: .seconds(RoverConfig.scanTurnSettleDuration))
            } else {
                try? await Task.sleep(for: .seconds(RoverConfig.commandInterval))
            }
        }
        try? await control.stop()
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
