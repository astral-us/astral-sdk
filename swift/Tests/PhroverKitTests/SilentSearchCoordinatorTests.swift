import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class SilentSearchCoordinatorTests: XCTestCase {
    func testCalibrationRequiresCompleteReadiness() async throws {
        let harness = SilentSearchTestHarness()
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())

        XCTAssertFalse(coordinator.startCalibration())
        XCTAssertEqual(coordinator.phase, .setup)
        XCTAssertEqual(coordinator.diagnostic, .notReady([.tracking, .detector, .commandLink]))
        XCTAssertTrue(harness.calibration.requests.isEmpty)

        harness.readiness.snapshot = SilentSearchReadiness(
            tracking: .normal(sessionGeneration: 9),
            detectorLoaded: true,
            commandLinkAvailable: true
        )
        coordinator.refreshReadiness()

        XCTAssertTrue(coordinator.startCalibration())
        XCTAssertEqual(coordinator.phase, .calibrating)
        XCTAssertEqual(harness.calibration.requests.count, 1)
        XCTAssertEqual(harness.calibration.requests.first?.markerID, "SILENT_SEARCH_01")
        XCTAssertEqual(harness.calibration.requests.first?.generation, 9)
    }

    func testCalibrationProgressRejectionAndAcceptanceUpdatePublicState() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())

        harness.calibration.send(.progress(acceptedFrameCount: 2))
        await eventually { coordinator.calibrationProgress == 2 }
        XCTAssertEqual(coordinator.calibrationProgress, 2)

        harness.calibration.send(.rejected(.headingDeviationExceeded))
        await eventually { coordinator.diagnostic == .calibrationRejected(.headingDeviationExceeded) }
        XCTAssertEqual(coordinator.phase, .calibrating)
        XCTAssertEqual(coordinator.diagnostic, .calibrationRejected(.headingDeviationExceeded))

        let wrongGeneration = try XCTUnwrap(SharedMissionFrame(
            localOrigin: Vec2(1, 2), localNorthHeading: 0.3, sessionGeneration: 5
        ))
        harness.calibration.send(.accepted(wrongGeneration))
        await eventually { coordinator.diagnostic == .calibrationRejected(.generationMismatch) }
        XCTAssertEqual(coordinator.phase, .calibrating)
        XCTAssertEqual(coordinator.diagnostic, .calibrationRejected(.generationMismatch))

        let frame = try XCTUnwrap(SharedMissionFrame(
            localOrigin: Vec2(1, 2), localNorthHeading: 0.3, sessionGeneration: 4
        ))
        harness.calibration.send(.accepted(frame))
        await eventually { coordinator.phase == .handshake(.ready) }

        XCTAssertEqual(coordinator.sharedFrame, frame)
        XCTAssertEqual(coordinator.phase, .handshake(.ready))
        XCTAssertNil(coordinator.diagnostic)
    }

    func testTransitionTableAcceptsLegalEdgesAndRejectsIllegalEdges() throws {
        let coordinator = SilentSearchTestHarness().coordinator()

        XCTAssertThrowsError(try coordinator.transition(to: .searching)) {
            XCTAssertEqual($0 as? SilentSearchTransitionError, .illegal(from: .setup, to: .searching))
        }
        XCTAssertEqual(coordinator.phase, .setup)

        try coordinator.transition(to: .calibrating)
        try coordinator.transition(to: .handshake(.ready))
        try coordinator.transition(to: .handshake(.scanning))
        try coordinator.transition(to: .waitingForSearch)
        try coordinator.transition(to: .searching)
        try coordinator.transition(to: .returning)
        try coordinator.transition(to: .rendezvous(.ready))
        try coordinator.transition(to: .waitingForConvergence)
        try coordinator.transition(to: .converging)
        try coordinator.transition(to: .terminal(.success))
        try coordinator.transition(to: .setup)

        XCTAssertEqual(coordinator.phase, .setup)
    }

    func testMissionRejectsInvalidSetupValues() {
        XCTAssertNil(SilentSearchMission(
            role: .a, targetLabel: " chair", searchDurationSeconds: 120, markerID: "SILENT_SEARCH_01"
        ))
        XCTAssertNil(SilentSearchMission(
            role: .a, targetLabel: "chair", searchDurationSeconds: 0, markerID: "SILENT_SEARCH_01"
        ))
        XCTAssertNil(SilentSearchMission(
            role: .a, targetLabel: "chair", searchDurationSeconds: 120, markerID: "not canonical"
        ))
    }

    func testStopAwaitsMotionBeforePublishingStableTerminalState() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 1)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        harness.motion.onStop = { XCTAssertNotEqual(coordinator.phase, .terminal(.operatorStopped)) }

        await coordinator.stop()

        XCTAssertEqual(harness.motion.stopCount, 1)
        XCTAssertEqual(coordinator.phase, .terminal(.operatorStopped))
        XCTAssertEqual(harness.events.entries.last?.event, "silent_search_phase_transition")

        await coordinator.abort()
        XCTAssertEqual(harness.motion.stopCount, 1)
        XCTAssertEqual(coordinator.phase, .terminal(.operatorStopped))
    }

    func testAbortCancelsCalibrationAndStopsBeforeTerminal() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 2)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())

        await coordinator.abort()

        XCTAssertEqual(harness.calibration.cancelCount, 1)
        XCTAssertEqual(harness.motion.stopCount, 1)
        XCTAssertEqual(coordinator.phase, .terminal(.operatorAborted))
    }

    func testResetClearsMissionCalibrationAndTerminalResult() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 3)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        await coordinator.stop()

        await coordinator.reset()

        XCTAssertEqual(coordinator.phase, .setup)
        XCTAssertNil(coordinator.mission)
        XCTAssertNil(coordinator.sharedFrame)
        XCTAssertEqual(coordinator.calibrationProgress, 0)
        XCTAssertNil(coordinator.diagnostic)
    }

    func testManualClockResumesOnlyReachedDeadlinesAndSafetyStreamIsMulticast() async throws {
        let harness = SilentSearchTestHarness()
        var resumed: [String] = []
        let first = Task { try await harness.clock.sleep(until: 10); resumed.append("first") }
        let second = Task { try await harness.clock.sleep(until: 20); resumed.append("second") }
        let cancelled = Task {
            do {
                try await harness.clock.sleep(until: 30)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await taskTurn()
        cancelled.cancel()
        let cancellationObserved = await cancelled.value
        XCTAssertTrue(cancellationObserved)

        harness.clock.advance(nanoseconds: 10)
        await taskTurn()
        XCTAssertEqual(resumed, ["first"])

        let leftTask = Task {
            var iterator = harness.safety.events().makeAsyncIterator()
            return await iterator.next()
        }
        let rightTask = Task {
            var iterator = harness.safety.events().makeAsyncIterator()
            return await iterator.next()
        }
        await taskTurn()
        harness.safety.send(.operatorStop)
        let left = await leftTask.value
        let right = await rightTask.value
        XCTAssertEqual(left, .operatorStop)
        XCTAssertEqual(right, .operatorStop)

        harness.clock.advance(nanoseconds: 10)
        _ = try await (first.value, second.value)
    }

    private func mission() throws -> SilentSearchMission {
        try XCTUnwrap(SilentSearchMission(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            role: .a,
            targetLabel: "chair",
            searchDurationSeconds: 120,
            markerID: "SILENT_SEARCH_01"
        ))
    }

    private func taskTurn() async {
        await Task.yield()
        await Task.yield()
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
    }
}
