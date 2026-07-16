# Hardened Navigation Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the physical rover's hardened navigation and visual-target mission behavior without losing the newer simulation, battery, team, and mission-history interfaces from main.

**Architecture:** Reconcile at the existing `RoverMotion` boundary. `NavigationController` owns physical closed-loop safety and reliable commands; `MissionAgent` owns interpretation, visual target locking/search, recovery, and cognition context. Simulator adapters continue conforming to those protocols without depending on ARKit or the real rover.

**Tech Stack:** Swift 6, Swift Concurrency, Observation, ARKit/Core ML integration, XCTest, Swift Package Manager, Xcode iOS simulator.

## Global Constraints

- Preserve all existing uncommitted user changes.
- Preserve `main` battery, team-radio, room-claim, recent-action, no-op, and Godot simulation behavior.
- Restore behavior from merge parent `6311c21`; do not revert merge `bbf583d` wholesale.
- Keep navigation faults terminal so command flooding cannot resume motion after a safety stop.
- Use the existing 90 percent visual confidence and 30 cm target stand-off defaults.

---

### Task 1: Restore the hardened navigation controller

**Files:**
- Modify: `swift/Sources/PhroverKit/Nav/NavigationController.swift`
- Test: `swift/Tests/PhroverKitTests/NavigationSafetyTests.swift`

**Interfaces:**
- Consumes: `ObstacleGuard.evaluate`, `RoverControl.sendNavigation`, `DriveProgressWatchdog`, `RotationCommand`, and `RoverConfig` safety constants.
- Produces: `navigate(to:stoppingAtForwardClearance:)`, `rotateForScan(by:)`, terminal `State` transitions, and navigation telemetry helpers.

- [ ] **Step 1: Verify the existing regression tests fail**

Run:

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'platform=iOS Simulator,id=B99F477C-ACD3-4E31-A683-81048E5C7FDA' \
  -only-testing:PhroverKitTests/NavigationSafetyTests
```

Expected: compilation fails because the hardened navigation methods are absent.

- [ ] **Step 2: Restore the navigation state machine from `6311c21`**

Restore visual stand-off decisions, terminal safety transitions, command failure handling,
progress watchdog, scan pulse behavior, and telemetry. Preserve `State: Sendable`.

- [ ] **Step 3: Run the navigation tests**

Run the Step 1 command again. Expected: all `NavigationSafetyTests` pass.

### Task 2: Reconcile MissionAgent behaviors

**Files:**
- Modify: `swift/Sources/PhroverKit/Voice/MissionAgent.swift`
- Test: `swift/Tests/PhroverKitTests/MissionAgentTests.swift`

**Interfaces:**
- Consumes: hardened `RoverMotion` methods plus current `RoverBattery`, `RoverTeamRadio`,
  `MissionContext`, and `RoverDecision.claimRoom` APIs.
- Produces: immediate stop, bounded brain decisions, visual locking/scanning/recovery, exploration,
  recent-action history, and team claims in one mission loop.

- [ ] **Step 1: Keep the test suite red until reconciliation is complete**

Run:

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'platform=iOS Simulator,id=B99F477C-ACD3-4E31-A683-81048E5C7FDA' \
  -only-testing:PhroverKitTests/MissionAgentTests
```

Expected before production edits: build or behavior failures from the missing motion contract and
lost mission logic.

- [ ] **Step 2: Three-way reconcile the mission loop**

Use common ancestor `58ca425`, branch parent `6311c21`, and main parent `bc1398d`. Resolve overlap by
keeping both sets of state where orthogonal, making error exits restore `.idle`, recording outcomes
after hardened recovery, and adding `.claimRoom` to logs and execution.

- [ ] **Step 3: Run mission tests**

Run the Step 1 command again. Expected: all `MissionAgentTests` pass.

### Task 3: Verify simulator and app compatibility

**Files:**
- Verify: `swift/Tests/PhroverSimTests/`
- Verify: `examples/PhroverOperator/PhroverOperator.xcodeproj`

**Interfaces:**
- Consumes: reconciled SDK protocols.
- Produces: proof that newer main behavior and the iOS app still compile.

- [ ] **Step 1: Run focused package tests**

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'platform=iOS Simulator,id=B99F477C-ACD3-4E31-A683-81048E5C7FDA' \
  -only-testing:PhroverKitTests/NavigationSafetyTests \
  -only-testing:PhroverKitTests/MissionAgentTests
```

- [ ] **Step 2: Compile simulation tests**

```bash
xcodebuild build-for-testing -scheme astral-sdk-Package \
  -destination 'platform=iOS Simulator,id=B99F477C-ACD3-4E31-A683-81048E5C7FDA'
```

- [ ] **Step 3: Build the operator app**

```bash
xcodebuild build \
  -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator \
  -destination 'platform=iOS Simulator,id=B99F477C-ACD3-4E31-A683-81048E5C7FDA'
```

- [ ] **Step 4: Check patch integrity**

```bash
git diff --check
git status --short --branch
```

Expected: no whitespace errors; only intended reconciled files, docs, and pre-existing user changes.
