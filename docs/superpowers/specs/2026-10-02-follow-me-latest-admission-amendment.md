# Follow-Me Latest-Observation Admission Amendment

**Date:** 2026-10-02

**Status:** Narrow user-approved amendment implemented locally; software validation complete, independent review pending.

**Baseline:** `040eb15`. This supplements the acquisition-reliability design and its first-send admission contract. The user approved implementing the reproduced readiness starvation and precise timing/rejection diagnostics. No commit, push, installation, or device execution is authorized by this amendment.

## Evidence and scope

The historical capture `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-040eb15-pause-runtime-retry.log` shows pausing at `2026-10-03T01:04:56Z`, searching/acquisition at `01:05:01Z`, and repeated observation deferrals. At `01:05:03Z` its controller source age is approximately 0.115 s, observation age approximately 0.346 s, and heading approximately 0.0348 rad. At `01:05:29Z` the session fails with “Person lost.” Clipping, depth confidence/projection rejection, and world-distance rejection are separate evidence; their thresholds are outside this change.

On the existing real-controller/coordinator seam, a manual-clock reproduction confirmed zero ready commands/authorizations over three healthy-frame/acknowledgement cycles. The selected test failed on three repetitions against unchanged production code. Its original admission guard required `pendingFrame == nil`, so newer unprocessed observations could repeatedly defeat readiness despite valid geometry. This reproduces the scheduling mechanism, not proof that it was the sole cause of the historical device session; those logs did not expose the exact observation subcondition.

## Synchronous admission snapshot

1. Preserve the generation/operation-scoped pending token and all cancellation, session, ownership, stop-confirmation, and failed-stop fences.
2. At the existing controller-first-send callback, choose the **newest ingested pending batch**, otherwise the latest processed batch. Frames still buffered upstream have not been ingested and are not claimed to be evaluated.
3. Evaluate frame age, normal tracking, finite pose, and depth through the same pure health gates used by the processor. Require finite/nonfuture age **at most 0.500 s inclusive**. Unknown tracking is not normal tracking, including after startup readiness.
4. For a pending batch, use the existing evaluated tracker against the **original locked observation and its position**. Retain confidence 0.50, world distance 0.75 m, IoU 0.10/screen displacement 0.25, and ambiguity semantics. Require the original AR generation and candidate/batch frame pairing. A lost, ambiguous, unhealthy, or incompatible newest batch cannot authorize using an older good observation.
5. Use the exact controller pose sample/read uptime captured **after acknowledgement**. Enriched samples must remain generation-compatible, normal, finite, nonfuture, and within the existing 500 ms source age. Preserve the explicitly unknown-provenance legacy controller path.
6. Compute heading/range from the selected world observation and that controller pose. Retain **0.05 rad inclusive** heading and **1.37 m inclusive** default clearance (`minimumHoldDistance + 0.12`).
7. On acceptance, atomically publish the accepted batch/frame/person/last position and save its evaluated association. Only then clear the token, consume the once-only attempt, and enter signaling. No await or asynchronous frame reception occurs between admission and send initiation.

`FollowAdmissionSnapshot` is pure: no motor commands, timers, tracker mutation, or asynchronous state handling. The controller retains all path, obstacle, communications, short-move, measured-progress, and stop authority.

## Processor handoff and failed pending data

The normal frame processor retains health/watchdog/state ownership. The accepted pending raw frame may pass the equal-frame deduplication guard **once**, using its saved original association decision. It does not associate again against the just-adopted person. Later distinct frames continue from that accepted person; other duplicate/older frames retain normal rejection. A newer consumed frame supersedes the one-entry saved evaluation. Start, Stop, terminal cleanup, and failed-stop cleanup clear it.

Health is checked again at processing time. An expired accepted batch cannot avoid the outage policy. Consuming the accepted raw frame is not a new post-stop observation and cannot establish a departure baseline. Existing final confirmation, distinct post-stop frame, fixed baseline, and +0.30 m departure rules remain.

Rejected pending data leaves the attempt unconsumed and is handled by the existing processor/loss/outage policies. Generation or candidate-frame mismatch must also fail normal continuity; admission rejection alone cannot make downstream processing certify that incompatible observation.

## Precise diagnostics

- Preserve typed outcomes `observation`, `ownership`, `heading`, and `clearance` for compatibility. Add **`rejection_condition`** to identify the actual gate, rather than using the outcome alone as the diagnosis.
- Emit `follow_ready.admission_rejected` synchronously at the callback, before stop/result delivery can replace observations or fence the operation. Keep `admission_deferred` for the resulting stopped, not-started lifecycle.
- Record pending evaluation status, immutable admission evaluation time/batch/person, exact controller source sample/read time, same-frame versus independent pairing, and actual evaluated tracker candidate reasons/counts. Never fill failed-pending geometry with the older lock.
- Distinguish lost/ambiguous, confidence/world/screen rejection, unknown/limited/unavailable tracking, stale/future/nonfinite timestamp, missing/nonfinite pose, missing depth, generation/pairing mismatch, controller source rejection, heading/range, and individual ownership fences. Health-stage rejection reports tracker evaluation as not evaluated.
- Diagnostics format captured decisions; they do not rerun projection/association or become policy inputs. Existing healthy-summary throttling remains.

## Receipt, ownership, pause, and phase timing

The app records **receipt of finalized recognized text at `submitFinalSpeech`**, before asynchronous routing. This is not acoustic utterance onset or a measurement of recognizer finalization latency. Logs retain classified command kind, not transcripts/audio, and explicitly mark physical utterance time as not measured.

App receipt, router, and coordinator use one shared `SystemFollowClock` in production, or one manual clock in tests. The existing structured emitter records full numeric monotonic timestamps/elapsed seconds, with UTC only for correlation:

- `operator_command.received`, ownership stop requested/confirmed/failed, and follow start requested;
- `follow_session.started`, `follow_pause.started`/`completed`, and `follow_phase` transitions;
- command/session/phase elapsed time, actual pause start/deadline/elapsed, and configured pause/freshness/heading/clearance values.

The full **five-second stationary interval starts after ownership stop confirmation and coordinator startup**, at the existing pause scheduling boundary. Receipt-to-start latency is additional time; it is never subtracted from the pause. Healthy frames cannot shorten the interval. Invalid receipt timing stays diagnostic-only and cannot authorize/inhibit motion. Existing public follow conformers keep their original requirements through an optional internal timed-start companion.

## Validation and remaining risks

See `../plans/2026-10-02-follow-me-latest-admission.md` for actual red/green and final validation evidence. Independent review is pending. Simulator results establish software admission/ownership/association behavior, not physical braking, breakaway, measured chassis movement, or real-scene projection quality. Unsafe newest data still legitimately rejects readiness. No projection, clipping, motor profile, navigation, or deadline threshold was loosened.
