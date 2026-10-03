# Latest-Observation Admission — Implementation Evidence

**Date:** 2026-10-02

**Approved scope:** `../specs/2026-10-02-follow-me-latest-admission-amendment.md`.

**Baseline:** `040eb15`; local changes only. Independent review is deferred as requested.

## Agreed seams and TDD

Used the existing public coordinator/state/events with the real `NavigationController`/`NavigationFollowMeMotion`, suspended acknowledgement, and manual clock; the router's existing ownership boundary; and the app view-model finalized-speech boundary. No fake generic admission was substituted for the production path.

SDK narrow commands ran from repository root:

```sh
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests/<method>
```

App narrow commands used `-project examples/PhroverOperator/PhroverOperator.xcodeproj -scheme PhroverOperator`, the same destination/serial/60-second flags, and `-only-testing:PhroverOperatorTests/ConversationViewModelTests/<method>`.

### Compiled assertion RED → GREEN slices

| Slice | Observed RED before its behavior change | Implemented minimum change / GREEN |
| --- | --- | --- |
| Original `testHealthyFramesArrivingBeforeFeedbackResumesCannotStarveReadyAdmission` | Prior reproduction: 3/3 repetitions produced zero commands and authorizations instead of one | Pure newest-pending evaluation, atomic accepted-observation preservation and one-entry processor handoff; exact selector green at 18:21 |
| `testUnsafeNewestPendingObservationNeverFallsBackToOlderGoodTrack` | At 18:22, incompatible generation and candidate frame remained `waitingForClearance` instead of `reacquiring`; other unsafe cases already blocked sends | Shared continuity generation/pairing fences; the unsafe selector passed in the 18:23 invocation |
| `testDifferentControllerARGenerationCannotAuthorizeLockedWorldPosition` diagnostic extension | At 18:25, expected `controller_source_generation_changed`, received nil | Preserve exact controller rejection condition; same selector green at 18:27 |
| Unsafe-pending diagnostic extension | At 18:25, synchronous rejected-decision event was absent | Emit immutable boundary rejection facts/candidate evidence before asynchronous result handling; same selector green at 18:27 |
| `testFinalizedReceiptOwnershipAndFullPauseUseOneMonotonicClock` | At 18:28, router/session/pause timing records were absent | Shared injected clock, optional timed start, classified receipt and lifecycle/phase timing; same selector green at 18:29 |
| App `testFinalizedSpeechPassesItsReceiptTimeBeforeAsynchronousRouting` | At 18:31, finalized text/time were nil and legacy submission occurred | Capture receipt before routing; production wiring shares the follow clock; same selector green at 18:32 |
| `testUnknownTrackingOnPendingFrameCannotAuthorizeOlderHealthyObservation` | At 18:33, missing batch tracking permitted a command, reported no issue, and emitted no rejection | Shared health rejects unknown tracking instead of treating absent metadata as normal; selector green in the full admission class at 18:34 |
| Exact health-condition diagnostics extension | At 18:35, typed camel-case/combined stale-or-invalid reasons did not distinguish the required exact conditions | Distinct unknown/limited/unavailable, stale/future/nonfinite, missing-pose/depth facts; green in the 18:35 affected exit |

**Eight assertion RED→GREEN slices including the previously executed reproduction; seven in this implementation task.** New methods relative to HEAD: **7 SDK + 1 app = 8** (the reproduction method already existed as uncommitted work at implementation start; this task adds 6 SDK + 1 app). Build errors in temporary scaffolding are not counted as RED evidence.

Preservation coverage includes 14 unsafe-pending variants plus a separate unknown-tracking case, exact 500 ms/0.05 rad gates, real post-ack controller provenance, full pause, Stop/new-session fencing, no uncertain/partial-signal retry, and final-stop/baseline behavior. Confidence stays 0.50; the 0.75 number is the world-distance gate.

The multiple-frame test processes earlier feedback-time frames, then queues the final pending frame before releasing acknowledgement. Its first draft released feedback with two upstream stream entries still queued; the controller could correctly see the first ingested close frame before the second entry arrived. The corrected fixture distinguishes newest **ingested** data from unread stream data. This fixture correction is not counted as a production-defect RED slice.

The strengthened accepted-pending case contains people at 2.3 and 2.6 m against the original 1.7 m lock. Only 2.3 matches the unchanged 0.75 m gate. Reassociating the raw frame against the adopted 2.3 m lock would wrongly produce ambiguity. The saved original decision survives raw-frame processing, and a subsequent 3.0 m observation continues from the adopted track. The same raw frame cannot establish a post-stop baseline.

