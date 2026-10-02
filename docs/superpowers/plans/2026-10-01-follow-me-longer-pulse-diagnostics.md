# Follow-Me Longer Pulse and Diagnostics Implementation Plan

**Approved spec:** `docs/superpowers/specs/2026-10-01-follow-me-longer-pulse-diagnostics-design.md`, user-approved at `c04fbcc`. That approval governs despite the spec's historical “pending written-spec review” header.

**Goal:** Request a 200 ms pulse only for follow search/reacquisition, retain all safety policy, and produce precise correlated motion and person-association evidence with deterministic operator failure messages.

**Execution status:** **Tasks 1–7 complete, uncommitted.** The caller-cancellation/replacement corrections and subsequent user-authorized calibration-blocker/P2 corrections are verified on current source: **499 full SDK tests and 29 app unit tests passed, zero failures/skips; unsigned generic iOS build exit 0**. Calibration diagnosis first reproduced the timeout on current source and clean `c04fbcc`, then exposed the extra event deterministically with unchanged expected assertions. Independent review found a same-frame backend-diagnostic clearing defect in the first pending-flag implementation; two real calibrator→coordinator tests ran assertion-red before correction, then passed **60 executions**. Final calibration/coordinator coverage passed **76 tests**. See the P2 evidence section at the end; preceding calibration checks establish earlier revisions. Branch/baseline: `feat/follow-me` / `c04fbcc`. No commit, push, manual application installation/launch, or physical rover work; simulator execution was limited to requested tests. Leave this plan uncommitted unless separately requested.

**Architecture:** Keep motor authority and stop serialization in `NavigationController`. Put immutable diagnostic types, formatting, failure reduction, and summary budgeting in small dedicated units. The tracker returns its decision and evaluation from one gate execution. The coordinator captures phase/session facts and applies failure resolutions; it does not calculate a second association policy or own a motor timer.

**Stack:** Swift 6, XCTest, structured concurrency, MainActor/actor isolation, existing runtime diagnostic file stream, Xcode iOS simulator tests.

## Scope and implementation rules

- Preserve `.superpowers` assets and earlier specifications. Preserve unrelated `.serena/project.yml`, `.opencode/`, and `AGENTS.md` work; do not stage, overwrite, or clean it up.
- Follow `CONTEXT.md` terminology. This spec supersedes only the follow-scan pulse and failure/diagnostic requirements of the ready-signal amendment.
- Write a failing behavior test before each production slice, including any motor-path edit. Use controllable clocks and suspended transport/stop continuations; never physical motion to reproduce failures.
- Follow scan alone: requested pulse `0.200 s`, settle `0.300 s`, wheel magnitude `min(0.10, abs(normalizedYawError) * 0.30)`, bypass generic minimum floor. Generic pulsed scan remains `0.080 s`; generic tuning and continuous rotation/follow alignment remain unchanged.
- Watchdog remains `2.5 s` / `0.05 rad`, with its existing error-improvement metric and timestamp policy. Angular tolerance remains `RoverConfig.scanTurnYawTolerance` (currently seven degrees). No deadline, gate, cap, gain, or ready-motion relaxation.
- Capture facts synchronously where they are owned. No logging awaits, asynchronous reads of mutable current-operation state, new motor tasks, extra pose reads that change the controller's sampling, or observation queues.
- Physical validation is a separately authorized task, not an implementation checkbox. Do not install, launch, connect to a rover, or move it until asked.

## Evidence and seams checked for this plan

- `RoverConfig.scanTurnPulseDuration` currently supplies `0.08` to both pulsed modes. `performRotate(to:mode:)` has follow-only cap/gain inline, sends then waits then stops then settles, and uses `DriveProgressWatchdog`.
- `rotateForFollowScan(by:)` brackets work with confirmed stops and operation-generation guards. `confirmStop` serializes previous stop/loop completion and owns `stopUnconfirmed`; cancellation is not stop acknowledgement.
- `FollowMeCoordinator.start()` currently maps every failed safety state to “Navigation safety failure.” `launchMovement` maps failed results to “Navigation failed.” Both need captured context rather than a late state lookup.
- `FollowMeMotion` and `NavigationFollowMeMotion` expose existing result/safety APIs. Preserve those callers and existing conformers while introducing a narrow contextual companion interface.
- `FollowTargetTracker.selectInitial`, `continueTrack`, and `reacquire` own eligibility and matching. Retain candidate order, center-based initial selection, ambiguity, inclusive age, and existing gate short-circuit semantics.
- Coordinator `lastFrameLogTime` currently budgets `follow_frame` separately; replace that separate budget with one shared healthy-summary budget.
- `RuntimeFileLog` accepts synchronous string fields. `RoverControl.sendJSON` sees real HTTP status, while controller send/stop closures return `Void`. Preserve the distinction between transport metadata that is actually available and an unknown status.
- Existing rotation harness advances a `Date` one second per sleep and cannot measure exact requested waits. Add focused manual timing/suspension support instead of treating it as a precise host clock.

## File map

Paths are relative to repository root. New units below have explicit responsibilities; do not paste their implementations into the controller or coordinator.

| Action | File | Responsibility |
| --- | --- | --- |
| New | `swift/Sources/PhroverKit/Nav/RotationDiagnosticModels.swift` | Immutable selected profile, operation context, stage/stop origins, pose/watchdog snapshots, typed failure delivery/result context. |
| New | `swift/Sources/PhroverKit/Nav/FollowScanDiagnosticTrace.swift` | Bounded operation/pulse stage capture, separate watchdog checkpoint/read times, and stop-specific receipt formatting. |
| New | `swift/Sources/PhroverKit/FollowMe/FollowDiagnosticEvent.swift` | Version-1 envelope, typed primitive/nested payload, null/availability handling, synchronous serialization adapter to existing event sink. |
| New | `swift/Sources/PhroverKit/FollowMe/FollowMotionFailureResolution.swift` | Pure generation/operation-keyed reducer, priority and shared operator formatter. No motor or UI authority. |
| New | `swift/Sources/PhroverKit/FollowMe/FollowAssociationDiagnostics.swift` | Tracker evaluation/candidate types and session summary-budget state. No association decisions. |
| New | `swift/Sources/PhroverKit/RoverSDK/RoverCommandDiagnosticReceipt.swift` | Immutable bounded command response metadata captured by transport, including unknown/error outcomes. |
| Modify | `swift/Sources/PhroverKit/Config/RoverConfig.swift` | Own named follow-scan profile; retain generic constants. |
| Modify | `swift/Sources/PhroverKit/Nav/NavigationController.swift` | Select/capture profile, instrument existing stages and confirmation, contextual internal entry points. |
| Modify | `swift/Sources/RoverNav/DriveProgressWatchdog.swift` | Add read-only diagnostic snapshot of actual checkpoint/error/time; leave `observe`/`reset` policy unchanged. |
| Modify | `swift/Sources/PhroverKit/RoverSDK/RoverControl.swift` | Add internal receipt-returning send/stop counterparts; existing public `Void` methods delegate and discard receipt. |
| Modify | `swift/Sources/PhroverKit/FollowMe/FollowMeDependencies.swift` | Add contextual companion protocol with compatibility defaults, preserving `FollowMeMotion` requirements. |
| Modify | `swift/Sources/PhroverKit/FollowMe/NavigationFollowMeMotion.swift` | Bridge immutable request context and contextual delivery to controller. |
| Modify | `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift` | Capture session/phase/budget, consume failure resolution, log tracker evaluation, share summary budget. |
| Modify | `swift/Sources/PhroverKit/FollowMe/FollowTargetTracker.swift` | Evaluated variants; existing methods delegate and return unchanged decisions. |
| New | `swift/Tests/PhroverKitTests/FollowDiagnosticEventTests.swift` | Pure schema, precision, ordering, null, privacy, serialization coverage. |
| New | `swift/Tests/PhroverKitTests/FollowMotionFailureResolutionTests.swift` | Pure reason/context/priority/race permutations. |
| New | `swift/Tests/PhroverKitTests/NavigationFollowScanDiagnosticsTests.swift` | Real-controller exact profile, stage events, watchdog, cancellation/confirmation tests. |
| New | `swift/Tests/PhroverKitTests/FollowAssociationDiagnosticsTests.swift` | Evaluated tracker parity, geometry, transition and shared budget coverage. |
| New | `swift/Tests/PhroverKitTests/Support/FollowDiagnosticTestDoubles.swift` | Manual monotonic/UTC clock, recording synchronous sink, suspendable send/stop/wait boundaries; no live transport. |
| Extend | `swift/Tests/PhroverKitTests/FollowMeCoordinatorTests.swift` | Correlated deliveries, detection-stop, lifecycle and stale-generation integration. |
| Extend | `swift/Tests/PhroverKitTests/Support/FollowMeTestDoubles.swift` | Contextual companion fake and controlled failure delivery, retaining legacy fake coverage. |
| Extend | `swift/Tests/PhroverKitTests/NavigationRotationWatchdogTests.swift` | Existing rotation/stop invariants and generic/continuous isolation. |
| Extend | `swift/Tests/PhroverKitTests/RoverControlTests.swift` | Stubbed HTTP receipt fidelity and backwards-compatible send/stop behavior. |
| Verify | `swift/Tests/PhroverKitTests/NavigationFollowReadySignalTests.swift`, `FollowTargetTrackerTests.swift`, `ARFollowMePerceptionSourceTests.swift`, `OperatorCommandRouterTests.swift` | Existing ready, association, coalescing/provenance and local Stop coverage. |
| Verify | `examples/PhroverOperator/PhroverOperatorTests/ConversationViewModelTests.swift` | Existing local Stop/no Thinking and terminal message routing; add a focused assertion here only if integration exposes a missing boundary. |

## Verification commands for future implementation

Run from `/Users/hungmai/Sites/Astral/astral-sdk`. These commands are documented, not executed. Select an available iOS 26+ simulator through the existing script (override `SIM_UDID` when needed):

```bash
SIM_UDID="$(./scripts/test-swift-sdk.sh --print-udid)"
```

For exact red/green isolation use direct `xcodebuild`, because the script already adds both SDK test targets. Each task below gives a class selector; run it before and after implementation, with no omitted test placeholders:

```bash
xcodebuild test -scheme astral-sdk-Package -destination "id=$SIM_UDID" \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -parallel-testing-enabled NO -quiet
```

Replace only the concrete class selector with the class specified by the task. New API tests may initially fail to compile for missing types; record that once, introduce the smallest declarations, then require a failing assertion for absent behavior before implementing the slice. A missing simulator or toolchain is a setup failure, not a behavioral red. Record commands and actual outcomes, not historical passing counts.

## Task 1 — Immutable event contract and pure telemetry seams

**Files:** New `RotationDiagnosticModels.swift`, `FollowDiagnosticEvent.swift`, `FollowDiagnosticEventTests.swift`, `Support/FollowDiagnosticTestDoubles.swift`.

- [x] Add red tests for required envelope keys and explicit nulls, full numeric precision plus signed six-decimal display, equal-time sequence order, stream separation, unknown pose source, and a nested candidate payload round-trip.
- [x] Run the command above; obtain assertion-level red for missing serialization/measurement behavior before integration edits.
- [x] Implement immutable primitive snapshots and an injected synchronous event emitter. Use a compact JSON payload in one existing sink field (alongside the event name), encoding explicit JSON null and real numbers; do not serialize numbers solely as rounded text. Keep existing `RuntimeFileLog.append` and legacy sink callers working. Signed six-decimal angle display fields accompany raw numeric radian values.
- [x] Envelope on **every** new event: `event`, `schema_version=1`, `session_generation`, `operation_id`, `stream_id`, `event_sequence`, `monotonic_s`, `utc_time`, `purpose`, `phase`, `pulse_index`, `stale`, `outcome`, `reason`. Null nonapplicable fields; unavailable measurements carry an availability reason. Pulse indices start at one per operation.
- [x] Increment sequence at each serialized emitting boundary; different stream IDs have no claimed total sequence. Monotonic seconds order/duration only within one runtime; UTC is correlation only. Inject monotonic and UTC providers independently without changing existing watchdog `Date` policy.
- [x] Define shortest signed normalization `[-π,π)`, delta `normalize(post-pre)`, improvement `abs(preError)-abs(postError)`. Test wraparound, negative improvement, positive/negative tiny angles, missing and nonfinite samples, and precision beyond six decimal places. Formatting cannot feed the watchdog.
- [x] Capture read-time, availability/finite status, tracking/frame/observation age only when known. With current pose provider, `pose_source_timestamp=null`, `pose_source_age_status=unknown`; read time is never substituted for source time. Mark controller/perception pairing `same_frame`, `independently_sampled`, or `unknown` from actual provenance.
- [x] Test bounded error codes/messages and absence of images, audio, full transcripts, arbitrary bodies, raw-detector/projection counts. Serialize one single-record payload without embedded newline records.
- [x] Rerun `FollowDiagnosticEventTests` green. No controller/motor changes in this slice.

## Task 2 — Profile isolation through the real controller

**Files:** `RoverConfig.swift`, `NavigationController.swift`, `RotationDiagnosticModels.swift`, new `NavigationFollowScanDiagnosticsTests.swift`, diagnostic test doubles; existing rotation tests.

