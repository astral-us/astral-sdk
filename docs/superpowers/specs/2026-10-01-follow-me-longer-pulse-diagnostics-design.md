# Follow-Me Longer Scan Pulse and Detailed Diagnostics Design

**Date:** 2026-10-01
**Status:** Approved design, pending written-spec review
**Baseline:** HEAD `259d442`
**Scope at this stage:** Design documentation only. Production implementation, test execution, build, installation, launch, and physical motion have not begun. The design is committed under the design workflow; pushing and hardware actions require separate authorization.

## 1. Decision and relationship to existing specifications

The user approved increasing the **requested follow-only scan motor pulse from 80 ms to 200 ms** and explicitly requested detailed logging of what happens. Settling remains 300 ms. Wheel cap, proportional gain, yaw-progress watchdog, safety checks, cancellation, and confirmed-stop behavior remain unchanged.

This specification supersedes only the follow-scan pulse duration and diagnostic/failure-reporting requirements in `2026-10-01-follow-me-ready-signal-amendment.md`. That amendment, including its review corrections, continues to define ready motion and local Stop. The stationary-departure, frame-coalescing, voice-only, and base follow-me specifications continue to apply wherever this document does not supersede them. Earlier documents and `.superpowers` workflow assets remain intact.

The change is a bounded calibration experiment with enough evidence to distinguish command scheduling, measured AR yaw progress, stopping, and person association. It is not a finding that a weak pulse caused the observed failure.

## 2. Evidence and unresolved cause

Latest actual-device evidence is the captured `phrover-iphone15pro-safety-259d442.log`, with failures on **2026-10-02 at 04:05:58 UTC and 04:06:42 UTC** (October 1 local time). The evidence is associated with revision `259d442` by the installation record, not by a build identifier in the log.

| Evidence | What it establishes |
| --- | --- |
| `no_yaw_progress` at both failure times | The existing measured-yaw progress watchdog terminated rotation. |
| Reported yaw about 31°, target about 61°, final opposite-sign wheel commands of magnitude about 0.10 m/s | Rotation still had substantial reported heading error at failure and was using the low follow-scan cap. These rounded values are historical evidence, not sufficient for a precise progress calculation. |
| Pulse requests returned HTTP 200 | The transport acknowledged requests; this is not wheel-motion or braking evidence. |
| AR observations were fresh and tracking was normal | The perception freshness/health checks passed. This does not prove that each controller yaw sample changed or that AR pose accurately represented physical rotation. |
| User observed “started rotate then stopped” | Some physical rotation occurred before stopping. Its angle, speed, duration, and relationship to individual pulses are not measured by that report. |

**Weak/insufficient pulse versus stale or insufficiently changing pose remains unproven.** No claim is made that the detector missed the person, that depth projection failed, or that the person-association thresholds caused these scan failures. The new logs must expose the available measurements without turning these hypotheses into diagnoses.

## 3. Focused controller architecture

### Profile ownership and selection

`RoverConfig` owns the follow-scan rotation profile. `NavigationController` selects it **only when the captured rotation purpose is `.followScan`**. Initial search and reacquisition scans use that purpose through the existing follow-motion adapter. The profile is selected once for an operation and retained in that operation's diagnostic snapshot.

| Parameter | Approved follow-scan value |
| --- | --- |
| Requested pulse wait | **0.200 s**, replacing 0.080 s |
| Settle wait after acknowledged pulse stop | **0.300 s**, unchanged |
| Wheel magnitude | `min(0.10, abs(normalizedYawError) * 0.30)` m/s |
| Generic minimum-speed floor | Bypassed for follow scan, as before |
| Yaw-progress watchdog interval | **2.5 s**, unchanged |
| Required yaw progress | **0.05 rad**, unchanged |
| Scan angular tolerance | Existing scan tolerance, unchanged; log the selected value |

