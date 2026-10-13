# Continuous pursuit, coasting and tolerant continuation

## Baseline and scope

Builds on `477a4b359b64015eefebe55e671b7e4ae1af0d46` (`feat/follow-me`). Follow-me was
jerky, dropped the target whenever it was briefly hidden, and lost it when only part of the
body was visible or the person was too close for the shoulders to be in frame.

The three changes below were chosen from a bench of five ideas run against a Python model of
this code on the Godot Depot sim (`eco/rover/sim/follow_bench`, coybot/eco). In that model they
removed the stop-and-go (28 full stops in 46 s to 0), carried the target through a 1-2 s
occlusion, and held it at 0.9 m, where the baseline aborted. Appearance re-ID and a steeper
camera tilt showed no benefit and are not ported. The bench is a model, not this code, so the
numbers are evidence for the design, not a measurement of it.

All three are off by default (`FollowMeConfiguration()` behaves exactly as before);
`FollowMeConfiguration.continuous` enables them and is what the example app uses.

## 1. Continuous goals (`continuousGoals`)

Today every goal change confirms a stop, relaunches `navigateForFollow`, which stops again, and
stops once more on arrival. A person walking at 0.3 m/s moved the 0.30 m goal threshold about
once a second, so the rover spent a large share of its time stationary.

- `NavigationController.updateFollowGoal(_:)` replaces the goal of the running follow drive
  and replans immediately, with no stop. It refuses (returns false, changes nothing) unless a
  `.followGoal` operation owns the controller, is unfenced and uncancelled, no stop is
  unconfirmed, and the new goal plans. The caller then falls back to stop-and-relaunch.
- `drive` adopts the live goal on its next tick and resets the stall watchdog, because
  distance-to-goal stops measuring progress across a goal change.
- Safety is unchanged: the same guard layer, obstacle stop, comms watchdog and ownership
  fencing run every tick. An obstacle still fails the follow drive exactly as before.
- With a track, the stand-off goal is aimed `goalLeadSeconds` (0.8 s, at most 1 m) ahead of the
  person's estimated velocity, so the rover closes toward the stand-off instead of settling at
  the far end of pursuit's slow-down ramp.
- Goal gating loosens to 0.10 m and 5 Hz (`continuousMinimumGoalChange`,
  `continuousMaximumGoalUpdatesPerSecond`).

## 2. Coasting track (`coastSeconds`)

`TargetKalmanFilter` (RoverNav) is a constant-velocity filter over `[x, y, vx, vy]` with
Mahalanobis gating for position and bearing measurements. The coordinator seeds it on the first
steady-following frame and drops it whenever the lock is dropped.

- Association predicts with the track instead of the last position. After 0.35 s without a
  measurement the world gate widens to 3 sigma (at most 2 m) and the box-overlap test, which
  compares against a stale box, is skipped.
- A frame with no match no longer starts recovery while the target has been unmeasured for at
  most `coastSeconds` (3 s). The follower keeps steering at the predicted position. Beyond that,
  `loseTarget` runs exactly as before (stop, scan, reacquire), so every existing recovery,
  fencing and deadline rule still applies.
- Coasting synthesizes a `FollowPersonObservation` at the predicted position for the current
  frame only. It never replaces `locked` and never enters reliable memory, so recovery's anchor
  is always the last real measurement.
- Logged as `follow_coast.started`, `.recovered` and `.expired`.

## 3. Tolerant continuation (`tolerantContinuation`)

The full-body check (both shoulders and both hips) is the right rule for choosing a target and
the wrong one for keeping it: a pillar over the hips, or standing 1 m away with the shoulders
out of frame, fails it. Acquisition is unchanged.

- `FollowFrameBatch.partialPeople` carries detections that did not become full observations
  (failed verification, projection rejected, below 0.50 confidence) as `FollowBearingObservation`:
  a bounding box and a nav-plane azimuth from `FollowPersonProjection.centerBearing`, which uses
  no depth. Depth read through a partly hidden body lands on the occluder, so only the direction
  is trusted.
- While coasting, exactly one partial inside the gate updates the track by bearing alone and
  refreshes the coast clock. The gate is the filter's own Mahalanobis gate **and** an absolute
  `maximumBearingInnovation` of 0.35 rad: a coasting filter is uncertain enough that its gate
  alone accepted a person 55 degrees off. Two candidates in the gate update nothing.
- Bearing alone can sustain the track for at most `maximumBearingOnlySeconds` (6 s) after the
  last full position measurement.
- A partial detection never acquires a target and never starts motion by itself.

## Regression coverage

- `TargetKalmanFilterTests`: learns velocity, coasts with growing uncertainty, gates and widens,
  bearing corrects direction but not range, wraps at pi, ignores past and non-finite times.
- `NavigationFollowLiveGoalTests`: redirects a running drive without a stop, ends as arrived at
  the live goal, refuses when idle, when unplannable and after the drive ended.
- `FollowContinuousCoordinatorTests`: steers instead of stopping; falls back when refused;
  default config still stops between goals and loses on the first miss; coasts and expires;
  resumes without searching; ignores a person far from the prediction; bearings extend the track
  but are bounded; wrong-direction and ambiguous bearings do not; partials never acquire.
- `FollowBearingObservationTests`: centre bearing agrees with the depth-projected direction,
  works without depth and with a clipped box, rejects bad input; rejected people become partials,
  accepted ones do not.

## Known limits

- Coasting steers toward a predicted position the rover cannot see. An obstacle on that path
  fails the follow drive as it would for any follow goal; it does not route around it.
- The constants (3 s coast, 0.35 rad bearing cap, 0.8 s lead) come from the bench and have not
  been tuned on a rover.
- The pre-follow phases (alignment, ready signal, departure gate) are unchanged and do not coast.
