# Room Transition Device Correction Design

## Summary

Correct the physical-device room-transition scan and replace the operator screen’s raw object-classifier output with navigation-relevant perception. The scan currently compares a rover-positive requested turn with Core Motion yaw whose sign is opposite the ARKit/rover convention. It therefore treats real motion as no progress, reverses direction, and can exhaust its pulse budget before collecting useful doorway geometry. Separately, the debug panel shows raw COCO detections such as `refrigerator`; COCO has no doorway class, so that output is unrelated to doorway selection and is misleading during room-transition testing.

## Evidence

The 2026-07-29 device trace contains two exact room-transition commands:

- Mission 6 started at `22:14:55Z`, repeatedly scanned, found no candidate, and returned to idle.
- Mission 7 started at `22:15:50Z`, ranked `doorway_candidate_1` as unreachable, continued scanning, and returned to idle without starting a transition.

During requested positive 30-degree scan turns, ARKit world yaw advanced in the requested direction while Core Motion pulse deltas were commonly negative. The controller recorded `nav_scan_no_progress`, reversed direction, and reached `nav_scan_pulse_limit` twice. No `room_transition_started` or doorway-crossing event occurred.

The same trace reported `refrigerator` at high confidence while the camera faced a doorway. This came from `RoverYOLO`, a COCO object detector. It did not select the doorway candidate and was not consumed by the deterministic room-transition mission.

## Goals

1. Make physical scan turns use one documented rover yaw convention across ARKit and Core Motion.
2. Preserve inertial heading as the relative-turn completion signal because it is resilient to ARKit relocalization.
3. Expose room-transition progress and failure states explicitly.
4. Make the operator panel describe navigation perception rather than raw object classification.
5. Verify doorway selection, crossing confirmation, and reverse traversal on a physical device.

## Non-goals

- Training or replacing the bundled object-detection model.
- Adding a doorway class to COCO output.
- Using object labels as doorway evidence.
- Redesigning general object-target missions.
- Changing topology persistence beyond its existing AR-session lifetime.

## Architecture

### Heading convention boundary

`ARSessionManager` remains the boundary between platform sensor coordinates and rover coordinates. It will convert `CMDeviceMotion.attitude.yaw` into the rover-positive yaw convention before exposing `inertialYaw`. The conversion will be a focused, testable helper: rover yaw is the normalized negative of device-motion yaw for the current fixed device mounting and camera orientation.

`NavigationController` will continue to express requested scan angles in rover coordinates. Its completion, progress, reversal, and pulse-limit logic will consume only the converted inertial yaw. ARKit pose remains the source for world position and world-facing doorway geometry. This avoids scattering sign inversions through navigation algorithms.

### Room-transition diagnostics

`MissionAgent` will publish a lightweight `RoomTransitionDebugState` through a callback, following its existing phase callback pattern. The state will communicate navigation meaning without exposing mission internals:

- `idle`
- `scanning(step:total:frontierCount:candidateCount:)`
- `candidateFound(id:reachable:)`
- `unreachable(id:)`
- `approaching(id:)`
- `confirmingCrossing(id:)`
- `completed(doorwayID:roomID:)`
- `exhausted`
- `failed(reason:)`

The state is diagnostic only. It cannot initiate movement or mutate topology.

### Operator panel

The live camera remains available for orientation and testing, but the primary text panel will show:

- ARKit tracking quality
- forward clearance
- geometric opening/frontier count
- doorway candidate count and reachability result
- selected doorway target, when any
- room-transition state

The panel will stop running its own object detection every 500 milliseconds and will remove `Detector` and `Visible` object rows. The detector remains available to `ARPerceptionSource` for object-target missions; this change only removes unrelated output and duplicate inference work from the navigation debug UI.

## Data Flow

1. Core Motion emits device yaw.
2. `ARSessionManager` converts and normalizes it to rover yaw.
3. `NavigationController.rotateForScan` measures directed progress and completion in that convention.
4. After each settled scan, `MissionAgent` obtains geometric frontiers, refreshes topology candidates, assesses beyond-plane goals, and publishes diagnostic state.
5. Reachable candidates proceed through approach and crossing confirmation. Unreachable candidates and exhausted scans are reported explicitly.
6. `ConversationView` stores the latest debug state on the main actor and passes it to the camera panel for display.

Raw COCO detections do not enter this room-transition path. Optional cloud doorway evidence remains only a ranking boost among geometric candidates.

## Error Handling and Safety

- Missing inertial heading stops the scan and reports failure; navigation does not fall back to an unbounded open-loop turn.
- Lost AR tracking retains the existing stop-and-recovery behavior.
- A scan that makes insufficient physical progress may reverse once and remains bounded by the pulse limit.
- Unreachable candidates are never approached.
- A transition is completed only after the existing doorway-plane crossing evidence and confirmation rules succeed.
- Exhaustion speaks the existing safe-route message and leaves the rover stopped.
- Diagnostic callback failures cannot affect motion; UI updates are optional observers.

## Testing

### Unit tests

- Device-positive and device-negative yaw map to the opposite, normalized rover yaw values.
- Wraparound near positive and negative pi remains continuous after conversion.
- A physical turn represented by the converted yaw is recognized as progress in the requested rover direction.
- Scan completion, one-time reversal, and pulse-limit safety behavior remain covered.
- Room-transition debug states advance through scan, candidate selection, approach, confirmation, completion, unreachable, and exhaustion paths.
- Diagnostic callbacks do not alter mission decisions.

### UI-focused tests

- Navigation summary formatting covers every room-transition state.
- The panel contains tracking, clearance, openings, doorways, target, and transition information.
- The panel does not invoke `Detector.detect` or display raw COCO labels.

### Regression suite

Run the complete Swift package tests, build `RoverNav`, build the PhroverOperator simulator target, and run the existing launch smoke test.

## Physical-Device Acceptance

1. Install and launch the corrected build on the iPhone-mounted rover.
2. Aim the rover at a doorway and say “Go to the other room.”
3. Confirm scan steps are controlled and do not oscillate because of opposing heading signs.
4. Confirm the panel reports geometric openings and doorway candidates instead of `refrigerator`.
5. Confirm a reachable beyond-plane goal is selected.
6. Confirm the rover crosses the doorway and records a room transition.
7. Command another-room traversal from the new room and confirm the known doorway can be traversed in reverse.
8. Pull the runtime log and verify scan progress, `room_transition_started`, `doorway_crossed`, and completion telemetry without scan pulse-limit failures.

## Success Criteria

The correction is complete when automated tests pass and a physical-device run demonstrates controlled scanning, navigation-relevant diagnostics, confirmed doorway crossing, and reverse traversal. Raw object false positives may still exist for object-target missions, but they are no longer presented as doorway/navigation understanding.
