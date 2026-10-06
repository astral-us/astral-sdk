import Foundation

/// Bounded operation-local telemetry projection. Receives immutable control facts;
/// owns no clock, source provider, wait, transport, or motion authorization.
@MainActor
final class FollowTurnBurstDiagnosticTrace {
    private(set) var fields: [String: FollowDiagnosticValue] = [:]
    private var burstIndex = 0
    private var obligationRecorded = false
    private var sourceReasons: Set<String> = []
    private var sourceFenceID: UUID?
    private var hasObservedRate = false

    func planning(_ calibration: FollowTurnBurstPlanner.Calibration, sample: NavigationPoseSample,
                  profile: FollowTurnBurstPlanner.Profile, decision: FollowTurnBurstPlanner.Decision, uptime: Double) {
        let error = sample.pose.map { FollowReacquisitionPlanner.wrap(calibration.targetYaw - $0.yaw) }
        let excess = error.map { max(0, abs($0) - profile.tolerance) }
        retain(calibration)
        fields["planning_uptime_s"] = .number(uptime)
        fields["controller_phase"] = .string("stopped_planning")
        fields["budget_formula"] = .string("min(maximum,max(0,E/R-A-C/R),overshootCeiling)")
        fields["budget_units"] = .string("angles_rad;rates_rad/s;durations_s;wheels_m/s")
        fields["allowance_policy"] = .string("conservative_send_plus_stop_including_drain;effective_rate_latency_double_count")
        fields["tolerance_rad"] = .number(profile.tolerance)
        fields["excess_rad"] = Self.number(excess)
        fields["signed_error_rad"] = Self.number(error)
        fields["signed_error_rad_display"] = error.map { .string(RotationDiagnosticMeasurement.angleDisplay($0)) } ?? .null
        fields["frozen_target_yaw_rad"] = .number(calibration.targetYaw)
        fields["profile_maximum_host_budget_s"] = .number(profile.maximumHostBurstBudget)
        fields["profile_fixed_wheel_magnitude_mps"] = .number(profile.fixedWheelMagnitude)
        fields["profile_breakaway_floor_mps"] = .number(profile.fixedWheelMagnitude)
        fields["profile_command_law"] = .string("fixed_signed_magnitude")
        fields["profile_yaw_gain_active"] = .bool(false)
        fields["minimum_host_budget_s"] = .null
        fields["budget_floor_policy"] = .string("no_hard_floor")
        fields["reference_rate_provenance"] = .string("provisional_120deg_per_s_not_certified")
        fields["candidate_budget_s"] = Self.number(excess.map {
            $0 / calibration.responseRate - (calibration.maximumSendDuration ?? 0)
                - (calibration.maximumStopDuration ?? 0) - (calibration.observedPostAckTravel ?? 0) / calibration.responseRate
        })
        fields["planning_source"] = .object(Self.source(sample, uptime: uptime))
        switch decision {
        case .burst(let direction, let budget):
            burstIndex += 1
            fields["selected_budget_s"] = .number(budget)
            fields["direction"] = .number(Double(direction))
            fields["planning_decision"] = .string("burst")
        case .arrived: fields["planning_decision"] = .string("arrived"); fields["selected_budget_s"] = .null
        case .resolutionFailure: fields["planning_decision"] = .string("rotation_resolution_insufficient"); fields["selected_budget_s"] = .null
        case .unavailable: fields["planning_decision"] = .string("unavailable"); fields["selected_budget_s"] = .null
        }
        fields["burst_index"] = .number(Double(burstIndex))
    }

