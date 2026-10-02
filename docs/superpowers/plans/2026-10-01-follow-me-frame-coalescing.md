# Follow-Me Frame Coalescing Implementation Plan

> **For agentic workers:** Implement task-by-task with test-driven development. Do not install, launch, or move the rover without explicit operator approval.

**Goal:** Prevent follow mode from processing a stale queue of camera observations, wait up to five seconds for startup readiness, and retain the two-second fail-closed recovery behavior after startup.

**Architecture:** Keep the combined perception event interface, but make `FollowMeCoordinator` ingest events without awaiting frame work. Lifecycle events enter the terminal path directly; frame events replace a single pending frame consumed by one generation-scoped processor. Track startup readiness separately from mid-session perception recovery and gate each continuous outage with one confirmed stop.

**Tech stack:** Swift 6, Observation, structured concurrency, AsyncStream, XCTest, PhroverKit, ARKit, and Xcode/iOS.

**Approved design:** `docs/superpowers/specs/2026-10-01-follow-me-frame-coalescing-design.md`

## Constraints

- Preserve the 500 ms maximum observation age.
- Preserve lossless AR interruption/failure handling.
- Preserve acknowledged motor stopping and the existing blocked state after stop failure.
- Startup readiness defaults to 5 seconds; mid-session perception recovery remains 2 seconds.
- Do not change detector, tracker, scan geometry, stand-off control, or reacquisition policy.
- Do not stage or overwrite `.serena/project.yml`, `.opencode/`, `AGENTS.md`, or existing `.superpowers` workflow assets.
- Commands run from the repository root.

## File map

- `swift/Sources/PhroverKit/FollowMe/FollowMeModels.swift`: add the independent startup readiness timeout.
- `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift`: separate ingestion from newest-frame processing and make outage stopping idempotent.
- `swift/Tests/PhroverKitTests/FollowMeCoordinatorTests.swift`: deterministic startup, coalescing, lifecycle, and outage regression tests.
- `swift/Tests/PhroverKitTests/Support/FollowMeTestDoubles.swift`: only extend test observability if the coordinator regressions cannot be asserted through existing state, goals, rotations, and stop counts.

---

### Task 1: Separate startup readiness from recovery

**Files:**
- Modify: `swift/Sources/PhroverKit/FollowMe/FollowMeModels.swift`
- Modify: `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift`
- Test: `swift/Tests/PhroverKitTests/FollowMeCoordinatorTests.swift`

- [ ] Add failing tests proving startup does not rotate from missing-pose, missing-depth, limited-tracking, unavailable-tracking, or stale frames.
- [ ] Add a failing test that advances the manual clock to 4.999 seconds, sends a healthy frame, and proves search/follow processing starts immediately.
- [ ] Add failing tests that advance to 5 seconds and assert the latest actionable issue is reported, while no-frame startup reports `FollowPerceptionIssue.noFrames.message`.
- [ ] Run the focused test class and confirm the new timeout cases fail for the expected current two-second/shared-timeout behavior:

```bash
scripts/test-swift-sdk.sh -only-testing:PhroverKitTests/FollowMeCoordinatorTests
```

- [ ] Add `startupReadinessSeconds: TimeInterval = 5` to `FollowMeConfiguration` without changing `perceptionRecoverySeconds`.
- [ ] Keep `startupTask` active until the first fully healthy frame, not merely the first frame. Unhealthy startup frames update `perceptionIssue` and diagnostics but do not enter the mid-session recovery timer.
- [ ] Gate initial candidate selection and scan launch on readiness. Cancel the startup timer on the first healthy frame and immediately process that frame through the existing searching state.
- [ ] Make the startup timeout fail with `perceptionFailureMessage`, which resolves to the current specific issue and falls back to `noFrames` when no frame arrived.
- [ ] Re-run the focused tests and confirm green.

### Task 2: Reproduce and fix stale frame accumulation

**Files:**
- Modify: `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift`
- Test: `swift/Tests/PhroverKitTests/FollowMeCoordinatorTests.swift`

