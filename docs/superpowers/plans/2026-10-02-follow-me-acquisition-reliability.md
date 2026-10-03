# Follow-Me Acquisition Reliability — Implementation Plan

**Date:** 2026-10-02

**Authority:** User-approved specification at commit `b79319f`, [acquisition reliability design](../specs/2026-10-02-follow-me-acquisition-reliability-design.md).

**Status:** Tasks 1–6 complete. Independent review confirmed the three reviewed fixes and no remaining issues; latest-code affected SDK classes, full SDK/app unit suites, unsigned generic-iOS build, and whitespace/status checks passed. Supervised physical acceptance remains unverified and separately authorized.

**Method:** Manual writing-plans fallback; implementation must use `/tdd` at the already-approved seams. No further design interview is required.

## Execution contract

Implement Tasks 1–5 in order, then complete Task 6. Within each task, execute **one behavioral test → RUN RED → minimum implementation → RUN GREEN**, then proceed to the next slice. Do not write the entire task's tests before implementing it. A red run must fail for the intended behavioral difference (or the newly required additive API), not because the destination, fixtures, or build is broken. Record the test selector, failure, change, and green result in the implementation handoff; keep this plan focused rather than appending large logs.

Use the approved boundaries: public coordinator state/actions and perception events; real `NavigationController` through `NavigationFollowMeMotion` and its existing injection seam; synthetic AR buffers through projection/batch APIs; structured diagnostic sinks; app view-model actions/status. Test doubles belong at those dependencies, not private methods. Never call `driveReadySignal` or `performRotate` directly from tests. Real-controller admission races require the real adapter, not only a scripted motion double.

Preserve the five-second pause, initial at-most-2π requested scan budget, shortened final increment, 10-second reacquisition deadline, inclusive 500 ms freshness, two-second continuous outage recovery, 0.75 m association gate, exclusive motor ownership, detection fence, serialized confirmed stops, sticky failed-stop latch, typed failure precedence, frame coalescing, and fixed post-signal departure baseline. HTTP acknowledgement and AR orientation are not physical-motion proof.

### Commands for every red/green slice

All commands in this document are **future execution instructions**, with working directory `/Users/hungmai/Sites/Astral/astral-sdk` (repository root), not the current example-app directory. Select an installed iOS 26+ iPhone simulator using the root script; do not copy a historical UDID:

```sh
SIM_UDID=$(scripts/test-swift-sdk.sh --print-udid)
```

For a single SDK regression use the package scheme directly:

```sh
xcodebuild test -scheme astral-sdk-Package -destination "id=$SIM_UDID" \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testFollowCapAndToleranceWithoutGenericFloor
```

Replace the selector with the class/method for the current slice below; repeat the **identical selector** after the minimum implementation. Class-level runs are the task exit check. The root script already selects both SDK test targets, so use direct `xcodebuild` for narrow red/green isolation. Do not run `swift test` for ARKit-dependent `PhroverKitTests`; the full package requires an iOS destination.

## Task 1 — Fixed reliable follow pulses, with generic isolation

**Modify:**
- `swift/Sources/PhroverKit/Config/RoverConfig.swift`
- `swift/Sources/PhroverKit/Nav/RotationDiagnosticModels.swift` (`FollowScanRotationProfile`)
- `swift/Sources/PhroverKit/Nav/NavigationController.swift` (`performRotate`, follow-profile selection)
- `swift/Sources/PhroverKit/Nav/FollowScanDiagnosticTrace.swift`
- `swift/Tests/PhroverKitTests/NavigationFollowScanDiagnosticsTests.swift`

**Vertical slices:**
1. [x] Replace/rename the obsolete `testFollowCapAndToleranceWithoutGenericFloor` expectation. Through the real follow adapter, record wheel commands at large positive/negative error and just outside ±7°. Expect navigation-convention `left=-signed`, `right=signed`, with every nonzero magnitude **0.25 m/s**, including the near-tolerance case previously expecting 0.039. RUN RED; select `minimumRotateWheelSpeed` as both floor and cap only for captured `.followScan`; RUN GREEN. Use an explicit fixed-magnitude command law, not `min(cap, abs(error)*0.30)`.
2. [x] Add inclusive ±7° no-nonzero-command/confirmed-stop cases, wraparound near ±π, and overshoot outside tolerance producing an opposite-sign bounded pulse. RUN RED/GREEN individually. Retain 200 ms requested pulse → acknowledged serialized stop → 300 ms settle. Cancellation or detection during each suspension inhibits the next pulse.
3. [x] Assert emitted profile floor, cap, and command-law identity. Remove gain from active control or label retained 0.30 metadata inactive. RUN RED/GREEN. Keep the actual checkpoint/error-improvement watchdog metric and 2.5 s / 0.05 rad semantics: changing frame IDs without adequate yaw progress still fails; do not extend/reset the watchdog for settling.
4. [x] Run existing generic 80 ms scan/minimum-floor, continuous alignment, ready-motion tuning, pulse-stage timing, cancellation, and stop-failure regressions. Add a behavioral isolation test only if existing coverage cannot detect a profile leak. Verify the existing firmware-side mapping through `RoverControlTests`, without changing `sendNavigation`.

**Exit:** `NavigationFollowScanDiagnosticsTests`, `NavigationRotationWatchdogTests`, `NavigationSilentSearchMotionTests`, `NavigationFollowReadySignalTests`, and `RoverControlTests` pass. Preserve angle budgets/deadlines and all non-follow profiles. Only obsolete low-cap expectations change; do not replace unrelated safety assertions with weaker checks.

## Task 2 — Atomic pose provenance and post-feedback freshness

**Create focused unit:** `swift/Sources/PhroverKit/Nav/NavigationPoseSample.swift` — immutable pose/source facts and synchronous validation; no timer, provider protocol, wheel authority, or logger.

**Modify:**
- `swift/Sources/PhroverKit/Nav/NavigationController.swift` (production/injected initializers, follow scan and ready reads)
- `swift/Sources/PhroverKit/Nav/RotationDiagnosticModels.swift`
- `swift/Sources/PhroverKit/Nav/FollowScanDiagnosticTrace.swift`
- `swift/Tests/PhroverKitTests/NavigationFollowScanDiagnosticsTests.swift`
- `swift/Tests/PhroverKitTests/NavigationFollowReadySignalTests.swift`
- `swift/Tests/PhroverKitTests/ARSessionManagerTests.swift` where needed for reset/snapshot delivery

**Vertical slices:**
1. [x] Add a real-controller regression where repeated reads return a frozen source frame older than 0.500 s despite fresh read times. RUN RED; add default-nil optional enriched sample closure beside the existing `() -> Pose2D?` injection, plus an injectable synchronous source-monotonic clock defaulting to system uptime; RUN GREEN. Production must capture **one `ar.latestSnapshot`** atomically on MainActor for pose, ID/generation, source timestamp, tracking quality, and source identity. A configured enriched closure returning nil is unavailable, not permission to fall back to legacy pose.
2. [x] Add cases one at a time for exactly 0.500 s accepted, >0.500 s rejected, future/nonfinite source time, nonfinite/missing pose, abnormal tracking, and changed AR generation. Bind the expected source generation to the operation and compare actual snapshot generations; never compare unrelated coordinator/controller generation counters. RUN RED/GREEN. Invalid production provenance inhibits the command and enters existing confirmed-stop/failure handling; preserve coordinator outage policy.
3. [x] Suspend the acknowledgement getter in a follow scan, replace its pose/frame with expired or invalid provenance, then resume. RUN RED; order the relevant follow loop as **await feedback → cancellation/ownership/latch fence → capture current clocks and one sample → validate safety → authorize command**; RUN GREEN. Add a second slice changing fresh yaw across tolerance while suspended: use only post-await yaw/error for completion and command sign. Extend the existing ready `testAsyncAckGetterUsesPostAwaitClockPoseAndClearance` and Stop-during-ack regression to enriched provenance.
4. [x] Assert pre/post frame IDs, generations, source times/ages, read times, tracking and availability reasons come from the exact control samples. RUN RED/GREEN. Pass samples into the trace; it must not fetch pose again. Match actual frame IDs to label same-frame versus independently sampled, otherwise unknown. Keep signed six-decimal displays and full numeric values. Assert legacy pose-only injection has unknown source age and existing finite/missing-pose checks, rather than falsely failing it as stale.

