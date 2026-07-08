import XCTest
@testable import PhroverKit

@MainActor
final class OnDeviceBrainTests: XCTestCase {
    func testCreatesFreshResponderForEachDecision() async throws {
        let factory = RecordingResponderFactory()
        let brain = OnDeviceBrain(isAvailable: { true }, makeResponder: factory.makeResponder)

        _ = try await brain.nextAction(MissionContext())
        _ = try await brain.nextAction(MissionContext())

        XCTAssertEqual(factory.createdCount, 2)
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
