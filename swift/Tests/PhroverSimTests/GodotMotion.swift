import Foundation
import RoverNav
import PhroverKit

/// `RoverMotion` backed by the Godot Depot sim, mirroring `NavigationController`'s real
/// loop (see sdk/swift/Sources/PhroverKit/Nav/NavigationController.swift) — plan with the
/// real `AStarPlanner`, drive with the real `PursuitController` — but reading pose/grid
/// from Godot's IPC instead of ARKit, and sending `phrover_drive {v,w}` instead of
/// `RoverControl`'s ESP32 HTTP command.
///
/// Deliberately does not use `ObstacleGuard`: the sim's own reactive safety guard
/// (phrover_manager.gd's forward-clearance check) already plays that role independently
/// of the brain, which is the more realistic test of capability #10 (corrigible/bounded
/// behavior) — a guard the brain can't see or override.
@MainActor
final class GodotMotion: RoverMotion {
    private let link: GodotLink
    private let rid: String
    private let planner = AStarPlanner()
    private let pursuit: PursuitController
    private let robotRadius: Double
    private let wheelBase: Double
    private let tickInterval: Double

    private(set) var state: NavigationController.State = .idle
    private var path: [Vec2] = []
    private var loop: Task<Void, Never>?
    private var replanCounter = 0

    init(link: GodotLink, rid: String,
         robotRadius: Double = 0.3, wheelBase: Double = 0.2, tickInterval: Double = 0.1) {
        self.link = link
        self.rid = rid
        self.robotRadius = robotRadius
        self.wheelBase = wheelBase
        self.tickInterval = tickInterval
        // goalTolerance must clear the rover's own physical radius (0.28m capsule, see
        // phrover_manager.gd's spawn()) plus a typical small prop's half-extent (~0.2m) —
        // navigating straight to an object's exact centre point (as ScriptedDepotBrain
        // does via .worldPoint) means collision physically prevents ever closing to less
        // than ~0.48m. 0.3 (RoverNav's on-device default, tuned for open-space waypoints)
        // is smaller than that floor, so `.arrived` could never fire and the mission
        // stalled permanently a hair short of the goal — confirmed live.
        self.pursuit = PursuitController(params: .init(
            lookahead: 0.5, maxLinear: 0.4, maxAngular: 1.2,
            wheelBase: wheelBase, goalTolerance: 0.6))
    }

    func navigate(to goal: Vec2) {
        cancel()
        guard let start = fetchPose()?.position else {
            state = .failed("no pose from sim")
            return
        }
        guard planAndStore(from: start, to: goal) else {
            state = .failed("no path to goal")
            return
        }
        state = .driving
        loop = Task { await drive(to: goal) }
    }

    func rotate(by angle: Double) async {
        cancel()
        guard let startYaw = fetchPose()?.yaw else {
            state = .failed("no pose from sim")
            return
        }
        let targetYaw = normalizeAngle(startYaw + angle)
        state = .driving
        let task = Task { await performRotate(to: targetYaw) }
        loop = task
        await task.value
    }

    func cancel() {
        loop?.cancel()
        loop = nil
        link.call(["op": "phrover_stop", "id": rid])
        // Without this, an external cancel (bypassing the brain entirely — the hard-stop
        // path) leaves `state` at `.driving` forever, so `MissionAgent.waitForMotionToSettle()`
        // (which polls `state == .driving`) never returns and the mission loop hangs.
        state = .idle
    }

    // MARK: - Loop