**Clock and scope checks:** AR timestamps and source age use the common uptime domain; verify with deterministic injected uptime/source-time fixtures and the AR snapshot ingestion contract. Never subtract AR uptime from `Date`. Leave acknowledgement age and watchdog `Date` clocks explicitly labeled and unchanged. No extra await for samples/logging. Scope changed ordering/age enforcement to follow scan and ready authorization; do not casually reorder all generic navigation/alignment paths. Any shared helper must retain legacy behavior for callers outside the approved scope.

**Exit:** both follow navigation classes, `ARSessionManagerTests`, and existing rotation safety/watchdog coverage pass, including changing IDs with unchanged yaw, Stop/new-operation fencing during feedback, and failed-stop precedence.

### Tasks 1–2 execution evidence — 2026-10-02

Executed from repository root at HEAD `b79319f`, using the script-selected iPhone 17 Pro / iOS 26.5 simulator. Each change below had a narrow RED run before its production patch and the identical selector GREEN afterward: `xcodebuild test -quiet -scheme astral-sdk-Package -destination "id=$SIM_UDID" -only-testing:PhroverKitTests/<class>/<method>`. `N` below means `NavigationFollowScanDiagnosticsTests`; `R` means `NavigationFollowReadySignalTests`.

| Selector | Observed RED → minimum change → GREEN |
| --- | --- |
| N/testFollowFixedSignedMagnitudeOutsideTolerance | Old 0.10/0.039 magnitudes → fixed signed 0.25 pulse → passed |
| N/testCompletedPulseTraceUsesExistingSamplesExactHostTimingAndCapturedContext | Missing floor/law/inactive-gain fields → captured profile metadata → passed; separate later RED for incorrect legacy clock labels → unknown source / host read labels → passed |
| N/testFrozenOldSourceFrameCannotAuthorizeFollowPulse | Missing additive sample API → snapshot sample, optional closure and uptime validation → passed |
| N/testFutureSourceTimeCannotAuthorizeFollowPulse | Future source sent → reject negative age → passed |
| N/testNonfiniteSourceTimeCannotAuthorizeFollowPulse | NaN source sent → finite timestamp/clock validation → passed |
| N/testUnhealthyTrackingCannotAuthorizeFollowPulse | Limited/unavailable tracking sent → require normal tracking → passed |
| N/testNonfinitePoseCannotAuthorizeFollowPulse | Invalid pose authorized motion/completion → finite pose validation → passed |
| N/testARGenerationChangeInhibitsNextPulse | Reset generation sent a second pulse → bind actual AR generation → passed |
| N/testSuspendedFeedbackCannotAuthorizeExpiredSourcePose | Pre-await pose sent after expiry → feedback-first follow ordering and ownership fence → passed |
| N/testTraceRetainsExactPrePostSourceProvenanceWithoutExtraReads | Source fields missing → pass exact immutable control samples into diagnostics → passed |
| R/testReadyFeedbackSuspensionRejectsExpiredEnrichedPose | Ready sent on expired source → enriched preflight/post-feedback validation and scoped generation fence → passed |
| N/testExpiredPostSampleTraceRetainsActualSourceAndRejectionReason | Rejected post-source facts discarded → retain rejected immutable sample → passed |
| N/testPreflightRejectionLogsAvailableSourceFacts | Preflight source facts unknown → retain rejected start sample → passed |
| N/testPulseSummaryRetainsStageTimingsReceiptClockAndNullableStopCorrelation | Settle duration became zero after feedback reordering → retain wait-specific boundaries → passed |
| N/testGenericScanAndAlignmentDoNotConsultFollowSourceClockOrProvider | Generic loops consulted follow clock → scope clock read to follow scan → passed |
| N/testNonfiniteSourceTraceCannotClaimAvailableSourceAge | Nonfinite age labeled available → explicit nonfinite age status → passed |

Totals: **17 RED→GREEN cycles**, **20 net-new test methods**, two obsolete test names/low-cap expectations updated. New preservation checks for inclusive ±7°, wrapped overshoot, exact 500 ms/missing enriched input, post-feedback yaw/sign, frozen frame versus changing fresh IDs with flat yaw, real AR ingestion/reset, and replacement during enriched scan/ready feedback passed on their first run; these are not claimed as RED cycles. Extended existing ready post-await clock/pose/clearance and Stop-during-ack checks also passed. Fixture/build mistakes encountered during development were corrected and are not counted as behavioral RED evidence.

Final bounded exit: **106 passed, 0 failed, 0 skipped**, across `NavigationFollowScanDiagnosticsTests`, `NavigationRotationWatchdogTests`, `NavigationSilentSearchMotionTests`, `NavigationFollowReadySignalTests`, `RoverControlTests`, `ARSessionManagerTests`, and `FollowDiagnosticEventTests`. Result bundle: `Test-astral-sdk-Package-2026.10.02_15-34-13--0700.xcresult` in the package DerivedData `Logs/Test` directory. The first exit exposed the obsolete watchdog low-cap assertion and the settle-timing regression; both are resolved in this final result.

Compatibility/scope: production captures one MainActor `latestSnapshot`; legacy injection retains unknown age, and configured enriched nil never falls back. Source age/read clocks use AR/system uptime; transport and watchdog clocks remain separate. Pairing is explicitly scoped to controller pre/post samples, not an unsupported detector-frame claim. Coordinator recovery policy and generic/alignment/ready tuning are unchanged. Tasks 3–6, full SDK/app suites, unsigned build, and supervised physical acceptance remain pending; no commit/push or device execution performed.

## Task 3 — Follow-only 5×5 median feet projection and confidence transport

**Create focused units:**
- `swift/Sources/PhroverKit/FollowMe/FollowPersonProjection.swift` — deterministic result with accepted geometry or terminal rejection and measured facts.
- `swift/Sources/PhroverKit/FollowMe/FollowPerceptionDiagnostics.swift` — immutable frame-local raw/projection evidence, separate from motion and tracking authority.
- `swift/Tests/PhroverKitTests/FollowPersonProjectionTests.swift` — synthetic buffer inputs through the projection boundary.

**Modify:**
- `swift/Sources/PhroverKit/Perception/ARSessionManager.swift` (snapshot, delegate ingestion, testing ingestion)
- `swift/Sources/PhroverKit/FollowMe/ARFollowMePerceptionSource.swift` (`batch`, inference status)
- `swift/Sources/PhroverKit/FollowMe/FollowMeDependencies.swift` (default-nil batch evidence)
- `swift/Sources/PhroverKit/FollowMe/FollowMeModels.swift` (additive candidate correlation if needed)
- `swift/Tests/PhroverKitTests/ARSessionManagerTests.swift`
- `swift/Tests/PhroverKitTests/ARFollowMePerceptionSourceTests.swift`
- `swift/Tests/PhroverKitTests/FollowTargetTrackerTests.swift`

