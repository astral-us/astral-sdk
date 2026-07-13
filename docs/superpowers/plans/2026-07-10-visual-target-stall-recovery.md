# Visual Target Stall Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover a stalled visual-target mission by performing deliberate 30-degree camera scan turns and returning the UI to Ready if the target cannot be reacquired.

**Architecture:** `PursuitController` will enforce a caller-supplied wheel-speed floor for in-place turns. `NavigationController` will monitor pose progress and fail a drive that remains stationary under command. `MissionAgent` will treat that failure as a stale visual goal, run its existing alternating scan routine, and resume navigation from a fresh detection.

**Tech Stack:** Swift 6, XCTest, ARKit-backed `PhroverKit`, pure Swift `RoverNav`.

## Global Constraints

- Visual detections must meet the existing 0.90 confidence threshold.
- Search turns use the existing 30-degree scan angle and alternate left/right.
- A single missed camera frame must not interrupt normal navigation.
- Exhausted search must leave the mission in `.idle`.

---

### Task 1: Reliable Path-Following Rotation

**Files:**
- Create: `swift/Tests/RoverNavTests/PursuitControllerTests.swift`
- Modify: `swift/Sources/RoverNav/PursuitController.swift`
- Modify: `swift/Sources/PhroverKit/Nav/NavigationController.swift`

**Interfaces:**
- Consumes: `RoverConfig.minimumRotateWheelSpeed`
- Produces: `PursuitController.Params.minimumRotateWheelSpeed: Double`

- [ ] Write a test that gives the controller a target behind the rover and asserts both wheel magnitudes are at least `0.25`.
- [ ] Run `swift test --filter PursuitControllerTests` and verify the test fails because the parameter does not exist or the command remains near `0.10`.
- [ ] Add `minimumRotateWheelSpeed` to `Params`, clamp only in-place turns to that magnitude, and pass the rover configuration value from `NavigationController`.
- [ ] Re-run `swift test --filter PursuitControllerTests` and verify it passes.

### Task 2: Navigation No-Progress Watchdog

**Files:**
- Modify: `swift/Sources/PhroverKit/Nav/NavigationController.swift`
- Modify: `swift/Tests/PhroverKitTests/NavigationSafetyTests.swift`

**Interfaces:**
- Produces: `NavigationProgressWatchdog.observe(pose:now:commanded:) -> Bool`, where `true` means stalled.
- Produces: failed navigation state text `Navigation stalled.`

- [ ] Write pure watchdog tests proving stationary commanded poses stall after two seconds and position/yaw progress resets the deadline.
- [ ] Run the focused navigation safety tests and verify the stationary test fails before implementation.
- [ ] Add the watchdog and invoke it from `drive(to:)` before sending each nonzero command; stop and set `.failed("Navigation stalled.")` when it fires.
- [ ] Re-run focused navigation safety tests and verify they pass.

### Task 3: Visual Reacquisition After Stall

**Files:**
- Modify: `swift/Sources/PhroverKit/Voice/MissionAgent.swift`
- Modify: `swift/Tests/PhroverKitTests/MissionAgentTests.swift`

**Interfaces:**
- Consumes: `NavigationController.State.failed("Navigation stalled.")`
- Consumes: `scanForUnresolvedVisualTarget(_:missionID:scanSteps:)`

- [ ] Add a mission test whose first visual navigation stalls, whose first scan sees no match, and whose second scan detects the target; assert alternating turns and a second navigation call.
- [ ] Run the focused mission test and verify it fails because stalled navigation ends the mission without scanning.
- [ ] Route stalled visual navigation into the existing scan loop, resume using the fresh goal, and return `.idle` after success or scan exhaustion.
- [ ] Re-run the focused mission tests and verify they pass.

### Task 4: Verification

**Files:**
- Modify: `docs/phrover-fixes-2026-07-08.md`

- [ ] Record the device-log root cause and implemented recovery behavior.
- [ ] Run focused Swift tests for `RoverNavTests` and `PhroverKitTests`.
- [ ] Run `xcodebuild -project examples/PhroverOperator/PhroverOperator.xcodeproj -scheme PhroverOperator -destination generic/platform=iOS build`.
- [ ] Run `git diff --check` and inspect the final scoped diff without staging unrelated files.
