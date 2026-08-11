# Silent Search: Optical Two-Rover Search

**Date:** 2026-08-11
**Base:** `main` at `2f2eedc`

## Goal

Deliver a constrained, repeatable two-rover demonstration in which two iPhone Pro–equipped WAVE ROVERs search complementary sectors without cloud services, shared Wi-Fi, Bluetooth, or radio communication between phones. The rovers coordinate only by scanning QR codes displayed on one another's screens.

The v1 demonstration must calibrate both independent ARKit sessions into one shared mission frame, divide an unknown indoor space into west and east search sectors, search those sectors through LiDAR-derived frontier exploration, exchange a confirmed target coordinate at a timed rendezvous, and drive both rovers to role-specific stand-off poses around the target.

## Product Behavior

- Each phone connects only to its own rover's ESP32 access point.
- The operator explicitly configures one app instance as Rover A and the other as Rover B.
- Both rovers calibrate against the same printed floor marker before exchanging mission data.
- Rover A searches the west half-plane and Rover B searches the east half-plane.
- The target is one object class supported by the bundled RoverYOLO model.
- Both rovers return to separate rendezvous staging poses at the agreed deadline. A finder may return early and wait safely.
- The finder reports a shared-frame target coordinate by QR code. The peer acknowledges it, and a final optical commit releases both rovers to converge.
- Both screens display `FOUND` only after their own navigation reaches the assigned target stand-off pose.
- If neither rover confirms the target, both stop after exchanging terminal not-found status.

## Architecture

The feature is a deterministic subsystem in `PhroverKit`. It does not depend on a language model and does not adapt `RoverTeamRadio`, whose continuous-radio semantics do not match intermittent optical exchange.

### `SilentSearchCoordinator`

Owns the mission state machine and terminal result. It depends on narrow protocols for calibration, optical exchange, exploration, target tracking, motion, and time. It never sends wheel commands directly; all movement goes through `NavigationController`, preserving the existing obstacle, communication, and progress safety checks.

The coordinator exposes state and diagnostics suitable for SwiftUI without importing UI concerns into the mission implementation.

### `SharedMissionFrame`

Represents a session-local rigid transform between ARKit's navigation plane and mission coordinates. The printed floor marker's center is `(0, 0)`. The marker's printed forward arrow defines mission north; mission west/east are the negative/positive perpendicular axes used for sector filtering.

Calibration detects the marker's QR corners, grounds them with LiDAR, and derives origin, heading, and observed physical size. It accepts calibration only after three samples agree within 0.10 m of origin, 5 degrees of heading, and 15 percent of the configured marker width. The transform is invalidated by an AR session reset or unrecovered tracking loss and is never persisted across sessions.

### `OpticalMessageCodec`

Encodes and validates compact, versioned QR payloads. Every message contains:

- protocol version;
- mission UUID;
- message kind and monotonically increasing sequence;
- sender role;
- calibration marker ID;
- timestamp;
- message-specific body;
- checksum over the canonical payload.

Message kinds are mission offer, acceptance, search commit, rover status, target report, report acknowledgement, and convergence commit. The codec rejects malformed, stale, duplicated, out-of-order, wrong-role, wrong-marker, wrong-mission, and unsupported-version messages.

### `OpticalExchangeService`

Generates high-contrast QR images and scans QR observations from rear-camera frames. Optical exchanges are sequential: one rover displays while the other positions its rear camera toward that screen, then the rovers reverse presentation geometry. The service reports observations; the coordinator decides whether a message is valid for the current phase.

### `SectorExplorer`

Builds a costmap from the current AR mesh, obtains candidate frontiers, converts their centroids into the shared mission frame, and keeps only candidates in the assigned half-plane. A 0.25 m exclusion band around the center line prevents path jitter from producing accidental sector crossings.

Eligible frontiers are ranked by path reachability, distance, width, and whether they have already been visited or rejected. The explorer navigates to one frontier at a time, settles, performs a visual scan, then rebuilds the candidate set. A candidate with no safe path is rejected and exploration continues. Exhaustion returns the rover to rendezvous rather than crossing into its peer's sector.

