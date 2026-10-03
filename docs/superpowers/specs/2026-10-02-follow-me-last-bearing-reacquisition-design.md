# Follow-Me Last-Bearing Reacquisition Design

**Date:** 2026-10-02

**Status:** User-approved behavior; documentation self-review complete; implementation pending.

**Inspected HEAD:** `a3c0367`.

**Scope of this task:** Documentation only. Future implementation and verification requirements below are not claims of implemented behavior or executed tests. No commit, push, installation, launch, or device motion is part of this task.

## 1. Decision

On first genuine loss or ambiguity of the locked person, immediately inhibit/cancel motion and confirm stop. Preserve the last valid matched world position with its same-observation rover pose, bearing, frame ID, AR generation, and source timestamp. Using a fresh current rover pose, return by the shortest signed orientation change toward that remembered person bearing, then search a finite set of alternating small arcs around one fixed episode center.

The exact stage targets are **center, +15°, −15°, +30°, −30°, +45°, −45°**, each offset measured from that fixed center. Execute one pass only, with relative command segments no larger than **30°**. If the pass finishes without credible recovery, confirm stop and observe stationary for the remainder of the original **10-second loss deadline**. Do not navigate forward toward the remembered point, repeat the sweep, or replace it with a full turn.

This narrowly supersedes positive-increment reacquisition and immediate deadline clearing on a reacquired candidate in the [base design](2026-09-29-follow-me-design.md). The [acquisition-reliability design](2026-10-02-follow-me-acquisition-reliability-design.md), [latest-observation admission amendment](2026-10-02-follow-me-latest-admission-amendment.md), and [stationary-departure amendment](2026-10-01-follow-me-stationary-departure-amendment.md) remain authoritative for projection, health, readiness, baseline, admission, and ordinary following. Initial search retains its existing **at-most-360° requested budget** and shortened final increment.

## 2. Current evidence and limits

Repository terminology was checked against `CONTEXT.md`. Source inspected at `a3c0367`:

| Source | Relevant current behavior |
| --- | --- |
| `swift/Sources/PhroverKit/FollowMe/FollowMeModels.swift` | Observation holds world position and paired pose/frame/timestamp. Defaults: confidence 0.50, freshness 0.500 s, continuity distance 0.75 m, reacquisition distance 1.5 m, loss recovery 10 s, perception outage 2 s, scan increment 30°, alignment tolerance 0.05 rad. |
| `FollowMe/FollowMeCoordinator.swift`, `receive`, `signalReady` | Initial selection and continued matches update `locked`/`lastPosition`; accepted pending admission also publishes the matched observation. Reacquisition updates those values and immediately clears `reacquireDeadline` before alignment/follow resumption. Rejected candidates do not update them. |
| `FollowMeCoordinator.scan`, `loseTarget` | Loss starts a deadline before stop acknowledgement. Reacquisition requests positive `scanIncrement`; completion launches another scan while state remains searching/reacquiring. Its timeout task currently checks only `.reacquiring`. |
| `FollowMeCoordinator.align`, `confirmStop`, `perceptionUnavailable` | Alignment and stop have operation/serial fences; stop cancels movement and advances operation identity. Perception outage stops and has a separate two-second deadline. |
| `FollowMe/FollowTargetTracker.swift` | Continuity enforces world and screen gates; reacquisition requires exactly one eligible candidate within 1.5 m of last position. Continuity has generation/frame pairing checks; reacquisition itself does not currently take an expected generation/frame. |
| `FollowMe/NavigationFollowMeMotion.swift`; `Nav/NavigationController.swift`, `rotateForFollowScan`, `performRotate` | Adapter forwards relative scan requests. Controller confirms stop, reads a pose, then builds `startYaw + suppliedAngle`. Loop samples enriched production pose after acknowledgement and checks source freshness/generation. A relative delta calculated upstream before the controller stop can therefore target the wrong absolute heading. |
| `Config/RoverConfig.swift` | Existing follow scan uses fixed nonzero magnitude 0.25 m/s, requested pulse wait 200 ms, acknowledged stop, settle 300 ms, and 7° tolerance. Continuous alignment remains 0.05 rad. |