- [x] Add red real-controller tests recording exact requested sleeps and wheel commands: follow scan requests `0.200` then `0.300`; generic scan requests `0.080` then `0.300`; generic/follow continuous alignment never uses pulse/settle waits. Test both search and reacquisition adapter calls.
- [x] Assert positive/negative wheel signs, `0.10` cap, `0.30` gain below cap, generic minimum floor unchanged, and follow-only bypass. Capture selected tolerance and profile once and retain it through cancellation/cleanup.
- [x] Run direct SDK test command with `PhroverKitTests/NavigationFollowScanDiagnosticsTests`; red must show the existing 80 ms follow wait.
- [x] Add `RoverConfig.followScanRotationProfile` with the approved constants. Select only for captured `.followScan`; keep generic pulse constant intact and alignment continuous. Move existing follow cap/gain literals into the profile without retuning.
- [x] Keep wait after send acknowledgement at its existing boundary; do not subtract send latency. Preserve existing pre-turn/final stop brackets and controller ownership.
- [x] Rerun new class and `NavigationRotationWatchdogTests` green. Assert no profile propagation to ready signal, stand-off following, or generic navigation.

## Task 3 — Context and transport receipts without breaking callers

**Files:** `RotationDiagnosticModels.swift`, `FollowMeDependencies.swift`, `NavigationFollowMeMotion.swift`, `NavigationController.swift`, `RoverCommandDiagnosticReceipt.swift`, `RoverControl.swift`; diagnostic/rotation/transport tests and fakes.

- [x] Add red tests that capture request context before an awaited pre-stop, then replace/cancel the operation; result and safety delivery retain session generation, controller operation ID, captured purpose/phase/profile and typed reason. Coordinator request token and controller ID must be mapped explicitly; do not assume their counters equal.
- [x] Add legacy-conformer tests: an existing `FollowMeMotion` implementation and old navigation public calls compile and preserve result semantics. Absence of contextual support yields explicit unknown context, never fabricated follow-scan/stall facts.
- [x] Add stub HTTP tests for 200, other accepted 2xx, non-2xx failure, invalid response, transport error, retries and cancellation. Assert real status/ack metadata versus null; nonzero acknowledgement never means stopped.
- [x] Run `NavigationFollowScanDiagnosticsTests` and `RoverControlTests` red for missing context/receipt behavior.
- [x] Introduce a narrow `FollowMeContextualMotion: FollowMeMotion` companion with contextual motion requests/results and contextual failure stream. Keep original protocol requirements, controller public return types, and adapter public methods. Compatibility defaults wrap legacy results with available request context and unknown controller/receipt facts; existing conformers need no new requirements.
- [x] Route the production adapter through contextual internal controller entry points for scan, alignment, ready and following so all follow failures reach one formatter. Context includes generation, request token, purpose, phase, requested scan used/remaining and operation-start profile where applicable. Reserve controller ID before the first suspension, and capture terminal context before cleanup.
- [x] Contextual consumers use the contextual failure stream; legacy consumers retain `safetyStates()`. Do not subscribe the coordinator to two competing failure channels. Awaited contextual result carries the same immutable operation correlation as its stream delivery, including failure before the first pulse.
- [x] Add internal receipt-returning transport counterparts at the existing send/stop path, preserving retry/order/ack policy. Public `send`, `sendNavigation`, `stop` continue returning `Void`. Use returned immutable receipts, not mutable “last receipt” lookup after an await. Capture on the owning actor without new diagnostic awaits.
- [x] Add defaulted optional receipt-producing closures to the internal controller initializer, with compatibility adapters for existing `Void` closures. Unknown HTTP status remains null; last acknowledgement is labelled with its actual exposed clock/provenance, not converted to invented monotonic source time.
- [x] Rerun those classes green and existing rotation/ready tests to prove caller/result/confirmation semantics unchanged.

## Task 4 — Complete pulse, watchdog, cancellation and stop evidence

**Files:** `NavigationController.swift`, diagnostic units, `DriveProgressWatchdog.swift`; `NavigationFollowScanDiagnosticsTests.swift`, `NavigationRotationWatchdogTests.swift`, diagnostic test doubles.

- [x] Write red deterministic event trace tests for a completed pulse, adequate progress, insufficient progress, wraparound, send failure, pulse stop failure, and cancellation at every stage. Run `NavigationFollowScanDiagnosticsTests` red before instrumenting motor paths. Missing trace behavior was assertion-red; already-implemented watchdog/math invariants remain regression guards (see new execution evidence).
- [x] Add a read-only watchdog snapshot exposing actual best-distance checkpoint, last-progress timestamp and current progress. Controller pairs the existing checkpoint with its captured yaw and monotonic read time when the watchdog initializes/resets progress. Do not run a second watchdog or calculate a replacement threshold.
- [x] Assert insufficient progress at `2.499` versus `2.500 s`, below `0.05` versus at `0.05 rad` progress, adequate-progress reset, and backwards/negative heading improvement. Record the actual error-distance metric, not raw yaw displacement as a substitute.
- [x] Emit the following complete version-1 controller motion schema at existing boundaries. The explicitly Task-5-owned `follow_motion.failure_resolution` row remains pending:

| Event | Stage payload required in addition to common envelope |
| --- | --- |
| `follow_scan.operation_begin` | Requested increment, target yaw, requested scan budget used/remaining, operation-start monotonic time, complete selected profile. |
| `follow_scan.pulse_begin` | Pre-pulse sample, signed wheel requests, pulse-begin time, error, watchdog checkpoint. |
| `follow_scan.send_begin` | Send-start time, command kind and nonzero wheel requests. |
| `follow_scan.send_ack` | Send-end time, host duration, acknowledgement/HTTP status if exposed, command-ack time/age with provenance. Failed send has failed outcome and null unavailable status. |
| `follow_scan.pulse_wait_begin`, `follow_scan.pulse_wait_end` | Requested wait, start/end monotonic times, measured host duration, completed/interrupted outcome. |
| `follow_scan.stop_begin`, `follow_scan.stop_response` | Unique stop identity, origin `pulse`/`independent`/`final`/`detection`/`cleanup`, start/end, host response duration, acknowledged/cancelled/failed outcome, confirmation and latch state. |
| `follow_scan.settle_begin`, `follow_scan.settle_end` | Requested settle, start/end, host elapsed, outcome, post sample when available. |
| `follow_scan.pulse_complete` | Pre/post samples, signed delta, improvement, watchdog snapshot/elapsed, operation elapsed. |
| `follow_scan.operation_complete` | Final yaw/error, elapsed, completed/cancelled/failed outcome, primary failure, stop result, final latch, last reached stage. |
| `follow_scan.cancel` | Origin, interrupted stage, fence state and monotonic time; no implied stop confirmation. |
| `follow_scan.failure` | Failed stage, typed reason, available pre/post/checkpoint measurements, elapsed/profile, current confirmation state. |
| `follow_motion.failure_resolution` | Stream/result source, retained primary reason, stop outcome, formatter message/priority, stale/deduplicated flags. Implement emission in Task 5. |

- [x] Pulse begin/completion, failure and operation completion include available `pre_yaw_rad`, `post_yaw_rad`, `target_yaw_rad`, `pre_error_rad`, `post_error_rad`, `signed_yaw_delta_rad`, `error_improvement_rad`; all watchdog keys from spec §6 (`watchdog_checkpoint_yaw_rad`, `watchdog_checkpoint_monotonic_s`, `watchdog_progress_rad`, `watchdog_elapsed_s`, `watchdog_required_progress_rad`, `watchdog_interval_s`); `operation_elapsed_s`, stage timings, `profile_pulse_wait_s=0.200`, `profile_settle_s=0.300`, `profile_wheel_cap_mps=0.10`, `profile_yaw_gain=0.30` and selected angular tolerance. Missing values are explicit, not zero.
- [x] Reuse the controller's authoritative pose samples; capture post-pulse at the existing post-settle/next evaluation boundary. Identify every duration as host timing (including transport/suspension) and every yaw as AR visual-inertial measurement, not encoder/chassis evidence.
- [x] Use suspended continuations to cancel during pre-stop, acknowledgement read/send, pulse wait, pulse-stop response, settle, independent/final confirmation and completion handoff. Interrupted entered waits emit end events; unentered stages emit nothing. Stop/cleanup events retain operation correlation with nullable pulse index.
- [x] At each suspension return recheck existing cancellation, generation/ownership and latch before any nonzero send or settle/continuation. Emit telemetry from captured context even when stale; it cannot revive work or clear a latch.
- [x] Assert a cancelled pulse-stop request is safe only after an independently valid confirmed stop; cancelled/failed independent stop leaves the latch blocking subsequent motion. Test successful stale callback after failed stop, no stale success/result mutation, and no later nonzero command. Serialized stop ordering is retained: the stale earlier response drains before the newer independent stop can fail; it cannot authorize another command or clear that newer failure.
- [x] Rerun new and existing rotation classes green. Review sink calls for synchronous capture, no extra motor owner, and no changed stop-confirmation policy.

## Task 5 — Shared failure reducer and coordinator race integration

**Files:** `FollowMotionFailureResolution.swift`, coordinator/adapter/context units; new `FollowMotionFailureResolutionTests.swift`, coordinator tests and contextual fakes.

- [x] Add pure red tests for stream→result and result→stream permutations; wrapper after stall; cancellation after stall; stop failure after stall; stale success after failed stop; old-session failure after restart. Run `FollowMotionFailureResolutionTests` red.
- [x] Implement one reducer record keyed by session generation/controller operation ID. A typed `.stalled` in captured `.followScan` maps to diagnostic `no_yaw_progress`; retain actual typed reason as well. Generic `navigation_failed`/`transport_failed` wrappers enrich but never replace a specific primary reason.
- [x] Shared formatter outputs exactly:
  - Pending: `Search rotation stopped: insufficient measured yaw progress. Confirming motor stop…`
  - Authoritatively confirmed: `Search rotation stopped: insufficient measured yaw progress. Stop confirmed. Restart following to try again.`
  - Confirmation failed (higher priority): `Motor stop could not be confirmed. Motion is blocked.`
- [x] Preserve non-stall specific mappings. Captured purpose determines context, never current coordinator state. Cancellation does not erase the stall, and stop-confirmation failure is retained alongside it in terminal diagnostics. A stale successful callback cannot downgrade failure priority or mutate the current latch/UI.
- [x] Rerun pure tests green; then write coordinator red tests delivering both channels in both orders while phase changes and stop is suspended. Assert same retained reason/message, one terminal cleanup, pending-to-confirmed wording only at actual acknowledgement, and failed-stop priority.
- [x] Replace the two generic coordinator mappings with shared resolution handling. Integrate pending diagnostic/UI publication with existing terminal confirmed-stop cleanup; do not introduce a second cleanup owner or prematurely cancel the stream before its failure context is captured. Keep enough immutable terminal context for the awaited result to enrich the record after cancellation.
- [x] Bound retained records to active/in-flight/terminal deliveries; prune completed records when their deliveries drain/session ends. Do not accumulate historical session state for logging. Emit `follow_motion.failure_resolution` synchronously for both correlated deliveries, marking duplicates and stale deliveries accurately.
- [x] Rerun `FollowMeCoordinatorTests` and pure reducer tests green. Test a legacy motion fake to prove compatibility without claiming contextual facts it does not expose.

## Task 6 — Tracker-owned association diagnostics and one shared budget

**Files:** `FollowAssociationDiagnostics.swift`, `FollowTargetTracker.swift`, coordinator and diagnostic event units; new `FollowAssociationDiagnosticsTests.swift`, tracker/coordinator tests.

- [x] Add red tests comparing evaluated decisions with existing initial/continuity/reacquisition behavior for zero/one/multiple matches, tie ordering, finite checks, inclusive confidence/age/world/IoU/screen/reacquisition thresholds and skipped gates. Run `FollowAssociationDiagnosticsTests` red.
- [x] Introduce evaluated tracker methods returning decision plus immutable evaluation; existing public methods delegate and discard evaluation. Evaluate gates once, preserving short-circuit outcomes/order; record skipped gates as not evaluated. No coordinator threshold duplication.
- [x] Each `follow_person.association` has the common envelope plus `association_outcome`, `previous_outcome`, `association_mode`; actual `frame_id`, `observation_monotonic_s`, `observation_age_s`, `tracking_state`, `same_frame`; `projected_person_count`, `eligible_candidate_count`, `matched_candidate_count`; `selected_candidate`, `candidate_evaluations`, `gate_metrics`, `gate_thresholds`.
- [x] Initial selection has matched count null with `not_applicable_initial_selection`. Candidate IDs are frame-local, not identity. Selected/per-candidate payloads include confidence, normalized `(x,y,width,height)` box, projected `(x,y)` in `Vec2` world X/world Z convention, paired rover pose, range metres and normalized heading radians when available. Each candidate evaluation includes eligible/matched results, stable rejection reasons, actual confidence/age/world-distance/IoU/screen-displacement/reacquisition-distance metrics and centralized thresholds used; skipped gates are explicitly not evaluated. `selected_candidate` is null when no selection occurred.
- [x] Compute diagnostic range/heading only from the observation's paired snapshot, never latest rover pose. State coordinate convention and provenance; missing geometry is null with reason, never zero distance. Do not alter tracker inputs to repair telemetry.
- [x] Add empty-projected-list tests: report “no projected person candidate available” and actual outcome/health; no raw detector/projection counts or “detector saw nobody”/“depth failed” inference. Initial/reacquired selection never claims biometric identity.
- [x] Rerun tracker-focused tests green; then write coordinator red tests for immediate initial/lost/ambiguous/reacquired/other transitions, identical lost/ambiguous repeats, and healthy frames faster than 1 Hz.
- [x] Use one per-session monotonic budget shared by healthy `follow_frame`/perception and continued association summaries. Prefer one combined association summary containing health when both are available; otherwise consume the slot with perception summary. Assert at most one healthy record in each one-second interval and eligibility at the exact one-second boundary. Reset budget at session start.
- [x] Transitions, failures, cancellation, stop responses and bounded scan lifecycle bypass the budget and emit immediately. Repeated identical lost/ambiguous evaluations do not create transitions. Retain existing latest-frame coalescing; no per-frame healthy emission or deferred frame history.
- [x] Rerun `FollowAssociationDiagnosticsTests`, `FollowTargetTrackerTests`, `FollowMeCoordinatorTests` green; validate schema with `FollowDiagnosticEventTests`.

