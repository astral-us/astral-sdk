# Follow-Me Acquisition Reliability Design

**Date:** 2026-10-02

**Status:** User-approved design; written-spec self-review completed; implementation pending.

**Inspected baseline:** `175285e` — Extend follow scan pulses and add correlated safety diagnostics.

**Task:** Documentation only. This document records future behavior and verification requirements; no implementation, test execution, commit, push, installation, app launch, or device motion was performed.

## 1. Decision and scope

Make acquisition reliable through three coordinated changes:

1. Follow search and reacquisition retain short, stopped-and-settled pulses, but each authorized nonzero pulse requests the existing reliable **0.25 m/s minimum turn magnitude**, replacing the 0.10 m/s cap used in the failed runs and avoiding proportional requests below the configured reliable minimum.
2. Project person feet using a conservative local median of valid same-snapshot depth, reject clipped/unreliable geometry, and expose the entire detector-to-projection-to-association decision chain.
3. A matched person who is too close before the ready signal enters active, stationary **`waitingForClearance`**. Ask them to step back, continue tracking, and authorize the one 10 cm signal only after fresh clearance and all motion gates pass.

This supersedes the low-cap follow-scan command rule and upstream diagnostic limitation in `2026-10-01-follow-me-longer-pulse-diagnostics-design.md`, and the terminal pre-signal close-person behavior in `2026-10-01-follow-me-ready-signal-amendment.md`. Their remaining safety, stop-confirmation, failure-resolution, and diagnostic contracts apply. The base, voice-only, frame-coalescing, and stationary-departure specifications continue to apply. Prior specifications and `.superpowers` assets remain historical records.

Approved scope excludes disabling/extending the progress watchdog, extending acquisition deadlines, loosening the 0.75 m association gate, treating HTTP success as physical motion, or automatically retrying a partial ready signal. The required verification below is future implementation work, not a report of checks run now.

## 2. Inspected evidence and what it establishes

### Current source

| Source | Current behavior relevant to this design |
| --- | --- |
| `swift/Sources/PhroverKit/Config/RoverConfig.swift:25–37` | Documents 0.25 m/s as the minimum reliable in-place turn; generic pulse is 80 ms, settle 300 ms, scan tolerance 7°. Follow profile is currently 200 ms / 300 ms, cap 0.10, gain 0.30. |
| `swift/Sources/PhroverKit/Nav/NavigationController.swift:881–989` | Follow pulse speed is `min(cap, abs(error) * gain)`, bypassing the generic minimum. `DriveProgressWatchdog(timeout: 2.5, minimumProgress: 0.05)` observes absolute heading error. The loop reads pose before awaiting the acknowledgement getter. |
| `swift/Sources/PhroverKit/FollowMe/ARFollowMePerceptionSource.swift:60–77` | Filters person detections, samples box `(midX, minY)` as feet, and drops failed projections. Batch exposes only projected people, not raw detection/projection counts or rejection reasons. |
| `swift/Sources/PhroverKit/Perception/ARSessionManager.swift:21–45, 133–139, 171–189, 290–344` | Snapshot includes ID, AR source timestamp, depth, intrinsics, transform, pose, and tracking quality. It has **no confidence map**. Ingestion selects `smoothedSceneDepth ?? sceneDepth`. Person depth uses one Float32 pixel with clamped indices; finite depth greater than 0.05 m is accepted. |
| `swift/Sources/PhroverKit/Nav/NavigationController.swift:173–213`; `Nav/RotationDiagnosticModels.swift:189–244` | Production pose closure is `{ ar.pose }`; injected closure also returns only `Pose2D?`. Rotation diagnostics currently emit null source timestamp and unknown source age. There is no existing pose-provider protocol carrying provenance. |
| `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift:506–553, 682–715` | Maintains matched person through alignment/readiness; close person before signal currently fails the session. Attempt is reserved before launching ready motion. Baseline is established only after successful motion, final confirmation, and a new post-stop matched frame. |
| `swift/Sources/PhroverKit/FollowMe/FollowMeModels.swift:31–52` | Association world-distance limit 0.75 m; hold minimum 1.25 m; alignment tolerance 0.05 rad; freshness 0.5 s; pause 5 s; reacquisition 10 s; outage recovery 2 s. |
| `examples/PhroverOperator/PhroverOperator/App/ConversationViewModel.swift:36–53` | Stop Following uses active follow state. Status switch has no clearance-wait state today. |

