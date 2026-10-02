# Follow-Me Slow Search, One Ready Signal, and Local Stop Amendment

Date: 2026-10-01 (device log timestamps below are UTC on 2026-10-02).
Base: `832e9de`. This amends the acquisition/departure sequence in
`2026-10-01-follow-me-stationary-departure-amendment.md`; previous evidence and specs
remain historical records.

## Latest device-log evidence

Read-only source:
`/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-iphone15pro-ready-signal-retry-20261001.log`,
latest session beginning after line 268586. Earlier sessions in this appended log
were not used to infer this run's outcome.

| UTC | Evidence | Interpretation |
| --- | --- | --- |
| 02:33:41–46 | `pausing`, then `searching`/`aligning`, lines 269696–269813 | The mandatory five-second pause occurred. |
| 02:33:48 | `waitingForMovement`, frame 1:1486, age 0.19085 s, normal tracking, depth and pose available, line 269855 | Alignment reached the old ready/waiting state. This was not evidence of a 10 cm signal; that path did not exist at the base revision. |
| 02:34:01 | `reacquiring`, frame 1:2295, age 0.21566 s, normal tracking and available pose/depth, line 270150 | The first target loss was on healthy perception. The log does not distinguish no association from ambiguity or identify which projection/association gate rejected it. Do not weaken tracking thresholds based on this evidence. |
| 02:34:02–39 | Repeated alignment/reacquisition, later stale-frame outages | Subsequent freshness problems are distinct from the initial healthy-frame target loss. |
| 02:34:40 | Scan command ±0.25 m/s, stale age 0.534 s, cancelled `T:0` stop, navigation safety failure, then successful `T:0` replies and `transport_failed`, lines 271015–271033 | A cancelled pulse stop could publish failure despite an independent acknowledged stop. Cancellation alone does not prove stopped motors; the independent acknowledgement remains authoritative. |

The generic rotation command applies a 0.25 m/s minimum. Search uses 80 ms pulses
and 300 ms settling. The reported roughly 36°/s sweep is physical observation,
not a guaranteed rate derivable from those timing constants or HTTP command units.

## Updated production sequence

1. Retain the complete five-second stationary pause. Healthy perception cannot shorten it.
2. Search with a follow-only slow pulsed rotation profile. The requested initial scan
   budget remains at most 2π, with a shortened final increment. A detected eligible
   person immediately cancels/fences scanning and requests confirmed stop before alignment.
3. Align and confirm stop. Require a fresh matched frame after alignment confirmation
   with heading error at most 0.05 rad. Track association continues during alignment.
4. Enter active `signalingReady` and attempt **one** forward ready signal per session.
   `FollowMeMotion.signalReady()` delegates to
   `NavigationController.navigateForFollowReadySignal()` through the existing adapter.
   The coordinator never issues timed wheel commands.
5. On successful motion, confirm motor stop again. Remain in `signalingReady` until a
   new fresh, healthy, same-track frame, timestamped at or after final confirmation,
   establishes the **post-signal** fixed range baseline. Then enter `waitingForMovement`.
6. Remain stationary until matched range increases by at least 0.30 m over that baseline.
   Retain normal stand-off following, hold band, goal replacement limits, and no reverse.
7. Successful signal and established baseline survive loss/reacquisition/realignment;
   do not repeat the signal. If loss occurs after signal confirmation but before the
   baseline, establish it after fresh reacquired alignment without a second move.

Loss/ambiguity during the signal cancels it and confirms stop. Reacquisition cannot
retry an interrupted move or declare readiness: it fails with restart guidance.
An unsuccessful/cancelled signal also fails with actionable restart guidance. A stale
frame cancels signal motion, retains the existing two-second recovery policy, and
cannot resume the partial signal. Stop, background/leave-Talk, safety failure, and old
operation completions remain fenced. Failed stop confirmations block new motion.

## Follow-only motion limits

These are narrow controller profiles; generic pursuit and rotation tuning are unchanged.

| Profile | Limits |
| --- | --- |
| Follow scan | Wheel magnitude `min(0.10, abs(yawError) * 0.3)` m/s; bypass generic minimum-speed floor; existing 80 ms pulse / 300 ms settle cadence and scan yaw tolerance; existing 2.5 s / 0.05 rad progress watchdog. |
| Ready signal | Forward goal 0.10 m from confirmed-start pose; arrival from 0.08 m measured forward progress (2 cm tolerance); wheel cap 0.05 m/s, proportional slowing without minimum-speed floor; no backward/turn command. |
| Ready travel bounds | Stop/fail on measured displacement over 0.12 m, backward progress below −0.02 m, lateral displacement over 0.02 m, or heading drift over 0.10 rad; 2.5 s / 0.01 m progress watchdog and five-second total loop deadline. |
| Ready path safety | Require an available nonempty plan and a clear actual swept segment in the inflated costmap; reject every touched occupied/inflated cell. Do not apply measured travel tolerances to quantized A* cell-center waypoints (see review correction below). |
| Ready obstacle/link safety | Require finite forward clearance; use unchanged 0.45 m obstacle guard; require a present, nonfuture command acknowledgement within the existing comms watchdog before every command, including the first. Pose must be present and finite. |
| Person clearance | Require at least `minimumHoldDistance + 0.12` (default 1.37 m) before starting; matched approach inside that conservative margin during the move aborts it. |
| Perception | Unchanged inclusive 500 ms observation freshness, timestamp-based watchdog, two-second outage recovery, and confirmed-stop blocking. |

