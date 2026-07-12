import XCTest
import RoverNav
import PhroverKit
import PhroverCloud

/// Phase 4, capability #9 (collaboration): 3 rovers, each driven by the REAL production
/// `CloudBrain` (same wire path as `CloudBrainCapstoneTests`), reasoning over a shared
/// `SimMesh` team context to claim rooms and re-divide work when a teammate is killed
/// mid-mission. No scripted allocation logic anywhere — every claim decision, and every
/// reaction to a lost teammate, is the real model's own choice via `RoverDecision
/// .claimRoom` and the `teamContext` in `MissionContext` (see `RoverBrain.swift`,
/// `MissionAgent.swift`, and `MISSION_AGENT_SYSTEM_PROMPT` in aws/src/rover.py).
///
/// Requires a Godot Depot sim (GODOT_HOST/GODOT_PORT) and `LIVE_ROVER_ACT_URL` — real,
/// billed Bedrock calls, 3x concurrent. Run via eco/rover/sim/run_live_team.py. Skips
/// (never fails) if either prerequisite is absent.
@MainActor
final class TeamCloudBrainTests: XCTestCase {
    private static let rooms = [
        TeamContext.Room(id: "roomA", worldPoint: Vec2(-4.0, 4.0)),
        TeamContext.Room(id: "roomB", worldPoint: Vec2(4.0, 4.0)),
        TeamContext.Room(id: "roomC", worldPoint: Vec2(-4.0, 8.0)),
    ]
    private static let roverIds = ["team-1", "team-2", "team-3"]
    private static let missionUtterance =
        "You're one of three rovers on this mission. Look at the claimable rooms and " +
        "teammates in your team context, claim an unclaimed room, search it for anything " +
        "out of place, and report what you find. If a teammate stops responding, claim " +
        "one of their unclaimed rooms too so nothing gets missed."

    func testLiveTeamAllocationAndSurvivorRecovery() async throws {
        guard let url = ProcessInfo.processInfo.environment["LIVE_ROVER_ACT_URL"], !url.isEmpty else {
            throw XCTSkip("LIVE_ROVER_ACT_URL not set — run via eco/rover/sim/run_live_team.py.")
        }
        let link: GodotLink
        do {
            link = try GodotLink()
        } catch {
            throw XCTSkip("Godot Depot sim not reachable — launch it first.")
        }

        let seed = Int(ProcessInfo.processInfo.environment["DEPOT_SEED"] ?? "7") ?? 7
        link.call(["op": "reset", "seed": seed])

        let starts: [(Double, Double, Double)] = [(-0.6, 1.0, .pi / 2), (0.0, 1.0, .pi / 2), (0.6, 1.0, .pi / 2)]
        for (i, id) in Self.roverIds.enumerated() {
            link.call(["op": "phrover_spawn", "id": id, "p": [starts[i].0, starts[i].1], "yaw": starts[i].2])
        }

        let config = PhroverCloudConfig(region: "us-west-2", apiEndpoint: url,
                                        identityPoolId: "", userPoolId: "",
                                        iotEndpoint: "", cognitoClientId: "")
        let mesh = SimMesh(latency: 0.3, lossRate: 0.1)
        let sharedEvents = EventLog()

        // Kill "team-3" partway through — its radio (heartbeat) AND its Godot body both
        // stop, so survivors must detect the silence themselves, exactly like a real
        // dropped teammate, not a scripted "member_lost" broadcast.
        let killTarget = "team-3"
        // Built fully before the task group starts (no shared-dictionary mutation across
        // concurrently-added tasks — Swift's strict concurrency checker otherwise can't
        // verify safety even though everything here is MainActor-isolated).
        let radios: [GodotTeamRadio] = Self.roverIds.map {
            GodotTeamRadio(roverId: $0, mesh: mesh, rooms: Self.rooms, allRoverIds: Self.roverIds)
        }
        guard let killRadio = radios.first(where: { $0.roverId == killTarget }) else {
            XCTFail("no radio for \(killTarget)")
            return
        }

        // Plain unstructured tasks, not `withTaskGroup` — the group's `addTask` API hits
        // a Swift 6 region-isolation checker limitation ("please file a bug") on this
        // capture pattern even though everything here is correctly MainActor-isolated.
        var handles: [Task<Void, Never>] = []
        for (id, radio) in zip(Self.roverIds, radios) {
            handles.append(Task { @MainActor in
                let motion = GodotMotion(link: link, rid: id)
                let perception = GodotPerception(link: link, rid: id)
                let battery = GodotBattery(link: link, rid: id)
                let voice = ScriptedVoice(events: sharedEvents)
                let brain = CloudBrain(config: config)
                let recorder = TaggedRecordingBrain(wrapping: brain, events: sharedEvents, roverId: id)
                let agent = MissionAgent(motion: motion, perception: perception, voice: voice,
                                          battery: battery, teamRadio: radio,
                                          maxTicksPerUtterance: 20) { recorder }
                await agent.handle(Self.missionUtterance)
                radio.stop()
            })
        }
        handles.append(Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            sharedEvents.log("inject", ["target": killTarget])
            killRadio.stop()
            link.call(["op": "inject", "name": "kill_rover", "params": ["id": killTarget]])
        })
        for h in handles { await h.value }

        let claims = sharedEvents.events.filter { $0.kind == "decision" && (($0.data["decision"] as? String)?.contains("claimRoom") ?? false) }
        print("=== \(claims.count) claimRoom decisions across the team ===")
        for c in claims { print("  ", c.data) }

        let doneByRover = Dictionary(grouping: sharedEvents.events.filter {
            $0.kind == "decision" && (($0.data["decision"] as? String)?.contains("done") ?? false)
        }, by: { $0.data["rover"] as? String ?? "?" })
        print("=== rovers reaching .done: \(doneByRover.keys.sorted()) ===")
    }
}

/// Same as `RecordingBrain` but tags each logged event with which rover produced it —
/// needed here since all 3 rovers share one `EventLog` for cross-rover assertions.
@MainActor
private final class TaggedRecordingBrain: RoverBrain {
    private let inner: RoverBrain
    private let events: EventLog
    private let roverId: String

    init(wrapping inner: RoverBrain, events: EventLog, roverId: String) {
        self.inner = inner
        self.events = events
        self.roverId = roverId
    }

    func nextAction(_ context: MissionContext) async throws -> BrainOutput {
        let output = try await inner.nextAction(context)
        events.log("decision", [
            "rover": roverId,
            "decision": String(describing: output.decision),
            "plan": output.updatedPlan ?? NSNull(),
        ])
        return output
    }
}
