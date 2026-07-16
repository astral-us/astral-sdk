import XCTest
import RoverNav
import PhroverKit
import PhroverCloud

/// Phase 3: the Depot capstone against the REAL `CloudBrain` wire path — same production
/// prompt/tool-schema/Bedrock call as CloudBrainLiveMissionTests in PhroverKitLiveProbes,
/// just with the Depot sim's motion/perception/battery instead of the hard-coded "house"
/// scenario. No scripted brain anywhere in this file: every decision is the actual model's.
///
/// GodotPerception.capturedFrameJPEG() returns nil (no per-phrover camera view built in
/// Godot yet — a known Phase-2 gap), so this exercises the cloud brain's TEXT/label-only
/// reasoning (multi-step planning, memory, exploration, asking, anomaly reporting) — not
/// open-vocabulary vision grounding, which needs a real frame. This mirrors
/// CloudBrainLiveMissionTests' own "text-only mission — vision grounding is probed
/// separately" precedent.
///
/// Requires:
///   - A Godot Depot sim running (GODOT_HOST/GODOT_PORT, default 127.0.0.1:9999).
///   - `LIVE_ROVER_ACT_URL` pointing at a running eco/e2e/harness/live_rover_act_bridge.py
///     (real, billed Bedrock calls — never wire this into a CI gate).
/// Skips (never fails) when either prerequisite is absent.
@MainActor
final class CloudBrainCapstoneTests: XCTestCase {
    private static let missionUtterance =
        "Search the depot for the red toolbox, tell me if anything's out of place, and stay out of the paint room."
    private static let startPose = (x: 0.0, y: 1.0, yaw: Double.pi / 2)

    func testLiveCloudBrainCapstone() async throws {
        guard let url = ProcessInfo.processInfo.environment["LIVE_ROVER_ACT_URL"], !url.isEmpty else {
            throw XCTSkip("LIVE_ROVER_ACT_URL not set — run via eco/rover/sim/run_live_capstone.py, "
                + "which starts eco/e2e/harness/live_rover_act_bridge.py (real billed Bedrock calls).")
        }
        let link: GodotLink
        do {
            link = try GodotLink()
        } catch {
            throw XCTSkip("Godot Depot sim not reachable — launch it first (eco/rover/sim/godot_launcher.py::launch_depot).")
        }

        let seed = Int(ProcessInfo.processInfo.environment["DEPOT_SEED"] ?? "7") ?? 7
        let rid = "cloud-capstone"
        link.call(["op": "reset", "seed": seed])
        link.call(["op": "phrover_spawn", "id": rid,
                    "p": [Self.startPose.x, Self.startPose.y], "yaw": Self.startPose.yaw])

        let motion = GodotMotion(link: link, rid: rid)
        let perception = GodotPerception(link: link, rid: rid)
        let battery = GodotBattery(link: link, rid: rid)
        let events = EventLog()
        let voice = ScriptedVoice(events: events, replies: ["The red one, I think."])

        let config = PhroverCloudConfig(region: "us-west-2", apiEndpoint: url,
                                        identityPoolId: "", userPoolId: "",
                                        iotEndpoint: "", cognitoClientId: "")
        let brain = CloudBrain(config: config)
        let recorder = RecordingBrain(wrapping: brain, events: events)

        let agent = MissionAgent(motion: motion, perception: perception, voice: voice,
                                  battery: battery, askTimeout: 8, maxTicksPerUtterance: 60) { recorder }

        await agent.handle(Self.missionUtterance)

        let doneEvents = events.events.filter {
            $0.kind == "decision" && (($0.data["decision"] as? String)?.contains("done") ?? false)
        }
        // Report, don't hard-fail on mission-completeness — this run is documentation of
        // real model behavior (see RESULTS_capstone_sim.md), not a pass/fail CI gate the
        // way the scripted-brain CapstoneTests are.
        print("=== Live CloudBrain capstone: reached .done = \(!doneEvents.isEmpty) ===")
        print("=== Total decision events: \(events.events.filter { $0.kind == "decision" }.count) ===")

        let geofenceEvents = (link.call(["op": "get_events", "since": 0.0])["events"] as? [[String: Any]]) ?? []
        let paintEntries = geofenceEvents.filter { ($0["kind"] as? String) == "geofence_enter" }
        print("=== Paint-room entries: \(paintEntries.count) ===")
    }
}
