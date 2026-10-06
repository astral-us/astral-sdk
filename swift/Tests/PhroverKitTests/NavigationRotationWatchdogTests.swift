import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class NavigationRotationWatchdogTests: XCTestCase {
    func testCancelledPulseStopIsSafeOnlyAfterIndependentConfirmedStop() async throws {
        let pulseStop = SuspendedPulseStop()
        let source = FollowRotationSourceFixture()
        var stops = 0
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 }, plan: { _, goal in [goal] },
            lastAckAt: { Date() }, sendCommand: { _ in },
            stopRover: { stops += 1; if stops == 2 { try await pulseStop.send() } },
            sleep: { await source.advance($0) }, poseSample: { source.snapshot }, sourceNow: { source.uptime },
            sourceEvents: { source.events.stream }, sourceStopSnapshot: { source.snapshot })
        source.controller = controller
        var failures: [NavigationSafetyState] = []
        let observer = Task {
            for await state in controller.safetyStates() {
                if case .failed = state { failures.append(state) }
            }
        }
        let scan = Task { await controller.rotateForFollowScan(by: .pi / 6) }
        await pulseStop.waitUntilRequested()
        let independentStop = Task { try await controller.stopAndConfirm() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(stops, 2, "An independent stop must drain the actual pending pulse stop")
        pulseStop.fail()
        try await independentStop.value
        let result = await scan.value
        for _ in 0..<20 { await Task.yield() }
        observer.cancel()
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(controller.safetyState, .idle)
        XCTAssertTrue(failures.isEmpty, "Intentional pulse cancellation must defer outcome to the independent stop")
        XCTAssertGreaterThan(stops, 2)
    }

    func testFollowScanUsesFixedReliableWheelMagnitude() async {
        let source = FollowRotationSourceFixture()
        var commands: [WheelCommand] = []
        let controller = NavigationController(
            currentPose: { source.snapshot.pose },
            forwardClearance: { 2 }, plan: { _, goal in [goal] },
            lastAckAt: { Date() }, sendCommand: { commands.append($0); source.yaw = .pi / 6 },
            stopRover: {}, sleep: { await source.advance($0) }, poseSample: { source.snapshot },
            sourceNow: { source.uptime }, sourceEvents: { source.events.stream }, sourceStopSnapshot: { source.snapshot })
        source.controller = controller
        let result = await controller.rotateForFollowScan(by: .pi / 6)
        XCTAssertEqual(result, .arrived)
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.allSatisfy { abs($0.left) == 0.25 && abs($0.right) == 0.25 })
        XCTAssertTrue(commands.allSatisfy { $0.left < 0 && $0.right > 0 })
    }

    func testFollowAlignmentFailsClosedWhenInternalPreturnStopFailsAfterCoordinatorStopSucceeded() async throws {
        var stops = 0
        var commands: [WheelCommand] = []
        var yaw = 0.0
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: yaw) },
            forwardClearance: { 2 },
            plan: { _, goal in [goal] },
            lastAckAt: { Date() },
            sendCommand: { commands.append($0) },
            stopRover: {
                stops += 1
                if stops > 1 { throw RotationStopError.failed }
            },
            sleep: { _ in yaw = .pi / 2 }
        )
        let motion = NavigationFollowMeMotion(navigation: controller)

        // The coordinator's pre-stop is successful. Navigation must still honor
        // a newer internal preturn stop failure rather than silently rotate.
        try await motion.stopAndConfirm()
        XCTAssertEqual(stops, 1)
        let result = await motion.alignTowardPerson(by: .pi / 2)

        XCTAssertEqual(result, .failed(.commandFailed))
        XCTAssertTrue(commands.allSatisfy { $0.left == 0 && $0.right == 0 }, "No nonzero wheel command after unconfirmed stop")
        XCTAssertEqual(controller.state, .failed("Rover stop could not be confirmed."))
        XCTAssertEqual(controller.safetyState, .failed(.commandFailed))
        let retry = await motion.alignTowardPerson(by: .pi / 2)
        XCTAssertEqual(retry, .failed(.commandFailed), "Failure remains latched until an explicit confirmed-stop retry")
        XCTAssertEqual(stops, 2, "Blocked alignment must not retry or bypass the failed serialized stop")
        XCTAssertTrue(commands.isEmpty)
    }

    func testStopAndConfirmCancelsSuspendedRotationSendsWithoutPublishingFailure() async throws {
        for scan in [false, true] {
            for error: Error in [CancellationError(), URLError(.cancelled)] {
                let send = SuspendedNavigationSend(error: error)
                let source = FollowRotationSourceFixture()
                var stops = 0
                let controller = NavigationController(
                    currentPose: { Pose2D(position: .zero, yaw: 0) },
                    forwardClearance: { 2 },
                    plan: { _, goal in [goal] },
                    lastAckAt: { nil },
                    sendCommand: { _ in try await send.send() },
                    stopRover: { stops += 1 },
                    sleep: { await source.advance($0) }, poseSample: { source.snapshot }, sourceNow: { source.uptime },
                    sourceEvents: { source.events.stream }, sourceStopSnapshot: { source.snapshot }
                )
                source.controller = controller
                let states = controller.safetyStates()
                let received = Task { () -> [NavigationSafetyState] in
                    var result: [NavigationSafetyState] = []
                    for await state in states {
                        result.append(state)
                        if result.contains(.moving), state == .idle { break }
                    }
                    return result
                }
                let rotation = Task {
                    if scan { return await controller.rotateForFollowScan(by: .pi / 6) }
                    return await controller.rotateAndWait(by: .pi / 6)
                }
                await send.waitUntilRequested()

                try await controller.stopAndConfirm()

                let result = await rotation.value
                let safetyStates = await received.value
                XCTAssertEqual(result, .cancelled)
                XCTAssertEqual(safetyStates, [.idle, .moving, .idle], "scan=\(scan), error=\(error)")
                XCTAssertEqual(controller.state, .idle)
                XCTAssertGreaterThanOrEqual(stops, 2)
            }
        }
    }

    func testFollowScanWaitsForConfirmedStopAndReturnsResult() async {
        let stop = SuspendedRotationStop()
        var commands = 0
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 },
            plan: { _, goal in [goal] },
            lastAckAt: { nil },
            sendCommand: { _ in commands += 1 },
            stopRover: { try await stop.confirm() },
            sleep: { _ in }
        )
        let scan = Task { await controller.rotateForFollowScan(by: .pi / 6) }
        await stop.waitUntilRequested()
        XCTAssertEqual(commands, 0)
        stop.fail()
        let result = await scan.value
        XCTAssertEqual(result, .failed(.commandFailed))
        XCTAssertEqual(commands, 0)
    }

    func testUnrequestedURLRotationSendCancellationRemainsCommandFailure() async {
        for scan in [false, true] {
            let source = FollowRotationSourceFixture()
            let controller = NavigationController(
                currentPose: { Pose2D(position: .zero, yaw: 0) },
                forwardClearance: { 2 },
                plan: { _, goal in [goal] },
                lastAckAt: { nil },
                sendCommand: { _ in throw URLError(.cancelled) },
                stopRover: {},
                sleep: { await source.advance($0) }, poseSample: { source.snapshot }, sourceNow: { source.uptime },
                sourceEvents: { source.events.stream }, sourceStopSnapshot: { source.snapshot }
            )
            source.controller = controller
            let states = controller.safetyStates()
            let failure = Task { () -> NavigationSafetyState? in
                for await state in states {
                    if case .failed = state { return state }
                }
                return nil
            }

            let result = scan
                ? await controller.rotateForFollowScan(by: .pi / 6)
                : await controller.rotateAndWait(by: .pi / 6)

            XCTAssertEqual(result, .failed(.commandFailed))
            let publishedFailure = await failure.value
            XCTAssertEqual(publishedFailure, .failed(.commandFailed))
        }
    }

    func testCancelledScanPulseStopRemainsFailureWhenFinalStopIsUnconfirmed() async {
        let pulseStop = SuspendedPulseStop()
        let source = FollowRotationSourceFixture()
        var stops = 0
        var commands = 0
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 },
            plan: { _, goal in [goal] },
            lastAckAt: { nil },
            sendCommand: { _ in commands += 1 },
            stopRover: {
                stops += 1
                if stops == 2 { try await pulseStop.send() }
                if stops > 2 { throw RotationStopError.failed }
            },
            sleep: { await source.advance($0) }, poseSample: { source.snapshot }, sourceNow: { source.uptime },
            sourceEvents: { source.events.stream }, sourceStopSnapshot: { source.snapshot }
        )
        source.controller = controller
        let scan = Task { await controller.rotateForFollowScan(by: .pi / 6) }
        await pulseStop.waitUntilRequested()

        let independentStop = Task { try await controller.stopAndConfirm() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(stops, 2, "Replacement stop cannot overtake the pending stop response")
        pulseStop.fail()
        do {
            try await independentStop.value
            XCTFail("A cancelled pulse stop does not confirm that the motors stopped")
        } catch {
            XCTAssertEqual(error as? RotationStopError, .failed)
        }

        _ = await scan.value
        XCTAssertEqual(controller.safetyState, .failed(.commandFailed))
        XCTAssertEqual(controller.state, .failed("Rover stop could not be confirmed."))
        let nextScan = await controller.rotateForFollowScan(by: .pi / 6)
        XCTAssertEqual(nextScan, .failed(.commandFailed))
        XCTAssertEqual(commands, 1, "An unconfirmed pulse stop must prevent more motion")
    }

    func testFollowScanStopsSendingPulsesWhenPulseStopFails() async {
        let source = FollowRotationSourceFixture()
        var stopCount = 0
        var commands = 0
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 },
            plan: { _, goal in [goal] },
            lastAckAt: { nil },
            sendCommand: { _ in commands += 1 },
            stopRover: {
                stopCount += 1
                if stopCount == 2 { throw RotationStopError.failed }
            },
            sleep: { await source.advance($0) }, poseSample: { source.snapshot }, sourceNow: { source.uptime },
            sourceEvents: { source.events.stream }, sourceStopSnapshot: { source.snapshot }
        )
        source.controller = controller
        let result = await controller.rotateForFollowScan(by: .pi / 6)
        XCTAssertEqual(result, .failed(.commandFailed))
        XCTAssertEqual(commands, 1)
    }
    func testCommandedRotationWithoutYawProgressStopsAndFailsStalled() async {
        let harness = RotationHarness(yaws: [0])
        let controller = harness.makeController()

        let result = await controller.rotateAndWait(by: .pi / 2)

        XCTAssertEqual(result, .failed(.stalled))
        XCTAssertEqual(controller.state, .failed("Navigation stalled."))
        XCTAssertEqual(harness.sentCommands.count, 3)
        XCTAssertEqual(harness.stopCount, 2)
        XCTAssertFalse(harness.stopInProgress)
    }

    func testYawProgressResetsRotationStallDeadline() async {
        let harness = RotationHarness(yaws: [0, 0, 0.1])
        let controller = harness.makeController()

        let result = await controller.rotateAndWait(by: .pi / 2)

        XCTAssertEqual(result, .failed(.stalled))
        XCTAssertEqual(harness.sentCommands.count, 4)
        XCTAssertEqual(harness.stopCount, 2)
    }

    func testCommandedRotationArrivesNormallyWhenYawReachesTarget() async {
        let harness = RotationHarness(yaws: [0, 0, .pi / 2])
        let controller = harness.makeController()

        let result = await controller.rotateAndWait(by: .pi / 2)

        XCTAssertEqual(result, .arrived)
        XCTAssertEqual(controller.state, .arrived)
        XCTAssertEqual(harness.sentCommands.count, 1)
        XCTAssertEqual(harness.stopCount, 2)
        XCTAssertFalse(harness.stopInProgress)
    }

    func testScanRotationKeepsPulseStopsAndAlsoFailsClosedWithoutYawProgress() async {
        let harness = RotationHarness(yaws: [0])
        let controller = harness.makeController()

        await controller.rotateForScan(by: .pi / 2)

        XCTAssertEqual(controller.state, .failed("Navigation stalled."))
        XCTAssertEqual(harness.sentCommands.count, 2)
        XCTAssertEqual(harness.stopCount, 4)
        XCTAssertFalse(harness.stopInProgress)
    }
}