    func reduction(_ response: FollowTurnBurstPlanner.Response, _ reduction: FollowTurnBurstPlanner.Reduction) {
        if reduction.rejection == nil, reduction.signedResponse != nil { hasObservedRate = true }
        retain(reduction.calibration)
        fields["controller_phase"] = .string("stopped_response_evaluation")
        fields["bracket_valid"] = .bool(reduction.rejection == nil)
        fields["bracket_complete_for_rate"] = .bool(reduction.rejection == nil && reduction.signedResponse != nil)
        fields["bracket_sample_count"] = .number(Double(response.samples.count))
        fields["response_burst_index"] = .number(Double(burstIndex))
        fields["bracket_rejection_reason"] = reduction.rejection.map { .string($0) } ?? .null
        fields["bracket_response_confidence"] = .string(reduction.rejection != nil ? "invalid" :
            (reduction.signedResponse == nil ? "unknown_missing_endpoints" : "observed_ar_sampled"))
        fields["response_signed_net_rad"] = Self.number(reduction.signedResponse)
        fields["response_sampled_absolute_travel_rad"] = Self.number(reduction.sampledAbsoluteTravel)
        fields["previous_requested_budget_s"] = .number(response.requestedBudget)
        fields["source_bracket"] = .array(response.samples.prefix(128).map { sample in .object([
            "frame_id": Self.frame(sample),
            "source_timestamp_s": Self.number(sample.sourceTimestamp), "collection_uptime_s": .number(sample.collectedUptime),
            "age_at_collection_s": Self.number(sample.sourceTimestamp.map { sample.collectedUptime - $0 }),
            "yaw_rad": .number(sample.yaw), "healthy_at_collection": .bool(sample.healthy),
            "source_identity": sample.sourceIdentity.map { .string($0) } ?? .null,
            "tracking_state": sample.trackingState.map { .string($0) } ?? .null,
            "clock": sample.clockDomain.map { .string($0) } ?? .null
        ]) })
        let intervals = zip(response.samples, response.samples.dropFirst()).prefix(127).map { before, after -> FollowDiagnosticValue in
            let dt = after.sourceTimestamp.flatMap { end in before.sourceTimestamp.map { end - $0 } }
            let delta = FollowReacquisitionPlanner.wrap(after.yaw - before.yaw)
            return .object(["source_interval_s": Self.number(dt), "signed_delta_rad": .number(delta),
                "observed_rate_rad_s": reduction.rejection == nil ? Self.number(dt.flatMap { $0 > 0 ? abs(delta) / $0 : nil }) : .null,
                "valid": .bool(reduction.rejection == nil),
                "invalid_reason": reduction.rejection.map { .string($0) } ?? .null])
        }
        fields["source_intervals"] = .array(intervals)
        let dt = response.samples.last?.sourceTimestamp.flatMap { end in response.samples.first?.sourceTimestamp.map { end - $0 } }
        fields["net_source_interval_s"] = reduction.signedResponse == nil ? .null : Self.number(dt)
        let rates = zip(response.samples, response.samples.dropFirst()).compactMap { before, after -> Double? in
            guard reduction.rejection == nil, reduction.signedResponse != nil,
                  let start = before.sourceTimestamp, let end = after.sourceTimestamp, end > start else { return nil }
            let rate = abs(FollowReacquisitionPlanner.wrap(after.yaw - before.yaw)) / (end - start)
            return rate.isFinite ? rate : nil
        }
        fields["maximum_consecutive_source_rate_rad_s"] = Self.number(rates.max())
        fields["response_measurement_provenance"] = .string("captured_ar_visual_inertial_not_physical_peak")
        fields["net_source_rate_rad_s"] = Self.number(reduction.signedResponse.flatMap { net in dt.flatMap { $0 > 0 ? abs(net) / $0 : nil } })
        fields["effective_budget_response_rate_rad_s"] = Self.number(reduction.signedResponse.map { abs($0) / response.requestedBudget })
        fields["post_ack_sample_endpoints"] = .array(response.samples.filter {
            ($0.sourceTimestamp ?? -.infinity) > response.stopAcknowledgementUptime
        }.prefix(128).map { sample in .object([
            "sequence": sample.sequence.map { .number(Double($0)) } ?? .null,
            "frame_id": Self.frame(sample),
            "source_identity": sample.sourceIdentity.map { .string($0) } ?? .null,
            "tracking_state": sample.trackingState.map { .string($0) } ?? .null,
            "source_timestamp_s": Self.number(sample.sourceTimestamp), "yaw_rad": .number(sample.yaw),
            "valid": .bool(reduction.rejection == nil)]) })
        fields["post_ack_travel_unknown_reason"] = .string(reduction.calibration.observedPostAckTravel == nil
            ? "no_valid_advancing_strict_post_ack_pair" : "ack_to_first_frame_and_unsampled_motion_unknown")
        fields["previous_excess_rad"] = Self.number(response.samples.first.map {
            max(0, abs(FollowReacquisitionPlanner.wrap(response.targetYaw - $0.yaw)) -
                (fields["tolerance_rad"].flatMap { if case .number(let value) = $0 { return value }; return nil } ?? 0))
        })
        fields["shrink_response_distance_rad"] = Self.number(reduction.signedResponse.map { abs($0) })
        fields["overshoot_shrink_formula"] = .string("previousBudget*min(1,previousExcess/abs(netResponse))")
    }