Repository terminology was checked against `CONTEXT.md`. Recent history is `175285e`, `c04fbcc` (longer-pulse design), `259d442` (slow search/ready signal), and `832e9de` (stationary departure).

### Recent device logs, read-only

Primary recent source:
`/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-175285e-usb-runtime.log`.
Use its October 2 session records below, not older appended sessions. Its filename associates the capture with the revision; this is not an embedded binary-build attestation.

| UTC / log lines | Observed facts | Interpretation and limit |
| --- | --- | --- |
| 20:34:27–29 / 279948–279987 | High-confidence initial/continued association, ranges about 0.93–0.96 m, normal tracking; terminal insufficient-clearance message with frame age 0.327 s. | Person was matched and perception healthy. Current pre-signal range policy ends a session that should instead wait stopped. It does not prove the physical person distance. |
| 20:35:24 / 283126–283130 | Frame `1:5340` range 0.964 m; frame `1:5346` range 2.168 m; world displacement 1.212814 m rejected as `world_distance_exceeded` against 0.75 m. Confidence remains about 0.9998; next box is near the right edge (`maxX` about 0.9995, not proof of clipping). | The gate correctly rejected a large projected jump. Single-pixel/background depth and truncation are plausible contributors, not proven causes; physical motion and pose error are not excluded. Do not widen the gate. |
| 20:35:26 / 283175 | Normal tracking, depth present, fresh frame `1:5417`, zero projected people. | Existing logs cannot distinguish no detector result from rejected depth/projection. |
| 20:35:28–29 / 283255–283292 | Follow profile 200 ms / 300 ms, cap 0.10; third pulse acknowledged HTTP 200. Host pulse wait 0.267663 s, stop response 0.119047 s, settle 0.378851 s. Reported yaw changes from −0.6703088 to −0.6703342 rad, error increases by about 0.0000254 rad; watchdog failure with error about 0.523107 rad. | Longer requested wait did not produce adequate measured progress in this run. Timings are host measurements; reported yaw is AR visual-inertial pose. Source frame/timestamp were unknown at this controller boundary, so stale pose versus weak physical motion remains unresolved. |
| 20:35:29–30 / 283295–283311 | Specific `no_yaw_progress` survives stream/result delivery; independent confirmation produces “Stop confirmed.” | Preserve the existing reason reducer and stop-confirmation precedence. A cancelled operation result is not itself proof of stopped motors. |

Earlier corroboration: `phrover-iphone15pro-safety-259d442.log:274002–274025,274178` records 0.10 m/s requests and `no_yaw_progress` at 04:05:58 and 04:06:42 UTC, despite healthy follow frames. Those earlier records do not establish the newer 200 ms profile. The reliable floor is supported by existing configuration/domain calibration, not a claim that these logs prove friction is the sole cause.

## 3. Exact follow-search profile

`RoverConfig` owns the purpose-specific profile. Only captured `.followScan` operations—initial search and reacquisition through `NavigationFollowMeMotion`—select it.

| Parameter | Required value |
| --- | --- |
| Requested pulse wait | **0.200 s**, current follow value retained |
| Settle after acknowledged pulse stop | **0.300 s**, retained |
| Minimum and maximum nonzero wheel magnitude | **0.25 m/s** each; use the existing `minimumRotateWheelSpeed` value |
| Angular completion tolerance | **7° = 0.1221730476 rad**, inclusive |
| Yaw-progress watchdog | **2.5 s / 0.05 rad**, existing evaluation semantics retained |
| Initial requested rotation budget | **At most 2π rad**, existing shortened final increment |
| Reacquisition deadline | **10 s**, original deadline; no reset for pulses or settling |

