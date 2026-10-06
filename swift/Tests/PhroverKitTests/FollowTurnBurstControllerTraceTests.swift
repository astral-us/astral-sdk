import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class FollowTurnBurstControllerTraceTests: XCTestCase {
    func testCoalescedBracketCannotVetoFreshStoppedArrivalAtInclusivePurposeBoundaries() async throws {
        let scanTolerance = 7 * Double.pi / 180
        for (purpose, startYaw, delta, endYaw, expected) in [
            (FollowMotionPurpose.followAlignment, 0.0, 0.5, 0.5, NavigationResult.arrived),
            (.followAlignment, -0.05, 0.1, 0.0, .arrived),
            (.followScan, -scanTolerance, 2 * scanTolerance, 0.0, .arrived),
            (.followAlignment, 0.0, 0.5, 0.2, .failed(.rotationResolutionInsufficient))
        ] {
            var uptime = 10.0
            var snapshot = sample(1, 9.99, yaw: startYaw)
            let events = AsyncStream<NavigationPoseSample>.makeStream()
            let sink = FollowDiagnosticRecordingSink()
            var stops = 0
            var sends = 0
            var controller: NavigationController!
            controller = NavigationController(currentPose: { snapshot.pose }, forwardClearance: { .infinity },
                plan: { _, _ in nil }, lastAckAt: { Date() }, sendCommand: { command in
                    sends += 1
                    XCTAssertEqual(abs(command.left), 0.25)
                    XCTAssertEqual(abs(command.right), 0.25)
                    uptime = 10.400
                    snapshot = self.sample(4, 10.39, yaw: endYaw) // Frame 3 was coalesced, not fabricated.
                    controller.ingestFollowTurnSource(snapshot)
                }, stopRover: { stops += 1 }, sleep: { try? await Task.sleep(for: $0) }, diagnosticEmitter:
                    .init(streamID: "coalesced-arrival", monotonic: { 700 }, utc: { Date() }, sink: sink.append),
                poseSample: { snapshot }, sourceNow: { uptime }, sourceEvents: { events.stream }, sourceStopSnapshot: { snapshot })
            let task = Task { await NavigationFollowMeMotion(navigation: controller).perform(
                purpose == .followAlignment ? .alignment(delta) : .scan(delta), context:
                    .init(sessionGeneration: 25, requestToken: 49, purpose: purpose, phase: "turning")) }
            for _ in 0..<1000 where stops == 0 { await Task.yield() }
            uptime = 10.300; snapshot = sample(2, 10.2, yaw: startYaw); controller.ingestFollowTurnSource(snapshot)
            for _ in 0..<1000 where stops < 2 { await Task.yield() }
            uptime = 10.701; snapshot = sample(5, 10.70, yaw: endYaw); controller.ingestFollowTurnSource(snapshot)
            let result = await task.value
            XCTAssertEqual(result.result, expected, "purpose=\(purpose), stopped yaw=\(endYaw)")
            XCTAssertEqual(sends, 1)
            XCTAssertEqual(stops, 2)
            let measured = try XCTUnwrap(try records(sink).first { $0["event"] as? String == "follow_scan.burst_response" })
            XCTAssertEqual(measured["bracket_valid"] as? Bool, false)
            XCTAssertNotNil(measured["bracket_rejection_reason"] as? String)
            XCTAssertEqual(measured["completed_responses"] as? Int, 0)
            XCTAssertEqual(try XCTUnwrap(measured["retained_response_rate_rad_s"] as? Double), 2 * .pi / 3, accuracy: 1e-12)
            events.continuation.finish()
        }
    }

    func testFeedbackDelayPastDeadlineIsNotReportedAsAdditionalMotorWait() async throws {
        var uptime = 10.0
        var snapshot = sample(1, 9.99)
        let events = AsyncStream<NavigationPoseSample>.makeStream()
        let sink = FollowDiagnosticRecordingSink()
        var feedback: CheckedContinuation<Void, Never>?
        var stops = 0
        var sends = 0
        var held = false
        var controller: NavigationController!
        controller = NavigationController(currentPose: { nil }, forwardClearance: { 2 }, plan: { _, _ in nil },
            lastAckAt: {
                if sends == 1, controller.followTurnBurstPendingStatus == nil, !held {
                    held = true
                    await withCheckedContinuation { feedback = $0 }
                }
                return Date()
            }, sendCommand: { _ in sends += 1; uptime = 10.330 }, stopRover: { stops += 1 },
            sleep: { try? await Task.sleep(for: $0) }, diagnosticEmitter:
                .init(streamID: "feedback-delay", monotonic: { 700 }, utc: { Date() }, sink: sink.append),
            poseSample: { snapshot }, sourceNow: { uptime }, sourceEvents: { events.stream }, sourceStopSnapshot: { snapshot })
        let task = Task { await NavigationFollowMeMotion(navigation: controller).perform(.alignment(0.5), context:
            .init(sessionGeneration: 25, requestToken: 49, purpose: .followAlignment, phase: "aligning")) }
        for _ in 0..<1000 where stops == 0 { await Task.yield() }
        uptime = 10.300; snapshot = sample(2, 10.2); controller.ingestFollowTurnSource(snapshot)
        for _ in 0..<1000 where feedback == nil { await Task.yield() }
        XCTAssertNotNil(feedback)
        uptime = 10.430; feedback?.resume(); feedback = nil
        for _ in 0..<1000 where stops < 2 { await Task.yield() }
        uptime = 10.731; snapshot = sample(3, 10.73, yaw: 0.5); controller.ingestFollowTurnSource(snapshot)
        let result = await task.value
        XCTAssertEqual(result.result, .arrived)
        let wait = try XCTUnwrap(try records(sink).first { $0["event"] as? String == "follow_scan.burst_wait_end" })
        XCTAssertEqual(wait["requested_additional_wait_s"] as? Double, 0)
        XCTAssertEqual(wait["actual_additional_wait_s"] as? Double, 0,
            "Feedback suspension is host latency, not an actually entered motor wait")
        events.continuation.finish()
    }

    func testHealthySourceIngressDoesNotSynchronouslyEmitFullBurstRecordsOrReadProviders() async throws {
        var uptime = 10.0
        var snapshot = sample(1, 9.99)
        let events = AsyncStream<NavigationPoseSample>.makeStream()
        let sink = FollowDiagnosticRecordingSink()
        var response: CheckedContinuation<Void, Never>?
        var stops = 0
        var reads = 0
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { 2 }, plan: { _, _ in nil },
            lastAckAt: { Date() }, sendCommand: { _ in await withCheckedContinuation { response = $0 } },
            stopRover: { stops += 1 }, sleep: { try? await Task.sleep(for: $0) }, diagnosticEmitter:
                .init(streamID: "healthy-ingress", monotonic: { 900 }, utc: { Date() }, sink: sink.append),
            poseSample: { reads += 1; return snapshot }, sourceNow: { uptime }, sourceEvents: { events.stream }, sourceStopSnapshot: { snapshot })
        let task = Task { await NavigationFollowMeMotion(navigation: controller).perform(.alignment(0.5), context:
            .init(sessionGeneration: 24, requestToken: 48, purpose: .followAlignment, phase: "aligning")) }
        for _ in 0..<1000 where stops == 0 { await Task.yield() }
        uptime = 10.300; snapshot = sample(2, 10.2); controller.ingestFollowTurnSource(snapshot)
        for _ in 0..<1000 where response == nil { await Task.yield() }
        let count = sink.records.count
        uptime = 10.320
        for sequence in UInt64(3)...34 {
            snapshot = sample(sequence, 10.300 + Double(sequence) * 0.0001)
            controller.ingestFollowTurnSource(snapshot)
        }
        XCTAssertEqual(sink.records.count, count, "Healthy ingress only retains bounded facts; no full per-frame emission")
        XCTAssertEqual(reads, 1, "The emitter has no source provider seam")
        uptime = 10.400; response?.resume(); response = nil
        for _ in 0..<1000 where stops < 2 { await Task.yield() }
        uptime = 10.701; snapshot = sample(35, 10.70, yaw: 0.5); controller.ingestFollowTurnSource(snapshot)
        let result = await task.value
        XCTAssertEqual(result.result, .arrived)
        let measured = try XCTUnwrap(try records(sink).first { $0["event"] as? String == "follow_scan.burst_response" })
        XCTAssertEqual(measured["bracket_sample_count"] as? Int, 34)
        XCTAssertEqual((measured["source_bracket"] as? [Any])?.count, 34)
        XCTAssertEqual(reads, 1)
        events.continuation.finish()
    }

    func testSampledPostAckTravelReportsActualEndpointSourcesAndIntervals() async throws {
        var uptime = 10.0
        var snapshot = sample(1, 9.99)
        let events = AsyncStream<NavigationPoseSample>.makeStream()
        let sink = FollowDiagnosticRecordingSink()
        var response: CheckedContinuation<Void, Never>?
        var stops = 0
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { 2 }, plan: { _, _ in nil },
            lastAckAt: { Date() }, sendCommand: { _ in await withCheckedContinuation { response = $0 } },
            stopRover: { stops += 1; if stops == 2 { uptime = 10.340 } }, sleep: { try? await Task.sleep(for: $0) },
            diagnosticEmitter: .init(streamID: "partial-coast", monotonic: { 800 }, utc: { Date() }, sink: sink.append),
            poseSample: { snapshot }, sourceNow: { uptime }, sourceEvents: { events.stream }, sourceStopSnapshot: { snapshot })
        let task = Task { await NavigationFollowMeMotion(navigation: controller).perform(.scan(0.3), context:
            .init(sessionGeneration: 22, requestToken: 46, purpose: .followScan, phase: "scanning")) }
        for _ in 0..<1000 where stops == 0 { await Task.yield() }
        uptime = 10.300; snapshot = sample(2, 10.2); controller.ingestFollowTurnSource(snapshot)
        for _ in 0..<1000 where response == nil { await Task.yield() }
        uptime = 10.320; snapshot = sample(3, 10.31, yaw: 0.35); controller.ingestFollowTurnSource(snapshot)
        uptime = 10.330; response?.resume(); response = nil
        for _ in 0..<1000 where stops < 2 { await Task.yield() }
        uptime = 10.351; snapshot = sample(4, 10.35, yaw: 0.32); controller.ingestFollowTurnSource(snapshot)
        uptime = 10.641; snapshot = sample(5, 10.64, yaw: 0.3); controller.ingestFollowTurnSource(snapshot)
        let result = await task.value
        XCTAssertEqual(result.result, .arrived)
        let measured = try XCTUnwrap(try records(sink).first { $0["event"] as? String == "follow_scan.burst_response" })
        XCTAssertEqual(try XCTUnwrap(measured["response_signed_net_rad"] as? Double), 0.3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(measured["response_sampled_absolute_travel_rad"] as? Double), 0.4, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(measured["effective_budget_response_rate_rad_s"] as? Double), 3.75, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(measured["observed_post_ack_travel_rad"] as? Double), 0.02, accuracy: 1e-12)
        XCTAssertEqual(measured["post_ack_travel_confidence"] as? String, "partial_sampled")
        XCTAssertEqual(measured["unsampled_coast_confidence"] as? String, "unknown")
        let endpoints = try XCTUnwrap(measured["post_ack_sample_endpoints"] as? [[String: Any]])
        XCTAssertEqual(endpoints.compactMap { $0["frame_id"] as? String }, ["4:4", "4:5"])
        XCTAssertEqual(endpoints.compactMap { $0["source_identity"] as? String }, ["trace_fixture", "trace_fixture"])
        XCTAssertEqual(endpoints.compactMap { $0["tracking_state"] as? String }, ["normal", "normal"])
        let intervals = try XCTUnwrap(measured["source_intervals"] as? [[String: Any]])
        XCTAssertEqual(intervals.count, 3)
        XCTAssertEqual(try XCTUnwrap(intervals.first?["observed_rate_rad_s"] as? Double), 3.18181818181818, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(measured["maximum_consecutive_source_rate_rad_s"] as? Double), 3.18181818181818, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(measured["net_source_interval_s"] as? Double), 0.44, accuracy: 1e-12)
        events.continuation.finish()
    }

    func testThirtyMillisecondAckRequestsOnlyRemainingBudgetAndSourceWakeRecordsActualWait() async throws {
        var uptime = 10.0
        var snapshot = sample(1, 9.99)
        let events = AsyncStream<NavigationPoseSample>.makeStream()
        let sink = FollowDiagnosticRecordingSink()
        var stops = 0
        var sends = 0
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { 2 }, plan: { _, _ in nil },
            lastAckAt: { Date() }, sendCommand: { _ in sends += 1; uptime = 10.330 }, stopRover: { stops += 1 },
            sleep: { try? await Task.sleep(for: $0) }, diagnosticEmitter:
                .init(streamID: "remaining", monotonic: { 700 }, utc: { Date() }, sink: sink.append),
            poseSample: { snapshot }, sourceNow: { uptime }, sourceEvents: { events.stream }, sourceStopSnapshot: { snapshot })
        let task = Task { await NavigationFollowMeMotion(navigation: controller).perform(.alignment(0.5), context:
            .init(sessionGeneration: 21, requestToken: 45, purpose: .followAlignment, phase: "aligning")) }
        for _ in 0..<1000 where stops == 0 { await Task.yield() }
        uptime = 10.300; snapshot = sample(2, 10.2); controller.ingestFollowTurnSource(snapshot)
        for _ in 0..<1000 where !sink.records.contains(where: { $0.event == "follow_scan.pulse_wait_begin" }) { await Task.yield() }
        uptime = 10.350; snapshot = sample(3, 10.34, yaw: 0.5); controller.ingestFollowTurnSource(snapshot)
        for _ in 0..<1000 where stops < 2 { await Task.yield() }
        uptime = 10.651; snapshot = sample(4, 10.64, yaw: 0.5); controller.ingestFollowTurnSource(snapshot)
        let result = await task.value
        XCTAssertEqual(result.result, .arrived)
        XCTAssertEqual(sends, 1)
        let all = try records(sink)
        let wait = try XCTUnwrap(all.first { $0["event"] as? String == "follow_scan.burst_wait_end" })
        XCTAssertEqual(try XCTUnwrap(wait["requested_additional_wait_s"] as? Double), 0.05, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(wait["actual_additional_wait_s"] as? Double), 0.02, accuracy: 1e-12)
        XCTAssertEqual(wait["wait_wake_reason"] as? String, "crossing")
        XCTAssertEqual(wait["additional_wait_clock"] as? String, "ar_system_uptime")
        let admitted = try XCTUnwrap(all.last { $0["event"] as? String == "follow_scan.stopped_source_accepted" })
        XCTAssertEqual(admitted["source_gate_strict_post_ack"] as? Bool, true)
        XCTAssertEqual(admitted["source_gate_ack_uptime_s"] as? Double, 10.35)
        XCTAssertEqual(admitted["watchdog_checkpoint_clock"] as? String, "controller_watchdog_date")
        XCTAssertEqual(admitted["continuous_outage_limit_s"] as? Double, 2)
        XCTAssertEqual(admitted["recovery_episode_limit_s"] as? Double, 10)
        events.continuation.finish()
    }

    func testStoppedSourceExpiryKeepsOriginalCaptureAndReportsFenceRejection() async throws {
        var uptime = 10.0
        let snapshot = sample(8, 9.99)
        let events = AsyncStream<NavigationPoseSample>.makeStream()
        let sink = FollowDiagnosticRecordingSink()
        var reads = 0
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { 2 },
            plan: { _, _ in nil }, lastAckAt: { Date() }, sendCommand: { _ in XCTFail("Must stay stopped") },
            stopRover: {}, sleep: { duration in
                uptime += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            }, diagnosticEmitter: .init(streamID: "expired-source", monotonic: { 600 }, utc: { Date() }, sink: sink.append),
            poseSample: { reads += 1; return snapshot }, sourceNow: { uptime }, sourceEvents: { events.stream },
            sourceStopSnapshot: { snapshot })
        let result = await NavigationFollowMeMotion(navigation: controller).perform(.alignment(0.3), context:
            .init(sessionGeneration: 20, requestToken: 44, purpose: .followAlignment, phase: "aligning"))
        XCTAssertEqual(result.result, .failed(.trackingLost))
        XCTAssertEqual(reads, 1)
        let all = try records(sink)
        let rejected = try XCTUnwrap(all.last { $0["event"] as? String == "follow_scan.stopped_source_rejected" })
        XCTAssertEqual(rejected["source_gate_reason"] as? String, "stale_source")
        let source = try XCTUnwrap(rejected["source_gate_sample"] as? [String: Any])
        XCTAssertEqual(source["source_timestamp_s"] as? Double, 9.99)
        XCTAssertEqual(source["frame_id"] as? String, "4:8")
        XCTAssertEqual(source["source_identity"] as? String, "trace_fixture")
        XCTAssertEqual(source["tracking_state"] as? String, "normal")
        XCTAssertGreaterThan(try XCTUnwrap(source["age_s"] as? Double), 0.5)
        XCTAssertEqual(rejected["source_gate_ack_uptime_s"] as? Double, 10)
        XCTAssertEqual(rejected["source_gate_highest_sequence"] as? Int, 8)
        XCTAssertLessThanOrEqual(all.filter { ($0["event"] as? String)?.hasPrefix("follow_scan.stopped_source") == true }.count, 4)
        events.continuation.finish()
    }

    func testPendingCrossingRecordsObligationBeforeAckAndSerializedStopFence() async throws {
        var uptime = 10.0
        var snapshot = sample(1, 9.99)
        let events = AsyncStream<NavigationPoseSample>.makeStream()
        let sink = FollowDiagnosticRecordingSink()
        let emitter = FollowDiagnosticEmitter(streamID: "pending", monotonic: { 900 }, utc: { Date() }, sink: sink.append)
        var response: CheckedContinuation<Void, Never>?
        var stops = 0
        var sends = 0
        var reads = 0
        let controller = NavigationController(currentPose: { XCTFail("No legacy read"); return nil },
            forwardClearance: { 2 }, plan: { _, _ in nil }, lastAckAt: { Date() }, sendCommand: { _ in
                sends += 1
                await withCheckedContinuation { response = $0 }
            }, stopRover: { stops += 1; if stops == 2 { uptime += 0.020 } },
            sleep: { try? await Task.sleep(for: $0) }, diagnosticEmitter: emitter,
            poseSample: { reads += 1; return snapshot }, sourceNow: { uptime },
            sourceEvents: { events.stream }, sourceStopSnapshot: { snapshot })
        let task = Task { await NavigationFollowMeMotion(navigation: controller).perform(.alignment(0.5), context:
            .init(sessionGeneration: 19, requestToken: 43, purpose: .followAlignment, phase: "aligning")) }
        for _ in 0..<1000 where stops == 0 { await Task.yield() }
        uptime = 10.300; snapshot = sample(2, 10.2); controller.ingestFollowTurnSource(snapshot)
        for _ in 0..<1000 where response == nil { await Task.yield() }
        uptime = 10.320; snapshot = sample(3, 10.31, yaw: 0.55); controller.ingestFollowTurnSource(snapshot)
        let pendingRecords = try records(sink)
        // Cleanup before throwable assertions: RED must drain the real controller.
        let obligation = pendingRecords.first { $0["event"] as? String == "follow_scan.burst_stop_obligation" }
        XCTAssertEqual(stops, 1, "Pending send must drain before stop")
        uptime = 10.400; response?.resume(); response = nil
        for _ in 0..<1000 where stops < 2 { await Task.yield() }
        uptime = 10.721; snapshot = sample(4, 10.70, yaw: 0.5); controller.ingestFollowTurnSource(snapshot)
        let result = await task.value
        XCTAssertEqual(result.result, .arrived)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(sends, 1)
        let captured = try XCTUnwrap(obligation)
        XCTAssertEqual(captured["stop_trigger_reason"] as? String, "crossing")
        XCTAssertEqual(captured["sender_still_pending"] as? Bool, true)
        XCTAssertEqual(captured["stop_obligation_uptime_s"] as? Double, 10.32)
        XCTAssertEqual(captured["session_generation"] as? Int, 19)
        let completed = try XCTUnwrap(try records(sink).first { $0["event"] as? String == "follow_scan.burst_stop_confirmed" })
        XCTAssertEqual(completed["stop_admission_uptime_s"] as? Double, 10.4)
        XCTAssertEqual(try XCTUnwrap(completed["stop_obligation_to_ack_s"] as? Double), 0.1, accuracy: 1e-12)
        XCTAssertEqual(completed["stop_fence_highest_sequence"] as? Int, 3)
        XCTAssertEqual(completed["stop_ack_return_uptime_s"] as? Double, 10.42)
        XCTAssertEqual(completed["requested_additional_wait_s"] as? Double, 0)
        events.continuation.finish()
    }

    private func sample(_ sequence: UInt64, _ timestamp: Double, yaw: Double = 0) -> NavigationPoseSample {
        .init(pose: .init(position: .zero, yaw: yaw), frameID: .init(generation: 4, sequence: sequence),
            sourceTimestamp: timestamp, trackingQuality: .normal, source: "trace_fixture")
    }

    private func records(_ sink: FollowDiagnosticRecordingSink) throws -> [[String: Any]] {
        try sink.records.map { record in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(record.fields["payload"]).utf8)) as? [String: Any])
        }
    }
}