- [ ] Add a deterministic failing regression: establish readiness and a track, suspend `stopAndConfirm`, send a frame that begins replacement/recovery work, then send a burst with increasing sequence/timestamps. Release the stop after advancing time. Assert processing uses the newest pending frame, does not visit obsolete frames, and does not fail with `staleFrame` solely because of the burst.
- [ ] Add a failing regression that injects `.interrupted` during the suspended frame operation and proves the coordinator reaches `failed("AR session interrupted.")` before the stop is released; repeat for `.failed(message)` if one parameterized test cannot cover both.
- [ ] Run only the new tests and confirm they reproduce the serial-consumer backlog and lifecycle delay.
- [ ] Add generation-scoped coordinator state for one pending frame and one frame-processor task.
- [ ] Change the perception ingestion loop so `.frame` only replaces the pending slot and starts the processor if needed. It must not await frame handling.
- [ ] Route `.interrupted` and `.failed` directly to the existing terminal path from ingestion. On stream completion, retain the existing `Perception ended.` behavior only if the generation remains active.
- [ ] Implement the single processor as a drain loop: take and clear the pending frame, await existing frame handling, then take the newest replacement. Exit when empty, inactive, cancelled, or generation-invalid.
- [ ] Ensure terminal cleanup clears the pending frame and cancels both ingestion and processing. Preserve monotonic frame-ID checks and timestamp validation at point of use.
- [ ] Re-run the new regressions and the full `FollowMeCoordinatorTests` class.

### Task 3: Make continuous perception outages idempotent

**Files:**
- Modify: `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift`
- Test: `swift/Tests/PhroverKitTests/FollowMeCoordinatorTests.swift`

- [ ] Add a failing test that sends multiple unhealthy frames during one mid-session outage and asserts exactly one new confirmed-stop operation and one unchanged recovery deadline.
- [ ] Add a test that recovers with a healthy frame, starts a second outage, and proves the second outage is allowed to initiate a new confirmed stop.
- [ ] Preserve and run the existing tests for a fresh frame arriving during watchdog stop, failed stop blocking future goals, stale-frame watchdog behavior, and delayed stop acknowledgement.
- [ ] Introduce the smallest explicit outage-stop state needed to distinguish “this outage has already requested stop” from the existing in-flight `stopTask` deduplication.
- [ ] Set the two-second deadline and request confirmed stop only when entering a new outage. Later unhealthy frames update the issue/reason but neither extend the deadline nor request another stop.
- [ ] Clear the outage marker only after a healthy frame recovers perception or terminal cleanup ends the generation.
- [ ] Ensure a stop failure still enters the existing failed/blocked path and cannot be cleared by a later frame.
- [ ] Run focused tests and confirm green.

### Task 4: Regression and build verification

**Files:**
- Verify all modified source and test files.

- [ ] Run all follow tests:

```bash
scripts/test-swift-sdk.sh   -only-testing:PhroverKitTests/FollowMeCoordinatorTests   -only-testing:PhroverKitTests/ARFollowMePerceptionSourceTests   -only-testing:PhroverKitTests/FollowTargetTrackerTests
```

- [ ] Run the complete SDK suite:

```bash
scripts/test-swift-sdk.sh
```

- [ ] Run whitespace validation:

```bash
git diff --check
```

- [ ] Build the app for a generic iOS device without installing or launching it:

```bash
xcodebuild build -quiet   -project examples/PhroverOperator/PhroverOperator.xcodeproj   -scheme PhroverOperator   -configuration Debug   -destination "generic/platform=iOS"
```

- [ ] Review the final diff for generation safety, terminal cleanup, single-stop outage semantics, unchanged 500 ms freshness, and unchanged 2-second mid-session recovery.
- [ ] Confirm unrelated workspace files remain unstaged and unmodified by this work.

## Physical validation (operator-authorized follow-up only)

After explicit approval to build/install and conduct a supervised rover test, install the signed app on the paired iPhone 15 Pro and perform the acceptance steps from the design. Pull `phrover-runtime.log` afterward and verify selected `follow_frame` age remains below the freshness boundary during goal replacement and reacquisition, while interruption and perception loss remain fail-closed.