## Task 7 — Deterministic lifecycle boundaries and final verification

**Files:** Existing coordinator/rotation/ready/perception/router/app tests; extend tests only where the new integration leaves an uncovered boundary.

- [x] Before any corrective production edit, write a failing focused boundary test. Already-passing invariants remain regression guards; do not force them red by weakening production behavior.
- [x] Test full stationary pause at `4.999` and `5.000 s` with healthy frames; startup readiness remains a separate window after the pause. Telemetry does not authorize early motion.
- [x] Assert initial requested scan sum never exceeds `2π`, final increment is shortened, and cancelled/stale operation cannot schedule another increment. Reacquisition deadline interrupts a long/suspended pulse at `10.000 s`, without reset/extension.
- [x] Suspend send/pulse/stop/settle, detect an eligible person, and assert immediate fence/cancel plus controller confirmed stop before continuous alignment. Coordinator sends no wheel commands or independent pulse timer; no leftover nonzero command is authorized.
- [x] Test observation age `0.500 s` accepted, greater rejected, invalid/future timestamp rejected; two-second continuous outage at `1.999`/`2.000 s`, with one stop and unchanged deadline. Logging cannot refresh timestamps or rescue stale frames. Preserve newest-frame coalescing/lossless interruption handling.
- [x] Assert one requested 10 cm ready signal per session, existing measured travel/clearance/watchdog limits, final confirmed stop and fresh post-stop departure baseline. Interrupted/partial signal is not retried, including reacquisition.
- [x] Preserve stand-off/hold/departure/no reverse, association gates, background/leave-Talk and safety cancellation, old-operation/session fencing. Test local Stop synchronous inhibition/local routing and no Thinking/brain fallback, including final acknowledgement handoff.
- [x] Run focused red/green classes as needed, then run affected SDK coverage from root:

```bash
xcodebuild test -scheme astral-sdk-Package -destination "id=$SIM_UDID" \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowAssociationDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/RotationCommandTests \
  -only-testing:PhroverKitTests/RoverControlTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/FollowTargetTrackerTests \
  -only-testing:PhroverKitTests/ARFollowMePerceptionSourceTests \
  -only-testing:PhroverKitTests/OperatorCommandRouterTests \
  -parallel-testing-enabled NO -quiet
```

- [x] Pass final full non-live SDK suite after the caller-cancellation and user-authorized calibration-blocker/P2 corrections using established script style: **499 passed, zero failures/skips**; see final evidence below.

```bash
SIM_UDID="$SIM_UDID" ./scripts/test-swift-sdk.sh -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 -quiet
```

- [x] Rerun all app unit tests, then unsigned generic iOS app build after the final caller-cancellation/replacement and calibration corrections: **29 passed, zero failures/skips; build exit 0** (root-relative project path; no manual installation/launch).

```bash
xcodebuild test -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination "id=$SIM_UDID" \
  -only-testing:PhroverOperatorTests -parallel-testing-enabled NO -quiet
xcodebuild build -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO -quiet
```

- [x] Inspect `git diff --check`, intended diff and status; review public API compatibility, no additional suspension/motor authority, bounded retained data, complete event keys, and preserved unrelated files. Record new evidence and any failed check honestly. Do not commit/push unless separately requested.

## Physical acceptance handoff — only after explicit permission

Use spec §9 as the acceptance procedure in a separate task. Correlate requested/host timings and AR yaw with supervised physical observations; HTTP acknowledgement is not measured braking, AR yaw is not encoder travel, and a 200 ms requested wait is not guaranteed motor-on duration. Include detection-stop, operator Stop during pulse, requested initial exhaustion and ten-second reacquisition evidence. Never obstruct powered wheels to manufacture a stall. A remaining `no_yaw_progress` failure must stop safely and report its precise reason; further tuning requires another design decision.

## Assumptions and risks

- The approved commit identifies the design; current source is the implementation baseline. Current public `Void` transport closures and legacy protocol conformers must continue to work with unknown metadata where appropriate.
- Weak pulse versus insufficiently changing/stale reported pose remains unproven. Longer host wait may improve motion or increase overshoot; tests establish control policy and evidence, not physical performance.
- Existing synchronous file output consumes host time. Keep payloads bounded to the emitted tracker evaluation, healthy summaries limited, and use the existing sink rather than a new logging architecture. Include that cost in measured host durations.
- Frame timestamps and pose-read times have different provenance. Unknown source age/pairing must survive serialization and cannot become a safety input.
- Race integration is the highest-risk seam: capture before suspension/cleanup, reduce both deliveries identically, and retain authoritative stop-failure priority without changing the latch's ownership.

## Written-plan self-review against the full approved spec

- [x] §§1–4: purpose-only 200 ms profile, unchanged generic 80 ms/settle/tuning/watchdog/tolerance, controller ownership, all lifecycle and confirmed-stop invariants mapped to Tasks 2, 4 and 7.
- [x] §5: exact pending/confirmed/failed-stop wording, typed immutable context, both arrival orders, wrapper/cancellation/stale success precedence and non-stall mappings mapped to Tasks 3 and 5.
- [x] §6: every event/envelope/stage field, precise raw/display angles, actual watchdog metric, monotonic versus UTC/host versus physical timing, unknown pose-source timestamps, interrupted ends and correlated cleanup mapped to Tasks 1, 3 and 4.
- [x] §7: single tracker gate execution, full candidate schema/provenance/count semantics, transitions/shared 1 Hz budget, no upstream inference, privacy/coalescing mapped to Task 6.
- [x] §8: deterministic test-first vertical slices with explicit files, concrete command style, expected red/green behavior, affected/full SDK/app unit/unsigned build commands mapped throughout and Task 7.
- [x] §§9–10: physical work separately authorized; uncertainty/overshoot/logging/provenance risks stated, no tuning workaround or device action included.
- [x] Focused diagnostic units and pure tests prevent controller/coordinator growth; narrow contextual integration preserves public callers; no undecided placeholders or vague deferred implementation decisions remain.

## Execution evidence — 2026-10-01 partial checkpoint

This is a bounded execution checkpoint at the session execution budget, **not completion of the full seven-task plan**. Remaining contextual/race/lifecycle/association integration requires continuation. No simulator/toolchain blocker or unresolved test failure was encountered. Healthy-summary budgeting and runtime structured motion logging are not yet connected to the controller/coordinator; passing current tests does not establish those future requirements.

### Task states and continuation

| Task | Actual state | Remaining work |
| --- | --- | --- |
| 1 | Pure seam complete | Integrate the emitter at the later owning boundaries; controller pulse numbering belongs to Task 4. |
| 2 | Profile behavior implemented; task partial | Signed wheels, cap/gain, tolerance, generic floor and continuous waits are covered. Immutable profile is selected before pre-stop. Contextual profile retention through cancellation/cleanup still needs Tasks 3–4's trace assertions. Search and reacquisition use the same coordinator `scan` → adapter `rotateForScan` path; separate captured phase assertions are pending. |
| 3 | Transport receipts implemented; task partial | Start next with a failing suspended-pre-stop context test. Add the contextual companion/defaults, request-token/controller-ID mapping, correlated stream/result delivery for scan/alignment/ready/following, and defaulted controller receipt closures. Preserve explicit unknown facts for legacy conformers/closures. |
| 4 | Not started | Authoritative watchdog snapshot; complete motion-stage schema; suspendable send/stop/wait controls and cancellation/confirmation boundary tests. |
| 5 | Not started | Pure keyed reducer and exact formatter, followed by both arrival-order coordinator tests and one-owner cleanup integration. |
| 6 | Not started | Evaluated tracker methods retaining one gate execution, candidate geometry/provenance, transitions and shared 1 Hz budget. |
| 7 | Current-checkpoint verification passed; task partial | Add/verify the planned deterministic lifecycle boundaries after integration, then rerun all final checks. Missing reducer/association test classes were not selected as if they existed. |

### Baseline and environment

- Initial `git status --short`, `git branch --show-current`, `git rev-parse --short HEAD`: `feat/follow-me`, `c04fbcc`; pre-existing `.serena/project.yml`, `.opencode/`, `AGENTS.md`, and the untracked plan preserved.
- Read the approved spec and `CONTEXT.md`; no spec changes.
- `./scripts/test-swift-sdk.sh --print-udid` returned `EEA52712-371D-4FF6-B8EF-A2C78319D57F`: iPhone 17 Pro, iOS 26.5.
- `xcodebuild -list` confirmed the root `astral-sdk-Package` scheme. Every SDK command below ran from `/Users/hungmai/Sites/Astral/astral-sdk`; no work-directory workaround was needed.

### Exact red/green command and outcomes

Each single-class run used this exact command, substituting the concrete selector recorded in the table:

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -parallel-testing-enabled NO -quiet
```

Times below are the actual Xcode run timestamps in local time. Red is an executed failing assertion after minimal declarations, except the separately labelled initial compilation failure. Empty success output with exit zero was verified against `.xcresult` summaries for the final tallies. Earlier result bundles can be evicted by Xcode's log retention; their command outputs were observed during execution.

| Selector | Behavior | Red → green run timestamps | Actual outcome |
| --- | --- | --- | --- |
| `FollowDiagnosticEventTests` | Initial declarations | 22:03:53 | **Compilation failure only**: missing `FollowDiagnosticEmitter` / `FollowDiagnosticEvent`; not counted as behavioral red. |
| `FollowDiagnosticEventTests` | Envelope/nulls/equal-time sequence | 22:04:15 → 22:05:59 | `testEnvelopeIncludesExplicitNullsAndOrdersEqualTimeEvents` failed assertions, then passed. |
| `FollowDiagnosticEventTests` | Captured context/nested primitives/stream separation | 22:06:49 → 22:07:58 | `testCapturedContextNestedNumbersAndIndependentStreams` failed assertions, then passed. |
| `FollowDiagnosticEventTests` | Angle math and missing/nonfinite measurements | 22:08:53 → 22:09:53 | `testPreciseAnglesWraparoundAndUnknownPoseProvenance` and `testMissingAndNonfiniteSamplesNeverBecomeZeroMeasurements` failed assertions, then passed. |
| `FollowDiagnosticEventTests` | Bounded errors/privacy/single record | 22:10:34 → 22:11:21 | `testBoundedErrorsSingleRecordAndPrivacy` failed assertions, then passed. |
| `NavigationFollowScanDiagnosticsTests` | Real-controller profile isolation | 22:12:42 → 22:13:32 | 1 failed / 3 passed on red. Exact assertion: `[0.08, 0.3]` is not equal to `[0.2, 0.3]`. Green included rotation/ready selectors, **25 passed / 0 failed**. |
| `RoverControlTests` | Real accepted status/ack clock | 22:14:57 → 22:15:56 | `testReceiptsPreserveRealAcceptedStatusAndAckClock` failed assertions, then passed. |
| `RoverControlTests` | Failure metadata, cancellation, retry and stop receipt | 22:16:52 → 22:17:38 | `testFailureReceiptsKeepActualStatusAttemptsAndOriginalErrors` and `testStopAndRetryReceiptsDescribeTheirOwnAcknowledgement` failed assertions, then passed. |
| `FollowDiagnosticEventTests` | Known metadata without invented source time | 22:21:01 → 22:21:45 | `testKnownObservationMetadataRetainsPairingWithoutInventingSourceTime` failed assertions, then passed; **7 tests passed** at that point. |
| `RoverControlTests` | Unknown acknowledgement must be nil | 22:27:02 → 22:27:37 | `testUnknownReceiptDoesNotClaimTransportFacts` failed an assertion, then passed; **12 passed / 0 failed**. |
| `FollowDiagnosticEventTests` | Nonfinite availability has deterministic precedence | 22:31:56 → 22:32:30 | `testNonfiniteAvailabilityCannotBeOverriddenBySuppliedMetadata` failed an assertion, then passed; **8 passed / 0 failed**. |

The 22:13:32 green command was:

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -parallel-testing-enabled NO -quiet
```

There were **10 assertion-red → green cycles**, plus one initial declaration compilation failure. Precision/independent-clock and additional record-count assertions also passed as regression guards; they are not claimed as separate red cycles. Added **16 test methods**: 8 telemetry, 4 controller profile, 4 transport receipt methods.

### Final current-checkpoint checks

These ran serially after the last production edit. Earlier full checks were rerun only after new receipt/serialization changes.

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/RotationCommandTests \
  -only-testing:PhroverKitTests/RoverControlTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/FollowTargetTrackerTests \
  -only-testing:PhroverKitTests/ARFollowMePerceptionSourceTests \
  -only-testing:PhroverKitTests/OperatorCommandRouterTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 -quiet

SIM_UDID=EEA52712-371D-4FF6-B8EF-A2C78319D57F ./scripts/test-swift-sdk.sh \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 -quiet

xcodebuild test -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverOperatorTests -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 -quiet