**Vertical slices:**
1. [x] Feed `batch` an interior box and stride-padded Float32 depth with a bad center pixel but a coherent neighborhood. Assert independently worked world coordinates from the 5×5 median. RUN RED; implement follow-only sampling and route batch through it; RUN GREEN. Preserve original feet `(midX,minY)`, inverse `.right` sensor coordinates `((1-y)*imageWidth,(1-x)*imageHeight)`, actual depth scaling, floored center, and the **original unrounded feet ray** for unprojection. Leave generic `ARSessionManager.unproject` behavior intact.
2. [x] Add full-window clipped/border and box tests individually: every touching/crossing image edge rejects; finite positive-area boxes strictly inside pass geometry checks; invalid image/depth sizes/layout reject. RUN RED/GREEN. No clamps, smaller windows, duplicated border pixels, or single-pixel fallback. Preserve world X/Z and camera −Z conventions; use worked cardinal/oblique transforms and ±π heading/range examples, including axial-depth versus Euclidean-range distinction.
3. [x] Add odd/even medians and sample-validity boundaries: NaN/infinite/≤0.05 invalid, exactly five valid accepted, four rejected. Then isolated outlier, MAD >0.10 rejection, insufficient 60%-within-0.20 inliers, and inclusive threshold examples. RUN RED/GREEN for each behavior. True even median is the mean of the two middle valid depths; minimum inliers is `ceil(0.60 * validCount)`.
4. [x] Add medium/high accepted, low/invalid confidence rejected, absent confidence explicitly unavailable, mismatched/wrong-format confidence rejected, and padded confidence-row tests. RUN RED; append default-nil confidence/source fields to snapshot initialization; RUN GREEN. In the AR delegate, retain the actual selected `smoothedSceneDepth ?? sceneDepth` object and transport **its depth and confidence together**, including selected-source identity. Carry these fields through `ingest`/testing ingestion without reading a later `currentFrame`. Use read-only locks, actual row strides, aligned one-component confidence, and unlock on every exit.
5. [x] Assert invalid intrinsics/focal lengths/transform and nonfinite world projection reject; no zero-position substitutes. RUN RED/GREEN. Populate rejection facts during the actual sample evaluation, not by a second diagnostic pass. Retain all applicable facts and the first terminal stage reason. Rejected raw people remain evidence but never become tracker observations.
6. [x] Through batch → real tracker, verify a stable person with one corrupted depth pixel remains associated, while a genuine projected jump >0.75 m still rejects. RUN RED/GREEN if missing coverage. Keep confidence 0.50, IoU/screen/world gates, ambiguity, and reacquisition rules unchanged.

**Evidence contract:** capture stable frame-local raw-person IDs, original box/detector confidence, clipping, feet/ray/depth coordinates and dimensions, chosen depth source, confidence availability, requested/valid/invalid-depth/low-confidence counts, median/MAD/inliers, accepted geometry and paired pose. Stable reasons are the spec's `invalid_box`, `clipped_box`, `depth_unavailable`, `invalid_depth_layout`, `invalid_confidence_map`, `clipped_depth_window`, `insufficient_valid_depth`, `inconsistent_depth`, `invalid_calibration`, `nonfinite_projection`. Define sample-count categories clearly so they reconcile without double-counting doubly-invalid pixels.

**Existing fixture directive:** `testPersonFeetProjectFromTheSameSnapshot` currently has a valid interior 20×20 fixture and worked X=1.8/Z=−3 coordinates; preserve that expectation. Change other center-only/tiny-map fixtures to support a full window only when their purpose is valid projection; add explicit rejection tests for deliberately undersized maps instead of hiding failures. Older snapshot/batch initializers must still compile.

**Exit:** `FollowPersonProjectionTests`, `ARFollowMePerceptionSourceTests`, `ARSessionManagerTests`, and `FollowTargetTrackerTests` pass. No temporal smoothing, gate relaxation, or change to non-follow object grounding.

### Task 3 execution evidence — 2026-10-02

Executed only Task 3 from repository root, preserving uncommitted Tasks 1–2 and unrelated work. Simulator selected by `scripts/test-swift-sdk.sh --print-udid`: iPhone 17 Pro / iOS 26.5. Each behavioral slice used `xcodebuild test -quiet -scheme astral-sdk-Package -destination "id=$SIM_UDID" -only-testing:PhroverKitTests/<class>/<method>` before its production patch and the identical selector afterward. Additive declarations compiled before asserting their behavior; no compile/fixture failure is counted as RED. `P` = `FollowPersonProjectionTests`, `A` = `ARSessionManagerTests`, `S` = `ARFollowMePerceptionSourceTests`.

| Selector | Assertion RED → minimum change → GREEN |
| --- | --- |
| P/testBatchUsesNeighborhoodMedianDespiteCorruptCenterWithPaddedStride | X=18/Z=−30 instead of 1.8/−3 → follow-only full-window median → passed |
| P/testBoxesMustHavePositiveFiniteAreaStrictlyInsideEveryEdge | Edge/zero/negative boxes produced people → strict normalized box checks (signed `size.width`, since CGRect `width` standardizes negatives) → passed |
| P/testUnsupportedDepthFormatRejectsRatherThanReadingAsFloat | Unsupported buffer produced person → Float32/nonplanar/stride layout checks → passed |
| P/testExactlyFiveFiniteDepthsAboveLowerBoundUseOddMedian | Invalid samples polluted median → finite >0.05 filtering and odd median → passed |
| P/testFourValidDepthsCannotProject | Four samples projected → minimum five → passed |
| P/testEvenMedianIsMeanOfMiddleTwoNotUpperMiddle | Upper middle gave Z=−3.02 → mean of middle pair in Double → passed |
| P/testMedianAbsoluteDeviationAbovePointOneRejectsMixedPatch | Mixed patch projected → MAD ≤0.10 → passed |
| P/testInliersRequireCeilingSixtyPercentEvenWhenMADIsZero | 14/25 inliers projected → ceil(60%) within 0.20 → passed |
| P/testLowAndInvalidConfidenceCannotSupplyValidSamples | Low/invalid levels projected → only medium/high samples → passed |
| P/testMalformedConfidenceIsRejectedInsteadOfIgnoredOrReinterpreted | Mismatched/wrong-format maps projected → aligned one-component layout validation → passed |
| P/testCalibrationRequiresAllFiniteElementsAndPositiveFocalLengths | Negative/nonfinite calibration projected → all-element finite and positive focal checks → passed |
| P/testBatchRetainsRejectedRawPeopleAndMeasuredProjectionFacts | Evidence nil → actual per-candidate facts, terminal reasons, reconciling counts and raw IDs → passed |
| P/testNonfiniteWorldProjectionHasTerminalReasonAndNoGeometry | Reason nil / nonfinite geometry present → full world-vector finite check → passed |
| A/testSnapshotIngestionRetainsSelectedDepthConfidencePairAndClearsItOnNextFrame | Confidence/source missing → paired selected-depth ingestion and default-nil transport → passed |
| S/testStreamMeasuresInferenceAndSkipsItForLimitedTracking | Executed instead of unknown outcome → truthful legacy detector status; skipped counts nil → passed |
| S/testFailedInferenceHasUnknownCountsAndDoesNotProjectSuppliedCandidates | Attempted count 1/candidates present → failed/not-evaluated path → passed |
| P/testEvidenceRetainsActualBufferFormatsOriginalCameraRayAndFullWorldPoint | Format/ray/world facts nil → capture actual values in same evaluation → passed |

**17 assertion RED→GREEN cycles**, **28 net-new methods**, plus one extended stream test. Preservation tests passed first run and are not claimed as RED: four depth borders/undersized maps, padded medium/high confidence and exclusive counts, differing 100×80 color / 20×20 depth dimensions with unrounded ray, cardinal/oblique/±π geometry, axial-depth versus ground range, retained snapshot after newer depth/confidence/pose, seven-sample ceiling, representable Float32 neighbors around dispersion thresholds, empty/missing depth/first reason, invalid image dimensions, and batch → real tracker corruption/jump isolation. Original same-snapshot X=1.8/Z=−3 test and all tracker thresholds remain intact. Count partition is `valid + invalid_depth + low_or_invalid_confidence = 25`; invalid depth takes precedence for doubly-invalid pixels. Before full-window evaluation, counts are nil, not zero; requested count 25 is the explicit policy.

