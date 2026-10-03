import XCTest
import RoverNav
import CoreVideo
import simd
@testable import PhroverKit

@MainActor
final class FollowReadyAdmissionIntegrationTests: XCTestCase {
    func testUnknownTrackingOnPendingFrameCannotAuthorizeOlderHealthyObservation() async throws {
        let fixture = Fixture()
        fixture.enriched = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.6, tracking: nil)
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.perceptionIssue, .trackingUnavailable)
        let rejection = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_rejected" })
        XCTAssertEqual(rejection["rejection_condition"] as? String, "tracking_unknown")
        _ = await fixture.coordinator.stop()
    }

    func testFinalizedReceiptOwnershipAndFullPauseUseOneMonotonicClock() async throws {
        let fixture = Fixture()
        fixture.stationaryPauseSeconds = 5
        fixture.clock.advance(to: 100)
        let mission = SuspendedMission()
        let router = OperatorCommandRouter(mission: mission, follow: fixture.coordinator,
            clock: fixture.clock, eventSink: { fixture.record($0, fields: $1) })
        let starting = Task { await router.submit("follow me", finalizedTextReceivedAt: 100) }
        await mission.stopFeedback.waitUntilEntered()
        XCTAssertEqual(fixture.coordinator.state, .idle)
        fixture.clock.advance(to: 103)
        mission.stopFeedback.release()
        let result = await starting.value
        XCTAssertEqual(result, .accepted)
        await drain()
        fixture.send(1, range: 1.6)
        await drain()
        fixture.clock.advance(to: 107.999)
        await drain()
        XCTAssertEqual(fixture.coordinator.state, .pausing)
        XCTAssertEqual(fixture.plans, 0)
        XCTAssertEqual(fixture.commands, 0)
        fixture.clock.advance(to: 108)
        fixture.send(2, range: 1.6)
        await drain()
        XCTAssertEqual(fixture.coordinator.state, .aligning)
        for (event, time) in [("operator_command.received", 100.0), ("operator_command.ownership_stop_requested", 100.0),
                              ("operator_command.ownership_stop_confirmed", 103.0), ("operator_command.follow_start_requested", 103.0),
                              ("follow_session.started", 103.0), ("follow_pause.started", 103.0), ("follow_pause.completed", 108.0)] {
            let record = try XCTUnwrap(fixture.records.first { $0["event"] as? String == event }, event)
            XCTAssertEqual(record["monotonic_s"] as? Double, time, event)
            XCTAssertEqual(record["command_received_at_s"] as? Double, 100, event)
            XCTAssertEqual(record["command_elapsed_s"] as? Double, time - 100, event)
        }
        let receipt = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "operator_command.received" })
        XCTAssertEqual(receipt["receipt_origin"] as? String, "finalized_text_receipt")
        XCTAssertEqual(receipt["physical_utterance_time_availability"] as? String, "not_measured")
        let pause = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_pause.completed" })
        XCTAssertEqual(pause["pause_elapsed_s"] as? Double, 5)
        let phase = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_phase" && $0["phase"] as? String == "searching" })
        XCTAssertEqual(phase["previous_phase_elapsed_s"] as? Double, 5)
        XCTAssertEqual(phase["session_elapsed_s"] as? Double, 5)
        _ = await fixture.coordinator.stop()
    }

    func testUnsafeNewestPendingObservationNeverFallsBackToOlderGoodTrack() async throws {
        for condition in ["target_lost", "target_ambiguous", "trackingLimited", "trackingUnavailable",
                          "frame_stale_or_invalid", "frame_timestamp_nonfinite", "frame_from_future", "depthUnavailable", "poseUnavailable",
                          "confidence", "world_distance", "screen_association", "frame_generation_mismatch", "locked_frame_mismatch"] {
            let fixture = Fixture()
            fixture.enriched = true
            await fixture.acquire()
            fixture.send(2, range: 1.6)
            await fixture.feedback.waitUntilEntered()
            switch condition {
            case "target_lost": fixture.send(3, range: 1.6, peopleAvailable: false)
            case "target_ambiguous": fixture.send(3, range: 1.6, secondPersonRange: 1.7)
            case "trackingLimited": fixture.send(3, range: 1.6, tracking: .limited)
            case "trackingUnavailable": fixture.send(3, range: 1.6, tracking: .unavailable)
            case "frame_stale_or_invalid": fixture.send(3, range: 1.6, timestamp: -0.501)
            case "frame_timestamp_nonfinite": fixture.send(3, range: 1.6, timestamp: .nan)
            case "frame_from_future": fixture.send(3, range: 1.6, timestamp: 0.001)
            case "depthUnavailable": fixture.send(3, range: 1.6, depthAvailable: false)
            case "poseUnavailable": fixture.send(3, range: 1.6, poseAvailable: false)
            case "confidence": fixture.send(3, range: 1.6, confidence: 0.49)
            case "world_distance": fixture.send(3, range: 2.5)
            case "screen_association": fixture.send(3, range: 1.6, box: CGRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05))
            case "frame_generation_mismatch": fixture.send(3, range: 1.6, generation: 2)
            default: fixture.send(3, range: 1.6, personFrameID: .init(generation: 1, sequence: 99))
            }
            fixture.feedback.release()
            await drain()
            XCTAssertEqual(fixture.commands, 0, condition)
            XCTAssertEqual(fixture.records.filter { $0["event"] as? String == "follow_ready.admission_authorized" }.count, 0, condition)
            XCTAssertEqual(fixture.states.last?["ready_signal_attempted"], "false", condition)
            let rejection = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_rejected" }, condition)
            XCTAssertEqual(rejection["frame_id"] as? String, condition == "frame_generation_mismatch" ? "2:3" : "1:3")
            XCTAssertEqual(rejection["pending_frame_evaluation"] as? String, "evaluated")
            let expected = ["confidence": "target_lost", "world_distance": "target_lost", "screen_association": "target_lost",
                            "locked_frame_mismatch": "target_lost", "trackingLimited": "tracking_limited",
                            "trackingUnavailable": "tracking_unavailable", "depthUnavailable": "depth_unavailable",
                            "poseUnavailable": "frame_pose_missing", "frame_stale_or_invalid": "frame_stale"][condition] ?? condition
            XCTAssertEqual(rejection["rejection_condition"] as? String, expected)
            if let candidateReason = ["confidence": "confidence_below_minimum", "world_distance": "world_distance_exceeded",
                                      "screen_association": "screen_association_rejected", "locked_frame_mismatch": "candidate_frame_mismatch"][condition] {
                let candidates = try XCTUnwrap(rejection["candidate_evaluations"] as? [[String: Any]])
                XCTAssertEqual(candidates.first?["rejection_reason"] as? String, candidateReason)
            }
            if ["target_lost", "target_ambiguous", "confidence", "world_distance", "screen_association",
                "frame_generation_mismatch", "locked_frame_mismatch"].contains(condition) {
                XCTAssertEqual(fixture.coordinator.state, .reacquiring, condition)
            }
            _ = await fixture.coordinator.stop()
        }
    }

    func testNewestOfMultiplePendingFramesAloneAuthorizesAndBecomesPostSignalTrack() async throws {
        let fixture = Fixture()
        fixture.enriched = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.3)
        fixture.send(4, range: 1.7)
        await drain()
        // Only 2.3 is within 0.75 m of the ORIGINAL 1.7 m lock. Reassociating
        // against the adopted 2.3 m lock would wrongly make 2.6 ambiguous.
        fixture.send(5, range: 2.3, secondPersonRange: 2.6)
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 1)
        let authorized = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_authorized" })
        XCTAssertEqual(authorized["frame_id"] as? String, "1:5")
        XCTAssertEqual(authorized["controller_pose_frame_id"] as? String, "1:5")
        XCTAssertEqual(authorized["pending_frame_evaluation"] as? String, "evaluated")
        XCTAssertEqual(authorized["matched_candidate_count"] as? Int, 1)
        XCTAssertEqual(fixture.coordinator.state, .signalingReady, "Consuming that raw frame cannot establish a new post-stop baseline")
        fixture.send(6, range: 3.0)
        await drain()
        XCTAssertEqual(fixture.coordinator.state, .waitingForMovement)
        fixture.send(7, range: 3.1)
        await drain()
        XCTAssertEqual(fixture.coordinator.state, .waitingForMovement)
        XCTAssertEqual(fixture.commands, 1)
        _ = await fixture.coordinator.stop()
    }

    func testPendingFrameAndPostAckControllerPoseAtInclusiveAgeAndHeadingGatesAdmit() async throws {
        let fixture = Fixture()
        fixture.enriched = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.clock.advance(to: 0.5, wakeSleepers: false)
        fixture.controllerSourceTimestamp = 0
        fixture.yaw = 0.05
        fixture.send(3, range: 1.6, timestamp: 0)
        fixture.feedback.release()
        await drain()
        XCTAssertEqual(fixture.commands, 1)
        let authorized = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_authorized" })
        XCTAssertEqual(authorized["frame_id"] as? String, "1:3")
        XCTAssertEqual(authorized["controller_source_age_s"] as? Double, 0.5)
        XCTAssertEqual(try XCTUnwrap(authorized["heading_rad"] as? Double), -0.05, accuracy: 0.000001)
        _ = await fixture.coordinator.stop()
    }

    func testStopWithHealthyPendingFrameFencesSuspendedFeedbackAndNewSession() async {
        let fixture = Fixture()
        fixture.enriched = true
        await fixture.acquire()
        fixture.send(2, range: 1.6)
        await fixture.feedback.waitUntilEntered()
        fixture.send(3, range: 1.7)
        fixture.coordinator.inhibitMotion()
        let stopping = Task { await fixture.coordinator.stop() }
        await drain()
        fixture.feedback.release()
        let stopped = await stopping.value
        XCTAssertTrue(stopped)
        XCTAssertEqual(fixture.commands, 0)
        fixture.stationaryPauseSeconds = 0
        let restarted = await fixture.coordinator.start()
        XCTAssertTrue(restarted)
        await drain()
        fixture.send(10, range: 1.3)
        await drain()
        fixture.send(11, range: 1.3)
        await drain()
        XCTAssertEqual(fixture.commands, 0)
        XCTAssertEqual(fixture.coordinator.state, .waitingForClearance)
        _ = await fixture.coordinator.stop()
    }

    func testHealthyFramesArrivingBeforeFeedbackResumesCannotStarveReadyAdmission() async throws {
        let fixture = Fixture()
        fixture.enriched = true
        fixture.stationaryPauseSeconds = 5
        let started = await fixture.coordinator.start()
        XCTAssertTrue(started)
        await drain()
        fixture.send(1, range: 1.68)
        await drain()
        fixture.clock.advance(to: 4.999)
        await drain()
        XCTAssertEqual(fixture.coordinator.state, .pausing)
        XCTAssertEqual(fixture.plans, 0)
        XCTAssertEqual(fixture.commands, 0)
        fixture.clock.advance(to: 5)
        fixture.send(2, range: 1.68)
        await drain()
        XCTAssertNotEqual(fixture.coordinator.state, .pausing)

        for attempt in 0..<3 {
            fixture.feedback = FollowDiagnosticSuspension()
            fixture.send(UInt64(3 + attempt * 2), range: 1.68)
            await fixture.feedback.waitUntilEntered()
            XCTAssertEqual(fixture.plans, attempt + 1)
            XCTAssertEqual(fixture.commands, 0)
            fixture.clock.advance(to: 5 + Double(attempt + 1) * 0.1, wakeSleepers: false)
            fixture.yaw = 0.034
            // Queue the newer healthy matched frame, then resume the real controller
            // acknowledgement without letting the frame processor drain first.
            fixture.send(UInt64(4 + attempt * 2), range: 1.68)
            fixture.feedback.release()
            await drain()
            if fixture.commands > 0 { break }
        }

        XCTAssertNil(fixture.coordinator.perceptionIssue)
        XCTAssertTrue(fixture.coordinator.isActive)
        XCTAssertEqual(fixture.turns, 0)
        XCTAssertEqual(fixture.commands, 1,
                       "Fresh matched frames during acknowledgement must not starve the one ready signal")
        XCTAssertEqual(fixture.records.filter { $0["event"] as? String == "follow_ready.admission_authorized" }.count, 1)
        let authorized = try XCTUnwrap(fixture.records.first { $0["event"] as? String == "follow_ready.admission_authorized" })
        XCTAssertEqual(authorized["frame_id"] as? String, "1:4")
        XCTAssertEqual(authorized["controller_pose_frame_id"] as? String, "1:4")
        XCTAssertEqual(authorized["controller_source_age_s"] as? Double, 0)
        XCTAssertEqual(try XCTUnwrap(authorized["heading_rad"] as? Double), -0.034, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(authorized["range_m"] as? Double), 1.68, accuracy: 0.000001)
        _ = await fixture.coordinator.stop()
    }

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
        XCTAssertEqual(deferred["rejection_condition"] as? String, "controller_source_generation_changed")
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
    private final class SuspendedMission: OperatorMission {
        let stopFeedback = FollowDiagnosticSuspension()
        func handle(_ text: String) async { XCTFail("Local follow must not reach mission handling") }
        func cancelCurrentMissionAndWait() async throws { await stopFeedback.suspend() }
    }

    @MainActor
    private final class Fixture {
        let perception = FollowPerceptionFake()
        let clock = ManualFollowClock()
        var feedback = FollowDiagnosticSuspension()
        let sendFeedback = FollowDiagnosticSuspension()
        var suspendSend = false
        var synthetic = false
        var enriched = false
        var independentControllerFrame = false
        var controllerGeneration: UInt64 = 1
        var sourceSequence: UInt64 = 0
        var controllerSourceTimestamp: Double?
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
        var stationaryPauseSeconds = 0.0
        lazy var controller = NavigationController(currentPose: { [self] in Pose2D(position: position, yaw: yaw) },
            forwardClearance: { [self] in clearance }, plan: { [self] _, goal in ready = true; plans += 1; return [goal] },
            lastAckAt: { [self] in await acknowledgement() }, sendCommand: { [self] command in try await sendCommand(command) },
            stopRover: { [self] in try stopRover() },
            sleep: { [self] _ in await tick() }, now: { [self] in controllerTime },
            poseSample: { [self] in
                let pose = Pose2D(position: position, yaw: yaw)
                return enriched ? .init(pose: pose, frameID: .init(generation: controllerGeneration, sequence: independentControllerFrame ? 100 : sourceSequence),
                    sourceTimestamp: controllerSourceTimestamp ?? clock.now, trackingQuality: .normal) : .legacy(pose)
            }, sourceNow: { [self] in clock.now })
        lazy var coordinator: FollowMeCoordinator = {
            var config = FollowMeConfiguration()
            config.stationaryPauseSeconds = stationaryPauseSeconds
            return FollowMeCoordinator(perception: perception, motion: NavigationFollowMeMotion(navigation: controller),
                clock: clock, configuration: config, eventSink: { [self] in record($0, fields: $1) })
        }()
        func record(_ event: String, fields: [String: String]) {
            if event == "follow_state" { states.append(fields) }
            if let json = fields["payload"], let data = json.data(using: .utf8),
               let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { records.append(record) }
            if event == "follow_ready.admission_authorized" { authorizedCommands.append(commands) }
        }
        func send(_ sequence: UInt64, range: Double, peopleAvailable: Bool = true, tracking: ARTrackingQuality? = .normal,
                  timestamp: Double? = nil, depthAvailable: Bool = true, poseAvailable: Bool = true,
                  confidence: Float = 0.99, box: CGRect = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6),
                  secondPersonRange: Double? = nil, generation: UInt64 = 1, personFrameID: ARFrameID? = nil) {
            let id = ARFrameID(generation: generation, sequence: sequence)
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
                    pose: Pose2D(position: position, yaw: yaw), trackingQuality: tracking ?? .unavailable)
                perception.send(.frame(ARFollowMePerceptionSource.batch(from: snapshot, detections: peopleAvailable ? [
                    .init(label: "person", confidence: 0.99, boundingBox: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.3))] : [])))
                return
            }
            let person = FollowPersonObservation(frameID: personFrameID ?? id, timestamp: timestamp ?? clock.now,
                confidence: confidence, boundingBox: box,
                position: Vec2(range, 0), pose: Pose2D(position: position, yaw: yaw))
            var people = peopleAvailable ? [person] : []
            if let secondPersonRange {
                people.append(.init(frameID: id, timestamp: timestamp ?? clock.now, confidence: confidence, boundingBox: box,
                    position: Vec2(secondPersonRange, 0), pose: Pose2D(position: position, yaw: yaw)))
            }
            perception.send(.frame(.init(frameID: id, timestamp: timestamp ?? clock.now,
                pose: poseAvailable ? Pose2D(position: position, yaw: yaw) : nil, depthAvailable: depthAvailable,
                people: people, trackingQuality: tracking)))
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