Normalize `error = targetYaw - pose.yaw` to `[-π, π)`. If `abs(error) <= tolerance`, confirm stop and complete without another nonzero pulse. Otherwise every newly authorized pulse uses `signed = sign(error) * 0.25`, `left = -signed`, `right = signed` in navigation convention. `RoverControl.sendNavigation` retains its existing firmware-side wheel mapping. The 0.30 gain must not lower an authorized pulse below 0.25 near tolerance; if retained as profile metadata, label it inactive for this fixed-magnitude profile. Record floor, cap, and command-law identity explicitly.

Do not repeatedly reduce speed below breakaway in pursuit of the last few degrees. An overshoot outside tolerance can produce an opposite-sign bounded pulse under the same safety/progress checks; no new unlimited oscillation/retry policy is introduced. Failure still stops and reports insufficient measured progress. Generic 80 ms scanning, continuous alignment (0.05 rad tolerance), pursuit, and ready translation retain their own profiles.

Keep the existing controller-owned lifecycle: validate → send → interruptible requested pulse wait → serialized acknowledged stop → interruptible settle → evaluate post-pulse pose/progress. Revalidate ownership, cancellation, freshness, and stop latch after suspension and immediately before a nonzero send. Detection fences scan continuation synchronously and requires confirmed stop before alignment. Coordinator never owns wheel commands or pulse timers.

The requested-angle budget is not encoder-measured physical rotation. Higher command magnitude with a short duty cycle may improve breakaway and reduce average sweep rate relative to continuous motion; it **does not guarantee** slow instantaneous rotation, exact motor-on duration, exact angle, or instantaneous braking. Preserve host timing logs to expose send/stop latency and suspension.

## 4. Controller pose provenance and freshness

### Production seam

Add a synchronous, optional provenance-capable pose-sample seam at the existing controller injection boundary. Its conceptual value contains `pose`, actual `ARFrameID`, AR source monotonic timestamp, snapshot tracking quality, and source identity. These are **new proposed API concepts**, not existing protocol/type names.

Production `NavigationController(ar:control:)` obtains all these fields atomically from one `ar.latestSnapshot` on the existing MainActor boundary. That property already exists; direct snapshot access is feasible without an extra await. Replace separate production pose/metadata reads with this one value. Capture the same immutable value for control and diagnostics. Never pair a pose from one read with an unrelated latest frame merely to fill fields.

Retain the old injected `() -> Pose2D?` path with an optional default-nil enriched sample closure. This additive closure is the selected seam because snapshot access is directly available; no new provider protocol is required. Older providers remain source-compatible and explicitly **unknown-provenance**. They retain existing missing/nonfinite-pose checks and coordinator freshness fences; unknown source age is neither a fresh-pose certificate nor evidence of staleness. Production must wire the enriched seam; legacy support is not permission to omit production age enforcement.

### Safety and diagnostic rules

- For available production provenance, require a finite source timestamp, same current AR generation, normal tracking, finite pose, and **`0 <= sourceAge <= 0.500 s`**. Missing/invalid enriched samples, future timestamps, expired samples, reset generations, or unhealthy tracking inhibit motion and request confirmed stop. Preserve the existing two-second perception-outage recovery policy; it never permits motion on stale pose.
- Obtain acknowledgement feedback first at its existing await, gate cancellation/ownership immediately, then synchronously capture fresh time, pose sample, and applicable safety inputs before authorizing the next command. A pre-await pose cannot authorize post-await motion. This applies to follow scan and ready motion; it adds no await for provenance or logging.
- Record pre/post source frame IDs, source timestamps, source ages, read times, availability reasons, tracking quality, and source generation. Source age uses a verified common monotonic clock with AR timestamps; do not subtract AR uptime from `Date`. Existing transport acknowledgement and watchdog clock semantics remain explicitly labeled and unchanged.
- Log whether controller pose and detector/depth observation are actually same-frame, independently sampled, or unknown. Fresh but independently sampled pose must not be labeled same-frame.
- A repeated source ID reveals reuse; a changing ID with nearly unchanged yaw reveals repeated reported orientation on new samples. Neither alone proves physical wheel motion or chassis stall. Source read time never substitutes for source timestamp.
- Preserve signed six-decimal angle displays, full numeric values, actual watchdog checkpoint/progress metric, pulse timings, operation correlation, and failure deduplication. Watchdog progress is the existing heading-error improvement policy, not a newly inferred accumulated yaw metric.