The planned path is also validated in mission coordinates. A path entering the opposite sector is rejected even when its destination remains in the correct sector.

### `TargetTracker`

Consumes RoverYOLO detections and LiDAR grounding. It confirms the configured canonical object class only after at least three recent detections each have confidence at or above `0.90`, valid depth, and shared-frame positions clustered within `0.35 m`.

The confirmed coordinate is the component-wise median of accepted shared-frame positions. A first sighting, an ungrounded detection, or a differently labelled object never triggers return or reporting.

## Mission State Machine

### 1. Setup

The operator selects Rover A or Rover B, a target from model-supported classes, and a search duration. The app requires normal AR tracking, a loaded detector, and an available rover command link before calibration.

### 2. Calibration

Each rover scans the same physical floor marker independently. The coordinator stores the resulting `SharedMissionFrame` and marker ID. A failed quality check remains in calibration and explains which criterion failed.

### 3. Handshake

The app guides a three-message exchange:

1. Rover A displays a mission offer containing target, role assignment, marker ID, sector policy, search duration, and rendezvous geometry. Rover B scans and validates it.
2. Rover B displays acceptance with its complementary role, calibration identity, and wall-clock reading. Rover A scans and validates it.
3. Rover A displays a search commit with a start time at least five seconds in the future and an absolute deadline. Rover B scans it.

The handshake rejects clock disagreement greater than two seconds. Both coordinators wait until the committed start time before moving.

### 4. Search

Each rover performs one settled initial scan, then repeats:

1. Check the deadline and safety state.
2. Confirm or reject current target observations.
3. Build and sector-filter the frontier set.
4. Select the highest-ranked safe unvisited frontier.
5. Navigate to it through a path that remains in-sector.
6. Settle, scan, and mark the frontier visited.

The loop ends when the target is confirmed, no eligible frontier remains, the deadline expires, or a terminal safety failure occurs. A finder records the target and returns immediately. A rover that exhausts its sector returns and waits.

### 5. Return and Rendezvous

The mission offer defines two staging poses relative to the marker, one per role, so the rovers do not target the same physical point. Each rover navigates to its own pose and remains stopped. A finder waits until the peer arrives or until 60 seconds after the deadline.

### 6. Status and Report Exchange

The app guides sequential role-ordered status exchange. If one rover found the target, the finder displays a target report containing the canonical label, shared coordinate, sample count, confidence summary, and report hash. The peer scans it and displays an acknowledgement of that hash. The finder scans the acknowledgement and displays a convergence commit with a start time at least five seconds in the future. The peer scans the commit.

If both rovers independently report a target, the reports must agree within 0.50 m; otherwise the mission fails as conflicting evidence. If neither reports a target, they exchange terminal not-found status and stop.

### 7. Convergence

Each rover converts the shared target coordinate into its local AR frame and applies a different role-specific stand-off offset. Both wait for the committed convergence time, navigate through normal safety controls, and turn to face the target. A rover displays `FOUND` only after its own motion reaches the stand-off pose and final heading tolerance.

### 8. Completion

The coordinator records a terminal success, not-found result, operator abort, partner timeout, protocol failure, calibration invalidation, or navigation/safety failure. Terminal states stop the rover and remain visible until the operator resets the mission.

## Safety and Recovery

Decision precedence is:

1. Operator Stop or emergency stop.
2. Existing obstacle, communication, tracking, and progress safety.
3. Calibration and shared-frame validity.
4. Optical protocol validity.
5. Mission deadline and rendezvous rules.
6. Exploration and convergence actions.

Additional behavior:

- Limited AR tracking pauses new movement. Failure to recover within five seconds stops the mission and invalidates calibration.
- An AR session reset always invalidates the shared frame.
- Deadline expiry cancels active exploration and begins return.
- A frontier planning failure rejects only that candidate; a transport, reactive-safety, or active-navigation failure terminates the mission.
- Every optical step times out after 30 seconds and offers Retry or Abort. Retry never advances sequence state until a valid message is scanned.
- A missing peer keeps the waiting rover stopped. The mission fails 60 seconds after the search deadline.
- Neither rover begins convergence until report acknowledgement and convergence commit are complete.
- No fallback permits crossing the assigned sector, accepting a lower-confidence target, or moving with an invalid shared frame.