The generic pulsed rotation profile remains 80 ms. Generic wheel tuning, generic navigation, continuous rotation, follow alignment, ready-signal motion, and following motion are unchanged. Alignment remains the existing continuous confirmed-stop-bracketed turn; it must not inherit the 200 ms pulse profile merely because it belongs to a follow session.

The controller retains sole authority over motor work, serialized command/stop handling, safety evaluation, and the `stopUnconfirmed` latch. The coordinator's `detectionStop` path fences/cancels scan work and asks the controller to confirm stopping; it does not send wheel commands, create a pulse timer, perform a motor stop itself, or authorize alignment before controller confirmation.

### Pulse lifecycle

For each pulse, preserve the existing sequence and interruptibility:

1. Validate current operation ownership, cancellation, latch, and existing safety gates; capture the pre-pulse pose/yaw and selected profile.
2. Begin the motor send and record its response or failure. Recheck ownership/cancellation after suspension before further work.
3. Perform the requested 200 ms pulse wait at the existing controller wait boundary. Do not move that boundary to compensate for transport latency. Record the actual host wait start/end.
4. Issue the existing serialized pulse stop and record its response. A failed or unconfirmed stop retains the latch and blocks further motion.
5. After confirmed stop, perform the unchanged 300 ms settling wait, with normal cancellation and ownership gates.
6. Capture post-pulse measured yaw, normalized delta/error, and watchdog state; continue, complete, or fail under the unchanged policy.

All existing independent confirmed-stop cleanup remains authoritative, including when cancellation interrupts a pulse's own stop request. A cancelled request is not confirmation that motors stopped. A valid independent acknowledgement is evaluated under the existing stop-confirmation rules, not inferred from task cancellation or an HTTP response for a nonzero command.

Increasing a host-requested wait can increase physical motion and overshoot. It does not guarantee 200 ms of physical motor activation: send latency, firmware timing, stop latency, inertia, and pose error still apply.

## 4. Preserved lifecycle and safety invariants

- Retain the mandatory **full five-second stationary pause**; healthy observations cannot shorten it. Retain the existing startup readiness window after that pause.
- Initial search remains bounded by **at most 360° (2π rad) of requested cumulative scan rotation**, with the final increment shortened. This is a requested-angle budget, not an encoder-measured travel guarantee.
- An eligible detected person immediately fences scan continuation and requires confirmed stop before alignment. Detection cannot authorize a leftover pulse or a second motion owner.
- Reacquisition remains bounded by **10 seconds** under the existing deadline semantics. A longer pulse does not reset or extend that deadline.
- Retain the single **10 cm requested ready signal** per session, all existing measured travel/clearance/watchdog bounds, final confirmed stop, fresh post-stop baseline, and no retry of an interrupted signal.
- Retain inclusive **500 ms observation freshness**, timestamp-based watchdog behavior, and the **two-second continuous-outage** policy. New diagnostics cannot refresh observations or rescue expired frames.
- Preserve stand-off following, association gates, hold band, departure baseline, no reverse, and generation/operation fencing.
- Stop, background/leave-Talk, safety failure, and cancellation remain effective throughout send, pulse wait, stop response wait, settle, and completion. No completion from an old session or operation can resume motion.
- `localStop` retains synchronous motion inhibition and local routing, with **no Thinking phase** or brain fallback. Failed stop confirmation blocks new motion through the existing latch/ownership rules.

## 5. One precise failure formatter and deterministic precedence

Use one shared formatter for follow-motion failures delivered through either the controller safety stream or the awaited motion result. Both deliveries carry an immutable context captured before the operation can be cancelled or replaced: session generation, operation ID, rotation purpose, selected profile, and the actual typed failure reason.

Map follow-scan `no_yaw_progress` to the operator message:

> Search rotation stopped: insufficient measured yaw progress. Stop confirmed. Restart following to try again.

The `Stop confirmed` wording is published only after authoritative confirmation. While confirmation is pending, use:

> Search rotation stopped: insufficient measured yaw progress. Confirming motor stop…

If stop confirmation fails, the higher-priority message is:

> Motor stop could not be confirmed. Motion is blocked.

The diagnostic reason remains `no_yaw_progress`; the terminal diagnostic also records any stop-confirmation failure. This formatter describes measured progress, not “motor stalled,” “person not found,” or proven stale pose. Non-stall reasons preserve their existing specific mappings. Captured purpose determines the context: a follow-scan failure must not be relabeled as alignment, generic navigation failure, or person loss after state changes.

The safety stream and result path converge on one generation/operation-scoped failure record. Either arrival order produces the same primary reason and operator message. The second delivery enriches/deduplicates that record and cannot overwrite a specific reason with a generic wrapper such as `navigation_failed` or `transport_failed`. An independently observed stop-confirmation failure has higher priority than the scan failure and cannot subsequently be downgraded by a successful stale callback. Stale records may be logged with `stale=true`, but cannot mutate the current session's UI or stop latch.

## 6. Structured motion event contract

Emit structured, single-record events on the existing diagnostic stream. Events capture immutable primitive values synchronously at the controller/coordinator/tracker boundary that owns the fact. Logging introduces **no awaits**, unstructured motor tasks, asynchronous state reads, or additional safety decisions. Formatting uses the captured values only; it must not consult mutable “current operation” state later. The existing serialized ownership boundary provides event ordering, with an incrementing sequence to resolve equal timestamps.

### Common envelope

Every event includes these keys. Fields that do not apply are explicit `null`; unavailable measurements are `null` with an availability reason, never fabricated zeroes.

| Key | Meaning |
| --- | --- |
| `event`, `schema_version` | Stable event name and version `1`. |
| `session_generation`, `operation_id` | Follow-session and controller-operation correlation; coordinator-only events use null operation ID when no operation exists. |
| `stream_id`, `event_sequence`, `monotonic_s` | Identified emitting serialized stream, its incrementing sequence, and host monotonic time in seconds. Sequence orders events within that stream; correlate different streams by operation and monotonic time without claiming a total sequence order. Compare monotonic times only within the same runtime. |
| `utc_time` | Wall-clock correlation with device logs; not the clock for durations/deadlines. |
| `purpose`, `phase`, `pulse_index` | Captured purpose and follow phase; pulse index starts at 1 per operation, null outside a pulse. |
| `stale`, `outcome`, `reason` | Ownership freshness, event outcome, and stable typed reason. |

### Required event names and stage fields

| Event | Required stage information |
| --- | --- |
| `follow_scan.operation_begin` | Requested increment, target yaw, requested scan budget used/remaining, operation-start time, full selected profile. |
| `follow_scan.pulse_begin` | Pre-pulse sample, signed wheel requests, pulse-begin time, current error and watchdog checkpoint. |
| `follow_scan.send_begin` | Send-start time and command kind/nonzero wheel requests. |
| `follow_scan.send_ack` | Send-end time, host send duration, acknowledgement status/HTTP status when available, command-ack time/age when exposed. |
| `follow_scan.pulse_wait_begin` / `follow_scan.pulse_wait_end` | Wait-start/end times, requested wait, measured host wait duration, completed/interrupted outcome. |
| `follow_scan.stop_begin` / `follow_scan.stop_response` | Stop identity, pulse/independent/final/detection/cleanup origin, start/end times, host response duration, acknowledged/cancelled/failed outcome and latch state. |
| `follow_scan.settle_begin` / `follow_scan.settle_end` | Settle-start/end times, requested settle, host elapsed, interrupted/completed outcome, post-pulse sample when available. |
| `follow_scan.pulse_complete` | Pre/post samples, measured signed yaw delta, error improvement, watchdog checkpoint and elapsed, operation elapsed. |
| `follow_scan.operation_complete` | Final yaw/error, elapsed, completed/cancelled/failed outcome, primary failure, stop result, final latch state. |
| `follow_scan.cancel` | Cancellation origin, interrupted stage, operation fence state and time; cancellation is not reported as stop confirmation. |
| `follow_scan.failure` | Failed stage, typed reason, pre/post/checkpoint measurements available at failure, elapsed, profile, and current confirmation state. |
| `follow_motion.failure_resolution` | Correlated stream/result delivery, retained primary reason, stop-confirmation outcome, formatter message/priority, stale/deduplicated status. |