    private func retain(_ calibration: FollowTurnBurstPlanner.Calibration) {
        fields["reference_rate_rad_s"] = .number(2 * .pi / 3)
        fields["retained_response_rate_rad_s"] = .number(calibration.responseRate)
        fields["response_rate_confidence"] = .string(hasObservedRate ? "observed_effective_not_physical_bound" : "provisional_reference")
        fields["maximum_send_duration_s"] = Self.number(calibration.maximumSendDuration)
        fields["maximum_stop_duration_s"] = Self.number(calibration.maximumStopDuration)
        fields["latency_allowance_s"] = Self.number(calibration.maximumSendDuration.flatMap { send in calibration.maximumStopDuration.map { send + $0 } })
        fields["latency_confidence"] = .string(calibration.maximumSendDuration == nil ? "unknown" : "measured_host_maxima")
        fields["observed_post_ack_travel_rad"] = Self.number(calibration.observedPostAckTravel)
        fields["post_ack_travel_confidence"] = .string(calibration.observedPostAckTravel == nil ? "unknown" : "partial_sampled")
        fields["unsampled_coast_confidence"] = .string("unknown")
        fields["overshoot_ceiling_s"] = Self.number(calibration.overshootCeiling)
        fields["completed_responses"] = .number(Double(calibration.completedResponses))
    }

    static func source(_ sample: NavigationPoseSample, uptime: Double) -> [String: FollowDiagnosticValue] {
        ["frame_id": sample.frameID.map { .string("\($0.generation):\($0.sequence)") } ?? .null,
         "source_timestamp_s": Self.number(sample.sourceTimestamp), "collection_uptime_s": .number(uptime),
         "age_s": Self.number(sample.sourceTimestamp.map { uptime - $0 }),
         "yaw_rad": Self.number(sample.pose?.yaw), "source_identity": .string(sample.source),
         "tracking_state": sample.trackingQuality.map { .string(String(describing: $0)) } ?? .null,
         "availability": .string(sample.rejection(at: uptime, requireEnriched: true) ?? "available")]
    }

    private static func number(_ value: Double?) -> FollowDiagnosticValue { value.map { .number($0) } ?? .null }
    private static func frame(_ sample: FollowTurnBurstPlanner.Sample) -> FollowDiagnosticValue {
        guard let generation = sample.generation, let sequence = sample.sequence else { return .null }
        return .string("\(generation):\(sequence)")
    }

