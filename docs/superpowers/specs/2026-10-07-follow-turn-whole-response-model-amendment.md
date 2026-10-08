# Whole-Response Follow Turn Model

## Approved correction and evidence

The user approved fixing the negative correction budget in the latest device log while preserving detailed on-screen detection information and motion safety. The October 8 03:45 UTC attempt made approximately 12.36 degrees of progress from an 80 ms host request. Calibration was valid. The previous model then subtracted a 274 ms send-plus-stop allowance and sampled post-ack travel from a rate that already represented the entire response, producing a negative budget.

The earlier attempt failed confirmed-stop acquisition because all three HTTP stop requests timed out. That remains a real link failure. This amendment does not permit motion after unconfirmed stopping, automatically reconnect the phone, or treat a timeout as successful stopping.

## Consistent planning law

Let E be the excess absolute heading error outside the unchanged purpose tolerance. Retain one operation-local gain R: the maximum of the provisional 120-degree/s reference and all valid measured **sampled angular travel / requested host budget** ratios. Sampled travel is the sum of absolute wrapped source deltas, so reversals do not cancel travel and underestimate subsequent response.

The next request is `min(80 ms, E/R, overshootCeiling)`. Latency and sampled post-ack travel are already represented in whole-response travel. They remain explicit telemetry but are not charged again. Source-interval angular velocities remain diagnostic rather than being mixed with the end-to-end request gain. No claim is made that R bounds physical peak speed or future response under a different load/link.

Search and recovery retain inclusive 7-degree tolerance; final alignment retains inclusive 0.05 radians. A stopped observation with 0.1-radian error therefore completes a coarse search segment but still requires an alignment correction. No relaxed readiness heading gate or hidden extra motor owner is introduced.

The actual recorded residual of 0.270216427 rad and gain 2.696092912 yields a 54.910340 ms request for scan tolerance, instead of the earlier negative request. Overshoot still imposes a smaller correction ceiling, and every reversal requires confirmed stopping and fresh source admission. Gain never decreases during the operation. Zero progress does not increase the maximum request or reset the existing watchdog.

## Preserved safety

- The 80 ms immutable send-entry budget, synchronous expiring transport authority, .25 wheel magnitude, confirmed stop, 300 ms settle, and fresh distinct post-stop source gates remain unchanged.
- Missing or invalid calibration is not interpreted as zero response. `measuredResponses` separately counts full validated response brackets; latency-only records cannot authorize a second provisional probe.
- Source/frame/generation/clock validation, bounded archive, independent control-read validation, non-repairable invalidity, and exact adjacent-boundary replay checks remain intact.
- Unrepresentable/nonpositive requests and terminal evidence faults still fail closed. The 2.5-second / 0.05-radian progress watchdog, ten-second recovery episode, cancellation, Stop, failed-stop latch, and once-only readiness remain unchanged.
- No automatic retry of an expired transport command or partial readiness signal. The separate readiness-speed/progress issue is not fixed by this change.

## Diagnostics and regression evidence

Telemetry labels the formula as `min(maximum,E/R,overshootCeiling)` and allowance policy as `included_in_measured_response;diagnostic_only`. Existing latency and post-ack fields retain their measured values. Effective budget-response gain uses sampled travel, while net/source-rate fields remain separately labeled measurements. `measured_responses` distinguishes complete evidence from latency-only records.

Executed assertion-red before production changes for the captured search response, source-cadence-independent response gain with reversals, incomplete evidence blocking another probe, and truthful telemetry. Existing controller regressions are updated for the approved law: a corrective burst is allowed after a valid overshoot, but must be smaller and occur after acknowledged stop; its completion still requires a new settled source. Obsolete assertions requiring failure solely from duplicated latency deductions are replaced, not retained as safety policy.

This is an empirical command-response model, not a proof of precise physical turn resolution. The software can now use valid evidence to attempt a bounded correction; device effectiveness and braking remain separate supervised acceptance work. No device action, commit, or push is authorized by this implementation task.

## Final verification

The captured search case failed before the budget correction and passed afterward. Separate assertion-red/green checks covered cadence-independent whole-response gain, reversal travel, unmeasured-response denial, and the telemetry formula. A further regression demonstrated that a later missing response must terminate even after earlier successful calibration; that condition is now sticky for the operation.

The first full suite had 793 passes and one obsolete diagnostic assertion expecting immediate resolution failure from duplicated latency penalties. The fixture now supplies a genuine second settled response and asserts the smaller opposite correction, frozen target, retained latency/coast telemetry, and confirmed stop. No deadline, failure latch, or freshness expectation was relaxed.

| Final check | Result |
| --- | --- |
| Full non-live SDK | 794 passed, 0 failed, 0 skipped |
| App unit tests | 33 passed, 0 failed, 0 skipped |
| Unsigned generic-iOS Debug build | Succeeded |
| Whitespace | Passed |

Tests ran serially with unchanged 60-second allowances. SDK command used the repository script; app command used `PhroverOperatorTests` on simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Evidence bundles in the approved temporary directory are `whole-response-model-sdk-verified.xcresult` and `whole-response-model-app-verified.xcresult`; the initial failed suite is retained as `whole-response-model-sdk-final.xcresult`.

The final diff was inspected for unchanged transport/stop authority, purpose tolerances, immutable deadlines, and missing-evidence behavior. Existing older test-capture and launch-configuration warnings remain. No independent review or physical qualification is claimed in this task.