A send error uses `send_ack` with a failed outcome and no invented HTTP status, followed by failure/cleanup events. Interrupted waits get their end event with an interrupted outcome. Stages never entered have no fabricated begin/end events; completion identifies the last reached stage. Detection-stop and final cleanup responses retain the operation correlation even if their pulse index is null.

### Measurement and timing fields

For pulse begin/completion, failure, and operation completion, include:

- `pre_yaw_rad`, `post_yaw_rad`, `target_yaw_rad`, `pre_error_rad`, `post_error_rad`, `signed_yaw_delta_rad`, and `error_improvement_rad` where available. Render angles with **six decimal places**, including their sign. Preserve numeric precision in the structured representation; display rounding is not watchdog input.
- Normalize errors to the shortest signed angle in `[-π, π)`. Define delta as `normalize(postYaw - preYaw)` and improvement as `abs(preError) - abs(postError)`; negative improvement means heading error increased. Do not subtract rounded log values.
- `watchdog_checkpoint_yaw_rad`, `watchdog_checkpoint_monotonic_s`, the controller's actual measured progress metric `watchdog_progress_rad`, `watchdog_elapsed_s`, `watchdog_required_progress_rad`, and `watchdog_interval_s`. These expose the existing watchdog evaluation rather than introducing a second progress policy.
- `operation_elapsed_s` and stage-specific monotonic start/end/duration fields; `profile_pulse_wait_s=0.200`, `profile_settle_s=0.300`, `profile_wheel_cap_mps=0.10`, `profile_yaw_gain=0.30`, and selected angular tolerance. Failure records retain this profile even after operation cleanup.
- Pose sample-read monotonic times, pose availability/finite status, AR tracking state, perception frame identity and observation age when actually available at that boundary. **Do not invent a pose-source timestamp.** If the pose provider does not expose one, set `pose_source_timestamp=null` and `pose_source_age_status=unknown`. A sample-read time is not the source timestamp or proof of a fresh/changing pose.

All duration fields describe **host timing**, including suspension and transport delay. All yaw/progress measurements describe **AR visual-inertial pose**, not encoders or physical motor duration. A repeated yaw value is evidence of repeated reported yaw, not proof that the chassis did not move. Correlating perception frames with a controller sample must explicitly identify whether the pairing is same-frame, independently sampled, or unknown.

## 7. Person-association diagnostics

The tracker produces a diagnostic evaluation alongside its existing decision. The coordinator logs that evaluation; it must not reimplement candidate gates or infer rejection from a second set of thresholds. This preserves one authoritative association policy.

Emit `follow_person.association` immediately on initial selection, entry into **lost** or **ambiguous**, successful **reacquired** selection, and any other outcome transition. Repeated evaluations with the same outcome are not new transitions. Emit **continued** summaries at most once per second per session during healthy stable tracking. Initial selection and reacquisition selection do not claim biometric identity.

Each association record includes the common envelope plus:

| Fields | Contract |
| --- | --- |
| `association_outcome`, `previous_outcome`, `association_mode` | Initial acquisition, locked continuity, or reacquisition and the evaluated transition. |
| `frame_id`, `observation_monotonic_s`, `observation_age_s`, `tracking_state`, `same_frame` | Actual observation identity/time/age/health and whether detector, depth projection, and rover pose belong to the same snapshot. Unknown provenance is explicit. |
| `projected_person_count`, `eligible_candidate_count`, `matched_candidate_count` | Counts over the candidates actually available to tracker evaluation. Matched means passing the continuity/reacquisition association gate; `matched_candidate_count` is null with reason `not_applicable_initial_selection` during initial selection. Initial eligibility and selected-candidate counts are not mislabeled as established-track matches. |
| `selected_candidate` | Null if none selected; otherwise frame-local candidate ID, confidence, normalized bounding box `(x,y,width,height)`, projected ground-plane position `(x,y)` in the existing `Vec2` convention (world X and world Z respectively), same-frame rover pose, range in metres, and normalized heading error in radians. |
| `candidate_evaluations` | The tracker-provided per-candidate confidence, normalized box, projected position/range/heading when available, eligible/matched results, and stable gate-rejection reasons. Candidate IDs are frame-local, not persistent identity. |
| `gate_metrics`, `gate_thresholds` | Actual evaluated confidence/age, world-distance, IoU/screen-displacement, or reacquisition-distance values and the centralized configuration values used by that evaluation; mark gates not evaluated as such. No duplicated threshold policy. |

Geometry uses the coordinate convention of the existing same-frame projection/rover pose and states that convention in the record. Range and heading are computed from that paired snapshot, not from a later rover pose. Missing geometry is explicit and cannot appear as a zero-distance person. Association diagnostics retain existing candidate order and decision semantics.

The available projected-person list **cannot distinguish raw-detector absence from depth/projection rejection**. This design does not add raw detector or projection-stage count instrumentation. Therefore those counts are absent from the schema and neither diagnostic text nor operator messages may claim “detector saw nobody” or “depth failed” solely because `projected_person_count` is zero. The supported statement is “no projected person candidate available,” with the actual tracker outcome and known health facts.

### Log volume and privacy

Healthy periodic perception/association summaries share a **one-record-per-second per-session budget**; repeated identical lost/ambiguous evaluations do not emit per-frame transition records. Transitions, failure, cancellation, stop responses, and the bounded scan pulse lifecycle are emitted immediately and are not suppressed by that budget. There is no per-frame healthy logging. Existing coalescing remains in place; logging never queues observations for later motion use.

Store only structured timing, status, confidence, geometry, identifiers, and bounded error codes/messages needed for these diagnostics. Do not record images, audio, or full transcripts. Do not include arbitrary request/response bodies. Per-candidate records cover the tracker input for an emitted evaluation, not retained image payloads or a history of all frames.

## 8. Implementation verification plan (future work)

No checks in this section were run for this documentation task. A separately authorized implementation must use red–green slices: first reproduce the missing behavior with a failing focused regression, implement that slice, then rerun the same regression and relevant existing coverage.

1. **Profile isolation:** with the real controller and controllable clock/transport, assert `.followScan` requests 200 ms and 300 ms settle, generic pulsed rotation still requests 80 ms, continuous generic/follow alignment behavior is unchanged, wheel cap/gain remain 0.10/0.30, and the generic minimum floor is still bypassed only for follow scan.
2. **Measured progress failure and stop safety:** exercise low-cap yaw that makes insufficient progress; prove the unchanged 2.5 s/0.05 rad watchdog fails closed and requests confirmed stop. Exercise adequate progress and wraparound without relaxing the threshold. Assert a failed stop latches `stopUnconfirmed` and blocks subsequent motion.
3. **Cancellation at every suspension/stage:** stop during pre-stop, command send, pulse wait, pulse-stop response, settle, independent/final confirmation, and completion handoff. Assert no later nonzero command, no stale success/new-generation mutation, and cancellation is safe only under the existing independent confirmed-stop rules. Include immediate detection-stop and reacquisition deadline interruption.
4. **Precise telemetry:** use deterministic samples/clock to assert six-decimal signed angles, normalized wraparound delta/error, negative improvement, checkpoint/elapsed/profile fields, stage ordering and interrupted ends, real HTTP statuses versus unknowns, host-duration labels, and unknown pose-source timestamps. Assert operation/pulse correlation survives cleanup, and synchronous logging adds no suspension or second motor owner.
5. **Failure mapping and race ordering:** deliver safety stream then result, result then safety stream, generic wrapper after specific stall, cancellation after stall, failed stop after stall, and stale success after failed stop. Assert captured `.followScan` purpose, one retained specific primary reason, deterministic formatter output, and stop-failure priority/latch preservation.
6. **Person outcomes and limits:** assert initial/continued/lost/ambiguous/reacquired event content against tracker evaluations, eligible/matched counts, candidate geometry from the same frame, gate reasons/threshold provenance, and explicit missing fields. Assert no inference about raw detection/depth from an empty projected list. Drive healthy frames faster than 1 Hz and verify the shared summary limit while transitions/failures remain immediate.
7. **Lifecycle regressions:** preserve mandatory pause, requested one-round initial bound including final shortened increment, ten-second reacquisition, 500 ms freshness boundary, two-second outage, one ready signal/fresh baseline, no retry of partial signal, continuous alignment, local Stop without Thinking, and old-generation/operation fences.

