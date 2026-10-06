# Follow-Me Adaptive Turn Bursts Design

**Date:** 2026-10-05

**Inspected HEAD:** `faaf32b`

**Status:** User approved the behavior with “Ok implement”; the concrete planner/calibration assumptions in §4 are proposed for approval, not additional previously approved guarantees. Implementation pending.

**Task scope:** Documentation only. This document specifies future implementation and verification; no code, tests, commit, push, installation, launch, or device motion is performed by this task.

## 1. Decision and exact supersession

Replace continuous **Follow Me alignment** and the fixed **200 ms follow-scan/recovery wait after acknowledgement** with controller-owned adaptive host turn bursts. Each burst requests at most **80 ms**, counted from entry into the nonzero command sender, including time awaiting its response. Keep the existing **0.25 m/s signed wheel magnitude/breakaway floor**. Stop immediately when the budget expires, the target is crossed, or a valid observation is within tolerance; no minimum motor wait is added. After confirmed stop, initially retain **300 ms settle**, then require genuine distinct, advancing post-stop AR source evidence before another turn or arrival handoff.

Tolerance remains **0.05 rad inclusive for follow alignment** and **7° inclusive for follow scan/recovery**. The measured-progress watchdog remains **2.5 s / 0.05 rad**, and recovery retains the original **10 s** loss deadline. Observation health, association, full startup five-second pause, ready signal, departure baseline, range/hold behavior, and following are unchanged.

This narrowly supersedes the fixed follow-only 200 ms pulse and acknowledgement-relative timing in the [longer-pulse design](2026-10-01-follow-me-longer-pulse-diagnostics-design.md), and the fixed-pulse/continuous-follow-alignment statements in the [last-bearing design](2026-10-02-follow-me-last-bearing-reacquisition-design.md). Its newer fixed 0.25 magnitude at this HEAD takes precedence over historical 0.10 proportional tuning. Retain those documents' diagnostic, failure, ownership, and last-bearing requirements except where explicitly replaced here. Earlier workflow assets and specifications remain intact.

Generic scan retains its **80 ms existing generic pulse policy**, and generic continuous alignment/rotation used by other consumers remains continuous. Shared helpers must select the new policy by captured `.followScan` or `.followAlignment` purpose, not merely because a follow session exists. `.followReady` and `.followGoal` do not inherit turn bursts.

## 2. Evidence at the inspected revision

Terminology follows `CONTEXT.md`. Relevant source:

| Source | Current behavior / implementation seam |
| --- | --- |
| `swift/Sources/PhroverKit/Config/RoverConfig.swift` | Generic scan 0.080 s; follow scan profile 0.200 s, settle 0.300 s, magnitude 0.25, tolerance 7°. |
| `swift/Sources/PhroverKit/Nav/NavigationController.swift` | `rotateForFollowAlignment` selects continuous rotation; ordinary alignment uses legacy pose evidence. `performRotate` sends nonzero wheels, awaits acknowledgement, then waits the full follow profile duration before pulse stop/settle. Recovery absolute stage resolution already occurs at the controller boundary. |
| `swift/Sources/PhroverKit/Nav/NavigationPoseSample.swift` | Enriched source snapshot carries pose, frame/generation, AR uptime timestamp, and tracking quality. `legacy_unknown` accepts pose-only compatibility without proving provenance. |
| `swift/Sources/PhroverKit/Nav/RotationDiagnosticModels.swift` | `FollowScanRotationProfile` is fixed signed magnitude; gain is historical inactive metadata. Task-scoped operation evidence and stop receipts support correlation. |
| `swift/Sources/PhroverKit/FollowMe/FollowMeCoordinator.swift` | `align` drains pending detection after stop, then issues a relative angle; final admission has frame/serial fences. These paths need the stricter source-time fence below. |
| `swift/Sources/PhroverKit/Nav/PathAdmissibilityPolicy.swift`, `FollowMe/FollowMotionFailureResolution.swift` | Public `NavigationFailure` lacks a resolution-specific case; shared reducer retains specific reasons and sticky failed-stop priority. |

