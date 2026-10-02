# Follow-Me Stationary Pause, Alignment, and Departure Amendment

**Date:** 2026-10-01
**Status:** User-confirmed requirements; implemented with coordinator and view-model regression coverage.

This amendment supersedes the startup-readiness-only and immediate-follow behavior in
`2026-10-01-follow-me-frame-coalescing-design.md` and the acquisition/follow portions of
`2026-09-29-follow-me-design.md`. The approved originals and historical plans remain intact.
The voice-only amendment still applies: hold the microphone, say **“follow me”**, then
release it. Stop Following and finalized spoken stop commands remain available.

## Required production sequence

1. After the command router has handed off stationary motion ownership, enter `pausing`
   for the **full five seconds** (`stationaryPauseSeconds`, default 5). Healthy perception
   does not shorten this interval. Ingest and process frames and diagnostic changes
   throughout the pause; do not issue scan, alignment, or translation commands.
2. At pause completion enter `searching`. Revalidate the most recent pause frame against
   the current clock before using it. An expired pause observation cannot initiate motion.
3. Select an eligible person immediately when observed. Otherwise search in safe pulsed
   scan increments, cumulatively bounded by at most one 360° round. Cap the last increment
   when the configured increment does not divide the round. Stop searching **as soon as
   a person is found**; never finish the round after detection. Exhaustion fails with
   `No person found.` and confirms stopping.
4. Enter `aligning`, confirm motor stop, and turn toward the selected person. The world
   heading is `atan2(person.y - rover.y, person.x - rover.x)`; the relative turn is that
   heading minus pose yaw, normalized to the shortest signed angle. The narrow motion
   API `alignTowardPerson(by:)` delegates to
   `NavigationController.rotateForFollowAlignment(by:)`, a continuous turn with the
   same serialized throwing confirmed-stop path and failed-stop latch as follow scan.
   Confirm motor stop after alignment, including a cancelled turn. Navigation failure
   uses terminal confirmed-stop cleanup. Alignment runs as a separately fenced task;
   the frame processor does not await the whole turn.
5. Continue associating the same person throughout alignment. Arrival alone does not
   certify heading. Require another fresh, healthy, matched observation after the final
   stop confirmation, with timestamp at or after confirmation and heading error no more
   than `alignmentAngularTolerance` (default 0.05 rad, matching continuous navigation
   rotation tolerance). A delayed in-turn frame cannot establish the baseline. Correct
   a remaining heading error with another stopped/bracketed alignment.
6. Enter `waitingForMovement` and establish the person's range from that post-alignment
   rover pose as a **fixed baseline**. Remain stationary regardless of how far away the
   stationary person is. Neither toward motion nor lateral movement at unchanged range
   triggers following. Begin following only when matched range is at least
   `baseline + departureRangeIncrease` (default **0.30 m**, inclusive). Do not slide the
   baseline as observations change; a 0.299 m increase still holds.
7. After departure, reuse the existing approximately 1.5 m stand-off, 1.25–1.75 m hold
   band, goal update limits, navigation clearance, and no-reverse behavior.

## Readiness and freshness policy

The mandatory pause and startup readiness are separate policies. The five-second
`startupReadinessSeconds` window begins **at pause end**, so a production session that
never receives a usable healthy frame fails at **10 seconds from start**. Frames during
the pause update diagnostics; readiness is evaluated at pause completion using a still
fresh cached frame or a subsequently delivered healthy frame. Startup does not begin
the two-second outage policy before readiness. A frame arriving at the readiness
deadline cannot rescue the session merely by beating the timeout task's scheduling.

After readiness, retain the inclusive 500 ms observation-age limit, timestamp-based
watchdog, two-second continuous-outage deadline, and one confirmed stop per outage
(terminal cleanup additionally confirms stopping). A delayed stop acknowledgement
cannot authorize alignment or translation from an expired observation.

## Target loss and cancellation

Loss or ambiguity while aligning or waiting enters the existing bounded reacquisition
policy and confirms stopping before scanning. Reacquisition before departure returns
through alignment, not directly to translation. If a baseline already exists, preserve
it through loss, reacquisition, and realignment; if loss preceded a valid baseline,
establish one only after reacquired alignment is confirmed. Once departure has occurred,
ordinary downstream reacquisition resumes existing follow control.

Newest-pending-frame coalescing, immediate interruption/failure handling, generation and
operation fencing, safety failures, and failed-stop blocking remain authoritative.
Alignment has an additional operation identity so an old turn cannot clear or resume
a newer turn or generation. Stop/background/leave-Talk cancel and fence work in every
active phase.

## Operator-facing phases