    private func drive(to goal: Vec2) async {
        // If the goal itself becomes structurally unreachable mid-drive (e.g. a door
        // closes right at the frontier point that *was* the goal), replanAndStore keeps
        // failing and — like the real NavigationController.drive(), which also ignores a
        // failed periodic replan — would otherwise just keep following the last-known
        // (now invalid) path forever: never `.arrived` (goal's gone), never `.failed`
        // (nothing sets it), permanently guard-stopped just short of a wall. Confirmed
        // live. Fail fast after a few consecutive replan misses so the brain gets control
        // back and can pick a different candidate, instead of hanging the mission.
        var consecutiveReplanFailures = 0
        let maxConsecutiveReplanFailures = 3

        // A DIFFERENT stall from the one above: the plan keeps succeeding (so replan
        // failure never fires) and pursuit never reports `reachedGoal` either — the
        // reactive guard (phrover_manager.gd, independent of this planner) keeps zeroing
        // velocity just short of `goalTolerance` because the true closest approach to a
        // solid object is larger than expected for that specific geometry (e.g. a box
        // wedged near a room corner). Neither `.arrived` nor `.failed` would ever fire on
        // their own — confirmed live: a real CloudBrain mission sat motionless and
        // guard-stopped for 10+ minutes navigating to a reported object. Detect "no real
        // progress toward the goal for N ticks" directly, independent of *why*.
        //
        // Measured via *distance to goal*, not raw displacement from the last checkpoint:
        // an earlier version compared current position to the last checkpoint's position,
        // which a rover being pushed around by phrover_manager.gd's person-safety dodge
        // (moving it >0.05m most ticks while a patrolling person is nearby, without ever
        // net-approaching the goal) kept incidentally satisfying — resetting the checkpoint
        // every time and never accumulating 30 ticks, hanging the mission indefinitely.
        // Confirmed live (49-minute and 5-minute stalls, both on the first `explore` in a
        // person-crossing mission) and reproduced with a free Godot-IPC-only repro.
        //
        // person_stop_active exemption: the person-safety governor's own natural-release
        // path can legitimately need 20+ seconds of being held before a real crossing
        // opportunity opens (see phrover_manager.gd's PERSON_OVERRIDE_MAX_SECONDS/
        // PERSON_OVERRIDE_GRACE_SECONDS history — confirmed live via a free repro that a
        // safe crossing needs one governor cycle of ~26s, sometimes several, to actually
        // clear a moving person's patrol line). That's an order of magnitude longer than
        // this detector's ~3s window, so without an exemption this fires and calls the
        // whole crossing "failed" almost immediately after the governor first engages —
        // long before the SAME governor cycle that would have let it through ever
        // completes. Confirmed live this was the actual cause of testPersonCrossingLive
        // never getting anywhere near the person (`maxY` topping out around 2.9-3.3):
        // the mission-level no-op counter (MissionAgent.swift) then abandons the whole
        // mission after just a handful of these fast, spurious "failed" navigate attempts.
        // Only exempt while person_stop_active is true, not permanently — a rover that's
        // ACTUALLY stuck for an unrelated reason (wall, unreachable goal) still needs this
        // detector at full strength.
        var lastProgressDistToGoal: Double?
        var ticksSinceProgress = 0
        let maxTicksSinceProgress = 30  // ~3s at the 0.1s tick interval

        while !Task.isCancelled {
            guard let sample = fetchState() else { break }
            let pose = sample.pose

            let distToGoal = pose.position.distance(to: goal)
            if sample.personStopActive {
                // Held for a known, expected-to-clear reason — don't let it count against
                // the stall budget, but don't manufacture "progress" either.
                lastProgressDistToGoal = distToGoal
            } else if let last = lastProgressDistToGoal, last - distToGoal < 0.05 {
                ticksSinceProgress += 1
                if ticksSinceProgress >= maxTicksSinceProgress {
                    link.call(["op": "phrover_stop", "id": rid])
                    state = .failed("no progress for \(maxTicksSinceProgress) ticks — likely guard-stopped short of the goal")
                    return
                }
            } else {
                lastProgressDistToGoal = distToGoal
                ticksSinceProgress = 0
            }

            replanCounter += 1
            // Every ~0.2s (2 ticks), not ~1s (10 ticks, the real NavigationController's
            // cadence): now that the costmap only counts walls the rover has actually
            // observed (see GodotGrid's doc comment — no more ground-truth map knowledge),
            // an "optimistic" plan can drive straight at a not-yet-discovered wall. Slower
            // replanning meant continuing to blindly follow that stale plan for up to a
            // full second after the sweep finally saw the wall, before correcting —
            // confirmed live: exploration ballooned to 25+ frontier hops over 300+ seconds
            // from repeated blind collisions. Faster replanning reacts to newly-observed
            // obstacles almost immediately instead.
            if replanCounter % 2 == 0 {
                if planAndStore(from: pose.position, to: goal) {
                    consecutiveReplanFailures = 0
                } else {
                    consecutiveReplanFailures += 1
                    if consecutiveReplanFailures >= maxConsecutiveReplanFailures {
                        link.call(["op": "phrover_stop", "id": rid])
                        state = .failed("goal unreachable after repeated replan attempts")
                        return
                    }
                }
            }

            let out = pursuit.step(pose: pose, path: path)
            if out.reachedGoal {
                link.call(["op": "phrover_stop", "id": rid])
                state = .arrived
                return
            }
            let (v, w) = unicycle(from: out.command)
            link.call(["op": "phrover_drive", "id": rid, "v": v, "w": w])
            try? await Task.sleep(for: .seconds(tickInterval))
        }
        link.call(["op": "phrover_stop", "id": rid])
    }

