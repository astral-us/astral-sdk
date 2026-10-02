import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class NavigationFollowReadySignalTests: XCTestCase {
    func testStopDuringAckReadPreventsReadyWheelCommand() async throws {
        var ackRead: CheckedContinuation<Date?, Never>?
        var commands = 0
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 }, plan: { _, goal in [goal] },
            lastAckAt: { await withCheckedContinuation { ackRead = $0 } },
            sendCommand: { _ in commands += 1 }, stopRover: {}, sleep: { _ in })
        let signal = Task { await controller.navigateForFollowReadySignal() }
        while ackRead == nil { await Task.yield() }
        let stopping = Task { try await controller.stopAndConfirm() }
        for _ in 0..<20 { await Task.yield() }
        ackRead?.resume(returning: Date())
        try await stopping.value
        let result = await signal.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(commands, 0)
        XCTAssertEqual(controller.safetyState, .idle)
    }

    func testAsyncAckGetterUsesPostAwaitClockPoseAndClearance() async {
        for scenario in 0..<5 {
            var time = Date(timeIntervalSince1970: 100)
            var position = Vec2.zero
            var clearance = 2.0
            var commands = 0
            let controller = NavigationController(
                currentPose: { Pose2D(position: position, yaw: 0) },
                forwardClearance: { clearance }, plan: { _, goal in [goal] },
                lastAckAt: {
                    let previousAck = time
                    await Task.yield()
                    time = time.addingTimeInterval(0.2)
                    if scenario == 3 { clearance = 0.1 }
                    if scenario == 4 { position = Vec2(0.14, 0) }
                    if scenario == 1 { return time.addingTimeInterval(1) }
                    if scenario == 2 { return time.addingTimeInterval(-10) }
                    if scenario >= 3 { return previousAck }
                    return time
                }, sendCommand: { _ in commands += 1 }, stopRover: {},
                sleep: { _ in position = Vec2(0.10, 0) }, now: { time })
            let result = await controller.navigateForFollowReadySignal()
            let expected: [NavigationResult] = [.arrived, .failed(.commsLost), .failed(.commsLost), .failed(.obstacle), .failed(.stalled)]
            XCTAssertEqual(result, expected[scenario], "scenario=\(scenario)")
            XCTAssertEqual(commands, scenario == 0 ? 1 : 0, "Never issue a command based on pre-await safety samples")
        }
    }

    func testRealPlannerReadySignalRejectsOccupiedStartInflationAndCornerContact() async {
        for scenario in 0..<3 {
            var map = Costmap(width: 120, height: 120, resolution: 0.10, origin: Vec2(-6, -6))
            let start = scenario == 0 ? Vec2(0.05, 0.05) : (scenario == 2 ? Vec2(0.09, 0.09) : .zero)
            let yaw = scenario == 2 ? Double.pi / 4 : 0
            if scenario == 0 { map.markObstacle(at: start) }
            if scenario == 1 { map.markObstacle(at: Vec2(0.05, 0.25)); map.inflate(radius: 0.25) }
            if scenario == 2 { map.markObstacle(at: Vec2(0.15, 0.05)) }
            let goal = start + Vec2(cos(yaw), sin(yaw)) * 0.10
            XCTAssertNotNil(AStarPlanner().plan(from: start, to: goal, in: map),
                            "A route or detour is not proof that the actual short straight segment is safe")
            var commands = 0
            let ack = Date()
            let controller = NavigationController(
                currentPose: { Pose2D(position: start, yaw: yaw) }, forwardClearance: { 2 },
                plan: { AStarPlanner().plan(from: $0, to: $1, in: map) },
                readySignalCostmap: { _ in map }, lastAckAt: { ack },
                sendCommand: { _ in commands += 1 }, stopRover: {}, sleep: { _ in })
            let result = await controller.navigateForFollowReadySignal()
            XCTAssertEqual(result, .failed(.noPath), "scenario=\(scenario)")
            XCTAssertEqual(commands, 0, "Free LiDAR clearance must not bypass grid occupancy/inflation")
        }
    }

    func testRealPlannerReadySignalAcceptsOpenFloorCardinalAndObliqueHeadings() async {
        let map = Costmap(width: 120, height: 120, resolution: 0.10, origin: Vec2(-6, -6))
        for yaw in [0.0, Double.pi / 2, -.pi / 2, .pi, .pi / 4, -.pi / 3] {
            var position = Vec2.zero
            var commands = 0
            let ack = Date()
            let controller = NavigationController(
                currentPose: { Pose2D(position: position, yaw: yaw) },
                forwardClearance: { 2 },
                plan: { AStarPlanner().plan(from: $0, to: $1, in: map) },
                readySignalCostmap: { _ in map },
                lastAckAt: { ack }, sendCommand: { _ in commands += 1 }, stopRover: {},
                sleep: { _ in position = Vec2(cos(yaw), sin(yaw)) * 0.10 })
            let result = await controller.navigateForFollowReadySignal()
            XCTAssertEqual(result, .arrived, "Open floor at yaw \(yaw) must not reject cell-center quantization")
            XCTAssertEqual(commands, 1)
        }
    }

    func testStopDuringFinalReadyAcknowledgementCannotReturnArrival() async throws {
        var x = 0.0
        var stops = 0
        var finalStop: CheckedContinuation<Void, Never>?
        let ack = Date()
        let controller = NavigationController(
            currentPose: { Pose2D(position: Vec2(x, 0), yaw: 0) },
            forwardClearance: { 2 }, plan: { _, goal in [goal] },
            lastAckAt: { ack }, sendCommand: { _ in },
            stopRover: { stops += 1; if stops == 2 { await withCheckedContinuation { finalStop = $0 } } },
            sleep: { _ in x = 0.10 })
        let signal = Task { await controller.navigateForFollowReadySignal() }
        while finalStop == nil { await Task.yield() }
        let stopping = Task { try await controller.stopAndConfirm() }
        for _ in 0..<20 { await Task.yield() }
        finalStop?.resume()
        let result = await signal.value
        try await stopping.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(controller.safetyState, .idle)
    }

    func testStopCancelsReadySignalSendAndIndependentStopFailureBlocksMotion() async {
        for fails in [false, true] {
            let send = SuspendedNavigationSend(error: URLError(.cancelled))
            var stops = 0
            var commands = 0
            let ack = Date()
            let controller = NavigationController(
                currentPose: { Pose2D(position: .zero, yaw: 0) },
                forwardClearance: { 2 }, plan: { _, goal in [goal] },
                lastAckAt: { ack }, sendCommand: { _ in commands += 1; try await send.send() },
                stopRover: { stops += 1; if fails && stops > 1 { throw URLError(.cannotConnectToHost) } },
                sleep: { _ in })
            let moving = Task { await controller.navigateForFollowReadySignal() }
            await send.waitUntilRequested()
            do { try await controller.stopAndConfirm(); XCTAssertFalse(fails) }
            catch { XCTAssertTrue(fails) }
            let result = await moving.value
            XCTAssertEqual(result, .cancelled)
            XCTAssertEqual(commands, 1)
            if fails {
                let next = await controller.navigateForFollowReadySignal()
                XCTAssertEqual(next, .failed(.commandFailed))
                XCTAssertEqual(commands, 1)
            } else { XCTAssertEqual(controller.safetyState, .idle) }
        }
    }

    func testReadySignalRequiresFreshCommandFeedbackEvenBeforeFirstMove() async {
        for ack in [Optional<Date>.none, Date().addingTimeInterval(-10)] {
            var commands = 0
            var time = Date()
            let controller = NavigationController(
                currentPose: { Pose2D(position: .zero, yaw: 0) },
                forwardClearance: { 2 }, plan: { _, goal in [goal] },
                lastAckAt: { ack }, sendCommand: { _ in commands += 1 }, stopRover: {},
                sleep: { _ in time = time.addingTimeInterval(0.1) }, now: { time })
            let result = await controller.navigateForFollowReadySignal()
            XCTAssertEqual(result, .failed(.commsLost))
            XCTAssertEqual(commands, 0)
        }
    }

    func testReadySignalActuallyMovesTenCentimetresAtLowSpeedThenConfirmsStop() async {
        var x = 0.0
        var commands: [WheelCommand] = []
        var stops = 0
        let ack = Date()
        let controller = NavigationController(
            currentPose: { Pose2D(position: Vec2(x, 0), yaw: 0) },
            forwardClearance: { 2 }, plan: { start, goal in [start, goal] },
            lastAckAt: { ack },
            sendCommand: { commands.append($0) }, stopRover: { stops += 1 },
            sleep: { _ in x += 0.01 })
        let result = await controller.navigateForFollowReadySignal()
        XCTAssertEqual(result, .arrived)
        XCTAssertGreaterThanOrEqual(x, 0.08)
        XCTAssertLessThanOrEqual(x, 0.12)
        XCTAssertFalse(commands.isEmpty, "Ordinary 20 cm goal tolerance would falsely arrive without moving")
        XCTAssertTrue(commands.allSatisfy { $0.left > 0 && $0.left <= 0.05 && $0.right == $0.left })
        XCTAssertGreaterThanOrEqual(stops, 2)
        XCTAssertEqual(controller.safetyState, .idle)
    }

    func testReadySignalFailsClosedOnObstacleNoPathPoseLossStallAndOvershoot() async {
        for scenario in 0..<5 {
            var x = 0.0
            var ticks = 0
            var commands = 0
            var time = Date()
            let controller = NavigationController(
                currentPose: { scenario == 2 && ticks > 0 ? nil : Pose2D(position: Vec2(x, 0), yaw: 0) },
                forwardClearance: { scenario == 0 ? 0.1 : 2 },
                plan: { _, goal in scenario == 1 ? nil : [goal] },
                lastAckAt: { time }, sendCommand: { _ in commands += 1 }, stopRover: {},
                sleep: { _ in ticks += 1; time = time.addingTimeInterval(0.1); if scenario == 4 { x = 0.14 } },
                now: { time })
            let result = await controller.navigateForFollowReadySignal()
            XCTAssertEqual(result, .failed([.obstacle, .noPath, .trackingLost, .stalled, .stalled][scenario]))
            if scenario < 2 { XCTAssertEqual(commands, 0) }
            XCTAssertLessThan(commands, 55, "Bound duration even when wheels stall at low speed")
        }
    }
}
