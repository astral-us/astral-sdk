import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class NavigationRotationWatchdogTests: XCTestCase {
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
