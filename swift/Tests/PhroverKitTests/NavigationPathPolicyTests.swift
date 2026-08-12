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

    func testStaleConcurrentCancellationCannotDetachReplacementNavigation() async {
        let harness = ConcurrentCancellationHarness()
        let controller = harness.makeController()
        controller.navigate(to: Vec2(0, 1))
        await harness.waitForSendCount(1)
        await harness.waitForStopCount(1)

        let firstCancellation = Task { await controller.cancelAndWait() }
        let secondCancellation = Task { await controller.cancelAndWait() }
        harness.resumeSend()
        await harness.resumeSleepWhenSuspended()
        await harness.waitForStopCount(3)
        await harness.waitForResumedCancellation(controller: controller)

        controller.navigate(to: Vec2(0, 2))
        await harness.waitForSendCount(2)
        harness.resumeSuspendedStop()
        await firstCancellation.value
        await secondCancellation.value

        XCTAssertEqual(controller.state, .driving)
        XCTAssertEqual(controller.path, [Vec2(0, 2)])

        harness.pose = nil
        let stopCount = harness.stopCount
        let replacementCancellation = Task { await controller.cancelAndWait() }
        await harness.resumeSleepWhenSuspended()
        await replacementCancellation.value
        await harness.waitForStopCount(stopCount + 2)
        XCTAssertEqual(harness.sendCount, 2)
    }

    func testLatestConcurrentNavigationWaitsForAndReplacesOlderRequestWithoutCommandOverlap() async {
        let harness = ConcurrentStartHarness()
        let controller = harness.makeController()
        let olderGoal = Vec2(0, 1)
        let latestGoal = Vec2(1, 0)

        let older = Task {
            let result = await controller.navigateAndWait(to: olderGoal)
            harness.olderResult = result
            return result
        }
        await harness.waitForStopCount(1)
        let latest = Task { await controller.navigateAndWait(to: latestGoal) }
        await harness.waitForStopCount(2)

        harness.resumeStop(1)
        await harness.waitForOlderResultOrCommand()
        harness.resumeStop(2)
        await harness.waitForPlan(to: latestGoal)
        await harness.waitForSendCount(harness.olderResult == nil ? 2 : 1)

        XCTAssertEqual(harness.olderResult, .cancelled)
        XCTAssertEqual(harness.plannedGoals, [latestGoal])
        XCTAssertEqual(harness.maximumConcurrentSends, 1)

        harness.pose = nil
        let cancellation = Task { await controller.cancelAndWait() }
        harness.resumeAllSends()
        _ = await cancellation.value
        let olderResult = await older.value
        let latestResult = await latest.value
        XCTAssertEqual(olderResult, .cancelled)
        XCTAssertEqual(latestResult, .cancelled)
    }

    func testLatestConcurrentRotationWaitsForNavigationRequestWithoutCommandOverlap() async {
        let harness = ConcurrentStartHarness()
        let controller = harness.makeController()
        let olderGoal = Vec2(0, 1)

        let older = Task {
            let result = await controller.navigateAndWait(to: olderGoal)
            harness.olderResult = result
            return result
        }
        await harness.waitForStopCount(1)
        let latest = Task { await controller.rotateAndWait(by: .pi / 2) }
        await harness.waitForStopCount(2)

        harness.resumeStop(1)
        await harness.waitForOlderResultOrCommand()
        harness.resumeStop(2)
        await harness.waitForSendCount(harness.olderResult == nil ? 2 : 1)

        XCTAssertEqual(harness.olderResult, .cancelled)
        XCTAssertTrue(harness.plannedGoals.isEmpty)
        XCTAssertEqual(harness.maximumConcurrentSends, 1)
        let rotationCommand = try? XCTUnwrap(harness.sentCommands.last)
        XCTAssertLessThan((rotationCommand?.left ?? 0) * (rotationCommand?.right ?? 0), 0)

        harness.pose = nil
        let cancellation = Task { await controller.cancelAndWait() }
        harness.resumeAllSends()
        _ = await cancellation.value
        let olderResult = await older.value
        let latestResult = await latest.value
        XCTAssertEqual(olderResult, .cancelled)
        XCTAssertEqual(latestResult, .cancelled)
    }

    private func westPolicy() -> SectorPathPolicy {
        SectorPathPolicy(
            sector: .west,
            frame: SharedMissionFrame(localOrigin: .zero, localNorthHeading: 0, sessionGeneration: 1)!
        )
    }
}

