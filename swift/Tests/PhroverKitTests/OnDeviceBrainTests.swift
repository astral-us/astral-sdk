import XCTest
@testable import PhroverKit
import RoverNav

@MainActor
final class OnDeviceBrainTests: XCTestCase {
    func testCreatesFreshResponderForEachDecision() async throws {
        let factory = RecordingResponderFactory()
        let brain = OnDeviceBrain(isAvailable: { true }, makeResponder: factory.makeResponder)

        _ = try await brain.nextAction(MissionContext())
        _ = try await brain.nextAction(MissionContext())

        XCTAssertEqual(factory.createdCount, 2)
    }

    func testRejectsVisualTargetInventedOutsideCurrentMission() async throws {
        let responder = ScriptedOnDeviceBrainResponder(output: BrainOutput(
            decision: .navigate(.visualQuery("the green chair")),
            updatedPlan: "1. find the green chair"
        ))
        let brain = OnDeviceBrain(isAvailable: { true }, makeResponder: { responder })
        var memory = MissionMemory()
        memory.beginMission(utterance: "Find a chair", at: Pose2D(position: .zero, yaw: 0))

        let output = try await brain.nextAction(MissionContext(
            memory: memory,
            explorationCandidates: [
                ExplorationCandidate(id: "opening_1",
                                     worldPoint: Vec2(1, 0),
                                     widthMeters: 1,
                                     status: .visited),
                ExplorationCandidate(id: "opening_2",
                                     worldPoint: Vec2(2, 0),
                                     widthMeters: 1),
            ]
        ))

        XCTAssertEqual(output.decision, .explore(candidateId: "opening_2"))
        XCTAssertNil(output.updatedPlan)
    }
}

@MainActor
private final class RecordingResponderFactory {
    private(set) var createdCount = 0

    func makeResponder() -> OnDeviceBrainResponder {
        createdCount += 1
        return FakeOnDeviceBrainResponder()
    }
}

private struct FakeOnDeviceBrainResponder: OnDeviceBrainResponder {
    func nextAction(prompt: String, context: MissionContext) async throws -> BrainOutput {
        BrainOutput(decision: .done)
    }
}

private struct ScriptedOnDeviceBrainResponder: OnDeviceBrainResponder {
    let output: BrainOutput

    func nextAction(prompt: String, context: MissionContext) async throws -> BrainOutput {
        output
    }
}
