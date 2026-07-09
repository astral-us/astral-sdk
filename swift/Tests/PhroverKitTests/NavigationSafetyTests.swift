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
}

private enum FakeCommandError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Timed out talking to rover."
    }
}