Read-only capture: **`/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-faaf32b-fast-turn.log`**. It includes appended older sessions. The evidence here is the session starting **2026-10-05T23:41:43Z**; filename correlation alone is not embedded binary-build attestation.

- Lines **303875–303885** record finalized local Follow command receipt, ownership stop confirmation, session start, and five-second pause start. They do not measure acoustic utterance onset.
- Line **304004** records actual `pause_elapsed_s=5.080835...`, `session_elapsed_s=5.083621...` (about **5.084 s**), and `command_elapsed_s=5.107437...`. The pause was not shortened; these fields are different intervals.
- Line **304026**, at 23:41:49Z, reports continuous mode with about **3°** error and opposite wheel requests of **0.25 m/s**. A request barely outside 0.05 rad still uses breakaway magnitude.
- Lines **304171/304202**, **304258/304289**, and **304348/304380** show scan errors changing approximately **+30° → −13°**, **+30° → −12°**, and **+30° → −11°**, with opposite-sign correction commands. Lines **304409/304439** show subsequent **+15° → −16°** correction. Rounded tick values are evidence of reported AR error/command reversal, not precision physical yaw or a measured physical peak rate.

This motivates shorter latency-accounted requests and measured adaptation. It does not establish a certified rate, coast bound, encoder accuracy, or guaranteed small-angle resolution. Ready-signal failures at its separate 0.05 m/s speed remain a separate issue; this design neither changes that speed nor retries a consumed attempt.

## 3. Controller lifecycle, timing, and physical limits

One controller-owned operation executes:

```text
reserve/fence → serialized confirmed stop → settle + fresh source gate
→ resolve fixed target → plan burst → validate synchronously → send entry
→ await send / budget or source stop trigger → serialized stop/drain
→ confirmed acknowledgement → settle + advancing source gate
→ update response evidence → arrive / next burst / stopped failure
```

1. After initial confirmed stop, wait until `ackUptime + 0.300 s`, with normal interruptibility, and obtain a qualifying post-stop sample (§5). Initial target resolution uses this actual pose, after any feedback awaits. Freeze the operation's absolute target once. Alignment resolves its relative request once against this validated boundary pose; never add the same delta anew on each burst. Existing association is revalidated upstream after stop before supplying alignment authority.
2. Before each nonzero send, revalidate ownership, task cancellation, failed-stop latch, newest health, source age/generation, safety/communications guard, recovery authorization/deadline, target, and planner output. Capture all decisions synchronously. No logger await, feedback await, or arbitrary actor hop may sit between the final validation and sender entry without revalidation.
3. **`sendEntryUptime` is captured immediately before invoking the serialized nonzero sender**, not at planner creation, HTTP acknowledgement, UTC receipt time, or diagnostic formatting. `burstDeadline = sendEntryUptime + requestedBudget`. Sender queue/transport/retry delay after entry consumes the same budget. Instrument actual transport entry/response separately when available.
4. While send is suspended, a controller-owned interruptible budget/source monitor may synchronously mark a stop obligation. It must not own motors or issue an unordered emergency command. If the sender is still pending, stop follows the existing serialized drain; it cannot overtake a pending TCP/HTTP send. Cancellation of a request alone is not proof it cannot reach the rover. No nonzero resend or additional retry may be admitted after expiry; already pending work is drained under the existing stop rules.
5. On send return, check expiry/fence **before any motor wait**, and evaluate the newest valid source without an extra feedback await. If expired, issue stop with **zero additional requested wait**. Otherwise remaining budget is `max(0, burstDeadline - nowUptime)`; interrupt it on expiry, crossing, tolerance, detection, cancellation, or loss of authority/health. Wake on advancing source events and the deadline, rather than only the 100 ms command cadence. Do not resend nonzero wheels during a burst.
6. Crossing uses the original burst error sign and continuous source-yaw unwrapping: directed travel reaches/passes the directed target distance. Do not treat the ±π normalized-error seam as a crossing. Within tolerance or crossing requires valid fresh same-generation source; repeated cached samples cannot create progress. The trigger ends the burst, **not the operation as arrived**.
7. Serialize stop and require authoritative acknowledgement, preserving independent noncancelled stop cleanup when a task is cancelled. Capture stop acknowledgement return uptime synchronously. Failed/unconfirmed stop blocks all future motion and overrides arrival/resolution/person-loss reporting.
8. Wait 300 ms after this acknowledgement, then evaluate qualifying fresh actual pose. If within tolerance, arrive; otherwise update evidence and plan again. Final wrapper/detection stops that occur after a burst invalidate earlier handoff evidence: use the newest relevant confirmation and its source fence before motion resumption/admission.

