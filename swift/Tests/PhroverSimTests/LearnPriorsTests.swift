import XCTest
import CoreGraphics
import RoverNav
import PhroverKit
import PhroverCloud

/// Phase 4, capability #6 (learning from experience) — real `CloudBrain` only, no
/// scripted stand-in of any kind: N training missions, each a real live Bedrock-driven
/// search, feed an empirically-derived prior (a plain-language sentence describing which
/// room the red toolbox has turned out to be in most often); M held-out missions then run
/// TWICE each with the real brain — once bare, once with that prior sentence appended to
/// the operator utterance — so the comparison is real search behavior with vs. without a
/// learned hint, never a scripted "prior-aware" search order.
///
/// `red_toolbox`'s candidate slots (env_depot.gd's PROP_DEFS) straddle two physically
/// different rooms (2 slots in Workshop/A, 2 in Storage/B) even though the prop's static
/// metadata says room "A" — so which room it's actually in on a given seed is genuine,
/// seed-dependent uncertainty, not a fixed fact. That's what makes a room-level prior a
/// fair thing to test, unlike e.g. exact slot position (Which the harness never reveals to
/// the brain anyway — `prop_truth` is oracle-only, used here strictly for building the
/// prior corpus and for a ground-truth room label, never fed into the mission itself).
///
/// Time-to-find is judged by the harness, not by asking the brain to self-report: an
/// `InstrumentedPerception` wrapper logs every `detectObjects()` call's labels, and the
/// first one containing "red_toolbox" gives the elapsed wall-clock seconds for that
/// episode — the same "harness judges from logged events" principle as `RecordingBrain`.
///
/// Requires a Godot Depot sim (GODOT_HOST/GODOT_PORT) and `LIVE_ROVER_ACT_URL` — real,
/// billed Bedrock calls, ~10 + 6*2 = 22 live episodes. Run via
/// eco/rover/sim/run_learn_priors.py. Skips (never fails) if either prerequisite absent.
@MainActor
final class LearnPriorsTests: XCTestCase {
    // Distinct seed ranges from every other test file's seeds (7, 200s, etc.) so this
    // never accidentally shares state/assumptions with door-block or team tests.
    private static let trainSeeds: [Int] = Array(500...509)      // N = 10
    private static let heldOutSeeds: [Int] = Array(600...605)    // M = 6

    private static let baseUtterance =
        "Search the depot for the red toolbox and report where you found it."
    private static let startPose = (x: 0.0, y: 1.0, yaw: Double.pi / 2)
    // Bumped from 15 (see RESULTS_learning_priors.md's first-run caveat: 10/22 episodes at
    // cap=15 never detected the toolbox at all, leaving too few clean before/after pairs).
    // 25 matches MissionAgent's own production default.
    private static let maxTicksPerEpisode = 25

    struct EpisodeResult {
        let seed: Int
        let primed: Bool
        let truthRoom: String?   // "A" (Workshop) or "B" (Storage), from oracle prop_truth
        let foundAtSeconds: Double?
        let reachedDone: Bool
    }

    func testLearningFromExperienceImprovesSearchTime() async throws {
        guard let url = ProcessInfo.processInfo.environment["LIVE_ROVER_ACT_URL"], !url.isEmpty else {
            throw XCTSkip("LIVE_ROVER_ACT_URL not set — run via eco/rover/sim/run_learn_priors.py.")
        }
        let link: GodotLink
        do {
            link = try GodotLink()
        } catch {
            throw XCTSkip("Godot Depot sim not reachable — launch it first.")
        }

        let config = PhroverCloudConfig(region: "us-west-2", apiEndpoint: url,
                                        identityPoolId: "", userPoolId: "",
                                        iotEndpoint: "", cognitoClientId: "")

        // --- Training: N real missions, no hint. Harvest ground-truth room per seed. ---
        var trainResults: [EpisodeResult] = []
        for seed in Self.trainSeeds {
            let result = await runEpisode(seed: seed, hint: nil, link: link, config: config)
            print("PRIOR_TRAIN \(jsonLine(seed: result.seed, room: result.truthRoom, foundAt: result.foundAtSeconds, done: result.reachedDone, primed: false))")
            trainResults.append(result)
        }

        let roomCounts = Dictionary(grouping: trainResults.compactMap { $0.truthRoom }, by: { $0 }).mapValues(\.count)
        let totalWithRoom = roomCounts.values.reduce(0, +)
        let majorityRoom = roomCounts.max(by: { $0.value < $1.value })?.key
        let hintSentence: String? = majorityRoom.map { room in
            let pct = totalWithRoom > 0 ? Int(round(100.0 * Double(roomCounts[room] ?? 0) / Double(totalWithRoom))) : 0
            let roomName = room == "A" ? "the Workshop (Room A)" : "the Storage room (Room B)"
            return "Note: based on \(totalWithRoom) past sweeps of this depot, the red toolbox " +
                   "was found in \(roomName) about \(pct)% of the time — worth checking there first if convenient."
        }
        print("=== learned prior: room counts \(roomCounts), hint = \(hintSentence ?? "(none — no training data)") ===")

        // --- Held-out: each seed run twice with the real brain — bare, then primed. ---
        var heldOutResults: [EpisodeResult] = []
        for seed in Self.heldOutSeeds {
            let baseline = await runEpisode(seed: seed, hint: nil, link: link, config: config)
            print("PRIOR_HELDOUT \(jsonLine(seed: baseline.seed, room: baseline.truthRoom, foundAt: baseline.foundAtSeconds, done: baseline.reachedDone, primed: false))")
            heldOutResults.append(baseline)

            let primed = await runEpisode(seed: seed, hint: hintSentence, link: link, config: config)
            print("PRIOR_HELDOUT \(jsonLine(seed: primed.seed, room: primed.truthRoom, foundAt: primed.foundAtSeconds, done: primed.reachedDone, primed: true))")
            heldOutResults.append(primed)
        }

        let baselineFound = heldOutResults.filter { !$0.primed }.compactMap(\.foundAtSeconds)
        let primedFound = heldOutResults.filter(\.primed).compactMap(\.foundAtSeconds)
        print("=== held-out baseline found-times: \(baselineFound) ===")
        print("=== held-out primed found-times: \(primedFound) ===")

        // Documentation run, not a pass/fail gate (see RESULTS_learning_priors.md for the
        // actual before/after comparison) — the one thing worth asserting is that every
        // episode terminated instead of hanging the whole 22-episode sweep.
        XCTAssertEqual(trainResults.count, Self.trainSeeds.count)
        XCTAssertEqual(heldOutResults.count, Self.heldOutSeeds.count * 2)
    }

