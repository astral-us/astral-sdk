import XCTest
import RoverNav
import PhroverKit

/// Free (no Bedrock), scripted test for the person-crossing corridor problem: exercises
/// `GodotMotion` directly (no `MissionAgent`/brain in the loop at all — irrelevant to what's
/// being tested here) so the `person_stop_active` stall-detector exemption can be verified
/// cheaply and repeatably, before ever spending live Bedrock cost on `testPersonCrossingLive`.
///
/// Requires a Godot Depot sim already running and reachable — same skip-if-unreachable
/// convention as CapstoneTests.
@MainActor
final class PersonCrossingMotionTests: XCTestCase {
    func testGodotMotionCrossesPersonPatrolGivenEnoughTime() async throws {
        let link: GodotLink
        do {
            link = try GodotLink()
        } catch {
            throw XCTSkip("Godot Depot sim not reachable at "
                + "\(ProcessInfo.processInfo.environment["GODOT_HOST"] ?? "127.0.0.1"):"
                + "\(ProcessInfo.processInfo.environment["GODOT_PORT"] ?? "9999")"
                + " — launch it first (eco/rover/sim/godot_launcher.py::launch_depot).")
        }

        let rid = "crossing-motion-1"
        link.call(["op": "reset", "seed": 7])
        link.call(["op": "phrover_spawn", "id": rid, "p": [0.0, 1.0], "yaw": Double.pi / 2])
        link.call(["op": "inject", "name": "person_walk", "params": ["on": true]])

        let motion = GodotMotion(link: link, rid: rid)
        // Comfortably past the person's y≈4 patrol line (PERSON_WAYPOINTS in env_depot.gd).
        motion.navigate(to: Vec2(0.0, 6.0))

        // Real-time budget: the governor's own proven-safe last-resort release cycle takes
        // ~26s (PERSON_OVERRIDE_MAX_SECONDS + PERSON_OVERRIDE_GRACE_SECONDS in
        // phrover_manager.gd); give it several cycles' worth of real time rather than the
        // GodotMotion 3s-window default so a genuine crossing has a fair chance to complete.
        let deadline = Date().addingTimeInterval(180)
        while motion.state == .driving && Date() < deadline {
            try? await Task.sleep(for: .seconds(0.2))
        }

        let finalState = link.call(["op": "phrover_state", "id": rid])
        let pose = godotDoubleArray(finalState["pose"])
        let finalY = pose?[1] ?? -1

        if case .failed(let reason) = motion.state {
            XCTFail("navigate failed before crossing: \(reason) (final y=\(finalY))")
        }
        XCTAssertEqual(motion.state, .arrived, "did not reach the goal past the person (final y=\(finalY))")
        XCTAssertGreaterThan(finalY, 4.5, "never actually got past the person's patrol line (final y=\(finalY))")

        let events = (link.call(["op": "get_events", "since": 0.0])["events"] as? [[String: Any]]) ?? []
        let personCollisions = events.filter {
            ($0["kind"] as? String) == "collision" && (($0["data"] as? [String: Any])?["with"] as? String) == "person"
        }
        XCTAssertTrue(personCollisions.isEmpty, "rover collided with the person while crossing: \(personCollisions)")
    }
}