## 5. Robust person-foot projection

Keep this change follow-specific so other consumers of generic unprojection retain their existing behavior. Introduce a pure/testable projection result carrying accepted geometry or rejection facts; `ARFollowMePerceptionSource.batch` consumes that result before creating tracker observations.

### Same-snapshot depth and confidence

Today `ARFrameSnapshot` carries depth but no confidence. Add optional depth-confidence data with default `nil` for existing snapshot/test initializers. During AR ingestion, retain the selected `ARDepthData` object (`smoothedSceneDepth ?? sceneDepth`) long enough to capture **both its `depthMap` and its `confidenceMap`** into the same snapshot. Do not combine smoothed depth with raw confidence, access `session.currentFrame` after inference, or assert that confidence was historically available.

If confidence is absent, report `confidence_availability=unavailable` and use the conservative valid-depth/dispersion checks below. If a confidence map is present but has incompatible dimensions/layout/format, reject the projection rather than silently ignoring it. Supported depth layout is Float32; confidence is an aligned one-component confidence buffer. Use row stride and read-only buffer access, not assumed contiguous storage.

### Exact conservative sampling policy

1. Require a finite, positive-area normalized Vision box **strictly inside** the image: `minX > 0`, `minY > 0`, `maxX < 1`, `maxY < 1`. Touching/crossing any edge is clipped and rejected; never repair it by clamping. This deliberately sacrifices edge acquisition rather than treating a truncated box as reliable feet.
2. Preserve the existing feet anchor `(box.midX, box.minY)` in upright Vision coordinates (bottom-left, y-up). Preserve inverse `.right` orientation: sensor pixel `((1-y)*imageWidth, (1-x)*imageHeight)`. Map into depth coordinates using actual depth dimensions and floor to the center integer pixel.
3. Require a full **5×5 depth-coordinate window** centered there (offsets −2…2 on each axis) inside the map. Reject a clipped window; no duplicated border samples, smaller substitute window, center clamping, or fallback single pixel. Validate finite positive image sizes, depth dimensions, calibration, and transform before projection.
4. Valid samples are finite depth **greater than 0.05 m** (existing lower bound) and, when confidence exists, **at least `ARConfidenceLevel.medium`**. Reject low/invalid confidence values; detector confidence is a different measurement. Require **at least five valid samples** out of 25.
5. Sort valid samples and compute their true median (middle element for odd count, mean of the middle two for even count). Require median absolute deviation **at most 0.10 m**, and at least **60% of valid samples** (rounded up) within **0.20 m inclusive** of the median. Otherwise reject as inconsistent depth. These dispersion checks detect mixed/unreliable patches; they are not proof that coherent background depth belongs to the person.
6. Unproject the original feet ray using that median axial depth, same-snapshot intrinsics and camera transform. Require finite positive focal lengths, finite calibration/transform, and finite resulting world coordinates. Do not use the closest depth, average all 25 samples, Euclidean range as axial depth, or a later pose.

World geometry remains `Vec2.x = world X`, `Vec2.y = world Z`. Heading is `normalize(atan2(person.y-rover.y, person.x-rover.x) - rover.yaw)`; ground range is Euclidean distance in this plane. Camera looks along −Z. Invalid geometry is absent, never zero range.

The 5×5/minimum-five/dispersion numbers are explicit conservative design selections within the approved local-median scope, **not device-validated tuning**. They require the tests in §9; any later parameter relaxation requires new evidence/design approval. This is spatial sampling within a frame, not temporal smoothing or prediction that could mask real motion or weaken association.