xcodebuild build -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
```

| Check | Final result |
| --- | --- |
| Implemented/available affected SDK selectors, 22:33:06 | **128 passed, 0 failed, 0 skipped** |
| Full non-live SDK, 22:33:19 | **441 passed, 0 failed, 0 skipped** |
| All app unit tests, 22:33:42 | **29 passed, 0 failed, 0 skipped** |
| Unsigned generic iOS build after app tests | Exit **0** |

Tallies were read with `xcrun xcresulttool get test-results summary --path <actual-result-bundle>`. The first app verification showed existing `UIScreen.main` deprecation / launch-configuration warnings; final incremental build exited zero. No warnings were converted into failed checks or hidden as blockers.

### Compatibility, ownership and remaining acceptance risks

- Public navigation calls and `FollowMeMotion` requirements are unchanged. Public transport methods still return `Void` and rethrow original errors; no receipt wrapper changes public error types.
- Follow profile uses 200 ms / 300 ms / 0.10 cap / 0.30 gain / existing tolerance; generic pulse remains 80 ms. Profile is captured before pre-stop and passed immutably to the existing loop. No new motor task, pose read, watchdog policy, deadline, gate or safety-latch edit was introduced.
- Receipts contain actual status/attempt/UTC acknowledgement facts where exposed. Unknown acknowledgement/status/attempt/time are nil. Receipt acknowledgement is not stop confirmation or physical braking evidence. Controller receipt compatibility adapters are still pending.
- The synchronous emitter has complete envelope keys, compact numeric/null JSON, stream-local ordering, bounded error fields, provenance and nonfinite handling. It is **not yet wired to runtime motion/association events**. The precise operator formatter, race-safe correlated failure handling, single evaluated tracker gates and shared 1 Hz budget remain required work.
- `git diff --check` passed for the tracked implementation diff. Each of the six new Swift files and this untracked plan were also checked with `git diff --no-index --check /dev/null <path>` at handoff. Final branch/HEAD remained `feat/follow-me` / `c04fbcc`; unrelated work is excluded from the implementation review. No staging/commit/push or physical work.
- The first bulk new-file whitespace loop failed with `zsh: command not found: git` because its loop variable was the reserved zsh `path`. It was corrected to `file_path` with `/usr/bin/git`; all seven new-file/plan whitespace checks then exited zero. A subsequent ordinary `git diff --check && git status --short` also succeeded. This was a shell-check setup error, not a compilation or behavioral test failure.

## Task 3 execution evidence — 2026-10-02

**Scoped status: Task 3 context/receipts complete; stopped here as directed.** The routing checkbox above establishes the contextual seams for the **Task 5** shared formatter. It does not claim that formatter, its pending/confirmed wording, reducer/race integration or failure-resolution event is implemented. Existing generic coordinator operator wording remains until Task 5. Tasks 4–7 were not advanced during this scoped continuation, and no full SDK/app/build verification was repeated.

### Production integration

- Added immutable request, operation, failure-delivery and result snapshots in `RotationDiagnosticModels.swift`, plus a MainActor-owned per-operation evidence object. Controller IDs are independently reserved before pre-stop; request generation/token/phase/budget are copied into that operation. Both IDs are explicit, never assumed equal.
- `FollowMeDependencies.swift` adds the optional internal contextual companion and compatibility defaults. Legacy conformers acquire no requirements; they preserve result semantics and carry available request intent with unknown actual controller purpose/profile/ID/receipt/confirmation facts.
- `NavigationFollowMeMotion.swift` implements the real contextual entry point and failure stream. Scan, alignment, ready and following, including existing adapter public calls, pass through controller-owned contextual execution. Controller public navigation result signatures and original public protocol requirements remain unchanged.
- `NavigationController.swift` captures operation context before suspension, binds it through existing child/stop tasks, freezes stream/result deliveries, and retains only active/latest-terminal evidence plus evidence still owned by in-flight tasks. Captured old context cannot become a replacement's phase/profile. Typed stall survives a final `.commandFailed` stop wrapper. A current failed-safety subscription is delivered with **unknown operation context**, not inferred historical scan facts.
- Real production send/stop closures now use the already-tested RoverControl receipt counterparts. Optional internal initializer closures return immutable response snapshots; legacy `Void` closures retain nil transport facts. The owning operation is captured before the transport await; there is no actor-global last-receipt lookup afterward. Acknowledgement time remains the exposed UTC `Date`.
- A nonzero send invalidates earlier **diagnostic** stop confirmation to pending. An actual pulse-stop latch failure and serialized-confirmation failure are captured where the controller owns those facts. No safety latch rule, stop serialization, motor timer/owner, watchdog, deadline, threshold or pose sampling was changed.
- `FollowMeCoordinator.swift` captures request generation/token/phase/budget for all four movement paths and selects one contextual failure subscription or the legacy safety subscription. Reacquisition remaining-angle budget is nil: its bound is time, not an invented initial-search angle limit.

### Red/green evidence

All commands ran from repository root on the same simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. `pgrep -fl 'xcodebuild|xctest|Simulator.*Runner'` returned no running matches before work and at handoff. Every verification invocation had a finite harness timeout (180 seconds for the continuation) and serial tests with 60-second per-test limits.

The common exact command for the full navigation class (command **A**) was:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

The focused coordinator command (**B**) used the same scheme/destination/flags with these exact selectors:

```bash
-only-testing:PhroverKitTests/FollowMeCoordinatorTests/testContextualRuntimeCapturesSearchFollowAndReacquisitionAndUsesOneFailureChannel
-only-testing:PhroverKitTests/FollowMeCoordinatorTests/testContextualRuntimeCapturesAlignmentReadyAndDepartureRequests
```

The focused latch/replacement command (**C**) used the same scheme/destination/flags with:

```bash
-only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testBlockedRequestCapturesUnconfirmedLatchWithoutInventingAnotherReceipt
-only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testLatePreStopFailureKeepsOldContextWhileReplacementFailsClosed
```

The initial-failure snapshot command (**D**) used the same scheme/destination/flags with:

```bash
-only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testContextualSubscriptionPreservesExistingFailedSafetySnapshotWithoutInventedOperation
```

The pulse-stop metadata command (**E**) used the same scheme/destination/flags with:

```bash
-only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testPulseStopFailureDeliveryCapturesAuthoritativeUnconfirmedLatch
```

| Behavior | Actual red run | Actual green run | Observed result |
| --- | --- | --- | --- |
| Controller ID/purpose/profile/correlation before pre-stop | A, 2026-10-01 22:45:34 | A, 2026-10-02 07:19:48 | `testContextIsReservedBeforePreStopAndBothDeliveriesKeepIt` assertion failures, then passed. |
| Returned receipt snapshots and `Void` unknowns | A, 07:21:41 | A, 07:23:38 | `testControllerUsesReturnedReceiptSnapshotsWithoutCallingVoidTransport` and `testVoidControllerTransportReportsUnknownMetadataDespiteConfirmedStop` assertion failures, then passed. |
| Nonzero ack cannot reuse pre-turn confirmation; final-stop wrapper retains stall | A, 07:27:10 | Focused controller/transport/rotation/ready classes, 07:28:23 | `testNonzeroAckDoesNotReusePreStopConfirmationAndStopFailureRetainsStall` failed, then passed. |
| Runtime request capture and one failure subscription | B, 07:33:08 | B, 07:34:45 | Both focused coordinator tests failed assertions, then **2 passed**. |
| Blocked-operation latch snapshot without fabricated new receipt | C, 07:39:01 | Five Task 3 classes, 07:40:11 | Blocked-request test failed assertions; late pre-stop replacement guard already passed. Green **111 passed** at that point. |
| Preserve already-failed safety snapshot on contextual subscription | D, 07:46:29 | Five Task 3 classes, 07:49:20 | Initial contextual delivery was missing; focused assertion red, then green **112 passed**. |
| Pulse-stop failure carries the actual unconfirmed latch | E, 07:56:29 | Five Task 3 classes, 07:57:12 | Exact reported assertion: `Optional(FollowMotionStopOutcome.pending)` was not equal to `Optional(FollowMotionStopOutcome.failed)`; green **113 passed**. |

There were **7 new assertion-red → green cycles** in this continuation. The initial 2026-10-01 22:45:11 run had a **test compilation error** (the stream collector's optional return needed an explicit type), corrected before assertion red; it is not counted as behavioral red. The earlier transport receipt red/green cycles remain recorded in the prior checkpoint. Additional replacement/cancellation/all-four-purpose/legacy tests passed as regression guards; no passing safety behavior was weakened to manufacture a red.

Added **14 test methods** in this continuation: 12 controller/context/receipt guards and 2 coordinator routing/capture tests. Test support adds a controllable pre-stop suspension and contextual companion fake while retaining the original legacy fake.

### Final Task 3 verification

After review made snapshot fields read-only and ensured follow execution uses its captured profile, this exact bounded command ran once (07:59:06):

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/RoverControlTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

**113 passed, 0 failed, 0 skipped**, confirmed with:

```bash
xcrun xcresulttool get test-results summary --path '/Users/hungmai/Library/Developer/Xcode/DerivedData/astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.02_07-59-06--0700.xcresult'
```

`git diff --check` and the intended API/ownership diff review passed. New/updated untracked Swift files and this plan receive `git diff --no-index --check /dev/null <path>` at handoff. No unresolved verification failure, timeout or critical dependency blocker. No commits/push, installation/launch outside authorized simulator tests, physical rover action, or edits to unrelated workflow/configuration assets.

**Next scoped work, when requested:** Task 4's stage events and authoritative watchdog snapshot, followed by Tasks 5–7. Runtime full structured pulse evidence, shared failure formatter/reducer/race handling, evaluated tracker/shared 1 Hz budget and final integrated full SDK/app/build checks remain unimplemented/unverified; the earlier 441 SDK / 29 app passes are not claimed as current final coverage.

## Task 4 partial checkpoint — 2026-10-02

Stopped after the smallest current red/green slice, per the user's updated direction. **Task 4 is not complete.** Its original compound checkboxes remain unchecked: the new watchdog getter is complete, but its controller pairing/trace integration is not.

### Implemented and verified

- `swift/Sources/RoverNav/DriveProgressWatchdog.swift`: immutable read-only `DiagnosticSnapshot` and `diagnosticSnapshot(distanceToGoal:now:)`, exposing the actual stored best-distance checkpoint / last-progress `Date`, current error-distance improvement, elapsed `Date` duration and existing interval/required progress.
- `swift/Tests/PhroverKitTests/NavigationFollowScanDiagnosticsTests.swift`: `testWatchdogSnapshotExposesActualCheckpointWithoutChangingBoundaryPolicy` verifies insufficient progress at 2.499 versus 2.500 seconds; below 0.05 versus 0.05 progress; adequate-progress checkpoint/time reset; explicit nil checkpoint after reset; and negative progress when distance increases.
- `observe` and `reset` are unchanged. No controller/motor/event implementation, extra pose sampling, new timer/authority, or safety-policy edit occurred in this Task 4 slice.

### Exact command and results

Run from repository root:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testWatchdogSnapshotExposesActualCheckpointWithoutChangingBoundaryPolicy \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

| Run | Actual result |
| --- | --- |
| 08:16:25, minimal getter declarations/stub | **Assertion red**: missing checkpoint/progress/time measurements. |
| 08:17:02, getter implementation | One failed assertion: elapsed `2.4989999532699585` versus `2.499` with `1e-12` accuracy. Inspected the actual `.xcresult`; this was test-clock precision from constructing a distant `Date` epoch, not changed watchdog behavior. |
| 08:18:07, test epoch at `Date(timeIntervalSinceReferenceDate: 0)` | **1 passed, 0 failed, 0 skipped**. No production policy change or weakened assertion tolerance. |

Final tally was confirmed with:

```bash
xcrun xcresulttool get test-results summary --path '/Users/hungmai/Library/Developer/Xcode/DerivedData/astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.02_08-18-07--0700.xcresult'
```

`pgrep -fl 'xcodebuild|xctest|Simulator.*Runner'` found **no running matches** at handoff. `git diff --check` passed; intended watchdog diff confirms only the additive snapshot API, not `observe`/`reset` edits. No full suite/app/build rerun; Task 3's 113-pass result remains its prior scoped evidence, not a Task 4 integration result.

### Remaining Task 4 work / next slice

Start next with an assertion-red completed-pulse trace using injected monotonic/UTC clocks and the existing synchronous sink. Implement a narrow per-operation trace unit and controller-owned emitting boundaries. Pair the new watchdog snapshot with yaw/read time at actual initialization/reset, using only existing authoritative pose samples. Then cover progress/failure/wraparound traces and every send/wait/stop/settle/confirmation cancellation boundary, explicit interrupted ends, stop identity/origin/latch/receipt fields, stale callbacks and complete version-1 schema. Run focused rotation/diagnostic regressions after integration. Tasks 5–7 remain unchanged and pending.

## Task 4 execution evidence — 2026-10-02 runtime integration

**Task 4 complete; Tasks 5–7 pending.** This continuation supersedes the preceding partial checkpoint. It adds **11 real-controller diagnostic test methods** and a detection-origin assertion in an existing coordinator test. Final affected verification: **135 passed, 0 failed, 0 skipped**. No full SDK/app/build run, commit, push, package installation or physical rover activity.

### Runtime integration and ownership review

- New `swift/Sources/PhroverKit/Nav/FollowScanDiagnosticTrace.swift` owns bounded per-operation samples, one current pulse's timings, checkpoint pairing and synchronous payload capture. It has no pose provider, motor closure, timer, observation queue or task. The controller owns the existing motor loop and serialized confirmation tasks.
- `NavigationController` defaults to a synchronous emitter backed by `RuntimeFileLog.append`; internal tests inject the existing emitter with independently controlled monotonic/UTC clocks. All required `follow_scan.*` events are connected at entered stages, including send failure/cancellation responses, interrupted waits, stop identities/origins, cleanup, failure and operation completion. `follow_motion.failure_resolution` remains Task 5.
- Task 3's generation/request token/controller operation ID mapping is retained. Direct public follow-scan calls also reserve operation evidence, with null unknown session/phase. Pulse indices start at one and are null outside pulses and for non-pulse stop responses/completion. Stale responses retain their captured operation context.
- Operation begin occurs before pre-stop. Its target yaw is explicitly null/unavailable until the **existing post-prestop start-pose sample** establishes the target. No extra pose read is used to fill that field. Completed one-pulse execution still uses exactly three reads: start, pre-pulse, next evaluation. Lost post-settle pose ends the entered settle with a null post sample and unavailable current watchdog progress, retaining the known checkpoint pairing.
- Profile, raw radians, signed six-decimal display fields, source-age/pairing unknowns, per-stage host timing, final sample/error, last reached stage, stop outcome and authoritative latch are included. Actual returned transport receipts supply HTTP status/acknowledgement and UTC acknowledgement age; legacy closures report unknown fields. UTC acknowledgement age is labelled `transport_utc`; it is not invented monotonic acknowledgement time. Watchdog elapsed is labelled with its existing controller `Date` policy.
- The controller observes **one unchanged watchdog**, pairs its actual initialization/reset checkpoint with the already-read yaw/host read time, and snapshots its actual error-distance metric. There is no second threshold or yaw-displacement watchdog. `observe`/`reset`, 2.5 s/0.05 rad, selected tolerance, cap/gain, pulse/settle waits and generic tuning are unchanged.
- Follow-only continuation guards now recheck cancellation/fencing/latch after acknowledgement read, send, pulse wait, pulse stop, settle and final confirmation. No nonzero command or new settle follows the tested cancellation boundaries. The existing pulse-stop failure latch assignment is captured before response emission; cancellation still cannot acknowledge stopping. Serialized stale success does not clear a newer failed-stop latch.
- Detection attribution is captured at the coordinator's existing detection-stop boundaries (initial scanning-to-alignment/following and reacquisition) and propagated through an immutable task-local origin to the existing stop call. This is diagnostic-only capture; it adds no cleanup owner, motor task, failure reducer, operator formatter or association policy.

### Executed red/green slices

All commands ran from `/Users/hungmai/Sites/Astral/astral-sdk`, serially, with a 180-second tool bound and 60-second per-test limits. Every production slice below followed an executed assertion-red. Existing watchdog/math/safety behavior was retained as regression coverage rather than deliberately weakened.

The complete single-class red command (runs at 08:33:46, 08:39:04, 08:42:17, 08:45:39, 08:51:50, 08:54:51, 08:58:42 and 09:01:56) was:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

Greens through 08:52:31 used the same command plus these two concrete selectors:

```bash
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests
```

| Slice | Assertion-red | Green | Actual evidence |
| --- | --- | --- | --- |
| Completed pulse | 08:33:46 | 08:37:49 | Missing event list/pulse; exact waits, 40 ms send latency, receipt unknowns, raw/display angles, profile, correlation and three pose reads pass. |
| Cancellation boundaries | 08:39:04 | 08:40:27 | Eight suspended boundaries: pre-stop, acknowledgement read, send, pulse wait, pulse stop, settle, arrival stop and final serialized confirmation/handoff. Missing cancel/interrupted events and prohibited later waits fail before guards/instrumentation, then pass. |
| Failure evidence | 08:42:17 | 08:44:22 | Send, pulse-stop, independent pre-stop and watchdog failures; typed reason, real failed status, failed stage, latch and blocked next request pass. |
| Retained stage timings/receipt clock and lost post sample | 08:45:39 | 08:47:28 | Missing summary timings, checkpoint display, UTC acknowledgement age, nullable non-pulse correlation and missing settle-end on pose loss fail, then pass. Wraparound has signed delta/improvement +0.3 rad. |
| Public/caller cancellation | 08:51:50 | 08:52:31 | Missing caller cancel and uncorrelated public-cancel stop events fail, then pass with no nonzero send after cancelled pre-stop. |
| Detection origin | 08:54:51; coordinator 08:56:03 | 08:57:22 | Adapter/controller initially reports independent origin; production coordinator detection initially lacks attribution. Both pass after synchronous source capture. |
| Availability/final schema | 08:58:42 | 09:00:10 | Missing unknown/unavailable reasons, final signed displays and last-stage key fail, then pass. |
| Lost-pose current watchdog metric | 09:01:56 | 09:03:47 | Reusing the prior progress value after pose loss fails; current progress is now null/unavailable while known checkpoint remains. |

The separate detection-owner red command was:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests/testProductionDetectionStopsScanImmediatelyAndAlignsWithoutBlockingFrames \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

Build/fixture failures were resolved, not counted as behavioral reds: 08:37:00 required splitting a large typed dictionary for Swift type checking; 08:47:00 exposed an omitted emitter UTC accessor, corrected before green. The 08:49:41 additional watchdog regression failed only because a distant UTC epoch yielded elapsed `2.4989999532699585`; moving the fixture to `Date(timeIntervalSinceReferenceDate: 0)` preserved strict `1e-12` assertions and passed without changing production. Actual-controller 2.499/2.500, 0.049/0.05 reset, backwards improvement, cancelled pulse-stop/independent-stop success and failure, and stale successful pre-stop are regression guards.

### Final affected verification

After the last production change, 09:03:47:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/RoverControlTests \
  -only-testing:PhroverKitTests/RotationCommandTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet

xcrun xcresulttool get test-results summary --path '/Users/hungmai/Library/Developer/Xcode/DerivedData/astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.02_09-03-47--0700.xcresult'
```

