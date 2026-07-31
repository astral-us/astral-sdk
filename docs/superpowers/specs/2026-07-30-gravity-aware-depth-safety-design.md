# Gravity-Aware Depth Safety Design

**Date:** 2026-07-30
**Status:** Approved

## Problem

During physical room-transition testing, the rover contacted a low table crossbar. The iPhone camera was mounted approximately 40–70 cm above the floor, and its pitch was not known. The runtime trace shows that the final forward command was issued while LiDAR clearance still reported 0.78 m. Navigation stopped because the 2.5-second progress watchdog expired, not because obstacle detection fired. Clearance fell to 0.51 m and then 0.14 m only after the rover stopped.

The current safety calculation samples the tenth percentile from a fixed image-space rectangle: the middle vertical third and central horizontal half of the depth map. This rectangle does not represent the rover chassis. A high or tilted camera can see background above or beyond a low crossbar while the chassis intersects it.

Two secondary weaknesses can defeat otherwise valid obstacle evidence:

- Scene-mesh floor height is estimated from anchor origins rather than mesh geometry, which can classify furniture as overhead.
- If periodic replanning fails, navigation retains and follows the previous path.

## Goals

- Detect low crossbars and other obstacles that intersect the rover body despite camera height or pitch.
- Define safety geometry in rover space rather than image pixels.
- Veto unsafe motor commands independently of route-planning success.
- Fail closed when required calibration or fresh depth is unavailable during translational motion.
- Preserve normal movement over visible clear floor without reacting to isolated depth noise.
- Provide enough telemetry to distinguish perception, calibration, planning, and braking failures.

## Non-goals

- General-purpose 3D mapping or persistent semantic reconstruction.
- Object classification or naming furniture.
- Autonomous calibration of a loose or moving phone mount.
- Replacing the scene-mesh route planner.
- Raising room-transition autonomy beyond the physical acceptance criteria in this document.

## Preconditions and calibration

The phone must be rigidly attached to the rover. A `CameraMountCalibration` records the camera-to-rover rigid transform, including measured camera height, longitudinal and lateral offset, and heading alignment. ARKit supplies each frame's camera orientation relative to gravity, so supported fixed mounting pitch does not require an image-space ROI adjustment.

Calibration values are validated against conservative physical bounds before translational movement. Missing, invalid, or internally inconsistent calibration makes depth safety unavailable and therefore prevents forward or reverse drive. A physically shifting mount is unsupported and must be treated as a hardware fault rather than estimated during motion.

## Architecture

### `CameraMountCalibration`

This value defines the camera frame relative to the rover frame. It exposes validation as part of its interface so consumers cannot silently use incomplete calibration.

### `DepthSafetyEvaluator`

This is a pure geometry module with no AR session or motor-control ownership. It accepts:

- raw and optional smoothed depth samples;
- camera intrinsics and image dimensions;
- the timestamp and camera transform;
- validated mount calibration;
- rover chassis dimensions and safety margins;
- the intended wheel command and timing assumptions.

It returns a `DepthSafetyObservation` containing:

- safety state: `clear`, `caution`, `stop`, or `unavailable`;
- nearest supported hazard distance;
- occupied-cell count and confidence;
- depth source and sample age;
- required stopping distance;
- calibration status and swept-volume coverage;
- the evaluated motion class.

### `ARSessionManager`

`ARSessionManager` remains responsible for ARKit frame acquisition. It passes each frame to `DepthSafetyEvaluator` and publishes the latest immutable safety observation. It does not decide whether motion is allowed.

Raw `sceneDepth` is required for translational safety decisions because smoothing may lag an approaching obstacle. `smoothedSceneDepth` provides secondary stability and diagnostic evidence only; it cannot authorize translation when raw depth is absent or override a nearer valid raw hazard.

### `ObstacleGuard`

`ObstacleGuard` evaluates the intended wheel command against the latest `DepthSafetyObservation`. Translational commands require a fresh, valid observation. It can allow, speed-limit, or reject the command. An unavailable observation rejects translation.

### `NavigationController`

The navigation loop changes ordering:

1. Obtain a fresh tracked pose.
2. Replan when due.
3. Compute the intended wheel command.
4. Evaluate that command's swept chassis volume using the latest depth observation.
5. Stop, slow, or send the command.
6. Repeat at every command tick.

If replanning fails, the controller clears the active path, stops, and reports a planning failure. It never continues on the stale route.