Final bounded exit: **43 passed, 0 failed, 0 skipped**, across the four Task 3 exit classes, including Task 2's existing AR generation/controller test. Result bundle: `Test-astral-sdk-Package-2026.10.02_16-13-37--0700.xcresult` under `/Users/hungmai/Library/Developer/Xcode/DerivedData/astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/` (summary checked with `xcresulttool`). The earlier 16:11 exit also passed; final exit includes the corrected 100×80 color-buffer fixture matching its image resolution. `git diff --check` and explicit new-file whitespace checks passed. Xcode's rolling result retention pruned older narrow bundles; RED outcomes above were observed during execution, with recent assertion text also checked using `xcresulttool`.

Task 3 adds frame-local evidence only, with no new log emission, history, buffers in evidence, awaits, tracker authority, or generic unprojection changes. **No Task 3 blocker; Task 4 is next.** Task 5 follow-up: `Detector.detect` currently swallows errors into arrays; live outcome/raw detector counts remain explicitly unknown until Task 5 exposes its success/failure contract. Supplied successful detections have measured raw counts; all actual projection attempts/results are captured, and explicit failed/skipped evaluations keep counts unknown. Full SDK/app suites, unsigned build, device acceptance, and commit remain pending.

## Task 4 — Active clearance wait and admission at the real first-send boundary

**Create focused units:**
- `swift/Sources/PhroverKit/FollowMe/FollowReadyAdmission.swift` — typed admission decision, scoped token, and explicit not-started/deferred contextual outcome; no transport or timer.
- `swift/Tests/PhroverKitTests/FollowReadyAdmissionIntegrationTests.swift` — public coordinator + real navigation adapter + suspended injected transport/feedback.

**Modify:**
- `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift` (state declaration, frame processing, readiness reservation/result handling)
- `swift/Sources/PhroverKit/FollowMe/FollowMeModels.swift` (exact gate/display requirement)
- `swift/Sources/PhroverKit/FollowMe/FollowMeDependencies.swift` (additive contextual admission/legacy adapter)
- `swift/Sources/PhroverKit/FollowMe/NavigationFollowMeMotion.swift`
- `swift/Sources/PhroverKit/Nav/NavigationController.swift` (`performFollowMotion`, ready preflight, **`driveReadySignal` first send**)
- `swift/Sources/PhroverKit/Nav/RotationDiagnosticModels.swift` (contextual result wiring)
- `swift/Tests/PhroverKitTests/FollowMeCoordinatorTests.swift`
- `swift/Tests/PhroverKitTests/NavigationFollowReadySignalTests.swift`
- `swift/Tests/PhroverKitTests/Support/FollowMeTestDoubles.swift` and contextual doubles as needed
- `examples/PhroverOperator/PhroverOperator/App/ConversationViewModel.swift`
- `examples/PhroverOperator/PhroverOperator/Views/ConversationView.swift` (production configuration wiring)
- `examples/PhroverOperator/PhroverOperatorTests/ConversationViewModelTests.swift`

**Vertical slices:**
1. [x] Replace `testTooClosePersonCannotAuthorizeReadySignalAcrossHoldClearance`'s terminal-failure expectation with active `waitingForClearance`, zero ready sends, and retained matched track after confirmed alignment stop/new fresh frame. RUN RED; add state/isActive and stopped wait processing; RUN GREEN. Continue updating locked/last position through normal coalescing. Do not align/scan/navigate while heading remains adequate; insufficient range alone does not consume an attempt, establish a baseline, or fail.
2. [x] Send gradual fresh matched step-back observations and test exact **minimumHoldDistance + 0.12 = 1.37 m inclusive** eligibility. RUN RED/GREEN. Expired/cached/future frames cannot release wait. Heading drift >0.05 rad exits wait into existing stop-bracketed alignment; require its new post-stop matched frame before reevaluation. Genuine loss/ambiguity/outage uses existing policy; still-matched waiting gets no new timeout and does not reset active deadlines.
3. [x] Add the real-adapter regression: eligible frame launches preflight, acknowledgement suspends, latest matched person becomes too close, then feedback resumes. RUN RED; plumb synchronous admission through contextual motion into **the private `driveReadySignal` loop**, after its feedback await and all pose/path/obstacle/comms/ownership/latch checks, immediately before its first nonzero `sendCommand` initiation; RUN GREEN. An adapter/controller-entry callback before the await is not a valid fix. No await or unstructured task may occur between accepted admission and send initiation.
4. [x] Model pending admission independently of `readySignalAttempted`. The coordinator callback validates current generation/request token, exclusive ownership, cancellation/latch, latest processed/pending observation health and timestamp, same-track match, heading and range; atomically consumes the attempt and enters `signalingReady` only on acceptance. If a newer pending frame has not been associated yet, it cannot be certified by the old locked range: defer until normal evaluation or fail closed under its actual health/loss policy. Add two-eligible-frame concurrency and stale-token regressions, each RUN RED/GREEN.
5. [x] Return a typed contextual **not-started/deferred** result for insufficient clearance, release only its matching pending token, and keep/return confirmed-stopped wait. Route heading drift to alignment and loss/outage to existing handling. Update contextual result reduction so deferral cannot become `.arrived`, an ordinary navigation failure, or a completed ready signal. Retain existing public `FollowMeMotion`/`NavigationResult` APIs; add optional/internal companion behavior with default compatibility implementations. The legacy adapter admits synchronously at its actual `signalReady()` call authorization boundary and reports unavailable first-wheel telemetry. Production uses controller admission.
6. [x] Individually RUN RED/GREEN for Stop/new generation while preflight is suspended, unsafe swept path, obstacle/nonfinite clearance, stale/future acknowledgement, invalid enriched pose, and failed stop. These retain specific safety failures, not clearance deferrals. Pass the captured operation reservation into loop authorization so replacement/Stop cannot send. Confirm deferral itself leaves motors authoritatively stopped; stop failure outranks wait UI.
7. [x] Once send begins, a thrown/uncertain transport, cancellation, zero motion, approach, loss, or stale perception irrevocably consumes the attempt. Individually RUN RED/GREEN for no automatic retry after recovery/reacquisition. Preserve 0.10 m requested signal, 0.05 cap/no floor/no reverse/turn, 0.08 arrival progress, 0.12 displacement, −0.02 backward/0.02 lateral/0.10 rad drift bounds, 2.5 s / 0.01 m watchdog, five-second deadline, and 0.45 obstacle guard.
8. [x] Reuse/extend final-stop/baseline regressions: Stop during final ack cannot arrive; no baseline before final confirmed stop; require distinct fresh healthy same-track frame timestamped at/after confirmation; successful move before loss can acquire its baseline after aligned reacquisition without repeating the signal. Keep baseline fixed and departure at +0.30 m.
9. [x] Add app status/Stop tests using the view-model seam. RUN RED; provide additive defaulted access to the **configured** gate (for example, coordinator read-only gate plus view-model closure wired by `ConversationView`), then RUN GREEN. Display `Step back to at least 1.4 m — waiting to signal ready.` for 1.37; compute `ceil(gate*10)/10`, not a hardcoded default or round-to-nearest. Test a nondefault gate and an exact tenth. Stop remains available in wait/pending/signal/final confirmation, local Stop avoids Thinking, stale callbacks cannot replace a newer UI.

**App red/green command:**

```sh
xcodebuild test -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination "id=$SIM_UDID" \
  -only-testing:PhroverOperatorTests/ConversationViewModelTests
```

**Exit:** coordinator, real admission integration, ready navigation, contextual compatibility/failure-resolution, and app view-model suites pass. Add no mandatory requirements to public motion/perception protocols. Keep token clearing generation-scoped and successful/consumed readiness persistent across reacquisition.