| Class | Passed |
| --- | ---: |
| NavigationFollowScanDiagnosticsTests | 28 |
| NavigationRotationWatchdogTests | 12 |
| NavigationFollowReadySignalTests | 9 |
| FollowDiagnosticEventTests | 8 |
| FollowMeCoordinatorTests | 64 |
| RoverControlTests | 12 |
| RotationCommandTests | 2 |
| **Total** | **135** |

`git diff --check` passed. Intended diff/ownership review confirms public signatures and legacy behavior retained, synchronous sinks, no extra pose reads, no new motor tasks or relaxed parameters. Untracked new/updated diagnostic files and this plan receive individual `git diff --no-index --check /dev/null <path>` checks. `pgrep -fl 'xcodebuild|xctest|Simulator.*Runner'` returned no running matches after verification. Unrelated `.serena/project.yml`, `.opencode/`, `AGENTS.md` and `.superpowers` assets are preserved.

**Remaining safety/acceptance work:** Task 5's correlated failure reducer/formatter and race-priority integration, Task 6's tracker-owned association/shared budget, Task 7's final integrated lifecycle/full SDK/app/build verification. Runtime events establish requested/host timings and AR yaw evidence, not physical motor-on time, braking or encoder measurements. Supervised physical acceptance remains separately authorized.

## Task 5 complete checkpoint — 2026-10-02

**Task 5 complete; next work is Tasks 6–7.** This scoped continuation supersedes the earlier Task-5-pending statements. Added **3 pure reducer tests and 5 coordinator tests**, with **seven executed assertion-red → green cycles**. Final affected verification after the last production edit: **129 passed, 0 failed, 0 skipped**. No full suite/app/build verification was run for this task.

### Implementation and bounded ownership

- New `swift/Sources/PhroverKit/FollowMe/FollowMotionFailureResolution.swift` is a pure value reducer and shared formatter. Its explicit key is generation/controller operation ID; when the controller ID is unknown, it isolates records with the actually available generation/request token instead. Request tokens are not treated as controller IDs. Unknown actual purpose remains unknown, so a legacy `.stalled` does not become `no_yaw_progress` merely because its request was a scan.
- Specific typed reasons survive `.commandFailed` (the existing transport wrapper) and `.cancelled`. Captured `.followScan` plus `.stalled` produces `no_yaw_progress` and the exact approved pending/confirmed wording. Failed stop is sticky, has priority 3, and retains the stall alongside the stop outcome. Stale confirmation cannot advance pending to confirmed. Non-stall reasons use specific shared messages.
- Coordinator scan/following, alignment and ready results consume the immutable contextual result before current-generation completion guards discard it. One contextual stream, or the legacy safety stream, feeds the same reducer. Legacy streams attach only the known request mapping; actual controller ID/purpose/profile/receipts stay unknown.
- The existing `finish` stop task remains the single terminal cleanup owner and drains existing detection/independent confirmation before its cleanup. The stream remains available while terminal deliveries drain. Pending failure is published before suspension, and acknowledgement updates the shared resolution only at the actual `stopAndConfirm` return. Concurrent Stop and the second delivery do not create another cleanup owner.
- Retention is **at most one terminal delivery record**, not a dictionary/history of sessions. Stream/result/cleanup source drain prunes it; start and successful explicit failed-stop recovery also clear the record/request mapping. An old in-flight result can enrich a still-owned terminal record without resuming work. After pruning, stale delivery is logged with its available facts without rebuilding retained history or publishing UI. No stale callback can undo failed-stop admission blocking or resurrect a recovered/stopped/restarted session.
- Synchronous `follow_motion.failure_resolution` events use the existing version-1 emitter and sink. Each includes captured generation/controller ID/purpose/phase, request token, delivery source, retained and delivered typed reason, diagnostic reason, stop outcome, formatter message/priority, stale and deduplicated flags. No logging awaits, extra motor task/timer, controller latch edit, pose read, association policy, deadline or tuning change was introduced.
- Existing cancellation-safety expectation was legitimately updated from `Navigation safety failure.` to `Navigation cancelled.` at both pending and post-stop assertions; the fencing/goal-count/stop-count expectations remain intact. Existing ready/interruption/failed-stop recovery behavior stays green.

### Exact red/green commands and evidence

All commands ran serially from `/Users/hungmai/Sites/Astral/astral-sdk`, with a **120-second tool timeout**, parallel testing disabled, and **60-second per-test limits**. Minimal compilable declarations preceded the first pure test: its red was failing assertions, not a missing-type build failure.

Pure runs (09:10:08 red, 09:11:19 green; 09:15:55 red, 09:16:52 green; 09:18:14 red, then 09:19:45 combined green):

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

Correlated coordinator runs (09:12:37 red → 09:14:23 green; concurrent-Stop regression green 09:17:38; pruning red 09:21:15 → green 09:22:18):

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests/testCorrelatedFailureOrdersPublishPendingThenOnlyAcknowledgedStopAndRetainFailedStop \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

Captured failed-stop/recovery runs (09:23:25 red → 09:24:06 green; late result after explicit recovery 09:26:58 red → 09:27:32 green):

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests/testCapturedFailedStopCannotBeDowngradedByCleanupSuccessOrAuthorizeRestart \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

Combined pure/coordinator runs (09:14:44 exposed the two old generic cancellation-message expectations; updated to the specific message, then **72 passed** at 09:19:45):

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

| Slice | Executed assertion-red evidence | Green |
| --- | --- | --- |
| Pure reason/stop precedence | Both orders failed exact pending/confirmed/blocked message, diagnostic reason, failed-stop outcome and priority assertions with the minimal reducer. | 09:11:19 |
| Coordinator channel convergence | Both orders exposed generic wording, missing resolution events and lost second delivery after stream cancellation. | 09:14:23 |
| Explicit operation key | `nil` versus `Key(generation: 7, operationID: 91)`; foreign-generation/operation and stale-ack assertions are regression guards. | 09:16:52 |
| Unknown controller request isolation | Foreign request token incorrectly advanced legacy stop outcome: `failed` versus `unknown`. | 09:19:45 |
| Completed delivery pruning | Late stale delivery reported deduplicated `true` versus expected `false` after all sources drained, exposing retained historical record. | 09:22:18 |
| Captured stop failure admission | `XCTAssertFalse` failed because cleanup success permitted restart despite the retained failed-stop resolution. | 09:24:06 |
| Explicit recovery ends terminal ownership | Old result after successful explicit Stop retry changed `.stopped` back to the blocked failure. | 09:27:32 |

Phase change during suspended detection confirmation, cancelled result after stall, concurrent Stop, old-session stream/result after restart and legacy unknown-purpose behavior passed as regression guards; they are not claimed as additional red cycles. No toolchain/simulator setup failure or test timeout occurred. Earlier automatically retained Xcode bundles can be evicted; the observed command output establishes the first reds, and later red summaries were inspected with `xcresulttool`.

### Final affected verification after the last production edit

The initial 09:24:48 affected run passed 129 tests. After the recovery-boundary correction, the same selectors were rerun at **09:27:49** with the final explicit result bundle:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/task5-affected-final-20261002.xcresult -quiet

