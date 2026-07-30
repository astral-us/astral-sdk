# Room Transition Gravity-Heading Correction Design

## Summary

Replace scan completion based on `CMAttitude.yaw` with mount-independent relative rotation measured around gravity. Slow the scan for reliability, stop treating expected commanded yaw as ARKit relocalization, accept safely traversable hallway-width openings without a fixed maximum width, and persist enough telemetry to distinguish heading, perception, filtering, and planning failures.

This design follows a failed physical-device acceptance run of the session-local room-topology implementation. It supersedes the fixed-mount yaw-conversion assumption in `2026-07-29-room-transition-device-correction-design.md`; the remaining topology, diagnostics, and operator-panel decisions in that design still apply.

## Evidence

The physical-device trace at `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-runtime-correction-20260729.log` contains two exact “Go to the other room” attempts:

- Mission 4 failed at `2026-07-30T00:12:24Z` with `Scan turn could not establish a reliable heading.`
- Mission 5 failed at `2026-07-30T00:13:00Z` with the same reason.
- Both reached `nav_scan_pulse_limit`; neither selected a doorway candidate or began a transition.

In the latest attempt, settled ARKit frame yaw changed consistently with physical wheel commands, usually by 47–71 degrees per pulse. Core Motion progress checks reported contradictory signed changes including -112, -31, +56, -96, -69, +15, +104, and +5 degrees. All sixteen settled frames were also classified as pose discontinuities because normal commanded rotation exceeded the existing 20-degree yaw-jump threshold.

The trace proves that scan control failed before doorway traversal. It does not persist frontier widths, direction availability, or doorway-filter rejection reasons, so it cannot determine why the visible hallway did not become a candidate. Earlier generic exploration in the same session reported multiple frontiers, showing that frontier production itself was active.

## Goals

1. Measure scan rotation reliably for upright, landscape, tilted, and near-vertical device mounting.
2. Perform conservative, settled scan steps that prioritize reliable perception over speed.
3. Separate expected commanded rotation from true AR tracking discontinuities.
4. Admit every safely traversable opening, including hallway entrances wider than 2.0 meters.
5. Persist per-step frontier, filtering, candidate, and heading diagnostics.
6. Pass forward and reverse physical traversal through the same opening.

## Non-goals

- Building a global compass heading.
- Using magnetic north or absolute device orientation.
- Training a doorway vision model.
- Replacing frontier geometry with object-classifier labels.
- Changing doorway-plane crossing confirmation.
- Persisting room topology beyond the current room-mapping session.
- Optimizing scan speed before physical reliability is established.

## Architecture

### Relative heading tracker

Add a focused `RelativeHeadingTracker` to `PhroverKit`. It consumes timestamped device-motion samples and integrates angular velocity projected onto the measured gravity axis. It measures only signed rotation since an explicit reset and does not expose an absolute heading.

The tracker exposes:

- accumulated signed rotation;
- timestamp of the latest accepted sample;
- sample freshness;
- reliability state and a concrete unreliability reason;
- reset for a new scan step.

Projection onto gravity makes the measurement independent of the phone’s fixed mounting orientation and avoids Euler-yaw singularities. The signed rover rate is `dot(rotationRate, normalizedGravity)`: Core Motion gravity points down, matching the positive direction of the existing AR ground-plane yaw convention. Samples with non-monotonic timestamps, excessive gaps, unavailable gravity, or non-finite values are rejected. A rejected sample cannot silently advance scan completion.

`ARSessionManager` owns Core Motion lifecycle and the tracker. Navigation consumes a relative scan-heading interface rather than `CMAttitude.yaw`. Raw attitude yaw is not a fallback.

Initial reliability constants are explicit and configuration-backed:

- device-motion update interval: 1/60 second;
- maximum integration gap: 0.10 seconds;
- maximum heading sample age: 0.15 seconds;
- accepted gravity magnitude: 0.8–1.2 g;
- requested scan step: 30 degrees with the existing 7-degree completion tolerance;
- minimum pulse duration: 0.02 seconds;
- settle duration: 0.75 seconds;
- maximum pulses per step: 8;
- unexpected scan translation: 0.10 meters;
- maximum settled AR/inertial rotation disagreement: 15 degrees.