### Task 4 execution evidence — 2026-10-02

Implemented only Task 4 from repository root, preserving uncommitted Tasks 1–3 and unrelated work. `scripts/test-swift-sdk.sh --print-udid` selected iPhone 17 Pro / iOS 26.5 (`EEA52712-371D-4FF6-B8EF-A2C78319D57F`). All test executions were bounded and serial (`-parallel-testing-enabled NO`). SDK narrow commands used `xcodebuild test -quiet -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' -parallel-testing-enabled NO -only-testing:PhroverKitTests/<class>/<method>`; app commands used the Task 4 project/scheme and `-only-testing:PhroverOperatorTests/ConversationViewModelTests/<method>` with the same destination/serial flags. Each narrow assertion RED below preceded its production change and the identical selector GREEN. `C` = `FollowMeCoordinatorTests`, `I` = `FollowReadyAdmissionIntegrationTests`, `R` = `NavigationFollowReadySignalTests`, `A` = app `ConversationViewModelTests`.

| Selector | Assertion RED → minimum change → GREEN |
| --- | --- |
| C/testTooClosePersonCannotAuthorizeReadySignalAcrossHoldClearance | Expected active clearance wait, received terminal close-person failure → active stopped wait and normal association → passed |
| I/testLatestClosePersonDuringRealReadyFeedbackDefersWithoutSending | Wait/active assertions failed after latest person approached during suspended feedback → scoped synchronous first-send admission and independent pending token → passed |
| A/testClearanceWaitExplainsStepBackAndLocalStopNeverThinks | Empty wait label instead of 1.4 m request → configured gate getter/closure, production wiring, upward-rounded status → passed |
| I/testLatestClosePersonDuringRealReadyFeedbackDefersWithoutSending (second cycle) | Attempt/pending facts nil instead of false → actual readiness flags/gate on existing state diagnostics → passed |
| A/testOldClearanceStopCompletionCannotClearNewerSubmissionGuidance | Old Stop cleared newer guidance → submission-generation fence after acknowledgement → passed |
| I/testExpiredLatestObservationAtAdmissionEntersExistingOutagePolicyWithoutSend | Stale observation rejected without publishing its outage issue → distinguish observation deferral and invoke existing outage policy → passed |
| A/testStopButtonStaysVisibleWhenMotorStopWasNotConfirmed | Stop hidden for the actual contextual failed-stop message → retain Stop for that formatter message → passed |
| R/testContextualDeferralIsNotArrivalOrFailureAndConfirmsStopAfterFeedback | Contextual outcome was navigation cancellation instead of not-started → typed `.notStarted(reason)` outcome and explicit coordinator reduction → passed |
| C/testContextualRuntimeCapturesAlignmentReadyAndDepartureRequests (phase cycle) | Request reported signaling before admission → capture actual pending launch phase → passed |
| I/testApproachAfterRealSendInitiationStopsAndNeverReturnsToResumableWait (pending cycle) | Initiated signal still reported pending admission → atomically clear reservation with attempt consumption/state transition → passed |

**10 narrow assertion RED→GREEN cycles.** The first bounded exit additionally exposed compatibility failures in C/testContextualRuntimeCapturesAlignmentReadyAndDepartureRequests and C/testCorrelatedFailureOrdersPublishPendingThenOnlyAcknowledgedStopAndRetainFailedStop: a nested default compatibility call cleared the admission TaskLocal, causing repeated ready requests and the wrong failed-stop message. Preserving the inherited scope fixed both; both exact selectors were rerun GREEN. Existing failure-resolution priority and unknown legacy controller/first-wheel facts remain intact.

Added **25 SDK methods and 3 app methods**. Preservation cases passed their first run and are not counted as RED cycles: exact 1.37 step-back and 500 ms inclusion; cached/future rejection; healthy matched waiting beyond ten seconds without motion; concurrent eligible frames; latest heading drift and required new post-alignment frame; pending loss/health with original 10 s / 2 s deadlines; Stop/new-generation fencing; obstacle/nonfinite clearance, unsafe short path, stale/future acknowledgement, invalid enriched pose; failed final stop/latch; uncertain send, zero measured motion, approach, loss and stale perception after send with no retry; configured nondefault/exact-tenth labels. Existing swept-costmap, final-ack Stop, successful reacquisition before baseline, fixed new post-stop baseline and +0.30 m departure regressions passed in the bounded exit. Fixture compile corrections, a Stop fixture waiting for confirmation before releasing suspended feedback, and premature sampling of the stalled-motion fixture are excluded from behavioral RED evidence; the corrected fixtures passed.

Final bounded SDK exit: **121 passed, 0 failed, 0 skipped**, across `FollowMeCoordinatorTests`, `FollowReadyAdmissionIntegrationTests`, `NavigationFollowReadySignalTests`, `FollowMotionFailureResolutionTests`, and `FollowDiagnosticEventTests`. Command used the SDK prefix above with those five class selectors. Result bundle: `/Users/hungmai/Library/Developer/Xcode/DerivedData/astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.02_16-56-24--0700.xcresult`.

Final bounded app exit: **12 passed, 0 failed, 0 skipped**, `ConversationViewModelTests`, using `xcodebuild test -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj -scheme PhroverOperator -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' -parallel-testing-enabled NO -only-testing:PhroverOperatorTests/ConversationViewModelTests`. Result bundle: `/Users/hungmai/Library/Developer/Xcode/DerivedData/PhroverOperator-fddpasjqbvmpvydqermesnrnjsro/Logs/Test/Test-PhroverOperator-2026.10.02_16-56-33--0700.xcresult`. Both totals were checked using `xcresulttool get test-results summary`.

Admission is inherited through the existing contextual adapter/task scope, invoked inside `driveReadySignal` after feedback/safety/operation fences immediately before first send initiation, with no intervening suspension. Legacy authorization is immediately before its actual `signalReady()` method call and keeps first-wheel telemetry unknown. Accepted attempts persist; clearance deferral clears only its matching token and cannot become arrival or failure. A failed stop outranks deferral. Requested short-move limits, generic navigation, final confirmation and baseline rules remain unchanged. Whitespace checks include tracked changes and new Task 4 files. **Task 4 complete; no unresolved Task 4 blocker.** Tasks 5–6, full SDK/app suites, unsigned build and supervised physical acceptance remain pending. No commit/push or physical-device deployment/motion performed.

## Task 5 — Full measured pipeline diagnostics and integration

**Modify:**
- `swift/Sources/PhroverKit/FollowMe/FollowPerceptionDiagnostics.swift`
- `swift/Sources/PhroverKit/FollowMe/ARFollowMePerceptionSource.swift`
- `swift/Sources/PhroverKit/FollowMe/FollowAssociationDiagnostics.swift`
- `swift/Sources/PhroverKit/FollowMe/FollowTargetTracker.swift` (correlation evidence only; unchanged decisions)
- `swift/Sources/PhroverKit/FollowMe/FollowDiagnosticEvent.swift`
- `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift`
- `swift/Tests/PhroverKitTests/FollowAssociationDiagnosticsTests.swift`
- `swift/Tests/PhroverKitTests/FollowDiagnosticEventTests.swift`
- `swift/Tests/PhroverKitTests/ARFollowMePerceptionSourceTests.swift`
- `swift/Tests/PhroverKitTests/FollowMeCoordinatorTests.swift`
- `swift/Tests/PhroverKitTests/FollowReadyAdmissionIntegrationTests.swift`