Read-only historical capture: `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-a3c0367-reacquisition.log`. It contains appended older sessions; evidence here is limited to the October 3 UTC records cited below (the design's requested filename/date remains October 2). The filename is capture correlation, not embedded binary-build attestation.

- Lines **297973, 298006, 298025** at 03:22:26–27 show continued matched bearing changing from `+0.343312 rad` (about +20°) to `−0.128085 rad` (about −7°), then loss with an actual left-clipped box and no projected person. The reported box moves from the right side to the left; this supports a last-bearing return instead of continuing positive scanning. It does not prove stationary-person identity, exact physical rotation, or a single causal mechanism.
- Lines **298066–298549** show subsequent positive follow-scan targets and opposite-sign overshoot corrections. Lines **297128–297167** separately show about +24° error becoming −10°, followed by correction. Thus “about 25° to −7°” is a coarse description, not an exact measured pair: the verified latest matched-bearing pair is about +20° to −7°. Requested 30° increments are not physical yaw measurements.
- Lines **296083, 296343, 297357, 297863** record pause elapsed values of about **5.082, 5.038, 5.060, 5.055 s**. These establish the full five-second host pause in those sessions; they do not measure acoustic utterance onset or prove physical immobility.
- Lines **296259–296268** record a separate ready-signal insufficient-progress failure and subsequent stop confirmation. Last-bearing recovery does not fix, retry, or suppress that failure.

These are verified partial observations, not device acceptance of the proposed policy. Projection clipping/confidence/association gates remain unchanged.

## 3. Reliable memory and immutable episode anchor

Maintain a bounded last-reliable observation record, updated atomically only when the healthy normal processor selects an initial target or accepts a unique **continuity match**, including the accepted latest-pending admission path and its saved association handoff. Store:

- Last valid matched world X/Z position and its paired rover X/Z position/yaw.
- Relative person bearing `normalize(atan2(personZ − roverZ, personX − roverX) − roverYaw)` and absolute view heading `normalize(roverYaw + bearing)`.
- Actual observation frame ID, its AR generation, source monotonic timestamp, and available frame-local raw-person ID. Frame-local IDs are diagnostic correlation, not durable person identity.
- Association source and validity/provenance facts; missing fields remain explicitly unavailable.

Never update reliable memory from a raw detector candidate, rejected/clipped projection, low-confidence observation, world/screen gate rejection, ambiguity, unhealthy/stale frame, or unrelated newest pose. Do not pair remembered geometry with a later pose to manufacture same-frame facts. Current valid matched position/pose are available in production today; a historical heading-only record is a compatibility case, not a reason to discard valid world geometry.

At first loss, freeze an **episode anchor** from that record before any suspension. Keep live/provisional lock bookkeeping separate from the frozen anchor. A unique `reacquired` candidate may provisionally replace `locked` for normal continuity/alignment evaluation, but it cannot overwrite the episode anchor, recenter the scan, or refresh the reliable memory merely by being reacquired. Commit reliable memory again when healthy normal continuity has actually restored the phase described in §5. Rejected data never erases the last valid anchor.

Use historical memory only within the active episode's ten-second bound: it is permitted to exceed ordinary 500 ms observation freshness because it supplies an orientation hint, **never fresh-person authority**. It must have been valid/fresh when accepted, have a finite nonfuture source timestamp, and belong to the same AR generation; there is no renewal of its age on reads or detection chatter. Expire it for recovery motion at the episode deadline. Fresh controller/perception health remains mandatory for every turn.

## 4. Fixed center and finite stopped-pulse search

### Center selection after confirmed stop

On a fresh same-generation current pose after the first confirmed stop, compute:

```text
normalize(a) = a wrapped to [−π, π)
center = normalize(atan2(anchor.personZ − current.roverZ,
                         anchor.personX − current.roverX))
returnDelta = normalize(center − current.yaw)
stageTarget(i) = normalize(center + offsets[i])
offsets = [0°, +15°, −15°, +30°, −30°, +45°, −45°]
```

Use the actual current rover position for the world bearing, not the historical rover position. Freeze `center` once for this episode; later pose updates correct command errors, not the center. At exactly π, the `[-π, π)` convention selects −π deterministically. Positive/negative mean navigation yaw convention; retain existing firmware wheel mapping rather than assigning camera-left/right meanings without evidence.

If world geometry is unavailable or cannot define a finite nonzero direction, use the anchor's valid historical absolute view heading **only if its paired yaw/bearing and same-generation provenance are valid**. If neither source is valid, remain stopped and observe until recovery or deadline; do not invent zero pose/bearing or revert to positive/full-turn search. An AR reset or incompatible generation terminates through existing stop/lifecycle handling; historical heading is never a cross-generation fallback.

### Stage progression

1. First reach center by the shortest signed path from the actual fresh current yaw, segmented as below. A center already within 7° completes without nonzero motion.
2. Visit the remaining offsets in the listed order, once each. Radii increase 15° → 30° → 45°, but **offsets are absolute about center**, not cumulative relative turns. Ideal target-to-target changes after center are +15°, −30°, +45°, −60°, +75°, −90°; the larger changes require segmentation.
3. For each segment, after serialized stop and fresh source validation, recompute `remaining = normalize(stageTarget − actualYaw)`. If within inclusive 7°, complete the stage; otherwise request a signed segment of `min(abs(remaining), 30°)`. Retain the segment's absolute target through its pulsed controller loop. Do not subtract requested angles from remaining error or treat a requested segment as measured arrival.
4. Confirm stop and settle, then evaluate actual pose and fresh perception before the next segment/stage. Advance only on authoritative arrival/within-tolerance evaluation. Existing watchdog/safety failure ends recovery with its specific reason and confirmed-stop precedence; do not retry failed motion as another arc.
5. After −45° completes, confirm stop and remain stationary at that reached heading for remaining time. There is no extra recentering turn, pass restart, or full-turn fallback. Deadline can truncate any stage; completing all stages within ten seconds is not promised.

All return/arc segments use existing **`.followScan`**, **0.25 m/s**, **200 ms requested pulse wait**, **300 ms settle**, **7° angular tolerance**, and **2.5 s / 0.05 rad measured-progress watchdog**. Every pulse retains existing controller validation, interruptible wait, acknowledged stop, settle, and post-pulse evaluation. Opposite-sign correction under that existing pulse loop is permitted; no new continuous return/overshoot loop or tuning change is introduced. Segmentation bounds requested relative targets, not guaranteed physical rotation, braking distance, total traveled yaw, or number of correction pulses. The finite stage list and deadline bound the search; cumulative requested/actual movement must be labeled separately.

### Navigation boundary and compatibility

Carry the fixed absolute stage heading, expected AR generation, episode identity/deadline, and continuation authorization to the navigation boundary. The selected production seam is a narrow **internal absolute-heading follow-scan request** (new proposed API), reusing controller-owned stop/pulse execution. Resolve each ≤30° segment from the actual post-stop pose at that boundary, not from a coordinator delta added to a different later start yaw. Recheck deadline/ownership/health after feedback awaits and before every nonzero send; no logging await intervenes.

If the existing public relative-only conformer contract needs compatibility, use an optional internal companion while preserving legacy requirements. A legacy adapter may convert to a bounded relative request only against a real fresh post-stop pose with verified shared AR generation and a boundary that preserves that start pose or revalidates the absolute target. If it cannot establish those facts, stay stopped/return unavailable; do not certify arbitrary pose-only fakes as production freshness. Tests may inject real synthetic samples with explicit provenance. Existing unknown-provenance diagnostic fields remain unknown. No public controller-wide API redesign or new motor owner is required.

## 5. One loss episode, credible recovery, and deadline ownership

Create a unique episode ID and `deadline = firstLossMonotonicTime + 10 s` synchronously at first loss, **before awaiting stop**. Stop latency, return, arc pulses, settle, detection handling, alignment, and recovery observation all consume that budget. A timer remains authoritative across `.reacquiring` and recovery `.aligning`; at `now >= deadline`, fence/cancel motion and perform terminal person-lost cleanup regardless of timer/frame scheduling order. Physical acknowledgement can complete later; the budget never licenses another send after expiry.

Repeated lost/ambiguous evaluations, a provisional reacquired candidate, stale-frame recovery, return attempts, and phase chatter do not reset the deadline, episode center, anchor, or stage cursor. If detection interrupts a segment, retain the current unfinished stage; renewed loss within that episode recomputes it from fresh actual yaw rather than restarting center or another pass. Once the pass is exhausted, renewed loss remains stationary. A confirmed stop before center initialization permits initialization once, not repeated recentering.

**Exact episode-clear boundary:** recovery requires confirmed scan stop and a **new, distinct, healthy, fresh normal-continuity matched frame after that stop**, not the provisional reacquired frame or a consumed pre-stop admission frame. Before departure, retain recovery alignment and its existing confirmed final stop, new post-stop matched frame, and inclusive **0.05 rad** heading gate. Clear the episode only when that normal matched evaluation actually establishes/resumes **`waitingForClearance`**, **`waitingForMovement`**, **`following`**, or **`holdingDistance`**, with all existing phase gates satisfied. Merely entering alignment or launching the ready signal does not clear it.

- Too-close but still matched can establish stopped `waitingForClearance` after alignment validation; it is not target loss.
- An unused ready attempt may proceed under existing admission rules. If recovery goes straight through readiness, retain the episode until its successful final confirmed stop and new matched baseline frame establish `waitingForMovement`. The ten-second recovery bound still applies during this incomplete recovery.
- If a post-signal departure baseline already exists, preserve it; matched recovery may resume `waitingForMovement` without replacing the fixed baseline. If success preceded baseline, establish it only under existing new post-stop frame rules.
- After actual departure, the new post-scan-stop continuity frame may resume ordinary following/holding under existing gates; no extra readiness move is introduced.

This selects phase-based healthy restoration rather than introducing an unapproved two-frame-count threshold. Clear deadline/timer and commit reliable memory atomically only at that boundary, with no await after validation; then a subsequent genuine loss is a new episode. A brief reacquired → aligning → lost sequence remains the old episode. A genuinely restored matched normal phase followed by new loss is intentionally a new episode.

Reacquisition remains spatial: require exactly one freshly eligible candidate within **1.5 m** of the frozen last reliable position, with same AR generation and candidate/batch frame pairing validated before calling/accepting the existing tracker result. Do not call initial-selection logic or choose a newly central person. Provisional lock then uses unchanged **0.75 m** continuity, confidence **0.50**, IoU **0.10** / screen displacement **0.25** gates. This does not recognize biometric identity.

## 6. Safety, lifecycle, and readiness invariants

- Loss/ambiguity synchronously inhibits scan continuation and cancels pursuit, alignment, or readiness as applicable; confirmed stop precedes recovery motion. A cancelled task/result alone is not proof of stopped motors. Reacquisition commands are in-place rotation only; historical position is not a forward goal.
- Detection synchronously fences/cancels the active return/arc and drains serialized stop before recovery alignment. Revalidate newest ingested health/association after awaits, preserving latest-pending coalescing and accepted-snapshot handoff semantics.
- Stale/missing/unhealthy perception inhibits motion immediately and preserves the existing **two-second continuous-outage** recovery/failure policy. Never turn using historical memory alone while perception/pose is stale. The outage deadline and episode deadline run concurrently; neither restarts or suspends the other. Fresh production source age is **0…0.500 s inclusive**, finite/nonfuture, normal tracking, finite pose, same generation.
- Stop, cancellation, background/leave-Talk, interruption/reset, safety failure, and ownership replacement invalidate episode/operation work before awaits. Old scan completion, timeout, stop success, processor defer, or alignment callback cannot advance a newer episode or clear its task. Use episode identity in addition to existing session/operation/alignment serial fences.
- Preserve single motor ownership, stop serialization, sticky failed-stop inhibition, existing obstacle/communications/guard checks, typed failure reduction, and failed-stop priority. Never overwrite a failed-stop latch with late success or person-lost UI.
- Preserve full startup five-second pause, initial search, continuous live-person alignment at **0.05 rad**, range/hold/goal limits, no reverse, and local Stop behavior.
- Preserve the once-only requested **10 cm** ready signal. Attempt-consumed and signal-succeeded flags/baseline survive recovery. Partial, uncertain, cancelled, or progress-failed ready motion cannot be retried; existing specific failure/restart guidance remains authoritative. Episode clearing cannot reset those flags. Ready-signal progress failures are separate from bearing recovery.

## 7. Diagnostics

Extend the existing immutable structured diagnostic stream, retaining shared healthy-summary throttling, immediate transitions/failures, bounded payloads, and existing controller/transport correlation. Record:

- Episode ID, first-loss time, elapsed time, fixed deadline/remaining budget, entry/retained/cleared/expired reason, recovery phase, stop outcome, and cursor retention on chatter.
- Frozen memory source (`initial`, `continued`, or accepted pending continuity), observation/frame-local IDs, AR generation/timestamp, age, paired pose, last world point, paired relative bearing/view heading, validity, and explicit unavailable reason.
- Center source (`world_from_post_stop_pose`, `historical_paired_view_heading`, or unavailable), center heading, initial fresh yaw, initial shortest signed return delta, center-selection sample and source timestamp/generation.
- Stage name, offset/index, segment index, absolute stage/segment target, recomputed signed planned delta, actual pre/post yaw and signed change/error, completion/skipped/exhausted reason, requested movement versus measured AR movement. Never call summed requested segments measured coverage.
- Actual controller source IDs, AR timestamps, read uptime/age, health/generation rejection, and same-frame versus independent/unknown pairing; pulse/send/stop/settle host durations and watchdog evidence remain separate measurements.
- Upstream projection/low-confidence/clipping rejection and tracker loss/ambiguity/gate reasons; typed stall/progress, cancellation/fence, deadline, generation/reset, no-valid-center, and stop-failure reasons without claiming one physical root cause.

No images, depth arrays, audio/transcripts, biometric identifiers, or fabricated source timestamps/pose facts. Logging formats captured decisions and adds no motion-authorizing await.

## 8. Future verification requirements — not executed

Use public coordinator behavior with manual clocks/perception/motion doubles, a public pure heading/stage planner seam, and the real navigation controller/adapter for boundary regressions. Verify observable safety behavior, not only a private helper mirroring implementation.

1. **Pure planner:** cardinal/oblique world bearings from actual current position, ±π wrap, shortest signed return and exact π convention; valid heading fallback only when world direction unavailable. Exact fixed offsets/radius progression, ≤30° segmented targets, 7° inclusive completion, finite exhausted-pass outcome. Demonstrate +30°/−30° are center offsets, not cumulative turns; report no physical total-rotation guarantee.
2. **Reliable memory:** last selected/continued match and accepted pending continuity update paired memory; reacquired-only, low confidence, clipped/rejected projection, world jump, ambiguity, stale/future/unhealthy frame cannot overwrite the frozen anchor or reset it. Same-generation/frame pairing mandatory; reset terminates, with no historical-heading fallback across generations.
3. **Real navigation boundary:** suspend initial stop and feedback, change actual pose before resumption, then prove absolute target/≤30° delta uses the new actual sample. Ensure controller receives the fixed stage heading, not old delta plus new yaw. Freeze stale pose despite reads, inject incompatible generation, and reject; legacy bounded conversion must establish its real pose boundary or emit no turn.
4. **Finite sequence/deadline:** stop latency counts; center return and segmented offsets share exactly the first ten-second deadline. Exhausted pass observes stationary. No additional pass/full turn/forward remembered goal. Deadline interrupts return, settle, arc, recovery alignment, and incomplete ready recovery; a frame at expiry cannot rescue it. Existing watchdog failure remains terminal, not a retry stage.
5. **Detection/chatter:** detection fences immediately and confirms stop before provisional recovery. New distinct post-stop continuity match is required; recovery alignment retains deadline. Reacquired → aligning → lost resumes saved cursor/anchor/center/deadline. Exhausted cursor stays stationary. Actual healthy gated normal-phase restoration clears once; subsequent genuine loss creates a new episode without a new frame-count parameter.
6. **Lifecycle races:** Stop during send/stop/settle/feedback, ambiguity during recovery, stale perception and two-second outage, AR reset, safety failure, and failed stop produce no later motion. Deliver late old task/timeout/alignment/stop success across operation, episode, and generation changes: no cursor advancement, memory reset, arc restart, latch clearing, or newer-task deletion.
7. **Readiness/normal behavior:** unused attempt may signal once; consumed partial/failed signal never retries; successful signal/baseline survive loss. Baseline needs existing final confirmation/new matched frame; existing baseline is not rebased. Preserve full pause, initial 360° budget, .25/200/300/7° follow pulses, 0.05 rad live alignment, and separate ready progress failure handling.
8. **Diagnostics:** frozen/source/center/stage/deadline facts match actual decisions, source timestamps are genuine, unknown legacy facts stay unknown, planned/AR-measured/host durations are distinguished, rejection/stall/stop priority remains specific, and summary rate stays bounded.

Later separately authorized supervised device acceptance must establish pulse effectiveness, observed braking/overshoot, stable projection, and recovery performance. This document does not assert those outcomes or authorize changing speed, pulse duration, tolerances, association gates, or deadlines.

## 9. Self-review and remaining risks

Self-review checked current source against prior specifications and the approved exact sequence; matched versus provisional memory, coordinate/wrap conventions, post-stop absolute targeting, finite progression, recovery-phase deadline retention, source/generation reality, suspension/callback fences, outage concurrency, and once-only readiness. No unresolved design alternatives or placeholders remain.

Residual risks are explicit: coherent incorrect world depth may still pass existing gates; spatial continuity is not identity proof; open-loop physical movement can exceed requested angles; host stop latency and AR pose latency limit accuracy; large returns may consume the whole deadline; segmentation/settle may prevent visiting every offset. These are acceptance limitations, not permission to relax safety or restart the episode budget. Phase-based clearing distinguishes genuinely restored control from alignment chatter but intentionally permits a new episode after a genuinely resumed matched normal phase.

**Documentation verification:** parent `docs/superpowers/specs/` was inspected before dedicated patch creation. Only this specification was authored. Existing `.serena/project.yml`, `.opencode/`, `AGENTS.md`, other documents, and `.superpowers` workflow assets are preserved. Documentation review/whitespace inspection is distinct from implementation, tests, or device verification.