“Immediate stop” means no deliberate additional motor wait and earliest stop admission permitted by the existing single-owner serialization. **80 ms is a host-request budget, not a hard bound on physical motor activation, yaw, or acknowledged stopping.** A 100 ms send response can already consume an 80 ms budget, and pending transport plus stopping/coast can move the chassis beyond the target. No firmware timed-wheel command, parallel stop socket, or separate emergency motor owner is introduced. Do not promise physical 80 ms control or universal 3° accuracy.

The existing sender can retry HTTP requests. Supply a narrow internal follow-burst authorization/deadline check at **each nonzero transport attempt and after retry backoff**, not only outside the outer send call. A timer flag without this attempt-level gate is insufficient to prevent a late retry. Preserve generic sender behavior and stop-command retry/confirmation semantics. Await pending attempts under existing bounded transport timeout/drain behavior; expiry does not invent an acknowledgement or bypass ordering. The budget/source monitor captures its operation identity and cannot mark a newer operation's stop obligation.

Use a shared monotonic **system-uptime clock domain** for burst deadlines, source ages, stop fences, response timing, and recovery authorization. Production AR timestamps must be proven compatible with that domain; injected clocks/samples share an explicit domain. Transport UTC remains correlation only. Preserve the existing watchdog's wall-clock duration semantics and thresholds; do not reset/pause its checkpoint on burst stops, settle, or stopped-frame waits. Existing safety/outage/episode/watchdog checks remain active during those waits. Including waits may cause a stopped operation to fail for insufficient progress; this is deliberate unchanged watchdog behavior, not grounds to extend it.

## 4. Pure planner and operation-local response calibration

### Proposed concrete assumptions requiring approval

The approved maximum is **80 ms**. The earlier “20–80 ms” proposal does **not** establish a minimum: select **no hard 20 ms floor**. Positive sub-20 ms requests are permitted; a zero result never authorizes a nonzero send. Use **120°/s (`2π/3 rad/s`) only as a provisional initial reference**. Unknown latency/coast is explicitly unknown; zero below is an arithmetic omission, never a claimed measured zero. Calibration is operation-local, never copied across operations, generations, surfaces, or sessions as certified response.

The pure planner takes finite target/current yaw, purpose tolerance, profile, previous burst/evidence, and authority state; it returns `arrived`, `burst(direction, budget, explanation)`, `resolutionFailure`, or `unavailable`. It owns no clock, sleep, source acquisition, transport, logging, or motor state. Invalid inputs do not become zero error. Integration owns stop confirmation even when the planner returns failure.

Let all angles be radians, durations seconds:

```text
e = wrap(targetYaw - actualYaw)             // [-π, π), exact π selects -π
T = purpose tolerance                      // 0.05 rad or 7π/180
E = max(0, abs(e) - T)                      // excess to enter unchanged tolerance
R0 = 2π/3                                  // provisional reference, not certified
R = max(R0, operation observed rates)       // never decreases within operation
A = maxObservedSendDuration + maxObservedStopDuration
C = maxObservedPostAckYawTravel             // only when a valid bracket exists

candidate = E/R - A - C/R
B = min(0.080, max(0, candidate))
```

