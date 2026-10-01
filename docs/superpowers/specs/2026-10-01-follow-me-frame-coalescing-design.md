# Follow-Me Frame Coalescing and Startup Readiness Design

**Date:** 2026-10-01
**Status:** Approved

## Problem

A physical-device follow session acquired and tracked a person successfully, with normal AR tracking, valid pose and depth, and detector inference taking roughly 22–50 milliseconds. The session later failed because processed observation age increased from 0.58 seconds to 1.65 seconds and then 2.43 seconds.

`ARSessionManager.snapshots()` already retains only its newest camera snapshot. However, `ARFollowMePerceptionSource` converts those snapshots into a combined, unbounded stream of frame and lifecycle events. `FollowMeCoordinator` consumes that stream serially and awaits motor-stop confirmation while processing a frame. Frames produced during that wait accumulate in the combined stream, so the coordinator later processes obsolete observations and correctly rejects them as stale.

A fixed delay before searching would not correct this mid-session backlog. Follow mode instead needs readiness-based startup and newest-frame processing without weakening lifecycle or motion safety.

## Goals

- Process only the newest pending frame when follow coordination is busy.
- Preserve every AR interruption and failure event.
- Keep the rover stationary until perception is ready, for at most five seconds after startup.
- Start searching as soon as a fresh frame has normal tracking, a pose, and depth.
- Keep the existing two-second recovery limit for perception loss after startup.
- Avoid repeated motor-stop requests during one continuous perception outage.
- Preserve the 500-millisecond observation freshness limit and all confirmed-stop requirements.

## Non-goals

- Increasing the 500-millisecond freshness limit.
- Weakening AR, depth, navigation, or motor-feedback safety policy.
- Changing detector, tracker, stand-off, scanning, or reacquisition behavior.
- Splitting the public perception protocol into separate frame and lifecycle streams.
- Adding a fixed five-second delay to every follow request.

## Chosen Approach

Implement coordinator-side selective coalescing. The perception event reader remains responsive and never awaits motor or navigation work. It handles lifecycle events without dropping them and stores frame events in a single newest-pending-frame slot. One frame processor drains that slot serially. If more frames arrive while processing is suspended, each replaces the pending frame, so processing resumes with the newest observation rather than an obsolete queue.

This approach is narrower than changing the `FollowMePerception` protocol and safer than applying `.bufferingNewest(1)` to the combined event stream. Buffering the combined stream could allow a camera frame to overwrite an interruption or failure event.

## Components and Responsibilities

### Perception event ingestion

The ingestion task reads `FollowPerceptionEvent` values continuously for the active generation.

- `.frame` replaces the pending frame and ensures one processor is running.
- `.interrupted` and `.failed` immediately enter the existing terminal failure path; they are never placed in the coalescing slot.
- Stream completion remains a terminal `Perception ended.` failure when the generation is still active.
- Generation changes, operator stop, safety failure, and teardown cancel ingestion and processing.

### Newest-frame processor

Only one frame processor runs for a generation. It takes the pending frame, clears the slot, and executes the existing frame-handling state machine. On completion it takes the newest frame that arrived during processing. It exits when no frame remains or the generation is inactive.

Frame identifiers remain monotonic guards. A frame older than or equal to the last accepted frame is ignored. Before any movement can start, the existing timestamp-age check is applied using the current clock, so a frame that expires during a motor acknowledgement still cannot produce a goal.

### Startup readiness

Add `startupReadinessSeconds` to `FollowMeConfiguration`, defaulting to 5 seconds. This is independent of `perceptionRecoverySeconds`, which remains 2 seconds.

At follow startup:

1. The coordinator enters `searching` and starts perception ingestion.
2. The rover remains stopped and scan rotation is not launched.
3. Frames may update the current diagnostic issue, but readiness is established only by a frame that is no more than 500 milliseconds old and has normal tracking, a valid pose, and depth.
4. On the first healthy frame, the startup timer is cancelled and normal initial candidate selection or scan behavior begins immediately.
5. If readiness is not established within five seconds, follow fails with the latest specific perception message, or the `noFrames` message if no frame arrived.

No mandatory startup delay is introduced.

### Mid-session perception recovery

After readiness, the first unhealthy or watchdog-detected observation in a continuous outage:

1. Records the perception issue.
2. Establishes one recovery deadline at current time plus two seconds.
3. Requests one confirmed motor stop.
4. Cancels active movement/scanning state after confirmation and starts one recovery timer.

Further unhealthy frames may replace the reported issue and diagnostics, but do not extend the deadline or initiate another stop while that outage remains active. A healthy frame clears the issue, deadline, and timer, then resumes state-machine processing. Failure to recover by the original deadline ends follow mode with the latest actionable issue.

If motor-stop confirmation fails, the existing failed/blocked behavior remains authoritative. No frame may launch motion while stop confirmation is pending or blocked.

## Safety and Error Handling

- AR interruption and failure events bypass frame coalescing and fail follow mode immediately.
- Operator stop, app teardown, safety failure, and generation invalidation prevent pending work from restarting movement.
- Frames stay subject to the 500-millisecond age boundary at the point of use.
- A delayed stop acknowledgement cannot make an expired frame actionable.
- Startup timeout reports the most recent issue without waiting longer than five seconds.
- Mid-session perception loss retains its original two-second limit; repeated frames cannot extend it.
- One continuous outage causes one confirmed-stop operation. Recovery followed by a later outage may initiate a new stop.

## Diagnostics

Existing `follow_state`, `follow_frame`, `follow_perception_unavailable`, and `follow_perception_recovered` events remain. Frame diagnostics describe frames actually selected for processing rather than every superseded frame. The latest batch remains available for failure details such as tracking reason, frame age, depth availability, and inference duration.

No high-volume log is added for every dropped frame. A bounded aggregate or occasional coalescing diagnostic may be added only if needed by tests or physical validation.

## Testing

Add deterministic regression coverage at the coordinator seam:

- Suspend motor-stop confirmation, send enough frames to reproduce accumulation, release the stop, and assert that only the newest pending frame is processed and obsolete frames do not cause a stale-frame failure.
- Send an interruption or failure amid a frame burst and assert that it is neither discarded nor delayed behind frame processing.
- Assert that one continuous perception outage initiates only one confirmed stop.
- Assert that a healthy frame recovers within the existing two-second mid-session window.
- Assert that startup accepts the first healthy frame at any time before five seconds and begins searching immediately.
- Assert that startup fails at five seconds with the latest actionable issue.
- Assert that startup with no frames reports `noFrames`.
- Assert that mid-session recovery still expires after two seconds.
- Retain coverage proving the 500-millisecond boundary is fail-closed and delayed stop confirmation cannot launch a goal from an expired observation.

Run focused FollowMe tests, the full SDK test suite, and an iOS device build.

## Physical Acceptance

In a supervised follow session:

1. Issue `follow me` and confirm the rover remains stationary until a healthy observation is available.
2. Confirm searching begins as soon as readiness is established rather than after a fixed delay.
3. Exercise goal replacement and person reacquisition while observing follow diagnostics.
4. Confirm selected frame age remains bounded and does not climb because of queued observations.
5. Confirm interruption, perception loss, operator stop, and safety failures still stop the rover fail-closed.

App installation, launch, and rover movement require an explicit operator request.
