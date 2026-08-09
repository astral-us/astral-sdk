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
    public private(set) var state: State = .idle
    public private(set) var path: [Vec2] = []

    private let ar: ARSessionManager
    private let control: RoverControl
    private let planner = AStarPlanner()
    private let pursuit = PursuitController(params: .init(
        wheelBase: RoverConfig.wheelBase,
        goalTolerance: 0.2,
        minimumRotateWheelSpeed: RoverConfig.minimumRotateWheelSpeed))
    private let guardLayer: ObstacleGuard
    private let safetyFeedback: () -> RoverFeedback?
    private let depthSafetyObservation: (WheelCommand) -> DepthSafetyObservation

    private var loop: Task<Void, Never>?
    private var replanCounter = 0
    private let trackingRecoveryTimeout: TimeInterval
    private let scanDepthRecoveryTimeout: TimeInterval

    static func awaitScanRotationTask(
        _ task: Task<Void, Never>,
        stop: @escaping @MainActor () async -> Void
    ) async {
        await withTaskCancellationHandler {
            await task.value
            guard Task.isCancelled else { return }
            task.cancel()
            await task.value
            await stop()
        } onCancel: {
            task.cancel()
        }
    }

    public convenience init(
        ar: ARSessionManager,
        control: RoverControl,
        trackingRecoveryTimeout: TimeInterval = RoverConfig.navigationTrackingRecoveryTimeout,
        scanDepthRecoveryTimeout: TimeInterval = RoverConfig.scanDepthRecoveryTimeout
    ) {
        self.init(
            ar: ar,
            control: control,
            trackingRecoveryTimeout: trackingRecoveryTimeout,
            scanDepthRecoveryTimeout: scanDepthRecoveryTimeout,
            guardLayer: ObstacleGuard(),
            safetyFeedback: { nil },
            depthSafetyObservation: { ar.depthSafetyObservation(for: $0) }
        )
    }

    init(
        ar: ARSessionManager,
        control: RoverControl,
        trackingRecoveryTimeout: TimeInterval,
        scanDepthRecoveryTimeout: TimeInterval,
        guardLayer: ObstacleGuard,
        safetyFeedback: @escaping () -> RoverFeedback?,
        depthSafetyObservation: @escaping (WheelCommand) -> DepthSafetyObservation
    ) {
        self.ar = ar
        self.control = control
        self.trackingRecoveryTimeout = trackingRecoveryTimeout
        self.scanDepthRecoveryTimeout = scanDepthRecoveryTimeout
        self.guardLayer = guardLayer
        self.safetyFeedback = safetyFeedback
        self.depthSafetyObservation = depthSafetyObservation
    }

    /// Begin autonomously driving to a nav-plane goal.
    public func navigate(to goal: Vec2) {
        startNavigation(to: goal, stoppingAtForwardClearance: nil)
    }

    /// Drive toward a locked visual target and stop at the requested LiDAR stand-off.
    public func navigate(to goal: Vec2, stoppingAtForwardClearance clearance: Double) {
        startNavigation(to: goal, stoppingAtForwardClearance: clearance)
    }

    public func assessGoal(_ goal: Vec2) -> NavigationGoalAssessment {
        guard let start = ar.pose?.position else {
            return NavigationGoalAssessment(goal: goal, isReachable: false, pathDistance: .infinity)
        }
        let costmap = CostmapBuilder.build(from: ar.meshAnchors, center: start)
        guard let candidatePath = planner.plan(from: start, to: goal, in: costmap) else {
            return NavigationGoalAssessment(goal: goal, isReachable: false, pathDistance: .infinity)
        }
        let distance = zip(candidatePath, candidatePath.dropFirst()).reduce(0) {
            $0 + $1.0.distance(to: $1.1)
        }
        return NavigationGoalAssessment(goal: goal, isReachable: true, pathDistance: distance)
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
        await stopAndWait()
        guard let startYaw = ar.pose?.yaw else {
            state = .failed("No ARKit pose yet — move the device to establish tracking.")
            return
        }
        let targetYaw = normalizeAngle(startYaw + angle)
        state = .driving
        let task = Task { await performContinuousRotation(to: targetYaw) }
        loop = task
        await task.value
    }

    /// Rotate in short pulses for camera-based target search. Stopping between pulses
    /// prevents a 30-degree scan step from sweeping past the object before detection can
    /// process a stable frame.
    public func rotateForScan(by angle: Double) async {
        await stopAndWait()
        guard await waitForUsableTracking(), let startPose = ar.pose else {
            state = .failed("AR tracking is not ready — keep the phone still and try again.")
            return
        }

        ar.beginRelativeHeadingMeasurement()
        guard await waitForReliableRelativeHeading() != nil else {
            ar.endRelativeHeadingMeasurement()
            state = .failed("Relative heading is not ready — keep the phone still and try again.")
            return
        }

        state = .driving
        let task = Task {
            await performScanRotation(
                from: startPose,
                requestedScanAngle: normalizeAngle(angle)
            )
        }
        loop = task
        await Self.awaitScanRotationTask(task) { [control] in
            try? await control.stop()
        }
        if Task.isCancelled {
            state = .idle
        }
    }

    /// Stop and clear the current goal.
    public func cancel() {
        loop?.cancel()
        loop = nil
        Task { try? await control.stop() }
        // Without this, an external cancel (e.g. a hard-stop bypassing the brain) leaves
        // `state` at `.driving` forever, so anything polling `state == .driving` to know
        // when motion has settled never returns.
        state = .idle
    }

    public func stopAndWait() async {
        let activeLoop = loop
        activeLoop?.cancel()
        loop = nil
        await activeLoop?.value
        try? await control.stop()
        state = .idle
    }

    // MARK: - Loop

    private func drive(to goal: Vec2, stoppingAtForwardClearance targetStopDistance: Double?) async {
        var hasSentCommand = false
        var consecutiveCommandFailures = 0
        var progressWatchdog = DriveProgressWatchdog(timeout: 2.5, minimumProgress: 0.05)
        while !Task.isCancelled {
            guard await waitForUsableTracking(), let pose = ar.pose else {
                try? await control.stop()
                if !Task.isCancelled {
                    state = .failed("AR tracking did not recover in time.")
                    RuntimeFileLog.append("nav_safety_stop", fields: ["reason": "tracking_unavailable"])
                }
                return
            }
            let distanceToGoal = pose.position.distance(to: goal)
            let isTargetApproach = targetStopDistance != nil
                && distanceToGoal <= RoverConfig.visualTargetApproachDistance

            // Replan every ~1s to fold in newly meshed obstacles.
            replanCounter += 1
            if replanCounter % 10 == 0,
               !planAndStore(from: pose.position, to: goal) {
                try? await control.stop()
                state = .failed("No path to goal after replanning.")
                RuntimeFileLog.append("nav_safety_stop", fields: [
                    "reason": "replan_failed",
                    "distance_to_goal": Self.formatMeters(distanceToGoal)
                ])
                return
            }

            // Safety gate.
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
                // Probe the forward envelope without sending motion so stale or blind depth
                // cannot turn an unsafe stop into a successful arrival.
                let arrivalProbe = WheelCommand(left: 0.02, right: 0.02)
                let arrivalSafety = ar.depthSafetyObservation(for: arrivalProbe)
                switch guardLayer.evaluate(command: arrivalProbe, depthSafety: arrivalSafety) {
                case .allow(_, _):
                    try? await control.stop()
                    state = .arrived
                case .stopDepth(let observation):
                    try? await control.stop()
                    let reason = observation.state.telemetryReason
                    state = .failed("Depth safety stop at arrival: \(reason).")
                    RuntimeFileLog.append("nav_safety_stop", fields: [
                        "reason": "depth_safety_at_arrival",
                        "depth_state": reason,
                        "depth_age": Self.formatSeconds(observation.sampleAge),
                        "support_count": "\(observation.supportCount)"
                    ])
                }
                return
            }
            let plannedCommand: WheelCommand
            if isTargetApproach {
                let maximum = max(abs(out.command.left), abs(out.command.right))
                let scale = maximum > RoverConfig.visualTargetApproachMaxWheelSpeed
                    ? RoverConfig.visualTargetApproachMaxWheelSpeed / maximum
                    : 1
                plannedCommand = WheelCommand(
                    left: out.command.left * scale,
                    right: out.command.right * scale
                )
            } else {
                plannedCommand = out.command
            }
            let command: WheelCommand
            let depthSafety: DepthSafetyObservation
            if DepthSafetyMotionClass.classify(plannedCommand) == .rotating {
                guard let recoveredCommand = await rotationSafetyCommand(
                    plannedCommand,
                    hasSentCommand: hasSentCommand
                ) else { return }
                command = recoveredCommand
                depthSafety = depthSafetyObservation(recoveredCommand)
            } else {
                depthSafety = depthSafetyObservation(plannedCommand)
                switch guardLayer.evaluate(command: plannedCommand, depthSafety: depthSafety) {
                case .allow(let safeCommand, _):
                    command = safeCommand
                case .stopDepth(let observation):
                    try? await control.stop()
                    let reason = observation.state.telemetryReason
                    state = .failed("Depth safety stop: \(reason).")
                    RuntimeFileLog.append("nav_safety_stop", fields: [
                        "reason": "depth_safety",
                        "depth_state": reason,
                        "clearance": Self.formatMeters(observation.clearance),
                        "depth_age": Self.formatSeconds(observation.sampleAge),
                        "support_count": "\(observation.supportCount)",
                        "motion_class": observation.motionClass.rawValue
                    ])
                    return
                }
            }
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
            telemetry["depth_safety_state"] = depthSafety.state.telemetryReason
            telemetry["depth_safety_clearance"] = Self.formatMeters(depthSafety.clearance)
            telemetry["depth_safety_age"] = Self.formatSeconds(depthSafety.sampleAge)
            telemetry["depth_safety_support"] = "\(depthSafety.supportCount)"
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

    private func waitForUsableTracking() async -> Bool {
        if Self.isNavigationObservationUsable(ar.latestObservation) { return true }
        try? await control.stop()
        let deadline = Date().addingTimeInterval(trackingRecoveryTimeout)
        while !Task.isCancelled, Date() < deadline {
            if Self.isNavigationObservationUsable(ar.latestObservation) { return true }
            try? await Task.sleep(for: .seconds(RoverConfig.navigationTrackingPollInterval))
        }
        return false
    }

    static func isNavigationObservationUsable(
        _ observation: PoseObservation?,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard let observation, observation.trackingQuality == .normal else { return false }
        return uptime - observation.timestamp <= RoverConfig.navigationTrackingFreshness
    }

    @discardableResult
    private func planAndStore(from: Vec2, to: Vec2) -> Bool {
        let costmap = CostmapBuilder.build(from: ar.meshAnchors, center: from)
        guard let p = planner.plan(from: from, to: to, in: costmap) else {
            path.removeAll()
            return false
        }
        path = p
        return true
    }

    private func performContinuousRotation(to targetYaw: Double) async {
        var hasSentCommand = false
        while !Task.isCancelled {
            guard let pose = ar.pose else {
                try? await control.stop()
                state = .failed("AR tracking pose became unavailable during rotation.")
                return
            }
            let error = normalizeAngle(targetYaw - pose.yaw)
            if abs(error) <= 0.05 {
                try? await control.stop()
                state = .arrived
                return
            }
            let plannedCommand = RotationCommand.command(forYawError: error)
            guard let cmd = await rotationSafetyCommand(
                plannedCommand,
                hasSentCommand: hasSentCommand
            ) else { return }
            RuntimeFileLog.append("nav_rotate_tick", fields: [
                "pose_x": Self.formatMeters(pose.position.x),
                "pose_y": Self.formatMeters(pose.position.y),
                "pose_yaw_deg": Self.formatDegrees(pose.yaw),
                "target_yaw_deg": Self.formatDegrees(targetYaw),
                "yaw_error_deg": Self.formatDegrees(error),
                "mode": "continuous",
                "heading_source": "arkit",
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
            try? await Task.sleep(for: .seconds(RoverConfig.commandInterval))
        }
        try? await control.stop()
    }

    private func performScanRotation(from scanStartPose: Pose2D,
                                     requestedScanAngle: Double) async {
        defer { ar.endRelativeHeadingMeasurement() }
        var scanPulseCount = 0
        var hasSentCommand = false

        while !Task.isCancelled {
            guard let pose = ar.pose else {
                try? await control.stop()
                state = .failed("AR tracking pose became unavailable during rotation.")
                return
            }
            let measurement = ar.relativeHeadingMeasurement()
            guard measurement.reliability == .reliable else {
                try? await control.stop()
                state = .failed(Self.relativeHeadingFailureMessage(measurement.reliability))
                RuntimeFileLog.append("nav_scan_heading_unreliable", fields: [
                    "reason": Self.relativeHeadingReliabilityDescription(measurement.reliability),
                    "sample_age": measurement.sampleAge.map(Self.formatSeconds) ?? "none"
                ])
                return
            }

            if Self.scanTurnReachedRelativeTarget(
                requestedAngle: requestedScanAngle,
                accumulatedAngle: measurement.accumulatedAngle,
                tolerance: RoverConfig.scanTurnYawTolerance
            ) {
                try? await control.stop()
                let directedTurn = requestedScanAngle >= 0
                    ? measurement.accumulatedAngle
                    : -measurement.accumulatedAngle
                RuntimeFileLog.append("nav_scan_completed", fields: [
                    "requested_deg": Self.formatDegrees(requestedScanAngle),
                    "accumulated_deg": Self.formatDegrees(measurement.accumulatedAngle),
                    "overshoot_deg": Self.formatDegrees(max(0, directedTurn - abs(requestedScanAngle))),
                    "pulses": "\(scanPulseCount)"
                ])
                state = .arrived
                return
            }

            if Self.scanTurnMovedOppositeDirection(
                requestedAngle: requestedScanAngle,
                accumulatedAngle: measurement.accumulatedAngle
            ) {
                try? await control.stop()
                state = .failed("Scan turn moved opposite the requested direction.")
                RuntimeFileLog.append("nav_scan_opposite_direction", fields: [
                    "requested_deg": Self.formatDegrees(requestedScanAngle),
                    "accumulated_deg": Self.formatDegrees(measurement.accumulatedAngle)
                ])
                return
            }

            if Self.scanPulseLimitReached(scanPulseCount) {
                try? await control.stop()
                state = .failed("Scan turn could not establish a reliable heading.")
                RuntimeFileLog.append("nav_scan_pulse_limit", fields: [
                    "pulses": "\(scanPulseCount)",
                    "requested_deg": Self.formatDegrees(requestedScanAngle),
                    "accumulated_deg": Self.formatDegrees(measurement.accumulatedAngle),
                    "pose_yaw_deg": Self.formatDegrees(pose.yaw)
                ])
                return
            }

            let directedTurn = requestedScanAngle >= 0
                ? measurement.accumulatedAngle
                : -measurement.accumulatedAngle
            let remaining = max(0, abs(requestedScanAngle) - directedTurn)
            let error = requestedScanAngle >= 0 ? remaining : -remaining
            let plannedCommand = RotationCommand.command(forYawError: error)
            guard let command = await rotationSafetyCommand(
                plannedCommand,
                hasSentCommand: hasSentCommand
            ) else { return }
            let pulseDuration = Self.scanPulseDuration()
            RuntimeFileLog.append("nav_rotate_tick", fields: [
                "pose_x": Self.formatMeters(pose.position.x),
                "pose_y": Self.formatMeters(pose.position.y),
                "pose_yaw_deg": Self.formatDegrees(pose.yaw),
                "requested_deg": Self.formatDegrees(requestedScanAngle),
                "accumulated_deg": Self.formatDegrees(measurement.accumulatedAngle),
                "sample_age": measurement.sampleAge.map(Self.formatSeconds) ?? "none",
                "pulse": "\(scanPulseCount + 1)",
                "pulse_seconds": Self.formatSeconds(pulseDuration),
                "mode": "scan_pulse",
                "heading_source": "gravity_axis_rotation_rate",
                "wheel_left": Self.formatMeters(command.left),
                "wheel_right": Self.formatMeters(command.right)
            ])

            do {
                try await control.sendNavigation(command)
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

            scanPulseCount += 1
            let frameBeforePulse = ar.frameSequence
            try? await Task.sleep(for: .seconds(pulseDuration))
            try? await control.stop()
            RuntimeFileLog.append("nav_scan_turn_settle", fields: [
                "pulse_seconds": Self.formatSeconds(pulseDuration),
                "settle_seconds": Self.formatSeconds(RoverConfig.scanTurnSettleDuration)
            ])
            try? await Task.sleep(for: .seconds(RoverConfig.scanTurnSettleDuration))

            guard let freshPose = await waitForFreshScanPose(afterFrame: frameBeforePulse) else {
                try? await control.stop()
                if Task.isCancelled { return }
                state = .failed("ARKit did not provide a fresh tracked frame after scan turn.")
                RuntimeFileLog.append("nav_scan_frame_unavailable", fields: [
                    "timeout_seconds": Self.formatSeconds(RoverConfig.scanFrameFreshnessTimeout)
                ])
                return
            }

            let settledMeasurement = ar.relativeHeadingMeasurement()
            guard settledMeasurement.reliability == .reliable else {
                try? await control.stop()
                state = .failed(Self.relativeHeadingFailureMessage(settledMeasurement.reliability))
                RuntimeFileLog.append("nav_scan_heading_unreliable", fields: [
                    "reason": Self.relativeHeadingReliabilityDescription(settledMeasurement.reliability),
                    "sample_age": settledMeasurement.sampleAge.map(Self.formatSeconds) ?? "none"
                ])
                return
            }

            let arRotation = normalizeAngle(freshPose.yaw - scanStartPose.yaw)
            let disagreement = abs(normalizeAngle(
                arRotation - settledMeasurement.accumulatedAngle
            ))
            RuntimeFileLog.append("nav_scan_frame_ready", fields: [
                "frame": "\(ar.frameSequence)",
                "pose_x": Self.formatMeters(freshPose.position.x),
                "pose_y": Self.formatMeters(freshPose.position.y),
                "pose_yaw_deg": Self.formatDegrees(freshPose.yaw),
                "ar_rotation_deg": Self.formatDegrees(arRotation),
                "accumulated_deg": Self.formatDegrees(settledMeasurement.accumulatedAngle),
                "disagreement_deg": Self.formatDegrees(disagreement)
            ])

            guard Self.isSettledScanPoseConsistent(
                from: scanStartPose,
                to: freshPose,
                accumulatedAngle: settledMeasurement.accumulatedAngle
            ) else {
                try? await control.stop()
                let translation = scanStartPose.position.distance(to: freshPose.position)
                if translation >= RoverConfig.scanPoseJumpTranslation {
                    state = .failed("Rover moved unexpectedly during an in-place scan.")
                    RuntimeFileLog.append("nav_scan_translation_jump", fields: [
                        "meters": Self.formatMeters(translation)
                    ])
                } else {
                    state = .failed("AR and inertial scan headings disagreed after settling.")
                    RuntimeFileLog.append("nav_scan_heading_disagreement", fields: [
                        "ar_rotation_deg": Self.formatDegrees(arRotation),
                        "accumulated_deg": Self.formatDegrees(settledMeasurement.accumulatedAngle),
                        "disagreement_deg": Self.formatDegrees(disagreement)
                    ])
                }
                return
            }
        }
        try? await control.stop()
    }

    private func rotationSafetyCommand(_ command: WheelCommand,
                                       hasSentCommand: Bool) async -> WheelCommand? {
        guard await rotationGeneralSafetyAllowsMotion(
            command,
            requireFreshAck: hasSentCommand
        ) else { return nil }

        let depthSafety = depthSafetyObservation(command)
        switch guardLayer.evaluate(command: command, depthSafety: depthSafety) {
        case .allow(let safeCommand, _):
            return safeCommand
        case .stopDepth(let observation):
            var stoppingObservation = observation
            if observation.state == .unavailable(.blindSweptVolume),
               observation.motionClass == .rotating {
                try? await control.stop()
                let depthVersion = ar.depthSnapshotVersion
                RuntimeFileLog.append("nav_scan_depth_retry_started", fields: [
                    "depth_version": String(depthVersion),
                    "timeout_seconds": Self.formatSeconds(scanDepthRecoveryTimeout),
                ])
                let deadline = Date().addingTimeInterval(scanDepthRecoveryTimeout)
                while ar.depthSnapshotVersion <= depthVersion,
                      Date() < deadline,
                      !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(RoverConfig.scanDepthRecoveryPollInterval))
                }
                guard !Task.isCancelled else { return nil }
                guard ar.depthSnapshotVersion > depthVersion else {
                    try? await control.stop()
                    state = .failed(
                        "I can’t safely see the space needed to turn. Reposition the rover or camera and try again."
                    )
                    RuntimeFileLog.append("nav_scan_depth_retry_timeout", fields: [
                        "depth_version": String(depthVersion),
                    ])
                    RuntimeFileLog.append("nav_safety_stop", fields: [
                        "reason": "blind_rotation_depth_timeout",
                        "depth_state": observation.state.telemetryReason,
                    ])
                    return nil
                }
                RuntimeFileLog.append("nav_scan_depth_fresh_snapshot", fields: [
                    "previous_version": String(depthVersion),
                    "depth_version": String(ar.depthSnapshotVersion),
                    "depth_timestamp": ar.depthSnapshotTimestamp.map(Self.formatSeconds) ?? "none",
                ])
                let retriedSafety = depthSafetyObservation(command)
                switch guardLayer.evaluate(command: command, depthSafety: retriedSafety) {
                case .allow(let safeCommand, let safeObservation):
                    guard await rotationGeneralSafetyAllowsMotion(
                        safeCommand,
                        requireFreshAck: true
                    ) else { return nil }
                    RuntimeFileLog.append("nav_scan_depth_original_authorized", fields: [
                        "depth_state": safeObservation.state.telemetryReason,
                        "support_count": String(safeObservation.supportCount),
                    ])
                    return safeCommand
                case .stopDepth(let retriedObservation):
                    stoppingObservation = retriedObservation
                }
                if stoppingObservation.state == .unavailable(.blindSweptVolume) {
                    let arcCommand = RotationCommand.depthVisibleArc(matching: command)
                    let arcSafety = depthSafetyObservation(arcCommand)
                    switch guardLayer.evaluate(
                        command: arcCommand,
                        depthSafety: arcSafety
                    ) {
                    case .allow(let safeArcCommand, let safeObservation):
                        guard await rotationGeneralSafetyAllowsMotion(
                            safeArcCommand,
                            requireFreshAck: true
                        ) else { return nil }
                        RuntimeFileLog.append("nav_scan_depth_visible_arc", fields: [
                            "original_depth_state": observation.state.telemetryReason,
                            "arc_depth_state": safeObservation.state.telemetryReason,
                            "arc_support_count": "\(safeObservation.supportCount)",
                            "wheel_left": Self.formatMeters(safeArcCommand.left),
                            "wheel_right": Self.formatMeters(safeArcCommand.right)
                        ])
                        return safeArcCommand
                    case .stopDepth(let arcObservation):
                        stoppingObservation = arcObservation
                        RuntimeFileLog.append("nav_scan_depth_visible_arc_rejected", fields: [
                            "original_depth_state": observation.state.telemetryReason,
                            "arc_depth_state": arcObservation.state.telemetryReason,
                            "arc_support_count": "\(arcObservation.supportCount)"
                        ])
                    }
                }
            }
            try? await control.stop()
            if observation.state == .unavailable(.blindSweptVolume) {
                state = .failed(
                    "I can’t safely see the space needed to turn. Reposition the rover or camera and try again."
                )
            } else {
                state = .failed(
                    "Depth safety stop while rotating: \(stoppingObservation.state.telemetryReason)."
                )
            }
            RuntimeFileLog.append("nav_safety_stop", fields: [
                "reason": "depth_safety_while_rotating",
                "depth_state": stoppingObservation.state.telemetryReason,
                "depth_age": Self.formatSeconds(stoppingObservation.sampleAge),
                "support_count": "\(stoppingObservation.supportCount)",
                "motion_class": stoppingObservation.motionClass.rawValue
            ])
            return nil
        }
    }

    private func rotationGeneralSafetyAllowsMotion(
        _ command: WheelCommand,
        requireFreshAck: Bool
    ) async -> Bool {
        let lastAck = await control.lastAckAt
        let now = Date()
        let motionClass = DepthSafetyMotionClass.classify(command)
        let decision = guardLayer.evaluate(
            forwardClearance: ar.forwardClearance,
            lastAckAt: lastAck,
            now: now,
            feedback: safetyFeedback(),
            requireFreshAck: requireFreshAck,
            checkForwardObstacle: motionClass != .rotating
        )
        switch decision {
        case .go:
            return true
        case .stopObstacle(let clearance):
            try? await control.stop()
            state = .failed(Self.obstacleMessage(clearance: clearance))
            RuntimeFileLog.append("nav_safety_stop", fields: [
                "reason": "obstacle_while_rotating",
                "clearance": String(format: "%.2f", clearance)
            ])
        case .stopCommsLost:
            try? await control.stop()
            state = .failed("Rover command link lost.")
            RuntimeFileLog.append("nav_safety_stop", fields: [
                "reason": "comms_lost_while_rotating",
                "ack_age": Self.ackAgeField(lastAckAt: lastAck, now: now)
            ])
        case .stopTipping:
            try? await control.stop()
            state = .failed("Rover may be tipping.")
            RuntimeFileLog.append("nav_safety_stop", fields: ["reason": "tipping_while_rotating"])
        }
        return false
    }

    private func waitForReliableRelativeHeading() async -> RelativeHeadingMeasurement? {
        let deadline = Date().addingTimeInterval(RoverConfig.scanFrameFreshnessTimeout)
        while !Task.isCancelled, Date() < deadline {
            let measurement = ar.relativeHeadingMeasurement()
            if measurement.reliability == .reliable {
                return measurement
            }
            if case .unreliable(let reason) = measurement.reliability,
               reason != .notStarted,
               reason != .staleSample {
                return nil
            }
            try? await Task.sleep(for: .seconds(RoverConfig.scanFramePollInterval))
        }
        return nil
    }

    private func waitForFreshScanPose(afterFrame baseline: UInt64) async -> Pose2D? {
        let deadline = Date().addingTimeInterval(RoverConfig.scanFrameFreshnessTimeout)
        while !Task.isCancelled, Date() < deadline {
            let currentFrame = ar.frameSequence
            let pose = ar.pose
            if Self.isScanFrameReady(
                baselineFrame: baseline,
                currentFrame: currentFrame,
                isTrackingNormal: ar.isTrackingNormal,
                hasPose: pose != nil
            ), let pose {
                return pose
            }
            try? await Task.sleep(for: .seconds(RoverConfig.scanFramePollInterval))
        }
        return nil
    }

    static func isScanFrameReady(baselineFrame: UInt64,
                                 currentFrame: UInt64,
                                 isTrackingNormal: Bool,
                                 hasPose: Bool) -> Bool {
        currentFrame > baselineFrame && isTrackingNormal && hasPose
    }

    static func scanTurnReachedRelativeTarget(requestedAngle: Double,
                                              accumulatedAngle: Double,
                                              tolerance: Double) -> Bool {
        let directedTurn = requestedAngle >= 0 ? accumulatedAngle : -accumulatedAngle
        return directedTurn >= max(0, abs(requestedAngle) - tolerance)
    }

    static func scanTurnMovedOppositeDirection(requestedAngle: Double,
                                               accumulatedAngle: Double) -> Bool {
        let directedTurn = requestedAngle >= 0 ? accumulatedAngle : -accumulatedAngle
        return directedTurn <= -RoverConfig.scanMinimumProgressYaw
    }

    static func isSettledScanPoseConsistent(from start: Pose2D,
                                            to current: Pose2D,
                                            accumulatedAngle: Double) -> Bool {
        guard start.position.distance(to: current.position) < RoverConfig.scanPoseJumpTranslation else {
            return false
        }
        let arRotation = normalizeAngle(current.yaw - start.yaw)
        return abs(normalizeAngle(arRotation - accumulatedAngle))
            <= RoverConfig.scanHeadingAgreementTolerance
    }

    static func scanPulseLimitReached(_ pulseCount: Int) -> Bool {
        pulseCount >= RoverConfig.scanTurnMaxPulseCount
    }

    static func scanPulseDuration() -> TimeInterval {
        RoverConfig.scanTurnPulseDuration
    }

    static func stateAfterObstacleStop(pose _: Pose2D, goal _: Vec2, clearance: Double) -> State {
        .failed(obstacleMessage(clearance: clearance))
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

    private static func relativeHeadingReliabilityDescription(
        _ reliability: RelativeHeadingReliability
    ) -> String {
        switch reliability {
        case .reliable:
            "reliable"
        case .unreliable(let reason):
            reason.rawValue
        }
    }

    private static func relativeHeadingFailureMessage(
        _ reliability: RelativeHeadingReliability
    ) -> String {
        "Relative heading became unreliable (\(relativeHeadingReliabilityDescription(reliability)))."
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
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