xcrun xcresulttool get test-results summary --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/task5-affected-final-20261002.xcresult
```

| Class | Passed |
| --- | ---: |
| FollowMotionFailureResolutionTests | 3 |
| FollowMeCoordinatorTests | 69 |
| FollowDiagnosticEventTests | 8 |
| NavigationFollowScanDiagnosticsTests | 28 |
| NavigationRotationWatchdogTests | 12 |
| NavigationFollowReadySignalTests | 9 |
| **Total** | **129** |

Final `git diff --check` and individual untracked reducer/test/plan whitespace checks passed. Reviewed intended changes against the supplied uncommitted Tasks 1–4 context; unrelated `.serena/project.yml`, `.opencode/`, `AGENTS.md` and `.superpowers` assets are preserved. No staging, commit, push, package installation, app installation/launch or physical rover work.

**Next scoped checkpoint:** Task 6: tracker-owned evaluated association diagnostics and the shared per-session healthy-summary budget. Task 7: remaining deterministic lifecycle boundaries, then final affected/full non-live SDK, app unit and unsigned app build verification. Those tasks and physical acceptance remain pending; this 129-test result does not claim their completion.

## Task 6 complete checkpoint — 2026-10-02

**Task 6 complete; next work is Task 7 only.** This section supersedes historical Task-6-pending checkpoints. Added **6 association diagnostic tests and 2 coordinator tests**, with **seven executed assertion-red → green vertical slices**. Final affected verification after the last production edit: **92 passed, 0 failed, 0 skipped**. Full SDK/app/build verification belongs to Task 7 and was not run here.

### Implementation and ownership

- New `swift/Sources/PhroverKit/FollowMe/FollowAssociationDiagnostics.swift` contains immutable evaluation facts, transient candidate evidence/primitive payload formatting and the pure per-session summary budget. It contains no eligibility, association thresholds, motor authority, observation queue or frame history.
- `FollowTargetTracker` owns the evaluated initial/continuity/reacquisition variants. Existing public methods delegate and discard evidence. One gate execution preserves confidence/age/finite-geometry ordering, inclusive centralized thresholds, stable input/tie order, world-distance rejection before IoU and IoU short-circuit before screen displacement. Unentered gates have null metrics with `not_evaluated`; rejected eligibility never executes an association gate. Existing tracker and stand-off tests remain green.
- Selected/per-candidate facts include frame-local IDs, confidence, normalized box, world X/world Z `Vec2` position, paired rover pose, exact numeric range/heading, eligibility/match evidence and stable reasons. Heading uses the existing diagnostic `[-π,π)` normalization without changing RoverNav's control math. Geometry is derived solely from the observation pair, even when a batch supplies a different/latest rover pose; nonfinite geometry is explicitly unavailable.
- Association records contain the full version-1 envelope, observation/frame health, actual projected/eligible/matched counts, selected candidate or null, evaluations, actual executed gate metrics and thresholds. Initial matched count is null with `not_applicable_initial_selection`. Empty projected input says only `no projected person candidate available`; no raw-detector/projection-stage counts or upstream-failure inference is introduced. Selection is labelled `spatial_association_only`.
- Coordinator consumes tracker evaluations at existing decision boundaries before motion awaits, using the existing synchronous emitter/sink. One `FollowSummaryBudget` replaces `lastFrameLogTime`, resets at session start, shares allowance across perception and continued summaries, and prefers combined association/health records. Healthy transitions emit immediately and occupy the current summary slot; stable continued records become eligible at the exact one-second boundary. Identical lost/ambiguous repeats are suppressed. The existing pause-frame revalidation can produce initial and continued transitions at the same timestamp; these are real distinct outcomes and bypass periodic budgeting.
- No new suspension, motor task/timer, pose sampling, coalescing change, safety policy, tuning, deadline or failure-resolution change. Retained diagnostic state is two budget values, not candidate/frame history. Existing issue/recovery transitions and motion/failure/stop emissions still bypass summary budgeting.

### Exact commands and vertical evidence

All commands ran serially from `/Users/hungmai/Sites/Astral/astral-sdk` with **120-second tool timeouts**, parallel testing disabled and **60-second per-test limits**. `./scripts/test-swift-sdk.sh --print-udid` returned the simulator below. Minimal compilable evidence declarations preceded assertion-red runs; compile-only failures are not counted as behavioral red.

Command A — association-only red/green runs:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowAssociationDiagnosticsTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

Command B — tracker-focused greens:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowAssociationDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowTargetTrackerTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

Command C — coordinator transitions red/green:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests/testAssociationTransitionsEmitImmediatelyAndIdenticalLostAmbiguousRepeatOnlyOnce \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

Command D — coordinator shared-budget red/green:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests/testHealthyFrameAndAssociationUseOneSessionBudgetAndPreferCombinedSummary \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet
```

| Slice | Assertion-red command/time | Green command/time | Observed behavior |
| --- | --- | --- | --- |
| Initial evidence | A 09:32:34 | A 09:34:21 | Empty evidence failed eligible count, selected index and candidate count; inclusive confidence/age, tie order, skipped age and paired geometry then pass. |
| Continuity/reacquisition | A 09:35:13 | B 09:37:58 | Missing matched/eligible counts and selected index fail; world-distance/IoU short-circuit, exact reacquisition boundary, loss and ambiguity then pass. |
| Association envelope/empty input | A 09:38:56 | A 09:40:16 | Missing schema payload/health/count/null/selected facts fail, then complete precise payload passes. |
| Pure shared budget | A 09:41:00 | A 09:41:39 | Unthrottled repeated healthy/lost/ambiguous output and absent previous outcome fail, then exact one-second/shared-slot/reset behavior passes. |
| Coordinator transitions | C 09:42:41 | C 09:43:32 | Missing immediate association records and previous outcomes fail, then initial→continued→lost→ambiguous→reacquired→continued passes with identical loss/ambiguity repeats suppressed. |
| Coordinator combined budget | D 09:44:46 | D 09:46:29 | Separate `follow_frame` budget emits extra healthy records and omits envelope at restart; one budget/combined summaries/reset then pass. |
| Diagnostic half-open heading/unknown health | A 09:49:23 | A 09:50:04 | +π instead of −π and missing inference/tracking availability reasons fail; diagnostic-only normalization and explicit unknowns then pass. |

Intermediate failures were resolved honestly: B 09:36:14 found the preserved CGRect IoU result `1.000000000000001`, so the test now uses `1e-12` accuracy instead of forcing production to round/clamp. A 09:39:52 failed Swift type-checking a large inferred dictionary; an explicit dictionary type fixed the build. D 09:45:33 exposed the fixture's overlooked existing pause-frame revalidation: actual transitions were both at 0.5 s, moving periodic eligibility to 1.5 s. The fixture now checks that behavior and 1.499/1.500 and 2.499/2.500 boundaries. The first affected run at 09:47:45 failed to compile an ambiguous `.infinity` test literal; specifying `CGFloat.infinity` fixed it, and the 09:48:07 run passed **91 tests**. Finite/boundary/legacy decision matrix coverage is a passing regression guard, not an additional red claim. No test timeout or simulator blocker occurred.

### Final affected verification

After the last production edit, at **09:50:28**:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowAssociationDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowTargetTrackerTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -quiet

xcrun xcresulttool get test-results summary --path /Users/hungmai/Library/Developer/Xcode/DerivedData/astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.02_09-50-28--0700.xcresult
```

| Class | Passed |
| --- | ---: |
| FollowAssociationDiagnosticsTests | 6 |
| FollowTargetTrackerTests | 7 |
| FollowMeCoordinatorTests | 71 |
| FollowDiagnosticEventTests | 8 |
| **Total** | **92** |

`git diff --check` and individual `git diff --no-index --check /dev/null` checks for the new association source/tests and updated plan passed. Reviewed the intended tracker/coordinator changes against the supplied Tasks 1–5 checkpoint; unrelated work and `.superpowers` assets are preserved. All edits used `apply_patch`. No staging, commit, push, application installation/launch or physical rover activity.

**Next checkpoint: Task 7**, remaining deterministic lifecycle boundaries and final affected/full non-live SDK, app-unit and unsigned-build verification. Task 7 and physical acceptance remain pending; the 92-test Task-6 run is not a full-suite claim.

## Task 7 complete — historical verification, 2026-10-02 (superseded below)

This section supersedes all earlier pending/checkpoint status. **Final full suites passed after the last production edit**, not merely at the supplied Tasks 1–6 checkpoint. All test/build commands ran serially from `/Users/hungmai/Sites/Astral/astral-sdk`, with **1,200,000 ms tool timeouts**, parallel testing disabled, and **60-second default/maximum per-test allowances**. Simulator selection returned `EEA52712-371D-4FF6-B8EF-A2C78319D57F` (iPhone 17 Pro, iOS 26.5).

### Boundary coverage and strict red/green

Added six test methods, at the approved coordinator and real-controller seams:

| Test | Evidence |
| --- | --- |
| `FollowMeCoordinatorTests.testInvalidAndFutureObservationTimestampsCannotBeRescuedByDiagnostics` | NaN, ±infinity and future frame timestamps remain stale with telemetry enabled; no scan/alignment/translation. Passed without a production change. |
| `FollowMeCoordinatorTests.testDetectionAtRealControllerSuspensionsFencesScanBeforeConfirmedAlignment` | Real adapter/controller at suspended send, 200 ms pulse wait, pulse stop and 300 ms settle: detection fence, one scan, confirmed detection stop before continuous alignment, no subsequent stale send. Passed without a production change initially; retained after the tighter race fix. |
| `FollowMeCoordinatorTests.testTenSecondReacquisitionDeadlineFencesRealSuspendedPulseWithoutExtension` | Healthy empty frames keep perception fresh; real pulse suspended until after 9.999/10.000 boundary. Deadline fences immediately, interrupted wait emits, no settle/new increment/late-target resurrection. Passed without a production change. |
| `FollowMeCoordinatorTests.testDetectionFencesSuspendedAckBeforeQueuedAlignmentTaskCanRun` | **Assertion red:** one queued scan send after detection versus required zero. Green after synchronous controller-owned detection fence. |
| `NavigationFollowScanDiagnosticsTests.testWatchdogCheckpointTimeIsObservationBoundaryNotEarlierPoseRead` | **Assertion red:** checkpoint time `0.0` versus `0.4` after acknowledgement latency. Green after separate observe-boundary checkpoint time capture. |
| `NavigationFollowScanDiagnosticsTests.testSerializedStopResponsesKeepTheirOwnReceiptAcrossConcurrentConfirmation` | **Assertion red:** stop 1 reported stop 2's HTTP `202` instead of `201` (and its acknowledgement time). Green after stop-specific receipt capture. |

Also strengthened existing requested-search-budget coverage: every prefix stays ≤2π, a 0.7-rad increment yields nine requests with last request `0.6831853071795862`. Strengthened the existing exact reacquisition deadline test to verify one terminal stop request and no new scan/goal after late completion/frame.

Existing passing regression coverage was inspected and retained, not artificially made red:

- `testProductionPauseProcessesPerceptionButNeverMovesBeforeFiveSeconds` and `testProductionReadinessWindowStartsAfterPauseAndFailsAtTenSeconds`: full 4.999/5.000 stationary boundary and separate readiness window.
- `testFreshnessBoundaryAndUnavailableTrackingRemainFailClosed`: inclusive 0.500 age and rejection at 0.501. `testContinuousOutageStopsOnceAndKeepsOriginalRecoveryDeadline`: outage begins at 0.1, remains active at 2.099 (elapsed 1.999), fails at 2.1 (elapsed 2.000), repeated bad frames request only one outage stop. Pending-stop/late-healthy-frame and newest-frame/lifecycle tests remain included.
- Coordinator ready-signal tests cover once-per-session, fresh post-stop baseline, partial/interrupted signal and no reacquisition retry; all nine `NavigationFollowReadySignalTests` cover actual requested/measured 10 cm, clearance/travel/watchdog limits and final acknowledgement handoff.
- Coordinator stand-off, hold, departure, no reverse, stale-operation/session, safety/interruption and inhibition tests; all router tests; all app units including local Stop without Thinking/brain fallback and leave-Talk inhibition passed.

The 09:56:57 coordinator run passed **73**, and the 09:58:18 coordinator run after adding the real deadline test passed **74**. These coverage additions were already green. The two new review regressions ran assertion-red at **10:03:29** before either corrective production edit:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testWatchdogCheckpointTimeIsObservationBoundaryNotEarlierPoseRead \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests/testDetectionFencesSuspendedAckBeforeQueuedAlignmentTaskCanRun \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/task7-review-boundaries-red.xcresult -quiet
```

Stop-receipt regression ran assertion-red at **10:05:50**, before its production correction:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testSerializedStopResponsesKeepTheirOwnReceiptAcrossConcurrentConfirmation \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/task7-stop-receipt-check.xcresult -quiet
```

After all three corrections, both complete classes ran green at **10:07:19**, **105 passed / 0 failed / 0 skipped**:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/task7-stop-receipt-green.xcresult -quiet
```

### Task-7 corrective file map and review

| File relative to root | Task-7 change |
| --- | --- |
| `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift` | Fence detected search/reacquisition scan synchronously before state transition or awaited confirmation. |
| `swift/Sources/PhroverKit/FollowMe/FollowMeDependencies.swift` | Internal contextual inhibition hook with compatibility default; original public protocol requirements preserved. |
| `swift/Sources/PhroverKit/FollowMe/NavigationFollowMeMotion.swift` | Delegate inhibition to controller. |
| `swift/Sources/PhroverKit/Nav/NavigationController.swift` | Synchronous generation/evidence fence and loop cancellation, retaining loop for serialized draining; capture each stop receipt through existing transport await. |
| `swift/Sources/PhroverKit/Nav/RotationDiagnosticModels.swift` | Transient per-stop TaskLocal receipt capture, distinct from operation result evidence. |
| `swift/Sources/PhroverKit/Nav/FollowScanDiagnosticTrace.swift` | Watchdog observe-boundary checkpoint time and explicit per-stop response receipt. |
| `swift/Tests/PhroverKitTests/FollowMeCoordinatorTests.swift` | Four new lifecycle/race tests and two strengthened existing budget/deadline tests. |
| `swift/Tests/PhroverKitTests/NavigationFollowScanDiagnosticsTests.swift` | Two new real-controller telemetry/receipt race tests. |
| This plan | Current status, completed checkboxes, file map and actual final evidence. |