@MainActor
private final class ConcurrentStartHarness {
    var pose: Pose2D? = Pose2D(position: .zero, yaw: 0)
    var olderResult: NavigationResult?
    private(set) var plannedGoals: [Vec2] = []
    private(set) var sentCommands: [WheelCommand] = []
    private(set) var maximumConcurrentSends = 0
    private var activeSends = 0
    private var stopCount = 0
    private var stopContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var sendContinuations: [CheckedContinuation<Void, Never>] = []

    func makeController() -> NavigationController {
        NavigationController(
            currentPose: { self.pose },
            forwardClearance: { 2 },
            plan: { _, goal in
                self.plannedGoals.append(goal)
                return [goal]
            },
            lastAckAt: { Date() },
            sendCommand: { command in
                self.sentCommands.append(command)
                self.activeSends += 1
                self.maximumConcurrentSends = max(self.maximumConcurrentSends, self.activeSends)
                await withCheckedContinuation { self.sendContinuations.append($0) }
                self.activeSends -= 1
            },
            stopRover: {
                self.stopCount += 1
                let count = self.stopCount
                if count <= 2 {
                    await withCheckedContinuation { self.stopContinuations[count] = $0 }
                }
            },
            sleep: { _ in await Task.yield() }
        )
    }

    func resumeStop(_ count: Int) {
        stopContinuations.removeValue(forKey: count)?.resume()
    }

    func resumeAllSends() {
        let continuations = sendContinuations
        sendContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForStopCount(_ expected: Int) async {
        while stopCount < expected { await Task.yield() }
    }

    func waitForOlderResultOrCommand() async {
        while olderResult == nil, sentCommands.isEmpty { await Task.yield() }
    }

    func waitForPlan(to goal: Vec2) async {
        while !plannedGoals.contains(goal) { await Task.yield() }
    }

    func waitForSendCount(_ expected: Int) async {
        while sentCommands.count < expected { await Task.yield() }
    }
}

@MainActor
private final class ConcurrentCancellationHarness {
    var pose: Pose2D? = Pose2D(position: .zero, yaw: 0)
    private(set) var sendCount = 0
    private(set) var stopCount = 0
    private var sendContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var sleepContinuation: CheckedContinuation<Void, Never>?

    func makeController() -> NavigationController {
        NavigationController(
            currentPose: { self.pose },
            forwardClearance: { 2 },
            plan: { _, goal in [goal] },
            lastAckAt: { Date() },
            sendCommand: { _ in
                self.sendCount += 1
                if self.sendCount == 1 {
                    await withCheckedContinuation { self.sendContinuation = $0 }
                }
            },
            stopRover: {
                self.stopCount += 1
                if self.stopCount == 3 {
                    await withCheckedContinuation { self.stopContinuation = $0 }
                }
            },
            sleep: { _ in
                await withCheckedContinuation { self.sleepContinuation = $0 }
            }
        )
    }

    func resumeSend() {
        sendContinuation?.resume()
        sendContinuation = nil
    }

    func resumeSuspendedStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func resumeSleepWhenSuspended() async {
        while sleepContinuation == nil { await Task.yield() }
        sleepContinuation?.resume()
        sleepContinuation = nil
    }

    func waitForSendCount(_ expected: Int) async {
        while sendCount < expected { await Task.yield() }
    }

    func waitForStopCount(_ expected: Int) async {
        while stopCount < expected { await Task.yield() }
    }

    func waitForResumedCancellation(controller: NavigationController) async {
        while controller.state != .idle { await Task.yield() }
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