**Vertical slices:**
1. [x] Through actual `batch` and structured sink assert distinct outcomes for executed/no raw person, executed/all projections rejected, limited-tracking/skipped inference, and actual detector failure. RUN RED/GREEN individually. Inspect the detector's result/error contract when wiring execution status; never relabel failure as successful empty inference. Skipped/failure counts are unknown/not evaluated, not invented zeros; older batch providers remain explicitly unknown.
2. [x] Assert raw detector/person → projection attempted/accepted/rejected → projected → tracker eligible/matched/selected counts reconcile, with raw IDs surviving projection filtering into tracker evidence. RUN RED/GREEN. Preserve initial-selection matched-count “not applicable” semantics and separate upstream projection reasons from tracker reasons. Correlate a real >0.75 m rejection with its accepted projection facts.
3. [x] Assert clipping/confidence/dispersion reasons and all measured candidate facts from Task 3 appear in the emitted immutable envelope for that exact frame, including rejected candidates. RUN RED/GREEN. Join with `follow_person.association` and healthy summaries, never re-run projection/gates or retain images/history for logging.
4. [x] Assert clearance entry/exit, admission deferred/authorized, cancellation/completion carry exact gate, latest frame/age, heading/range, pending/attempted/succeeded, stop state and reason. RUN RED/GREEN. Differentiate too-close-before-send from approach-during-signal. Emit transitions/failures/stop/pulse lifecycle immediately, but repeated healthy pipeline/association/wait summaries share **one record per second per session**. Include rejection-reason changes in transition detection so an unchanged “lost” outcome cannot hide a new upstream reason.
5. [x] Integrate synthetic raw depth/detections → batch → real tracker/coordinator → real navigation adapter → captured wheel/stop output: close acquisition stays stopped; gradual step-back admits one signal; final confirmed stop plus new frame creates baseline; departure triggers existing follow. Add fresh versus independently sampled controller provenance and a suspended-feedback deferral variant. RUN RED/GREEN per scenario; no private-state inspection required.
6. [x] Verify bounded fields exclude images, depth arrays, audio/transcripts, biometric identity, arbitrary response bodies, URLs/request payloads. Keep stream/source sequence, generation/operation correlation, UTC/monotonic labels, signed six-decimal angles/full values, host stage durations, actual watchdog checkpoint, and stream/result failure deduplication. Use existing emitter/reducer, no second logging architecture or new awaits.

**Exit:** diagnostic classes, perception, coordinator, admission integration, `FollowMotionFailureResolutionTests`, and `NavigationFollowScanDiagnosticsTests` pass. The logs explain an empty projection list without claiming that spatial continuity is identity recognition.

### Task 5 execution evidence — 2026-10-02

Implemented only Task 5, preserving the existing Tasks 1–4 and unrelated work. Script-selected simulator: iPhone 17 Pro / iOS 26.5 (`EEA52712-371D-4FF6-B8EF-A2C78319D57F`). All executions were from repository root, serial and bounded. Each cycle used `xcodebuild test -quiet -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' -parallel-testing-enabled NO -only-testing:PhroverKitTests/<class>/<method>` for its assertion RED before production patch and identical selector GREEN afterward. `P` = new `FollowPipelineDiagnosticsTests`; `I` = `FollowReadyAdmissionIntegrationTests`; `S` = `ARFollowMePerceptionSourceTests`; `C` = `FollowMeCoordinatorTests`.

| Selector | Observed assertion RED → change → GREEN |
| --- | --- |
| S/testStreamMeasuresInferenceAndSkipsItForLimitedTracking | Live success was unknown/raw nil and skipped duration zero → additive detector evaluation receipt through existing handler/Vision execution, measured success count and unmeasured skip duration → passed |
| P/testMeasuredEmptyInferenceDiffersFromRejectedProjectionInEnvelope | Upstream counts/candidate facts missing or stripped → serialize actual frame-local projection evidence on existing envelope → passed |
| P/testActualThrowingDetectorFailureAndTrackingSkipKeepCountsUnknown | Failed empty frame claimed same-frame pairing → prohibit vacuous pairing on failed/skipped inference → passed |
| P/testRawIDsSurviveFilteringAndWorldJumpKeepsProjectionAndTrackerReasonsSeparate | Selected count/raw ID missing and projected index replaced raw ID → stable raw correlation and selected count → passed |
| P/testUnchangedLostOutcomeEmitsChangedProjectionReasonButDeduplicatesRepeats | Only first lost/clipping record emitted → include actual upstream/tracker rejection signatures in existing budget → passed |
| I/testAdmissionDiagnosticsCapturePendingDeferredAndAuthorizedAtActualSendBoundary | Pending lifecycle record absent → captured pending/deferred/authorized/completed readiness records and authoritative stop facts → passed |
| I/testSyntheticPipelineCloseWaitStepBackOneSignalNewBaselineAndDeparture | Clearance entry record absent → immediate entry/exit and combined wait facts → passed |
| I/testSyntheticPipelineSuspendedFeedbackDeferralThenLocalCancellationIsTruthful | Cancellation record absent → immediate bounded local cancellation facts → passed |
| I/testAdmissionDiagnosticsCapturePendingDeferredAndAuthorizedAtActualSendBoundary (boundary cycle) | Controller boundary/telemetry fields missing → captured actual controller versus legacy call boundary → passed |
| P/testHealthSummaryKeepsUnevaluatedTrackerAndLegacyPipelineCountsUnknown | Health counts absent rather than explicitly unknown → measured projected input, null unevaluated tracker counts and legacy availability → passed |
| P/testActualThrowingDetectorFailureAndTrackingSkipKeepCountsUnknown (projected-count cycle) | Failed/skipped projected count zero → null not-evaluated projection count, separate actual tracker input count → passed |
| I/testAdmissionUsesExactPostFeedbackControllerSampleAndLabelsFramePairing | Actual controller sample fields missing → pass exact validated post-feedback sample/uptime into synchronous admission; same-frame/independent/unknown comparison → passed |
| I/testRepeatedHealthyWaitUsesOneCombinedSummaryBudgetAndRetainsTrackerCounts | Wait merge erased tracker counts with nulls → preserve authoritative evaluated association fields in combined summary → passed |
| I/testApproachAfterRealSendInitiationStopsAndNeverReturnsToResumableWait | Authoritative cancellation stop response missing → one bounded readiness-stop response after confirmation → passed |
| C/testDiagnosticsAreThrottledAndReportUnavailableReasonChangesAndRecovery | Frame timings were `[0, 0.3, 1.3]`, hiding changed tracking reason and repeating unhealthy status → immediate reason transitions, deduplicated identical unhealthy frames → passed with `[0, 0.2, 0.3]` |
| I/testAdmissionDiagnosticsCapturePendingDeferredAndAuthorizedAtActualSendBoundary (deferral telemetry cycle) | Deferred controller boundary implied send telemetry → unknown first-wheel telemetry for non-started attempt → passed |

**16 assertion RED→GREEN cycles; 12 net-new test methods.** Additional preservation assertions passed in the bounded exit: emitted low-confidence and MAD/inlier facts from the actual 25-sample window; legacy callback/source telemetry unknown; nested privacy exclusions; original projection geometry, all sample/confidence/calibration boundaries, stable corruption versus world jump; controller host timings/source clocks/signed precision/watchdog provenance; failure stream/result deduplication and stop precedence. The synthetic departure fixture initially ran unconstrained pursuit to its communications timeout after successful departure; suspending its departure transport made the intended public-state observation deterministic. That fixture correction is not counted as a behavioral RED cycle. The first bounded exit exposed an obsolete aggregate frame-count assertion; its replacement checks the exact newly required immediate reason-transition times and identical-unhealthy deduplication through a separate RED→GREEN cycle above.

