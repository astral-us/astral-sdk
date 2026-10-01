# Follow-Me Design

**Date:** 2026-09-29
**Status:** Approved

**Voice-only scope amendment:** `2026-09-30-follow-me-voice-only-amendment.md` supersedes the text-entry and Send-button requirements below; follow-me is now press-and-hold microphone only.

## Problem

The operator can currently submit missions only by holding the microphone on the Talk screen. A follow request is awkward because the operator faces the iPhone display while the rover perceives the world through the rear camera. The rover also has no continuous person-following lifecycle: ordinary visual-target navigation approaches a target once and finishes.

## Goals

- Add a general text-command field whose request is submitted with one tap.
- Route finalized speech and typed text through one command path.
- Recognize follow and stop commands locally without cloud connectivity.
- Rotate the rover through at most one full turn to acquire the operator with the rear camera.
- Continuously follow the selected person at approximately 1.5 metres until stopped.
- Preserve the selected track when another person becomes more central.
- Pause and attempt bounded reacquisition when the selected person is lost.
- Stop immediately on operator request or safety failure.

## Non-goals

- Front-camera capture or front-to-rear camera handoff.
- Face recognition, person identification, or an identity guarantee after a full occlusion.
- Remote command transport outside the existing app.
- Cloud-dependent follow control.
- Following a specifically named person or allowing the operator to select among candidates.
- Reversing toward a person who moves inside the desired following distance.

## Architecture

### Operator command router

`OperatorCommandRouter` accepts finalized requests from both text entry and speech recognition. It normalizes surrounding whitespace, letter case, and terminal punctuation before applying a small local phrase allowlist:

- Start follow: `follow me`, `start following`, and `start following me`.
- Stop: `stop`, `stop following`, and `stop following me`.

Start-follow phrases activate `FollowMeCoordinator`; stop phrases immediately cancel follow mode or the current ordinary mission. Every other nonblank request is forwarded unchanged to `MissionAgent` so existing AI interpretation remains available.

Only one motion owner may be active. Starting follow mode cancels the current ordinary mission before searching. Ordinary commands are rejected while follow mode is active with an instruction to stop following first. Repeated start-follow requests during an active follow session are accepted as no-ops and do not restart acquisition.

### Follow-me coordinator

`FollowMeCoordinator` is a dedicated state machine with these externally observable states:

- `idle`
- `searching`
- `following`
- `holdingDistance`
- `reacquiring`
- `stopped`
- `failed(message)`

The coordinator owns one cancellable follow task. It depends on narrow perception, motion, clock, and lifecycle interfaces rather than SwiftUI, speech, or an AI brain. Its perception interface supplies frame identity and time, YOLO person confidence and bounding boxes, AR pose, and depth-backed world projection. This preserves information that the existing `RoverPerception.detectObjects()` abstraction discards and lets tracker logic be tested independently.

The motion interface exposes scan rotation, navigation toward a world point with the existing safety clearance, and cancellation. Production wiring adapts `NavigationController`; it does not duplicate or bypass navigation safety.

### Existing runtime

The production implementation reuses:

- The bundled YOLO-family `RoverYOLO` Core ML model through `Detector` for `person` bounding boxes.
- Rear-camera frames, pose, and scene depth from `ARSessionManager`.
- Depth unprojection into world coordinates.
- `NavigationController` for rotation, path planning, obstacle handling, motor feedback, and cancellation.

No front-camera session or cloud service is introduced.

## Text and Speech Command UI

The Talk screen adds a general command row containing a text field and a one-tap **Send** button. Keyboard submit performs the same action. Blank or whitespace-only input is not submitted. Accepted input clears the field; rejected or failed submission leaves it available for correction or retry.

Text entry does not depend on speech authorization. The existing push-to-talk control remains available, but its finalized transcript enters the same `OperatorCommandRouter` as typed input.

While follow mode is active, the screen shows the coordinator status and a prominent **Stop Following** button that remains usable without opening the keyboard. Operator-facing labels include:

- `Searching for you…`
- `Following — 1.5 m`
- `Holding distance`
- `Person lost — searching…`
- `Stopped`
- A concise actionable failure message

## Acquisition and Track Lock

On a local start-follow command, the coordinator verifies that the detector is loaded, its labels include `person`, and AR pose/depth are available. It then rotates in 30-degree safe scan increments until it either finds a candidate or completes a cumulative 360-degree search.

An eligible initial candidate is a `person` detection with confidence of at least 0.50, an observation age no greater than 500 milliseconds, and valid depth projection. If several are eligible, the coordinator chooses the candidate whose bounding-box centre is nearest the image centre. That choice establishes the session's track lock.

Subsequent frames gate person detections against the locked track. A candidate must have confidence of at least 0.50, be no more than 500 milliseconds old, remain within 0.75 metres of the predicted world position, and satisfy either bounding-box overlap of at least 0.10 intersection-over-union or normalized screen-centre displacement no greater than 0.25. Exactly one candidate passing the gate continues the track. No passing candidate means loss; more than one means ambiguity. These conservative defaults are centralized configuration values so device calibration can adjust them without changing state-machine behavior.