Independent source review ran concurrently **read-only**, with no test/build overlap: `codex exec --sandbox read-only --ephemeral` reported the three concerns above; deterministic tests reproduced all three before corrections. A second independent read-only follow-up during final verification reported **no actionable findings** and confirmed all three corrections, controller motor ownership, stop serialization/latch policy and public compatibility. Reports are in the temporary evidence directory as `task7-review.txt` and `task7-review-followup.txt`. Review does not claim runtime or physical validation.

No new motor owner, timer, pose read, logging await, observation queue, deadline/gate/watchdog-policy change or tuning relaxation. The synchronous fence inhibits continuation only; confirmed stop still owns authorization for alignment. Per-stop receipt capture lives until its waiter drains, and formatting receives that stop's immutable receipt even if operation-wide evidence advances. Complete event-envelope/privacy/precision, tracker parity and summary-budget tests are in final affected coverage.

### Final executed commands and totals

These ran serially **after the last production change**:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowAssociationDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/RotationCommandTests \
  -only-testing:PhroverKitTests/RoverControlTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/FollowTargetTrackerTests \
  -only-testing:PhroverKitTests/ARFollowMePerceptionSourceTests \
  -only-testing:PhroverKitTests/OperatorCommandRouterTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/task7-affected-postfix.xcresult -quiet

SIM_UDID=EEA52712-371D-4FF6-B8EF-A2C78319D57F ./scripts/test-swift-sdk.sh \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/task7-sdk-postfix.xcresult -quiet

xcodebuild test -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverOperatorTests -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/task7-app-final.xcresult -quiet

xcodebuild build -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
```

| Final check | Actual result |
| --- | --- |
| All 12 affected SDK classes, 10:08:11 | **176 passed, 0 failed, 0 skipped** |
| Full non-live SDK, 10:08:24 | **489 passed, 0 failed, 0 skipped** |
| All app unit tests, 10:08:51 | **29 passed, 0 failed, 0 skipped** |
| Unsigned generic iOS build after app tests | **Exit 0** |

Totals were read using `xcrun xcresulttool get test-results summary --path` for each actual bundle above. Earlier affected verification at 09:58:49 passed **173** before the three review regressions were added. The earlier full SDK attempt at 09:59:03 had **485 passed, 1 failed, 0 skipped**, due to `ARSharedMissionFrameCalibratorTests.testThirdAcceptedSampleEmitsContextualProgressBeforeAcceptance` exceeding its **60-second** allowance. Its unchanged source ingests three calibration frames with `Task.yield()` while waiting for stream acceptance; the timeout is recorded as an observed intermittent scheduling-sensitive test failure, not a proven root cause or follow-me regression. One isolated recheck at 10:01:29 passed; the final full SDK rerun above also passed it. No timeout relaxation, test exclusion or unrelated test edit was used. If that blocker had repeated, execution would have stopped for reporting.

The isolated recheck command was:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests/testThirdAcceptedSampleEmitsContextualProgressBeforeAcceptance \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/task7-calibration-recheck.xcresult -quiet
```

Observed final warnings/diagnostics: SDK commands printed `IDERunDestination: Supported platforms for the buildables in the current scheme is empty.` and succeeded with the explicit simulator destination. Both app tests/build emitted the existing iOS-26 `UIScreen.main` deprecation at `examples/PhroverOperator/PhroverOperator/Views/ConversationView.swift:269`. No warning was treated as a hidden failed check. Review CLI had unrelated MCP authentication/transport startup diagnostics but completed both source reviews.

Final tracked `git diff --check` and individual untracked implementation/plan whitespace checks passed. Branch/HEAD remain `feat/follow-me` / `c04fbcc`; unrelated `.serena/project.yml`, `.opencode/`, `AGENTS.md` and `.superpowers` assets were preserved. No staging, commit, push, manual app installation/launch, rover connection or physical motion. **No unresolved implementation blocker; physical acceptance remains a separately authorized task.**

## Caller-cancellation correction — source fixed; final verification blocked, 2026-10-02

**This section governs current status.** A subsequent independent review identified a High defect missed by the earlier reviews and coverage: cancelling the contextual caller did not cancel the unstructured running controller loop. Existing stage tests invoked `stopAndConfirm` separately and therefore did not establish caller-only cancellation. Earlier complete/green status above is historical, not acceptance of this correction.

### Strict assertion-red before corrective production edits

Added six tests at the approved real-controller/contextual adapter seam. No external `stopAndConfirm`, public `cancel`, or coordinator inhibition rescues the caller-only tests.

| Regression | Executed red | Current outcome |
| --- | --- | --- |
| `testContextualCallerCancellationAloneDrainsScanAndRequiresIndependentStop` | 10:19:11, missing fence/cancel, additional pulse/send and absent independent confirmation. | Green; expanded across ack read, send, pulse wait, pulse-stop response, settle and final confirmation. Suspended independent acknowledgement gates terminal return. |
| `testContextualCallerCancellationAloneFailedStopLatchesAndBlocksMotion` | Same 10:19:11 run, missing independent failure/latch and further motion admission. | Green across the same six boundaries. Cancelled loop cleanup is not acknowledgement; failed/cancelled independent acknowledgement fails the result and blocks subsequent motion. |
| `testContextualCallerCancellationAlsoFencesAlignmentReadyAndFollowing` | 10:21:02, companion caller cancellation allowed additional sends/arrival rather than independently confirmed cancellation. | Green at ack-read/send boundaries for all three contextual request types. |
| `testQueuedCallerCancellationCleanupCannotStopAReplacementReservation` | 10:24:15, old operation issued two independent stops instead of one after replacement reservation. | Green after a second identity/reservation guard inside the queued cleanup task. |
| `testGenericReplacementWaitsForRunningCallerCancellationStopAndFailsClosed` | 10:30:40, two sends instead of one before old stop acknowledgement; generic replacement also arrived despite failed old stop. | Green for awaited generic navigation/rotation, successful/failed old independent stop. |
| `testCancelledHighPriorityContextualCallerCannotLaunchAfterPreStop` | Passed at 10:32:49 before adding post-pre-stop guards; **not claimed as a red**. | Passing regression guard for high-priority alignment/following caller cancellation with lower-priority cancellation actor hop. Explicit post-pre-stop cancellation/fence checks close the source-permitted scheduling window as part of the previously assertion-red companion cancellation slice. |

The first three failing test methods were executed before any cancellation-handler production edit. The queued-cleanup and generic-replacement failures were executed before their respective corrective edits. All reds were assertions, not build/tool setup failures or forced production weakening. Unfixed scan fixtures naturally finish after a second pulse so red cannot hang indefinitely. Expanded already-passing boundaries are regression guards, not additional red claims.

All commands ran serially from `/Users/hungmai/Sites/Astral/astral-sdk`, with **1,200,000 ms tool timeouts**, **60-second** default/maximum test allowances and parallel testing disabled. Exact red commands:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testContextualCallerCancellationAloneDrainsScanAndRequiresIndependentStop \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testContextualCallerCancellationAloneFailedStopLatchesAndBlocksMotion \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/caller-cancel-red.xcresult -quiet

xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testContextualCallerCancellationAlsoFencesAlignmentReadyAndFollowing \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/caller-cancel-companion-red.xcresult -quiet

xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testQueuedCallerCancellationCleanupCannotStopAReplacementReservation \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/caller-cancel-replacement-red.xcresult -quiet

xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testGenericReplacementWaitsForRunningCallerCancellationStopAndFailsClosed \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/caller-cancel-generic-red.xcresult -quiet
```

### Minimal corrective file map and ownership

| File | Correction |
| --- | --- |
| `swift/Sources/PhroverKit/Nav/NavigationController.swift` | Contextual `withTaskCancellationHandler`; bounded MainActor hop; operation-identity/owned-generation fence; cancel and drain owned loop, join independent serialized confirmed stop before freezing result. Guard again when queued cleanup runs. Contextual acknowledgement/pre-stop checks inhibit continuation. Awaited generic replacement joins existing outstanding confirmation instead of bypassing it, propagates failure and rechecks generation/latch. |
| `swift/Sources/PhroverKit/Nav/RotationDiagnosticModels.swift` | MainActor-owned reservation and one bounded per-operation cancellation-confirmation task. `true` means actual acknowledgement succeeded, `false` actual confirmation failed, `nil` superseded cleanup skipped and does not claim confirmation. |
| `swift/Tests/PhroverKitTests/NavigationFollowScanDiagnosticsTests.swift` | Six new tests above, with suspended transport/wait/confirmation gates and bounded red completion. |
| This plan | Superseded historical acceptance, reopened final SDK/app/build checks, actual red/green/blocker evidence. |

`onCancel` is `@Sendable` and cannot synchronously mutate MainActor controller state. It schedules one bounded actor hop; the controller verifies captured evidence identity and the actual owned generation before fencing/cancelling. A second check prevents delayed queued cleanup from touching a replacement reservation. Running confirmations are serialized before awaited generic replacement admission. The wrapper awaits its operation's cancellation confirmation before terminal snapshots. A failed stop is not cancelled-success or confirmed-stop evidence and retains the blocking latch and typed failure delivery. No global cancellation owner, new pulse timer, motor owner, pose read, logging await, deadline or tuning change. New tasks perform only operation-scoped cancellation/joining of the existing controller-owned confirmation path.

Transport/wait cancellation remains cooperative: a suspended send/stop must drain before independent confirmation can complete. These tests establish fencing and no *subsequent* nonzero command, not cancellation of a command already sent, physical braking, or an upper bound on noncooperative transport completion. Fixed yield counts in some scheduling probes are bounded liveness observations, not proof of every actor schedule; explicit continuation entry/acknowledgement gates establish the safety boundaries under test.

Independent source review ran concurrently read-only via `codex exec --sandbox read-only --ephemeral`, never running tests/builds. Its first report found the generic awaited-replacement bypass (then reproduced red) and the pre-stop scheduling window. The follow-up reported both addressed and **no new actionable source regression within scope**, while noting the yield-count scheduling limitation. Reports: temporary evidence directory `caller-cancel-review.txt` and `caller-cancel-review-final.txt`. No source review is claimed as runtime/physical proof.

### Current focused/affected verification — after the last production edit

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/caller-cancel-all-boundaries-green.xcresult -quiet

xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowAssociationDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/RotationCommandTests \
  -only-testing:PhroverKitTests/RoverControlTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/FollowTargetTrackerTests \
  -only-testing:PhroverKitTests/ARFollowMePerceptionSourceTests \
  -only-testing:PhroverKitTests/OperatorCommandRouterTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/caller-cancel-affected-complete.xcresult -quiet
```

| Current check | Actual result |
| --- | --- |
| Complete diagnostics/rotation/ready classes, 10:34:57 | **57 passed, 0 failed, 0 skipped** (36 diagnostics, 12 rotation, 9 ready) |
| All 12 affected SDK classes, 10:35:45 | **182 passed, 0 failed, 0 skipped** |
| Full SDK attempt, 10:36:00 | **494 passed, 1 failed, 0 skipped** — extra calibration event |
| One isolated calibration recheck, 10:36:54 | **1 passed, 0 failed, 0 skipped** |
| Full SDK rerun, 10:37:06 | **494 passed, 1 failed, 0 skipped** — 60-second calibration timeout; **stopped** |
| Final app unit/build after the final replacement/pre-stop fixes | **Not run** due to repeated full-suite blocker |

Exact full-suite/recheck commands:

```bash
SIM_UDID=EEA52712-371D-4FF6-B8EF-A2C78319D57F ./scripts/test-swift-sdk.sh \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/caller-cancel-sdk-complete.xcresult -quiet

xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests/testSuccessfulEmptyScanClearsScannerFailureOnce \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/caller-cancel-calibration-recheck.xcresult -quiet

SIM_UDID=EEA52712-371D-4FF6-B8EF-A2C78319D57F ./scripts/test-swift-sdk.sh \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/caller-cancel-sdk-verified.xcresult -quiet
```

The first failed SDK test was `ARSharedMissionFrameCalibratorTests.testSuccessfulEmptyScanClearsScannerFailureOnce`: expected scanner-failed and waiting-for-marker events, but received an additional `scanCompleted` for frame sequence 3. The isolated recheck passed. The full rerun then timed out `ARSharedMissionFrameCalibratorTests.testThirdAcceptedSampleEmitsContextualProgressBeforeAcceptance` after one minute, repeating the same timeout previously observed during historical Task-7 verification. Both calibration source and tests are unchanged. The underlying cause is **not diagnosed**; failures are not excluded, converted to follow-me reds, or excused by a claimed green full suite. No more retry/build attempts after repeated full-suite failure, as instructed.

### Superseded intermediate passes and observed warnings

Before the final generic-replacement/pre-stop corrections, intermediate affected coverage at 10:27:34 passed **180**, full SDK at 10:27:47 passed **493**, app unit tests at 10:28:15 passed **29**, and unsigned generic iOS build exited **0**. They establish that intermediate revision only. The app/build commands actually executed were:

```bash
xcodebuild test -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverOperatorTests -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/caller-cancel-app-final.xcresult -quiet

xcodebuild build -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
```