Final bounded exit: **229 passed, 0 failed, 0 skipped**, checked with `xcresulttool get test-results summary`. Exact class selectors: `FollowPipelineDiagnosticsTests`, `FollowAssociationDiagnosticsTests`, `FollowDiagnosticEventTests`, `ARFollowMePerceptionSourceTests`, `FollowMeCoordinatorTests`, `FollowReadyAdmissionIntegrationTests`, `FollowMotionFailureResolutionTests`, `NavigationFollowScanDiagnosticsTests`, `NavigationFollowReadySignalTests`, `FollowPersonProjectionTests`, and `DetectorTests`, all under `PhroverKitTests`, using the SDK command prefix above. Result bundle: `/Users/hungmai/Library/Developer/Xcode/DerivedData/astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.02_17-21-36--0700.xcresult`.

Implementation uses the existing emitter, tracker evaluation and session budget. Focused `FollowReadinessDiagnostics` formats immutable admission/wait facts; detector receipt preserves both public `detect` defaults and uses the existing handler, with bounded failure codes rather than error descriptions. No projection/gate reruns, additional awaits, image/depth history, or motion-policy changes. Whitespace checks cover tracked changes and modified/new untracked implementation/tests. **Task 5 complete; no unresolved Task 5 blocker.** Task 6 review/full SDK/app suites/unsigned build and separately authorized device acceptance remain pending. No commit/push, full-suite execution, build or device motion performed.

## Task 6 — Review, full SDK/app tests, unsigned build

### Reviewed-defect checkpoint — 2026-10-02

Scope: the two high-priority first-send/perception defects and the medium-priority pre-send false-arrival defect supplied in the review request. Read the approved specification and implementation source. Preserve existing uncommitted Tasks 1–5 and unrelated work; full SDK/app suites, unsigned build, and device execution await review confirmation.

Approved seams: public coordinator actions/state/events with the real navigation adapter and suspended acknowledgement; live AR perception stream with synthetic color/depth buffers; detector's actual orientation-selection loop with an injected Vision execution handler; contextual ready result and confirmed-stop output. No private controller calls.

Each behavioral fix followed a **compiled assertion RED run before its behavior patch**, then the same selector GREEN. Commands ran from repository root on the script-selected iPhone 17 Pro / iOS 26.5 (`EEA52712-371D-4FF6-B8EF-A2C78319D57F`), using `xcodebuild test -quiet -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' -parallel-testing-enabled NO -only-testing:PhroverKitTests/<class>/<method>`. Some GREEN runs included additional narrow preservation selectors. Assertion messages were inspected with `xcresulttool`; build/fixture errors are not RED evidence.

| Selector | Observed assertion RED → minimum behavior change → GREEN |
| --- | --- |
| FollowReadyAdmissionIntegrationTests/testControllerOnlyForwardCorrectionDefersClearanceWithoutConsumingAttempt | One command and `signalingReady` instead of zero commands and clearance deferral after controller-only +0.05 m correction against unchanged 1.4 m observation → pass controller sample/read uptime into admission, validate same actual AR generation and current health/age/ownership, compute heading/range against latest locked world position; retain explicit legacy unknown path → passed |
| NavigationFollowReadySignalTests/testPreSendPoseCorrectionCannotCompleteReadySignalOrConsumeAdmission | Contextual `.arrived` at all three pre-send corrections, 0.08/0.10/0.12 m → arrival requires prior send; apparent completion before send returns existing `.failed(.stalled)` after safety checks and confirmed stop, with no admission/consumption → passed |
| ARFollowMePerceptionSourceTests/testLiveFollowDoesNotProjectAsymmetricFallbackBoxUsingRightInverse | Live stream tried `.right,.up`, projected an up-oriented asymmetric box as a valid right-inverse world observation, and claimed one raw/projection input → additive `evaluateForFollow` performs right-only evaluation; live follow uses it; generic APIs retain fallback → passed |
| FollowReadyAdmissionIntegrationTests/testControllerOnlyForwardCorrectionDefersClearanceWithoutConsumingAttempt (diagnostic cycle) | Deferred range logged old 1.4 m instead of actual 1.35 m → readiness formatting uses captured controller pose plus locked world position, labels controller geometry and same/independent/unknown source pairing → passed |

**Four assertion RED→GREEN cycles; seven new regression methods.** The additive orientation-aware Vision handler seam was wired into the existing production selection loop before its assertion RED; that scaffolding preserved the defective fallback behavior, demonstrated by the RED's actual wrong world observation. It is not claimed as a behavior fix or RED cycle. The tests exercise real selection, not merely orientation arrays. Their 100×80 color / 20×16 depth fixture has different coherent surfaces at up/right feet coordinates, and demonstrates that the generic fallback box would otherwise project to X=1.2/Z=−3.

Additional preservation checks passed: controller-only +0.06 rad yaw against unchanged batch defers heading, remains in stop-bracketed alignment, and leaves attempt/token false; controller AR generation differing from the observation cannot authorize its world position; pre-send apparent completion fails the coordinator explicitly, clears its matching pending token, leaves attempt false, and cannot silently reattempt on a later frame; detector receipts retain actual right/up orientation, successful-empty versus error status, and generic fallback after empty/error. One initial yaw-test assertion incorrectly required a wheel turn before a new matched frame despite unchanged batch heading; removing that fixture expectation preserved the required alignment/new-frame boundary. It is not counted as a behavioral RED cycle.

Final affected-class checkpoint: **176 passed, 0 failed, 0 skipped**, verified with `xcresulttool get test-results summary`. Exact selectors: `FollowReadyAdmissionIntegrationTests`, `FollowMeCoordinatorTests`, `NavigationFollowReadySignalTests`, `ARFollowMePerceptionSourceTests`, `DetectorTests`, `FollowPersonProjectionTests`, `FollowPipelineDiagnosticsTests`, `FollowMotionFailureResolutionTests`, and `FollowDiagnosticEventTests`, all under `PhroverKitTests`, using the command prefix above. Result bundle: `/Users/hungmai/Library/Developer/Xcode/DerivedData/astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.02_17-33-16--0700.xcresult`.

The specific three reviewed defects are resolved at this checkpoint. Limits/gates, generic detection fallback, failed-stop precedence, post-send attempt consumption and baseline rules remain covered by the affected suites. Task 6 is not complete: broader review confirmation, full deterministic SDK/app suites, unsigned build and separately authorized supervised device acceptance remain outstanding. No commit/push or device motion performed.

1. [x] Review implementation against spec §§3–9 and the approved seams. Inspect diff for unintended generic navigation changes, public-protocol breakage, obsolete expectation updates, clock mixing, extra awaits, token lifetime bugs, fake arrival on deferral, accidental attempt reset, and stop-failure masking. Keep projection/evidence/admission logic in focused units; controller owns authorization/send/stop, coordinator owns session/track decisions. Any review fix with observable impact gets its own red/green regression before the final checks.
2. [x] Run full deterministic SDK coverage from root using the existing simulator selector script:

   ```sh
   SIM_UDID="$SIM_UDID" scripts/test-swift-sdk.sh
   ```

   This runs `RoverNavTests` and `PhroverKitTests`; live probes/Godot tests require different dependencies and are not this gate. Report actual failures/results, not a prior revision's evidence.
3. [x] Run full app unit coverage:

   ```sh
   xcodebuild test -project examples/PhroverOperator/PhroverOperator.xcodeproj \
     -scheme PhroverOperator -destination "id=$SIM_UDID" \
     -only-testing:PhroverOperatorTests
   ```

4. [x] Complete the established unsigned iOS app build:

   ```sh
   xcodebuild build -project examples/PhroverOperator/PhroverOperator.xcodeproj \
     -scheme PhroverOperator -configuration Debug \
     -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
   ```

5. [x] Check whitespace (`git diff --check`, plus new-file checks where needed), inspect status and intended diff, and summarize exact verification evidence and unresolved blockers. Preserve existing `.superpowers` assets and unrelated work. Do not commit or start supervised device acceptance unless separately instructed.

### Task 6 final verification evidence — 2026-10-02