First evaluate inclusive tolerance; if `abs(e) <= T`, return arrival for the integration's stopped/fresh validation. With **no completed response evidence**, omit unknown `A` and `C` from the calculation and request `min(0.080, E/R0)`. This is an explicitly provisional first probe, including for small corrections; do not reject every initial turn based on invented latency/coast. Once latency is measured it is retained even if yaw rate or coast is still unavailable. Independently measured initial stop durations can be logged, but the first probe uses completed nonzero-burst response evidence for this formula.

After a completed, healthy, unambiguous burst bracket, update:

- Pre-send and settled post-stop samples have distinct advancing IDs/timestamps, same generation, finite yaw, normal tracking, source age within 0…0.500 s at collection, and no intervening owner/target replacement or other movement. Source samples arrive in increasing timestamp order. Samples may age in retained evidence; they had to be valid at collection. Never calibrate from cancelled, failed, unhealthy, ambiguously attributed, or cross-generation work.
- Unwrap consecutive yaw samples using shortest signed differences; sum absolute increments as sampled travel and signed increments as directed travel. Wrap-crossing is supported; sampling cannot certify missed full turns. If a sample interval cannot disambiguate traversal, reject the calibration bracket rather than invent direction/rate. This is reported AR travel, not physical traveled yaw.
- `D = abs(unwrapped postYaw - preYaw)` is net bracket response. Source rate candidate is `D / (postSourceTimestamp - preSourceTimestamp)` for strictly positive time. Also take the maximum finite `abs(deltaYaw)/deltaSourceTime` of valid consecutive distinct samples in the bracket. These are effective observed AR rates, **not physical peak-speed bounds**.
- Budget-response candidate is `D / previousRequestedBudget`, for positive budget. It deliberately folds transport/settle response into a conservative equivalent response-per-request rate. Retain `R = max(previousR, R0, source-rate candidates, budget-response candidate)`. Low/zero response never lowers `R` or lengthens the maximum burst to overcome a stall.
- Capture send duration from send entry to its response return and stop duration from stop obligation/admission (including required drain) to confirmed return. Retain operation maxima separately. `A` is their sum. Because budget-response rate already includes some latency, subtracting `A` can double-count it: this is an explicit conservative planning choice, not a fitted physical model or statistical confidence interval.
- For `C`, use absolute sampled yaw travel from the first valid source sample strictly after stop acknowledgement to the settled evaluation sample, provided both exist and advance. Retain the operation maximum. Name it **observed post-ack travel**, not total coast: acknowledgement-to-first-frame movement and later unsampled motion are unknown. A single post-stop sample does not establish zero coast. Omit unavailable `C` arithmetically and keep `coastConfidence=unknown/partial` in evidence. No numeric unmeasured coast bound is invented.

If a burst crossed the target and settled **outside** tolerance, explicitly shrink the next request as well as updating `R/A/C`:

```text
shrinkCeiling = previousBudget * min(1, previousExcess / D)
nextBudget = min(B, shrinkCeiling)
```

For a genuine directed overshoot outside tolerance, `D > previousExcess`, so this ceiling is strictly smaller than the previous request. Store its provenance and apply to the next correction. If evidence cannot establish that inequality, do not claim an adaptive shrink: remain stopped and fail resolution when the overshoot cannot be safely planned from valid evidence. Direction reverses only from the fresh settled error; no reversal while the previous command/stop is pending. Newly larger error may still produce the 80 ms cap unless an overshoot ceiling applies.

### Resolution failure and finite correction behavior

With completed response evidence and error outside tolerance, **`candidate <= 0` is a typed stopped resolution failure**, not arrival, a minimum-duration pulse, or wider tolerance. It means this conservative observed model leaves no positive request budget for the remaining excess; it does not prove a universal physical impossibility. A positive budget that cannot produce a representable positive monotonic deadline also fails resolution without sending. Do not round it up to a transport/timer minimum.