The existing navigation transport exposes command acknowledgements, not wheel encoder
odometry or a live IMU feedback provider. Travel is measured from ARKit visual-inertial
pose. This path uses that existing feedback boundary; it does not claim measured wheel
distance or new IMU tipping coverage (`ObstacleGuard` receives nil chassis feedback,
as in existing navigation). The coordinator's perception watchdog provides freshness
fencing while the controller's pose/progress checks bound stalled or missing pose.

Physical calibration remains necessary: a 0.10 m/s search command or 0.05 m/s forward
command may be below breakaway speed on a particular surface. In that case the bounded
watchdogs fail closed. Observed travel limits cannot eliminate pose error, inertia,
command latency, or braking overshoot. No physical rate or exact 10 cm travel is claimed
from simulator results. Unsafe/unplannable short motion fails; it is never bypassed.

## Local Stop and UI ownership

`OperatorCommandKind.classify` shares the router's existing case/space/punctuation
normalization with the app. `localStop` goes directly to router stop, never to
`mission.handle` or a brain fallback. The router reserves stopping ownership and calls
`inhibitMotion()` synchronously before creating/awaiting stop work. New mission requests
are rejected until confirmed stop; success returns ownership to idle, failure blocks it.

`ConversationViewModel` owns the displayed mission phase. Local stop and the stop button
set idle and inhibit immediately, suppress stale mission callbacks, and clear errors
on acceptance. Local follow also avoids Thinking. Ordinary missions retain Thinking.
`ConversationView` no longer sets Thinking before classification; speech recognition
processing displays `Processing speech…`. The ready-signal status is
`Signaling ready — moving 10 cm…`, with Stop Following available.

## TDD and verification

Agreed seams: public coordinator, real navigation controller/adapter, router, and app
view model. Changes used `apply_patch`. Each implementation behavior had a red test
run before its production edit, then a passing run:

- Slow wheels: `NavigationRotationWatchdogTests/testFollowScanUsesSlowWheelsWithoutGenericMinimumFloor`.
- Pulse cancellation: `NavigationRotationWatchdogTests/testCancelledPulseStopIsSafeOnlyAfterIndependentConfirmedStop`.
- Actual short motion/safety: `NavigationFollowReadySignalTests` (initial red was the missing API compile failure).
- One signal/fresh baseline: `FollowMeCoordinatorTests/testReadySignalOnceThenFreshPostStopBaselineBeforeWaiting`.
- Loss after confirmed signal but before baseline: `FollowMeCoordinatorTests/testLossAfterSignalStopBeforeBaselineReacquiresWithoutSecondMoveAndCanDepart`.
- Immediate local fencing: `OperatorCommandRouterTests/testNormalizedLocalStopFencesFollowAndBlocksNewMissionUntilConfirmed`.
- UI reset/no Thinking: `ConversationViewModelTests/testLocalStopNeverThinksAndResetsUIBeforeAndAfterAcknowledgement` (initial red was missing view-model phase API).
- Required acknowledgement before motion: `NavigationFollowReadySignalTests/testReadySignalRequiresFreshCommandFeedbackEvenBeforeFirstMove`.
- Person-clearance checks: coordinator `testTooClosePersonCannotAuthorizeReadySignalAcrossHoldClearance` and `testPersonApproachingDuringReadySignalCancelsBeforeHoldClearanceIsCrossed`.
- Stop during final ready acknowledgement: `NavigationFollowReadySignalTests/testStopDuringFinalReadyAcknowledgementCannotReturnArrival`.

SDK red/green command template, repository root (replace selector with the entries above):

```sh
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/<suite>/<test> -quiet
```

App red/green uses the same destination, from `examples/PhroverOperator`, with
`-project PhroverOperator.xcodeproj -scheme PhroverOperator` and
`-only-testing:PhroverOperatorTests/ConversationViewModelTests`.

Additional passing regressions cover unsuccessful/cancelled/stale/operator-stopped
signals, loss during signal, actual controller send cancellation, failed independent
stops, baseline retention through reacquisition, and existing generic rotation tuning.
Historical production-sequence tests now supply the additional post-signal baseline
frame; they do not disable the production ready signal.

