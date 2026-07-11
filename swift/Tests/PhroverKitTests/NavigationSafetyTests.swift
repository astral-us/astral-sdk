import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class NavigationSafetyTests: XCTestCase {
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

private enum FakeCommandError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Timed out talking to rover."
    }
}
