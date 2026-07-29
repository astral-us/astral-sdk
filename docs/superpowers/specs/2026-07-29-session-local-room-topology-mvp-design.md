# Session-Local Room Topology MVP Design

## Summary

Phrover Operator correctly recognizes “Go to the other room,” but historical device logs show the mission can inherit a stale navigation failure, select an already-visited opening, and abort during post-turn ARKit stabilization. This design completes the existing recovery work and adds a deterministic, session-local room topology to the SDK. A room-transition mission will select a viable doorway, traverse it, confirm that the rover crossed into another room, and stop.

The topology is session-local: it starts with an AR session and is discarded when that AR session resets or the app terminates. It is topological rather than a full geometric floor plan: rooms are nodes, doorways are bidirectional edges, and poses provide local evidence for transitions.

## Goals

- Make standalone room-transition commands such as “Go to the other room” deterministic and testable.
- Keep room behavior in the SDK rather than the example application.
- Confirm success from physical doorway crossing, not merely arrival near an opening.
- Recover within fixed limits from blocked candidates, stale state, and tracking interruptions.
- Operate offline from geometry; use cloud vision only as an optional ranking signal.
- Preserve all existing navigation safety controls.

## Non-goals

- Persistent topology across AR resets or app launches.
- Named or semantically classified rooms.
- Polygonal room boundaries or a complete floor plan.
- A dedicated on-device doorway model.
- Multi-rover topology synchronization.
- Replacing object-target missions such as “find the chair in the other room.”

## Domain model

- **Room-mapping session:** the lifetime of one local room topology, aligned with one AR tracking session.
- **Room:** a topological region occupied by the rover. The MVP stores identity and representative poses, not a polygon.
- **Doorway candidate:** an opening with enough geometric evidence to potentially connect the current room to another room.
- **Doorway:** a promoted, bidirectional connection between rooms.
- **Room transition:** a confirmed crossing from one room to another through a doorway.
- **Current room:** the room containing the latest stable rover pose.
- **Room-transition mission:** a mission whose destination is another room rather than an object or named location.

A standalone command with a transition verb (`go`, `move`, or `enter`) and a destination phrase (`other room`, `another room`, or `next room`) is a room-transition mission. Commands containing a concrete target, such as “go to the chair in the other room,” remain object-target missions.

## Architecture

### `RoverNav`: frontier direction

Extend `Frontier` with an outward unit direction from observed space toward adjacent unobserved space. `FrontierFinder` derives it from the aggregate vectors between frontier cells and their unobserved neighbors. Degenerate clusters without a stable direction remain exploration frontiers but are not doorway candidates.

This direction defines a doorway plane through the frontier centroid. Its positive side points toward unknown space.

### `PhroverKit`: session topology

Add a focused `SessionRoomTopology` module with no dependency on mission-brain implementations or motor control. Its public interface supports:

- starting and resetting a room-mapping session;
- ingesting stable poses, frontiers, and optional visual evidence;
- returning ranked doorway candidates for the current room;
- beginning, observing, confirming, rejecting, or abandoning a pending transition;
- reading the current room and session graph.

The initial stable pose creates `room_1`. The module owns stable room and doorway identities. `MissionAgent` consumes this interface but does not manipulate topology internals.

### `PhroverKit`: mission orchestration

`MissionAgent` recognizes room-transition intent before asking a general-purpose brain for a decision. It requests the best doorway, asks `NavigationController` to navigate to a point beyond the doorway plane, observes transition progress, and completes after crossing is confirmed.

At mission start, any non-idle motion state is canceled and reset before context or topology decisions are made. Candidate rejection is mission-local unless geometry proves the candidate is no longer usable for the session.

### `PhroverKit`: navigation

`NavigationController` remains responsible for motion and safety. It accepts topology-suggested goals but continues to enforce obstacle, person, tipping, command-link, path, and tracking constraints. Scan turns use bounded inertial-heading progress, fresh post-turn camera frames, and AR pose rebasing. A topology module cannot bypass a safety stop.

### `PhroverCloud`: optional visual evidence

Define `DoorwayEvidenceProviding` in `PhroverKit`. The protocol returns confidence in `[0, 1]` for currently visible candidates. `PhroverCloud` implements it through the existing cloud vision capability. The provider has a 1.5-second deadline and is optional. Missing, late, malformed, or failed evidence contributes no score and never blocks geometric operation.

The example app only wires the topology, optional cloud provider, and AR-session reset notification.

## Candidate construction and ranking

A frontier can become a doorway candidate when:

- its width is between 0.65 m and 2.0 m;
- it has a stable outward direction;
- its centroid is reachable according to the current navigation map;
- it is not already rejected for the active mission.

Fresh candidates match existing candidates when their centroids are within 0.5 m and outward directions differ by no more than 35 degrees. Matching preserves identity across perception updates.