Verification commands:

```sh
# Repository root: full non-live SDK suite
./scripts/test-swift-sdk.sh -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 -quiet

# examples/PhroverOperator: all app unit tests and unsigned device build
xcodebuild test -project PhroverOperator.xcodeproj -scheme PhroverOperator \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverOperatorTests -parallel-testing-enabled NO -quiet
xcodebuild build -project PhroverOperator.xcodeproj -scheme PhroverOperator \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
```

Initial verification, before the three review corrections below:

Focused affected SDK suites: **139 passed** before the final-acknowledgement regression.
Final full SDK: **420 passed**, zero failed/skipped. The previously documented unrelated
calibration failures did not reproduce in these serial runs; no calibration fixes were made.
All app unit tests: **28 passed**, including eight conversation-view-model tests.
Generic unsigned iOS build succeeded. Existing `UIScreen.main` deprecation and launch
configuration warnings appeared in the initial build. Whitespace check passed.

Result bundles under `~/Library/Developer/Xcode/DerivedData`:

- SDK: `astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.01_20-06-05--0700.xcresult`.
- App: `PhroverOperator-fddpasjqbvmpvydqermesnrnjsro/Logs/Test/Test-PhroverOperator-2026.10.01_20-06-36--0700.xcresult`.

Verification used simulator test runners and an unsigned build only. No physical-device
installation, interactive app launch, rover movement, commit, or push was performed.

## Changed files

- `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift`
- `swift/Sources/PhroverKit/FollowMe/FollowMeDependencies.swift`
- `swift/Sources/PhroverKit/FollowMe/NavigationFollowMeMotion.swift`
- `swift/Sources/PhroverKit/FollowMe/OperatorCommandRouter.swift`
- `swift/Sources/PhroverKit/Nav/NavigationController.swift`
- `swift/Sources/PhroverKit/Voice/MissionAgent.swift`
- `swift/Sources/RoverNav/Costmap.swift`
- `examples/PhroverOperator/PhroverOperator/App/ConversationViewModel.swift`
- `examples/PhroverOperator/PhroverOperator/Views/ConversationView.swift`
- `swift/Tests/PhroverKitTests/FollowMeCoordinatorTests.swift`
- `swift/Tests/PhroverKitTests/NavigationFollowReadySignalTests.swift`
- `swift/Tests/PhroverKitTests/MissionAgentTests.swift`
- `swift/Tests/PhroverKitTests/NavigationRotationWatchdogTests.swift`
- `swift/Tests/PhroverKitTests/OperatorCommandRouterTests.swift`
- `swift/Tests/PhroverKitTests/Support/FollowMeTestDoubles.swift`
- `examples/PhroverOperator/PhroverOperatorTests/ConversationViewModelTests.swift`
- `docs/superpowers/specs/2026-10-01-follow-me-ready-signal-amendment.md`

Pre-existing `.serena/project.yml`, `.opencode/`, and `AGENTS.md` work was preserved.
Existing `.superpowers` workflow assets and previous specifications were preserved.

## Three review corrections: red-run evidence and current verification

Each correction was reproduced with an executed failing regression before its production
patch, then verified green. No commits, device deployment, or physical motion occurred.

### 1. Grid quantization versus measured travel bounds (high)

The initial ready path compared A* waypoints against the rover's 2 cm lateral and
12 cm forward measured-motion bounds. On the production 10 cm grid with origin
`(-6, -6)`, the start cell center is `(0.05, 0.05)`; even open floor could fail at
heading zero. Other cardinal and oblique headings also reproduced rejection.

The production controller now obtains an inflated costmap for ready-path validation.
`Costmap.isSegmentClear(from:to:margin:)` checks the actual straight segment using
segment/expanded-cell intersection, including cell boundaries and out-of-bounds
rejection. It rejects any touched nonzero cost, conservatively including soft inflation,
not only lethal cells. The checked envelope extends 12 cm forward with 2 cm margin,
matching the existing measured travel/deviation bounds. It does not follow a planner
detour. A nonempty A* plan is still required; the exact-path injected seam without a
costmap retains its fail-closed exact waypoint checks.

Regressions use the actual `AStarPlanner` and 10 cm `Costmap`, not `[goal]` alone:

- Open floor: yaw 0, ±π/2, π, π/4, and −π/3 succeeds and emits a low-speed forward command.
- Occupied start, soft inflation, and diagonal corner contact reject motion despite
  clear forward LiDAR. Fixtures also assert that A* can find a route, showing why
  a route/detour alone does not authorize this straight short move.
- The occupied-start fixture uses `(0.05, 0.05)` so the goal is unambiguously in the
  next cell. An intermediate assertion failed at the grid boundary `(0, 0)` because
  floating-point conversion put the 10 cm goal in the occupied start cell; correcting
  that fixture required no production change.