Image-centre proximity is only an initial-selection rule. A newly central person cannot steal an established lock merely by entering the middle of the frame. Implausible jumps are rejected. If two detections make association ambiguous, the rover cancels forward motion and enters reacquisition rather than guessing.

YOLO does not recognize identity. Continuity tracking reduces accidental switching but cannot prove that a person returning after a complete occlusion is the original operator. Reacquisition therefore accepts only exactly one eligible person projected within 1.5 metres of the track’s last world position; zero or multiple eligible candidates do not restore the lock. If that cannot be established within the timeout, follow mode stops instead of selecting a fresh central person.

## Follow Control

For the locked observation, the coordinator projects the lower-centre region of the person's bounding box through scene depth. The lower-centre point better approximates the person's ground location than the box centre. Invalid or stale frame/depth combinations are never used for motion.

The desired stand-off is 1.5 metres, with a 1.25-to-1.75-metre hold band to prevent oscillation. When the person is outside that band, the coordinator computes a world-space goal on the rover-to-person line that preserves the stand-off rather than navigating to the person's position. When inside the band, it cancels forward motion and continues observing. When too close, it holds position; it does not reverse toward or away from the person as part of this MVP.

Perception continues while navigation is active. Goal replacement occurs at most three times per second and only when the computed goal moves by at least 0.30 metres, preventing overlapping operations and motion churn. A replacement cancels the older navigation operation before issuing the newer goal. Every goal is derived from a recent observation, and stale callbacks from earlier follow tasks cannot restart motion.

## Loss and Reacquisition

When the locked target disappears, becomes ambiguous, or cannot be projected safely, the coordinator immediately cancels forward navigation and enters `reacquiring`. It rotates in 30-degree safe scan increments and only restores `following` when exactly one candidate passes the reacquisition gate. Reacquisition lasts at most 10 seconds. Timeout transitions to `stopped` with a person-lost message and leaves motion cancelled.

Initial acquisition is separately bounded by one cumulative 360-degree rotation. Completing the rotation without a valid candidate stops with `No person found.` The rover never spins indefinitely.

## Safety and Failure Handling

Follow mode fails closed:

- Missing detector, missing `person` label, missing AR pose, or unavailable depth prevents driving and produces an actionable failure.
- A transient loss of pose or depth cancels motion and allows recovery for at most two seconds; failure to recover ends follow mode.
- Obstacle, unsafe clearance, stale motor feedback, path-planning failure, or other navigation failure ends follow mode without weakening `NavigationController` policy.
- The Stop button and local stop phrases cancel the coordinator task and navigation immediately in every state.
- Backgrounding the app or tearing down its runtime cancels follow mode and rover motion.
- Unexpected errors cancel motion, emit detailed runtime telemetry, and expose only a concise operator message.

Cancellation is generation-scoped: observations, navigation completions, and timers from an older session cannot mutate or restart a newer session.

## Testing

### Unit and integration tests

- The command router recognizes the documented normalized follow and stop phrases locally.
- Other typed and spoken requests reach `MissionAgent` unchanged.
- Blank text is rejected, and repeated follow starts are safe no-ops.
- Initial acquisition chooses the eligible person nearest image centre.
- Track association retains the locked person when another person becomes more central.
- Implausible or ambiguous associations cancel motion and begin reacquisition.
- Distance control approaches when too far, holds around 1.5 metres, and never reverses when too close.
- Initial acquisition stops after one cumulative 360-degree search.
- Reacquisition resumes only a plausible track and stops after 10 seconds.
- Invalid or stale frame/depth pairs cannot produce navigation goals.
- Operator stop, safety failure, app backgrounding, and task cancellation always cancel navigation.
- Events from an old session cannot restart movement or change the current state.
- UI tests cover one-tap text submission, keyboard submission, field retention/clearing, status labels, and the always-accessible Stop button.
- Existing mission, speech, navigation, perception, and detector tests remain green.

### Physical-device acceptance

1. With cloud connectivity disabled, face the phone display, type `follow me`, and tap **Send** once.
2. Confirm the rover rotates using the rear camera and stops searching after finding the operator or completing one full rotation.
3. Walk in view and confirm the rover follows while maintaining approximately 1.5 metres of separation.
4. Have a second person cross through the image centre and confirm that the established track is retained or the rover pauses if association becomes ambiguous; it must not select the newcomer solely for being central.
5. Briefly occlude the operator and confirm movement pauses, bounded reacquisition occurs, and following resumes only for a plausible continuation.
6. Keep the operator lost or the scene ambiguous and confirm the rover stops within 10 seconds.
7. Confirm the Stop button and typed or spoken `stop` halt motion immediately.
8. Confirm navigation safety failures end follow mode without continued or stale movement.
