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
    public enum State: Equatable { case idle, planning, driving, arrived, failed(String) }

    public private(set) var state: State = .idle
    public private(set) var path: [Vec2] = []

    private let ar: ARSessionManager
    private let control: RoverControl
    private let planner = AStarPlanner()
    private let pursuit = PursuitController(params: .init(
        wheelBase: RoverConfig.wheelBase, goalTolerance: 0.2))
    private let guardLayer = ObstacleGuard()

    private var loop: Task<Void, Never>?
    private var replanCounter = 0

    public init(ar: ARSessionManager, control: RoverControl) {
        self.ar = ar
        self.control = control
    }

    /// Begin autonomously driving to a nav-plane goal.
    public func navigate(to goal: Vec2) {
        cancel()
        guard let start = ar.pose?.position else {
            state = .failed("No ARKit pose yet — move the device to establish tracking.")
            return
        }
        guard planAndStore(from: start, to: goal) else {
            state = .failed("No path to goal.")
            return
        }
        state = .driving
        loop = Task { await drive(to: goal) }
    }

    /// Rotate in place by `angle` radians (CCW positive, matching `Pose2D.yaw`) and wait
    /// for it to finish. A pure turn, no path planning — used by the mission agent to scan
    /// for something not currently in view (e.g. up to a full `2 * .pi` look-around).
    /// Honors the same `ObstacleGuard` gate and command cadence as `drive()`, and can be
    /// interrupted by `cancel()`.
    public func rotate(by angle: Double) async {
        cancel()
        guard let startYaw = ar.pose?.yaw else {
            state = .failed("No ARKit pose yet — move the device to establish tracking.")
            return
        }
        let targetYaw = normalizeAngle(startYaw + angle)
        state = .driving
        let task = Task { await performRotate(to: targetYaw) }
        loop = task
        await task.value
    }

    /// Stop and clear the current goal.
    public func cancel() {
        loop?.cancel()
        loop = nil
        Task { try? await control.stop() }
    }

    // MARK: - Loop

    private func drive(to goal: Vec2) async {
        while !Task.isCancelled {
            guard let pose = ar.pose else { break }

            // Replan every ~1s to fold in newly meshed obstacles.
            replanCounter += 1
            if replanCounter % 10 == 0 { _ = planAndStore(from: pose.position, to: goal) }

            // Safety gate.
            let lastAck = await control.lastAckAt
            let decision = guardLayer.evaluate(forwardClearance: ar.forwardClearance,
                                               lastAckAt: lastAck,
                                               feedback: nil)
            guard decision == .go else {
                try? await control.stop()
                // For a static obstacle, replanning next tick may route around it; for
                // comms loss / tip we just keep commanding stop until cleared.
                try? await Task.sleep(for: .seconds(RoverConfig.commandInterval))
                continue
            }

            let out = pursuit.step(pose: pose, path: path)
            if out.reachedGoal {
                try? await control.stop()
                state = .arrived
                return
            }
            try? await control.send(out.command)
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

    private func performRotate(to targetYaw: Double) async {
        let angularTolerance = 0.05 // rad
        let rotateGain = 2.0
        let maxAngular = 1.5 // rad/s — matches PursuitController's default turn rate

        while !Task.isCancelled {
            guard let pose = ar.pose else { break }
            let error = normalizeAngle(targetYaw - pose.yaw)
            if abs(error) <= angularTolerance {
                try? await control.stop()
                state = .arrived
                return
            }

            let lastAck = await control.lastAckAt
            let decision = guardLayer.evaluate(forwardClearance: ar.forwardClearance,
                                               lastAckAt: lastAck,
                                               feedback: nil)
            guard decision == .go else {
                try? await control.stop()
                try? await Task.sleep(for: .seconds(RoverConfig.commandInterval))
                continue
            }

            let w = min(max(error * rotateGain, -maxAngular), maxAngular)
            let cmd = DifferentialDrive.wheels(v: 0, w: w,
                                               wheelBase: RoverConfig.wheelBase,
                                               maxWheelSpeed: RoverConfig.maxWheelSpeed)
            try? await control.send(cmd)
            try? await Task.sleep(for: .seconds(RoverConfig.commandInterval))
        }
        try? await control.stop()
    }
}