### Association and range semantics

Leave `FollowTargetTracker` authoritative for selection/continuity/reacquisition, including confidence 0.50, **0.75 m world-distance**, box IoU 0.10/screen displacement 0.25, reacquisition distance 1.5 m, and ambiguity handling. No fallback accepts a world jump simply because screen overlap is good. Rejected projections do not enter tracker input; an empty trustworthy projected list may legitimately produce loss, with its upstream reason visible.

A valid matched person's short range is a clearance/hold decision, **not person loss**. Never manufacture loss/reacquisition solely because the person is below the ready margin. Continue updating the locked person on every fresh matched frame as they step back. Gradual movement remains normal association; a jump outside the unchanged gate still follows the existing loss path.

## 6. Stationary clearance wait and exactly-once readiness

Add **`waitingForClearance`** to `FollowMeState` and its active-state classification. `isActive` keeps Stop Following available and mission ownership retained. Display:

> Step back to at least 1.4 m — waiting to signal ready.

The precise gate is **`minimumHoldDistance + 0.12 m`**, default **1.37 m inclusive**. The UI rounds the request upward to 1.4 m; never lower the actual gate to a rounded value. If configuration changes the gate, round the displayed requirement upward to the next tenth of a metre.

### Entry, updates, and exit

1. Search acquisition still immediately cancels/fences scanning, confirms stop, aligns, confirms stop, and requires a new fresh matched post-alignment frame with heading error **at most 0.05 rad**. When clearance alone is insufficient, enter `waitingForClearance` instead of terminal failure. Stop must already be confirmed; a stop failure blocks motion and retains its higher-priority message.
2. Remain stopped while waiting. Continue the normal latest-frame/coalesced perception path, association, source health, depth freshness, UI, and outage watchdogs. Update `locked` and `lastPosition` with each matched observation. Do not navigate toward the person, scan, reverse, establish a departure baseline, or run alignment **while in this state**.
3. While the heading remains adequate, a fresh healthy latest matched observation with range at least the gate makes readiness eligible. Revalidate generation, exclusive ownership, cancellation, latch, frame/source age, same-track geometry, heading, and clearance at the final authorization boundary. A cached range or frame that expired during stop/feedback suspension cannot authorize the signal.
4. If matched heading drifts outside 0.05 rad, leave the waiting state for the existing confirmed-stop-bracketed `aligning` flow. Resume waiting or readiness eligibility only after its fresh post-stop frame. Do not rotate under the clearance-wait label or weaken heading requirements.
5. Genuine loss/ambiguity uses existing stop and bounded **10 s reacquisition**. On successful matched reacquisition, return through alignment and fresh clearance evaluation. Merely waiting for a still-matched person has no new timeout; it does not reset a running reacquisition or two-second outage deadline. Outages keep motion inhibited and use the existing recovery/failure policy.

### Reservation versus an actual attempt

Keep a generation/operation-scoped **pending admission token** to prevent concurrent ready requests. It is distinct from `readySignalAttempted`. Too-close waiting never reserves/consumes the once-only attempt and never publishes a failed session merely for insufficient range.

The controller remains the sole motion authority. At the contextual ready-motion seam, add a synchronous coordinator admission callback (new proposed seam) at the boundary **after controller preflight/feedback awaits and safety checks, immediately before the first nonzero command**, with no suspension between accepted callback and send initiation. The callback checks the latest locked observation/health/heading/clearance and ownership, then atomically marks `readySignalAttempted` and enters `signalingReady`. Pending admission alone cannot set the attempted flag.

If clearance becomes insufficient before this boundary, return an explicit **not-started/deferred** contextual outcome (new, not an existing `NavigationResult` success/failure), release only the pending token, and stay/return stopped in `waitingForClearance`. Heading change returns to alignment; loss/outage follows its existing policy. Deferral cannot masquerade as arrival or retry a command that might have been sent. Other controller preflight failures (unsafe path, obstacle, unavailable pose, communications, failed stop) retain their specific existing fail-closed handling.