This policy can fail for a roughly 3° error just outside 0.05 rad after one overshooting initial probe. That is an honest outcome of latency-dominated response at 0.25 magnitude, not a promise to always correct 3°. Unknown physical response permits a provisional initial probe; later evidence can reject another correction. No silent tolerance widening, slower unapproved wheel magnitude, indefinite opposite-sign hunt, or automatic calibration retry is allowed.

Maintain the existing error-improvement watchdog/checkpoint across bursts and source waits. Repeated reversals with no qualifying measured improvement fail through existing `.stalled` / `no_yaw_progress` semantics at the existing bound; shrinking bursts do not reset that timer. If adaptation drives the computed budget to zero, resolution failure ends earlier. Arrival remains based on actual stopped fresh error. Small positive budgets making insufficient progress remain subject to the unchanged watchdog, not longer pulses. Operation replacement cannot renew correction calibration to evade a terminal failure.

Example planner arithmetic (synthetic, **not device calibration**): alignment at 3° leaves `E≈0.002360 rad`; initial reference requests about **1.13 ms**, not 20 ms. With measured `R=R0`, `A=0.020 s`, and unknown `C`, the later candidate is negative, so the controller remains stopped and reports resolution failure. A 30° scan error with 7° tolerance initially requests the **80 ms cap**. Increasing observed response or allowances reduces subsequent candidates.

## 5. Fresh post-stop source and coordinator admission

For **every production follow turn**, including ordinary alignment outside recovery, require enriched `NavigationPoseSample` provenance: real frame ID/generation, finite AR source timestamp, finite pose, normal tracking, and finite/nonfuture age **0…0.500 s inclusive**. Pose-only `legacy_unknown` remains unknown in legacy diagnostics; do not alter generic compatibility globally or manufacture freshness from the sample-read time. A legacy follow adapter without these facts returns unavailable/failure while stopped. Tests supply explicit synthetic provenance.

At each acknowledged stop return, synchronously capture:

- Stop identity, operation/session/recovery fences, acknowledgement return uptime, and expected AR generation.
- Highest already ingested source frame sequence and source timestamp, including cached/pending frames even if not yet processed by detection.

A qualifying sample must be same-generation, healthy/fresh at evaluation, **distinct and advancing beyond that stop fence and the last consumed sample**, with **source timestamp strictly `> ackReturnUptime`**. Equality cannot prove “after”; a distinct frame with the same timestamp is insufficient. Read uptime after acknowledgement, or a frame merely delivered after acknowledgement but captured before it, is insufficient. Settle finishes no earlier than `ackReturnUptime + 0.300`; select/revalidate the sample at/after that completion. It may have been captured during settle if still fresh then. This does not certify zero physical coast.

If no qualifying sample exists, remain stopped and await advancing source events under existing watchdog, perception-outage, cancellation, and recovery-deadline handling. Re-reading a cached sample cannot advance evidence or authorize another burst. A fresh but repeated frame is not itself an unhealthy-source failure; it simply cannot pass the new advancement gate. No added timeout constant or watchdog reset is introduced. Evaluate deadlines while waiting, not only on a later frame or before a send. Missing/stale/unhealthy source invokes existing health/failure policy.

Controller arrival requires a post-stop sample satisfying the gate and unchanged tolerance. Coordinator admission after final alignment/detection stop additionally requires a **new post-stop healthy normal-continuity matched person frame**, with the paired pose, same generation, strict source-time/advancement fence, and existing association/range gates. A controller pose frame is not matched-person authority.

Drain newest pending detection through normal processing after confirmation, but reject it for motion admission if its capture timestamp/frame does not clear the stop fence. Preserve accepted-snapshot handoff and coalescing; never relabel a pending pre-stop candidate as a fresh post-stop match. Detection synchronously fences active scanning before an await, then drains serialized confirmed stop before alignment. Old post-stop samples, late burst completions, and old alignment callbacks cannot clear a newer stop fence or delete a newer task.

