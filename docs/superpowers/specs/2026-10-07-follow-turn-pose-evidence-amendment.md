# Follow-Turn Ingress Pose Evidence and Specific Source Failures

## Approved scope

The user requested fixes for calibration failure caused by coalesced frames, misleading resolution messages, and stale-pose misclassification. Burst budgets, speed, tolerances, watchdogs, recovery deadlines, projection gates, confirmed-stop priority, and once-only readiness remain unchanged.

The October 7 runtime confirms authorization now takes less than 0.001 ms and motion requests receive HTTP 200. Alignment and scan instead fail `incomplete_or_ambiguous` because newest-only pose delivery skips source IDs. A separate planning sample ages from 499 ms to 501 ms with normal tracking and is correctly refused, but previously displayed tracking loss.

## Evidence delivery

- `ARSessionManager` records compact pose witnesses synchronously at ingress, before newest-only image delivery. Each witness contains yaw, actual frame/generation, source timestamp, actual collection uptime, source identity, tracking quality, and collection validity. No image, depth buffer, mesh, or detector payload is retained.
- The archive has a hard capacity of 128 witnesses. Reset, interruption, and failure clear it. Evicted or missing ranges are explicitly unavailable.
- Control and person-perception streams remain newest-only. Archived data is never read to authorize motion, claim fresh tracking, establish readiness, or alter current target/phase.
- At settled burst evaluation, production requests the complete ingress range between the actual planning and stopped-evaluation frame IDs. Every frame and generation must be present in order, and both endpoints must exactly match their independent control observations, including timestamps and yaw.
- Only a complete matching range replaces coalesced delivery evidence. The original planning boundary is retained for adjacent-burst provenance; the final endpoint retains the actual settled evaluation time. The existing response reducer still validates every timestamp, collection age, tracking state, operation attribution, and angular traversal rule.
- Missing archive ranges cannot fall back to a supposedly complete consumer stream. Legacy providers without an archive retain conservative delivery-based validation; they do not receive invented ingress facts.

## Failure semantics

Incomplete, invalid, or unreliable response evidence uses internal cause `calibration_evidence_incomplete`, with the existing public resolution-failure case. It reports incomplete calibration evidence rather than asserting physical response is too coarse. A valid learned model with no positive correction budget retains the genuine resolution-failure explanation.

Normal tracking with a source rejected as `stale_source` uses internal cause `pose_source_stale`, retaining the existing public tracking-failure case and the same stop gates. Operator text is: “Camera pose is stale. Motion stopped; wait for fresh camera frames.” Tracking unavailability, generation changes, and missing pose keep their own existing failure semantics. Failed stopping remains the highest-priority blocked-motion message.

Fresh stopped arrival remains independent of calibration eligibility: an already-authorized, genuinely fresh stopped pose inside tolerance may arrive without learning an unreliable bracket. Outside tolerance, unavailable evidence ends the operation stopped; it never authorizes an automatic retry or extra probe.

## Regression and acceptance evidence

Regression-first checks cover actual AR ingress while snapshot consumption is suspended, archive eviction/reset/interruption, real controller learning despite a dropped control frame, and failure when an explicitly supplied archive is unavailable even though consumer delivery is otherwise complete. No contiguous-frame or freshness check is disabled.

Message regressions reproduce stale planning with normal tracking and distinguish rejected response evidence from true coarse response. Shared reduction retains both specific causes across stream/result orders, generic wrappers, stale success, and failed stop.

Detailed response telemetry labels `bounded_AR_ingress_archive` versus compatibility control evidence, the 128-witness capacity, and unavailable/mismatched range reasons. Capture time remains distinct from later evaluation time.

Physical small-angle accuracy is not established by these software corrections. The latest alignment still showed approximately 10° AR response to a 5° target; complete evidence may therefore correctly produce a genuine resolution failure. No change to actuation magnitude, tolerance, timing budget, or the separate 10 cm readiness motion is implied.

Changes are uncommitted; no physical-device actions are part of this implementation task. Final review and verification results will be appended after execution.

## Final review and verification

Review found that archive substitution could erase an unhealthy control collection. A same-generation regression reproduced that defect before the correction. Non-repairable invalidity is now sticky: unhealthy collections (including duplicates), replay/reordering, and capacity overflow cannot be repaired by an archive. Only delivery gaps can be filled. Follow-up review found no remaining high/medium issue in scope; Standards found no documented breaches.

The initial review fixture used the wrong AR generation and was green for an unrelated reason. It was corrected to generation 4 before recording the actual assertion-red and applying the production correction.

| Final gate | Result |
| --- | --- |
| Full non-live SDK | 781 passed, 0 failed, 0 skipped |
| All app unit tests | 33 passed, 0 failed, 0 skipped |
| Unsigned generic-iOS Debug build | Succeeded |
| Whitespace checks | Passed |

All final tests ran serially with unchanged 60-second per-test limits. The SDK command used `scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`. App tests used `PhroverOperatorTests` on simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`; build used `generic/platform=iOS`, Debug, and `CODE_SIGNING_ALLOWED=NO`.

Evidence bundles in the approved temporary directory: `pose-ingress-evidence-sdk-final.xcresult`, `pose-ingress-evidence-app-verified.xcresult`, and `pose-evidence-review-fixed.xcresult`.

The first scoped run exposed a recovery-boundary fixture failure; adding an explicit per-boundary cancelled-result assertion retained the original matrix expectation. Five focused executions and the final full suite passed. No recovery deadline or expected result was weakened.

The first app invocation executed no tests because the simulator denied launch as Busy. After booting the already-shutdown selected simulator and waiting for readiness, the app suite passed. Only simulator infrastructure was changed; the physical iPhone was not launched or moved.

Existing warnings remain for older Sendable test captures, `UIScreen.main`, launch configuration, and the package supported-platform notice. Software verification does not establish physical turn resolution, motor timing, or braking.