    private func performRotate(to targetYaw: Double) async {
        let angularTolerance = 0.05
        let rotateGain = 2.0
        let maxAngular = 1.2

        while !Task.isCancelled {
            guard let pose = fetchPose() else { break }
            let error = normalizeAngle(targetYaw - pose.yaw)
            if abs(error) <= angularTolerance {
                link.call(["op": "phrover_stop", "id": rid])
                state = .arrived
                return
            }
            let w = min(max(error * rotateGain, -maxAngular), maxAngular)
            link.call(["op": "phrover_drive", "id": rid, "v": 0.0, "w": w])
            try? await Task.sleep(for: .seconds(tickInterval))
        }
        link.call(["op": "phrover_stop", "id": rid])
    }

    @discardableResult
    private func planAndStore(from: Vec2, to: Vec2) -> Bool {
        guard let grids = GodotGrid.fetch(link: link, rid: rid, robotRadius: robotRadius) else { return false }
        // Navigating straight to a reported object's exact centre can land inside the
        // inflation buffer around a nearby wall (a ladder leaning against one, say) —
        // AStarPlanner correctly refuses a lethal goal cell outright. A real nav stack
        // doesn't drive its centre onto the object either; it stops at the nearest
        // traversable cell (goalTolerance, already sized past the physical approach
        // limit, closes the rest of the gap). Confirmed live: two targets 0.4m from a
        // wall (within the 0.5m inflation radius) made every plan attempt fail outright.
        let effectiveGoal = nearestFreeCell(to: to, in: grids.costmap) ?? to
        guard let p = planner.plan(from: from, to: effectiveGoal, in: grids.costmap) else { return false }
        path = p
        return true
    }

    private func nearestFreeCell(to goal: Vec2, in map: Costmap, maxRingRadius: Int = 8) -> Vec2? {
        let (gx, gy) = map.worldToCell(goal)
        if map.inBounds(gx, gy), !map.isBlocked(gx, gy) { return goal }
        for ring in 1...maxRingRadius {
            for dy in -ring...ring {
                for dx in -ring...ring {
                    guard max(abs(dx), abs(dy)) == ring else { continue }
                    let nx = gx + dx, ny = gy + dy
                    guard map.inBounds(nx, ny), !map.isBlocked(nx, ny) else { continue }
                    return map.cellCenter(nx, ny)
                }
            }
        }
        return nil
    }

    private func fetchPose() -> Pose2D? {
        fetchState()?.pose
    }

    /// Pose plus `person_stop_active` (phrover_manager.gd's person-safety governor holding
    /// the rover for a moving obstacle right now) in one IPC round-trip — the stall
    /// detector in `drive()` needs both from the same instant, not two separate calls that
    /// could straddle a tick and disagree.
    private func fetchState() -> (pose: Pose2D, personStopActive: Bool)? {
        let r = link.call(["op": "phrover_state", "id": rid])
        guard r["ok"] as? Bool == true,
              let pose = godotDoubleArray(r["pose"]), pose.count == 3
        else { return nil }
        let personStopActive = r["person_stop_active"] as? Bool ?? false
        return (Pose2D(position: Vec2(pose[0], pose[1]), yaw: pose[2]), personStopActive)
    }

    /// Inverse of `DifferentialDrive.wheels(v:w:wheelBase:maxWheelSpeed:)` — PursuitController
    /// hands back per-wheel speeds (what a real WAVE ROVER command needs); Godot's phrover
    /// kinematics wants the unicycle (v, w) it was integrated from.
    private func unicycle(from command: WheelCommand) -> (Double, Double) {
        let v = (command.left + command.right) / 2.0
        let w = (command.right - command.left) / wheelBase
        return (v, w)
    }
}