## 6. Targets, profiles, and implementation boundaries

Retain the shared last-bearing resolver: remembered reliable point, frozen episode anchor/center, exact finite stages **center, +15°, −15°, +30°, −30°, +45°, −45°**, and **≤30° relative target segments**. Resolve each segment once against actual validated post-stop pose at the controller boundary; freeze its absolute heading during all corrective bursts. Recompute error from actual yaw, not accumulated requests. Burst adaptation must not rebase center, recalculate a new relative target from every start yaw, advance an unfinished stage, restart the pass, or renew the ten-second deadline. Requested initial coverage remains at most 360° with the shortened last increment.

Introduce a narrow internal follow-turn profile/planner seam shared by scan and alignment, with explicit fields such as `maximumHostBurstBudget=0.080`, `initialReferenceRate=2π/3`, `settleWait=0.300`, `fixedWheelMagnitude=0.25`, selected tolerance, and command/budget laws. Purpose selects tolerance and diagnostics. Supersede `pulseWait=0.200` as a **follow execution** field: it must not remain active, be reported as the new wait, or be copied into the new profile. Historical logs retain their historical schema/values. Generic scan configuration stays separate. Historical `yawGain` may be retained as inactive metadata only, never described as controlling this fixed magnitude.

`NavigationController` remains the sole motor owner. The pure planner/calibration reducer accepts immutable value evidence; source/event waiting, sender-entry timing, serialization, and stop receipts stay inside the existing controller/transport boundary. The coordinator retains association, phase, pending-admission, and episode authority. Extend follow stop inhibition to alignment as required by the shared executor while preserving captured-purpose routing and unrelated motor consumers.

### Typed failure and compatibility

Select proposed **`NavigationFailure.rotationResolutionInsufficient`** for the new terminal outcome, with stable diagnostic `rotation_resolution_insufficient` and captured purpose/profile/model evidence. Update all exhaustive mappings when implemented, including controller message, shared follow reason/message/priority, `NavigationSilentSearchMotion` reduction, and app `SilentSearchViewModel` display; search the whole workspace for further switches. A generic fallback may describe insufficient rotation resolution but cannot relabel it as person loss, stall, or command failure.

The enum is public and currently non-frozen; an additive case still affects downstream exhaustive source switches. Document that compatibility impact when implementing/releasing, keep existing method/protocol requirements and cases intact, and avoid a broader public API redesign. This specification does not require replacing existing public contracts or changing generic behavior.

Follow operator text uses captured purpose (search rotation or person alignment): “Turn stopped: observed response is too coarse for the remaining angle. Stop confirmed. Restart following to try again.” While confirmation is pending, replace the confirmation clause with “Confirming motor stop…”. Publish confirmed wording only from authoritative stop evidence. A failed stop retains **“Motor stop could not be confirmed. Motion is blocked.”** at highest priority. Stream/result/confirmation deliveries deduplicate by existing generation/operation key; generic wrappers, cancellation, and stale success cannot downgrade the specific reason or sticky stop latch. No automatic retry is implied by restart guidance.

## 7. Preserved bounds and lifecycle

- Full five-second startup pause and existing startup readiness window; shortened turning must not be presented as a pause fix.
- 0.25 signed wheel magnitude/floor, existing wheel/yaw convention; inclusive 0.05 rad alignment and 7° scan gates.
- 2.5 s / 0.05 rad progress watchdog, wall-clock checkpoint semantics including waits; no silent extension, reset, or relaxed threshold.
- First-loss ten-second recovery deadline consumes send/stop latency, settle, source waits, alignment, and incomplete readiness. Neither provisional reacquisition nor shorter bursts clears/renews it. Retain phase-based credible restoration and finite stage cursor.
- 500 ms perception/source freshness and two-second continuous-outage policy; health must authorize every turn. Stop during outage; never turn solely on historical memory.
- Once-only requested 10 cm ready signal, attempted/succeeded flags, confirmed final stop, new baseline frame, and fixed departure baseline. No retry of partial/failed/uncertain signal; no signal-speed change.
- Ordinary following, hold/clearance/range/goal gates, no reverse, local Stop without Thinking, and existing obstacle/communications/tipping checks.
- Cancellation, Stop, target loss/ambiguity, background/leave-Talk, reset/generation change, safety failure, and ownership replacement synchronously inhibit before awaits, drain pending send, and confirm stop. Check fences after **every suspension**, including initial/final stop, guard reads, send, budget/source wait, settle, and handoff. Stale work cannot send, advance stages, publish arrival, clear a failure, consume readiness, or mutate newer state.