    func sourceGate(fence: FollowTurnStopFence, sample: NavigationPoseSample?, uptime: Double,
                    reason: String?, evidence: FollowMotionOperationEvidence, latch: Bool) {
        if sourceFenceID != fence.identity { sourceReasons.removeAll(); sourceFenceID = fence.identity }
        let reason = reason ?? "accepted"
        fields["controller_phase"] = .string(reason == "accepted" ? "stopped_source_accepted" : "stopped_source_wait")
        fields["source_gate_reason"] = .string(reason)
        fields["source_gate_sample"] = sample.map { .object(Self.source($0, uptime: uptime)) } ?? .null
        fields["source_gate_stop_id"] = .string(fence.identity.uuidString)
        fields["source_gate_ack_uptime_s"] = .number(fence.acknowledgementUptime)
        fields["source_gate_highest_sequence"] = fence.highestSequence.map { .number(Double($0)) } ?? .null
        fields["source_gate_highest_timestamp_s"] = Self.number(fence.highestSourceTimestamp)
        fields["source_gate_expected_generation"] = fence.sourceGeneration.map { .number(Double($0)) } ?? .null
        fields["source_gate_strict_post_ack"] = .bool(true)
        fields["settle_requested_s"] = .number(0.300)
        fields["ack_to_source_evaluation_s"] = .number(uptime - fence.acknowledgementUptime)
        fields["post_settle_source_wait_elapsed_s"] = .number(max(0, uptime - fence.acknowledgementUptime - 0.300))
        fields["source_freshness_limit_s"] = .number(0.500)
        fields["continuous_outage_limit_s"] = .number(2)
        fields["recovery_episode_limit_s"] = .number(10)
        fields["recovery_remaining_s"] = evidence.recoveryDeadline.map { .number(max(0, $0 - uptime)) } ?? .null
        // Immediate lifecycle evidence, at most one record per reason/fence.
        guard sourceReasons.count < 16, sourceReasons.insert(reason).inserted else { return }
        evidence.scanTrace?.emit(reason == "accepted" ? "stopped_source_accepted" : "stopped_source_rejected",
            evidence: evidence, latch: latch, outcome: reason == "accepted" ? "accepted" : "waiting_or_rejected", reason: reason)
    }

    func senderEntry(_ entry: Double, deadline: Double, budget: Double) {
        obligationRecorded = false
        for key in ["stop_obligation_uptime_s", "stop_trigger_reason", "stop_admission_uptime_s",
                    "stop_obligation_observed_uptime_s",
                    "stop_ack_return_uptime_s", "stop_obligation_to_ack_s", "source_bracket", "source_intervals",
                    "response_burst_index", "bracket_sample_count", "bracket_valid", "bracket_complete_for_rate",
                    "bracket_rejection_reason", "bracket_response_confidence", "response_signed_net_rad",
                    "response_sampled_absolute_travel_rad", "net_source_rate_rad_s", "net_source_interval_s",
                    "maximum_consecutive_source_rate_rad_s", "effective_budget_response_rate_rad_s",
                    "post_ack_sample_endpoints", "send_response_uptime_s", "send_entry_to_response_s",
                    "remaining_budget_at_response_s", "ack_overrun_s", "sender_outcome", "sender_failure_reason",
                    "transport_attempt_entries", "transport_entry_uptime_s", "transport_entry_availability",
                    "additional_wait_start_uptime_s", "additional_wait_end_uptime_s", "wait_wake_reason",
                    "stop_admission_to_ack_s", "pending_send_drain_s", "send_return_to_stop_admission_s",
                    "stop_fence_id", "stop_fence_operation_generation", "stop_fence_source_generation",
                    "stop_fence_highest_sequence", "stop_fence_highest_source_timestamp_s"] {
            fields[key] = .null
        }
        fields["controller_phase"] = .string("sending")
        fields.merge([
            "burst_clock": .string("ar_system_uptime"),
            "requested_host_budget_s": .number(budget),
            "send_entry_uptime_s": .number(entry), "burst_deadline_uptime_s": .number(deadline),
            "physical_motor_duration_s": .null,
            "physical_motor_duration_confidence": .string("unknown"),
            "physical_80ms_guarantee": .bool(false),
            "profile_historical_pulse_wait_s": .number(0.200),
            "profile_historical_pulse_wait_active": .bool(false),
            "profile_maximum_host_budget_s": .number(0.080),
            "requested_additional_wait_s": .number(0), "actual_additional_wait_s": .number(0)
        ]) { _, value in value }
    }