## Geometry and hazard extraction

Valid depth pixels are unprojected through camera intrinsics into 3D camera coordinates and transformed into rover-relative coordinates. Safety evaluation therefore remains stable across supported camera heights and pitch angles.

The evaluator rejects points outside the rover's collision-height band, including floor returns beneath the chassis and overhead returns above it. Remaining points are voxelized into small rover-space cells. Requiring a small connected support cluster rejects isolated noisy pixels without using a global percentile that can hide a narrow crossbar.

For each intended command, the evaluator constructs the rover body's swept volume over the braking horizon:

- Straight translation uses the chassis width plus lateral safety margin.
- Curved translation follows the differential-drive arc and includes the swept outer corners.
- Reverse translation uses the rear swept volume and is permitted only when that volume has adequate sensor coverage; otherwise it fails closed.
- In-place rotation uses the swept footprint and available current depth/mesh evidence. It must not reuse a forward-only clearance assumption.

The evaluator also verifies observability: the near swept volume from the chassis leading edge through the stopping boundary must lie inside the raw-depth camera frustum and contain valid depth support. If camera pitch or missing samples leave that safety-critical volume blind, the result is `unavailable` rather than `clear`.

Any supported occupied cell intersecting the stopping envelope produces `stop`. A supported hazard inside the larger slowdown envelope produces `caution`.

## Braking policy

Required stopping distance is computed from:

- a fixed chassis clearance margin;
- distance travelled over the maximum accepted depth age;
- command and network latency;
- estimated chassis braking/coasting distance at the requested speed;
- an additional configurable safety margin.

A caution observation caps translational wheel speed before the stop boundary. A stop or unavailable observation sends emergency stop and terminates the current navigation attempt with a specific reason. A nearer raw-depth result always wins over a farther smoothed result.

The initial constants must be conservative and derived from physical braking trials. They are configuration values covered by tests rather than literals spread through navigation code.

## Scene-mesh and planner corrections

The scene mesh remains a planning aid and a redundant source of obstacle evidence, not the final motor-safety authority.

Floor height must be derived from actual transformed mesh vertices or a validated horizontal floor plane. Furniture vertices are classified by height above that floor. The implementation must not derive floor height by subtracting a fixed value from anchor origins.

Periodic planning is transactional: a successful plan replaces the active path; a failed plan clears it. Telemetry reports the map evidence, planning result, and stop action.

## Failure handling and telemetry

Forward or reverse translation stops when depth is stale, absent, malformed, unsupported, or paired with invalid calibration. Rotation also requires sufficient evidence for its swept footprint.

Every safety decision logs:

- state and reason;
- raw and smoothed nearest clearance;
- occupied-cell and connected-support counts;
- depth source, age, and swept-volume coverage;
- intended wheel speeds and motion class;
- computed stopping and slowdown distances;
- calibration validity;
- whether mesh planning succeeded.

If the progress watchdog fires and a nearby hazard appears immediately afterward, telemetry records a probable contact or sensing miss. This does not weaken the stop; it makes the incident diagnosable.

## Testing

### Geometry tests

Synthetic depth fixtures cover:

- a low crossbar with camera heights from 0.40 to 0.70 m;
- camera pitches from 30 degrees downward through 30 degrees upward, producing either correct detection or fail-closed `unavailable` when the swept volume leaves the depth frustum;
- centered and lateral crossbar positions;
- flat visible floor;
- overhead geometry above the rover;
- narrow connected hazards;
- isolated invalid or noisy samples;
- straight, curved, reverse, and rotational swept volumes.

### Safety integration tests

Tests verify that:

- no translational motor command is sent with stale, unavailable, or invalid depth;
- caution limits speed;
- stop sends emergency stop;
- nearer raw depth wins over smoothed depth;
- failed replanning clears the previous route and stops;
- corrected mesh floor estimation retains furniture in the obstacle band;
- a sanitized minimal fixture derived from the collision trace flags a physical stall before an obstacle stop.

### Physical acceptance

1. Place a low crossbar at multiple lateral positions and verify that the rover stops without contact.
2. Repeat at representative supported phone pitches.
3. Verify clear-floor travel without persistent false stops.
4. Block or disable depth and verify fail-closed behavior before translation.
5. Record measured stop margin for every obstacle trial.
6. Complete the room-transition mission in both directions without contacting furniture.

Acceptance requires every obstacle trial to retain a documented positive safety margin and both room-transition runs to complete without collision.
