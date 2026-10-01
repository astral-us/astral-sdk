import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class NavigationSafetyTests: XCTestCase {
    func testStopAndConfirmCancelsSuspendedURLSendWithoutPublishingFailure() async throws {
        try await assertIntentionalSendCancellation(error: URLError(.cancelled))
    }

    func testStopAndConfirmCancelsSuspendedTaskSendWithoutPublishingFailure() async throws {
        try await assertIntentionalSendCancellation(error: CancellationError())
    }

    private func assertIntentionalSendCancellation(error: Error) async throws {
        let send = SuspendedNavigationSend(error: error)
        var stops = 0
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 },
            plan: { _, goal in [goal] },
            lastAckAt: { nil },
            sendCommand: { _ in try await send.send() },
            stopRover: { stops += 1 },
            sleep: { _ in }
        )
        let states = controller.safetyStates()
        let received = Task { () -> [NavigationSafetyState] in
            var result: [NavigationSafetyState] = []
            for await state in states {
                result.append(state)
                if result.contains(.moving), state == .idle { break }
            }
            return result
        }
        let navigation = Task { await controller.navigateAndWait(to: Vec2(2, 0)) }
        await send.waitUntilRequested()

        try await controller.stopAndConfirm()

        let result = await navigation.value
        let safetyStates = await received.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(safetyStates, [.idle, .moving, .idle])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertGreaterThanOrEqual(stops, 2, "Cancellation still requires an acknowledged motor stop")
    }

    func testUnrequestedURLSendCancellationRemainsCommandFailure() async {
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 },
            plan: { _, goal in [goal] },
            lastAckAt: { nil },
            sendCommand: { _ in throw URLError(.cancelled) },
            stopRover: {},
            sleep: { _ in }
        )

        let result = await controller.navigateAndWait(to: Vec2(2, 0))

        XCTAssertEqual(result, .failed(.commandFailed))
        XCTAssertEqual(controller.safetyState, .failed(.commandFailed))
    }

    func testIntentionalSendCancellationDoesNotHideUnconfirmedMotorStop() async {
        for error: Error in [FakeCommandError.timedOut, URLError(.cancelled)] {
            let send = SuspendedNavigationSend(error: URLError(.cancelled))
            var stops = 0
            var plans = 0
            let controller = NavigationController(
                currentPose: { Pose2D(position: .zero, yaw: 0) },
                forwardClearance: { 2 },
                plan: { _, goal in plans += 1; return [goal] },
                lastAckAt: { nil },
                sendCommand: { _ in try await send.send() },
                stopRover: {
                    stops += 1
                    if stops > 1 { throw error }
                },
                sleep: { _ in }
            )
            let navigation = Task { await controller.navigateAndWait(to: Vec2(2, 0)) }
            await send.waitUntilRequested()

            do {
                try await controller.stopAndConfirm()
                XCTFail("An unconfirmed motor stop must throw")
            } catch let stopError {
                XCTAssertEqual((stopError as NSError).domain, (error as NSError).domain)
                XCTAssertEqual((stopError as NSError).code, (error as NSError).code)
            }

            let result = await navigation.value
            XCTAssertEqual(result, .cancelled, "The motion task is cancelled, not arrived")
            XCTAssertEqual(controller.state, .failed("Rover stop could not be confirmed."))
            XCTAssertEqual(controller.safetyState, .failed(.commandFailed))
            let nextGoal = await controller.navigateForFollow(to: Vec2(3, 0), stoppingAtForwardClearance: 1.5)
            XCTAssertEqual(nextGoal, .failed(.commandFailed))
            XCTAssertEqual(plans, 1, "Failed stop confirmation must bar subsequent motion")
        }
    }

    func testConfirmedStopPropagatesFailureAndBarsFollowGoal() async {
        var goals = 0
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 },
            plan: { _, goal in goals += 1; return [goal] },
            lastAckAt: { nil },
            sendCommand: { _ in },
            stopRover: { throw FakeCommandError.timedOut },
            sleep: { _ in }
        )

        do {
            try await controller.stopAndConfirm()
            XCTFail("Stop must propagate its error")
        } catch {
            XCTAssertEqual(error as? FakeCommandError, .timedOut)
        }
        let result = await controller.navigateForFollow(to: Vec2(2, 0), stoppingAtForwardClearance: 1.5)
        XCTAssertEqual(result, .failed(.commandFailed))
        XCTAssertEqual(goals, 0)
    }

    func testFollowGoalWaitsForMotorStopBeforePlanning() async {
        let stop = SuspendedNavigationStop()
        var plans = 0
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 },
            plan: { _, goal in plans += 1; return [goal] },
            lastAckAt: { nil },
            sendCommand: { _ in throw FakeCommandError.timedOut },
            stopRover: { await stop.confirm() },
            sleep: { _ in }
        )
        let goal = Task { await controller.navigateForFollow(to: Vec2(2, 0), stoppingAtForwardClearance: 1.5) }
        await stop.waitUntilRequested()
        XCTAssertEqual(plans, 0)
        stop.finish()
        let result = await goal.value
        XCTAssertEqual(plans, 1)
        XCTAssertEqual(result, .failed(.commandFailed))
    }


    func testFollowGoalDoesNotReportArrivalWhenMotorStopFails() async {
        var stops = 0
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 },
            plan: { _, goal in [goal] },
            lastAckAt: { nil },
            sendCommand: { _ in },
            stopRover: {
                stops += 1
                if stops > 1 { throw FakeCommandError.timedOut }
            },
            sleep: { _ in }
        )
        let result = await controller.navigateForFollow(to: .zero, stoppingAtForwardClearance: 1.5)
        XCTAssertEqual(result, .failed(.commandFailed))
    }

    func testFollowGoalDoesNotTreatUnrelatedNearObstacleAsPersonArrival() async {
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 0.30 },
            plan: { _, goal in [goal] },
            lastAckAt: { Date() },
            sendCommand: { _ in },
            stopRover: {},
            sleep: { _ in }
        )

        let result = await controller.navigateForFollow(to: Vec2(0, 1),
                                                         stoppingAtForwardClearance: 1.25)

        XCTAssertEqual(result, .failed(.obstacle))
    }

    func testFollowGoalDoesNotCountObstacleAsArrivalEvenNearWaypoint() async {
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 0.30 },
            plan: { _, goal in [goal] },
            lastAckAt: { Date() },
            sendCommand: { _ in }, stopRover: {}, sleep: { _ in }
        )

        let result = await controller.navigateForFollow(to: Vec2(0, 0.5),
                                                         stoppingAtForwardClearance: 1.25)
        XCTAssertEqual(result, .failed(.obstacle))
    }
    func testNavigationPublishesTypedCommandFailureDuringMovement() async {
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 },
            plan: { _, goal in [goal] },
            lastAckAt: { nil },
            sendCommand: { _ in throw FakeCommandError.timedOut },
            stopRover: {},
            sleep: { _ in }
        )
        let states = controller.safetyStates()
        let received = Task { () -> [NavigationSafetyState] in
            var iterator = states.makeAsyncIterator()
            var result: [NavigationSafetyState] = []
            if let state = await iterator.next() { result.append(state) }
            if let state = await iterator.next() { result.append(state) }
            if let state = await iterator.next() { result.append(state) }
            return result
        }

        _ = await controller.navigateAndWait(to: Vec2(2, 0))

        let safetyStates = await received.value
        XCTAssertEqual(safetyStates, [.idle, .moving, .failed(.commandFailed)])
    }

    func testObstacleAtTargetCountsAsArrived() {
        let state = NavigationController.stateAfterObstacleStop(
            pose: Pose2D(position: Vec2(0.4, 0), yaw: 0),
            goal: Vec2(0.9, 0),
            clearance: 0.32
        )

        XCTAssertEqual(state, .arrived)
    }

    func testObstacleBeforeTargetStopsAsFailed() {
        let state = NavigationController.stateAfterObstacleStop(
            pose: Pose2D(position: .zero, yaw: 0),
            goal: Vec2(2.0, 0),
            clearance: 0.28
        )

        XCTAssertEqual(state, .failed("Obstacle ahead at 0.28 m."))
    }

    func testVisualTargetApproachStopsAtThirtyCentimeters() {
        XCTAssertEqual(
            NavigationController.visualTargetApproachDecision(
                distanceToGoal: 0.99,
                forwardClearance: 0.29,
                stopDistance: 0.30
            ),
            .arrived
        )
    }

    func testVisualTargetApproachBrakesBeforeStandOffToCompensateForOvershoot() {
        XCTAssertEqual(
            NavigationController.visualTargetApproachDecision(
                distanceToGoal: 0.99,
                forwardClearance: 0.39,
                stopDistance: 0.30
            ),
            .arrived
        )
    }

    func testVisualTargetApproachRelaxesObstacleGuardOnlyNearProjectedGoal() {
        XCTAssertEqual(
            NavigationController.visualTargetApproachDecision(
                distanceToGoal: 0.99,
                forwardClearance: 0.41,
                stopDistance: 0.30
            ),
            .approach
        )
        XCTAssertEqual(
            NavigationController.visualTargetApproachDecision(
                distanceToGoal: 1.21,
                forwardClearance: 0.29,
                stopDistance: 0.30
            ),
            .inactive
        )
    }

    func testVisualTargetApproachSlowsForwardCommandBeforeStopDistance() {
        let command = NavigationController.visualTargetApproachCommand(
            WheelCommand(left: 0.35, right: 0.31),
            forwardClearance: 0.45,
            stopDistance: 0.30
        )

        XCTAssertEqual(command.left, RoverConfig.visualTargetApproachMaxWheelSpeed, accuracy: 0.001)
        XCTAssertEqual(command.right, 0.106, accuracy: 0.001)
    }

    func testVisualTargetApproachKeepsCommandOutsideSlowdownDistance() {
        let original = WheelCommand(left: 0.35, right: 0.31)

        let command = NavigationController.visualTargetApproachCommand(
            original,
            forwardClearance: 0.61,
            stopDistance: 0.30
        )

        XCTAssertEqual(command, original)
    }

    func testCommandFailureStopsNavigationAsFailed() {
        let state = NavigationController.stateAfterCommandFailure(FakeCommandError.timedOut)

        XCTAssertEqual(state, .failed("Rover command failed: Timed out talking to rover."))
    }

    func testStaleAckIsIgnoredUntilNavigationSendsFirstCommand() {
        let guardLayer = ObstacleGuard(watchdogTimeout: 0.5)
        let decision = guardLayer.evaluate(
            forwardClearance: 2.0,
            lastAckAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 10),
            feedback: nil,
            requireFreshAck: false
        )

        XCTAssertEqual(decision, .go)
    }

    func testStaleAckStopsActiveNavigationAfterFirstCommand() {
        let guardLayer = ObstacleGuard(watchdogTimeout: 0.5)
        let decision = guardLayer.evaluate(
            forwardClearance: 2.0,
            lastAckAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 10),
            feedback: nil,
            requireFreshAck: true
        )

        XCTAssertEqual(decision, .stopCommsLost)
    }

    func testDefaultWatchdogToleratesShortCommandLoopGap() {
        let guardLayer = ObstacleGuard()
        let decision = guardLayer.evaluate(
            forwardClearance: 2.0,
            lastAckAt: Date(timeIntervalSince1970: 10.0),
            now: Date(timeIntervalSince1970: 11.2),
            feedback: nil,
            requireFreshAck: true
        )

        XCTAssertEqual(decision, .go)
    }

    func testDefaultWatchdogStopsLongCommandLoopGap() {
        let guardLayer = ObstacleGuard()
        let decision = guardLayer.evaluate(
            forwardClearance: 2.0,
            lastAckAt: Date(timeIntervalSince1970: 10.0),
            now: Date(timeIntervalSince1970: 12.1),
            feedback: nil,
            requireFreshAck: true
        )

        XCTAssertEqual(decision, .stopCommsLost)
    }

    func testAckAgeFieldFormatsCurrentAckAge() {
        let value = NavigationController.ackAgeField(
            lastAckAt: Date(timeIntervalSince1970: 10.0),
            now: Date(timeIntervalSince1970: 11.234)
        )

        XCTAssertEqual(value, "1.23")
    }

    func testAckAgeFieldReportsMissingAck() {
        let value = NavigationController.ackAgeField(lastAckAt: nil)

        XCTAssertEqual(value, "none")
    }

    func testForwardObstacleCanBeIgnoredForInPlaceRotation() {
        let guardLayer = ObstacleGuard(stopDistance: 0.45)
        let decision = guardLayer.evaluate(
            forwardClearance: 0.30,
            lastAckAt: nil,
            feedback: nil,
            checkForwardObstacle: false
        )

        XCTAssertEqual(decision, .go)
    }

    func testNavigationTelemetryFieldsIncludeGoalPoseDistanceAndWheelCommand() {
        let fields = NavigationController.driveTelemetryFields(
            pose: Pose2D(position: Vec2(1.0, 2.0), yaw: .pi / 2),
            goal: Vec2(1.0, 3.0),
            command: WheelCommand(left: 0.12, right: 0.34),
            consecutiveCommandFailures: 1
        )

        XCTAssertEqual(fields["goal_x"], "1.00")
        XCTAssertEqual(fields["goal_y"], "3.00")
        XCTAssertEqual(fields["pose_x"], "1.00")
        XCTAssertEqual(fields["pose_y"], "2.00")
        XCTAssertEqual(fields["pose_yaw_deg"], "90")
        XCTAssertEqual(fields["distance_to_goal"], "1.00")
        XCTAssertEqual(fields["wheel_left"], "0.12")
        XCTAssertEqual(fields["wheel_right"], "0.34")
        XCTAssertEqual(fields["command_failures"], "1")
    }
}

@MainActor
private final class SuspendedNavigationStop {
    private var requested = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    func confirm() async {
        guard !requested else { return }
        requested = true
        requestWaiter?.resume()
        requestWaiter = nil
        await withCheckedContinuation { stopWaiter = $0 }
    }
    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func finish() {
        stopWaiter?.resume()
        stopWaiter = nil
    }
}

private enum FakeCommandError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Timed out talking to rover."
    }
}

@MainActor
final class SuspendedNavigationSend {
    private let error: Error
    private var requested = false
    private var requestWaiter: CheckedContinuation<Void, Never>?

    init(error: Error) { self.error = error }

    func send() async throws {
        requested = true
        requestWaiter?.resume()
        requestWaiter = nil
        do {
            try await Task.sleep(for: .seconds(60))
            XCTFail("Expected the suspended send to be cancelled")
        } catch {
            throw self.error
        }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
}