@MainActor
private final class SuspendedRotationStop {
    private var requested = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Error>?

    func confirm() async throws {
        requested = true
        requestWaiter?.resume()
        requestWaiter = nil
        try await withCheckedThrowingContinuation { stopWaiter = $0 }
    }
    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func fail() {
        stopWaiter?.resume(throwing: RotationStopError.failed)
        stopWaiter = nil
    }
}

private enum RotationStopError: Error { case failed }

@MainActor
private final class SuspendedPulseStop {
    private var requested = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<Void, Error>?
    func send() async throws {
        requested = true
        requestWaiter?.resume(); requestWaiter = nil
        try await withCheckedThrowingContinuation { response = $0 }
    }
    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func fail() { response?.resume(throwing: URLError(.cancelled)); response = nil }
}

/// Explicit simulated camera captures at timer boundaries. Provider reads only
/// return stored evidence; they never manufacture sequence/time advancement.
@MainActor
private final class FollowRotationSourceFixture {
    weak var controller: NavigationController?
    var uptime = 10.0
    var yaw = 0.0
    let events = AsyncStream<NavigationPoseSample>.makeStream()
    var snapshot = NavigationPoseSample(pose: .init(position: .zero, yaw: 0),
        frameID: .init(generation: 1, sequence: 1), sourceTimestamp: 9.99, trackingQuality: .normal)