    func senderResponse(entry: Double, deadline: Double, response: Double,
                        attempts: [FollowTurnTransportAttempt], obligated: Bool, result: RoverCommandDiagnosticResult) {
        fields["controller_phase"] = .string("send_response")
        fields["send_response_uptime_s"] = .number(response)
        fields["send_entry_to_response_s"] = .number(response - entry)
        fields["remaining_budget_at_response_s"] = .number(max(0, deadline - response))
        fields["ack_overrun_s"] = .number(max(0, response - deadline))
        fields["stop_obligation_at_response"] = .bool(obligated || response >= deadline)
        fields["sender_outcome"] = .string(String(result.receipt.outcome.prefix(64)))
        if let denial = result.failure as? FollowTurnBurstTransportDenial {
            fields["sender_failure_reason"] = .string(String(describing: denial))
        } else {
            fields["sender_failure_reason"] = result.failure.map { .string(String(String(describing: type(of: $0)).prefix(64))) } ?? .null
        }
        fields["transport_attempt_entries"] = .array(attempts.prefix(3).map {
            .object(["operation_id": .number(Double($0.operationID)), "attempt": .number(Double($0.attempt)),
                "entry_uptime_s": .number($0.entryUptime)])
        })
        fields["transport_entry_uptime_s"] = attempts.first.map { .number($0.entryUptime) } ?? .null
        fields["transport_entry_availability"] = .string(attempts.isEmpty ? "not_exposed_by_sender" : "available")
    }

    func obligation(at uptime: Double, observedAt: Double? = nil, reason: String, pending: Bool,
                    evidence: FollowMotionOperationEvidence, latch: Bool) {
        guard !obligationRecorded else { return }
        obligationRecorded = true
        fields["stop_obligation_uptime_s"] = .number(uptime)
        fields["stop_obligation_observed_uptime_s"] = .number(observedAt ?? uptime)
        fields["stop_trigger_reason"] = .string(reason)
        fields["sender_still_pending"] = .bool(pending)
        fields["controller_phase"] = .string(pending ? "pending_send_stop_obligation" : "stop_obligation")
        evidence.scanTrace?.emit("burst_stop_obligation", evidence: evidence, latch: latch)
    }

    func stopAdmission(at uptime: Double) {
        fields["stop_admission_uptime_s"] = .number(uptime)
        if case .number(let response) = fields["send_response_uptime_s"] {
            fields["send_return_to_stop_admission_s"] = .number(max(0, uptime - response))
            if case .number(let obligation) = fields["stop_obligation_uptime_s"] {
                fields["pending_send_drain_s"] = .number(max(0, response - obligation))
            }
        }
        fields["controller_phase"] = .string("serialized_stop")
    }

    func stopConfirmed(_ fence: FollowTurnStopFence, obligation: Double, evidence: FollowMotionOperationEvidence, latch: Bool) {
        fields["stop_ack_return_uptime_s"] = .number(fence.acknowledgementUptime)
        fields["stop_obligation_to_ack_s"] = .number(fence.acknowledgementUptime - obligation)
        if case .number(let admission) = fields["stop_admission_uptime_s"] {
            fields["stop_admission_to_ack_s"] = .number(fence.acknowledgementUptime - admission)
        }
        fields["stop_fence_id"] = .string(fence.identity.uuidString)
        fields["stop_fence_operation_generation"] = .number(Double(fence.operationGeneration))
        fields["stop_fence_source_generation"] = fence.sourceGeneration.map { .number(Double($0)) } ?? .null
        fields["stop_fence_highest_sequence"] = fence.highestSequence.map { .number(Double($0)) } ?? .null
        fields["stop_fence_highest_source_timestamp_s"] = Self.number(fence.highestSourceTimestamp)
        fields["controller_phase"] = .string("confirmed_stop")
        evidence.scanTrace?.emit("burst_stop_confirmed", evidence: evidence, latch: latch)
    }

    func additionalWait(requested: Double, start: Double, end: Double) {
        fields["requested_additional_wait_s"] = .number(requested)
        fields["actual_additional_wait_s"] = .number(max(0, end - start))
        fields["additional_wait_start_uptime_s"] = .number(start)
        fields["additional_wait_end_uptime_s"] = .number(end)
        fields["additional_wait_clock"] = .string("ar_system_uptime")
    }

    func waitEnded(reason: String, evidence: FollowMotionOperationEvidence, latch: Bool) {
        fields["wait_wake_reason"] = .string(reason)
        fields["controller_phase"] = .string("remaining_wait_end")
        evidence.scanTrace?.emit("burst_wait_end", evidence: evidence, latch: latch)
    }
}
