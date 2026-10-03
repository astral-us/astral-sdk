# Follow-Me Last-Bearing Reacquisition — Implementation Plan

**Date:** 2026-10-02

**Approved spec:** [Last-bearing reacquisition design](../specs/2026-10-02-follow-me-last-bearing-reacquisition-design.md), user-confirmed and committed in `0025527`.

**Inspected implementation HEAD:** `0025527` (the spec's source evidence remains its historical `a3c0367` snapshot).
**Status:** Tasks 1–6 and the three additional user-supplied review findings are implemented at unchanged base HEAD `0025527`, on `feat/follow-me`. Latest 2026-10-03 evidence: **236 focused / 663 SDK / 33 app tests passed**, all with **0 failed / 0 skipped / 0 expected failures**, and unsigned generic-iOS Debug build succeeded. The prior independent-review approval and 350 affected / 661 SDK results are historical; this correction session does not claim a new independent review. Actual deadline assertion RED → GREEN and maintenance evidence are recorded in the final section. This plan and implementation stay uncommitted; physical acceptance and ready-motion effectiveness remain unverified.

## Contract and current seams

Follow `CONTEXT.md` and the approved spec, including its acquisition, latest-admission, and stationary-departure references. Deliver six focused vertical slices, each with a compiled behavioral RED, the minimum implementation, and the same selector GREEN. A build/scaffolding error is not RED evidence. Preserve `.superpowers` assets and unrelated work.

Paths below are relative to `/Users/hungmai/Sites/Astral/astral-sdk`:

| Seam | Current finding / implementation responsibility |
| --- | --- |
| `swift/Sources/PhroverKit/FollowMe/FollowMeModels.swift` | `FollowPersonObservation` already carries paired position/pose/frame/timestamp and optional frame-local raw ID. Add immutable reliable-memory/episode value types; unavailable provenance stays explicit. |
| `FollowMe/FollowMeCoordinator.swift`: `receive`, `signalReady` | Initial/continuity and accepted pending admission update `locked`/`lastPosition`. Reacquired observations currently overwrite them and clear the deadline immediately. Separate provisional lock from frozen reliable anchor; preserve saved pending-association handoff. |
| Coordinator: `loseTarget`, `scan`, `align`, `confirmStop`, `perceptionUnavailable` | Loss deadline starts before stop, but its timer currently checks only `.reacquiring`; scan completion starts another positive increment. Replace only recovery progression; preserve initial search and serialized stop/operation/alignment fences. |
| `FollowMe/FollowTargetTracker.swift`, `FollowAdmissionSnapshot.swift` | Continuity has generation/frame gates; reacquisition lacks expected-generation/batch-frame input. Add internal validated recovery evaluation against the frozen 1.5 m anchor, with typed rejection evidence. Preserve public tracker compatibility. |
| `FollowMe/FollowMeDependencies.swift`, `NavigationFollowMeMotion.swift` | Public motion is relative-only; an optional internal contextual companion already exists. Add a narrow optional absolute-heading companion/request without adding requirements to old conformers or bypassing contextual failure reduction. |
| `Nav/NavigationController.swift`: `rotateForFollowScan`, `readFollowPose`, `performRotate` | Relative scan confirms stop then adds the supplied angle to a new yaw. Resolve recovery segments at the controller's real post-stop source boundary; retain existing controller owner, `.followScan` pulse loop, trace, watchdog, and sticky stop latch. |

`FollowMe/` and `Nav/` in the table mean directories under `swift/Sources/PhroverKit/`. New suggested files: `FollowMe/FollowReacquisitionPlanner.swift`, `FollowMe/FollowReacquisitionEpisode.swift`, and `swift/Tests/PhroverKitTests/FollowReacquisitionPlannerTests.swift`. Keep the pure planner public for direct contract tests; keep production motion machinery internal.

### Fixed semantics

- Freeze reliable observation at first loss, synchronously before suspension. Create one episode ID and `firstLoss + 10 s` deadline; stop latency consumes that budget. Repeated loss, provisional recovery, alignment, readiness, and outage chatter retain anchor, center, cursor, and deadline.
- Reliable memory accepts only healthy normal initial selection/unique continuity, including accepted latest-pending continuity with its original association decision. During recovery, commit memory only at actual gated normal-phase restoration. Reacquired-only data may update provisional `locked`, never the anchor or reliable memory.
- Select center once from a fresh same-generation post-stop current position toward the remembered world point. If that direction is unavailable/zero/nonfinite, only a valid paired historical yaw/bearing heading may substitute. Otherwise stay stopped. Wrap radians to `[-π, π)`; exactly π chooses −π.
- Targets are fixed center offsets `[0, +15, −15, +30, −30, +45, −45]` degrees, one pass. At each controller post-stop boundary recompute error from actual yaw, request at most 30° signed, and preserve that segment's absolute target through the pulse loop. Advance only on measured authoritative arrival/inclusive 7° tolerance. Retain unfinished stage on interruption; exhaustion stays stationary without recentering.
- Historical memory is an orientation hint within this episode, never fresh-person authority or a forward goal. Fresh source age must be finite/nonfuture and `0…0.500 s`, with normal tracking, finite pose, expected generation, current perception health, and valid ownership. No full-turn fallback or failed-motion retry.
- Preserve `.followScan` 0.25 m/s, requested 200 ms pulse wait, acknowledged stop, 300 ms settle, 7° tolerance, and 2.5 s / 0.05 rad measured-progress watchdog; preserve opposite-sign corrections. Requested ≤30° segments are not physical rotation guarantees.
- Episode clearing requires confirmed scan stop plus a distinct healthy fresh **normal-continuity matched frame after that stop**, and actual establishment/resumption of `waitingForClearance`, `waitingForMovement`, `following`, or `holdingDistance` under existing gates. Before departure retain recovery alignment, confirmed final stop, new post-stop matched frame, and inclusive 0.05 rad gate. Entering alignment or starting ready does not clear it.
- Incomplete alignment/ready/baseline recovery remains deadline-bound. Too-close matched recovery may establish stopped `waitingForClearance` after alignment validation. Successful ready/baseline survive; existing baseline never rebases; consumed partial/failed/cancelled ready never retries. A truly restored normal phase followed by loss intentionally starts a new episode.

## Implementation tasks

- [x] **1. Pure heading planner and immutable episode/memory contract**
  - RED: add public planner contract tests for cardinal/oblique bearings using actual current position, wrap around ±π/exact π, heading fallback provenance, invalid/zero direction, generation mismatch, inclusive 7°, the exact seven offsets, ≤30° segments, and finite exhaustion. Test +30°/−30° as center offsets rather than accumulated deltas; simulate actual yaw/overshoot rather than subtracting requests.
  - RUN: `sdk_test PhroverKitTests/FollowReacquisitionPlannerTests` using the command setup below; capture compiled failing assertions.
  - GREEN: implement pure center/next-segment decisions and immutable paired reliable-memory/episode records with identity, first-loss/deadline, frozen anchor, once-selected center, stable stage/segment cursor, and unavailable reasons. Planner has no clock sleeps, motor calls, or perception authority; stage progression uses actual arrival evidence. Re-run the same selector.

- [x] **2. Controller-owned absolute-heading recovery segment**
  - RED: extend `NavigationFollowScanDiagnosticsTests` with the real controller/adapter and explicit synthetic source provenance. Suspend initial stop and feedback, change actual pose before each resumes, and prove the fixed absolute stage target yields a newly resolved ≤30° segment from the actual post-stop yaw. Freeze source timestamp while reads continue; test future/nonfinite source, wrong generation, expiry/ownership change during feedback, and inclusive tolerance without a nonzero send. Exercise public old relative callers unchanged and legacy conformers issuing no recovery turn when the required facts are absent.
  - RUN: `sdk_test PhroverKitTests/NavigationFollowScanDiagnosticsTests`.
  - GREEN: introduce an optional internal absolute-heading request/companion carrying stage heading, expected AR generation, episode ID/deadline, and continuation callback/context. Reuse controller stop/pulse execution and typed contextual failures; do not route recovery through old-delta-plus-new-yaw. Validate after awaits and immediately before every nonzero send with no logging await in between. Carry episode authorization into recovery alignment and incomplete ready motion too; preserve ordinary relative semantics when there is no recovery context. Legacy conversion is allowed only with real fresh post-stop provenance and a preserved/revalidated absolute-target boundary; otherwise return unavailable/stay stopped. Re-run the selector and `NavigationRotationWatchdogTests`.

- [x] **3. Adopt reliable matched memory and wire first-loss return**
  - RED: coordinator/admission integration tests show latest initial/continued match and accepted pending continuity atomically retain the observation's paired geometry/provenance. Include the saved original association handoff so processing cannot reassociate against the newly adopted lock. Reject raw/clipped/low-confidence/world-jump/ambiguous/stale/future/unhealthy or mismatched-frame data without erasing memory. Provisional reacquisition near the 1.5 m frozen anchor must not overwrite it; reject another generation and candidate/batch mismatch before accepting tracker output.
  - RUN: `sdk_test PhroverKitTests/FollowMeCoordinatorTests PhroverKitTests/FollowReadyAdmissionIntegrationTests PhroverKitTests/FollowTargetTrackerTests`.
  - GREEN: wire immutable memory adoption through normal selection/continuity and accepted pending snapshot, with recovery writes gated by task 5's restoration boundary. Synchronously inhibit/cancel active pursuit/alignment/readiness on first loss, freeze episode before any await, confirm stop, initialize center once from a real fresh source, and request the first absolute segment through task 2. If provenance/center is unavailable, observe stationary. Keep provisional lock separate and never call initial selection for recovery. Re-run the selectors.

- [x] **4. Finite cursor, shared deadline, and lifecycle fences**
  - RED: manual-clock public coordinator + real-boundary tests cover multi-segment center return, all offsets, measured arrival, overshoot, interruption/reentry at unfinished stage, no recenter on chatter, stationary exhausted pass, and no remembered forward goal. Stop latency and every return/pulse/settle consume the original 10 s. Test expiry during stop/feedback/send wait/settle/arc, a frame exactly at expiry, and a watchdog failure that remains terminal. Race old completion/timeout/stop success against new session/operation/episode/AR generation; old work cannot delete newer tasks or advance cursors.
  - RUN: `sdk_test PhroverKitTests/FollowMeCoordinatorTests PhroverKitTests/NavigationFollowScanDiagnosticsTests PhroverKitTests/FollowMotionFailureResolutionTests`.
  - GREEN: replace only reacquisition's endless positive scan branch with one-pass episode progression. Timer ownership is episode-based across all incomplete recovery phases, not state equality with `.reacquiring`; enforce `now >= deadline` synchronously in frame/authorization/result boundaries as well. Fence before awaits on Stop, cancellation, leave-Talk/background, reset/interruption, safety failure, and owner replacement. Keep concurrent two-second continuous-outage policy and ten-second episode budget independent. Sticky failed-stop inhibition and specific failure priority win over late success/person-lost cleanup. Re-run selectors.

- [x] **5. Credible restoration, alignment, and once-only readiness**
  - RED: detection synchronously fences the active segment and drains stop before provisional recovery. Require a new distinct healthy normal-continuity frame after scan stop; neither the provisional frame nor consumed pre-stop admission frame qualifies. Reacquired → aligning → lost retains anchor/center/cursor/deadline. Test expiry in recovery alignment and ready completion/baseline wait, 0.05 rad inclusive gate, too-close clearance phase, ready-attempt-not-yet-used, consumed unsuccessful attempt, succeeded-but-baseline-pending, retained fixed baseline, and post-departure following/holding. Test atomic clearing once at actual normal-phase restoration, then a new genuine loss gets a new episode.
  - RUN: `sdk_test PhroverKitTests/FollowMeCoordinatorTests PhroverKitTests/FollowReadyAdmissionIntegrationTests PhroverKitTests/NavigationFollowReadySignalTests`.
  - GREEN: add explicit scan-stop frame/time evidence and one gated restoration transaction with no await between final validation, deadline/timer clear, and reliable-memory commit. Revalidate newest ingested health/association after feedback/stop awaits while preserving pending coalescing/handoff. Alignment/ready authorization and completion callbacks retain episode fences/deadline until the actual normal phase is established; baseline keeps existing final-stop/new-frame rules. Preserve attempted/succeeded flags and baseline across loss. Ready progress failure from the cited log is separate: do not fix, suppress, or retry it here. Re-run selectors, including initial pause/search, 360° requested-budget shortened-final-increment, ordinary following, no reverse, and local Stop preservation cases.

- [x] **6. Full diagnostics, independent review, and final software evidence**
   - [x] **Diagnostics-only slice:** compiled assertion RED before each behavior's production change; corrected scoped GREEN **241 / 0 / 0**, detailed below.
    - [x] **Supplied independent-review findings corrected:** high pending-reacquisition fencing and medium processed-frame reassociation; compiled assertion RED → GREEN and related-class gate recorded below.
     - [x] **Independent implementation review approval:** user reports independent follow-up resolution of both findings and no further issues; attribution and final verification below.
   - [x] **Post-review affected exit, full SDK/app tests and unsigned build:** all passed on the corrected latest source; exact counts, commands, bundles and warnings below.
  - RED: extend `FollowDiagnosticEventTests`, `FollowAssociationDiagnosticsTests`, `FollowPipelineDiagnosticsTests`, and `NavigationFollowScanDiagnosticsTests` to assert actual frozen/source/center/stage/deadline decisions and truthful unavailable fields. Include rejection, exhaustion, cursor retention, restoration, expiry, failed stop, and throttling; distinguish requested targets/deltas, measured AR yaw, and host durations.
  - RUN: `sdk_test PhroverKitTests/FollowDiagnosticEventTests PhroverKitTests/FollowAssociationDiagnosticsTests PhroverKitTests/FollowPipelineDiagnosticsTests PhroverKitTests/NavigationFollowScanDiagnosticsTests`.
  - GREEN: extend the existing immutable structured stream and controller/transport correlation. Include episode ID/first-loss/elapsed/deadline/remaining/reason/phase/stop; memory source, observation/raw frame-local ID, frame/generation/timestamp/age/paired pose/world point/bearing/heading/validity; center source/sample/yaw/return; stage offset/index/segment/absolute targets/recomputed delta/pre-post yaw/error/completion; genuine controller source IDs/AR times/read age/health/generation/pairing; upstream clipping/confidence/association gates, watchdog/failure/fence reasons. Keep shared healthy-summary budget, immediate transitions/failures, bounded payloads, and no authorization-await introduced by logging. No images/depth/audio/transcripts/biometrics or fabricated AR/source facts.
  - Obtain independent implementation review against spec §§3–8, focused on source-boundary targeting, pending adoption, expiry before each send, restoration, cursor reentry, and old-callback/failed-stop races. Fix findings and add meaningful regression cases. Then run the affected exit, full SDK, all app unit tests, and unsigned build below on the final corrected tree. Record actual commands, RED/GREEN assertions, result paths/counts/status, review disposition, and remaining risks in implementation evidence. Do not reuse pre-fix final evidence or copy historical counts as new assertions.

## Command runbook

All commands run from repository root `/Users/hungmai/Sites/Astral/astral-sdk`, **not** `examples/PhroverOperator` or `swift`. Use Bash for the array helper below. Verify temporary parent exists first; select one available iOS 26+ iPhone simulator with the repository script and reuse its UDID throughout. Use unique result paths per invocation. Actual implementation checkpoints and final Task 6 invocations are recorded below.

```bash
pwd
ls '/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode'
SIM_UDID="$(scripts/test-swift-sdk.sh --print-udid)"
export SIM_UDID
EVIDENCE='/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode'
TEST_FLAGS=(-parallel-testing-enabled NO -test-timeouts-enabled YES
  -default-test-execution-time-allowance 60
  -maximum-test-execution-time-allowance 60)
sdk_test() {
  local selectors=() selector
  for selector in "$@"; do selectors+=("-only-testing:$selector"); done
  xcodebuild test -quiet -scheme astral-sdk-Package \
    -destination "id=$SIM_UDID" "${TEST_FLAGS[@]}" "${selectors[@]}" \
    -resultBundlePath "$EVIDENCE/last-bearing-narrow-$(uuidgen).xcresult"
}
```

Use direct `xcodebuild` for narrow selectors: `scripts/test-swift-sdk.sh` already selects both complete SDK test targets, so appending a narrow selector to that script does not define a reliable narrow gate. Each listed `sdk_test` command supports a method selector `PhroverKitTests/ClassName/testMethodName` for an individual RED/GREEN slice. Record the generated bundle path and exact method/command in evidence.

Affected exit after review fixes:

```bash
sdk_test \
  PhroverKitTests/FollowReacquisitionPlannerTests \
  PhroverKitTests/FollowMeCoordinatorTests \
  PhroverKitTests/FollowTargetTrackerTests \
  PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  PhroverKitTests/NavigationRotationWatchdogTests \
  PhroverKitTests/NavigationSilentSearchMotionTests \
  PhroverKitTests/NavigationFollowReadySignalTests \
  PhroverKitTests/FollowMotionFailureResolutionTests \
  PhroverKitTests/FollowDiagnosticEventTests \
  PhroverKitTests/FollowAssociationDiagnosticsTests \
  PhroverKitTests/FollowPipelineDiagnosticsTests \
  PhroverKitTests/FollowPersonProjectionTests \
  PhroverKitTests/ARFollowMePerceptionSourceTests \
  PhroverKitTests/ARSessionManagerTests \
  PhroverKitTests/RoverControlTests \
  PhroverKitTests/OperatorCommandRouterTests \
  PhroverKitTests/FollowReacquisitionDiagnosticsTests
```

Final gates (fresh paths; record expanded values):

```bash
SDK_RESULT="$EVIDENCE/last-bearing-sdk-$(uuidgen).xcresult"
APP_RESULT="$EVIDENCE/last-bearing-app-$(uuidgen).xcresult"
scripts/test-swift-sdk.sh -quiet "${TEST_FLAGS[@]}" \
  -resultBundlePath "$SDK_RESULT"
xcodebuild test -quiet \
  -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination "id=$SIM_UDID" \
  -only-testing:PhroverOperatorTests "${TEST_FLAGS[@]}" \
  -resultBundlePath "$APP_RESULT"
xcodebuild build -quiet \
  -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcrun xcresulttool get test-results summary --path "$SDK_RESULT"
xcrun xcresulttool get test-results summary --path "$APP_RESULT"
git diff --check
```

Run serially, once per gate, with 60-second per-test timeouts and no retry flags/retry-until-pass. Capture affected/narrow summaries too. Diagnose failures, correct the implementation, and generate fresh post-fix evidence rather than masking failures with retries. Historical latest-admission evidence was **598 SDK / 33 app** tests; the new planner/regressions should change totals. Assert actual result-summary passed/failed/skipped counts and statuses, never those historical numbers.

## Tasks 1–2 actual implementation evidence (2026-10-02)

Scope: public pure planner/memory/episode value types, optional internal absolute-heading companion and recovery authorization, real controller boundary/result machinery, and the two scoped test files. Coordinator/tracker/admission wiring is Task 3 onward. `FollowReliableMemory(accepted:...)` validates the original observation source and paired geometry; normal-phase association/projection acceptance remains the caller's responsibility, to be wired in Task 3.

Implemented files:

- `swift/Sources/PhroverKit/FollowMe/FollowReacquisitionPlanner.swift`: paired accepted memory, genuine current source value, world-from-current-position center, explicit paired-yaw/bearing-only compatibility without invented position, `[-π, π)` wrap, fixed offsets, inclusive 7° arrival, bounded signed segments and exhaustion.
- `swift/Sources/PhroverKit/FollowMe/FollowReacquisitionEpisode.swift`: immutable episode ID, first loss/deadline, anchor, once-selected center, measured-arrival stage/segment cursor and unavailable reason. Interrupted/unarrived evaluations retain the cursor; exhaustion does not restart.
- `swift/Sources/PhroverKit/FollowMe/FollowRecoveryMotion.swift`, `FollowMeDependencies.swift`, `NavigationFollowMeMotion.swift`: internal absolute request and episode/generation/deadline/continuation authorization; optional contextual authorization for incomplete alignment/readiness. Relative-only conformers confirm stop and return unavailable/cancelled, with unknown controller/source facts.
- `swift/Sources/PhroverKit/Nav/NavigationController.swift`, `RotationDiagnosticModels.swift`: reuse serialized stop and controller-owned `.followScan` execution. Retain actual post-stop source; resolve the ≤30° absolute segment against actual pose after feedback; freeze that segment through opposite-sign corrections. Validate provenance, generation, deadline and continuation after suspension and immediately before motor send. Freeze one actual final post-stop sample into contextual segment/stage evidence; unresolved/invalid facts remain unknown. Existing public relative APIs/protocol requirements and rotation profile/watchdog values are retained.
- `swift/Tests/PhroverKitTests/FollowReacquisitionPlannerTests.swift`, `NavigationFollowScanDiagnosticsTests.swift`.

### Exact command setup and single-assertion RED → GREEN evidence

Working directory for every invocation: `/Users/hungmai/Sites/Astral/astral-sdk`.

`scripts/test-swift-sdk.sh --print-udid` returned `EEA52712-371D-4FF6-B8EF-A2C78319D57F`; result summary identifies iPhone 17 Pro, iOS Simulator 26.5, build `23F77`. Temporary parent was verified with `ls` before the first result creation.

Every individual selector below was run with this exact direct-command structure, first RED, then its minimal implementation patch, then the same selector GREEN:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/CLASS/METHOD \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb-STEM-PHASE.xcresult
```

In the table, `P` expands to `FollowReacquisitionPlannerTests`; `N` expands to `NavigationFollowScanDiagnosticsTests`; the method column is literal. `PHASE` is `red` or `green`, except `center` RED uses `red-valid`. Each of the **20 RED summaries** reports `Failed / 0 passed / 1 failed / 0 skipped`, with a compiled XCTest assertion failure. Each paired **20 GREEN summaries** reports `Passed / 1 passed / 0 failed / 0 skipped`. Assertions were added one vertical slice at a time, not as a bulk preimplementation test batch. New API scaffolding returned unavailable/no progression until its behavioral RED.

| STEM | CLASS / METHOD | Actual RED assertion evidence (abridged) |
| --- | --- | --- |
| `center` | P / `testCenterUsesActualCurrentPositionInsteadOfHistoricalYaw` | `nil` rather than `π/2` from actual current position |
| `fallback` | P / `testPairedFallbackWrapAndInvalidSources` | `+π` rather than `−π`; missing valid paired fallback |
| `stages` | P / `testFixedStagesBoundSegmentsAndUseMeasuredOvershoot` | all `unavailable` rather than fixed stages, bounded turns, measured negative return and exhaustion |
| `episode` | P / `testEpisodeFreezesCenterAndAdvancesOnlyOnFreshMeasuredStageArrival` | `[0,0,0,0,0,0,0,0,1]` rather than `[0,0,0,0,1,1,1,1,1]` |
| `boundary` | N / `testAbsoluteRecoveryResolvesAfterAcknowledgedStopAndFeedback` | repeated sends after actual yaw `0.8`, rather than one send; old relative target stalled. Final test also asserts changed post-stop and post-feedback positions/yaw/source target |
| `result` | N / `testRecoveryResultReportsActualSegmentArrivalWithoutClaimingStageArrival` | missing arrival source and segment/stage facts despite `.arrived` |
| `source` | N / `testRecoveryRequiresRealFreshExpectedGenerationAtStopAndAfterFeedback` | sends `[1,0,0,0,0,1,0]` rather than all zero for invalid generation/provenance/source |
| `auth` | N / `testRecoveryDeadlineAndOwnershipAreRecheckedAfterEverySuspension` | late commands/noncancelled results at pre-stop, feedback, detection, send, pulse wait, settle/final stop; nonfinite heading also sent |
| `incomplete` | N / `testRecoveryAuthorizationAlsoFencesIncompleteAlignmentAndReadyAfterFeedback` | sends `[1,1,1,1,1,0]` rather than all zero |
| `memory` | P / `testAcceptedMemoryRetainsSameObservationGeometryAndRejectsInvalidSource` | nil accepted paired geometry/provenance rather than the observation's literal facts |
| `cursor` | P / `testSegmentCursorRetainsInterruptedTargetAndFinitePassExhausts` | `[1,0,0,7,7]` rather than `[0,1,1,7,7]` |
| `legacy` | N / `testLegacyRecoveryStopsWithoutTurningOrInventingSourceFacts` | `[0,1,1,1,1,0]` rather than stopped-only `[0,0,0,3,1,1]` |
| `finalsource` | N / `testRecoveryCannotClaimArrivalFromSourceInvalidatedDuringFinalStop` | `[false,false,false]` rather than true for age/generation/future rejection and unknown arrival |
| `incomplete-final` | N / `testIncompleteRecoveryCannotRestoreFromGenerationChangedDuringFinalStop` | alignment/ready `.arrived` rather than `.failed(.trackingLost)` |
| `presend` | N / `testRecoveryRevalidatesSourceAgeImmediatelyBeforeEachMotorSend` | scan/alignment/ready sends `[1,1,1]` rather than `[0,0,0]` |
| `unknown` | N / `testInterruptedRecoveryReportsUnknownUnresolvedSegmentWithoutInventedRelativeRequest` | failed unknown unresolved segment/request/target assertion |
| `headingonly` | P / `testHistoricalHeadingOnlyFallbackDoesNotFabricatePairedPosition` | failed paired yaw/bearing fallback without a fabricated position |
| `coherent` | N / `testRecoveryArrivalUsesOneFinalPostStopSampleForResultAndEvidence` | failed coherent final sample/result assertion due to redundant independent source lookup |
| `relative` | N / `testOrdinaryRelativeAlignmentRetainsYawOnlyLegacyBehavior` | `.failed(.noPose)` rather than legacy `.arrived`; restored ordinary yaw-only behavior |
| `owner-final` | N / `testIncompleteRecoveryFinalStopCannotReturnLateArrivalAfterOwnerReplacement` | `[.arrived,.cancelled]` rather than `[.cancelled,.cancelled]` after ownership changed during final stop; result freeze now checks the controller's own generation/fence as well as episode authorization |

Preflight correction: the originally documented `-test-iterations 1` was rejected by Xcode (`Must specify -test-iterations with more than 1 iteration`). Its attempted `lb-center-red.xcresult` is **not** RED evidence. The next attempted reuse of that path was rejected as already existing, also **not** RED evidence. The corrected single default-run command used fresh `lb-center-red-valid.xcresult`; all subsequent commands omit that invalid flag. No retry/retry-until-pass flags were used.

Supplemental retention regressions (already GREEN behavior, no claimed RED): `N/testAbsoluteRecoveryKeepsSegmentTargetThroughOppositeSignCorrectionAndInclusiveTolerance` and `N/testAbsoluteRecoveryCallerCancellationDrainsStopAndRetainsFailedLatch`. These verify +0.25/−0.25 correction pulses toward the same ≤30° segment, 200/300 ms waits, inclusive 7° no-send arrival, caller cancellation at pre-stop/feedback/pulse wait, independent confirmation, failed-stop latch and blocked subsequent absolute requests. Existing class cases additionally cover replacement/generation/lifecycle races, old relative callers and watchdog failure priority.

### Final scoped software gate

After final source/result coherence, legacy compatibility, actor-safe test-capture cleanup and the last final-stop ownership regression/fix, executed:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowReacquisitionPlannerTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb-tasks12-owner-final.xcresult
xcrun xcresulttool get test-results summary --path \
  /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb-tasks12-owner-final.xcresult
git diff --check
```

Actual final result: **Passed — 88 passed / 0 failed / 0 skipped**, comprising planner **7**, controller diagnostics **69**, rotation watchdog **12** (verified from `xcresulttool get test-results tests`). `git diff --check` passed. Earlier scoped `lb-tasks12-scoped.xcresult` was **83 passed / 0 failed / 0 skipped**; `lb-tasks12-final.xcresult` was **87 passed / 0 failed / 0 skipped**, before the final-stop ownership regression/fix. Neither is reused as final-tree evidence.

Next: Tasks 3–5 wire these contracts into matched memory adoption, first-loss/finite recovery, lifecycle/deadline ownership and credible restoration. Task 6 retains independent review, full SDK/app tests and unsigned app build. No implementation blocker for the next task is known; those integration/review/final gates remain pending. No commit, push, physical-device install/launch/motion or full-suite gate was executed. Existing `.serena/project.yml`, `.opencode/`, `AGENTS.md` and `.superpowers` assets were not edited by this implementation.

## Tasks 3–4 actual implementation evidence (2026-10-02)

Scope was limited to reliable-memory adoption, first-loss absolute return, finite episode progression, deadline/operation/lifecycle fences, and their scoped regressions. The existing Tasks 1–2 planner/episode value files and controller profile/pulse/watchdog implementation were retained. The adapter's additional optional source read exposes the controller's actual sample after coordinator-confirmed stop; its default is explicitly unavailable. Relative-only providers remain stopped and observe, including when a healthy perception pose exists.

Implemented integration:

- `FollowMeCoordinator.swift`: one last-valid reliable record replaces the old shadow position; healthy initial/normal continuity adopts the original observation's paired facts before suspension. Accepted pending admission adopts that same record atomically, and the saved original association still reaches the processor. Processing the same accepted frame does not relabel its memory source.
- First loss freezes one immutable episode and starts its timer before stop acknowledgement. Provisional locks never write reliable memory, move the frozen 1.5 m anchor, recenter, or renew the deadline. Recovery frame/candidate generation pairing is validated; a subsequent incompatible AR generation fences and terminates recovery.
- First center uses a real fresh same-generation post-stop sample, once. Every recovery scan carries a fixed absolute stage heading plus episode/deadline/operation authorization to the Tasks 1–2 companion. Actual authoritative final arrival advances the immutable stage/segment cursor; a successful result without source evidence does not. The exact seven offsets exhaust once and then observe stationary. Interrupted stages resume without recentering.
- Deadline ownership is episode-based across incomplete recovery phases, including alignment and readiness. Frame ingress uses a synchronous clock check; completion checks introduce no non-expired authorization await before task/scan-flag mutation. Stop, cancellation, session replacement, AR reset, watchdog failure and outage retain existing fences and failed-stop precedence. A forward-goal stop completion at expiry cannot launch a goal.
- `FollowTargetTracker.swift`: optional internal batch/expected-generation gates preserve public entry points. Clipped observations are rejected using the projection seam's existing strict interior box rule; no new clipping threshold was introduced.
- Tests use the public coordinator, manual clock, optional absolute companion with explicit synthetic provenance, and real controller/adapter. Legacy fixtures are not certified as fresh sources. Recovery readiness tests that require motion now use an explicitly sourced companion. Initial pause/360° requested budget, ordinary following, fixed baseline, once-only ready attempt, two-second outage, and .25/200/300/7° controller regressions remain in the scoped gate.

### Single-behavior RED → GREEN commands and assertions

Every invocation used repository root, the previously selected **iPhone 17 Pro / iOS Simulator 26.5 / `EEA52712-371D-4FF6-B8EF-A2C78319D57F`**, and the verified temporary parent. No retries or retry-until-pass flags were used.

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/CLASS/METHOD \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb34-STEM-PHASE.xcresult
```

`C` below expands to `FollowMeCoordinatorTests`; `A` expands to `FollowReadyAdmissionIntegrationTests`. Each of the **11 compiled behavioral RED summaries** reports **Failed / 0 passed / 1 failed / 0 skipped**; each paired GREEN summary reports **Passed / 1 passed / 0 failed / 0 skipped**. RED ran before the implementation of that behavior, then the same method selector ran GREEN.

| STEM | CLASS / literal METHOD | Actual compiled RED assertion (abridged) |
| --- | --- | --- |
| `legacy` | C / `testLegacyRecoveryObservesStationaryWithoutInventedFreshPose` | relative `[0.5235987755982988]` rather than `[]` |
| `memory` | C / `testRecoveryReturnsToLatestMatchedWorldPointFromActualPostStopPosition` | no absolute request rather than heading `1.849095985800008` from latest matched world point and changed post-stop position |
| `anchor` | C / `testProvisionalReacquisitionCannotMoveFrozenSpatialAnchor` | `following` rather than `reacquiring` after a candidate drifted outside the original 1.5 m anchor |
| `pair` | C / `testRecoveryRejectsUnpairedCandidateBeforeSpatialAcceptance` | `following` rather than `reacquiring` for wrong generation / candidate-batch pairing |
| `deadline` | C / `testOriginalLossDeadlineIncludesPendingStopAndRecoveryAlignment` | pending stop still `reacquiring`, and alignment surviving an expiry frame, rather than `Person lost.` |
| `finite` | C / `testRecoveryVisitsFixedOffsetsOnceUsingMeasuredSegmentsAndOvershoot` | only `[90]` rather than `[90,105,75,120,60,135,45]` |
| `pending` | A / `testAcceptedPendingContinuityFreezesItsOriginalPairedMemoryAtLoss` | missing frozen episode/memory evidence; GREEN asserted accepted-pending frame `1:4`, paired person/rover/yaw and original association handoff |
| `clipped` | C / `testRejectedClippedContinuationCannotShadowReliablePairedMemory` | anchor `1:2` rather than last-valid `1:1` |
| `initial-pair` | C / `testInitialSelectionCannotAuthorizeCandidateFromAnotherBatch` | unpaired initial candidate established `following` rather than remaining `searching` |
| `generation` | C / `testGenerationReplacementFencesRecoveryBeforeOldResultCanAdvance` | recovery remained active after AR generation replacement |
| `forward-deadline` | C / `testRecoveryStopCompletionAtOriginalDeadlineCannotLaunchForwardGoal` | `following` and a new goal rather than `Person lost.` at original deadline |

For `initial-pair`, RED is `lb34-initial-pair-red-valid.xcresult`. The earlier `lb34-initial-pair-red.xcresult` passed its insufficient goal-only assertion (the later follow freshness gate already suppressed the send); it is **not** RED evidence. Adding the selected-phase assertion exposed the actual pairing defect before the implementation patch.

Supplemental retention coverage, already GREEN without a claimed new behavioral RED:

- `lb34-retention-boundaries.xcresult`: **2 passed** — real negative-world-heading controller pass `[-90,-75,-105,-60,-120,-45,-135]`, measured negative overshoot followed by positive `.25` correction, exhaustion; interrupted +15° stage retained with frozen center/episode/deadline while old completion cannot clear the newer scan.
- `lb34-retention-safety.xcresult`: **4 passed** — command success without arrival source cannot advance; rejected confidence/world jump/ambiguity/stale/future/unhealthy/frame-pair candidates cannot erase memory; real recovery watchdog remains terminal; old completion and old ten-second timer cannot delete/expire a new session's eleven-second episode.
- Existing Tasks 1–2 real-boundary cases in the final scope cover expiry/source/ownership checks during pre-stop, feedback, send, pulse wait, settle, final stop, alignment and ready completion, along with unchanged profile and watchdog policy.

### Scoped failures diagnosed and corrected

`lb34-scoped-first.xcresult` ran the five Task 3–4 classes: **187 passed / 10 failed / 0 skipped**. Older tests assumed relative-only recovery commands or source-less real-controller recovery (one timed out waiting for a prohibited pulse). They were corrected to assert stationary legacy behavior or explicitly inject sourced recovery facts. One latest-pending rejection regression was corrected by preserving the admission token's original owner and keeping non-expired ingress checks synchronous; `lb34-handoff-green.xcresult` then passed its method. `lb34-scoped-second.xcresult` passed **200 / 0 / 0** before the later retention additions.

`lb34-final-scoped.xcresult` ran the seven final selectors: **224 passed / 1 failed / 0 skipped**. The existing newest-pending test released feedback before frame 5 had actually reached ingress, admitting frame 4. A one-shot manual-clock callback now releases feedback at the synchronous ingress clock read, ensuring the newest frame is ingested first. `lb34-pending-ingress-green.xcresult` then reported **0 passed / 2 failed** because the normal processor legitimately consumed the ingested frame before admission; memory truthfully reported `continued` rather than `acceptedPendingContinuity`, and admission reported `not_pending` rather than an invented second association. The two tests now assert the same newest paired frame and original unique match under either valid ordering, with source/evaluation fields matching the actual order. The earlier single-method `lb34-pending-green.xcresult` records the accepted-pending path explicitly. `lb34-pending-ingress-ordered.xcresult` passed **2 / 0 / 0** after this fixture/assertion correction. None of these pre-correction bundles is final-tree evidence.

### Final corrected scoped gate

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  -only-testing:PhroverKitTests/FollowTargetTrackerTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/FollowReacquisitionPlannerTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb34-final-corrected.xcresult
xcrun xcresulttool get test-results summary --path \
  /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb34-final-corrected.xcresult
xcrun xcresulttool get test-results tests --path \
  /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb34-final-corrected.xcresult
git diff --check
```

Actual final result: **Passed — 225 passed / 0 failed / 0 skipped**: coordinator **94**, admission integration **33**, tracker **7**, controller diagnostics **69**, failure resolution **3**, planner **7**, rotation watchdog **12**. The retained Tasks 1–2 classes still contribute their original **88** passing tests. `git diff --check` passed. No full SDK suite, app suite/build, independent implementation review, commit/push or physical-device operation ran.

**Next / blocked completion:** Task 5 must implement the exact confirmed-scan-stop/new-distinct-normal-frame restoration transaction and atomic episode clear/reliable-memory commit. Until that boundary exists, even a provisionally resumed normal phase remains under the original ten-second episode budget; alignment, readiness and detection chatter do not clear it. Tasks 3–4 do not claim completed credible restoration. Task 6 then completes diagnostic lifecycle/stage payloads, independent review and final full SDK/app/build evidence. There is no known blocker to starting Task 5; final feature completion is blocked on those remaining tasks.

## Task 5 actual implementation evidence (2026-10-02)

**Checkpoint:** credible restoration is implemented; Task 6 is still pending. Task 5 changed only `FollowMeCoordinator.swift`, `FollowMeCoordinatorTests.swift`, `FollowReadyAdmissionIntegrationTests.swift`, and this plan on top of the existing uncommitted Tasks 1–4 tree.

Implementation:

- Provisional detection fences/cancels the scan and confirms serialized stop, including stationary/exhausted recovery. The stop boundary records both the newest ingested frame (pending or processed) and confirmation uptime. Recovery requires a strictly newer same-generation, healthy, fresh, normal-continuity matched frame with timestamp at/after confirmation. The provisional and consumed pre-confirmation frames cannot restore control.
- Post-departure provisional detection stays `reacquiring`; its next qualifying normal match resumes `following` or `holdingDistance` under the existing range, goal, freshness and stop gates. Before departure, confirmed alignment, a new post-alignment-stop matched frame and inclusive 0.05-rad heading validation remain required.
- One synchronous restoration transaction validates the final frame, establishes the actual normal phase, commits its original paired reliable memory, removes the episode/stop evidence, and cancels/removes the old timer. No await splits this transaction. Too-close alignment or a confirmed real-controller clearance deferral can establish `waitingForClearance` without consuming readiness. Successful readiness establishes `waitingForMovement` only with the existing distinct final-stop/baseline frame; retained baselines never rebase.
- Alignment, pending admission, ready motion and baseline wait remain under the original deadline. Admission validates recovery post-stop evidence and expiry independently; continuation authorization checks newest ingested normal association as well as health/generation. Confirmed-stop callbacks enforce expiry before recording alignment/readiness success, even without timer delivery. Alignment/readiness confirmation markers include ingested pending frames.
- Reacquired → aligning → lost retains the old episode/anchor/center/cursor/deadline. A genuinely restored normal phase then lost freezes a new episode from its newly committed memory. Existing attempt-consumed/succeeded flags, specific failures, two-second outage policy, stop latch and controller pulse/profile behavior are preserved.

### Exact vertical RED → GREEN evidence

Every command ran at repository root `/Users/hungmai/Sites/Astral/astral-sdk`, using iPhone 17 Pro / iOS Simulator 26.5 / `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. The temporary parent was verified before result creation. The exact command structure was:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/CLASS/METHOD \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb5-STEM-PHASE.xcresult
```

`C` = `FollowMeCoordinatorTests`; `A` = `FollowReadyAdmissionIntegrationTests`. Each RED below compiled and reported **Failed / 0 passed / 1 failed / 0 skipped**; each same-selector GREEN reported **Passed / 1 passed / 0 failed / 0 skipped**. Each behavior was asserted and run RED before its implementation patch, then run GREEN before the next slice. `PHASE` is literally `red` or `green`.

| STEM | CLASS / literal METHOD | Actual RED assertion (abridged) |
| --- | --- | --- |
| `normal` | C / `testPostDepartureRecoveryNeedsDistinctContinuityThenNewLossFreezesRestoredMemory` | `holdingDistance` rather than `reacquiring` on provisional detection; missing new loss episode from restored frame. GREEN covers both holding and following. |
| `departure` | C / `testBeforeDepartureRestorationClearsOnlyAtAlignedClearanceOrRetainedBaselinePhase` | anchors `[1:3]` rather than `[1:3,1:6]`. GREEN covers both clearance and waiting-for-movement, preserving readiness count/baseline. |
| `admission` | A / `testRecoveryReadyClearanceDeferralCommitsNewestNormalMatchWithoutConsumingAttempt` | one episode rather than two after confirmed healthy clearance deferral and new loss; missing newest frame `1:5` memory. |
| `finalstop` | C / `testRecoveryFinalAlignmentAndReadyStopsEnforceDeadlineWithoutTimerDelivery` | `aligning` rather than `Person lost.` after final stop at the original deadline. GREEN covers alignment and ready final-stop callbacks. |

Supplemental retention evidence (already GREEN, no claimed behavioral RED):

- `lb5-stop-red.xcresult` is **Passed / 1 / 0 / 0**, despite its filename; it is **not RED evidence**. C / `testRecoveryDetectionStopRevalidatesNewestAssociationAndExcludesConsumedStopFrame` verifies suspended detection stop, conflicting newest targets, no alignment launch on ambiguity, and exclusion of a frame consumed before confirmation.
- `lb5-retention-ready-valid.xcresult`: **Passed / 2 / 0 / 0** — C / `testUnusedRecoveryReadyStaysBoundUntilDistinctBaselineAndNeverRetries` and `testRecoveryAlignmentInclusivePointZeroFiveGateNeedsNewFrameAndRejectsOutsideGate`. Exact-deadline fresh frames fail incomplete baseline recovery but do not resurrect a cleared timer; 0.050001 is rejected and 0.05 accepted without an extra frame-count threshold.
- `lb5-retention-real.xcresult`: **Passed / 2 / 0 / 0** — A / `testRealRecoveryReadyFeedbackRetainsDeadlineAndSuccessfulBaselineClearsIt` uses the real controller/adapter; C / `testProvisionalAlignmentLossKeepsOriginalEpisodeAndDeadline` verifies original anchor, unfinished heading and ten-second boundary on alignment chatter.
- Existing scoped tests retain consumed partial/cancelled/failed ready behavior, succeeded-but-baseline-pending recovery, fixed baseline, stale/future/ambiguous/wrong-generation association, latest-pending handoff, two-second outage, all lifecycle/old-callback/failed-stop fences, startup pause/360° requested budget, ordinary follow/hold/no reverse/local Stop, and .25/200/300/7° controller behavior.

Non-final attempts, diagnosed rather than retried unchanged:

- `lb5-scoped-first.xcresult`: **148 passed / 1 failed / 0 skipped** across the three Task 5 classes. `testLossStopsBeforeReacquisitionRotationAndRejectsCentralNewcomer` still expected the provisional frame to resume following. Its assertion now requires `reacquiring` first, then sends a distinct matched continuation and asserts following. This preserves rejection of the central newcomer while adopting the approved restoration boundary.
- `lb5-retention-ready.xcresult` failed compilation because the saved snapshot association is optional; corrected optional chaining before `lb5-retention-ready-valid.xcresult`. The build failure is not behavioral RED evidence.

### Final Task 5 scoped gate

After all implementation and retention corrections:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb5-final-scoped.xcresult
xcrun xcresulttool get test-results summary --path \
  /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb5-final-scoped.xcresult
xcrun xcresulttool get test-results tests --path \
  /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb5-final-scoped.xcresult
git diff --check
```

Actual final result: **Passed — 225 passed / 0 failed / 0 skipped**, verified from the result summary and test tree: coordinator **101**, admission integration **35**, ready controller **17**, scan controller diagnostics **69**, failure resolution **3**. The three prescribed Task 5 classes contribute **153** tests; the two controller/failure retention classes contribute **72**. No retry/retry-until-pass flags were used. This is a new result bundle, not reused Tasks 3–4 evidence.

**Next / risks:** Task 6 still owns complete episode/restoration diagnostic payloads, independent implementation review, affected exit gate, full SDK/app unit tests and unsigned app build. Those gates, hardware acceptance and the documented depth/spatial-identity/latency/overshoot/budget limitations remain open. This Task 5 checkpoint does not claim final feature completion. No commit, push, installation, physical motion or full-suite run occurred.

## Task 6 diagnostics-only actual evidence (2026-10-02)

**Checkpoint:** diagnostics slice complete, corrected scoped GREEN; returned for independent review. Task 6's overall checkbox deliberately remains open. No independent reviewer, affected exit gate, full SDK suite, app suite/build, commit/push, installation or physical motion ran in this session.

### File map and diagnostic contract

Paths relative to repository root:

- `swift/Sources/PhroverKit/FollowMe/FollowReacquisitionDiagnostics.swift` (**new**): fixed-size primitive formatter for frozen episode/memory/center/cursor, live last-reliable versus provisional snapshots, and controller segment samples. No clock, pose-provider, motor, timer, event history, or motion authorization ownership. Source timestamps/read times stay distinct; unknown raw IDs, unavailable geometry and unresolved movements stay null. Availability follows final values, including nonfinite serialization. Heading fallback exposes its reason and does not invent historical world/rover position.
- `FollowMe/FollowMeCoordinator.swift`: synchronous first-loss freeze event; once-selected center and retained cursor/deadline; absolute request start/completion; measured segment/stage completion, inclusive-tolerance skip and stationary exhaustion; provisional post-stop retention; exact normal-phase clear with restored frame; expiry; stop response and lifecycle/terminal fences. Completion describes the **evaluated** stage/segment plus separate next cursor, not the already-advanced stage. Phase/readiness/association/pipeline snapshots distinguish last-valid memory, provisional lock and unavailable current authority. Existing association/pipeline summary budget owns periodic snapshots; unchanged outages produce no added per-frame stream. Unavailable-source reasons are deduplicated. Terminal/stop records capture old identity before suspension; late completion cannot log a current-episode clear.
- `FollowMe/FollowRecoveryMotion.swift`: optional captured source-read uptimes on existing immutable segment evidence; authorization accepts its already-read time so controller diagnostics capture the same check without another clock read.
- `Nav/RotationDiagnosticModels.swift`: per-operation episode/deadline/expected-generation/stage correlation and actual controller authorization-check time/outcome.
- `Nav/NavigationController.swift`: capture existing post-stop/resolution/final-arrival source times, including rejected post-stop samples. Preserve existing pose reads and authorization evaluation/short-circuit order. No diagnostic await or additional pose sample. Resolve/arrival behavior, source guards, wheel sends and safety tuning are retained.
- `Nav/FollowScanDiagnosticTrace.swift`: merge frozen recovery facts into existing controller pulse/send/stop/settle/watchdog records, retaining request token, controller operation and inherited transport correlation. Planned/requested movement, measured AR signed change/error, system-uptime authorization deadline and host-monotonic durations remain separate. Signed net source-yaw change is explicitly **not cumulative physical coverage**.
- Tests: `FollowDiagnosticEventTests.swift`, `FollowAssociationDiagnosticsTests.swift`, `FollowPipelineDiagnosticsTests.swift`, `NavigationFollowScanDiagnosticsTests.swift`, `FollowMeCoordinatorTests.swift`, and new `FollowReacquisitionDiagnosticsTests.swift`. Existing Tasks 1–5 tests/fixtures were retained except the documented interior-box association fixture correction below.

`FollowMe/` and `Nav/` above are under `swift/Sources/PhroverKit/`; test paths are under `swift/Tests/PhroverKitTests/`. Unrelated pre-existing `.serena/project.yml`, `.opencode/`, `AGENTS.md` and `.superpowers` assets were preserved.

### Exact RED → GREEN commands and assertions

Every invocation ran from `/Users/hungmai/Sites/Astral/astral-sdk` on the retained iPhone 17 Pro / iOS Simulator 26.5 / `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Temporary parent was verified with `ls` before creating results. No retry flags were used.

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/CLASS/METHOD \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb6-STEM-PHASE.xcresult
```

`C` = `FollowMeCoordinatorTests`, `N` = `NavigationFollowScanDiagnosticsTests`, `P` = `FollowPipelineDiagnosticsTests`. Eleven single-method RED cycles each compiled and reported **Failed / 0 passed / 1 failed / 0 skipped** before production edits; paired GREENs each report **Passed / 1 / 0 / 0**. The availability correction ran the two listed selectors together: **RED 0 / 2 / 0**, then **GREEN 2 / 0 / 0**. Result summaries were inspected with `xcrun xcresulttool get test-results summary --path PATH`.

| STEM | CLASS / literal METHOD | Actual compiled RED evidence |
| --- | --- | --- |
| `freeze` | C / `testRecoveryDiagnosticsFreezePairedMemoryAndSelectCenterExactlyOnce` | missing `anchor_person_z` rather than `4`; partial freeze lacked source/bearing/pending-stop/center record |
| `lifecycle` | C / `testRecoveryDiagnosticsReportExhaustionExpiryRestorationAndFailedStop` | empty completed-segment stream; missing exhaustion/expiry/restoration/termination |
| `controller` | N / `testRecoveryDiagnosticStreamUsesCapturedControllerReadsAndActualFinalYaw` | missing actual episode/controller-source facts; GREEN distinguishes request `.30` from measured `.35`, and asserts exactly four pose reads |
| `snapshot` | P / `testRecoverySnapshotsKeepLastReliableSeparateFromProvisionalAndShareSummaryBudget` | missing unavailable-companion record; GREEN checks last-valid `1:1`, provisional `1:3`, unhealthy current authority, original deadline and bounded repeats |
| `stage` | C / `testRecoveryDiagnosticsReportExhaustionExpiryRestorationAndFailedStop` | completion stage `1` rather than actually evaluated `0`; missing movement and next cursor |
| `fence` | C / `testRecoveryDiagnosticsFenceLifecycleAndIgnoreLateOldCompletionAcrossEpisodes` | missing lifecycle fence/terminal record; GREEN releases old suspended completion after a new episode and asserts no extra records/clear |
| `auth` | N / `testRecoveryDiagnosticStreamUsesCapturedControllerReadsAndActualFinalYaw` | missing controller authorization check time `8.1`; GREEN verifies original deadline clock/remaining from actual check |
| `inactive` | P / `testRecoverySnapshotsKeepLastReliableSeparateFromProvisionalAndShareSummaryBudget` | missing explicit null provisional entry and inactive current-availability/episode fields |
| `rejection` | N / `testRecoveryDiagnosticsRejectSourceAndDeadlineWithoutInventingResolvedMovement` | missing captured rejected source `5:10`; GREEN covers wrong generation, missing pose and exact-deadline feedback, with unresolved targets/movement null and no sends |
| `stop` | C / `testRecoveryDiagnosticsPreserveFirstLossStopFailureOverDeadlineCleanup` | missing failed first-loss stop record; GREEN retains failed-stop priority against old deadline cleanup |
| `availability` | C / lifecycle method above **and** N / rejection method above | known movement mislabeled `unavailable`; known absolute stage target lacked `available` after merge |
| `cleared-status` | C / lifecycle method above | cleared record carried `recovery_active: true` from its pre-clear forensic snapshot; GREEN explicitly reports recovery/deadline inactive and provisional fields null while retaining the historical episode/anchor |

`PHASE` is literally `red` or `green`, except lifecycle's valid paired GREEN is `lb6-lifecycle-green-valid.xcresult`. The earlier `lb6-lifecycle-green.xcresult` was **0 / 1 / 0**: its fixture expected `following` before readiness/baseline completion. The assertion was corrected to require `signalingReady` with retained episode, then distinct baseline frame `1:5` establishing `waitingForMovement`. No production phase rule was relaxed.

Supplemental already-GREEN retention assertions (no claimed new behavioral RED) exercise exact negative-π paired-heading fallback, unavailable geometry/memory, actual `waitingForClearance`/`following`/`holdingDistance` clear boundaries, readiness snapshots while baseline-pending, frame/generation rejection facts, primitive precision/nonfinite/privacy filtering, and the inherited summary/controller/transport/watchdog/profile tests.

### Corrected scoped gate

`lb6-scoped-first.xcresult` reported **239 passed / 1 failed / 0 skipped**. The older association boundary-matrix test used boxes touching x/y image edges, now correctly rejected by Task 3's clipping gate before IoU/screen evaluation. Only that fixture was changed to exact binary **interior** geometry (IoU `.5`, displacement `.125`, matching test-local thresholds), retaining exact-boundary acceptance and just-outside rejection. No production clipping or association threshold changed.

`lb6-scoped-final.xcresult` reported **241 / 0 / 0** before the availability-label regression/fix. `lb6-scoped-corrected.xcresult` then reported **241 / 0 / 0** before the final cleared-status regression/fix. Both are historical, not final-tree evidence. After cleared-status RED→GREEN, executed this fresh review-checkpoint gate:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/FollowAssociationDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowPipelineDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowReacquisitionDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb6-review-checkpoint.xcresult
xcrun xcresulttool get test-results summary --path \
  /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb6-review-checkpoint.xcresult
xcrun xcresulttool get test-results tests --path \
  /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb6-review-checkpoint.xcresult
git diff --check
```

Actual corrected result: **Passed — 241 passed / 0 failed / 0 skipped**. Test tree confirms association diagnostics **7**, diagnostic envelope **9**, coordinator **106**, failure resolution **3**, pipeline diagnostics **8**, reacquisition diagnostics **2**, admission integration **35**, controller scan diagnostics **71**. `git diff --check` passed.

### Independent-review handoff / safety concerns

Review the combined uncommitted Tasks 1–6 implementation against spec §§3–8, especially post-stop source/absolute targeting, pending-adoption handoff, expiry at each send, exact restoration/cursor reentry and old-callback/failed-stop races. Diagnostics preserve captured old context; a late source is not current authority, a frame-local ID is not identity, a requested angle is not measured yaw, and net AR source-yaw change is not cumulative physical coverage. Stop-wait/terminal budget snapshots explicitly name their capture boundary rather than renewing source time or implying later stop latency did not count.

No known blocker remains for independent review; scoped simulator evidence is not hardware acceptance or full feature completion. Existing depth/spatial-identity, source/stop latency, overshoot and ten-second search-budget limitations remain. Run review and resolve findings **before** the affected exit/full SDK/app/build gates in the runbook; generate fresh final evidence after any corrections.

## Task 6 independent-review corrections (2026-10-02)

**Checkpoint only:** addressed the supplied high and medium findings. Follow-up independent review approval, affected exit, full SDK/app tests and unsigned app build remain open. No final feature-completion claim.

Changed `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift`, `swift/Tests/PhroverKitTests/FollowReadyAdmissionIntegrationTests.swift`, and this plan:

- **High:** at recovery continuation authorization, a genuinely pending healthy unique reacquisition is evaluated using the frozen episode anchor and the existing 1.5 m gate, expected generation and candidate/frame pairing. It synchronously inhibits scan continuation with detection origin and rejects continuation. It neither selects an initial target nor tests provisional continuity. The normal processor still owns cancellation, serialized stop confirmation and provisional adoption; cursor, frozen center/anchor and original deadline remain unchanged.
- **Medium:** retain the original association decision keyed by coordinator generation and exact AR frame ID before updating the lock. Both normally processed and admission-accepted frames retain that authority. Authorization reuses only the matching frame's original decision; a genuinely new pending frame is evaluated against the current previous lock, with its snapshot handed to the processor. Frame health/freshness, AR/session generation, operation/episode ownership and deadline remain independent checks. A newly accepted current frame replaces the record; start, lifecycle inhibition, terminal finish and failed-stop fencing clear it. Old-generation processing is rejected before any current-record mutation.
- Real controller/adapter regressions hold **controller acknowledgement**, including ready acknowledgement after one real nonzero send; they do not substitute a held external-stop callback. Scan regression releases acknowledgement from the ingress clock, before scheduling the pending processor, and checks no additional nonzero send before the next confirmed stop plus provisional alignment, frozen anchor and original deadline. Ready regression processes `1.7 m → [2.3 m, 2.6 m]` while acknowledgement is held: the original unique result survives release without a new frame, one ready completion occurs, and baseline still requires a distinct fresh frame with no repeated ready signal.
- Supplemental safety matrix verifies a genuinely new ambiguous pending frame, stale current source, AR-generation replacement and exact original deadline cannot inherit the accepted decision; an older ignored frame cannot erase current accepted authority. The complete related classes retain old-session/completion/pending-admission lifecycle protections and existing thresholds/profiles/watchdogs/restoration gates.

### Exact RED → GREEN evidence

Every command ran from `/Users/hungmai/Sites/Astral/astral-sdk`, using the retained iPhone 17 Pro / iOS Simulator 26.5 / `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, with the temporary parent verified before result creation. No retry flags were used.

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests/METHOD \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BUNDLE.xcresult
```

| Finding / literal METHOD | RED bundle / assertion | Same-selector GREEN bundle |
| --- | --- | --- |
| High / `testPendingUniqueReacquisitionFencesRealScanBeforeAcknowledgementResumes` | `lb6-review2-pending-red-drained`: **0 passed / 1 failed / 0 skipped**, one nonzero send before the next stop rather than zero | `lb6-review2-pending-green-drained`: **1 / 0 / 0** |
| Medium / `testRecoveryReadyKeepsProcessedUniqueDecisionAcrossHeldPostSendAcknowledgement` | `lb6-review2-decision-red`: **0 / 1 / 0**, failed ready completion rather than `signalingReady` after reassociating the same raw frame against its updated lock | `lb6-review2-decision-green`: **1 / 0 / 0** |

The high fixture was corrected before the authoritative RED: constructing a batch itself reads the manual clock, so the release callback must be installed **after** sending the constructed batch; old scheduled clock readers must be drained while controller acknowledgement is held. The authoritative corrected selector was run against the pre-fix production behavior before reinstating its fix. Earlier `pending-red`, `pending-red-boundary`, `pending-red-valid`, `pending-green-valid`, `pending-green-ingress`, `pending-green-final`, and `pending-green-synchronous` used an insufficiently isolated fixture and are not authoritative evidence. `pending-red-ingress` passed and is not RED evidence. `pending-green` failed compilation on optional anchor geometry and is not behavioral evidence. These were diagnosed, not retried unchanged.

`lb6-review2-safety.xcresult` ran `testAcceptedRecoveryDecisionCannotAuthorizeNewPendingOrInvalidatedSource`: **1 / 0 / 0**, supplemental already-GREEN retention evidence with the five safety conditions above.

### Corrected full related-class gate (not full SDK)

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  -only-testing:PhroverKitTests/FollowTargetTrackerTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/FollowReacquisitionPlannerTests \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/FollowAssociationDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowPipelineDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowReacquisitionDiagnosticsTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb6-review2-related-classes.xcresult
xcrun xcresulttool get test-results summary --path \
  /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/lb6-review2-related-classes.xcresult
git diff --check
```

Actual result: **Passed — 287 passed / 0 failed / 0 skipped**. `git diff --check` passed. No full SDK/app tests, app build, commit, push or physical-device operation ran. Return this corrected uncommitted tree for review before advancing Task 6's remaining gates.

## Historical pre-verification completion, approval, and risks

Implementation is approved by the referenced spec; this plan adds no threshold, tuning, identity mechanism, or new frame-count rule. Independent review and final software evidence are future implementation completion gates. No commit/push is requested. No device installation, launch, or physical motion is authorized; supervised device acceptance remains separately authorized under the spec.

Residual risks: coherent incorrect depth can pass existing spatial gates; spatial association is not identity; AR/host stop latency and physical overshoot can exceed requested rotation; large returns and settle overhead can consume the ten-second budget before all offsets. These limitations never authorize stale motion, deadline renewal, another pass, or a ready retry.

**Original documentation-only verification (historical):** inspected the existing plans parent before dedicated patch creation; checked current coordinator/tracker/admission/controller seams and test script at `0025527`. The original plan authoring changed only this document and ran no tests/builds. Subsequent Tasks 1–2 implementation and actual scoped test evidence are recorded above.

## Task 6 final verification-only evidence (2026-10-02)

**Disposition:** all required software gates passed. Independent review approval is attributed to the user's final-verification instruction: the two findings were independently resolved and no more issues remain. This verification session did not create a new independent review. Historical open-gate statements above describe their original checkpoints and are superseded by this section.

### Exact execution and result evidence

Working directory: `/Users/hungmai/Sites/Astral/astral-sdk`; HEAD `0025527`. Verified the temporary parent with `ls`; `scripts/test-swift-sdk.sh --print-udid` again selected `EEA52712-371D-4FF6-B8EF-A2C78319D57F` (iPhone 17 Pro, iOS Simulator 26.5, `23F77`). Ran affected → SDK → app → build serially, once each, against the latest corrected source. No skip, retry, retry-until-pass, warning-suppression, or test-weakening flags. All four commands exited 0. No fresh regression required reproduction or production changes.

Exact expanded common values below; affected selectors are the complete 18-class runbook list above, each supplied as `-only-testing:PhroverKitTests/CLASS`. The original 17 classes were preserved and the new `FollowReacquisitionDiagnosticsTests` added. No additional matrix test file exists; existing planner, controller, coordinator, admission and diagnostics matrix methods ran in full.

```bash
SIM_UDID=EEA52712-371D-4FF6-B8EF-A2C78319D57F
EVIDENCE=/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode
TEST_FLAGS=(-parallel-testing-enabled NO -test-timeouts-enabled YES
  -default-test-execution-time-allowance 60
  -maximum-test-execution-time-allowance 60)
# Affected: all 18 -only-testing selectors from the affected runbook above.
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination "id=$SIM_UDID" "${TEST_FLAGS[@]}" "${selectors[@]}" \
  -resultBundlePath "$EVIDENCE/lb6-final-affected-20261002.xcresult"
SIM_UDID="$SIM_UDID" scripts/test-swift-sdk.sh -quiet "${TEST_FLAGS[@]}" \
  -resultBundlePath "$EVIDENCE/lb6-final-sdk-20261002.xcresult"
xcodebuild test -quiet \
  -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination "id=$SIM_UDID" \
  -only-testing:PhroverOperatorTests "${TEST_FLAGS[@]}" \
  -resultBundlePath "$EVIDENCE/lb6-final-app-20261002.xcresult"
xcodebuild build -quiet \
  -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/lb6-final-build-20261002.xcresult"
```

Each actual invocation used `set -o pipefail` and `2>&1 | tee` to the same-stem `.log` beside its bundle. Counts/status were read from `xcrun xcresulttool get test-results summary --path PATH`; class/method coverage from `get test-results tests`; warnings/errors/build status from `get build-results` for all four bundles. These are fresh results, not the 287-test review checkpoint.

| Gate / bundle under `EVIDENCE` | Result | Passed | Failed | Skipped | Expected failures | Build warnings / errors |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `lb6-final-affected-20261002.xcresult` | Passed | 350 | 0 | 0 | 0 | 0 / 0 |
| `lb6-final-sdk-20261002.xcresult` | Passed | 661 | 0 | 0 | 0 | 0 / 0 |
| `lb6-final-app-20261002.xcresult` | Passed | 33 | 0 | 0 | 0 | 1 / 0 |
| `lb6-final-build-20261002.xcresult` | succeeded | — | — | — | — | 2 / 0 |

SDK means both complete configured SDK targets (`PhroverKitTests`: **642**, `RoverNavTests`: **19**), as selected by the repository script; live cloud probes and separate simulator-package targets are outside that prescribed gate. All app unit classes ran: calibration preview **9**, conversation model **13**, manual QR exchange **4**, silent-search map transform **7**. The 350 affected tests are a subset of the 661 SDK tests; unique SDK + app total is **694**, while total passing executions across the three gates are **1,044**.

Affected test-tree counts (all Passed): planner **7**, coordinator **106**, tracker **7**, ready admission **38**, controller scan diagnostics **71**, rotation watchdog **12**, silent-search motion **6**, ready controller **17**, failure resolution **3**, diagnostic envelope **9**, association diagnostics **7**, pipeline diagnostics **8**, person projection **26**, AR follow perception **6**, AR session **5**, rover control **12**, command router **8**, reacquisition diagnostics **2** = **350**. This includes both review regressions and the five-condition accepted-decision safety matrix.

**Actual warnings, retained without changes:** app tests report the `UIScreen.main` iOS 26 deprecation at `examples/PhroverOperator/PhroverOperator/Views/ConversationView.swift:273:58`. Unsigned build reports that same deprecation and “A launch configuration or launch storyboard or xib must be provided unless the app requires full screen.” All analyzer-warning counts are 0. Both SDK logs also contain the Xcode runtime diagnostic “Supported platforms for the buildables in the current scheme is empty”; their result bundles still report 0 build warnings and successful testing. The build log's removed-stale-derived-product messages are notes, not source edits or warnings. Incremental latest-source builds were used; reported warning counts describe these invocations, not a clean-build inventory.

### Diff, new-file whitespace, and file map

Inspected every tracked implementation source/test diff and all six new Swift files. `git diff --check` passed; each new Swift file was separately checked with `git diff --no-index --check /dev/null PATH` (no whitespace diagnostics; exit 1 denotes the new-file difference). The same plan check found three pre-existing Markdown hard-break trailing spaces in its header; replaced them with blank-line spacing and the final check passed. Only this plan was edited during final verification; production and tests stayed as supplied. Git status retains the original 14 tracked implementation source/test changes, six new Swift files, and this untracked plan. Unrelated `.serena/project.yml`, `.opencode/`, `AGENTS.md` and `.superpowers` assets were preserved. No commit, push, device installation, device launch or physical motion occurred.

Compact implementation file map (paths under `swift/`):

| Files | Responsibility |
| --- | --- |
| `Sources/PhroverKit/FollowMe/FollowReacquisitionPlanner.swift`, `FollowReacquisitionEpisode.swift` (new) | Public pure heading/source contract, immutable reliable anchor, one deadline, seven fixed offsets, measured stage/segment progression. |
| `FollowMe/FollowRecoveryMotion.swift` (new), `FollowMeDependencies.swift`, `NavigationFollowMeMotion.swift` | Optional internal absolute companion and recovery authorization, real source access, stationary legacy fallback. |
| `FollowMe/FollowMeCoordinator.swift`, `FollowTargetTracker.swift` | Reliable-memory adoption, pending/current original association, first-loss stop, finite recovery, credible restoration, once-only readiness and lifecycle/deadline fences. |
| `FollowMe/FollowReacquisitionDiagnostics.swift` (new), `Nav/NavigationController.swift`, `RotationDiagnosticModels.swift`, `FollowScanDiagnosticTrace.swift` | Controller-owned absolute segment resolution, provenance/pre-send/final-stop guards and immutable truthful correlated diagnostics. |
| `Tests/PhroverKitTests/FollowReacquisitionPlannerTests.swift`, `FollowReacquisitionDiagnosticsTests.swift` (new) | Public planner/episode and frozen diagnostic contract tests. |
| `FollowMeCoordinatorTests.swift`, `FollowReadyAdmissionIntegrationTests.swift`, `NavigationFollowScanDiagnosticsTests.swift` | Recovery/restoration/deadline/source/ownership/acknowledgement races, real controller/adapter and review safety matrices. |
| `FollowAssociationDiagnosticsTests.swift`, `FollowDiagnosticEventTests.swift`, `FollowPipelineDiagnosticsTests.swift`, `Support/FollowMeTestDoubles.swift` | Rejection/boundary/privacy/throttling evidence and deterministic ingress-clock suspension fixtures. |

Source map shorthand `FollowMe/` and `Nav/` means `Sources/PhroverKit/`; test shorthand means `Tests/PhroverKitTests/`.

### Exact assumptions and acceptance boundary

- Freeze the last healthy normal accepted observation's paired geometry at first loss, before suspension. Provisional recovery never replaces that anchor. One `firstLoss + 10 s` deadline includes stop latency, alignment, incomplete readiness and baseline wait; the independent two-second continuous-outage policy remains.
- Center is chosen once from a genuinely fresh same-generation post-stop position toward the remembered world point; only a valid paired historical yaw/bearing may substitute. Memory is an orientation hint, never fresh person authority or a forward goal. Missing provenance stays stationary.
- Absolute center offsets remain `[0, +15, −15, +30, −30, +45, −45]°`, one pass. Each real controller source boundary resolves at most 30° signed from actual yaw. Inclusive 7° measured arrival advances; interruption retains unfinished cursor and exhaustion stays stopped. Healthy source age must be finite, nonfuture and at most 0.500 s, with valid generation/health/ownership.
- Recovery clears only with confirmed scan stop, a distinct healthy fresh normal-continuity matched post-stop frame, and actual gated normal-phase restoration. Before departure, final alignment stop/new frame/inclusive 0.05-rad gate still apply. Attempt/success flags and the fixed baseline survive loss; consumed partial/failed/cancelled ready attempts never retry.
- Software recovery verification is complete; **physical reacquisition effectiveness is unverified**. Requested ≤30° segments and AR net yaw do not bound physical overshoot or cumulative coverage. Existing 0.25 m/s, 200 ms pulse wait, stop acknowledgement, 300 ms settle and 2.5 s / 0.05-rad watchdog were retained.
- **Ready-motion measured-progress failure remains separate and unfixed.** Passing synthetic ready-controller tests does not verify effective 10 cm movement, motor response or physical readiness. Coherent wrong depth, spatial association without identity, source/stop latency, overshoot and exhaustion of the ten-second budget remain documented limitations; none authorize a second pass, stale send, renewed deadline or ready retry.

## Three additional review findings — actual correction evidence (2026-10-03)

The user explicitly approved these fixes to the current uncommitted implementation. No new design gate or expanded refactor was introduced. Scope of this session: the coordinator, planner, navigation controller, their two coordinator/planner test files, and this existing plan. Base HEAD remains `0025527`.

### 1. Correctness first: authoritative restoration deadline

Added `FollowMeCoordinatorTests/testRecoveryRestorationRechecksDeadlineAtAtomicCommitWithoutTimerDelivery` before editing production. The public coordinator starts an episode with deadline 10, provisionally reacquires, and receives a healthy distinct normal-continuity frame at timestamp 9.8. A deterministic clock callback armed at that frame's association advances selected later reads from 9.999 to exactly 10 or 10.001; sleepers are never awakened. Thus timer scheduling cannot supply the expiry or hide an erroneous restoration.

Compiled behavioral RED: `lb7-deadline-red-valid-controller-before.xcresult` reports **71 passed / 1 failed / 0 skipped / 0 expected failures**. The 71 passing cases are the entire existing real-controller `NavigationFollowScanDiagnosticsTests` class, before maintenance. The coordinator fails with: `holdingDistance` is not equal to `failed("Person lost.")` — “Final validation at 10.0, read 5, must decide actual restoration.” The same test also exercises the final accepted-memory read at exact/beyond deadline and the healthy pre-deadline control. The earlier `lb7-deadline-red-controller-before.xcresult` failed compilation due to a missing `fields:` test-sink argument label (with cascading inference errors); it is **not behavioral RED evidence**. Production was unchanged until the compiled RED ran.

Minimum correction: `restoreRecovery` captures one final `validationTime` after preliminary eligibility, checks the retained episode's inclusive deadline, and calls `expireRecovery` with that same time on expiry rather than merely returning false. Only the expired branch suspends. Non-expired final health and accepted-memory validation reuse that timestamp; paired memory and the actual phase are assigned before any state-change diagnostic clock read. All callers await the helper, and clearance deferral respects its failure so terminal expiry cannot be overwritten by a normal state. The expired path retains episode/anchor evidence through the existing failure/stop cleanup. Original episode/timer clearing still happens only on successful restoration.

Same-selector GREEN: `lb7-deadline-green.xcresult` reports **1 passed / 0 failed / 0 skipped / 0 expected failures**. Final regression adds a diagnostic-read control: validation at 9.999 commits both memory/phase before the state-change diagnostic advances the clock to 10; that later diagnostic cannot retroactively invalidate successful restoration. Exact/beyond-deadline controls require one expired event, no cleared event, and the original `1:1` anchor/reliable memory. Healthy controls require one clear and no expiry.

### 2. Shared public pure absolute-stage segment resolver

`FollowReacquisitionPlanner.resolveAbsoluteStage(stageHeading:actualYaw:)` owns wrapped shortest signed error, inclusive 7° arrival, 30° cap, wrapped target and exact-π negative direction. `nextSegment` delegates to it after stage validation. The real controller calls it only with its freshly validated post-feedback sample where it previously duplicated this calculation; its once-resolved target remains frozen through pulses/corrections.

Added a direct public contract test with independently worked degree literals: both seam-crossing directions, ±180° ties, measured overshoot, a short final segment, an equivalent multi-turn heading, inclusive ±7°, 7.001° outside arrival, and nonfinite inputs. This is maintenance contract/retention coverage, **not a claimed new behavioral RED**. Existing actual-source, suspended-stop/feedback, frozen-target, opposite-sign correction, tolerance, source-age, deadline, cancellation, sticky-stop and watchdog controller tests passed before and after this extraction.

### 3. Immutable paired recovery stop boundary

Replaced independent optional frame/time fields with optional `RecoveryStopBoundary`, whose `frameID` and `time` are immutable. Detection stop completion captures one boundary value/time, uses that same time for the earlier deadline check, then assigns the complete value. Eligibility reads both facts from that value; initialization, restoration, repeated-loss and continuation-loss clearing sites clear it as a unit. Generation, episode identity and reacquiring-phase checks precede assignment, so a late old callback cannot populate a new episode's boundary. Existing suspended-stop/new-distinct-frame and old-session/episode callback regressions supply behavioral coverage without implementation-mirroring tests.

### Commands and final checkpoint

Every command ran from `/Users/hungmai/Sites/Astral/astral-sdk`. Verified the temporary parent with `ls`; `scripts/test-swift-sdk.sh --print-udid` returned the same iPhone 17 Pro / iOS Simulator 26.5 / `23F77` simulator. Exact shared arguments below describe the executed commands; invocations supplied these values directly and used fresh paths. No retry flags.

```bash
EVIDENCE=/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode
SIM_UDID=EEA52712-371D-4FF6-B8EF-A2C78319D57F
TEST_FLAGS=(-parallel-testing-enabled NO -test-timeouts-enabled YES
  -default-test-execution-time-allowance 60
  -maximum-test-execution-time-allowance 60)
METHOD=PhroverKitTests/FollowMeCoordinatorTests/testRecoveryRestorationRechecksDeadlineAtAtomicCommitWithoutTimerDelivery
# Compiled RED plus real-controller pre-maintenance retention:
xcodebuild test -quiet -scheme astral-sdk-Package -destination "id=$SIM_UDID" \
  "${TEST_FLAGS[@]}" -only-testing:"$METHOD" \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -resultBundlePath "$EVIDENCE/lb7-deadline-red-valid-controller-before.xcresult"
# Same-method GREEN, before the maintenance edits:
xcodebuild test -quiet -scheme astral-sdk-Package -destination "id=$SIM_UDID" \
  "${TEST_FLAGS[@]}" -only-testing:"$METHOD" \
  -resultBundlePath "$EVIDENCE/lb7-deadline-green.xcresult"
# Corrected focused checkpoint, delivered before the broad gates:
xcodebuild test -quiet -scheme astral-sdk-Package -destination "id=$SIM_UDID" \
  "${TEST_FLAGS[@]}" \
  -only-testing:PhroverKitTests/FollowReacquisitionPlannerTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  -resultBundlePath "$EVIDENCE/lb7-focused-corrected.xcresult"
scripts/test-swift-sdk.sh -quiet "${TEST_FLAGS[@]}" \
  -resultBundlePath "$EVIDENCE/lb7-sdk-final.xcresult"
xcodebuild test -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination "id=$SIM_UDID" \
  -only-testing:PhroverOperatorTests "${TEST_FLAGS[@]}" \
  -resultBundlePath "$EVIDENCE/lb7-app-final.xcresult"
xcodebuild build -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO -resultBundlePath "$EVIDENCE/lb7-build-final.xcresult"
```

Read each test bundle with `xcrun xcresulttool get test-results summary --path PATH`; read build status/warnings with `xcrun xcresulttool get build-results --path PATH`. Final source results:

| Bundle under `EVIDENCE` | Result | Passed | Failed / skipped / expected failures |
| --- | --- | ---: | --- |
| `lb7-focused-corrected.xcresult` | Passed | 236 | 0 / 0 / 0 |
| `lb7-sdk-final.xcresult` | Passed | 663 | 0 / 0 / 0 |
| `lb7-app-final.xcresult` | Passed | 33 | 0 / 0 / 0 |
| `lb7-build-final.xcresult` | succeeded | — | 0 build errors; 1 warning; 0 analyzer warnings |

`lb7-focused-final.xcresult` was an earlier **236 / 0 / 0** checkpoint. A subsequent code inspection caught the clearance caller ignoring restoration failure and the state's `didSet` reading the diagnostic clock before the paired-memory assignment. Corrected both within this same finding, then ran the fresh corrected focused gate above. It is the final checkpoint, not a reused earlier result. The full SDK includes the two new tests (663 rather than historical 661); focused tests are a subset, not additional unique tests.

The app tests/build report the existing `UIScreen.main` iOS 26 deprecation at `ConversationView.swift:273:58`; SDK commands emit the existing Xcode supported-platforms diagnostic. The latest incremental unsigned build reports only the one deprecation warning. `git diff --check` passed. All edits used `apply_patch`. Unrelated `.serena`, `.opencode`, `AGENTS.md` and `.superpowers` work was preserved. No commit, push, dependency installation or device operation occurred. No new independent review was performed; physical acceptance and ready-motion effectiveness remain unverified.
