# Follow Search: Turn, Stop, Look

## Requested correction

The user approved addressing aggressive turn pacing, renewed provisional probes, delayed stopping, and perception contention. The latest device capture showed 20.7° and 46.9° sampled yaw changes, roughly 250 ms sender-to-stop-ack envelopes, and a stale-source terminal failure despite later fresh preview frames. Software changes cannot certify physical brake response or reposition the phone.

## Behavior

- Production initial search requests 10° increments rather than 30°, retaining the same total at-most-360° requested budget and inclusive 7° scan tolerance. Recovery's existing fixed absolute stage sequence is segmented at no more than 10°; its original ten-second episode deadline remains.
- After a completed step, remain stopped for at least one second and require a newly processed healthy observation captured after that interval before another turn. A valid person detection can interrupt this observation phase for normal confirmed-stop acquisition. Old frames cannot release it; Stop and perception-outage handling stay live.
- Carry only the conservative measured response-rate floor from a successfully completed and confirmed same-generation search operation into the next compatible step. Do not copy its target, response frames, latency history, or operation identity. Reset at a new follow session; a generation mismatch cannot import a prior floor. The floor only reduces a future request and never lowers the provisional reference.
- Keep fixed wheel magnitude, 80 ms maximum host budget, source freshness, stop confirmation, bounded transport retries, stall watchdog, loss/recovery rules, and once-only readiness unchanged. Smaller requested angles and stationary dwell reduce scan pace, not instantaneous wheel speed guarantees.

## Control responsiveness

Follow and preview inference now await a dedicated serial worker. Vision requests are protected by an inference lock; preview cache reads use a separate short lock and cannot wait for native inference. At most one active and one newest pending async frame are retained; superseded jobs return no result. Cancelled jobs cannot deliver observations to the caller. Lifecycle/reset checks after inference prevent old frame authority.

Native inference remains non-preemptible once started; its completion is discarded if cancelled. No inference job owns motors. Existing 500 ms observation limits apply to complete inference duration and are not extended.

Runtime log formatting/file writing run on a dedicated bounded serial writer (256 queued jobs). Overflow is explicit via `runtime_log_dropped` rather than blocking control. Navigation structured JSON serialization is also deferred; immutable event facts, sequence, and capture clocks are recorded before queueing. Injected diagnostic sinks retain synchronous test semantics. This removes synchronous disk work from stop dispatch; it does not bound network or physical stopping latency.

## Verification scope

Regression-first checks cover off-main inference, smaller production scan requests, stopped fresh-frame admission, inherited response floors, and nonblocking logging. Additional coverage exercises bounded queues, cancellation, old-source rejection, finite scan coverage, and existing stop/latch/deadline rules. Legacy scenario tests can explicitly request their old 30°/zero-dwell configuration when testing unrelated lower-level gates; production-default pacing has separate coverage.

Body verification and bounding-box diagnostics remain in place. The camera still needs shoulders and hips in view; pointing at a nearby tabletop or floor cannot be fixed by software. Physical pulse effectiveness and braking remain unverified without a separately authorized device trial.

No commit, push, installation, launch, or rover movement is requested by this implementation task. Verification results are recorded after execution.

## Review corrections

- Normal mission perception also refreshes asynchronously. Its synchronous detection getter reads only a fresh cache, so it cannot join an active preview inference lock. Mission identity is rechecked after refresh. Local detection-point projection uses the paired detection snapshot; generic image-point projection retains its existing live-AR contract. Both lock responsiveness and detector-independent image-point projection had executed failing regressions before correction.
- The recovery observation gate is recorded on owned, confirmed arrival before checking whether current perception permits progression. A regression advances the clock after arrival authorization so perception ages at completion; the next healthy frame still cannot start an early turn. This regression ran red before moving the gate.
- Observation deadline/frame fields are grouped in one immutable optional `ScanObservationGate`. Follow-up Standards review closed the optional pairing concern with no hard breach. Final scoped Spec review found no remaining high/medium blocker.

## Final verification

| Gate | Result |
| --- | --- |
| Full SDK | 808 passed, 0 failed, 0 skipped |
| App unit tests | 33 passed, 0 failed, 0 skipped |
| Unsigned generic-iOS Debug build | Succeeded |
| Whitespace | Passed |

Final SDK/app tests ran serially with unchanged 60-second per-test allowances and no exclusions. SDK used `scripts/test-swift-sdk.sh`; app used `PhroverOperatorTests` on simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. The already-shutdown simulator was booted for app verification; no physical-device execution occurred.

Evidence bundles in the approved temporary directory: `stop-look-sdk-verified.xcresult`, `stop-look-app-final.xcresult`, and `stop-look-core-verified.xcresult`. The first full SDK run had one old immediate-retry expectation; it was updated to feed healthy captures through the production dwell interval while retaining the exact non-advancing-stage assertion. Downstream legacy matrices explicitly select old scan sizing/pacing where that policy is not under test. Production-default tests cover ten-degree requests, one-second capture gating, default and non-dividing full-round budgets, and seed reset on a new session.

Native inference and log writing had assertion-red/green tests proving execution off the control thread. Queue bounds, supersession, cancellation suppression, and explicit log-overflow reporting are covered. The async public methods are additive; generic synchronous detector APIs remain available but are not used by production follow, preview, or normal mission refresh.

Existing `UIScreen.main`, launch-configuration, and older Sendable test-capture warnings remain. There is no guaranteed physical ten-degree pulse or lower instantaneous wheel speed: the command magnitude remains the empirically usable 0.25 m/s floor, the smaller target/budget and stopped dwell reduce scan pace, and network/coast can still dominate a burst. No timeout, freshness, stop latch, or failed-command gate was relaxed.