    private func jsonLine(seed: Int, room: String?, foundAt: Double?, done: Bool, primed: Bool) -> String {
        let obj: [String: Any] = [
            "seed": seed, "room": room ?? NSNull(),
            "foundAtSeconds": foundAt ?? NSNull(), "reachedDone": done, "primed": primed,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func runEpisode(seed: Int, hint: String?, link: GodotLink,
                             config: PhroverCloudConfig) async -> EpisodeResult {
        let rid = "learner"
        link.call(["op": "reset", "seed": seed])
        link.call(["op": "phrover_spawn", "id": rid,
                    "p": [Self.startPose.x, Self.startPose.y], "yaw": Self.startPose.yaw])

        let truthProps = (link.call(["op": "prop_truth"])["props"] as? [[String: Any]]) ?? []
        let truthWorld = truthProps.first { ($0["label"] as? String) == "red_toolbox" }
            .flatMap { godotDoubleArray($0["world"]) }
        let truthRoom = truthWorld.map { $0[0] < -1.0 ? "A" : "B" }

        let events = EventLog()
        let motion = GodotMotion(link: link, rid: rid)
        let perception = InstrumentedPerception(inner: GodotPerception(link: link, rid: rid), events: events)
        let battery = GodotBattery(link: link, rid: rid)
        let voice = ScriptedVoice(events: events)
        let brain = CloudBrain(config: config)
        let recorder = RecordingBrain(wrapping: brain, events: events)

        let utterance = hint.map { "\(Self.baseUtterance) \($0)" } ?? Self.baseUtterance
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice,
                                  battery: battery, maxTicksPerUtterance: Self.maxTicksPerEpisode) { recorder }
        await agent.handle(utterance)
        link.call(["op": "phrover_despawn", "id": rid])

        let foundAt = events.events.first {
            $0.kind == "detect" && (($0.data["labels"] as? [String])?.contains("red_toolbox") ?? false)
        }?.t
        let reachedDone = events.events.contains {
            $0.kind == "decision" && (($0.data["decision"] as? String)?.contains("done") ?? false)
        }
        return EpisodeResult(seed: seed, primed: hint != nil, truthRoom: truthRoom,
                              foundAtSeconds: foundAt, reachedDone: reachedDone)
    }
}

/// Wraps `RoverPerception` to log every `detectObjects()` call's labels — lets the harness
/// (this file, plus eco/rover/sim/run_learn_priors.py parsing the same EVT stream) measure
/// time-to-find directly from what the sim actually reported was visible, independent of
/// whether/when the brain itself chose to mention it.
@MainActor
final class InstrumentedPerception: RoverPerception {
    private let inner: RoverPerception
    private let events: EventLog

    init(inner: RoverPerception, events: EventLog) {
        self.inner = inner
        self.events = events
    }

    var pose: Pose2D? { inner.pose }

    func detectObjects() -> [PerceivedObject] {
        let objs = inner.detectObjects()
        events.log("detect", ["labels": objs.map(\.label)])
        return objs
    }

    func unproject(normalizedPoint: CGPoint) -> Vec2? { inner.unproject(normalizedPoint: normalizedPoint) }
    func capturedFrameJPEG() -> Data? { inner.capturedFrameJPEG() }
    func explorationFrontiers() -> [Frontier] { inner.explorationFrontiers() }
}
