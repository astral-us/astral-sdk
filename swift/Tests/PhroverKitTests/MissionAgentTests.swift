import XCTest
import CoreGraphics
import RoverNav
@testable import PhroverKit

/// Exercises `MissionAgent`'s decision loop against scripted fakes for `RoverBrain`,
/// `RoverMotion`, `RoverPerception`, and `RoverVoice` — no live ARKit session, no bundled
/// CoreML model, no network. This is the "does the loop do the right thing given a
/// decision" layer; live grounding accuracy and on-device Foundation Model behavior can
/// only be verified on a real device (see rover/README.md status notes).
@MainActor
final class MissionAgentTests: XCTestCase {
    func testGroundsVisibleTargetAndFinishes() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        let voice = FakeVoice()
        let brain = FakeBrain(script: [.navigate(.imagePoint(CGPoint(x: 0.5, y: 0.5))), .done])
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice) { brain }

        await agent.handle("go to the chair")

        XCTAssertEqual(motion.navigateCalls, [perception.unprojectResult])
        XCTAssertEqual(agent.phase, .idle)
    }

    func testLooksAroundWhenNothingVisible() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        let voice = FakeVoice()
        let brain = FakeBrain(script: [.lookAround(angle: .pi), .done])
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice) { brain }

        await agent.handle("go to the chair")

        XCTAssertEqual(motion.rotateCalls, [.pi])
    }

    func testSearchesOpeningWhenVisualTargetIsNotCurrentlyDetected() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        perception.frontiers = [Frontier(centroid: Vec2(2, 1), widthMeters: 1.0, cellCount: 5)]
        let voice = FakeVoice()
        let brain = FakeBrain(script: [.navigate(.visualQuery("chair")), .done])
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice) { brain }

        await agent.handle("go to the chair")

        XCTAssertEqual(motion.navigateCalls, [Vec2(2, 1)])
        XCTAssertTrue(voice.spoken.isEmpty)
    }

    func testScansWhenVisualTargetIsNotDetectedAndNoOpeningIsKnown() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        let voice = FakeVoice()
        let brain = FakeBrain(script: [.navigate(.visualQuery("table")), .done])
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice) { brain }

        await agent.handle("go to the table")

        XCTAssertEqual(motion.rotateCalls, [.pi / 2])
        XCTAssertTrue(voice.spoken.isEmpty)
    }

    func testReportsPhaseChangesWhileHandlingCommand() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        let voice = FakeVoice()
        let brain = FakeBrain(script: [.lookAround(angle: .pi), .done])
        var observedPhases: [MissionAgent.Phase] = []
        let agent = MissionAgent(motion: motion,
                                 perception: perception,
                                 voice: voice,
                                 phaseDidChange: { observedPhases.append($0) },
                                 currentBrain: { brain })

        await agent.handle("turn left")

        XCTAssertTrue(observedPhases.contains(.thinking))
        XCTAssertTrue(observedPhases.contains(.acting))
        XCTAssertEqual(observedPhases.last, .idle)
    }

    func testAsksThenActsOnTheAnswer() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        let voice = FakeVoice()
        voice.scriptedReplies = ["the kitchen"]
        let brain = FakeBrain(script: [.ask("Where should I go?"), .done])
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice) { brain }

        await agent.handle("go somewhere")

        XCTAssertEqual(voice.spoken, ["Where should I go?"])
        // The reply becomes both a memory entry and the next think-tick's utterance.
        XCTAssertEqual(brain.seenContexts.map(\.utterance), ["go somewhere", "the kitchen"])
        XCTAssertTrue(agent.memory.turns.contains { $0.utterance == "the kitchen" })
    }

    func testProceedsBestEffortOnNoAnswer() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        let voice = FakeVoice()
        voice.scriptedReplies = [nil]
        let brain = FakeBrain(script: [.ask("Where?"), .done])
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice) { brain }

        await agent.handle("go somewhere")

        // No reply came back, so the next tick carries no fresh utterance but is flagged
        // so the brain knows not to just ask the same question again.
        XCTAssertEqual(brain.seenContexts.count, 2)
        XCTAssertNil(brain.seenContexts[1].utterance)
        XCTAssertTrue(brain.seenContexts[1].lastAnswerWasInconclusive)
    }

    func testStopsGracefullyWhenNoBrainIsAvailable() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        let voice = FakeVoice()
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice) { nil }

        await agent.handle("go to the chair")

        XCTAssertEqual(agent.phase, .idle)
        XCTAssertFalse(voice.spoken.isEmpty)
        XCTAssertTrue(motion.navigateCalls.isEmpty)
    }

    func testLogsBrainErrorsWithContext() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        perception.objects = [PerceivedObject(label: "chair", confidence: 0.82, normalizedPoint: CGPoint(x: 0.4, y: 0.6))]
        perception.frontiers = [Frontier(centroid: Vec2(2, 1), widthMeters: 1.0, cellCount: 5)]
        let voice = FakeVoice()
        let brain = ThrowingBrain(error: FakeBrainError.modelUnavailable)
        var logged: [(error: Error, context: MissionContext)] = []
        let agent = MissionAgent(motion: motion,
                                 perception: perception,
                                 voice: voice,
                                 brainErrorLogger: { error, context in logged.append((error, context)) },
                                 currentBrain: { brain })

        await agent.handle("go to the chair")

        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.error as? FakeBrainError, .modelUnavailable)
        XCTAssertEqual(logged.first?.context.utterance, "go to the chair")
        XCTAssertEqual(logged.first?.context.visibleObjects.map(\.label), ["chair"])
        XCTAssertEqual(logged.first?.context.explorationCandidates.map(\.id), ["opening_1"])
        XCTAssertEqual(voice.spoken, ["Sorry, I'm having trouble thinking right now."])
    }

    func testStopDecisionCancelsMotion() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        let voice = FakeVoice()
        let brain = FakeBrain(script: [.stop])
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice) { brain }

        await agent.handle("never mind")

        XCTAssertEqual(motion.cancelCallCount, 1)
    }

    func testEmergencyStopBypassesMissingPoseAndBrain() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        perception.pose = nil
        let voice = FakeVoice()
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice) { nil }

        await agent.handle("stop")

        XCTAssertEqual(motion.cancelCallCount, 1)
        XCTAssertEqual(agent.phase, .idle)
        XCTAssertTrue(voice.spoken.isEmpty)
    }

    func testEmergencyStopBypassesBrainErrors() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        let voice = FakeVoice()
        let brain = ThrowingBrain(error: FakeBrainError.modelUnavailable)
        var logged: [(error: Error, context: MissionContext)] = []
        let agent = MissionAgent(motion: motion,
                                 perception: perception,
                                 voice: voice,
                                 brainErrorLogger: { error, context in logged.append((error, context)) },
                                 currentBrain: { brain })

        await agent.handle("emergency stop")

        XCTAssertEqual(motion.cancelCallCount, 1)
        XCTAssertEqual(agent.phase, .idle)
        XCTAssertTrue(voice.spoken.isEmpty)
        XCTAssertTrue(logged.isEmpty)
    }

    func testNormalCommandDoesNotEnterBrainWhileMissionIsThinking() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        let voice = FakeVoice()
        let brain = BlockingBrain()
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice) { brain }

        let first = Task { @MainActor in await agent.handle("go to the chair") }
        await brain.waitUntilEntered()

        let second = Task { @MainActor in await agent.handle("go to the table") }
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(brain.seenContexts.map(\.utterance), ["go to the chair"])
        XCTAssertEqual(voice.spoken, ["I'm still working on the previous command. Say stop if you want me to cancel it."])

        brain.finishAll(with: .done)
        await first.value
        await second.value
    }

    func testEmergencyStopInvalidatesInFlightBrainDecision() async {
        let motion = FakeMotion()
        let perception = FakePerception()
        let voice = FakeVoice()
        let brain = BlockingBrain()
        let agent = MissionAgent(motion: motion, perception: perception, voice: voice) { brain }

        let first = Task { @MainActor in await agent.handle("go to the chair") }
        await brain.waitUntilEntered()

        await agent.handle("stop")
        brain.finishAll(with: .navigate(.worldPoint(Vec2(4, 5))))
        await first.value

        XCTAssertEqual(motion.cancelCallCount, 1)
        XCTAssertTrue(motion.navigateCalls.isEmpty)
        XCTAssertEqual(agent.phase, .idle)
    }
}