All three added phases are active and keep Stop Following available:

| Phase | Status |
| --- | --- |
| `pausing` | `Pausing — five seconds` |
| `aligning` | `Aligning toward you…` |
| `waitingForMovement` | `Ready — walk away to begin following` |

## Automated verification

Approved seams: public `FollowMeCoordinator` behavior with motion/perception doubles
and a manual clock, plus `ConversationViewModel` status and stop behavior.

Production-default regressions exercise the full pause, early scan termination,
normalized heading from a nonzero rover position/yaw, asynchronous alignment, fresh
post-stop baseline, stationary/toward/lateral hold, inclusive departure threshold,
one-round scan bound, reacquisition baseline retention, and ten-second startup limit.
Preservation coverage includes stop during pause/alignment/waiting, old-generation
completion, outdated motor acknowledgement, target continuity, and the two-second
one-stop outage policy. Existing tests that intentionally exercise downstream legacy
follow/readiness behavior explicitly opt out with zero pause and departure increase;
production-default sequence tests do not use these overrides.

Each implementation slice was preceded by a failing simulator test run and followed
by a passing repeat. The red–green slices were:

- `testProductionPauseProcessesPerceptionButNeverMovesBeforeFiveSeconds`
- `testProductionDetectionStopsScanImmediatelyAndAlignsWithoutBlockingFrames`
- `testProductionSequenceRequiresFreshAlignedBaselineAndPointThreeRangeDeparture`
- `testLossBeforeDepartureReacquiresAndRetainsFixedBaseline` and
  `testStopDuringAlignmentAllowsNewGenerationToAlignBeforeOldTurnCompletes`
- `testBaselineRejectsDelayedPreCompletionFrameAndIncorrectHeading`
- `testProductionSearchNeverExceedsOneRoundEvenWithNonDividingScanIncrement`
- `testCancelledAlignmentStillConfirmsStopAndCannotEstablishBaseline`
- `testHealthyFrameAtReadinessDeadlineCannotBeatTimeoutTask`
- App: `testStationaryAcquisitionPhasesExplainBehaviorAndKeepStopAvailable`

SDK focused command template (repository root):

```sh
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests/<test-name> -quiet
```

The first pause red run used `./scripts/test-swift-sdk.sh -quiet` with that test selector;
subsequent targeted cycles used direct `xcodebuild` selectors to isolate the slice.
App cycles use `-project PhroverOperator.xcodeproj -scheme PhroverOperator` from
`examples/PhroverOperator`, selecting the view-model test under `PhroverOperatorTests`.
One parallel SDK green attempt failed because the simulator test daemon was shut down;
the sequential repeat passed. Simulator suites are subsequently run sequentially.

Initial verification on 2026-10-01, before the review corrections below:

| Check | Command / result |
| --- | --- |
| Focused follow coverage | Direct SDK `xcodebuild test` selecting `FollowMeCoordinatorTests`, `FollowTargetTrackerTests`, `ARFollowMePerceptionSourceTests`, and `OperatorCommandRouterTests`: passed. |
| Full SDK | `./scripts/test-swift-sdk.sh` (nonquiet, 900-second timeout): **404 tests passed**, 385 PhroverKit + 19 RoverNav, zero failures. Includes all 55 coordinator tests. |
| App view model | `xcodebuild test -project PhroverOperator.xcodeproj -scheme PhroverOperator -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' -only-testing:PhroverOperatorTests/ConversationViewModelTests`: **7 passed**. |
| Generic device build | `xcodebuild build -project PhroverOperator.xcodeproj -scheme PhroverOperator -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet`: succeeded. |
| Whitespace | `git diff --check`: passed. |

App commands ran from `examples/PhroverOperator`. Build warnings were the existing
`UIScreen.main` deprecation in `ConversationView.swift:271`, missing launch configuration
for non-full-screen support, and skipped AppIntents metadata extraction because no
AppIntents framework dependency exists. No follow implementation compiler warning
remained. The device build was unsigned; simulator app tests used the Xcode test runner.

Result bundles in Xcode DerivedData:

- SDK: `astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.01_18-38-28--0700.xcresult`
- App: `PhroverOperator-fddpasjqbvmpvydqermesnrnjsro/Logs/Test/Test-PhroverOperator-2026.10.01_18-39-07--0700.xcresult`

## Read-only review corrections and TDD evidence

Two subsequent review findings were reproduced and corrected separately using
`apply_patch`, with each test run failing before its production change and the exact
same command passing afterward:

1. **Internal preturn stop failure:** the previous adapter called `rotateAndWait`,
   whose `cancelAndWait` ignored `stopRover` errors. A successful coordinator pre-stop
   therefore did not prevent a newer internal failed stop from being followed by wheel
   motion. `rotateForFollowAlignment` now uses the serialized throwing `confirmStop`
   path before and after a continuous turn, checks the failed-stop latch before motion,
   and fences operation completion exactly as `rotateForFollowScan` does. Regression
   coverage uses the real `NavigationController` through `NavigationFollowMeMotion`:
   the external pre-stop succeeds, the internal preturn stop fails, no nonzero wheel
   command is sent, failure is published, and subsequent alignment stays blocked.
2. **Alignment starvation during stop acknowledgement:** the previous task captured
   a selected frame before awaiting stop and rejected it whenever newer frames arrived.
   Healthy frame association now continues during alignment-owned pre/post-stop waits.
   After acknowledgement, any newest pending frame passes through the normal processor;
   alignment then uses the newest fresh, healthy, still-matched person and pose from
   that same snapshot. Generation and alignment identities remain fenced, and the
   500 ms expiry is unchanged. The regression sends matched frames every 100 ms during
   a 200 ms acknowledgement, verifies the newest snapshot's heading, then continues
   arrivals across the post-turn stop and reaches `waitingForMovement` without translation.

From the repository root, the exact red–green commands were:

```sh
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests/testFollowAlignmentFailsClosedWhenInternalPreturnStopFailsAfterCoordinatorStopSucceeded \
  -quiet

xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests/testAlignmentProgressesWithNewMatchedFramesDuringEveryStopAcknowledgement \
  -quiet
```

Review-correction verification:

- Affected suites passed: `NavigationRotationWatchdogTests`, `NavigationPathPolicyTests`,
  `NavigationSafetyTests`, `FollowMeCoordinatorTests`, `FollowTargetTrackerTests`,
  `ARFollowMePerceptionSourceTests`, and `OperatorCommandRouterTests`.
- `ConversationViewModelTests`: all **7 passed**, using the app command above with `-quiet`.
- Generic device build: succeeded with the command above. The existing `UIScreen.main`
  deprecation warning remains. `git diff --check` passed.
- Full SDK script was rerun nonquiet. The unmodified command hit its 900-second harness
  timeout in the unchanged calibration test
  `testThirdAcceptedSampleEmitsContextualProgressBeforeAcceptance` (which yields only
  once between frames and awaits three accepted samples from a coalescing stream).
- Repeating with `-test-timeouts-enabled YES -default-test-execution-time-allowance 120
  -maximum-test-execution-time-allowance 120` completed the suite but failed on that
  test's execution timeout. The follow/navigation suites passed in that run.
- A serial full repeat with `-parallel-testing-enabled NO -test-timeouts-enabled YES
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`
  completed **406 tests**: **404 passed; 2 failed**. The failures were unchanged
  `ARSharedMissionFrameCalibratorTests.testSuccessfulEmptyScanClearsScannerFailureOnce`
  (line 480) and `testSuccessfulEmptyScanClearsWrongMarkerFailureOnce` (line 572): each
  observed an additional third-frame `scanCompleted` event absent from its expected
  array. The earlier third-sample test passed in this serial run. All 56 coordinator
  tests, navigation tests, and 19 RoverNav tests passed. Calibration code/tests were
  not modified as part of these two review corrections.

Full-suite result bundles for the correction runs:

- Timeout-enabled failure: `astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.01_19-12-05--0700.xcresult`
- Completed serial run: `astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.01_19-17-46--0700.xcresult`

## Updated physical acceptance (not executed in this implementation session)

The following sequence replaces the startup/departure steps of the older device
acceptance document. Physical calibration and motor behavior remain unverified here.

1. Finalize spoken “follow me”; verify a full five stationary seconds even with healthy
   AR frames and a person already visible. Confirm live perception diagnostics continue.
2. Verify a rear-camera pulsed search stops immediately on finding the person, or fails
   after at most one 360° round. Verify alignment faces that person and ends stopped.
3. Stand still, including outside 1.75 m range: verify no translation. Move laterally at
   unchanged range or toward the rover: verify it continues holding. Increase range by
   at least 0.30 m: verify following starts and maintains approximately 1.5 m stand-off.
4. Introduce another person and briefly occlude the selected person before departure.
   Verify conservative continuity, bounded reacquisition, realignment, and preservation
   of the original departure gate rather than immediate approach.
5. Exercise Stop Following, finalized spoken stop, leave-Talk, backgrounding, perception
   outage, and navigation failure in each new phase. Confirm acknowledged motor stop
   and no old callback restarting motion.

No device installation, interactive app launch, or rover movement was performed.
