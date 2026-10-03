import XCTest
import RoverNav
import CoreVideo
import simd
@testable import PhroverKit

@MainActor
final class FollowReadyAdmissionIntegrationTests: XCTestCase {
    func testControllerOnlyYawCorrectionDefersHeadingWithoutConsumingAttempt() async throws {
        let fixture = Fixture()
        fixture.enriched = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.yaw = 0.06
        fixture.sourceSequence = 100
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.state, .aligning)
        // Alignment remains stop-bracketed and requires a new matched frame.
        let deferred = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_deferred" })
        XCTAssertEqual(deferred["reason"] as? String, "heading")
        XCTAssertEqual(try XCTUnwrap(deferred["heading_rad"] as? Double), -0.06, accuracy: 0.000001)
        XCTAssertEqual(deferred["ready_signal_attempted"] as? Bool, false)
        XCTAssertEqual(deferred["ready_admission_pending"] as? Bool, false)
        _ = await fixture.coordinator.stop()
    }
    func testPreSendApparentCompletionFailsCoordinatorAndClearsUnconsumedToken() async {
        let fixture = Fixture()
        fixture.enriched = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.position = Vec2(0.10, 0)
        fixture.sourceSequence = 100
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.state, .failed("Navigation stopped: insufficient measured progress."))
        XCTAssertEqual(fixture.states.last?["ready_signal_attempted"], "false")
        XCTAssertEqual(fixture.states.last?["ready_admission_pending"], "false")
        fixture.send(3, range: 1.6)
        await drain()
        XCTAssertEqual(fixture.plans, 1)
        XCTAssertEqual(fixture.commands, 0)
        _ = await fixture.coordinator.stop()
    }
    func testDifferentControllerARGenerationCannotAuthorizeLockedWorldPosition() async throws {
        let fixture = Fixture()
        fixture.enriched = true
        fixture.controllerGeneration = 2
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        let deferred = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_deferred" })
        XCTAssertEqual(deferred["reason"] as? String, "observation")
        XCTAssertEqual(deferred["ready_signal_attempted"] as? Bool, false)
        XCTAssertEqual(deferred["ready_admission_pending"] as? Bool, false)
        _ = await fixture.coordinator.stop()
    }
    func testControllerOnlyForwardCorrectionDefersClearanceWithoutConsumingAttempt() async throws {
        let fixture = Fixture()
        fixture.enriched = true
        await fixture.acquire()
        fixture.send(2, range: 1.4)
        await fixture.feedback.waitUntilEntered()
        fixture.position = Vec2(0.05, 0)
        fixture.sourceSequence = 100
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.state, .waitingForClearance)
        let deferred = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_deferred" })
        XCTAssertEqual(deferred["reason"] as? String, "clearance")
        XCTAssertEqual(try XCTUnwrap(deferred["range_m"] as? Double), 1.35, accuracy: 0.000001)
        XCTAssertEqual(deferred["ready_signal_attempted"] as? Bool, false)
        XCTAssertEqual(deferred["ready_admission_pending"] as? Bool, false)
        XCTAssertEqual(deferred["controller_perception_pairing"] as? String, "independently_sampled")
        _ = await fixture.coordinator.stop()
    }
    func testRepeatedHealthyWaitUsesOneCombinedSummaryBudgetAndRetainsTrackerCounts() async throws {
        let fixture = Fixture()
        fixture.synthetic = true
        await fixture.acquire()
        fixture.send(2, range: 1.3)
        await drain()
        for sequence: UInt64 in 3...14 {
            fixture.clock.advance(to: Double(sequence - 2) / 10, wakeSleepers: false)
            fixture.send(sequence, range: 1.3)
            await drain()
        }
        let periodic = fixture.records.filter { $0["event"] as? String == "follow_person.association"
            && $0["phase"] as? String == "waitingForClearance" }
        XCTAssertEqual(periodic.count, 1)
        let record = try XCTUnwrap(periodic.first)
        XCTAssertEqual(record["raw_person_count"] as? Int, 1)
        XCTAssertEqual(record["projection_accepted_count"] as? Int, 1)
        XCTAssertEqual(record["eligible_candidate_count"] as? Int, 1)
        XCTAssertEqual(record["matched_candidate_count"] as? Int, 1)
        XCTAssertEqual(record["selected_candidate_count"] as? Int, 1)
        XCTAssertEqual(record["ready_signal_attempted"] as? Bool, false)
        XCTAssertEqual(record["stop_state"] as? String, "confirmed")
        XCTAssertEqual(fixture.records.filter { $0["event"] as? String == "follow_ready.clearance_entered" }.count, 1)
        XCTAssertFalse(fixture.records.contains { $0["event"] as? String == "follow_frame" })
        _ = await fixture.coordinator.stop()
    }
    func testAdmissionUsesExactPostFeedbackControllerSampleAndLabelsFramePairing() async throws {
        for independent in [false, true] {
            let fixture = Fixture()
            fixture.synthetic = true
            fixture.enriched = true
            fixture.independentControllerFrame = independent
            await fixture.acquire()
            fixture.send(2, range: 1.6)
            await fixture.feedback.waitUntilEntered()
            fixture.send(3, range: 1.7)
            await drain()
            fixture.feedback.release()
            await drain()
            let event = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_authorized" })
            XCTAssertEqual(event["frame_id"] as? String, "1:3")
            XCTAssertEqual(event["controller_pose_frame_id"] as? String, independent ? "1:100" : "1:3")
            XCTAssertEqual(event["controller_perception_pairing"] as? String, independent ? "independently_sampled" : "same_frame")
            XCTAssertEqual(event["controller_source_age_s"] as? Double, 0)
            XCTAssertEqual(event["controller_source_clock"] as? String, "system_uptime")
            XCTAssertEqual(event["controller_pose_yaw_rad"] as? Double, 0)
            _ = await fixture.coordinator.stop()
        }
    }
    func testSyntheticPipelineCloseWaitStepBackOneSignalNewBaselineAndDeparture() async throws {
        let fixture = Fixture()
        fixture.synthetic = true
        fixture.suspendDeparture = true
        await fixture.acquire()
        fixture.send(2, range: 1.3)
        await drain()
        XCTAssertEqual(fixture.coordinator.state, .waitingForClearance)
        XCTAssertEqual(fixture.commands, 0)
        let entry = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.clearance_entered" })
        XCTAssertEqual(entry["reason"] as? String, "too_close_before_send")
        XCTAssertEqual(entry["stop_state"] as? String, "confirmed")
        XCTAssertEqual(entry["ready_signal_attempted"] as? Bool, false)
        fixture.send(3, range: 1.35)
        await drain()
        fixture.send(4, range: 1.5)
        await fixture.feedback.waitUntilEntered()
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 1)
        XCTAssertEqual(fixture.coordinator.state, .signalingReady)
        fixture.send(5, range: 1.5)
        await drain()
        XCTAssertEqual(fixture.coordinator.state, .waitingForMovement)
        fixture.send(6, range: 1.7)
        await drain()
        XCTAssertEqual(fixture.coordinator.state, .waitingForMovement, "Post-signal baseline stays fixed")
        fixture.send(7, range: 1.9)
        await drain()
        XCTAssertEqual(fixture.coordinator.state, .following)
        XCTAssertGreaterThanOrEqual(fixture.plans, 2)
        let associations = fixture.records.filter { $0["event"] as? String == "follow_person.association" }
        XCTAssertTrue(associations.contains { $0["raw_person_count"] as? Int == 1 && $0["projection_accepted_count"] as? Int == 1 })
        XCTAssertEqual(fixture.records.filter { $0["event"] as? String == "follow_ready.admission_authorized" }.count, 1)
        XCTAssertEqual(fixture.records.filter { $0["event"] as? String == "follow_ready.clearance_exited" }.count, 1)
        fixture.sendFeedback.release()
        _ = await fixture.coordinator.stop()
    }

    func testSyntheticPipelineSuspendedFeedbackDeferralThenLocalCancellationIsTruthful() async throws {
        let fixture = Fixture()
        fixture.synthetic = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.3)
        await drain()
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.state, .waitingForClearance)
        _ = await fixture.coordinator.stop()
        let cancellation = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.cancelled" })
        XCTAssertEqual(cancellation["reason"] as? String, "local_stop")
        XCTAssertEqual(cancellation["ready_signal_attempted"] as? Bool, false)
        XCTAssertEqual(cancellation["ready_admission_pending"] as? Bool, false)
    }
    func testAdmissionDiagnosticsCapturePendingDeferredAndAuthorizedAtActualSendBoundary() async throws {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.3)
        await drain()
        fixture.feedback.release()
        await drain()
        let pending = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_pending" })
        XCTAssertEqual(pending["ready_admission_pending"] as? Bool, true)
        XCTAssertEqual(pending["ready_signal_attempted"] as? Bool, false)
        let deferred = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_deferred" })
        XCTAssertEqual(deferred["reason"] as? String, "clearance")
        XCTAssertEqual(deferred["frame_id"] as? String, "1:3")
        XCTAssertEqual(deferred["range_m"] as? Double, 1.3)
        XCTAssertEqual(deferred["heading_rad"] as? Double, 0)
        XCTAssertEqual(deferred["ready_signal_clearance_m"] as? Double, 1.37)
        XCTAssertEqual(deferred["stop_state"] as? String, "confirmed")
        XCTAssertEqual(deferred["admission_boundary"] as? String, "controller_first_send")
        XCTAssertEqual(deferred["first_wheel_telemetry_availability"] as? String, "unknown")
        XCTAssertEqual(fixture.commands, 0)
        fixture.send(4, range: 1.37)
        await drain()
        let authorized = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_authorized" })
        XCTAssertEqual(authorized["ready_admission_pending"] as? Bool, false)
        XCTAssertEqual(authorized["ready_signal_attempted"] as? Bool, true)
        XCTAssertEqual(authorized["frame_id"] as? String, "1:4")
        XCTAssertEqual(authorized["admission_boundary"] as? String, "controller_first_send")
        XCTAssertEqual(authorized["first_wheel_telemetry_availability"] as? String, "send_initiation_only")
        XCTAssertEqual(fixture.authorizedCommands, [0], "Authorization records precede actual first send, never controller entry")
        XCTAssertEqual(fixture.records.filter { $0["event"] as? String == "follow_ready.completed" }.count, 1)
        _ = await fixture.coordinator.stop()
    }
    func testLatestClosePersonDuringRealReadyFeedbackDefersWithoutSending() async {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.3)
        await drain()
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(String(describing: fixture.coordinator.state), "waitingForClearance")
        XCTAssertEqual(fixture.turns, 0, "Adequate heading must remain stationary under the clearance-wait label")
        XCTAssertTrue(fixture.coordinator.isActive)
        XCTAssertEqual(fixture.states.last?["ready_signal_attempted"], "false")
        XCTAssertEqual(fixture.states.last?["ready_admission_pending"], "false")
        _ = await fixture.coordinator.stop()
    }

    private func drain() async { for _ in 0..<100 { await Task.yield() } }

    func testZeroMeasuredReadyMotionConsumesAttemptAndFailsAtExistingWatchdog() async {
        let fixture = Fixture()
        fixture.stall = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.feedback.release()
        let deadline = Date().addingTimeInterval(2)
        while fixture.coordinator.isActive, Date() < deadline { await Task.yield() }
        await drain()
        XCTAssertGreaterThan(fixture.commands, 0)
        XCTAssertLessThan(fixture.commands, 55)
        XCTAssertEqual(fixture.coordinator.state, .failed("Navigation stopped: insufficient measured progress."))
        XCTAssertEqual(fixture.states.last?["ready_signal_attempted"], "true")
        let commands = fixture.commands
        fixture.stall = false
        fixture.send(3, range: 1.7)
        await drain()
        XCTAssertEqual(fixture.commands, commands)
        _ = await fixture.coordinator.stop()
    }

    func testStalePerceptionAfterRealSendCannotRetryWhenHealthyFramesRecover() async {
        let fixture = Fixture()
        fixture.suspendSend = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.feedback.release()
        await fixture.sendFeedback.waitUntilEntered()
        fixture.clock.advance(to: 0.501)
        await drain()
        fixture.suspendSend = false
        fixture.sendFeedback.release()
        await drain()
        fixture.send(3, range: 1.6)
        await drain()
        fixture.send(4, range: 1.6)
        await drain()
        XCTAssertEqual(fixture.commands, 1)
        XCTAssertEqual(fixture.plans, 1)
        XCTAssertEqual(fixture.coordinator.state, .failed("Ready signal interrupted. Stop and start following again."))
        _ = await fixture.coordinator.stop()
    }

    func testLossAfterRealSendCannotRepeatReadyAfterAlignedReacquisition() async {
        let fixture = Fixture()
        fixture.suspendSend = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.feedback.release()
        await fixture.sendFeedback.waitUntilEntered()
        fixture.send(3, range: 1.6, peopleAvailable: false)
        await drain()
        fixture.suspendSend = false
        fixture.sendFeedback.release()
        await drain()
        fixture.send(4, range: 1.6)
        await drain()
        fixture.send(5, range: 1.6)
        await drain()
        XCTAssertEqual(fixture.commands, 1)
        XCTAssertEqual(fixture.plans, 1)
        XCTAssertEqual(fixture.coordinator.state, .failed("Ready signal interrupted. Stop and start following again."))
        _ = await fixture.coordinator.stop()
    }

    func testApproachAfterRealSendInitiationStopsAndNeverReturnsToResumableWait() async {
        let fixture = Fixture()
        fixture.suspendSend = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.feedback.release()
        await fixture.sendFeedback.waitUntilEntered()
        XCTAssertEqual(fixture.states.last?["ready_admission_pending"], "false",
                       "Authorization consumes the reservation; an initiated signal is no longer pending admission")
        fixture.send(3, range: 1.3)
        await drain()
        XCTAssertEqual(fixture.coordinator.state,
                       .failed("Person too close during ready signal. Step back and start following again."))
        fixture.sendFeedback.release()
        await drain()
        fixture.send(4, range: 1.6)
        await drain()
        XCTAssertEqual(fixture.commands, 1)
        XCTAssertFalse(fixture.coordinator.isActive)
        XCTAssertEqual(fixture.states.last?["ready_signal_attempted"], "true")
        let cancellation = fixture.records.first { $0["event"] as? String == "follow_ready.cancelled" }
        XCTAssertEqual(cancellation?["reason"] as? String, "person_approached_during_signal")
        XCTAssertEqual(cancellation?["ready_signal_attempted"] as? Bool, true)
        let stopped = fixture.records.first { $0["event"] as? String == "follow_ready.stop_confirmed" }
        XCTAssertEqual(stopped?["stop_state"] as? String, "confirmed")
        XCTAssertEqual(fixture.records.filter { $0["event"] as? String == "follow_ready.stop_confirmed" }.count, 1)
        _ = await fixture.coordinator.stop()
    }

    func testUnhealthyLatestFrameDuringRealPreflightKeepsTwoSecondOutageDeadline() async {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.6, tracking: .limited)
        await drain()
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.perceptionIssue, .trackingLimited)
        fixture.clock.advance(to: 2)
        await drain()
        XCTAssertFalse(fixture.coordinator.isActive)
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.states.last?["ready_signal_attempted"], "false")
        _ = await fixture.coordinator.stop()
    }

    func testHeadingDriftDuringRealPreflightAlignsBeforeNewPostStopFrameCanAdmit() async {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.yaw = 0.06
        fixture.send(3, range: 1.6)
        await drain()
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.state, .aligning)
        XCTAssertEqual(fixture.turns, 1)
        fixture.send(4, range: 1.6)
        await drain()
        XCTAssertEqual(fixture.commands, 1)
        _ = await fixture.coordinator.stop()
    }

    func testExactlyFiveHundredMillisecondLatestObservationStillAdmitsOneSend() async {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.clock.advance(to: 0.5, wakeSleepers: false)
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 1)
        XCTAssertEqual(fixture.coordinator.state, .signalingReady)
        _ = await fixture.coordinator.stop()
    }

    func testLossDuringPendingRealAdmissionCannotSendReadyAndKeepsReacquisitionDeadline() async {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.6, peopleAvailable: false)
        await drain()
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.state, .reacquiring)
        XCTAssertEqual(fixture.states.last?["ready_signal_attempted"], "false")
        fixture.clock.advance(to: 10)
        await drain()
        XCTAssertEqual(fixture.coordinator.state, .failed("Person lost."))
        XCTAssertEqual(fixture.commands, 0)
        _ = await fixture.coordinator.stop()
    }

    func testFailedFinalStopAfterDeferralOutranksWaitAndBlocksNewAdmission() async {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.3)
        await drain()
        fixture.failStop = true
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.state, .failed("Motor stop could not be confirmed. Motion is blocked."))
        let started = await fixture.coordinator.start()
        XCTAssertFalse(started)
        fixture.send(4, range: 1.6)
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        fixture.failStop = false
        _ = await fixture.coordinator.stop()
    }

    func testObstacleDuringReadyFeedbackWinsOverCloseClearanceDeferral() async {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.3)
        await drain()
        fixture.clearance = 0.44
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.state, .failed("Obstacle detected. Motion stopped."))
        XCTAssertEqual(fixture.states.last?["ready_signal_attempted"], "false")
        _ = await fixture.coordinator.stop()
    }

    func testUncertainFirstSendIrrevocablyConsumesAttemptAndCannotRetryOnClearanceRecovery() async {
        let fixture = Fixture()
        fixture.failSend = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 1)
        XCTAssertFalse(fixture.coordinator.isActive)
        XCTAssertEqual(fixture.states.last?["ready_signal_attempted"], "true")
        fixture.failSend = false
        fixture.send(3, range: 1.7)
        await drain()
        XCTAssertEqual(fixture.commands, 1)
        XCTAssertNotEqual(fixture.coordinator.state, .waitingForClearance)
        _ = await fixture.coordinator.stop()
    }

    func testExpiredLatestObservationAtAdmissionEntersExistingOutagePolicyWithoutSend() async {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.clock.advance(to: 0.501, wakeSleepers: false)
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.perceptionIssue, .staleFrame,
                       "A delayed watchdog must not let admission hide the actual stale-frame outage")
        _ = await fixture.coordinator.stop()
    }

    func testStopAndNewGenerationFenceOldSuspendedAdmission() async {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.coordinator.inhibitMotion()
        let stopping = Task { await fixture.coordinator.stop() }
        await drain()
        fixture.feedback.release()
        _ = await stopping.value
        _ = await fixture.coordinator.start()
        await drain()
        fixture.send(10, range: 1.3)
        await drain()
        fixture.send(11, range: 1.3)
        await drain()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.state, .waitingForClearance)
        XCTAssertEqual(fixture.states.last?["ready_signal_attempted"], "false")
        _ = await fixture.coordinator.stop()
    }

    func testTwoEligibleFramesWhileFeedbackSuspendsOwnOnlyOnePendingRequest() async {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.65)
        fixture.send(4, range: 1.7)
        await drain()
        XCTAssertEqual(fixture.plans, 1)
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 1)
        _ = await fixture.coordinator.stop()
    }

    func testDeferredAttemptCanStepBackGraduallyAndSignalExactlyAtInclusiveGate() async {
        let fixture = Fixture()
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.3)
        await drain()
        fixture.feedback.release()
        await drain()
        fixture.send(4, range: 1.36)
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        fixture.send(5, range: 1.37)
        await drain()
        XCTAssertEqual(fixture.commands, 1, "Deferral cannot consume the one attempt; the exact gate is inclusive")
        XCTAssertEqual(fixture.coordinator.state, .signalingReady, "A final stop alone cannot establish a baseline")
        fixture.send(6, range: 1.37)
        await drain()
        XCTAssertEqual(fixture.coordinator.state, .waitingForMovement)
        XCTAssertEqual(fixture.commands, 1)
        _ = await fixture.coordinator.stop()
    }

    @MainActor
    private final class Fixture {
        let perception = FollowPerceptionFake()
        let clock = ManualFollowClock()
        let feedback = FollowDiagnosticSuspension()
        let sendFeedback = FollowDiagnosticSuspension()
        var suspendSend = false
        var synthetic = false
        var enriched = false
        var independentControllerFrame = false
        var controllerGeneration: UInt64 = 1
        var sourceSequence: UInt64 = 0
        var suspendDeparture = false
        var commands = 0
        var plans = 0
        var failSend = false
        var failStop = false
        var clearance = 2.0
        var yaw = 0.0
        var turns = 0
        var turning = false
        var stall = false
        var controllerTime = Date(timeIntervalSince1970: 100)
        var states: [[String: String]] = []
        var records: [[String: Any]] = []
        var authorizedCommands: [Int] = []
        var ready = false
        var position = Vec2.zero
        lazy var controller = NavigationController(currentPose: { [self] in Pose2D(position: position, yaw: yaw) },
            forwardClearance: { [self] in clearance }, plan: { [self] _, goal in ready = true; plans += 1; return [goal] },
            lastAckAt: { [self] in await acknowledgement() }, sendCommand: { [self] command in try await sendCommand(command) },
            stopRover: { [self] in try stopRover() },
            sleep: { [self] _ in await tick() }, now: { [self] in controllerTime },
            poseSample: { [self] in
                let pose = Pose2D(position: position, yaw: yaw)
                return enriched ? .init(pose: pose, frameID: .init(generation: controllerGeneration, sequence: independentControllerFrame ? 100 : sourceSequence),
                    sourceTimestamp: clock.now, trackingQuality: .normal) : .legacy(pose)
            }, sourceNow: { [self] in clock.now })
        lazy var coordinator: FollowMeCoordinator = {
            var config = FollowMeConfiguration()
            config.stationaryPauseSeconds = 0
            return FollowMeCoordinator(perception: perception, motion: NavigationFollowMeMotion(navigation: controller),
                clock: clock, configuration: config, eventSink: { [self] event, fields in
                    if event == "follow_state" { states.append(fields) }
                    if let json = fields["payload"], let data = json.data(using: .utf8),
                       let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { records.append(record) }
                    if event == "follow_ready.admission_authorized" { authorizedCommands.append(commands) }
                })
        }()
        func send(_ sequence: UInt64, range: Double, peopleAvailable: Bool = true, tracking: ARTrackingQuality = .normal) {
            let id = ARFrameID(generation: 1, sequence: sequence)
            sourceSequence = sequence
            if synthetic {
                var image: CVPixelBuffer?
                var depth: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, 20, 20, kCVPixelFormatType_32BGRA, nil, &image)
                CVPixelBufferCreate(kCFAllocatorDefault, 20, 20, kCVPixelFormatType_DepthFloat32, nil, &depth)
                let map = depth!
                CVPixelBufferLockBaseAddress(map, [])
                let base = CVPixelBufferGetBaseAddress(map)!.assumingMemoryBound(to: Float.self)
                for row in 0..<20 { for col in 0..<20 { base[row * CVPixelBufferGetBytesPerRow(map) / 4 + col] = Float(range - position.x) } }
                CVPixelBufferUnlockBaseAddress(map, [])
                let snapshot = ARFrameSnapshot(id: id, timestamp: clock.now, image: image!,
                    cameraTransform: simd_float4x4(columns: (SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, 1, 0, 0),
                        SIMD4<Float>(-1, 0, 0, 0), SIMD4<Float>(Float(position.x), 0, Float(position.y), 1))),
                    cameraIntrinsics: simd_float3x3(columns: (SIMD3<Float>(10, 0, 0), SIMD3<Float>(0, 10, 0), SIMD3<Float>(10, 10, 1))),
                    imageResolution: CGSize(width: 20, height: 20), depthMap: map,
                    pose: Pose2D(position: position, yaw: yaw), trackingQuality: tracking)
                perception.send(.frame(ARFollowMePerceptionSource.batch(from: snapshot, detections: peopleAvailable ? [
                    .init(label: "person", confidence: 0.99, boundingBox: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.3))] : [])))
                return
            }
            let person = FollowPersonObservation(frameID: id, timestamp: clock.now,
                confidence: 0.99, boundingBox: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6),
                position: Vec2(range, 0), pose: Pose2D(position: position, yaw: yaw))
            perception.send(.frame(.init(frameID: id, timestamp: clock.now,
                pose: Pose2D(position: position, yaw: yaw), depthAvailable: true,
                people: peopleAvailable ? [person] : [], trackingQuality: tracking)))
        }
        func acquire() async {
            _ = await coordinator.start()
            for _ in 0..<30 { await Task.yield() }
            send(1, range: 1.6)
            for _ in 0..<100 { await Task.yield() }
        }
        func acknowledgement() async -> Date? {
            if ready && !feedback.entered { await feedback.suspend() }
            return controllerTime
        }
        func sendCommand(_ command: WheelCommand) async throws {
            turning = command.left != command.right
            if turning { turns += 1 }
            if command.left == command.right, command.left != 0 { commands += 1 }
            if suspendSend || (suspendDeparture && plans > 1) { await sendFeedback.suspend() }
            if failSend { throw URLError(.networkConnectionLost) }
        }
        func stopRover() throws {
            if failStop { throw URLError(.cannotConnectToHost) }
        }
        func tick() async {
            if turning { yaw = 0 } else {
                controllerTime = controllerTime.addingTimeInterval(0.1)
                if !stall { position = Vec2(0.1, 0) }
            }
            await Task.yield()
        }
    }
}