The original starvation test now asserts successful public command/authorization outcome and captured authorized geometry; it does not require healthy attempts to remain deferred. No assertions were skipped or made expected failures.

## Final software validation

All final runs used one iteration, no retries, serial execution, and per-test **60 s** timeout. Each command completed within a 120 s tool timeout. Simulator: iPhone 17 Pro / iOS 26.5, `EEA52712-371D-4FF6-B8EF-A2C78319D57F`.

| Gate | Passed | Failed | Skipped | Evidence |
| --- | ---: | ---: | ---: | --- |
| All 17 affected/preservation SDK classes | 293 | 0 | 0 | `ready-snapshot-affected-20261002.xcresult` |
| Full SDK: PhroverKitTests + RoverNavTests | 598 | 0 | 0 | `ready-snapshot-sdk-20261002.xcresult` |
| All app unit tests | 33 | 0 | 0 | `ready-snapshot-app-20261002.xcresult` |
| Debug unsigned iOS app build | passed | — | — | Completed `xcodebuild build ... CODE_SIGNING_ALLOWED=NO -quiet` |

Result bundles are in `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/`; actual counts/status were checked with `xcrun xcresulttool get test-results summary --path <bundle>`. **631 distinct full-suite tests** passed, with 293 additional affected-class executions. Calibration was included in the full SDK gate and did not fail or require a retry. Final affected exit also verifies all preceding narrow GREEN slices against the final tree.

Affected class selectors: `NavigationFollowScanDiagnosticsTests`, `NavigationRotationWatchdogTests`, `NavigationSilentSearchMotionTests`, `NavigationFollowReadySignalTests`, `RoverControlTests`, `ARSessionManagerTests`, `FollowDiagnosticEventTests`, `FollowPersonProjectionTests`, `ARFollowMePerceptionSourceTests`, `FollowTargetTrackerTests`, `FollowMeCoordinatorTests`, `FollowReadyAdmissionIntegrationTests`, `FollowMotionFailureResolutionTests`, `FollowPipelineDiagnosticsTests`, `FollowAssociationDiagnosticsTests`, `DetectorTests`, and `OperatorCommandRouterTests` (each under `PhroverKitTests`).

Full gate commands:

```sh
SIM_UDID=EEA52712-371D-4FF6-B8EF-A2C78319D57F scripts/test-swift-sdk.sh -quiet \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath '/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/ready-snapshot-sdk-20261002.xcresult'
xcodebuild test -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverOperatorTests -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath '/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/ready-snapshot-app-20261002.xcresult'
xcodebuild build -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

Use fresh result-bundle paths when rerunning. SDK final runs emitted the existing empty-supported-platforms Xcode diagnostic. App testing/build emitted the existing `UIScreen.main` deprecation, and the unsigned build also emitted the existing launch-configuration warning. No test failure was hidden or retried.

## File map and boundaries

- New `swift/Sources/PhroverKit/FollowMe/FollowAdmissionSnapshot.swift`: pure health and latest-observation evaluation.
- `FollowMeCoordinator.swift`: accepted snapshot handoff/deduplication, exact boundary conditions, session/pause/phase facts.
- `FollowReadyAdmission.swift`: captured observation snapshot and rejection condition beside existing controller sample facts.
- `FollowTargetTracker.swift`: continuity generation/candidate-frame fences; numerical association thresholds unchanged.
- `OperatorCommandRouter.swift`: receipt/ownership/start diagnostics and optional internal timed-start companion.
- `swift/Tests/PhroverKitTests/FollowReadyAdmissionIntegrationTests.swift`: real-path regression/preservation cases and narrowly extended fixtures.
- App `ConversationViewModel.swift`, `ConversationView.swift`, and `ConversationViewModelTests.swift`: finalized-text receipt seam and shared-clock wiring.
- This evidence document and the new amendment; prior specifications/workflow assets remain historical records.

`git diff --check` passed. Unrelated `.serena/project.yml`, `.opencode/`, `AGENTS.md`, and `.superpowers` assets were preserved. No commit, push, installation, physical device execution, or physical motion was performed.

**Remaining risks:** independent review is pending; simulator coverage cannot establish physical motion/braking or actual scene projection reliability. The extra boundary event carries the exact decision even if later asynchronous operation delivery is fenced. Unsafe pending observations still correctly prevent readiness; legacy controller samples retain unknown provenance rather than being labeled fresh enriched samples.
