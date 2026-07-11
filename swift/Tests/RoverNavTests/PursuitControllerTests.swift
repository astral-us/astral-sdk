import XCTest
@testable import RoverNav

final class PursuitControllerTests: XCTestCase {
    func testRotateInPlaceUsesConfiguredMinimumWheelSpeed() {
        let controller = PursuitController(params: .init(
            maxLinear: 0.35,
            wheelBase: 0.13,
            minimumRotateWheelSpeed: 0.25
        ))

        let output = controller.step(
            pose: Pose2D(position: .zero, yaw: .pi),
            path: [.zero, Vec2(1, 0)]
        )

        XCTAssertFalse(output.reachedGoal)
        XCTAssertGreaterThanOrEqual(abs(output.command.left), 0.25)
        XCTAssertGreaterThanOrEqual(abs(output.command.right), 0.25)
        XCTAssertLessThan(output.command.left * output.command.right, 0)
    }

    func testNoGoalProgressTriggersStallAfterTimeout() {
        var watchdog = DriveProgressWatchdog(timeout: 2, minimumProgress: 0.05)
        let start = Date(timeIntervalSince1970: 10)

        XCTAssertFalse(watchdog.observe(distanceToGoal: 2, now: start, commanded: true))
        XCTAssertFalse(watchdog.observe(distanceToGoal: 1.98,
                                         now: start.addingTimeInterval(1),
                                         commanded: true))
        XCTAssertTrue(watchdog.observe(distanceToGoal: 1.98,
                                        now: start.addingTimeInterval(2.1),
                                        commanded: true))
    }

    func testGoalProgressResetsStallDeadline() {
        var watchdog = DriveProgressWatchdog(timeout: 2, minimumProgress: 0.05)
        let start = Date(timeIntervalSince1970: 10)

        XCTAssertFalse(watchdog.observe(distanceToGoal: 2, now: start, commanded: true))
        XCTAssertFalse(watchdog.observe(distanceToGoal: 1.9,
                                         now: start.addingTimeInterval(1.5),
                                         commanded: true))
        XCTAssertFalse(watchdog.observe(distanceToGoal: 1.9,
                                         now: start.addingTimeInterval(3),
                                         commanded: true))
        XCTAssertTrue(watchdog.observe(distanceToGoal: 1.9,
                                        now: start.addingTimeInterval(3.6),
                                        commanded: true))
    }
}