Ranking is deterministic in this order:

1. unexplored candidates before previously traversed candidates; candidates rejected for the active mission are excluded;
2. candidates with a navigable goal beyond the doorway;
3. geometric doorway quality, including usable width and frontier support;
4. optional cloud-vision confidence boost;
5. shorter path distance;
6. stable candidate identifier as the final tie-breaker.

Visual evidence can reorder otherwise viable candidates but cannot promote geometrically invalid candidates.

## Transition geometry and data flow

When a candidate is selected:

1. Record the current room, doorway plane, approach-side signed distance, and candidate identity.
2. Place the navigation goal on the unknown side of the plane far enough for the rover center to clear the plane by 0.35 m, subject to path planning and safety clearance.
3. While navigating, ingest only normal-tracking poses from fresh frames.
4. Confirm crossing after the signed distance changes from the current-room side to at least +0.35 m and remains there for three consecutive fresh poses.
5. Stop motion and promote a first-time candidate to a doorway connected to a new room. If the candidate matches an existing doorway, use that doorway’s known opposite room instead of creating another room.
6. Set the destination room as current and emit completion telemetry.

Approach, lateral motion, arrival at the centroid, or a single discontinuous pose cannot confirm a transition. Crossing an existing doorway in reverse returns to its known source room instead of creating another room.

## Recovery and failure behavior

- **No candidate:** perform one bounded scan covering at most 360 degrees, refresh frontiers, then retry selection.
- **Blocked or unreachable candidate:** reject it for the active mission and try the next ranked candidate.
- **Candidate budget:** attempt at most three candidates in one room-transition mission.
- **Tracking interruption:** stop, wait for fresh normal tracking, and retry within the existing bounded scan/tracking budget.
- **Crossing not confirmed:** do not mutate the room graph; reject the attempt and continue within budget.
- **Cloud timeout:** continue immediately with geometric ranking.
- **Cancellation or “stop”:** cancel motion and abandon the pending transition without changing current room.
- **AR reset:** synchronously discard rooms, doorways, candidates, and pending transitions.
- **Budget exhausted:** stop and report, “I couldn’t find a safe route into another room.”

Telemetry includes `room_session_started`, `doorway_candidate_ranked`, `room_transition_started`, `doorway_crossed`, `room_transition_completed`, `room_transition_rejected`, and `room_session_reset` with stable session-local identifiers.

## Testing

### Frontier tests

- Outward directions point from observed cells toward unknown cells.
- Degenerate directions are rejected for doorway use.
- Width filtering accepts door-sized openings and rejects noise or overly broad map edges.

### Topology unit tests

- First stable pose creates the initial room.
- Approach, lateral motion, stale frames, and pose jumps do not confirm crossing.
- Three fresh poses beyond the margin confirm a transition.
- Forward crossing creates a second room and a bidirectional doorway.
- Reverse crossing returns to the original room.
- Spatially matching doorway observations deduplicate.
- AR reset clears all session topology.

### Mission integration tests

- Standalone “Go to the other room” uses deterministic topology rather than free-form planner selection.
- Object-target commands mentioning another room retain existing behavior.
- New missions clear stale navigation failure before choosing a doorway.
- Blocked and previously visited candidates reroute to the next viable candidate.
- A mission stops after its first confirmed room transition.
- Cancellation and exhausted recovery do not mutate topology incorrectly.

### Cloud adapter tests

- Visual evidence boosts candidate ranking.
- Timeout, offline operation, malformed output, and provider errors fall back to geometry.

### Navigation regression tests

- Scan turns accept fresh post-turn frames.
- AR pose discontinuities rebase scan targets.
- Inertial no-progress handling and direction reversal remain bounded.
- Every scan failure sends a stop command.

### Test infrastructure

Add an iOS Simulator test path for SDK tests. The present `swift test` path cannot compile UIKit-dependent `PhroverKit` on macOS, and the current Xcode package schemes have no test action. The new test path must run the topology, mission integration, and navigation regression suites from one documented command.

## Device acceptance

On an iPhone connected to the rover:

1. Start a fresh AR session in Phrover Operator.
2. Issue “Go to the other room.”
3. Verify the rover chooses a viable doorway and does not reuse a rejected candidate.
4. Verify logs contain `room_transition_started`, `doorway_crossed`, and `room_transition_completed`.
5. Verify current room changes from `room_1` to `room_2` only after crossing.
6. Verify no stale navigation failure appears in the first mission context.
7. Verify no unbounded scan or repeated doorway loop occurs.
8. Issue the reverse room-transition command and verify the known doorway returns the rover to `room_1`.

## Success criteria

The feature is complete when the automated SDK suites run through the documented iOS Simulator command and the device acceptance sequence completes without `mission_motion_failed`, stale mission state, repeated rejected candidates, or false room creation.