Values may be tightened after trace-backed physical calibration, but changing them requires updated tests and telemetry evidence.

### Scan controller

`NavigationController` remains the sole motor-control owner. For each requested 30-degree scan step it:

1. stops and waits for fresh normal AR tracking;
2. resets relative heading to zero;
3. sends one minimum-duration turn pulse in the requested direction;
4. stops and waits for physical and visual settling;
5. reads accumulated signed rotation and tracker reliability;
6. repeats conservatively only when more directed rotation is required;
7. completes on reaching the requested angle within tolerance, including correct-direction overshoot;
8. captures the settled AR pose as the actual world-space scan heading.

Each scan step is independent. The next step resets relative heading instead of accumulating a global inertial target. The controller does not automatically reverse after contradictory samples. Contradictory or unreliable heading data causes a bounded safe stop with a specific failure reason.

Pulse duration remains at the minimum while reliability is being established. It does not increase in response to low progress. If a pulse overshoots, the step completes, the overshoot is logged, and the next step still uses the minimum pulse duration. Further speed calibration is deferred until forward and reverse acceptance passes.

### AR tracking validation

ARKit remains authoritative for world position, settled camera pose, geometry, and crossing evidence. Expected yaw during a commanded scan is not itself a pose discontinuity.

During a scan, invalidation is based on:

- session-generation change;
- tracking loss or failure to recover after settling;
- unavailable or stale pose;
- unexpected translation beyond 0.10 meters;
- settled AR rotation differing from reliable inertial rotation by more than 15 degrees.

A normal commanded yaw larger than the old 20-degree threshold is accepted when direction and magnitude are consistent with relative inertial rotation. Outside commanded scans, existing pose-safety behavior remains unchanged.

### Doorway candidate policy

`FrontierFinder` remains responsible for geometric openings. `SessionRoomTopology` converts frontiers into doorway candidates.

Candidate admission requires:

- width at or above the rover-safe minimum;
- a finite centroid;
- a normalizable outward direction;
- geometry that yields a finite beyond-plane goal.

The fixed 2.0-meter maximum width is removed. Wide hallway entrances remain eligible. Width may influence ranking quality, but width above a conventional doorway size is not a rejection reason. Reachability and existing geometric quality determine selection. Optional cloud doorway evidence remains only a ranking boost among admitted geometric candidates.

The existing crossing-clearance and multi-frame doorway-plane confirmation rules remain authoritative for promoting a candidate to a doorway and creating the next room.

### Telemetry boundary

Telemetry is emitted by the component that makes each decision:

- the heading tracker reports accepted/rejected samples and reliability transitions;
- navigation reports pulses, accumulated rotation, settled AR delta, overshoot, completion, and terminal failure;
- topology reports each frontier’s admission or rejection and reason;
- the mission reports scan-step counts, candidate counts, reachability, selection, approach, crossing, and completion.

The operator callback remains diagnostic-only and cannot mutate motion or topology.

## Data Flow

For every scan step:

1. `MissionAgent` obtains current frontiers and refreshes candidates.
2. It logs the scan step, frontier count, candidate count, and ranked reachability.
3. If no reachable unexcluded candidate exists and scan budget remains, it requests a positive 30-degree scan.
4. `NavigationController` establishes normal AR tracking and resets relative heading.
5. `ARSessionManager` feeds device-motion samples to `RelativeHeadingTracker` while navigation performs stop-pulse-stop-settle control.
6. Navigation completes from reliable directed relative rotation, then validates the settled AR frame.
7. Perception extracts frontiers from the new settled view.
8. Topology logs and applies candidate admission rules, including hallway-width openings.
9. The mission ranks reachable candidates and either scans again or begins the existing approach and doorway-plane crossing flow.

No object-classifier label enters this path.

## Telemetry Schema

Each scan step must produce enough structured fields to replay its decision:

- mission ID, room-session generation, and scan-step index;
- requested angle, accumulated inertial angle, settled AR angle, and disagreement;
- pulse index, direction, duration, and overshoot;
- heading sample age and reliability reason;
- AR frame sequence and tracking quality;
- frontier ID, centroid, width, cell count, and whether direction is available;
- frontier admission result and explicit rejection reason;
- candidate ID, beyond-plane goal, reachability, path distance, and rank;
- selected candidate or reason scanning continued;
- terminal scan, navigation, or transition outcome.

Required frontier rejection reasons are `below_safe_width`, `missing_direction`, `invalid_centroid`, `invalid_direction`, and `invalid_beyond_plane_goal`. Additional reasons may be added but must remain explicit.

## Error Handling and Safety

- Motion samples unavailable or stale: stop and fail the scan step.
- Gravity-axis projection unreliable: stop and report the tracker’s reason.
- Timestamp discontinuity or excessive sample gap: invalidate the current relative measurement; do not infer open-loop progress.
- AR tracking unavailable before or after a pulse: stop and use the bounded existing recovery window.
- Unexpected translation during an in-place scan: stop and fail rather than continuing against corrupted geometry.
- AR/inertial disagreement above tolerance: stop and report disagreement; do not reverse automatically.
- Correct-direction overshoot: complete the step at the settled pose and log overshoot.
- No openings: continue the bounded scan.
- Rejected openings: log every reason and continue the bounded scan.
- Unreachable candidates: exclude each for the current mission and continue scanning.
- Exhausted full scan: report that no safe route was found.
- Navigation or tracking failure after selecting a candidate: stop and publish a terminal transition failure.

All failure paths stop the motors before publishing their outcome.

## Testing

### Relative-heading unit tests

- Integrates positive and negative rotation around gravity.
- Produces the same rover-relative result for upright, landscape, tilted, and near-vertical mount fixtures.
- Remains continuous across quaternion and angle wraparound.
- Rejects non-monotonic timestamps, excessive gaps, missing gravity, and non-finite samples.
- Reset makes every scan step zero-based and independent.

### Navigation tests

- Completes after directed rotation reaches the target tolerance.
- Completes and records modest correct-direction overshoot.
- Does not reverse after contradictory or unreliable samples.
- Keeps pulse duration conservative rather than escalating after low progress.
- Stops on stale heading, unexpected translation, AR tracking loss, and AR/inertial disagreement.
- Accepts expected commanded yaw without classifying it as relocalization.
- Still rejects true generation changes and translation jumps.

### Doorway and mission tests

- Conventional doorways become candidates.
- Openings wider than 2.0 meters become hallway candidates.
- Openings below rover-safe width remain rejected.
- Missing or invalid direction and geometry produce explicit rejection telemetry.
- No-opening, rejected-opening, unreachable-candidate, exhausted-scan, and terminal-failure paths remain bounded.
- Candidate approach still requires existing reachability and crossing confirmation.

### Regression suite

Run focused heading, navigation, topology, and room-transition tests; the complete Swift SDK test script; the `RoverNav` target build; the PhroverOperator simulator build; and the physical-device build.

## Physical-Device Acceptance

Reliability, not speed, gates acceptance:

1. Install and launch the corrected app on the iPhone-mounted rover.
2. Place the rover in room A with one safely traversable doorway or hallway entrance available.
3. Command “Go to the other room.”
4. Confirm the bounded scan finishes without heading failure, oscillatory reversal, or pulse-limit exhaustion.
5. Confirm telemetry identifies frontiers, filtering outcomes, a reachable candidate, and candidate selection.
6. Confirm the rover crosses the candidate plane and records room B.
7. From room B, command “Go to the other room” again.
8. Confirm the rover selects the same connection in reverse, crosses its plane, and records room A.
9. Pull the runtime log and verify monotonic relative heading within each step, settled AR agreement, two candidate selections, and two confirmed transitions.

Any heading failure, unbounded motion, missing rejection diagnostics, or unconfirmed crossing fails acceptance. No implementation commit is accepted until both traversals pass.

## Success Criteria

The correction is complete when automated tests pass and one physical run demonstrates reliable scanning, selection of a conventional or hallway-width opening, confirmed room A-to-B traversal, and confirmed room B-to-A traversal through the same connection. The runtime log must independently explain every scan, filtering, selection, and transition decision.