After focused slices pass, run the full non-live SDK suite, all app unit tests, and the unsigned generic iOS app build using the repository's established verification commands. Record commands/results as new implementation evidence rather than copying historical passing counts from earlier amendments.

## 9. Physical acceptance requires separate permission

A supervised physical run is a separate authorized task; **do not launch or move the rover now**. After implementation verification and explicit permission, use the voice-only follow flow with an operator able to stop motion and record:

1. Full stationary pause, follow scan using the 200 ms requested profile, immediate cancellation/confirmed stop on eligible person detection, continuous alignment, and the existing ready/departure sequence.
2. Physical observation of rotation alongside correlated pulse/send/stop/settle and AR yaw records. Compare with the supplied failure evidence without claiming encoder measurement or a guaranteed motor-on duration.
3. Operator Stop during scanning and an interrupted pulse, confirmed-stop/latch outcome, no subsequent stale motion, and no Thinking phase.
4. Bounded initial exhaustion and target-loss reacquisition with association transition evidence and unchanged deadlines. Do not deliberately obstruct or restrain powered wheels to manufacture a stall; use deterministic tests for watchdog/failed-stop injection.

Acceptance requires the specified profile, bounds, fencing, confirmation behavior, and complete interpretable diagnostics. If the low-cap scan still has insufficient measured yaw progress, it must stop safely with the precise reason; do not compensate by increasing cap/gain, extending watchdog/deadlines, weakening association gates, or retrying ready motion. Diagnose any remaining failure from the new evidence and seek a separate design decision for further tuning.

## 10. Risks, limitations, and document review

- A 200 ms request can improve breakaway motion or increase overshoot; neither outcome is established before a supervised run.
- Fresh normal AR observations and successful HTTP replies do not guarantee accurate changing yaw, wheel motion, or a physically stopped chassis. The controller retains its existing acknowledgement boundary and AR-based progress measurement.
- Synchronous event capture avoids formatting races and added suspension, but formatting/output still consumes host time. Logging must use the existing lightweight stream, bounded healthy summaries, and immutable snapshots rather than blocking transport work or introducing a new sink architecture.
- Person continuity is not identity recognition. Projected-candidate diagnostics explain tracker decisions but cannot explain unseen upstream detector/projection losses.

**Written-spec self-review completed:** profile scope is purpose-specific; requested/host/physical timing and AR/encoder distinctions are explicit; all fixed safety bounds are retained; detection-stop has no independent motor authority; failure ordering and stop-confirmation precedence are specified; telemetry unknowns, association provenance, privacy, and rate limits are explicit; verification is future work and physical execution requires separate permission. No placeholders or undecided implementation alternatives remain. Status remains **Approved design, pending written-spec review**.