## Operator Experience

The app adds a `Silent Search` tab with phase-specific screens:

- **Setup:** role, supported target class, duration, and readiness checks.
- **Calibration:** marker identity, sample progress, tracking state, and quality diagnostics.
- **Optical exchange:** either a full-screen QR or scanner state with explicit physical positioning instructions.
- **Search:** sector, remaining time, current frontier, visited/rejected counts, rover pose, and target-confirmation progress.
- **Rendezvous:** staging-pose progress and the next report/acknowledgement action.
- **Convergence:** reported target and navigation state.
- **Terminal:** full-screen `FOUND`, `NOT FOUND`, or an exact failure reason.

A persistent red Stop control is present in every moving phase. Waiting states explicitly say that the rover is stopped intentionally.

The functional map displays the marker origin and heading, sector boundary, local rover pose, eligible/visited/rejected frontiers, rendezvous staging poses, planned path, and confirmed target. It does not merge full AR meshes between devices.

## Telemetry

Structured runtime logs include:

- mission UUID and local role;
- coordinator state transitions;
- calibration sample quality and accepted transform;
- QR message kind, sequence, validation outcome, and rejection reason;
- frontier discovery, sector rejection, ranking, path rejection, visit, and exhaustion;
- target observation confidence, grounding result, cluster decision, and confirmation;
- deadline, return, rendezvous, report, acknowledgement, and convergence events;
- terminal result and safety reason.

Logs do not store camera images or complete QR payloads.

## Testing Strategy

Implementation is test-first wherever behavior does not require physical hardware.

### Unit Tests

- Round-trip every QR message and reject altered checksums, stale timestamps, duplicate sequences, wrong roles, markers, and missions.
- Convert points and poses between AR-local and shared frames in both directions.
- Accept and reject calibration sample sets at each quality boundary.
- Filter frontier destinations and full paths against west/east sectors and the center exclusion band.
- Rank reachable, visited, rejected, and exhausted frontiers deterministically.
- Confirm only clustered, depth-grounded, high-confidence detections and compute their median coordinate.
- Derive collision-free role-specific rendezvous and target stand-off poses.
- Exercise every valid and invalid coordinator transition, deadline, timeout, retry, abort, and terminal state.

### Coordinator Tests

Run two coordinators with fake clocks, perception, motion, and an in-memory optical relay. Cover:

- complete handshake and synchronized start;
- Rover A or Rover B as the sole finder;
- matching and conflicting dual reports;
- neither rover finding the target;
- sector exhaustion before deadline;
- duplicate and out-of-order optical messages;
- missing acknowledgement or convergence commit;
- partner rendezvous timeout;
- calibration invalidation and safety-stop propagation.

### UI Tests

- Configuration and readiness gating.
- Calibration cannot advance without accepted samples.
- Presentation/scanning phases and Retry/Abort controls.
- Persistent Stop access during every moving phase.
- Intentional-waiting, not-found, success, and exact failure displays.

### Device Verification

- Use two iPhone Pros, each connected only to its own rover AP.
- Disable cloud-dependent app configuration and use airplane mode where compatible with rover Wi-Fi.
- Verify both phones calibrate to the same marker and agree on test points.
- Verify both paths remain in their sectors during timed frontier search.
- Test each rover as finder, complete the optical report exchange, and confirm both converge without cross-device radio traffic.
- Pull logs and verify calibration, protocol sequence, target evidence, rendezvous, convergence, and terminal status.

## Non-Goals

- Survivor takeover after a rover misses rendezvous.
- VLM-negotiated sector assignment.
- Full map or AR-mesh transfer and map merging.
- Cloud, Bluetooth, peer-to-peer Wi-Fi, or `RoverTeamRadio` coordination.
- Arbitrary object classes or model training.
- Persistent calibration across AR sessions.
- Multiple search/rendezvous rounds.
- Operation without the shared printed marker.