Once send is initiated, the attempt is irrevocably consumed even if transport fails, cancellation races, or measured motion is zero. This conservative boundary avoids a second signal after an uncertain send. Do not reset it on loss, reacquisition, clearance recovery, or stale callbacks. Older motion test doubles/providers may use the existing contextual compatibility path, but its adapter must reserve at its actual call authorization boundary and never claim first-wheel telemetry it cannot expose; production uses controller admission.

### Signal and baseline

Keep the existing requested **0.10 m forward signal**, 0.05 m/s cap, no minimum floor, no reverse/turn, arrival at 0.08 m forward progress, measured upper displacement 0.12 m, backward bound −0.02 m, lateral bound 0.02 m, heading drift bound 0.10 rad, 2.5 s / 0.01 m progress watchdog, and five-second signal loop deadline. Preserve nonempty planning, actual swept-segment inflated-costmap checks, finite forward clearance, 0.45 m obstacle guard, and fresh/nonfuture communications feedback before the first and subsequent commands. Clearance waiting does not authorize bypassing controller safety.

After the first command is authorized, person approach below the conservative margin, loss, cancellation, stale perception, or safety failure cancels the signal and confirms stop; it must not become resumable clearance waiting. A partial/uncertain signal requires restart guidance, **never automatic retry**.

On success, await authoritative final confirmed stop. Only a **new fresh healthy same-track frame**, distinct from the frame at confirmation and timestamped at or after final confirmation, establishes the fixed **post-signal** departure-range baseline. A frame from before step-back or before the 10 cm move cannot establish it. Enter `waitingForMovement` only then; departure requires **0.30 m increase** over this fixed baseline. Successful signal/baseline survive loss/reacquisition; success before baseline may establish the baseline after fresh reacquired alignment without repeating the move.

## 7. Full pipeline and wait diagnostics

Extend the existing structured diagnostic stream and immutable envelope; do not create a second motion owner, extra awaits, image queues, or a new logging architecture. Preserve source-specific ordering/sequence, generation/operation correlation, host monotonic times, UTC correlation, explicit nulls and availability reasons, and the existing failure-resolution priority.

For every **emitted** perception/pipeline evaluation, retain counts and per-candidate rejection facts from the actual processing of that same snapshot:

- Inference status (`executed`, `skipped_tracking`, or actual failure), raw detector count, raw canonical-person count, projection attempted/accepted/rejected counts, projected-person count, tracker eligible/matched/selected counts. Skipped inference is **unknown/not evaluated**, not zero detected people.
- Use frame-local IDs stable across raw-person projection and tracker evaluation. Keep rejected raw candidates in the diagnostic evaluation, not in tracker input. Counts reconcile with actual decisions; tracker counts retain initial-selection “not applicable” semantics.
- Each raw person includes detector confidence and original normalized box; clipping flags, feet anchor, image/depth coordinates and dimensions; chosen depth source; confidence-map availability; 25 requested samples, valid/invalid-depth/low-confidence counts; median/MAD/inlier count when computed; projection geometry and paired pose when accepted.
- Stable rejection reasons include `invalid_box`, `clipped_box`, `depth_unavailable`, `invalid_depth_layout`, `invalid_confidence_map`, `clipped_depth_window`, `insufficient_valid_depth`, `inconsistent_depth`, `invalid_calibration`, `nonfinite_projection`, and tracking/inference-not-evaluated reasons. Preserve all applicable facts and the first terminal stage reason. Upstream reasons and tracker gate reasons remain separate.
- Correlate these facts with `follow_person.association` transitions and healthy summaries. An empty projected list can now be explained from measured upstream results; unavailable older-provider diagnostics remain unknown and cannot justify “detector saw nobody.”
- Emit clearance entry/exit, ready admission/deferred/authorized, cancellation, and completion events with exact gate, latest frame ID/age, range, heading, pending/attempted/succeeded flags, stop-confirmation state, and reason. Separate “too close before any send” from “person approached during signal.”