## 8. Diagnostics

Extend the existing immutable structured stream and bounded healthy-summary rate. Capture facts synchronously and emit using lightweight existing logging; no logger await is inserted into send-entry, expiry, crossing, or stop paths. Detailed per-burst records include:

- Session/request/controller-operation IDs, captured purpose/phase/profile, burst index, episode/stage/segment and fixed absolute target.
- Signed pre/post error, inclusive tolerance, excess `E`, direction, actual source yaw/delta/travel, bracket/source identities/generation/timestamps/read uptime/age, validity and rejected-bracket reason.
- 0.25 requested magnitude/breakaway floor, 80 ms maximum, selected budget, reference `R0`, retained `R`, candidates and units/provenance, previous budget, overshoot detection and shrink ceiling, formula result and decision.
- Explicit reference/observed/unknown confidence; latency unknown versus measured maxima; post-ack travel `C` availability and sample endpoints; unsampled coast remains unknown. Do not present effective rate as certified physical peak or observed travel as total coast.
- Planning time, send-entry/deadline, actual transport-entry if exposed, send response/host duration, expiry-obligation time, actual stop admission/drain/response duration and acknowledgement return, remaining budget at response, requested/actual additional wait, stop-trigger reason (expiry/crossing/tolerance/detection/fence/health).
- Settle requested/actual time, highest pre-ack ingested/pending frame fence, accepted/rejected post-stop frame/time, source wait elapsed, watchdog checkpoint/error improvement/elapsed, recovery remaining time, arrival/failure and stop-latch state.
- Separate requested host budget, actual host timing, AR-measured response, and unknown physical motor duration. Logs must reveal when response latency exceeds the budget rather than report “80 ms motor-on”.

Retain six-decimal signed angle display with full numeric calculation precision, source pairing distinctions, transport correlation, specific failure reduction, and existing person-association/projection diagnostics. Legacy unavailable fields stay null with reasons; never forge AR timestamps or healthy frame advancement. Existing healthy perception/association summaries share their current bounded throttle. Burst lifecycle/failure transitions are immediate bounded records, not per-frame healthy logging. No image/depth/audio payload is added.

## 9. Future verification — not executed by this task

Use deterministic clocks, bounded explicit-provenance fake AR samples, suspended transport acknowledgements, the real controller/adapter, and public coordinator behavior. Test observable command/stop/admission outcomes rather than just reproducing helper math.

