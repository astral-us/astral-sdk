# Room Transition Runtime Recovery Design

**Date:** 2026-08-05
**Status:** Approved

## Summary

Fix the physical-device failure where Phrover recognizes “Go to other room” but immediately returns to Ready without moving or retaining an operator-visible result. The device trace proves speech recognition and mission dispatch succeed. The room transition then rejects two apparently reachable doorway candidates because their directions are inconsistent with the rover’s current side, and its fallback scan stops because the rotational swept volume is not visible in depth.

The repair keeps motion fail-closed. It corrects doorway orientation at the topology boundary using the current observed rover pose, adds typed transition-start outcomes, performs only depth-authorized scan recovery, and keeps one persistent last-command card in the operator UI.

## Evidence

The device runtime log at `2026-08-05T20:39:04Z` records:

- `speech_capture_completed ... transcript=Go to other room`
- `voice_command_received utterance=Go to other room`
- `mission_started mission=1`
- two reachable doorway candidates followed by `transition_could_not_start`
- fallback rotation stopped with `depth_state=blind_swept_volume` and `support_count=0`

The operator screen retained only the speech partial and returned its phase badge to Ready. `ConversationView` has no persistent command-result model, so the navigation failure looked like an unrecorded voice command.

## Goals

1. Orient doorway candidates away from the rover’s current-room side using the current observation, not a historical representative pose.
2. Replace generic transition-start failure with typed, diagnosable outcomes.
3. Recover from blind scan rotation only through commands authorized against fresh depth evidence.
4. Keep the rover stopped when no scan command has observable swept-volume coverage.
5. Persist the latest recognized command and its terminal result on screen.
6. Lock the device failure down with automated geometry, safety, mission, and UI-state tests.

## Non-goals

- Weakening depth-safety thresholds or permitting movement with unavailable depth.
- Adding full conversation history or persistent storage across app launches.
- Redesigning general object-target missions.
- Replacing frontier detection, route planning, or the room-topology model.
- Automatically correcting an unsupported or physically shifting camera mount.

## Architecture

### Current-pose doorway orientation

`SessionRoomTopology.refreshCandidates` will accept the current observed rover pose as an explicit orientation reference. For every admitted frontier it will retain the raw frontier direction for telemetry, normalize the operational direction, and flip it when the reference pose lies on the direction’s positive side. The beyond-plane goal is calculated only after this correction.

This replaces the current dependency on the current room’s last representative pose. Representative poses remain room evidence, but they are not authoritative for orienting a doorway selected for immediate movement.

Transition startup will return a typed result rather than `Bool`. Outcomes distinguish:

- started;
- corrected orientation, requiring goal reassessment;
- transition already active;
- missing current room;
- missing candidate;
- invalid geometry or approach side.

If startup detects that the latest approach pose now conflicts with the stored direction, topology atomically corrects the candidate and returns it without starting movement. `MissionAgent` reassesses the corrected beyond-plane goal before retrying transition startup. A stale, pre-correction goal is never sent to navigation.

### Depth-safe scan recovery

`NavigationController` continues to own motor-command safety. When an in-place scan command produces `blind_swept_volume`, it will:

1. send stop;
2. wait for a newer raw-depth observation within a bounded timeout;
3. re-evaluate the intended in-place turn;
4. if still blind, evaluate a bounded low-speed depth-visible arc matching the requested turn direction;
5. send only a command explicitly allowed by `ObstacleGuard` for that exact depth observation;
6. otherwise remain stopped and return a specific visibility failure.

The recovery is bounded and does not reinterpret unavailable depth as clear. Freshness, calibration, swept-volume coverage, obstacle, tipping, and command-link checks remain authoritative.

### Typed mission command status

`MissionAgent` will publish a lightweight typed command-status callback independent of its transient phase callback. It emits `recognized` synchronously when `handle` accepts a nonblank utterance, followed by `working` when mission execution begins. Events cover:

- recognized command text;
- working;
- succeeded with a concise result;
- failed with an operator-facing reason;
- cancelled.

Every mission exit path must publish one terminal status. Returning the mission phase to idle does not erase the terminal event.

### Last-command card

`ConversationView` will own a focused `LastCommandState` reducer/model containing:

- command text;
- status: recognized, working, succeeded, failed, or cancelled;
- concise result text.