// MARK: - Fakes

private enum FakeBrainError: Error, Equatable {
    case modelUnavailable
}

@MainActor
private final class FakeBrain: RoverBrain {
    private var script: [RoverDecision]
    private(set) var seenContexts: [MissionContext] = []

    init(script: [RoverDecision]) { self.script = script }

    func nextAction(_ context: MissionContext) async throws -> BrainOutput {
        seenContexts.append(context)
        return BrainOutput(decision: script.isEmpty ? .done : script.removeFirst())
    }
}

@MainActor
private final class ThrowingBrain: RoverBrain {
    private let error: Error

    init(error: Error) { self.error = error }

    func nextAction(_ context: MissionContext) async throws -> BrainOutput {
        throw error
    }
}

@MainActor
private final class BlockingBrain: RoverBrain {
    private(set) var seenContexts: [MissionContext] = []
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var decision: RoverDecision?

    func nextAction(_ context: MissionContext) async throws -> BrainOutput {
        seenContexts.append(context)
        enteredContinuation?.resume()
        enteredContinuation = nil
        while decision == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return BrainOutput(decision: decision ?? .done)
    }

    func waitUntilEntered() async {
        guard seenContexts.isEmpty else { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func finishAll(with decision: RoverDecision) {
        self.decision = decision
    }
}

@MainActor
private final class FakeMotion: RoverMotion {
    var state: NavigationController.State = .idle
    private(set) var navigateCalls: [Vec2] = []
    private(set) var rotateCalls: [Double] = []
    private(set) var cancelCallCount = 0
    /// What `state` settles to shortly after `navigate(to:)` — simulates the real drive
    /// loop reaching `.arrived` asynchronously.
    var navigateOutcome: NavigationController.State = .arrived

    func navigate(to goal: Vec2) {
        navigateCalls.append(goal)
        state = .driving
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            state = navigateOutcome
        }
    }

    func rotate(by angle: Double) async { rotateCalls.append(angle) }

    func cancel() { cancelCallCount += 1 }
}

@MainActor
private final class FakePerception: RoverPerception {
    var pose: Pose2D? = Pose2D(position: .zero, yaw: 0)
    var objects: [PerceivedObject] = []
    var frontiers: [Frontier] = []
    var unprojectResult: Vec2? = Vec2(1, 2)

    func detectObjects() -> [PerceivedObject] { objects }
    func unproject(normalizedPoint: CGPoint) -> Vec2? { unprojectResult }
    func capturedFrameJPEG() -> Data? { nil }
    func explorationFrontiers() -> [Frontier] { frontiers }
}

@MainActor
private final class FakeVoice: RoverVoice {
    private(set) var spoken: [String] = []
    var scriptedReplies: [String?] = []

    func speak(_ text: String) { spoken.append(text) }

    func ask(_ question: String, timeout: TimeInterval) async -> String? {
        spoken.append(question)
        return scriptedReplies.isEmpty ? nil : scriptedReplies.removeFirst()
    }
}