The real-planner open-floor selector failed at **20:12:09 local**, before the controller
and costmap edits; the ready-motion, Costmap, and A* suites passed at **20:13:31**.

### 2. Old mission phase callbacks after Stop and a new mission (medium)

The UI's `acceptsMissionPhase` boolean cannot identify an old callback once a new
ordinary mission enables callbacks again. Stop waits for motor acknowledgement, not
for an old brain request to finish. Old generation-mismatch paths previously assigned
`phase = .idle`, overwriting the new mission's Thinking phase.

All mission-owned phase mutations now pass through source-side
`MissionAgent.setPhase(_:missionID:)`, which compares the emitting mission with
`missionGeneration` before changing the observable phase or invoking `phaseDidChange`.
The acknowledged-stop path continues to publish its own current generation's idle.
Current mission completion also continues to publish acting then idle.

The regression suspends the first brain, acknowledges Stop, starts/suspends the second
mission, then releases the first. It asserts no phase mutation and no callback from
the old mission. Releasing the second must still publish its valid idle. This failed
at **20:14:44** before the source fence, and passed at **20:15:40**, together with the
direct-cancellation regression. An additional app regression wires a real MissionAgent
callback into ConversationViewModel and verifies the same sequence through local Stop
and finalized ordinary speech.

### 3. Acknowledgement getter suspension and safety sampling (medium)

The old loop captured time, pose, and clearance before awaiting the actor-backed
acknowledgement getter. A legitimate acknowledgement written during that suspension
could look like it came from the future; safety samples could also be out of date.

The loop now awaits the getter first, gates cancellation immediately, then samples
`now()`, pose, and forward clearance synchronously before checking acknowledgement age
and commanding wheels. Legitimately fresh acknowledgements obtained during suspension
are accepted. Truly future, stale, and absent acknowledgements remain rejected.
Measured travel, pose, obstacle, stall, and operation-generation gates are retained.

The controlled async getter yields and advances time, returns fresh/future/stale
acknowledgements, and changes pose/clearance during suspension. The regression verifies
arrival for fresh feedback and zero commands for future/stale feedback, a new obstacle,
and measured overshoot. It failed at **20:16:27** before the sampling reorder and passed
at **20:17:08**. Additional coverage stops while the getter is suspended and proves
zero wheel commands after cancellation.

### Exact red–green command selectors

All three use the repository-root command below, substituting each full selector:

```sh
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/<selector> -quiet
```

1. `NavigationFollowReadySignalTests/testRealPlannerReadySignalAcceptsOpenFloorCardinalAndObliqueHeadings`
2. `MissionAgentTests/testOldBrainCompletionAfterConfirmedStopCannotOverwriteNewMissionPhase`
3. `NavigationFollowReadySignalTests/testAsyncAckGetterUsesPostAwaitClockPoseAndClearance`

The first green run selected the entire ready-motion suite plus Costmap/A* suites;
the second also selected direct cancellation. The third repeated the exact red selector.

### Current verification results

| Check | Result |
| --- | --- |
| Affected SDK suites, 20:19:14 | **178 passed**, zero failures/skips. Includes ready motion, rotation watchdog, navigation safety/path policy, follow coordinator/router, mission agent/cognition, Costmap/A*. |
| Full non-live SDK suite, 20:21:48 | **425 passed**, zero failures/skips. Serial run with 60 s per-test allowance, using the full-suite command above. No previously documented calibration failure reproduced; no calibration changes were made. |
| All app unit tests, 20:21:32 | **29 passed**, zero failures/skips, including the real-agent/view-model callback regression and valid current idle. |
| Generic unsigned iOS build | Passed using the build command above; existing UIScreen.main deprecation warning remains. |
| Whitespace | `git diff --check` passed. |

Two earlier app attempts failed before test execution with simulator preflight `Busy`.
The destination was subsequently found shut down; `xcrun simctl bootstatus
EEA52712-371D-4FF6-B8EF-A2C78319D57F -b` booted it to readiness, and the unchanged app
test command passed. This was test-environment recovery, not an application fix.

Result bundles under `~/Library/Developer/Xcode/DerivedData`:

- Focused: `astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.01_20-19-14--0700.xcresult`.
- Full SDK: `astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.01_20-21-48--0700.xcresult`.
- App: `PhroverOperator-fddpasjqbvmpvydqermesnrnjsro/Logs/Test/Test-PhroverOperator-2026.10.01_20-21-32--0700.xcresult`.

Correction-specific file scope: `NavigationController.swift`, `Costmap.swift`,
`MissionAgent.swift`, their ready-motion/mission-agent regressions,
`ConversationViewModelTests.swift`, and this amendment. Physical calibration and
AR/transport limitations described above remain applicable.