Healthy pipeline/association/wait summaries share the existing **one record per second per session** budget. Outcome/rejection-reason transitions, failures, cancellation, stop responses, and bounded pulse lifecycle emit immediately; repeated identical wait/lost evaluations do not log each frame. Capture full stage facts for the emitted frame, not a history of retained frames. Continue frame coalescing.

Record only bounded structured status, timing, confidence, geometry, and frame-local identifiers. No images, depth arrays, audio, transcripts, biometric identity, arbitrary response bodies, or raw URLs/request payloads are added. Association is spatial continuity, not person identity recognition. Existing historical logs containing transport URLs are evidence, not a template for new fields.

## 8. Preserved safety and lifecycle contracts

- Complete stationary **five-second pause**, followed by existing startup readiness behavior; healthy frames never shorten it.
- Initial **360° requested budget**, existing scan increments/final shortening, immediate detection fencing/confirmed stop, and **10-second reacquisition** semantics.
- Inclusive **500 ms freshness**, invalid/future timestamps rejected, timestamp-based **two-second continuous outage** behavior. Source provenance adds enforcement, not freshness relaxation.
- Single motor owner, serialized stop handling, synchronous local Stop inhibition, no Thinking/brain fallback for local follow/Stop, cancellation at every suspension, generation/operation fences, and sticky failed-stop latch. No successful stale callback clears it.
- Existing stand-off 1.5 m, hold band 1.25–1.75 m, goal-change/rate limits, no reverse, single requested 10 cm readiness move, final acknowledgement, fresh post-stop baseline, and no partial-signal retry.
- Specific typed failure survives generic wrappers; failed stop outranks scan/projection/clearance UI. “Stop confirmed” appears only after authoritative confirmation. No claim of live wheel encoders or new IMU tipping coverage is introduced.

## 9. Future implementation verification

These are required tests/acceptance criteria, **not executed for this documentation task**. Use the existing public coordinator, real navigation controller/adapter, synthetic AR projection helpers, and app view-model seams. Add focused failing behavioral regressions before implementing each slice, then run relevant SDK and app coverage and the established unsigned app build in a separately authorized implementation task.

1. **Navigation pulse law:** real controller requests 200 ms pulse / 300 ms settle and signed 0.25 m/s at large error and just outside ±7°; at ±7° emits no nonzero pulse and confirms stop. Check wraparound, firmware wheel mapping, overshoot correction, fixed-profile metadata, generic 80 ms profile, and unchanged continuous alignment/ready tuning. Insufficient measured progress still fails at the original 2.5 s / 0.05 rad semantics.
2. **Fresh provenance:** frozen old snapshot despite new reads stops at >0.500 s; exactly 0.500 s passes freshness; future/nonfinite timestamps, missing pose, reset generation, unhealthy tracking reject. Changing frame IDs with unchanged yaw still exercise the progress watchdog. Legacy pose-only injection reports unknown age without asserting freshness/staleness. Suspend acknowledgement getter, change pose/frame/clearance, then resume: only post-await samples authorize motion; Stop during suspension produces no later send. Verify no new provenance/logging awaits.
3. **Actual median projection:** synthetic stride-padded Float32/one-component buffers exercise all 25 positions, odd/even medians, invalid/NaN/infinite/≤0.05 m samples, five-valid boundary, four-valid rejection, isolated extreme outliers, mixed depth MAD/inlier rejection and inclusive thresholds. Confidence medium/high accepted, low/invalid rejected, missing map explicitly unavailable, malformed/mismatched map rejected. Test selected depth/confidence from one snapshot, not merely a mocked final projected position.
4. **Geometry/clipping:** exact Vision `.right` inverse, different color/depth dimensions, corner/border full-window rejection without clamps, any clipped/touching box edge, invalid boxes/intrinsics/transforms, and world-X/world-Z projection. Test cardinal/oblique yaw and ±π wrap for heading/range with synthetic transforms; prove axial depth differs from Euclidean range where expected. Stable feet with one bad pixel must remain stable without loosening the 0.75 m gate; a real >0.75 m projected jump still rejects.
5. **Coordinator wait:** fresh matched close person enters active stopped wait, Stop remains available, no scan/navigation/alignment commands while heading adequate, no attempt/baseline/failure solely due to range. Step back through fresh matched frames, including exactly 1.37 m, and authorize once. Old/expired frames cannot release wait. Heading drift exits to alignment with fresh post-stop validation; real loss/ambiguity follows bounded reacquisition, preserving unused admission and consumed attempt distinctions.
6. **Admission races:** defer on close latest person while controller preflight awaits; no first command, no attempt consumed. Two eligible frames cannot launch two pending requests. Stop/new generation/failure during preflight or before send fences authorization. Once send starts, failure/uncertainty consumes the attempt and cannot return to resumable wait. Unsafe path, stale pose, obstacle, stale/future feedback, and failed stop remain specific failures, not clearance deferrals.
7. **Readiness lifecycle:** approach/loss/staleness during signal confirms stop and cannot retry after reacquisition. Stop during final acknowledgement cannot return arrival. No baseline before move or final acknowledgement; require new post-stop matched frame. Success before baseline can reacquire and establish baseline without second move. Fixed baseline and 0.30 m departure, hold/follow behavior remain intact.
8. **Diagnostics:** exercise raw detector absence versus all projection rejects, skipped inference versus zero results, reconciling counts and stable frame-local IDs, confidence/clipping/dispersion reasons, tracker world-distance rejection, same-frame versus independently sampled/unknown controller provenance. Assert host durations versus AR measurements, existing watchdog clock labels, six-decimal signs, failure ordering, stream/result deduplication, bounded logging, and excluded private payloads.
9. **App tests:** add clearance-wait status and upward-rounded threshold label; Stop Following visible/functional throughout wait, admission, signaling, and final confirmation. Local Stop never enters Thinking; stale mission/follow callbacks cannot replace a newer session UI. Existing ready/walk-away labels apply only at their proper phases.