Review prerequisite: the user independently confirmed Tasks 1–5 and all three reviewed fixes with no remaining issues. Final verification inspected the intended diff/status and ran against the latest working tree after those fixes. No production or test changes were needed in this verification session; only this plan was updated.

All commands ran serially from `/Users/hungmai/Sites/Astral/astral-sdk`, with a 1,200,000 ms tool timeout per test/build command. The selector script chose iPhone 17 Pro / iOS 26.5, `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Test commands used `-parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`. Xcode's default single iteration/no retries was retained; neither retry nor repetition switches were enabled.

| Latest-code gate | Passed | Failed | Skipped | Evidence bundle/log basename |
| --- | ---: | ---: | ---: | --- |
| All 16 affected/preservation SDK classes below | 278 | 0 | 0 | `acquisition-task6-affected-valid-20261002.xcresult` |
| Full root SDK script: PhroverKitTests + RoverNavTests | 591 (572 + 19) | 0 | 0 | `acquisition-task6-sdk-valid-20261002.xcresult` |
| All PhroverOperatorTests | 32 | 0 | 0 | `acquisition-task6-app-20261002.xcresult` |
| Debug unsigned generic/platform=iOS build | passed | — | — | `acquisition-task6-build-20261002.log` |

All bundles and corresponding `.log` files are under the exact directory `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/`. Counts and Passed status were read from `xcrun xcresulttool get test-results summary --path <bundle>`; full SDK target counts and calibration results were checked with `get test-results tests`. **901 successful test executions; 623 distinct full-suite tests** (the 278 affected tests are included in the full SDK total), zero failures/skips/expected failures. The previously flaky calibration coverage passed without retry, including all 18 `ARSharedMissionFrameCalibratorTests` and all 58 `SilentSearchCoordinatorTests`.

Exact affected selectors are `-only-testing:PhroverKitTests/<class>` for each row:

| Class | Passed | Coverage/file map |
| --- | ---: | --- |
| NavigationFollowScanDiagnosticsTests | 54 | RoverConfig, NavigationController, RotationDiagnosticModels, FollowScanDiagnosticTrace, new NavigationPoseSample |
| NavigationRotationWatchdogTests | 12 | Follow pulses, progress watchdog, confirmed-stop preservation |
| NavigationSilentSearchMotionTests | 6 | Generic motion isolation |
| NavigationFollowReadySignalTests | 17 | Enriched post-feedback pose, ready safety, first-send and false-arrival fixes |
| RoverControlTests | 12 | Existing firmware navigation mapping |
| ARSessionManagerTests | 5 | Atomic snapshot/generation and selected depth-confidence transport |
| FollowDiagnosticEventTests | 8 | Envelope, correlation, failure/stop precedence |
| FollowPersonProjectionTests | 26 | New FollowPersonProjection and FollowPerceptionDiagnostics; full-window geometry, confidence, calibration |
| ARFollowMePerceptionSourceTests | 6 | Batch/stream evidence and right-only live follow inference fix |
| FollowTargetTrackerTests | 7 | Corruption continuity and unchanged association gates |
| FollowMeCoordinatorTests | 78 | Active wait, pending/consumed readiness, baseline/deadlines, compatibility |
| FollowReadyAdmissionIntegrationTests | 25 | New FollowReadyAdmission; real-adapter admission, controller geometry, synthetic pipeline |
| FollowMotionFailureResolutionTests | 3 | Typed outcomes and failed-stop precedence |
| FollowPipelineDiagnosticsTests | 7 | New FollowReadinessDiagnostics; measured perception/association/readiness evidence |
| FollowAssociationDiagnosticsTests | 6 | Association fields, raw correlation, shared summary budget |
| DetectorTests | 6 | Evaluation receipts, actual orientation loop, generic fallback preservation |

Remaining affected files: `FollowMeDependencies.swift`, `FollowMeModels.swift`, and `FollowDiagnosticEvent.swift` carry additive contextual/evidence fields; the app's `ConversationViewModel.swift`, `ConversationView.swift`, and `ConversationViewModelTests.swift` cover configured step-back guidance and local Stop. Each SDK class above maps to `swift/Tests/PhroverKitTests/<class>.swift`; new focused units reside under `swift/Sources/PhroverKit/FollowMe/`, except `Nav/NavigationPoseSample.swift`.

Reproducible commands (affected invocation used the 16 explicit selectors listed above):

```sh
SIM_UDID=$(scripts/test-swift-sdk.sh --print-udid)
EVIDENCE=/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode
# Common flags below were passed explicitly to each test command.
xcodebuild test -quiet -scheme astral-sdk-Package -destination "id=$SIM_UDID" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath "$EVIDENCE/acquisition-task6-affected-valid-20261002.xcresult" \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationSilentSearchMotionTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/RoverControlTests \
  -only-testing:PhroverKitTests/ARSessionManagerTests \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/FollowPersonProjectionTests \
  -only-testing:PhroverKitTests/ARFollowMePerceptionSourceTests \
  -only-testing:PhroverKitTests/FollowTargetTrackerTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/FollowPipelineDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowAssociationDiagnosticsTests \
  -only-testing:PhroverKitTests/DetectorTests
SIM_UDID="$SIM_UDID" scripts/test-swift-sdk.sh -quiet \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath "$EVIDENCE/acquisition-task6-sdk-valid-20261002.xcresult"
xcodebuild test -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination "id=$SIM_UDID" -only-testing:PhroverOperatorTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath "$EVIDENCE/acquisition-task6-app-20261002.xcresult"
xcodebuild build -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
```

Actual warnings: affected/full SDK logs contain no `warning:` compiler diagnostics. App tests emitted one `UIScreen.main` iOS 26 deprecation at `examples/PhroverOperator/PhroverOperator/Views/ConversationView.swift:270:58`; unsigned build emitted the same deprecation plus `A launch configuration or launch storyboard or xib must be provided unless the app requires full screen.` Thus **three compiler/build warning occurrences, two distinct warnings**. Both SDK runs also emitted one Xcode `[MT] IDERunDestination: Supported platforms for the buildables in the current scheme is empty.` diagnostic (two occurrences); they still selected the correct simulator and passed. Build notes about removing stale signing artifacts are notes, not warnings.

Invocation accounting: the first affected and full-SDK invocations incorrectly supplied `-test-iterations 1`; Xcode rejected both before tests with `Must specify -test-iterations with more than 1 iteration.` Their original `acquisition-task6-affected-20261002` / `acquisition-task6-sdk-20261002` logs/bundles are retained and are not counted as test passes or failures. Corrected `-valid-` commands removed repetition/retry switches and passed on their first actual test execution. No assertion failures were hidden or retried.

Whitespace/status: `git diff --check` passed. Explicit `git diff --no-index --check /dev/null <file>` checks for all eight new SDK source/test files and this untracked plan emitted no whitespace diagnostics (normal no-index difference status 1). Intended tracked/new files and final status were inspected. Existing `.serena/project.yml`, `.opencode/`, and `AGENTS.md` work and `.superpowers` assets were preserved. No install, commit, push, device deployment, or physical motion was performed. **Task 6 complete with no software verification blocker; physical breakaway/braking/projection/pulse acceptance remains unverified.**

### Completion evidence and critical risks

Completion requires all six task exits, full SDK/app test results, and unsigned build result. No implementation/test/build/device execution occurred while writing this plan.

The high-risk review points are **post-await source freshness**, **actual-loop first-send admission**, **typed deferral versus arrival**, **pending versus consumed attempt**, **same-selected-depth confidence pairing**, **full-window/stride geometry**, **fixed post-confirmation baseline**, and **failed-stop precedence**. Simulator tests validate software behavior, not breakaway speed, braking overshoot, mounted-phone projection accuracy, or physical pulse effectiveness; those remain the specification's separately authorized supervised acceptance items.