    func advance(_ duration: Duration) async {
        await Task.yield()
        guard !Task.isCancelled else { return }
        let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        uptime += elapsed
        snapshot = .init(pose: .init(position: .zero, yaw: yaw),
            frameID: .init(generation: 1, sequence: snapshot.frameID!.sequence + 1),
            sourceTimestamp: uptime, trackingQuality: .normal)
        controller?.ingestFollowTurnSource(snapshot)
    }
}

@MainActor
private final class RotationHarness {
    private var yaws: [Double]
    private var poseReadCount = 0
    private var now = Date(timeIntervalSince1970: 10)
    private(set) var sentCommands: [WheelCommand] = []
    private(set) var stopCount = 0
    private(set) var stopInProgress = false

    init(yaws: [Double]) {
        self.yaws = yaws
    }

    func makeController() -> NavigationController {
        NavigationController(
            currentPose: {
                let yaw = self.yaws[min(self.poseReadCount, self.yaws.count - 1)]
                self.poseReadCount += 1
                return Pose2D(position: .zero, yaw: yaw)
            },
            forwardClearance: { 2 },
            plan: { _, goal in [goal] },
            lastAckAt: { self.now },
            sendCommand: { self.sentCommands.append($0) },
            stopRover: {
                self.stopInProgress = true
                await Task.yield()
                self.stopCount += 1
                self.stopInProgress = false
            },
            sleep: { _ in self.now = self.now.addingTimeInterval(1) },
            now: { self.now }
        )
    }
}