A later separately authorized supervised device acceptance should correlate pulses, actual frame provenance, median/rejection facts, and operator-observed motion; verify step-back → one signal → final stop → fresh baseline, and Stop during acquisition. Physical pulse effectiveness, slow sweep, braking overshoot, confidence availability, and mounted-phone projection remain empirical acceptance items. Do not report simulator assertions as physical calibration or increase deadlines/relax gates if the watchdog still fails.

## 10. Explicit assumptions, limitations, and self-review

- Existing 0.25 m/s reliable-turn configuration is the approved command reference, not a universal physical guarantee across surfaces. Retaining the current 200 ms follow pulse is the selected short-pulse policy; there is no unapproved pulse-duration or deadline experiment in this design.
- Conservative 5×5, five-valid, medium-confidence-when-present, strict clipping, and dispersion checks are selected parameters, not claims about measurements absent from current logs. Coherent wrong-surface depth may still pass; association and safety remain authoritative.
- The production snapshot supplies actual source provenance today; confidence transport and enriched controller sampling are new implementation seams. Legacy providers cannot gain source-age claims from a read timestamp. Clock compatibility must be verified in implementation tests.
- The default 1.37 m gate and upward-rounded 1.4 m request are intentional. Waiting is active/stopped and can persist while the matched person remains close; outage/reacquisition deadlines remain fixed. The readiness attempt is consumed at first-send authorization, not while waiting or merely scheduling preflight.
- Review checked scope, parameter consistency, clipping/angle conventions, source/API reality, suspension races, exactly-once admission, partial-signal failure, final acknowledgement/baseline ordering, diagnostic privacy/rate limits, and future-test labeling. No placeholders or unresolved design alternatives remain. No evidence establishes a single physical root cause; the design addresses the approved reliability gaps without relaxing safety.

**Documentation verification:** parent `docs/superpowers/specs/` was inspected before creation. Only this new specification was authored; existing `.serena/project.yml`, `.opencode/`, `AGENTS.md`, prior specifications, and `.superpowers` assets were preserved. Written-spec review and whitespace validation are documentation checks, not implementation/test/device evidence.
