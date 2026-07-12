import XCTest
import RoverNav
import PhroverKit

/// The Depot capstone ("Sweep and Report") against the real `MissionAgent`, with only
/// motion/perception/voice/battery swapped for Godot-backed sim implementations (see
/// GodotMotion/GodotPerception/GodotBattery/ScriptedVoice) and `ScriptedDepotBrain` in
/// place of a real reasoner — the fast/deterministic tier (see design plan's phase table;
/// CloudBrain runs the same mission in Phase 3 via live_rover_act_bridge.py).
///
/// Requires a Godot Depot sim already running and reachable (GODOT_HOST/GODOT_PORT env,
/// default 127.0.0.1:9999) — start it with `eco/rover/sim/godot_launcher.py` or the
/// harness (`depot_harness.py`). Skips (never fails) if unreachable, so it can't leak
/// into a CI gate that doesn't launch Godot.
@MainActor
final class CapstoneTests: XCTestCase {
    private static let missionUtterance =
        "Search the depot for the red toolbox, tell me if anything's out of place, and stay out of the paint room."
    // Matches env_depot.gd's ROOMS["D"] (the paint/keep-out room) exactly.
    private static let paintRoomKeepOut = [(min: Vec2(1.0, 6.0), max: Vec2(7.0, 10.0))]
    private static let startPose = (x: 0.0, y: 1.0, yaw: Double.pi / 2)

    private func makeMission(rid: String, seed: Int) throws
        -> (agent: MissionAgent, voice: ScriptedVoice, events: EventLog, link: GodotLink) {
        let link: GodotLink
        do {
            link = try GodotLink()
        } catch {
            throw XCTSkip("Godot Depot sim not reachable at "
                + "\(ProcessInfo.processInfo.environment["GODOT_HOST"] ?? "127.0.0.1"):"
                + "\(ProcessInfo.processInfo.environment["GODOT_PORT"] ?? "9999")"
                + " — launch it first (eco/rover/sim/godot_launcher.py::launch_depot).")
        }
        link.call(["op": "reset", "seed": seed])
        link.call(["op": "phrover_spawn", "id": rid,
                    "p": [Self.startPose.x, Self.startPose.y], "yaw": Self.startPose.yaw])

        let motion = GodotMotion(link: link, rid: rid)
        let perception = GodotPerception(link: link, rid: rid)
        let battery = GodotBattery(link: link, rid: rid)
        let events = EventLog()
        // Covers the ambiguity beat if it fires (both toolboxes seen before the red one
        // is confirmed) without forcing it — see ScriptedDepotBrain's colour-blind design.
        let voice = ScriptedVoice(events: events, replies: ["The red one, I think."])
        let brain = ScriptedDepotBrain(keepOutRects: Self.paintRoomKeepOut)
        let recorder = RecordingBrain(wrapping: brain, events: events)
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice,
                                  battery: battery, maxTicksPerUtterance: 80) { recorder }
        return (agent, voice, events, link)
    }

    private func decisionEvents(_ events: EventLog, containing substring: String) -> [EventLog.Event] {
        events.events.filter {
            $0.kind == "decision" && (($0.data["decision"] as? String)?.contains(substring) ?? false)
        }
    }

    private func speakEvents(_ events: EventLog, containing substring: String) -> [EventLog.Event] {
        events.events.filter {
            $0.kind == "speak" && (($0.data["text"] as? String)?.lowercased().contains(substring) ?? false)
        }
    }

    // MARK: - #5 exploration, #8 anomaly report, #10 keep-out geofence

    func testFindRedToolboxReportsAnomalyAndReturns() async throws {
        let (agent, _, events, link) = try makeMission(rid: "capstone-1", seed: 7)

        await agent.handle(Self.missionUtterance)

        XCTAssertFalse(decisionEvents(events, containing: "done").isEmpty,
                        "mission never completed — decisions: \(events.events.map { $0.kind })")
        XCTAssertFalse(speakEvents(events, containing: "spill").isEmpty,
                        "expected an unprompted spill report")

        let geofenceEvents = (link.call(["op": "get_events", "since": 0.0])["events"] as? [[String: Any]]) ?? []
        let paintEntries = geofenceEvents.filter { ($0["kind"] as? String) == "geofence_enter" }
        XCTAssertTrue(paintEntries.isEmpty, "rover entered the geofenced paint room")

        let finalState = link.call(["op": "phrover_state", "id": "capstone-1"])
        if let pose = godotDoubleArray(finalState["pose"]) {
            let dist = ((pose[0] - Self.startPose.x).magnitudeSquared
                        + (pose[1] - Self.startPose.y).magnitudeSquared).squareRoot()
            XCTAssertLessThan(dist, 1.0, "rover did not return near its start pose (final \(pose))")
        }
    }

    // MARK: - #3 planning with commitment (replan around a blocked door)

    func testReplansAroundBlockedDoor() async throws {
        let (agent, _, events, link) = try makeMission(rid: "capstone-2", seed: 7)

        // Block door A shortly after the mission starts — room A only reconnects to the
        // hallway via the A/C interior doorway (see env_depot.gd), so this only passes if
        // the mission actually reroutes through it rather than getting stuck.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            link.call(["op": "inject", "name": "block_door", "params": ["door": "A"]])
        }

        await agent.handle(Self.missionUtterance)

        XCTAssertFalse(decisionEvents(events, containing: "done").isEmpty,
                        "mission never completed despite an alternate route existing via the A/C interior doorway")
    }

    // MARK: - #4 self-model / calibrated uncertainty (battery)

    func testBatteryForcesEarlyReturn() async throws {
        let (agent, _, events, link) = try makeMission(rid: "capstone-3", seed: 7)
        link.call(["op": "inject", "name": "battery_drain", "params": ["rate": 400.0]])

        await agent.handle(Self.missionUtterance)

        XCTAssertFalse(speakEvents(events, containing: "battery").isEmpty,
                        "expected the brain to announce a low-battery return")
        XCTAssertFalse(decisionEvents(events, containing: "done").isEmpty,
                        "expected the mission to still reach .done after returning")
    }

    // MARK: - #2 persistent world model with memory

    func testGoBackToRememberedObject() async throws {
        let (agent, _, events, link) = try makeMission(rid: "capstone-4", seed: 7)
        await agent.handle(Self.missionUtterance)

        let truth = (link.call(["op": "prop_truth"])["props"] as? [[String: Any]]) ?? []
        guard let ladder = truth.first(where: { ($0["label"] as? String) == "ladder" }),
              let ladderWorld = godotDoubleArray(ladder["world"])
        else {
            XCTFail("no ladder prop in ground truth")
            return
        }

        await agent.handle("go back to the ladder")

        XCTAssertFalse(decisionEvents(events, containing: "worldPoint").isEmpty,
                        "expected a memory-based worldPoint navigate, not a fresh visual search")

        let finalState = link.call(["op": "phrover_state", "id": "capstone-4"])
        guard let pose = godotDoubleArray(finalState["pose"]) else {
            XCTFail("no final pose")
            return
        }
        let dist = ((pose[0] - ladderWorld[0]).magnitudeSquared
                    + (pose[1] - ladderWorld[1]).magnitudeSquared).squareRoot()
        XCTAssertLessThan(dist, 1.5, "rover did not navigate back to the remembered ladder (final \(pose), ladder \(ladderWorld))")
    }
}

private extension Double {
    var magnitudeSquared: Double { self * self }
}
