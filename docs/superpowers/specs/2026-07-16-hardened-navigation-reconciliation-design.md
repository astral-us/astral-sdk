# Hardened Navigation Reconciliation Design

## Problem

Merge `bbf583d` selected the `main` versions of `NavigationController.swift` and
`MissionAgent.swift`. That retained new simulation, battery, team-radio, and mission-history
interfaces, but removed the branch's physical-rover safety and visual-target behavior. The
remaining branch tests no longer compile because the production methods they cover disappeared.

## Decision

Reconcile both parents instead of reverting the merge:

- Use `6311c21` as the behavioral reference for physical navigation and visual-target missions.
- Preserve the newer `main` interfaces for battery state, team context, room claims, recent action
  history, bounded no-op recovery, and Godot simulation tests.
- Keep the current Swift 6 `Sendable` fixes and the app's direct observation of
  `MissionAgent.phase`.
- Do not change unrelated app UI, detector, cloud-brain, or simulator implementation details.

## NavigationController

Restore the hardened closed loop:

- visual-target navigation with a LiDAR stand-off and final-approach speed cap;
- one terminal state transition for obstacle, comms, tipping, command, and no-progress failures;
- navigation command retries through `RoverControl.sendNavigation`;
- pulsed scan rotation that ignores forward-only obstacle clearance while still enforcing comms
  and tipping checks;
- runtime telemetry for goals, pose, clearance, wheel commands, retries, safety stops, and arrival;
- minimum wheel magnitude for reliable in-place turns.

The controller must stop once and leave `.driving` after a terminal fault. It must not continuously
alternate stop and drive commands when clearance jitters.

## MissionAgent

Restore the hardened mission behavior while retaining main's newer cognition inputs:

- immediate emergency-stop bypass, mission generation invalidation, and busy-command rejection;
- bounded brain decisions with error logging and phase recovery;
- visual-query locking at 90 percent confidence, paced 30-degree scan steps, target reacquisition,
  and 30 cm stand-off navigation;
- blocked-heading and stalled-navigation recovery;
- battery/team context, room claims, recent action outcomes, no-op warnings, and bounded fallback;
- exploration candidate persistence and Godot-compatible `RoverMotion`/`RoverPerception` seams.

## Error Handling

Transport, obstacle, tip, and progress failures become terminal navigation states and return
control to the mission agent. Brain errors and timeouts return the mission phase to `.idle`.
Emergency stop always invalidates an in-flight decision before it can start motion.

## Verification

1. Run the existing `NavigationSafetyTests` and `MissionAgentTests` to prove the merge regression
   is red before implementation and green afterward.
2. Run `PhroverSimTests` to verify the retained simulation/team contracts.
3. Build the PhroverOperator app for the iOS 26.5 simulator.
4. Run `git diff --check` and inspect the final diff for unrelated changes.