A single card renders this model. A new recognized command replaces the previous card. The existing engineering debug panel remains available and continues to show detailed transition telemetry. No scrollable conversation history or disk persistence is added.

## Data Flow

1. `SpeechIn` finalizes the transcript and passes it to `MissionAgent.handle`.
2. `MissionAgent` publishes `recognized`; `ConversationView` reduces that event into the latest-command card.
3. `MissionAgent` publishes `working` and captures the current rover pose.
4. The mission requests frontiers and refreshes topology candidates using that exact pose.
5. Topology orients candidates away from the current-room side and logs raw direction, operational direction, reference pose, signed distance, and whether it flipped the candidate.
6. Navigation assesses only corrected beyond-plane goals.
7. Transition startup either begins, returns a corrected candidate for reassessment, or returns a typed rejection.
8. The mission approaches a valid doorway or starts bounded scan recovery.
9. `NavigationController` sends only depth-authorized commands.
10. Mission completion, exhaustion, safety failure, or cancellation publishes a terminal command status that remains visible after the phase returns to Ready.

## Error Handling and Operator Messages

- Orientation correction is deterministic and logged; it is not silently performed after a motor goal has already been chosen.
- Invalid candidate geometry is excluded with a specific reason and the mission may try another candidate within its existing budget.
- No safe scan command leaves the rover stopped and reports: “I can’t safely see the space needed to turn. Reposition the rover or camera and try again.”
- Candidate exhaustion reports: “I couldn’t find a safe route into another room.”
- Cancellation displays `Cancelled` rather than success or an unexplained Ready state.
- Internal typed reasons remain available in telemetry while the card presents concise operator language.
- The generic `transition_could_not_start` event is removed from the corrected path.

## Testing

### Topology tests

- Reproduce the device geometry where a stale room representative pose and the current mission pose lie on different doorway sides; orientation follows the current pose.
- A corrected candidate’s beyond-plane goal points away from the current rover side.
- Raw and corrected directions produce complete telemetry.
- Every typed transition-start outcome is covered.
- Startup correction returns an updated candidate and does not create pending-transition state until its corrected goal is reassessed.
- Forward and reverse traversal of known doorways preserve their existing semantics.

### Mission tests

- The room-transition mission passes its current pose into candidate refresh.
- A corrected startup result causes goal reassessment before navigation.
- A stale, pre-correction goal is never sent to `RoverMotion`.
- Candidate rejection, exhaustion, scan safety failure, success, stop, and task cancellation each publish exactly one terminal command status.

### Navigation safety tests

- A blind in-place rotation sends stop and no movement command.
- A newer depth observation is required before retry authorization.
- A depth-visible low-speed arc can be sent only when its exact swept volume is allowed.
- Stale, unavailable, malformed, or insufficient depth keeps the rover stopped.
- Recovery remains bounded and preserves obstacle, tipping, calibration, and communication checks.

### UI-state tests

- `recognized → working → succeeded` persists after mission phase becomes Ready.
- `recognized → working → failed` retains the failure reason.
- Cancellation remains visible.
- A new recognized command replaces the previous card.
- Transient speech partials cannot erase a terminal command result.

### Regression verification

Run the focused topology, room-transition mission, depth-safety, navigation-safety, and UI-state tests, then the complete supported Swift/Xcode test suite and PhroverOperator build.

## Physical-Device Acceptance

1. Install and launch the corrected build on the iPhone-mounted rover.
2. Say “Go to other room.”
3. Confirm the last-command card appears immediately and advances to Working.
4. Verify telemetry records the current reference pose and corrected candidate orientation.
5. Confirm transition startup no longer emits generic `transition_could_not_start` for the reproduced geometry.
6. Confirm the rover never moves when rotational depth coverage is unavailable.
7. With a safely visible doorway, confirm the rover starts the transition, crosses the doorway, and displays Succeeded.
8. With intentionally blind scan geometry, confirm the rover remains stopped and the card displays the repositioning instruction.
9. Pull the device runtime log and verify speech completion, corrected candidate selection, depth authorization, and the appropriate terminal mission event.

## Success Criteria

The repair is complete when automated tests pass and physical-device testing demonstrates both paths: a correctly oriented, depth-authorized doorway transition succeeds, while an unobservable scan remains stopped with a persistent and actionable command result. No movement bypasses depth safety, no stale doorway goal reaches navigation, and the operator can always see what happened to the latest command.