1. **Budget origin/expiry:** enter send at time zero with an 80 ms budget; release acknowledgement at 100 ms. Assert no added pulse wait, earliest serialized stop after drain, no resend, and logged latency overrun. For acknowledgement at 30 ms, remaining requested wait is at most 50 ms. Planner/feedback/logger delay before send does not start the budget; queue/sender delay after entry does. No extra 20 ms minimum.
2. **Crossing/tolerance:** healthy advancing source crosses either direction or enters inclusive tolerance before deadline; assert immediate stop obligation and no further nonzero command. Delay stop response and prove no reversal/arrival before confirmed stop and settled fresh evaluation. Test crossing during pending send with serialization, ±π seam without false crossing, exact π convention, and wraparound in both directions.
3. **Source advancement:** cached pre-stop frame, pending detection captured before acknowledgement, equal source timestamp at acknowledgement, new ID with repeated timestamp, future/stale/unhealthy source, and incompatible generation cannot authorize another burst or readiness. Distinct advancing post-ack same-generation sample after settle permits evaluation. Frozen-source repeated reads remain stopped; existing watchdog/outage/deadline continues during waiting.
4. **Planner/adaptation:** cap, positive sub-20 ms first probe, initial unknown response without fabricated allowance or blanket rejection, measured maxima never decreasing, partial/unknown coast, invalid bracket exclusion, and smaller next budget after real overshoot. Inject source/effective-rate/host latency evidence and assert zero candidate gives typed failure with no new send. Check synthetic 3° arithmetic and an initial small probe followed by unachievable stopped failure. Zero/low yaw does not relax rate or lengthen bursts and fails unchanged watchdog.
5. **Finite corrections:** persistent opposite-sign overshoot without qualifying error improvement cannot reset watchdog at stop/settle or escape failure by replacing operations. Positive tiny requests remain subject to watchdog; no widened tolerance, minimum request, lower magnitude, or indefinite hunt. Arrival only on genuine stopped post-ack actual error, never on the crossing trigger alone.
6. **Every cancellation/ownership phase:** initial stop/source wait, pending send, budget wait, pulse stop/drain, settle, post-stop source wait, final stop, coordinator pending detection/admission. Inject Stop, loss/ambiguity, reset, stale source, generation/session replacement, and ten-second deadline. Assert no late nonzero command/stale arrival/newer-task deletion. Failed stop is sticky under late success and stream/result orderings; independent authoritative confirmation follows existing rules.
7. **Shared targets/profile isolation:** use changed actual pose after initial stop to resolve one alignment target, then multiple bursts without target rebasing. Last-bearing stages retain frozen center, ≤30° segments, one finite pass, cursor on chatter, and original deadline. Both follow purposes use 80 ms maximum and purpose tolerance; generic scan remains its existing 80 ms policy, generic continuous alignment remains continuous, and ready/following remain unchanged.
8. **Failure compatibility/diagnostics:** new enum case compiles through every exhaustive workspace mapping; captured alignment/search purpose, stable resolution reason, pending/confirmed/failed stop text, deduplication and priority are correct. Verify formula/provenance/confidence/latency fields, actual source fence, logging with no motion-authorizing await, and requested/host/physical distinctions.
9. **Coordinator regressions:** pending/latest association handoff, final post-stop normal match before readiness/departure, once-only signal and fixed baseline, full pause, source outage, initial requested coverage, finite recovery, and unchanged 0.05 m/s ready signal. A turn-resolution failure cannot become “person not found” or restart readiness.

Future implementation should run relevant focused regressions, then repository-required non-live SDK/app checks and unsigned build, recording actual results. Device acceptance is separate future evidence: determine observed response, latency, coast, and small-angle limitations without claiming this document certifies them.

## 10. Documentation self-review and approval boundary

Self-review checked purpose isolation, exact supersession, send-entry timing versus serialized physical limits, no request floor, strict post-ack source time/advancement, pending detection, initial unknown-response behavior, finite conservative math/units, explicit partial coast, overshoot shrink, unchanged watchdog/deadlines, absolute target freezing, enum mapping/compatibility, specific failure precedence, and future-only verification. No implementation placeholders or contradictory physical guarantees are intended.

**Approval assumptions to confirm:** provisional **120°/s** first-reference rate; **no 20 ms minimum**; operation-max effective response and send-plus-stop allowance with partial observed post-ack travel; the explicit overshoot shrink formula; and terminal stopped resolution failure when that conservative model yields no positive budget. These make the approved behavior implementable but do not assert that the chassis can achieve every small angle. The new failure case name is a proposed additive mapping detail.

The documentation parent `docs/superpowers/specs/` was verified before dedicated patch creation. This task authors only this document and preserves prior specifications, `.superpowers` assets, and pre-existing workspace changes. Documentation/whitespace review is not implementation, test execution, or device acceptance.
