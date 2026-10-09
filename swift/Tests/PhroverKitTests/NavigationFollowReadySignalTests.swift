import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class NavigationFollowReadySignalTests: XCTestCase {
    func testReadyGeometryRejectionsReportTheActualGuardAndPoseInsteadOfProgressTimeout() async throws {
        for (point, heading, reason) in [
            (Vec2(0.13, 0), 0.0, "ready_travel_limit"),
            (Vec2(-0.03, 0), 0.0, "ready_backward_motion"),
            (Vec2(0.01, 0.03), 0.0, "ready_lateral_deviation"),
            (Vec2(0.01, 0), 0.12, "ready_heading_deviation")
        ] {
            var time = 100.0
            var sequence: UInt64 = 1
            var pose = Pose2D(position: .zero, yaw: 0)
            var sends = 0
            var stops = 0
            let controller = NavigationController(currentPose: { pose }, forwardClearance: { 2 },
                plan: { _, goal in [goal] }, lastAckAt: { Date(timeIntervalSince1970: time) },
                sendCommand: { _ in sends += 1; pose = .init(position: point, yaw: heading) }, stopRover: {
                    stops += 1
                    if stops >= 3 { pose = .init(position: Vec2(10, 20), yaw: 1) }
                },
                sleep: { duration in
                    time += max(0.001, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
                    sequence += 1; await Task.yield()
                }, now: { Date(timeIntervalSince1970: time) }, poseSample: {
                    .init(pose: pose, frameID: .init(generation: 1, sequence: sequence),
                        sourceTimestamp: time, trackingQuality: .normal)
                }, sourceNow: { time })
            let result = await NavigationFollowMeMotion(navigation: controller).perform(.ready, context:
                .init(sessionGeneration: 1, requestToken: 1, purpose: .followReady, phase: "aligning"))
            let failure = try XCTUnwrap(result.failure)
            let resolution = FollowMotionFailureResolution(failure)
            XCTAssertEqual(result.result, .failed(.stalled))
            XCTAssertEqual(result.stopOutcome, .confirmed)
            XCTAssertEqual(sends, 1)
            XCTAssertEqual(resolution.diagnosticReason, reason)
            XCTAssertNotEqual(resolution.message, "Navigation stopped: insufficient measured progress.")
            XCTAssertEqual(failure.turnDiagnosticFields["ready_along_m"], .number(point.x))
            XCTAssertEqual(failure.turnDiagnosticFields["ready_lateral_m"], .number(abs(point.y)))
            XCTAssertEqual(failure.turnDiagnosticFields["ready_heading_change_rad"], .number(abs(heading)))
            XCTAssertEqual(failure.turnDiagnosticFields["ready_current_pose"], .object([
                "world_x": .number(point.x), "world_z": .number(point.y), "yaw_rad": .number(heading)]))
            XCTAssertEqual(failure.turnDiagnosticFields["ready_start_pose"], .object([
                "world_x": .number(0), "world_z": .number(0), "yaw_rad": .number(0)]))
            XCTAssertEqual(failure.turnDiagnosticFields["ready_maximum_travel_m"], .number(0.12))
            XCTAssertEqual(failure.turnDiagnosticFields["ready_maximum_backward_m"], .number(0.02))
            XCTAssertEqual(failure.turnDiagnosticFields["ready_maximum_lateral_m"], .number(0.02))
            XCTAssertEqual(failure.turnDiagnosticFields["ready_maximum_heading_change_rad"], .number(0.10))
        }
    }

    func testRejectedPreStopDisplacementCannotRenewReadyProgressDeadline() async {
        var time = 100.0
        var sourceTime = 100.0
        var sequence: UInt64 = 1
        var position = Vec2.zero
        var sends = 0
        var stops = 0
        let controller = NavigationController(currentPose: { .init(position: position, yaw: 0) },
            forwardClearance: { 2 }, plan: { _, goal in [goal] }, lastAckAt: { Date(timeIntervalSince1970: time) },
            sendCommand: { _ in
                sends += 1
                guard sends == 1 else { throw URLError(.badURL) }
                time = 100.02; sourceTime = 100.02; sequence = 2; position = Vec2(0.02, 0)
            }, stopRover: { stops += 1 }, sleep: { duration in
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                if stops < 2 { time = max(time, 100.04) }
                else if seconds >= 0.09 { time = 100.14 }
                else {
                    time = 102.6; sourceTime = time; sequence = 3; position = .zero
                }
                await Task.yield()
            }, now: { Date(timeIntervalSince1970: time) }, poseSample: {
                .init(pose: .init(position: position, yaw: 0), frameID: .init(generation: 1, sequence: sequence),
                    sourceTimestamp: sourceTime, trackingQuality: .normal)
            }, sourceNow: { time })
        let result = await NavigationFollowMeMotion(navigation: controller).signalReady()
        XCTAssertEqual(result, .failed(.stalled))
        XCTAssertEqual(sends, 1, "A rejected pre-stop pose must not extend authority for another pulse")
    }

    func testReadyArrivalAfterLatePulseAndStopCannotBypassMovementDeadline() async {
        // The repeated case renews legitimate progress within every 2.5 s
        // window, isolating the independent five-second overall deadline.
        for repeated in [false, true] { await assertReadyDeadline(repeated: repeated) }
    }

    private func assertReadyDeadline(repeated: Bool) async {
        var time = 100.0
        var sequence: UInt64 = 1
        var position = Vec2.zero
        var sends = 0
        let controller = NavigationController(currentPose: { .init(position: position, yaw: 0) },
            forwardClearance: { 2 }, plan: { _, goal in [goal] }, lastAckAt: { Date(timeIntervalSince1970: time) },
            sendCommand: { _ in
                sends += 1
                time += repeated ? 1.65 : 5.2
                sequence += 1; position = position + Vec2(repeated ? 0.03 : 0.09, 0)
            }, stopRover: {}, sleep: { duration in
                time += max(0.001, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
                sequence += 1; await Task.yield()
            }, now: { Date(timeIntervalSince1970: time) }, poseSample: {
                .init(pose: .init(position: position, yaw: 0), frameID: .init(generation: 1, sequence: sequence),
                    sourceTimestamp: time, trackingQuality: .normal)
            }, sourceNow: { time })
        let result = await NavigationFollowMeMotion(navigation: controller).signalReady()
        XCTAssertEqual(result, .failed(.stalled), "Late measured displacement cannot turn an expired readiness move into success")
        XCTAssertEqual(sends, repeated ? 3 : 1)
    }

    func testReadyPulseCannotCompleteOrRepeatUsingAPreStopCapture() async throws {
        var time = 100.0
        var position = Vec2.zero
        var sends = 0
        let sink = FollowDiagnosticRecordingSink()
        let controller = NavigationController(currentPose: { .init(position: position, yaw: 0) },
            forwardClearance: { 2 }, plan: { _, goal in [goal] }, lastAckAt: { Date(timeIntervalSince1970: time) },
            sendCommand: { _ in sends += 1; position = Vec2(0.09, 0) }, stopRover: {}, sleep: { duration in
                time += max(0.001, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
                await Task.yield()
            }, now: { Date(timeIntervalSince1970: time) }, diagnosticEmitter: .init(
                streamID: "ready-stop-snapshot", monotonic: { time }, utc: { Date() }, sink: sink.append), poseSample: {
                .init(pose: .init(position: position, yaw: 0), frameID: .init(generation: 1, sequence: 1),
                    sourceTimestamp: 100, trackingQuality: .normal)
            }, sourceNow: { time })
        let result = await NavigationFollowMeMotion(navigation: controller).signalReady()
        XCTAssertEqual(result, .failed(.trackingLost))
        XCTAssertEqual(sends, 1, "A cached capture cannot authorize a second pulse or establish arrival")
        let event = try XCTUnwrap(sink.records.first { $0.event == "follow_ready.pulse_stopped" })
        let json = try XCTUnwrap(event.fields["payload"])
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let capture = try XCTUnwrap(fields["ready_stop_return_source_timestamp_s"] as? Double)
        let ack = try XCTUnwrap(fields["ready_stop_ack_uptime_s"] as? Double)
        let returned = try XCTUnwrap(fields["ready_pulse_return_uptime_s"] as? Double)
        let read = try XCTUnwrap(fields["ready_stop_return_pose_read_uptime_s"] as? Double)
        XCTAssertEqual(capture, 100)
        XCTAssertLessThan(capture, ack)
        XCTAssertLessThanOrEqual(ack, returned)
        XCTAssertLessThanOrEqual(returned, read)
        XCTAssertEqual(fields["ready_stop_return_frame_id"] as? String, "1:1")
    }

    func testReadySignalUsesEffectiveStoppedPulsesRatherThanSubBreakawayVelocityCommands() async {
        var time = 100.0
        var sequence: UInt64 = 1
        var position = Vec2.zero
        var commands: [WheelCommand] = []
        var moving = false
        var stops = 0
        var pulseStops = 0
        let controller = NavigationController(currentPose: { .init(position: position, yaw: 0) },
            forwardClearance: { 2 }, plan: { _, goal in [goal] }, lastAckAt: { Date(timeIntervalSince1970: time) },
            sendCommand: { command in
                XCTAssertFalse(moving, "Every readiness pulse must follow an acknowledged stop")
                commands.append(command)
                // A WAVE ROVER-like dead zone: low PWM is accepted but produces
                // no translation. This catches the old repeated 0.05 command.
                if command.left >= 0.20 && command.right >= 0.20 {
                    moving = true
                    position = position + Vec2(0.03, 0)
                }
            }, stopRover: {
                stops += 1
                if moving { pulseStops += 1 }
                moving = false
            }, sleep: { duration in
                time += max(0.001, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
                sequence += 1
                await Task.yield()
            }, now: { Date(timeIntervalSince1970: time) }, poseSample: {
                .init(pose: .init(position: position, yaw: 0), frameID: .init(generation: 1, sequence: sequence),
                    sourceTimestamp: time, trackingQuality: .normal)
            }, sourceNow: { time })
        let result = await NavigationFollowMeMotion(navigation: controller).signalReady()
        XCTAssertEqual(result, .arrived)
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(pulseStops, 3)
        XCTAssertGreaterThanOrEqual(stops, 4)
        XCTAssertTrue(commands.allSatisfy { $0.left == 0.25 && $0.right == 0.25 })
        XCTAssertEqual(position.x, 0.09, accuracy: 1e-12)
        XCTAssertFalse(moving)
    }

    func testPreSendPoseCorrectionCannotCompleteReadySignalOrConsumeAdmission() async {
        for correction in [0.08, 0.10, 0.12] {
            let gate = FollowDiagnosticSuspension()
            var position = Vec2.zero
            var sequence: UInt64 = 1
            var commands = 0
            var admissions = 0
            let controller = NavigationController(currentPose: { Pose2D(position: position, yaw: 0) },
                forwardClearance: { 2 }, plan: { _, goal in [goal] }, lastAckAt: {
                    if !gate.entered { await gate.suspend() }; return Date()
                }, sendCommand: { _ in commands += 1 }, stopRover: {}, sleep: { _ in },
                poseSample: { NavigationPoseSample(pose: Pose2D(position: position, yaw: 0),
                    frameID: .init(generation: 1, sequence: sequence), sourceTimestamp: 100,
                    trackingQuality: .normal) }, sourceNow: { 100 })
            let admission = FollowReadyAdmission { admissions += 1; return .accepted }
            let context = FollowMotionRequestContext(sessionGeneration: 1, requestToken: 1,
                purpose: .followReady, phase: "aligning")
            let task = Task { await NavigationFollowMeMotion(navigation: controller).performContextual(.ready,
                context: context, admission: admission) }
            await gate.waitUntilEntered()
            position = Vec2(correction, 0)
            sequence = 2
            gate.release()
            let result = await task.value
            XCTAssertEqual(result.outcome, .navigation(.failed(.stalled)), "correction=\(correction)")
            XCTAssertNil(result.deferred)
            XCTAssertEqual(result.stopOutcome, .confirmed)
            XCTAssertEqual(commands, 0)
            XCTAssertEqual(admissions, 0)
        }
    }
    func testExpiredEnrichedPoseFailsBeforeAdmissionInsteadOfDeferring() async {
        await assertSafetyBeforeAdmission(sourceTimestamp: 99.499, expected: .trackingLost)
    }
    func testUnsafeShortPathFailsBeforeAdmissionInsteadOfDeferring() async {
        await assertSafetyBeforeAdmission(safePlan: false, expected: .noPath)
    }
    func testNonfiniteObstacleClearanceFailsBeforeAdmissionInsteadOfDeferring() async {
        await assertSafetyBeforeAdmission(clearance: .nan, expected: .obstacle)
    }
    func testFutureAcknowledgementFailsBeforeAdmissionInsteadOfDeferring() async {
        await assertSafetyBeforeAdmission(ack: Date(timeIntervalSince1970: 101), expected: .commsLost)
    }
    func testStaleAcknowledgementFailsBeforeAdmissionInsteadOfDeferring() async {
        await assertSafetyBeforeAdmission(ack: Date(timeIntervalSince1970: 90), expected: .commsLost)
    }

    private func assertSafetyBeforeAdmission(clearance: Double = 2,
        ack: Date? = Date(timeIntervalSince1970: 100), safePlan: Bool = true,
        sourceTimestamp: Double = 100, expected: NavigationFailure) async {
        var admissions = 0
        var commands = 0
        let controller = NavigationController(currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { clearance }, plan: { _, goal in safePlan ? [goal] : [Vec2(0.1, 0.03)] },
            lastAckAt: { ack }, sendCommand: { _ in commands += 1 }, stopRover: {}, sleep: { _ in },
            now: { Date(timeIntervalSince1970: 100) }, poseSample: {
                NavigationPoseSample(pose: Pose2D(position: .zero, yaw: 0), frameID: .init(generation: 1, sequence: 1),
                    sourceTimestamp: sourceTimestamp, trackingQuality: .normal)
            }, sourceNow: { 100 })
        let admission = FollowReadyAdmission { admissions += 1; return .deferred(.clearance) }
        let context = FollowMotionRequestContext(sessionGeneration: 1, requestToken: 1, purpose: .followReady, phase: "aligning")
        let result = await NavigationFollowMeMotion(navigation: controller).performContextual(.ready,
            context: context, admission: admission)
        XCTAssertEqual(result.outcome, .navigation(.failed(expected)))
        XCTAssertNil(result.deferred)
        XCTAssertEqual(admissions, 0)
        XCTAssertEqual(commands, 0)
    }
    func testContextualDeferralIsNotArrivalOrFailureAndConfirmsStopAfterFeedback() async {
        let gate = FollowDiagnosticSuspension()
        var admissions = 0
        var commands = 0
        var stops = 0
        let controller = NavigationController(currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 }, plan: { _, goal in [goal] }, lastAckAt: {
                await gate.suspend(); return Date()
            }, sendCommand: { _ in commands += 1 }, stopRover: { stops += 1 }, sleep: { _ in })
        let admission = FollowReadyAdmission { admissions += 1; return .deferred(.clearance) }
        let context = FollowMotionRequestContext(sessionGeneration: 1, requestToken: 2, purpose: .followReady, phase: "aligning")
        let task = Task { await NavigationFollowMeMotion(navigation: controller).performContextual(.ready,
            context: context, admission: admission) }
        await gate.waitUntilEntered()
        XCTAssertEqual(admissions, 0, "Controller entry/preflight is too early to reserve an attempt")
        gate.release()
        let result = await task.value
        XCTAssertEqual(admissions, 1)
        XCTAssertEqual(result.deferred, .clearance)
        XCTAssertEqual(result.outcome, .notStarted(.clearance), "Contextual consumers must distinguish deferral from navigation cancellation")
        XCTAssertNotEqual(result.result, .arrived)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.stopOutcome, .confirmed)
        XCTAssertEqual(commands, 0)
        XCTAssertEqual(stops, 2)
    }
    func testReadyFeedbackSuspensionRejectsExpiredEnrichedPose() async {
        let gate = FollowDiagnosticSuspension()
        var timestamp = 100.0
        var position = Vec2.zero
        var commands = 0
        let controller = NavigationController(currentPose: { Pose2D(position: position, yaw: 0) },
            forwardClearance: { 2 }, plan: { _, goal in [goal] }, lastAckAt: {
                if !gate.entered { await gate.suspend() }; return Date()
            }, sendCommand: { _ in commands += 1 }, stopRover: {}, sleep: { _ in position = Vec2(0.1, 0) },
            poseSample: { NavigationPoseSample(pose: Pose2D(position: position, yaw: 0),
                frameID: ARFrameID(generation: 8, sequence: 1), sourceTimestamp: timestamp,
                trackingQuality: .normal) }, sourceNow: { 100 })
        let signal = Task { await NavigationFollowMeMotion(navigation: controller).signalReady() }
        await gate.waitUntilEntered()
        timestamp = 99.499
        gate.release()
        let result = await signal.value
        XCTAssertEqual(result, .failed(.trackingLost))
        XCTAssertEqual(commands, 0)
    }

    func testStopDuringAckReadPreventsReadyWheelCommand() async throws {
        var ackRead: CheckedContinuation<Date?, Never>?
        var commands = 0
        let controller = NavigationController(
            currentPose: { Pose2D(position: .zero, yaw: 0) },
            forwardClearance: { 2 }, plan: { _, goal in [goal] },
            lastAckAt: { await withCheckedContinuation { ackRead = $0 } },
            sendCommand: { _ in commands += 1 }, stopRover: {}, sleep: { _ in },
            poseSample: { NavigationPoseSample(pose: Pose2D(position: .zero, yaw: 0),
                frameID: ARFrameID(generation: 8, sequence: 1), sourceTimestamp: 100,
                trackingQuality: .normal) }, sourceNow: { 100 })
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
        for scenario in 0..<8 {
            var time = Date(timeIntervalSince1970: 100)
            var position = Vec2.zero
            var clearance = 2.0
            var commands = 0
            var sourceTime = 100.0
            var sourceTimestamp = 100.0
            var sourceGeneration: UInt64 = 8
            var sourceTracking = ARTrackingQuality.normal
            var sequence: UInt64 = 1
            let controller = NavigationController(
                currentPose: { Pose2D(position: position, yaw: 0) },
                forwardClearance: { clearance }, plan: { _, goal in [goal] },
                lastAckAt: {
                    let previousAck = time
                    await Task.yield()
                    time = time.addingTimeInterval(0.2)
                    sourceTime += 0.2
                    sourceTimestamp = sourceTime
                    sequence += 1
                    if scenario == 5 { sourceTimestamp = sourceTime - 0.501 }
                    if scenario == 6 { sourceGeneration = 9 }
                    if scenario == 7 { sourceTracking = .limited }
                    if scenario == 3 { clearance = 0.1 }
                    if scenario == 4 { position = Vec2(0.14, 0) }
                    if scenario == 1 { return time.addingTimeInterval(1) }
                    if scenario == 2 { return time.addingTimeInterval(-10) }
                    if scenario >= 3 { return previousAck }
                    return time
                }, sendCommand: { _ in commands += 1 }, stopRover: {},
                sleep: { duration in
                    let elapsed = max(0.001, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
                    time = time.addingTimeInterval(elapsed); sourceTime += elapsed; sourceTimestamp = sourceTime
                    sequence += 1; position = Vec2(0.10, 0)
                }, now: { time },
                poseSample: { NavigationPoseSample(pose: Pose2D(position: position, yaw: 0),
                    frameID: ARFrameID(generation: sourceGeneration, sequence: sequence), sourceTimestamp: sourceTimestamp,
                    trackingQuality: sourceTracking) }, sourceNow: { sourceTime })
            let result = await controller.navigateForFollowReadySignal()
            let expected: [NavigationResult] = [.arrived, .failed(.commsLost), .failed(.commsLost), .failed(.obstacle),
                .failed(.stalled), .failed(.trackingLost), .failed(.trackingLost), .failed(.trackingLost)]
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
            var uptime = 100.0
            let controller = NavigationController(
                currentPose: { Pose2D(position: position, yaw: yaw) },
                forwardClearance: { 2 },
                plan: { AStarPlanner().plan(from: $0, to: $1, in: map) },
                readySignalCostmap: { _ in map },
                lastAckAt: { Date(timeIntervalSince1970: uptime) }, sendCommand: { _ in commands += 1 }, stopRover: {},
                sleep: { duration in
                    uptime += max(0.001, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
                    position = Vec2(cos(yaw), sin(yaw)) * 0.10
                }, now: { Date(timeIntervalSince1970: uptime) }, sourceNow: { uptime })
            let result = await controller.navigateForFollowReadySignal()
            XCTAssertEqual(result, .arrived, "Open floor at yaw \(yaw) must not reject cell-center quantization")
            XCTAssertEqual(commands, 1)
        }
    }

    func testStopDuringFinalReadyAcknowledgementCannotReturnArrival() async throws {
        var x = 0.0
        var stops = 0
        var finalStop: CheckedContinuation<Void, Never>?
        var uptime = 100.0
        let controller = NavigationController(
            currentPose: { Pose2D(position: Vec2(x, 0), yaw: 0) },
            forwardClearance: { 2 }, plan: { _, goal in [goal] },
            lastAckAt: { Date(timeIntervalSince1970: uptime) }, sendCommand: { _ in },
            stopRover: { stops += 1; if stops == 2 { await withCheckedContinuation { finalStop = $0 } } },
            sleep: { duration in
                uptime += max(0.001, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
                x = 0.10
            }, now: { Date(timeIntervalSince1970: uptime) }, sourceNow: { uptime })
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
            let send = FollowDiagnosticSuspension()
            var stops = 0
            var commands = 0
            let ack = Date()
            let controller = NavigationController(
                currentPose: { Pose2D(position: .zero, yaw: 0) },
                forwardClearance: { 2 }, plan: { _, goal in [goal] },
                lastAckAt: { ack }, sendCommand: { _ in
                    commands += 1; await send.suspend(); throw URLError(.cancelled)
                },
                stopRover: { stops += 1; if fails && stops > 1 { throw URLError(.cannotConnectToHost) } },
                sleep: { _ in })
            let moving = Task { await controller.navigateForFollowReadySignal() }
            await send.waitUntilEntered()
            let stopping = Task { try await controller.stopAndConfirm() }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(stops, 1, "Stop must drain an already-entered request")
            send.release()
            do { try await stopping.value; XCTAssertFalse(fails) }
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

    func testReadySignalActuallyMovesTenCentimetresWithBoundedPulsesThenConfirmsStop() async {
        var x = 0.0
        var commands: [WheelCommand] = []
        var stops = 0
        var uptime = 100.0
        let controller = NavigationController(
            currentPose: { Pose2D(position: Vec2(x, 0), yaw: 0) },
            forwardClearance: { 2 }, plan: { start, goal in [start, goal] },
            lastAckAt: { Date(timeIntervalSince1970: uptime) },
            sendCommand: { commands.append($0); x += 0.03 }, stopRover: { stops += 1 },
            sleep: { duration in
                uptime += max(0.001, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
            }, now: { Date(timeIntervalSince1970: uptime) }, sourceNow: { uptime })
        let result = await controller.navigateForFollowReadySignal()
        XCTAssertEqual(result, .arrived)
        XCTAssertGreaterThanOrEqual(x, 0.08)
        XCTAssertLessThanOrEqual(x, 0.12)
        XCTAssertFalse(commands.isEmpty, "Ordinary 20 cm goal tolerance would falsely arrive without moving")
        XCTAssertTrue(commands.allSatisfy { $0.left == 0.25 && $0.right == $0.left })
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
                now: { time }, sourceNow: { time.timeIntervalSince1970 })
            let result = await controller.navigateForFollowReadySignal()
            XCTAssertEqual(result, .failed([.obstacle, .noPath, .trackingLost, .stalled, .stalled][scenario]))
            if scenario < 2 { XCTAssertEqual(commands, 0) }
            XCTAssertLessThan(commands, 55, "Bound duration even when wheels stall at low speed")
        }
    }
}