SDK commands emitted the existing `IDERunDestination: Supported platforms for the buildables in the current scheme is empty.` diagnostic. Intermediate app tests/build emitted the existing iOS-26 `UIScreen.main` deprecation at `ConversationView.swift:269`. Counts/failures were read with `xcrun xcresulttool get test-results summary --path` for the actual bundles, not inferred from quiet output. Final tracked `git diff --check` exited 0. Individual untracked model/test/plan `git diff --no-index --check /dev/null <file>` checks emitted no whitespace diagnostics; their exit code was 1 because no-index reports the new-file difference, **not exit 0**. A chained shell check consequently short-circuited; explicit subprocess capture verified each outcome, and branch/HEAD were checked separately (`feat/follow-me` / `c04fbcc`). Unrelated files/assets remain preserved. No staging, commit, push, manual installation/launch, rover connection or physical motion. **Next action requires resolving the calibration verification blocker, then rerunning full SDK → all app units → unsigned generic build on current source. Task 7 is not complete.**

## Calibration-blocker diagnosis and final verification — 2026-10-02

This section supersedes the preceding blocked checkpoint. User explicitly authorized investigation and fixes to complete Task 7, preserving assertions and the 60-second execution allowance.

### Executed capture and baseline proof

Before reading calibration implementation to form theories, ran the two original failing tests repeatedly. The first invocation used unsupported `-test-repetition-mode until-failure` and was rejected before tests ran; this is a command setup error, not behavioral red. Corrected to supported `-run-tests-until-failure`:

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests/testSuccessfulEmptyScanClearsScannerFailureOnce \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests/testThirdAcceptedSampleEmitsContextualProgressBeforeAcceptance \
  -test-iterations 30 -run-tests-until-failure -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/calibration-repro-current.xcresult -quiet

git worktree add --detach \
  /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/calibration-baseline-c04fbcc c04fbcc
```

The temporary parent was verified before creation. Ran the exact test command above from that detached worktree, replacing only result path with `calibration-repro-baseline.xcresult` in the same temporary parent. `git status --short` was empty before and after baseline execution. Main worktree was never checked out/reset. The owned baseline worktree remains available for evidence; it was not removed.

- **Current capture, 12:32:10:** 47 passing executions, one failure. Third-sample test timed out on **repetition 18**, exact cause `Test exceeded execution time allowance of 1 minute`. Empty-scan test passed all 30 repetitions.
- **Clean baseline capture, 12:34:08:** 49 passing executions, one failure. Same timeout on **repetition 20**. Empty-scan test passed all 30 repetitions. This establishes that the timeout exists without the uncommitted follow-me changes.
- Inspected actual bundles using `xcrun xcresulttool get test-results summary --path <bundle>` and `get test-results tests --path <bundle>`. Inspected current third-sample `get test-results activities --path <bundle> --test-id 'ARSharedMissionFrameCalibratorTests/testThirdAcceptedSampleEmitsContextualProgressBeforeAcceptance()'`; failed repetition contains the timeout and its spindump attachment, not an assertion failure.

### Ranked hypotheses and minimization

Communicated these ranked, falsifiable hypotheses before testing them:

1. Grounding suspends while newest-only snapshot buffering coalesces frames. Waiting for actual progress before ingesting the next frame should eliminate the timeout.
2. Snapshot subscription starts late. Synchronous subscription would prevent first-frame loss but not later coalescing. No subscription/production buffering change was needed for the observed failures; this remains a possible separate lifecycle concern, not a demonstrated cause here.
3. Empty-scan assertion races delivery. Draining the third scan should consistently expose whether `scanCompleted` occurs after recovery.

Changed only input/event ordering in the existing tests first: awaited actual progress for each accepted sample; awaited scanner acknowledgements for each empty scan, then cancelled calibration and drained the consumer. Original assertion bodies and expected arrays stayed unchanged. These are bounded one-second XCTest expectation waits, replacing scheduler guesses, not increasing the 60-second allowance. Cancellation also prevents a missing sample from leaving an unbounded stream wait.

Executed the same two-test command without repetition flags, result `calibration-ordered-red.xcresult`, at **12:38:10**: **one passed, one assertion-failed**. Exact failing sequence was `[scannerFailed(frame 1), waitingForMarker(frame 2), scanCompleted(frame 3)]` versus unchanged expected `[scannerFailed(frame 1), waitingForMarker(frame 2)]`.

Repeated that command with `-test-iterations 5` (without `-run-tests-until-failure`), result `calibration-ordered-red-repeat.xcresult`, at **12:38:50**: empty-scan test failed **5/5**, third-sample test passed **5/5**. This converts the scheduling-sensitive event race into a fast, deterministic assertion-red loop.

### Corrections and regressions

- **Timeout:** test scheduling defect. `ARSessionManager.snapshots()` intentionally uses `.bufferingNewest(1)`, and calibration yields between marker feedback and grounding. Three ingests separated only by `Task.yield()` do not guarantee three processed samples. The existing test now waits for each `.progress` acknowledgement before providing its next sample; production coalescing and three-sample acceptance policy remain intact.
- **Extra event:** calibrator emitted `scanCompleted` for every clean empty scan, including after `waitingForMarker` had already cleared the scanner failure. Added one attempt-local pending-backend-diagnostic flag. A clean empty scan emits completion only when needed to close a prior diagnostic-only cycle. Waiting recovery, tracking feedback and scanner failure clear pending state. Actual backend diagnostics, recurrence resetting and calibration model policy are preserved.
- Applied acknowledged/drained ordering to the equivalent wrong-marker recovery test without changing its expected assertion.
- Added `testCleanEmptyScansOnlyCompletePendingBackendDiagnosticCycle`: diagnostic frame 1 → completion frame 2 → silent clean frame 3 → recurring diagnostic frame 4. Ran it and the strengthened wrong-marker test **before production edit**, selecting those two methods with the same destination/timeout flags and result `calibration-cycle-red.xcresult` at **12:39:53**. Both failed assertions because of extra frame-3 completion.
- Added controlled real-grounder `testFramesCoalesceWhileGroundingAndOnlyProcessedSamplesCount`: ingest frames 2 and 3 during frame-1 grounding. Assert processed IDs `[1, 3]` with no acceptance, then ingest frame 4 and assert `[1, 3, 4]` followed by acceptance. This is a mechanism/invariant proof, not a claimed additional assertion-red regression.
- No debug logging or throwaway source instrumentation was introduced. The tests exercise real manager → scanner → grounding → calibration → consumer boundaries.

### Focused verification commands and actual counts

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests/testSuccessfulEmptyScanClearsScannerFailureOnce \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests/testThirdAcceptedSampleEmitsContextualProgressBeforeAcceptance \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests/testCleanEmptyScansOnlyCompletePendingBackendDiagnosticCycle \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests/testSuccessfulEmptyScanClearsWrongMarkerFailureOnce \
  -test-iterations 100 -run-tests-until-failure -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/calibration-ordered-green.xcresult -quiet

xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests \
  -only-testing:PhroverKitTests/SilentSearchCoordinatorTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/calibration-affected-green.xcresult -quiet

xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests/testFramesCoalesceWhileGroundingAndOnlyProcessedSamplesCount \
  -test-iterations 30 -run-tests-until-failure -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/calibration-coalescing-proof.xcresult -quiet
```

At **12:40:39**, all **400 executions** of four focused tests passed. At **12:40:59**, both affected classes passed **73 tests** including the coordinator's diagnostic recurrence integration. At **12:42:08**, the controlled coalescing proof passed **30 executions**. Xcresult summaries distinguish unique tests from repetitions; counts above use execution totals where stated.

### Final Task 7 verification after root fixes

Only after diagnosis, assertion-red regressions and focused greens, executed:

```bash
SIM_UDID=EEA52712-371D-4FF6-B8EF-A2C78319D57F ./scripts/test-swift-sdk.sh \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/calibration-fixed-sdk-final.xcresult -quiet

xcodebuild test -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverOperatorTests -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/calibration-fixed-app-final.xcresult -quiet

xcodebuild build -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
```

| Final check | Actual result |
| --- | --- |
| Full non-live SDK, 12:42:46 | **497 passed, 0 failed, 0 skipped** |
| All app unit tests, 12:43:14 | **29 passed, 0 failed, 0 skipped** |
| Unsigned generic iOS app build | **Exit 0** |
| `git diff --check` | **Exit 0** |

Read both final result-bundle summaries; SDK count includes the two new calibration tests. Current-source final checks supersede all earlier blocked/partial verification claims. Test expectations and execution allowance were not relaxed, and no tests were skipped. Follow-me code was preserved during this scoped calibration correction. Unrelated `.serena`, `.opencode`, `AGENTS.md`, `.superpowers` assets and other user work were preserved. Branch/HEAD remain `feat/follow-me` / `c04fbcc`; nothing staged, committed or pushed. Physical acceptance remains a separately authorized handoff.

Prevention: asynchronous tests should pace inputs using observed processing acknowledgements and drain streams before exact event assertions. Scheduler yields and scanner counters alone do not prove a downstream consumer has processed a frame.

## Independent-review P2 — same-frame diagnostic obligation — 2026-10-02

**Corrected and verified.** This section supersedes the first pending-flag implementation and its final-check counts above. Review correctly identified that `SilentSearchCoordinator.completeScannerDiagnosticCycle(context:)` deliberately ignores same-context completion feedback. The producer must retain the obligation after diagnostics accompanied by waiting guidance or a successfully grounded marker from that same frame.

### Strict integration regressions, executed before the production fix

Added two tests in `SilentSearchCoordinatorTests.swift`:

- `testCleanScanAfterSameFrameBackendDiagnosticAndWaitingRecordsRecurrence`
- `testCleanScanAfterSameFrameBackendDiagnosticAndMarkerRecordsRecurrence`

Both drive actual `ARSessionManager` → `ARSharedMissionFrameCalibrator` → `SilentSearchCoordinator` streams. Sequence: frame 1 throws → frame 2 has backend D plus empty waiting recovery (or D plus a valid marker) → frame 3 is a clean empty scan → frame 4 repeats D. Marker variant uses real depth grounding and asserts one accepted sample and grounded-corner state. Every scanner call is acknowledged before the next input. A real limited-tracking frame 5 emits coordinator telemetry as a FIFO consumer barrier; exact telemetry arrays are asserted only after that barrier. No calibration feedback is fabricated or injected into the coordinator.

Executed **before changing production**, from repository root:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/SilentSearchCoordinatorTests/testCleanScanAfterSameFrameBackendDiagnosticAndWaitingRecordsRecurrence \
  -only-testing:PhroverKitTests/SilentSearchCoordinatorTests/testCleanScanAfterSameFrameBackendDiagnosticAndMarkerRecordsRecurrence \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/calibration-pending-obligation-red.xcresult -quiet
```

**12:50:26 red: 0 passed, 2 failed, 0 skipped.** Both tests failed the exact recurrence assertion: recorded backend frame sequences `["2"]` versus expected `["2", "4"]`, and one error-domain record versus two. All scan/consumer-barrier expectations and successful-marker assertions passed; this was assertion-red on the review defect, not compilation failure or test timeout. Read the actual result-bundle summary before the production correction.

Evidence-ranked explanations communicated before the fix: (1) pending obligation lost across same-frame feedback; retaining it predicts recurrence restored; (2) frame coalescing, ruled out in this loop by scanner acknowledgements; (3) premature assertion, ruled out by the frame-5 consumer barrier.

### Production correction

In `ARSharedMissionFrameCalibrator.swift`, any outcome containing backend diagnostics sets the pending obligation, whether or not observations are present. Same-frame `waitingForMarker` with diagnostics retains it. Nonempty observation lists no longer discard it. Tracking/failure paths no longer silently reset it. A subsequent clean empty scan discharges the obligation through its real `scanCompleted` receipt, or through clean `waitingForMarker` recovery if that receipt is already emitted. Once discharged, later clean empty frames stay silent. The original exact-array scanner-failure and wrong-marker recovery assertions remain unchanged, and no per-frame completion heartbeat was introduced.

### Green and final verification

Ran the exact red selectors with `-test-iterations 30 -run-tests-until-failure`, changing the bundle path to `calibration-pending-obligation-green.xcresult` in the same temporary parent: **12:52:28 green, 60 passing executions, zero failures/skips** (two unique tests). Then executed:

```bash
xcodebuild test -scheme astral-sdk-Package -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests \
  -only-testing:PhroverKitTests/SilentSearchCoordinatorTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/calibration-pending-affected-final.xcresult -quiet

SIM_UDID=EEA52712-371D-4FF6-B8EF-A2C78319D57F ./scripts/test-swift-sdk.sh \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/calibration-pending-sdk-final.xcresult -quiet

xcodebuild test -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -only-testing:PhroverOperatorTests -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/calibration-pending-app-final.xcresult -quiet

xcodebuild build -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
```

| Final check after P2 correction | Actual result |
| --- | --- |
| Calibration/coordinator classes, 12:52:48 | **76 passed, 0 failed, 0 skipped** |
| Full non-live SDK, 12:53:03 | **499 passed, 0 failed, 0 skipped** |
| All app unit tests, 12:53:32 | **29 passed, 0 failed, 0 skipped** |
| Unsigned generic iOS build | **Exit 0** |
| `git diff --check` | **Exit 0** |

Read each result summary with `xcrun xcresulttool get test-results summary --path <actual-bundle>`. No timeout increase or skipped tests. Earlier 73-class count predates the controlled coalescing proof; current 76 comprises that additional test plus both P2 integration regressions. Earlier 497-SDK count is superseded by current 499. No debug instrumentation, commits, pushes or device work. Unrelated work and follow-me changes were preserved.

Prevention: a producer-side exact-event test cannot establish consumer diagnostic-cycle semantics. The new real-pipeline regressions lock down same-context versus later-context behavior, including successful marker feedback, and expose the defect with exact telemetry assertions after downstream consumption.
