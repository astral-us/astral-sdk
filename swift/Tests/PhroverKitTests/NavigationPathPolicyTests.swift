import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class NavigationPathPolicyTests: XCTestCase {
    func testInitialPolicyRejectionStoresNoPathAndSendsNoCommand() async {
        let harness = NavigationHarness(plans: [[Vec2(0, 0.5), Vec2(0, 0)]])
        let controller = harness.makeController()

        let result = await controller.navigateAndWait(
            to: Vec2(0, 1),
            policy: westPolicy()
        )

        XCTAssertEqual(result, .failed(.pathRejected(.outsideSector(pointIndex: 2))))
        XCTAssertTrue(controller.path.isEmpty)
        XCTAssertEqual(harness.sentCommands, 0)
    }

    func testRejectedReplanStopsClearsOldPathAndDoesNotSendAgain() async {
        let safe = [Vec2(0, 0.5), Vec2(0, 0.8)]
        let unsafe = [Vec2(0, 0.5), Vec2(0, 0)]
        let harness = NavigationHarness(plans: [safe, unsafe])
        let controller = harness.makeController()

        let result = await controller.navigateAndWait(to: Vec2(0, 1), policy: westPolicy())

        XCTAssertEqual(result, .failed(.pathRejected(.outsideSector(pointIndex: 2))))
        XCTAssertTrue(controller.path.isEmpty)
        XCTAssertEqual(harness.sentCommands, 9)
        XCTAssertGreaterThanOrEqual(harness.stops, 1)
    }

    func testMissingReplanStopsClearsOldPathAndReturnsNoPath() async {
        let harness = NavigationHarness(plans: [[Vec2(0, 0.5), Vec2(0, 0.8)], nil])
        let controller = harness.makeController()

        let result = await controller.navigateAndWait(to: Vec2(0, 1), policy: westPolicy())

        XCTAssertEqual(result, .failed(.noPath))
        XCTAssertTrue(controller.path.isEmpty)
        XCTAssertEqual(harness.sentCommands, 9)
        XCTAssertGreaterThanOrEqual(harness.stops, 1)
    }

    func testNoPoseHasTypedFailureAndLegacyState() async {
        let harness = NavigationHarness(plans: [], pose: nil)
        let controller = harness.makeController()

        let result = await controller.navigateAndWait(to: Vec2(0, 1))

        XCTAssertEqual(result, .failed(.noPose))
        XCTAssertEqual(
            controller.state,
            .failed("No ARKit pose yet — move the device to establish tracking.")
        )
    }

    func testAwaitedNavigationStopsCurrentOperationBeforePlanningReplacement() async {
        var events: [String] = []
        let controller = NavigationController(
            currentPose: { Pose2D(position: Vec2(0, 0), yaw: 0) },
            forwardClearance: { 2 },
            plan: { _, goal in
                events.append("plan")
                return [goal]
            },
            lastAckAt: { Date() },
            sendCommand: { _ in events.append("send") },
            stopRover: { events.append("stop") },
            sleep: { _ in }
        )

        _ = await controller.navigateAndWait(to: Vec2(0, 0))

        XCTAssertEqual(Array(events.prefix(2)), ["stop", "plan"])
    }

    private func westPolicy() -> SectorPathPolicy {
        SectorPathPolicy(
            sector: .west,
            frame: SharedMissionFrame(localOrigin: .zero, localNorthHeading: 0, sessionGeneration: 1)!
        )
    }
}

@MainActor
private final class NavigationHarness {
    var plans: [[Vec2]?]
    var pose: Pose2D?
    var sentCommands = 0
    var stops = 0

    init(plans: [[Vec2]?], pose: Pose2D? = Pose2D(position: Vec2(0, 0.5), yaw: 0)) {
        self.plans = plans
        self.pose = pose
    }

    func makeController() -> NavigationController {
        NavigationController(
            currentPose: { self.pose },
            forwardClearance: { 2 },
            plan: { _, _ in self.plans.isEmpty ? nil : self.plans.removeFirst() },
            lastAckAt: { Date() },
            sendCommand: { _ in self.sentCommands += 1 },
            stopRover: { self.stops += 1 },
            sleep: { _ in }
        )
    }
}
