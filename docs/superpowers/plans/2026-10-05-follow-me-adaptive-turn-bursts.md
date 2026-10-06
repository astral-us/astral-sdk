# Follow-Me Adaptive Turn Bursts — Implementation Plan

**Date:** 2026-10-05

**Inspected HEAD:** `8cbcfe7`

**Approved spec:** [Adaptive turn bursts design](../specs/2026-10-05-follow-me-adaptive-turn-bursts-design.md), 203 lines. The user's explicit implementation confirmation includes the concrete §4 assumptions; the spec's historical `faaf32b` evidence and proposed-approval wording are retained as historical context.

**Status: Tasks 1–6 complete at the software gates**, at HEAD `8cbcfe7` plus the corrected working tree; follow-up independent review with no remaining findings was reported by the user. **Final 2026-10-06 evidence, prefix `at6-final-complete20261006-recovered`: full non-live SDK 756 passed / 0 failed / 0 skipped; all 445 affected methods included and passed exactly once; app 33 passed / 0 failed / 0 skipped; unsigned generic-iOS Debug build succeeded; tracked/untracked source/test/plan whitespace passed.** Current inventories match xcresult exactly, with no missing/unexpected/duplicate selectors. The calibration and admission ordering failures are disposed by their recorded test-only corrections and this fresh full SDK gate. The historical app Busy-preflight failure is disposed after inspecting only the selected simulator, clean boot/readiness and a successful app gate. Earlier failed records remain historical evidence. Physical/device acceptance and the separate readiness-motion issue remain outside software completion. Original plan creation used the manual writing-plans fallback.

## Contract, seams, and sequence

Follow `CONTEXT.md`. Preserve existing specifications and `.superpowers` workflow assets. All paths and future commands are relative to `/Users/hungmai/Sites/Astral/astral-sdk`.

Path shorthand below is exact: **S** = `swift/Sources/PhroverKit`, **T** = `swift/Tests/PhroverKitTests`, **A** = `examples/PhroverOperator/PhroverOperator`, **AT** = `examples/PhroverOperator/PhroverOperatorTests`.

| Inspected seam | Required narrow change |
| --- | --- |
| `S/Nav/NavigationController.swift` | `rotateForFollowAlignment` currently selects continuous rotation/ordinary legacy pose; `performRotate` waits the follow pulse after acknowledgement. Share a follow-only executor, strict source events, and stop receipts. Keep sole motor ownership. |
| `S/Nav/NavigationPoseSample.swift` | `rejection` permits `legacy_unknown`; add a follow-specific strict gate rather than breaking generic compatibility. |
| `S/Perception/ARSessionManager.swift` | `snapshots()` already publishes source snapshots; production controller has `latestSnapshot` and `sourceNow` uptime injection but no source-event wait seam. Subscribe before stop/send fences and retain bounded evidence. |
| `S/RoverSDK/RoverControl.swift` | `sendJSONDiagnostic` retries `session.data(for:)` after backoff. The final controller check cannot fence this internal retry; add an internal attempt-level authorization path. |
| `S/FollowMe/FollowMeCoordinator.swift` | `align`, `confirmStop`, pending detection, alignment/readiness frame fences, and admission must use the newest confirmed stop and strict capture-time evidence. |
| `S/Config/RoverConfig.swift`, `S/Nav/RotationDiagnosticModels.swift`, `S/Nav/FollowScanDiagnosticTrace.swift` | Fixed follow `pulseWait=0.200` becomes an inactive historical field; immutable burst profile/evidence and truthful timing replace its execution/reporting use. |

Implement tasks 1–6 in order. Each is a vertical behavioral slice: add a compiled failing assertion, **RUN RED**, implement the minimum behavior, **RUN identical selector GREEN**, then the listed class exit. Add declaration-only scaffolding when necessary to compile a test; missing symbols, fixture errors, and build failures are not assertion RED. Keep clocks, bounded explicit-provenance fake source events, suspended transport responses, real controller/adapter, and public coordinator behavior in the tests. Record actual assertion, command, result bundle, and counts during implementation; Tasks 1–3 are completed below.

### Fixed decisions

- Captured `.followAlignment` / `.followScan` purpose alone selects bursts: maximum requested **0.080 s**, no 20 ms floor, fixed signed **0.25 m/s**, inclusive tolerances **0.05 rad / 7°**, confirmed-stop settle **0.300 s**. Generic scan keeps its existing 80 ms policy; generic continuous alignment/rotation, `.followReady`, and `.followGoal` retain their behavior.
- `sendEntryUptime` immediately precedes invocation of the serialized nonzero sender. Its queue, transport, and retries consume the budget. At 100 ms response for an 80 ms request, added wait is zero; at 30 ms, remaining wait is at most 50 ms. Expiry marks a stop obligation, drains pending send, then admits serialized stop; no parallel motor owner/command or assumed cancellation acknowledgement.
- Use one proven AR/system-uptime domain for source time, ages, stop fences, burst timing, and recovery authorization; transport UTC is correlation only. Keep the existing Date-based watchdog semantics.
- Every stop captures acknowledgement-return uptime, identity/ownership/generation, and highest ingested/pending frame and timestamp synchronously. After settle, require healthy finite same-generation source, age `0…0.500 s`, advancing beyond both stop fence and last consumed sample, and capture time strictly greater than acknowledgement uptime. Equality/repeated reads cannot authorize motion or arrival.
- Freeze each absolute target once from the validated stopped pose. Recovery retains frozen center, `[0,+15,−15,+30,−30,+45,−45]°`, ≤30° segments, finite cursor/pass, and original first-loss 10 s deadline. Initial requested search coverage stays ≤360° with shortened last increment.
- All waits consume existing 2.5 s / 0.05 rad progress-watchdog time, two-second continuous-outage policy, and recovery deadline. No reset, new timeout constant, tolerance relaxation, or operation replacement to evade terminal correction failure.
- Keep full five-second startup pause, health/association/range/obstacle/comms/tipping checks, local Stop, no reverse, and once-only requested 10 cm readiness with existing 0.05 m/s speed, attempt flags, final stop/new baseline frame, and fixed departure baseline. No physical ready-motion fix is included.

## Six implementation tasks

- [x] **1. Public pure planner, immutable calibration, and typed terminal resolution**
  - **Files — add:** `S/Nav/FollowTurnBurstPlanner.swift`, `T/FollowTurnBurstPlannerTests.swift`. **Modify:** `S/Nav/PathAdmissibilityPolicy.swift`, `S/Nav/NavigationController.swift`, `S/Nav/RotationDiagnosticModels.swift`, `S/Config/RoverConfig.swift`, `S/FollowMe/FollowMotionFailureResolution.swift`, `S/SilentSearch/Device/NavigationSilentSearchMotion.swift`, `A/App/SilentSearchViewModel.swift`, `T/FollowMotionFailureResolutionTests.swift`, `T/NavigationSilentSearchMotionTests.swift`. Document compatibility in `README.md`.
  - **RED:** assert first unknown-response probe at 3° alignment is positive ~1.13 ms, 30° scan caps at 80 ms, inclusive tolerance arrives, and invalid/nonfinite inputs are unavailable rather than zero error. Test ±π/exact π, both directions, measured latency with unknown coast, maxima never falling, overshoot shrink, invalid bracket exclusion, and zero candidate yielding typed failure without a send. Verify failure reduction retains captured purpose/specific reason and failed-stop precedence through stream/result orderings.
  - **RUN:** `sdk_test PhroverKitTests/FollowTurnBurstPlannerTests PhroverKitTests/FollowMotionFailureResolutionTests PhroverKitTests/NavigationSilentSearchMotionTests` (method selector first for each new assertion).
  - **Minimal GREEN:** expose public pure immutable input/decision/calibration values; no clock, sleep, source reads, transport, or logging. `E=max(0,abs(wrap(target-actual))-T)`, `R0=2π/3` is provisional reference only. Initially `B=min(.080,E/R0)` omits unknown allowances. With completed response evidence, `R=max(previousR,R0,valid source/net and consecutive rates,D/previousBudget)`, `A=maxSendDuration+maxStopDuration`, `C=maxObservedPostAckSampledTravel` only with valid advancing endpoints; `B=min(.080,max(0,E/R-A-C/R))`. Preserve independently measured latency even without rate/coast; initial stop alone does not make a completed burst.
  - Accept only healthy, finite, age-valid-at-collection, strictly source-time-ordered, distinct same-generation attributed brackets; reject cancelled/failed/replaced/unhealthy/ambiguous traversal. Unwrap consecutive shortest yaw deltas; retain sampled absolute travel and signed/net response. A single post-stop frame cannot establish zero coast. `D/previousBudget` plus subtraction of `A` intentionally double-counts latency conservatively; neither rate nor post-ack travel is a certified physical bound.
  - Genuine directed overshoot settled outside tolerance applies `previousBudget*min(1,previousExcess/D)` as next ceiling, strictly shrinking when `D>previousExcess`; otherwise stop/fail if valid evidence cannot support safe planning. Zero candidate after response evidence is `.rotationResolutionInsufficient`; a positive budget without a representable future uptime deadline also fails without rounding up. Unknown initial response allows one provisional probe, not automatic calibration retries.
  - Add public non-frozen `NavigationFailure.rotationResolutionInsufficient` and stable `rotation_resolution_insufficient`; update **every exhaustive workspace mapping**, including controller message, follow reason/message/priority, silent-search reduction, and app display. Search the entire workspace for `NavigationFailure` and switches, record any additional exact affected paths before editing. Document additive downstream exhaustive-source-switch impact while keeping public methods/protocol requirements/cases intact. Confirmed text requires authoritative stop receipt; pending text says “Confirming motor stop…”; failed stop remains highest-priority blocked-motion text. Re-run same selectors GREEN.

- [x] **2. Controller strict post-stop source gate and event/clock injection**
  - **Files — add:** `S/Nav/FollowTurnSourceGate.swift`, `T/NavigationFollowTurnBurstTests.swift`. **Modify:** `S/Nav/NavigationController.swift`, `S/Nav/NavigationPoseSample.swift`, `S/Nav/RotationDiagnosticModels.swift`, `S/Perception/ARSessionManager.swift`, `T/ARSessionManagerTests.swift`, `T/NavigationFollowScanDiagnosticsTests.swift`.
  - **RED:** suspend initial stop; ingest cached/pending frames before acknowledgement, then deliver them afterward. Assert no nonzero command until 300 ms settle plus a qualifying advancing post-ack sample. Reject equal acknowledgement timestamp, new ID/repeated timestamp, stale/future/nonfinite/unhealthy source and wrong generation; ordinary non-recovery follow alignment also rejects legacy-only pose. Repeated healthy frame waits while watchdog/outage/deadline continues; genuine fresh advance permits boundary evaluation. Count provider calls to expose fabricated advancement/extra reads.
  - **RUN:** `sdk_test PhroverKitTests/NavigationFollowTurnBurstTests PhroverKitTests/ARSessionManagerTests PhroverKitTests/NavigationFollowScanDiagnosticsTests`.
  - **Minimal GREEN:** inject an internal source-event provider alongside existing `poseSample`/`sourceNow` and interruptible waits; wire production to existing `ARSessionManager.snapshots()`, proving `ARFrame.timestamp` compatibility with system uptime. Subscribe before fencing; synchronously retain the ingested high-water mark and bounded immutable samples. Add strict follow-only validation, stop-fence/last-consumed advancement, and settle selection/revalidation. Generic legacy validation stays compatible.
  - Capture acknowledgement-return uptime and fence synchronously, including frames received while detection is pending. Wake on advancing source events and active deadlines, never cached-read polling or 100 ms command cadence. A repeated healthy frame is waiting, not automatically unhealthy. Use one captured sample for decision/diagnostic/calibration facts, avoiding extra diagnostic provider reads. During waits recheck ownership, cancellation, stop latch, current health, safety/comms, recovery authorization/deadline, and unchanged watchdog. Re-run GREEN; keep new executor disconnected until task 4.

- [x] **3. Follow-only transport-attempt deadline and authorization fence**
  - **Files — add:** `S/Nav/FollowTurnBurstAuthorization.swift`. **Modify:** `S/RoverSDK/RoverControl.swift`, `S/Nav/NavigationController.swift`, `T/RoverControlTests.swift`, `T/NavigationFollowTurnBurstTests.swift`.
  - **RED:** with real sender and fake transport, suspend first response past 80 ms and assert no second nonzero attempt; make the first attempt retryable, expire/cancel/replace during backoff, and assert the retry never enters transport. Cover queue delay before transport, authorization loss before first attempt, stale monitor touching a newer operation, and unchanged generic/stop retries. Expiry must not fabricate stop acknowledgement or allow stop to overtake a pending request.
  - **RUN:** `sdk_test PhroverKitTests/RoverControlTests PhroverKitTests/NavigationFollowTurnBurstTests`.
  - **Minimal GREEN:** add an internal follow-burst sender context/overload carrying immutable operation identity/deadline plus safely synchronized authorization. Preserve public sender compatibility. At **every nonzero transport attempt**, immediately before `session.data(for:)`, check deadline/current fences; check again after retry backoff, including swallowed sleep cancellation. Controller final validation alone or a timer flag alone is insufficient. Denial exits without transport; pending attempts drain under existing bounded timeout/serialization.
  - Keep stop commands outside this nonzero-burst gate and retain stop retry/confirmation behavior. No parallel stop socket or motor-writing monitor. Capture sender entry/response and transport-attempt entry independently, with no authorizing await after the final attempt gate. Re-run identical selectors GREEN.

- [x] **4. Shared controller burst executor for alignment and scan**
  - **Files — modify:** `S/Nav/NavigationController.swift`, `S/Nav/RotationDiagnosticModels.swift`, `S/Config/RoverConfig.swift`, `S/FollowMe/NavigationFollowMeMotion.swift`, `T/NavigationFollowTurnBurstTests.swift`, `T/NavigationFollowScanDiagnosticsTests.swift`, `T/NavigationRotationWatchdogTests.swift`, `T/NavigationSafetyTests.swift`.
  - **RED:** through real controller/adapter, release send at 100 ms for an 80 ms budget: assert zero added motor wait, serialized stop after drain, no resend. At 30 ms assert ≤50 ms remaining; pre-send feedback delay does not consume budget, post-entry queue delay does. Advancing source reaches tolerance/crosses either direction during pending send and during remaining wait: mark stop immediately, never reverse/arrive until confirmation, settle, and fresh evaluation. Test ±π seam without false crossing, wrap both ways, exact π, no 20 ms floor, adaptation to smaller next correction, and typed stopped failure after overshoot.
  - **RUN:** `sdk_test PhroverKitTests/NavigationFollowTurnBurstTests PhroverKitTests/NavigationFollowScanDiagnosticsTests PhroverKitTests/NavigationRotationWatchdogTests PhroverKitTests/NavigationSafetyTests`.
  - **Minimal GREEN:** route captured follow purposes to one executor. Initial confirmed stop → strict settle/source gate → resolve relative alignment/recovery segment once → freeze absolute target → plan → synchronous final validation → capture send-entry uptime/invoke gated sender. Follow magnitude remains fixed signed 0.25; replace active 200 ms execution field with 80 ms maximum profile, retaining historical metadata only as inactive.
  - Run operation-scoped budget/source monitor while send is suspended; it marks stop obligation only. Track original burst sign and continuously unwrapped directed source travel against target distance, not normalized-error sign reversal at ±π. Crossing/tolerance ends the burst, never establishes arrival. On send return check expiry/fence/newest captured valid source before any wait; request only remaining time and interrupt on source/deadline/detection/authority/health. No nonzero resend within a burst.
  - Drain and serialize authoritative stop; capture obligation-to-confirmation duration including drain. Stop failure blocks all future motion and overrides resolution/arrival/person loss. Preserve independent noncancelled cleanup. After every stop use task 2's gate, reduce only valid bracket evidence, and arrive only on actual stopped fresh inclusive error. New wrapper/final stops invalidate earlier arrival evidence.
  - Exercise cancellation/fence at **every suspension**: initial/final stop, guard/feedback read, pending send, remaining wait, stop/drain, settle, source wait; inject Stop, loss/ambiguity, reset/generation/session/owner replacement, background/leave-Talk, safety failure, recovery expiry. Old tasks cannot send, clear newer failure/task, publish arrival, or advance stages. Preserve Date watchdog checkpoint across all burst/source waits; low/zero response never increases rate allowance or lengthens bursts. Re-run GREEN including generic scan/continuous isolation and fixed recovery target/cursor tests.

- [x] **5. Coordinator newest-stop matched-frame handoff and preserved episode bounds**
   - **2026-10-06 completion:** `at5-task5-exit.xcresult`: **365 passed / 0 failed / 0 skipped**, all 365 declared methods across 15 classes executed once, no missing/unexpected/duplicate selector. Includes coordinator 107, admission 42 and all planned Task 5 companion gates. This supersedes the coordinator-only checkpoint and incomplete admission attempts. Exact evidence and intermediate dispositions are recorded at the end. Task 6 is unstarted.
  - **Files — modify:** `S/FollowMe/FollowMeCoordinator.swift`, `S/FollowMe/FollowAdmissionSnapshot.swift`, `S/FollowMe/FollowMeDependencies.swift`, `S/FollowMe/NavigationFollowMeMotion.swift`, `S/Nav/RotationDiagnosticModels.swift`, `T/FollowMeCoordinatorTests.swift`, `T/FollowReadyAdmissionIntegrationTests.swift`, `T/Support/FollowMeTestDoubles.swift`, `T/NavigationFollowReadySignalTests.swift`.
  - **RED:** a delivered-late pre-stop pending detection and controller-only pose arrival cannot authorize alignment/readiness/departure. A final wrapper/detection stop invalidates earlier post-burst evidence; require a new healthy normal-continuity matched frame and paired pose beyond the newest stop frame/time fence. Test equal/repeated timestamp, mismatched generation, saved accepted-snapshot handoff, coalescing, newer task versus late alignment callback, and synchronous detection inhibition before stop await.
  - **RUN:** `sdk_test PhroverKitTests/FollowMeCoordinatorTests PhroverKitTests/FollowReadyAdmissionIntegrationTests PhroverKitTests/NavigationFollowReadySignalTests`.
  - **Minimal GREEN:** pass immutable authoritative stop/source-fence facts through the existing internal contextual companion without new public protocol requirements. Add a compatible injected uptime source for coordinator capture-time comparisons; do not compare AR uptime with its Date-based session clock. Capture highest ingested/pending frame/time at confirmation, drain latest detection normally, and reject old capture evidence for admission without relabeling it. Keep original accepted association decision/paired pose transaction intact.
  - Revalidate association, source, stop identity, ownership, and episode authority after all awaits; controller pose is not person authority. Existing stop inhibitors cover both follow purposes. Keep first-loss 10 s active through scan, stop/drain, settle, source wait, alignment, incomplete readiness/baseline; check deadlines while waiting, not only on later frames. Provisional reacquisition cannot renew it; frozen center/segments/cursor advance only on authoritative arrival.
  - GREEN exits also prove full pause, initial ≤360° requested coverage, 500 ms freshness/two-second outage, unchanged 2.5 s progress watchdog, once-only consumed ready attempt, 0.05 m/s ready request, confirmed final stop/new baseline frame/fixed baseline, normal range/hold/following/no reverse/local Stop. Resolution failure remains specific and terminal; no readiness restart or unrelated tuning. Re-run identical selectors.

- [x] **6. Structured burst telemetry, independent review, and final software gates**
   - [x] Telemetry slice only, with assertion RED → GREEN and complete scoped class verification (see 2026-10-06 evidence below).
   - [x] Independent review findings fixed with recorded RED → GREEN regressions; follow-up review with no remaining findings reported by the user at final-gate entry.
   - [x] Final corrected-tree gates: full SDK 756/756 including affected 445/445; app 33/33 after selected-simulator launch recovery; unsigned Debug generic-iOS build and tracked/untracked whitespace pass. Exact final evidence below; physical acceptance remains separate.
  - **Files — modify:** `S/Nav/FollowScanDiagnosticTrace.swift`, `S/Nav/RotationDiagnosticModels.swift`, `S/Nav/NavigationController.swift`, `S/RoverSDK/RoverControl.swift`, `T/NavigationFollowScanDiagnosticsTests.swift`, `T/NavigationFollowTurnBurstTests.swift`, `T/FollowDiagnosticEventTests.swift`, `T/FollowPipelineDiagnosticsTests.swift`, `T/FollowMotionFailureResolutionTests.swift`. Update this plan with actual future evidence and `README.md` compatibility note.
  - **RED:** assert captured-purpose burst records for both follow purposes include formula/units/provenance, unknown versus measured rate/latency/post-ack travel, overshoot ceiling, rejected bracket reason, strict source fence, and actual latency overrun. Assert pending/confirmed/failed stop text/priority and bounded healthy summaries. Instrument diagnostic sink/provider to prove no logger await or extra source read can affect motion authorization.
  - **RUN:** `sdk_test PhroverKitTests/NavigationFollowScanDiagnosticsTests PhroverKitTests/NavigationFollowTurnBurstTests PhroverKitTests/FollowDiagnosticEventTests PhroverKitTests/FollowPipelineDiagnosticsTests PhroverKitTests/FollowMotionFailureResolutionTests`.
  - **Minimal GREEN:** extend immutable structured stream with operation/session/episode/stage/segment/burst identities, frozen target, source bracket/yaw/travel/error, requested fixed magnitude/budget/reference and retained maxima, confidence and decision. Record planning/send-entry/deadline/transport-entry/response, remaining budget, requested/actual added wait, stop obligation/admission/drain/confirmation, settle/source-wait elapsed, accepted/rejected fences, watchdog/recovery remaining, and stop latch. Keep missing facts null with reasons and six-decimal display/full-precision calculations.
  - Emit captured facts through lightweight existing logging without motion-authorizing awaits; keep existing shared healthy-summary throttle and immediate bounded lifecycle/failure records. Distinguish **requested host budget**, **actual host timing**, **reported AR response**, and **unknown physical activation/coast**. Never label 80 ms motor-on, certify observed rate/total coast, or guarantee 3° accuracy. No image/depth/audio payload.
  - Re-run identical GREEN selectors. Obtain a genuinely **independent implementation review** against spec §§3–9, especially attempt/backoff gates, pending-send source monitor/serialization, strict newest-stop source clock, invalid calibration brackets, failure priority, cancellation fences, and preserved bounds. Record reviewer/disposition; fix findings with meaningful assertion RED → GREEN regressions. This documentation session does not claim that review happened.
  - On the final corrected tree run the affected exit below, full non-live SDK, all app unit tests, and unsigned app build. Record exact commands/results/counts/skips/warnings/bundles and remaining risks; never reuse historical counts or pre-fix final evidence. Future device acceptance is separate and cannot be inferred from simulator success.

## Future command runbook — not executed by this task

Run from repository root. Use Bash for this array helper; verify the evidence parent, select one available iOS 26+ simulator, and reuse its UDID. The script already selects full SDK targets, so narrow RED/GREEN uses direct package `xcodebuild`, not added selectors on the full SDK script.

```bash
ls '/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode'
SIM_UDID="$(scripts/test-swift-sdk.sh --print-udid)"
export SIM_UDID
EVIDENCE='/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode'
TEST_FLAGS=(-parallel-testing-enabled NO -test-timeouts-enabled YES
  -default-test-execution-time-allowance 60
  -maximum-test-execution-time-allowance 60)
sdk_test() {
  local selectors=() selector
  for selector in "$@"; do selectors+=("-only-testing:$selector"); done
  xcodebuild test -quiet -scheme astral-sdk-Package \
    -destination "id=$SIM_UDID" "${TEST_FLAGS[@]}" "${selectors[@]}" \
    -resultBundlePath "$EVIDENCE/adaptive-turn-narrow-$(uuidgen).xcresult"
}
# For each behavior use ClassName/testMethodName, then identical selector GREEN.
```

Affected final exit (21 existing classes, including the added real-controller trace class):

```bash
sdk_test \
  PhroverKitTests/FollowTurnBurstPlannerTests \
   PhroverKitTests/NavigationFollowTurnBurstTests \
   PhroverKitTests/FollowTurnBurstControllerTraceTests \
  PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  PhroverKitTests/NavigationRotationWatchdogTests \
  PhroverKitTests/NavigationSafetyTests \
  PhroverKitTests/RoverControlTests \
  PhroverKitTests/ARSessionManagerTests \
  PhroverKitTests/ARFollowMePerceptionSourceTests \
  PhroverKitTests/FollowReacquisitionPlannerTests \
  PhroverKitTests/FollowReacquisitionDiagnosticsTests \
  PhroverKitTests/FollowMeCoordinatorTests \
  PhroverKitTests/FollowTargetTrackerTests \
  PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  PhroverKitTests/NavigationFollowReadySignalTests \
  PhroverKitTests/FollowMotionFailureResolutionTests \
  PhroverKitTests/NavigationSilentSearchMotionTests \
  PhroverKitTests/FollowDiagnosticEventTests \
  PhroverKitTests/FollowAssociationDiagnosticsTests \
  PhroverKitTests/FollowPipelineDiagnosticsTests \
  PhroverKitTests/OperatorCommandRouterTests
SDK_RESULT="$EVIDENCE/adaptive-turn-sdk-$(uuidgen).xcresult"
APP_RESULT="$EVIDENCE/adaptive-turn-app-$(uuidgen).xcresult"
scripts/test-swift-sdk.sh -quiet "${TEST_FLAGS[@]}" -resultBundlePath "$SDK_RESULT"
xcodebuild test -quiet \
  -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination "id=$SIM_UDID" \
  -only-testing:PhroverOperatorTests "${TEST_FLAGS[@]}" -resultBundlePath "$APP_RESULT"
xcodebuild build -quiet \
  -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcrun xcresulttool get test-results summary --path "$SDK_RESULT"
xcrun xcresulttool get test-results summary --path "$APP_RESULT"
```

## Critical risks / completion record

The highest-risk boundary is an already pending transport request: expiry can prevent later attempts, but cannot overtake or prove cancellation of the in-flight request. Serialized stop latency and physical coast remain outside the 80 ms host request. Conservative equivalent-rate plus latency subtraction can intentionally terminate small corrections; never hide this by a minimum pulse or wider tolerance. AR/uptime-domain proof and highest-ingested pending-frame fences are essential to avoid falsely fresh motion authority.

At plan creation only the approved spec, terminology, relevant code seams, prior command runbook, HEAD/status, and documentation parent were inspected; all six stages were then unimplemented. Future completion of Tasks 2–6 must supply their assertion RED/GREEN, focused/full SDK/app/build results, independent review disposition, and explicit separation from physical/device acceptance.

### Task 1 completion evidence — 2026-10-05

Read the approved 203-line spec, `CONTEXT.md`, TDD skill and its test/mocking references; confirmed HEAD `8cbcfe7`. Used `apply_patch` for all edits. Test seams are the approved public pure planner and existing follow failure / silent-search adapter reducers. Planner tests import `PhroverKit` publicly, without private clock or frame-sequence access. Source times and collection uptime carry an explicit common domain; legacy/unknown provenance is rejected for calibration, not converted into fabricated source evidence.

Workspace-wide `NavigationFailure`, `.stalled`, `headingToleranceExceeded`, and failure-switch searches identified the planned mappings plus the additional exact path **`swift/Sources/PhroverKit/SilentSearch/SilentSearchDependencies.swift`**, recorded before its edit. Its additive typed case preserves the resolution reason through the existing silent-search protocol and app display. Existing methods/protocol requirements/cases remain intact; README documents downstream exhaustive-switch impact for both public non-frozen enums.

The new immutable public profile lives with the planner. No executor wiring, active fixed-pulse/configuration change, source gate, transport-attempt gate, watchdog change, readiness/motor/logging change is included in Task 1. Those integrations remain in their later tasks. Controller modification is solely its exhaustive failure-message mapping. Unknown response allows one issued provisional probe; integration must record issuance and remain stopped on rejected evidence. A shared exact immutable settled endpoint is a boundary of adjacent brackets, not fabricated frame advancement. Supplied unhealthy/invalid evidence rejects all learning; missing endpoints permit independently measured latency and partial post-ack travel without inventing net response/rate. None of these observed values certifies physical rate, full turns, total coast, or motor-on time.

#### Executed RED → GREEN cycles

All commands ran from `/Users/hungmai/Sites/Astral/astral-sdk` on iPhone 17 Pro, iOS Simulator 26.5, UDID `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Evidence parent **`/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`** was verified. Each row used the following exact command template twice, replacing `SELECTOR` and `BUNDLE` with the row values (RED then identical selector GREEN):

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -only-testing:SELECTOR \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BUNDLE
```

Selector prefix is `PhroverKitTests/`; **P** means `FollowTurnBurstPlannerTests`, **F** means `FollowMotionFailureResolutionTests`, **N** means `NavigationSilentSearchMotionTests`. Each valid RED bundle reports **1 executed / 1 failed / 0 passed / 0 skipped**; each corresponding GREEN reports **1 executed / 1 passed / 0 failed / 0 skipped**, verified with `xcresulttool get test-results summary`.

| Selector after prefix | Assertion observed RED | RED → GREEN bundle names |
| --- | --- | --- |
| P/testFirstThreeDegreeProbeUsesWorkedSubMillisecondExcessWithoutFloor | Unknown response was unavailable instead of a positive 3° probe; GREEN literal is 0.0011267585362157 s (about 1.127 ms, not sub-1 ms) | `at1-probe-red.xcresult` → `at1-probe-green.xcresult` |
| P/testCircularErrorUsesInclusivePurposeToleranceAndExactPiNegativeDirection | Inclusive tolerance returned a burst; exact π used positive direction; ±π seam corrections were capped incorrectly | `at1-wrap-red.xcresult` → `at1-wrap-green.xcresult` |
| P/testInvalidAuthorityAndNonfiniteInputsAreUnavailableNotZeroError | Nonfinite inputs / denied authority produced decisions instead of unavailable | `at1-input-red.xcresult` → `at1-input-green.xcresult` |
| P/testCompletedLatencyIsRetainedWithUnknownYawAndCoast | No measured latency or completed response was retained | `at1-latency-red.xcresult` → `at1-latency-green.xcresult` |
| P/testMeasuredLatencyTerminatesSmallCorrectionAndUnrepresentableDeadlineWithoutRetry | Negative candidate, unrepresentable deadline, and lost first-response evidence still produced bursts | `at1-resolution-red.xcresult` → `at1-resolution-green.xcresult` |
| P/testInvalidResponseBracketsNeverLearnOrEraseOperationEvidence | Invalid/cancelled/failed/replaced/unhealthy/stale/nonadvancing/wrong-domain evidence learned calibration | `at1-validity-red-valid.xcresult` → `at1-validity-green.xcresult` |
| P/testWrappedSampledResponseRetainsRateLatencyAndPartialTravelMaxima | Reported wrap-crossing response did not raise rate or retain sampled post-ack travel | `at1-rates-red.xcresult` → `at1-rates-green.xcresult` |
| P/testDirectedOvershootShrinksNextCeilingWithoutMistakingPiSeamForCrossing | Genuine directed overshoot retained no strict shrink ceiling | `at1-overshoot-red.xcresult` → `at1-overshoot-green.xcresult` |
| F/testResolutionFailureRetainsCapturedPurposeReasonAndStopPriorityInBothOrders | Generic reason/message/priority replaced the specific resolution failure | `at1-text-red.xcresult` → `at1-text-green.xcresult` |
| N/testResolutionFailureRemainsSpecificThroughNavigationAndRotation | Adapter relabeled resolution as command-link failure | `at1-mapping-red.xcresult` → `at1-mapping-green.xcresult` |
| P/testReplayedResponseAndFramesCannotCalibrateANewerBurst | Replayed host response / frame IDs / source timestamps learned another response | `at1-replay-red.xcresult` → `at1-replay-green.xcresult` |
| P/testSampledTravelPreservesReversalsAndRejectsNonfiniteRateWithoutFullTurnInference | Signed and absolute sampled travel remained unavailable | `at1-travel-red.xcresult` → `at1-travel-green.xcresult` |
| F/testSpecificDeliverySuppliesCapturedPurposeAfterUnknownGenericWrapper | Generic-first wrapper kept unknown purpose after specific alignment failure | `at1-purpose-red.xcresult` → `at1-purpose-green.xcresult` |
| P/testAdjacentBurstsMayShareTheExactSettledBoundaryWithoutFabricatedAdvancement | Exact shared boundary was rejected despite a genuinely advancing next sample | `at1-boundary-red.xcresult` → `at1-boundary-green.xcresult` |
| P/testFiniteEndpointValuesCannotHideAnOverflowedTargetError | Finite endpoint values with overflowed target error learned calibration | `at1-overflow-red.xcresult` → `at1-overflow-green.xcresult` |
| P/testPartialPostAckBracketMeasuresTravelWithoutInventingNetBurstResponse | Valid partial post-ack evidence discarded independent latency/travel | `at1-partial-red.xcresult` → `at1-partial-green.xcresult` |

**16 compiled behavioral RED → GREEN cycles**. `at1-validity-red.xcresult` was a test-fixture compile error (extraneous `time:` argument label), corrected and rerun before production GREEN; it is **not** counted as RED. The wrap test's independent seam-budget literal was corrected before GREEN; its inclusive-boundary/exact-π RED assertions were genuine behavioral failures. The exact-zero-candidate and stop-drain arithmetic test additionally verifies already implemented terminal/allowance branches in the class exit.

#### Final Task 1 software gates

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowTurnBurstPlannerTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/NavigationSilentSearchMotionTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at1-focused-final.xcresult

xcodebuild test -quiet \
  -project examples/PhroverOperator/PhroverOperator.xcodeproj -scheme PhroverOperator \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverOperatorTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at1-app-final-retry.xcresult

xcrun xcresulttool get test-results summary --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at1-focused-final.xcresult
xcrun xcresulttool get test-results summary --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at1-app-final-retry.xcresult
git diff --check
```

- Final focused SDK: **26 passed / 0 failed / 0 skipped** (planner 14, failure reduction 5, silent-search motion 7).
- Final app unit / exhaustive app compile gate: **33 passed / 0 failed / 0 skipped**. `at1-app-final.xcresult` had a simulator launcher Mach `-308` server-died error while SDK/app gates ran concurrently on the same simulator; the identical app command passed when retried alone in `at1-app-final-retry.xcresult`. This infrastructure failure is not behavioral RED.
- Earlier intermediate class/app runs (`at1-focused.xcresult`, `at1-app.xcresult`) passed, but final evidence above supersedes them. Initial app compile emitted the existing `ConversationView.swift:273` `UIScreen.main` iOS 26 deprecation warning; narrow package invocations emitted the Xcode empty-supported-platforms notice. No remaining test/build blocker.
- Full SDK, unsigned-device build, independent implementation review, and physical/device acceptance remain later-task final gates; no such completion is claimed here. No commits or device operations performed.

Exact Task 1 changed-file list:

1. `swift/Sources/PhroverKit/Nav/FollowTurnBurstPlanner.swift` (new)
2. `swift/Tests/PhroverKitTests/FollowTurnBurstPlannerTests.swift` (new)
3. `swift/Sources/PhroverKit/Nav/PathAdmissibilityPolicy.swift`
4. `swift/Sources/PhroverKit/Nav/NavigationController.swift`
5. `swift/Sources/PhroverKit/FollowMe/FollowMotionFailureResolution.swift`
6. `swift/Sources/PhroverKit/SilentSearch/SilentSearchDependencies.swift`
7. `swift/Sources/PhroverKit/SilentSearch/Device/NavigationSilentSearchMotion.swift`
8. `examples/PhroverOperator/PhroverOperator/App/SilentSearchViewModel.swift`
9. `swift/Tests/PhroverKitTests/FollowMotionFailureResolutionTests.swift`
10. `swift/Tests/PhroverKitTests/NavigationSilentSearchMotionTests.swift`
11. `README.md`
12. `docs/superpowers/plans/2026-10-05-follow-me-adaptive-turn-bursts.md`

Pre-existing `.serena/project.yml`, `.opencode/`, and `AGENTS.md` working-tree changes were preserved. `.superpowers` assets and approved specifications were preserved. Only Task 1's completion checkbox was changed.

### Tasks 2–3 completion evidence — 2026-10-05

Implemented only the source and transport boundary foundations, preserving Task 1's uncommitted changes. Read the approved spec, especially §§3 and 5, repository terminology, and TDD guidance. All edits used `apply_patch`. The agreed seams were the strict source gate, real controller stopped-source/sender boundaries, AR ingress, and real `RoverControl` with a URLProtocol HTTP stub. No Task 4 executor, target freezing/adaptation integration, active pulse-profile replacement, Task 5 coordinator production changes, or Task 6 telemetry/review completion is claimed.

**Task 2:** `NavigationPoseSample.rejection` gains a default-false `requireEnriched` argument. Generic legacy compatibility is retained; ordinary follow alignment now rejects legacy provenance while stopped. The source gate retains bounded actual samples (latest and last consumed) and independent ingestion high-water facts. Stop return captures uptime, UUID, owner/context, generation, highest sequence and timestamp inside the returning stop task, before its waiter resumes. AR ingress retains the timestamp maximum even when the newest/pending snapshot regresses. Production snapshot and lifecycle subscriptions are established before the stop fence; health/generation is also checked synchronously, so an interruption cannot reuse cached normal evidence. Stop/result evidence carries the actual last acknowledged fence even when a newer wrapper stop fails.

The gate requires 300 ms from ACK return, normal finite same-generation source, nonfuture age ≤500 ms, source time strictly greater than ACK and both timestamp fences, and sequence beyond the ingested/consumed fences. A newer stop UUID invalidates an older gate even with the same operation owner. Waiting uses source/lifecycle events and settle, freshness, existing Date-watchdog and original recovery deadlines, without pose polling or a command cadence. Ownership/caller cancellation wakes waits; subscription cleanup is identity-scoped. Existing two-second perception-outage handling remains in the coordinator. The 2.5 s / 0.05 rad checkpoint is passed into the wait rather than reset at settle.

Clock evidence is software-domain evidence: production preserves `ARFrame.timestamp` unchanged, uses `ProcessInfo.systemUptime`, and the production-initializer AR-ingress test uses explicit system-uptime synthetic captures. Stop, source, queue, attempt and response tests share their injected uptime domain; watchdog `Date` precision/policy is unchanged. This is not live AR/device clock attestation or physical acceptance.

**Task 3:** a default-none task-local authorization context gates only nonzero navigation attempts. Its deadline is immutable and starts at controller sender entry; queue/actor/transport time consumes it. The optional `@Sendable` asynchronous authorization callback crosses one actor boundary, followed by synchronous cancellation, uptime/deadline and operation-token checks before HTTP starts. Gates run before every attempt, before retry backoff when denial is already known, and again after backoff. No mutable actor-global last-receipt lookup is used. Attempt entry and sender response are frozen per invocation.

An operation-owned deadline monitor only inhibits its own synchronized token/marks a stop obligation. It does not send motors. Pending requests drain before `stopAndConfirm`, public Cancel, or cancellation cleanup can stop; a second sender cannot replace the pending token/drain. Late real ACK remains acknowledged; expired/fenced/cancelled/invalid-budget denial never invents ACK or stopping. Generic requests and STOP retain three-attempt retry behavior. Zero/nonfinite/over-cap/unrepresentable budgets do not send; a representable 1 ms request is not rounded to a floor. These helpers remain disconnected from the active turn loop until Task 4.

#### Executed assertion RED → GREEN evidence

All runs used repository root, iPhone 17 Pro simulator, iOS 26.5, UDID `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Evidence parent was verified. Each row used this exact command with the row's full selector and bundle name, first RED then identical selector GREEN:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -only-testing:SELECTOR \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BUNDLE.xcresult
```

Selector prefix: `PhroverKitTests/`. **N** = `NavigationFollowTurnBurstTests`, **R** = `RoverControlTests`, **A** = `ARSessionManagerTests`, **D** = `NavigationFollowScanDiagnosticsTests`. Bundle cells omit `.xcresult`. All listed RED bundles were verified as **1 executed / 1 failed / 0 passed / 0 skipped**, and the final GREEN bundles as **1 executed / 1 passed / 0 failed / 0 skipped**, using `xcresulttool get test-results summary`.

| Selector after prefix | Behavioral assertion RED | RED → authoritative GREEN bundles |
| --- | --- | --- |
| N/testConfirmedStopRequiresSettleAndActualAdvancingPostAckSource | Cached/equal/repeated/below-fence source passed; settle and consumption were absent | `at2-fence-red` → `at2-fence-green` |
| N/testPostStopRejectsInvalidSourceWithoutChangingGenericLegacyCompatibility | Wrong generation, future/stale/nonfinite/unhealthy source passed | `at2-valid-red` → `at2-valid-green` |
| N/testOrdinaryFollowAlignmentRejectsLegacyWhileStopped | Legacy ordinary alignment returned arrival | `at2-legacy-red` → `at2-legacy-green` |
| N/testControllerCapturesAckReturnFenceAndAwaitsSourceWithoutProviderPolling | Controller selected cached source/finished early and reread provider | `at2-events-red` → `at2-events-green` |
| N/testSourceWaitGuardAwaitConsumesExistingProgressCheckpoint | Guard await could pause the original watchdog and admit source | `at2-progress-red` → `at2-progress-green-final` |
| A/testIngressHighWaterRetainsPendingTimestampEvenWhenNewestSnapshotRegresses | Pending timestamp maximum was lost | `at2-ingress-red` → `at2-ingress-green` |
| N/testReplacingStoppedSourceWaitWakesOldCallerWithoutDeletingNewFence | Old source wait did not wake on owner replacement | `at2-replace-red` → `at2-replace-green` |
| N/testNewGenerationUsesItsOwnConsumedSequenceWithoutAdmittingOldGeneration | Previous generation's consumed sequence blocked a legitimate new generation | `at2-generation-red-valid` → `at2-generation-green-final` |
| N/testRecoverySourceWaitCannotAdoptGenerationChangedBeforeStop | Stop gate silently adopted a generation outside episode authority | `at2-recoverygen-red` → `at2-recoverygen-green` |
| N/testStopEvidenceCarriesActualLastAcknowledgedFenceThroughFailedWrapperStop | Result omitted actual last acknowledged stop/source context | `at2-receipt-red` → `at2-receipt-green` |
| D/testGenericScanAndAlignmentDoNotConsultFollowSourceClockOrProvider | Generic rotation consulted follow source clock at stop | `at2-generic-red` → `at2-generic-green` |
| N/testNewWrapperStopInvalidatesEarlierFenceEvenWithSameOperationOwner | Earlier same-owner stop admitted a frame below the newest stop fence | `at2-neweststop-red` → `at2-neweststop-green` |
| R/testProductionSourceWaitCannotUseCachedNormalFrameAfterARInterruption | Production initializer admitted cached normal post-ack source after interruption | `at2-lifecycle-red` → `at2-lifecycle-green` |
| R/testFollowBurstFirstTimeoutAt100msCannotRetryAn80msDeadline | Real sender entered all three attempts past deadline | `at3-expiry-red` → `at3-expiry-green` |
| R/testFollowBurstAuthorityLossBeforeFirstAttemptAndDuringBackoff | Lost authority still entered first/later HTTP | `at3-authority-red` → `at3-authority-green` |
| R/testFollowBurstCancellationDuringBackoffCannotBeSwallowedIntoRetry | Cancelled backoff entered another attempt | `at3-cancel-red` → `at3-cancel-green` |
| R/testAttemptRechecksDeadlineAndFenceAfterAuthorizationActorBoundary | Authorization await did not recheck deadline/fence before HTTP | `at3-hop-red` → `at3-hop-green` |
| R/testControllerSenderQueueConsumesWhole80msBudgetBeforeHTTPEntry | Queue delay did not consume budget; HTTP still entered | `at3-queue-red` → `at3-queue-green-final` |
| R/testPendingBurstExpiryOnlyMarksObligationAndStopDrainsActualHTTP | Pending expiry had no scoped obligation and STOP could overtake HTTP | `at3-drain-red` → `at3-drain-green` |
| R/testControllerRejectsInvalidOrUnrepresentableBudgetWithoutRoundingToFloor | Invalid/over-cap budget lacked typed no-send rejection | `at3-budget-red` → `at3-budget-green` |
| R/testPendingBurstCannotBeOverwrittenByNewSenderEntry | Second sender entered HTTP and overwrote active token/drain | `at3-replacement-red` → `at3-replacement-green` |
| R/testControllerRecordsActualTransportEntrySeparatelyFromSenderQueueAndLateAck | Actual attempt-entry evidence was missing | `at3-entry-red` → `at3-entry-green` |
| R/testPublicCancelWaitsForPendingBurstBeforeItsIndependentStop | Public Cancel admitted STOP before pending send drained | `at3-publiccancel-red` → `at3-publiccancel-green` |
| R/testCancellationAtAuthorizationBoundaryIsCancelledRatherThanFenced | Actor-boundary cancellation was mislabeled fenced | `at3-cancelhop-red` → `at3-cancelhop-green` |
| R/testExpiredResponseDrainsWithoutAddingRetryBackoffBeforeStopAdmission | Known expiry added deliberate retry backoff before drain/stop admission | `at3-backoff-red` → `at3-backoff-green` |

**25 compiled behavioral RED → GREEN cycles**, plus existing-behavior/exit coverage for the original watchdog firing during settle, recovery expiry without another frame, caller cancellation during source wait, expiry during backoff, nonfinite budgets and unchanged generic/STOP retries. The early `at2-generation-red`/`at2-generation-green` used a settle literal below the representable ACK-plus-300-ms deadline; excluded from valid generation evidence, corrected and rerun RED before final GREEN. `at23-boundaries` exposed an overly strict test tolerance for existing Date precision (`0.10000002384185791` versus `0.1`); corrected to 1 μs without changing production watchdog semantics. Not behavioral RED.

#### Fixture/regression dispositions and final software gates

Additional exact test-only paths were identified and announced before editing: `T/FollowReadyAdmissionIntegrationTests.swift` and `T/FollowMeCoordinatorTests.swift`. Their real-controller fixtures now supply explicit source provenance. Source timestamps are stored at camera/frame ingestion, never generated by provider reads. One stale-person admission scenario now explicitly ingests a newer independent controller frame: a fresh pose still must not hide stale matched-person authority. Malformed detector timestamps remain malformed; assertions for invalid source, pending admission, cancellation, outage, and stop priority were retained. Existing diagnostics alignment fixtures advance IDs/timestamps on simulated pose updates. The obsolete follow-legacy acceptance assertion now asserts rejection; generic legacy compatibility keeps its existing test.

Intermediate evidence is retained, not presented as final success: `at23-focused-checkpoint` was killed by the 120 s tool timeout and has no complete result bundle. `at23-focused-checkpoint2` exposed an incorrectly placed watchdog-after-await check and expiry-versus-fence classification; corrected and verified by `at23-regressions-green`, final identical single selectors, and final suites. `at23-sdk-final` exceeded 600 s while legacy integration fixtures waited for motion that was now unavailable; no completed SDK count is claimed for it. `at23-integration-fixtures` had 143 passed / 2 failed; fixture capture-time changes were then corrected, with both original assertions passing in `at23-admission-fixtures-green`. `at23-affected-final` recorded intermittent coordinator failure-text and pending-admission ordering failures (296 passed / 2 failed). These were not fixed by changing coordinator production code, skipping tests, or weakening their assertions; do not infer their root cause is resolved merely from later passes. Carry the ordering evidence into Tasks 5–6 review. Earlier passing gates were superseded after the production AR lifecycle regression was discovered and fixed.

Final corrected-tree commands (all from repository root):

```bash
EVIDENCE=/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode
SIM_UDID=EEA52712-371D-4FF6-B8EF-A2C78319D57F
# These flags were spelled out in each actual invocation.
TEST_FLAGS=(-parallel-testing-enabled NO -test-timeouts-enabled YES
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60)
xcodebuild test -quiet -scheme astral-sdk-Package -destination "id=$SIM_UDID" "${TEST_FLAGS[@]}" \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -only-testing:PhroverKitTests/RoverControlTests \
  -only-testing:PhroverKitTests/ARSessionManagerTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationSafetyTests \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -resultBundlePath "$EVIDENCE/at23-affected-final-health.xcresult"
SIM_UDID="$SIM_UDID" scripts/test-swift-sdk.sh -quiet "${TEST_FLAGS[@]}" \
  -resultBundlePath "$EVIDENCE/at23-sdk-final-health.xcresult"
xcodebuild test -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination "id=$SIM_UDID" "${TEST_FLAGS[@]}" \
  -only-testing:PhroverOperatorTests -resultBundlePath "$EVIDENCE/at23-app-final-health.xcresult"
xcodebuild build -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcrun xcresulttool get test-results summary --path "$EVIDENCE/at23-affected-final-health.xcresult"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/at23-sdk-final-health.xcresult"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/at23-app-final-health.xcresult"
git diff --check
```

- **Affected exit: 300 passed / 0 failed / 0 skipped.** Source boundary 13, real RoverControl 27, AR ingress 6, follow diagnostics 71, rotation watchdog 12, safety 26, ready integration 38, coordinator 107.
- **Full non-live SDK: 709 passed / 0 failed / 0 skipped.** Full-suite runs were confined to the final gate stage; the timeout/fixture correction and later genuine lifecycle fix required corrected final reruns.
- **App units: 33 passed / 0 failed / 0 skipped. Unsigned generic-iOS build passed.** No install, device launch, device motion, commit or push.
- Package invocations emitted the existing empty-supported-platforms notice. App emitted the existing `ConversationView.swift:273` `UIScreen.main` iOS 26 deprecation warning. An earlier unsigned build also emitted the existing launch-configuration warning and stale-signing-file cleanup notes. Final summaries were read mechanically with `xcresulttool`; counts are not reused from Task 1.

Task 2–3 changed paths: `S/Nav/FollowTurnSourceGate.swift` (new), `S/Nav/FollowTurnBurstAuthorization.swift` (new), `S/Nav/NavigationController.swift`, `S/Nav/NavigationPoseSample.swift`, `S/Nav/RotationDiagnosticModels.swift`, `S/Perception/ARSessionManager.swift`, `S/RoverSDK/RoverControl.swift`, `T/NavigationFollowTurnBurstTests.swift` (new), `T/RoverControlTests.swift`, `T/ARSessionManagerTests.swift`, `T/NavigationFollowScanDiagnosticsTests.swift`, the two additional fixture paths above, and this plan. Prior Task 1 and unrelated working-tree assets remain present.

**Next: Task 4.** Wire the shared alignment/scan executor to these seams, preserve the original watchdog across all waits, freeze targets, use only remaining budget after response, and integrate source-crossing/adaptation/serialized stop. Final gates have no current build/test blocker; intermediate ordering failures remain an explicit review risk. Independent implementation review, coordinator newest matched-frame handoff, full runtime burst telemetry, live clock/device attestation and physical response acceptance remain later-task work.

### Task 4 partial green checkpoint — 2026-10-05

Used the user's explicit allowance to return a bounded green checkpoint rather than start an unfinished routing/calibration migration. **Task 4 remains unchecked.** Tasks 1–3 and unrelated working-tree changes are preserved. All edits used `apply_patch`; no commits, installations, full-suite reruns, Task 5 coordinator edits or Task 6 work.

Implemented at internal real-controller sender/one-burst/source-ingress seams:

- `FollowTurnBurstObservation` retains distinct advancing same-generation source and original signed target distance. Continuous shortest-delta unwrapping triggers directed crossing or unchanged inclusive tolerance; the ±π representation seam alone is not crossing. A trigger is a stop obligation, never arrival.
- Operation-scoped synchronous ingress observers retain brief actual source triggers before the cache is replaced. Pending-send monitor/observers inhibit only their own token, never write motors; unhealthy pending source inhibits transport attempts. Observer/subscription cleanup uses captured identities.
- `FollowTurnBurstExecutor` sequences actual sender return, interruptible remaining deadline budget, and independent confirmed stop. At a 100 ms response for an 80 ms request there is **no added sleep invocation**; at 30 ms only 50 ms remains. Unknown diagnostic receipts do not discard measured controller sender/response clocks. Remaining wait can end on source before its budget timer returns. The sender's late-started deadline monitor also avoids a zero-duration sleep after expiry.
- The immutable one-burst return includes the actual confirmed stop's uptime/high-water fence; a later wrapper stop cannot mutate it. This is a dependency interface for subsequent integration, not completed coordinator admission. Owner replacement prevents this seam from appending stale stop work; cancellation cleanup remains independent of the caller.

#### Assertion RED → minimal GREEN evidence

Repository-root commands used iPhone 17 Pro / iOS Simulator 26.5, UDID `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. The evidence parent was verified before execution. Each row used this exact command template for RED, then the **identical selector** for GREEN:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests/SELECTOR \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BUNDLE.xcresult
```

| Selector | Observed assertion RED | RED → authoritative GREEN bundle (without `.xcresult`) |
| --- | --- | --- |
| `testAdvancingToleranceSourceWhileSendPendingMarksObligationWithoutConcurrentStop` | Pending advancing in-tolerance source left stop obligation false | `at4-pending-source-red` → `at4-pending-source-green-fixed` |
| `testDirectedCrossingUnwrapsBothWaysWithoutFalsePiSeamTrigger` | Directed outside-tolerance crossing failed to trigger in both wrap directions | `at4-crossing-red` → `at4-crossing-green` |
| `testHundredMillisecondAckForEightyMillisecondBurstStopsWithZeroAddedWait` | Added zero-duration sleep after expiry; no executor-confirmed stop | `at4-overrun-red` → `at4-overrun-green-fixed` |
| `testThirtyMillisecondAckWaitsOnlyRemainingFiftyMillisecondsBeforeStop` | No remaining wait; stop occurred at 30 ms instead of 80 ms | `at4-remaining-red` → `at4-remaining-green` |
| `testPendingSourceTriggerIsRetainedWhenNextFrameLeavesToleranceBeforeAck` | Cache replacement lost the briefly in-tolerance event | `at4-event-retention-red-ingress` → `at4-event-retention-green` |
| `testAdvancingSourceDuringRemainingWaitStopsWithoutWaitingForBudgetTimer` | No stop at source trigger before budget timer returned | `at4-wait-source-red` → `at4-wait-source-green` |
| `testUnhealthyPendingSourceInhibitsBurstWithoutConcurrentMotorCommand` | Actual unhealthy source left pending transport authorized | `at4-health-red` → `at4-health-green` |
| `testBurstReturnCarriesItsActualConfirmedStopBoundaryThroughLaterWrapperStop` | Returned stop fence was nil | `at4-stop-return-red` → `at4-stop-return-green` |

**8 compiled assertion RED → GREEN cycles:** each listed RED has 1 executed / 1 failed / 0 passed / 0 skipped; each listed GREEN has 1 executed / 1 passed / 0 failed / 0 skipped. Verified all 16 summaries mechanically using `xcrun xcresulttool get test-results summary --path BUNDLE`.

Intermediate dispositions: `at4-pending-source-green` failed compilation because the planner's private `wrap` was used; corrected to the existing shared recovery wrap and rerun, not counted as behavioral RED or GREEN. `at4-overrun-green` still failed the genuine zero-added-sleep assertion; fixed the late monitor entry and reran the identical selector. `at4-event-retention-red` passed because asynchronous delivery scheduling could interleave the monitor between the two frames; it is **not counted as RED**. The real subscription now delegates to a synchronous ingress seam; delivering both captures through that seam without yielding produced the deterministic assertion failure in `at4-event-retention-red-ingress` before the production fix. Fake suspended timers/response continuations are released on both RED and GREEN, avoiding test-timeout cleanup.

#### Focused checkpoint exit

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationSafetyTests \
  -only-testing:PhroverKitTests/RoverControlTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at4-checkpoint-focused.xcresult
xcrun xcresulttool get test-results summary \
  --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at4-checkpoint-focused.xcresult
git diff --check
```

**157 passed / 0 failed / 0 skipped; whitespace check passed.** Existing empty-supported-platforms Xcode notice only. This focused checkpoint does not supersede the previous full-suite results or claim final Task 4 acceptance.

Changed in this checkpoint: `S/Nav/FollowTurnBurstExecutor.swift` (new), `S/Nav/FollowTurnBurstObservation.swift` (new), `S/Nav/NavigationController.swift`, `T/NavigationFollowTurnBurstTests.swift`, and this plan. Existing controller/diagnostic fixtures and motion guards were not weakened.

**Remaining Task 4 / next checkpoint:** production alignment and relative/absolute scan/recovery still run their prior continuous/fixed-pulse paths. Route both captured follow purposes into the shared seam only after assertion RED specifies initial confirmed-stop → 300 ms strict advancing source gate → feedback revalidation → one frozen actual-pose target. Carry the original Date watchdog through pending send, remaining wait, every stop/settle/source wait; add bounded immutable per-event calibration evidence, measured obligation-to-stop duration including drain, pure reduction and overshoot shrink/typed terminal failure. Prove 3° no-floor probe, fixed signed 0.25, ≤30° recovery segmentation, generation/cancellation fences at every suspension, newest-stop post-source arrival, and legitimate strict-source fixture migrations. The one-burst seam is not yet a complete authority/admission boundary and must not be connected without those tests. Actual source stream buffering and attribution/ambiguous intervals also need integration-level coverage before any claim of complete frame brackets. No current focused build/test blocker; scope/budget is the reason for this partial checkpoint.

**Task 5 follows completed Task 4**, using immutable confirmed-stop/source facts for newest matched-person-frame handoff, with original ten-second recovery/two-second outage semantics. It is not ready to begin on the basis of this partial checkpoint. Task 6 telemetry/review/full software gates remain later.

### Task 4 interrupted-continuation recapture — 2026-10-06

Resumed at HEAD `8cbcfe7`; controller tracked diff was +576 lines before this session's edits. The prior timed-out continuation had modified `NavigationController.swift`, `FollowTurnBurstExecutor.swift`, and `NavigationFollowTurnBurstTests.swift` beyond the preceding documented checkpoint. Those intervening changes were **not assumed tested**. Evidence-directory entries `at4-route-alignment-red/green`, `at4-route-scan-red/green/green-fresh`, and `at4-route-recovery-red` exist, but their summaries were not successfully recovered in this session; no additional historical RED → GREEN claim is made from their names.

Current runtime inspection shows `rotateForFollowAlignment` and `rotateForFollowScan` route through `startFollowTurn` and `FollowTurnOperationExecutor`. Initial confirmed stop and strict stopped-source admission precede target freezing. Absolute recovery uses the actual stopped yaw to resolve a maximum 30-degree segment. Current narrow tests recapture 3.7-degree no-floor alignment, fixed signed 0.25 wheels, 80 ms scan maximum, unchanged 7-degree scan tolerance, expired-response zero added wait, fresh stopped arrival, and immutable recovery segment target. This supersedes the earlier statement that routing was disconnected, **not** the outstanding Task 4 requirements.

Only production inspection, test-fixture corrections, and this plan update were performed in this resume. No production behavior was changed, so no new production RED → GREEN cycle is claimed. Two older zero-scan stop tests could no longer reach their intended receipt assertions: active zero-angle follow correctly requires post-stop source admission. Their fixtures now exercise actual serialized controller confirmations directly instead of attempting a zero-angle operation without fresh frames:

- `testNewWrapperStopInvalidatesEarlierFenceEvenWithSameOperationOwner` uses three zero-budget executor calls (no nonzero send), retains the same owner, captures the preceding actual stop during the newest stop, and still asserts that the earlier stop identity cancels source admission before any wait. An intermediate `stopAndConfirm` fixture changed the owner; its same-owner assertion failed and was corrected to the executor seam.
- `testStopEvidenceCarriesActualLastAcknowledgedFenceThroughFailedWrapperStop` uses real controller stop confirmations under captured operation evidence, throws on the third stop, and checks the frozen evidence's failed outcome and actual second acknowledged fence. This is receipt-boundary coverage, not an end-to-end zero-turn arrival claim.

All commands ran from `/Users/hungmai/Sites/Astral/astral-sdk`. Verified the evidence parent and obtained simulator UDID directly with `scripts/test-swift-sdk.sh --print-udid`: `EEA52712-371D-4FF6-B8EF-A2C78319D57F` (iPhone 17 Pro / iOS 26.5). Shell test calls had a **600000 ms** limit. Common command, with selectors/bundle substituted as recorded below:

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at4-resume-navigation-green-20261006.xcresult
git diff --check
```

| Actual run | Selectors / flags relative to command above | Observed result |
| --- | --- | --- |
| `at4-resume-navigation-20261006.xcresult` | Same class, added `-quiet` | Compiled; failed wrapper-identity and failed-wrapper receipt tests; 241.410 s test operation. No summary count claimed. |
| `at4-resume-navigation-fixtures-20261006.xcresult` | Same class, added `-quiet` | Failed same-owner wrapper test after initial fixture correction. |
| `at4-resume-wrapper-diagnosis-20261006.xcresult` | Replace class selector with `PhroverKitTests/NavigationFollowTurnBurstTests/testNewWrapperStopInvalidatesEarlierFenceEvenWithSameOperationOwner` | **1 executed / 1 failed**; actual owner mismatch `Optional(2)` versus `Optional(3)` from public stop calls. Fixture corrected without production changes. |
| `at4-resume-focused-20261006.xcresult` | Same class plus `PhroverKitTests/NavigationFollowScanDiagnosticsTests`, `PhroverKitTests/NavigationRotationWatchdogTests`, `PhroverKitTests/NavigationSafetyTests` | Hit **600 s tool limit**, after diagnostics failures and multiple 60 s test timeouts. No complete counts or successful broad exit claimed. Full captured command/output: `/Users/hungmai/.local/share/opencode/tool-output/tool_111b61223001l7T6tWxNPOs4m6`. |
| `at4-resume-navigation-green-20261006.xcresult` | Exact displayed command | **24 executed / 0 failed**, `TEST SUCCEEDED`; all three active routing tests passed. Count comes from actual XCTest console summary. |

`xcresulttool get test-results summary` on the initial bundle produced no output and timed out at 120 s, then at 600 s; direct executable retry with `--compact` also timed out at 20 s. Consequently the final count is console evidence, not a fabricated bundle-summary result. `pgrep -fl 'xcodebuild|xctest'` found no matching processes after the broader timeout. Whitespace check passed. Build emitted the empty-supported-platforms notice, AppIntents metadata-skipped warning, and a mutable `uptime` captured by the recovery fixture's Sendable closure warning; the narrow package compiled successfully.

#### Explicit remaining Task 4 blockers

1. **Calibration is not integrated.** `FollowTurnOperationExecutor.execute` currently creates a `let calibration`, sets `probeIssued` after one burst, and never reduces attributed source/host response evidence. Outside-tolerance second correction therefore terminates as unknown-response resolution failure rather than adapting from a valid bracket. Add a real behavioral assertion RED before changing this loop; retain bounded advancing immutable frames, actual collection times, measured send/stop latency and obligation-to-confirmation drain, post-ACK sampled travel, and valid/invalid bracket disposition. Prove conservative rates, shrink, and typed stopped failure.
2. **Runtime watchdog/safety carry-through is incomplete.** The runtime `burst` closure currently discards its supplied progress argument (`_`); pending-send/remaining-wait monitors do not carry the original Date watchdog. Runtime admission and source waiting evaluate with `feedback: nil`, so the required actual tipping/feedback revalidation is not demonstrated. Deadline wake/owner/generation/health/cancellation checks at every suspension still need end-to-end assertions and fixes. Existing helper-only source-wait watchdog tests do not certify the active loop.
3. **Broader exit is failing, not green.** Examples observed: `testAbsoluteRecoveryKeepsSegmentTargetThroughOppositeSignCorrectionAndInclusiveTolerance` failed expected runtime facts; adapter early failure expected `.noPose` but got `.trackingLost`; AR-generation pulse count expected 1 but got 0; completed-pulse trace and returned-receipt tests failed before sending; watchdog trace failed with `.trackingLost` instead of `.stalled` and then indexed an empty fixture array. Absolute recovery/cancellation tests repeatedly timed out. Inspect each fixture and assertion before migrating it to explicit capture-time source events; preserve source gates and genuine safety assertions. Do not mass-replace expected results or skip tests. Old fixed-200-ms trace expectations require disposition without pulling Task 6 completion into this checkpoint.
4. Re-run the full **Task 4 four-class exit** only after the above runtime/fixture corrections, then mark Task 4 complete if its contract is fulfilled. The **24-test narrow green checkpoint is not full Task 4 acceptance**. Generic isolation, actual safety feedback, cancellation during active bursts, calibration, and original watchdog/deadline behavior must be verified before proceeding.

No Task 5/6 implementation, commit, push, full SDK/app suite, installation, or device test was performed. Existing `.serena`, `.opencode`, `AGENTS.md`, Tasks 1–3, and `.superpowers` assets were preserved.

### Task 4 calibration-only green checkpoint — 2026-10-06

Under explicit user direction, addressed only blocker 1 from the preceding recapture. **Task 4 remains unchecked.** No broader-exit fixture migration, safety/watchdog redesign, Task 5/6 implementation, full suite, app/device operation, or commit. Read the already-approved planner/controller/source seams; kept the pure Task 1 planner and its public API unchanged.

#### Behavioral RED → GREEN

Added and **ran** `NavigationFollowTurnBurstTests/testSecondAlignmentBurstShrinksFromActualResponseLatencyAndPartialCoast` before production edits. It uses the actual controller and `NavigationFollowMeMotion` adapter, explicit same-generation source captures and synchronous ingress, actual successful sender/stop returns, and a real strict 300 ms stopped-source gate. RED executed **1 test / 1 failed test**, with four assertions: only one send instead of two, missing second budget, missing second frozen target, and `.rotationResolutionInsufficient` instead of arrival. Bundle: **`at4-calibration-shrink-red-20261006.xcresult`**.

Implemented the minimal integration, then ran the **identical selector** GREEN: **1 test / 0 failures** in **`at4-calibration-shrink-green-20261006.xcresult`**; complete build/test log **`at4-calibration-shrink-green-20261006.log`**. All evidence files below are under `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode` (parent verified); commands ran at `/Users/hungmai/Sites/Astral/astral-sdk`. Simulator selected by `scripts/test-swift-sdk.sh --print-udid`: `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, iPhone 17 Pro / iOS 26.5. Every test shell call used **600000 ms** tool limit and serial **60 s** test limits.

Exact RED/GREEN command template (substitute `COLOR` with `red` or `green`; GREEN also redirected stdout/stderr to its matching `.log`):

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests/testSecondAlignmentBurstShrinksFromActualResponseLatencyAndPartialCoast \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at4-calibration-shrink-COLOR-20261006.xcresult
```

#### Integrated behavior / exact changed files

- **`S/Nav/FollowTurnBurstExecutor.swift`:** calibration is still an immutable value but its operation-local binding is replaced by the pure `FollowTurnBurstPlanner.recording` result after each successful burst's actual confirmed stop and strict fresh settled sample. Captured operation ID, source generation, target, profile and the original progress/watchdog object persist. A failed sender, thrown/failed stop, cancelled/replaced owner, or failed/cancelled source admission exits **before reduction**; rejected evidence remains stopped and returns `.rotationResolutionInsufficient`. Subsequent planning uses the retained maxima and overshoot ceiling, not another provisional 80 ms request.
- **`S/Nav/FollowTurnBurstObservation.swift`:** added `FollowTurnResponseBracket`, retaining up to **128 immutable actual collection facts** from pre-send source through pending-send, stop/drain and settle. Repeated unchanged source is not appended as frame advancement. A strict stopped evaluation can replace the exact same last ingress endpoint with its actual evaluation collection time; an adjacent burst can reuse that exact immutable boundary. Missing/coalesced sequence, reordered source, overflow, unhealthy repeated source, and pure-reducer invalid timestamp/generation/half-turn evidence cannot become trusted traversal/rate evidence. No extra pose-provider reads. The bounded observer is removed by captured UUID on completion or any exit.
- **`S/Nav/FollowTurnBurstAuthorization.swift`:** sender receipts now retain the first known stop-obligation uptime; the synchronized token preserves the earliest timestamp rather than overwriting it at response return. Cancellation-only inhibition remains non-learning. Public sender compatibility is unchanged.
- **`S/Nav/NavigationController.swift`:** retains a burst-local source observer until strict stopped-source admission; passes captured response facts to the shared operation executor. Reduction requires the returned stop fence to still be the newest actual same-owner/same-generation fence. Obligation time includes deadline/source inhibition before send drain, rather than measuring only stop-call latency; send entry/response, stop acknowledgement, and actual source collection times remain separate. No parallel motor writer. Existing fixed signed 0.25 wheels, alignment 0.05 rad and scan 7-degree profiles, send-entry budget and strict settle gates remain in use.
- **`T/NavigationFollowTurnBurstTests.swift`:** three new seam-behavior tests, added/run one at a time. No old fixtures/assertions changed in this calibration slice.
- **This plan:** precise evidence/current checkpoint and remaining scope.

Worked integration case: frozen alignment target **0.5 rad**, first requested budget **0.080 s**, settled yaw **0.18 rad**, effective rate **0.18 / 0.08 = 2.25 rad/s**, measured sender duration **0.080 s**, obligation-to-stop duration **0.010 s**, and two actual post-ACK capture endpoints providing partial sampled travel **0.010 rad**. Remaining excess **0.270 rad** gives **0.270/2.25 − (0.080+0.010) − 0.010/2.25 = 0.0255555555555556 s**. The second send's captured target remains **0.5 rad**, and arrival requires its own stopped fresh source. This verifies the measured host response allowance and partial sampled coast arithmetic, not certified physical rate/coast.

#### Additional coverage and final narrow exit

The following tests verify branches already integrated by the above RED → GREEN slice, not additional claimed production RED cycles:

| Selector after `PhroverKitTests/NavigationFollowTurnBurstTests/` | Bundle / matching `.log` prefix | Result |
| --- | --- | --- |
| `testMeasuredOvershootWithNonpositiveCandidateFailsStoppedWithoutReverseOrResend` | `at4-calibration-terminal-20261006` | **1 executed / 0 failures**; valid measured overshoot outside tolerance, nonpositive correction candidate, one send only, actual acknowledged stop retained, typed resolution failure. |
| `testRecoveredHealthyEndpointCannotHideInvalidPendingCalibrationSource` | `at4-calibration-invalid-20261006` | **1 executed / 0 failures**; unhealthy captured source while send is pending is retained despite subsequent healthy frames/ACK; no learned second correction. |

Each used the exact RED/GREEN command flags above, replacing selector/bundle, and redirected stdout/stderr to its matching `.log`. An intermediate class check after the first GREEN (`at4-calibration-class-check-20261006.xcresult` / matching `.log`) passed **25 tests / 0 failures**; final below supersedes it.

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at4-calibration-final-20261006.xcresult \
  > /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at4-calibration-final-20261006.log 2>&1
git diff --check
```

**Final: 27 executed / 0 failed, `TEST SUCCEEDED`; whitespace check passed.** Counts are from actual XCTest console logs, without retrying the previously hanging `xcresulttool` summary command. Compilation emitted the existing mutable-uptime Sendable recovery-fixture warning, empty-supported-platforms notice, and AppIntents metadata-skipped warnings; no new compile error or test timeout. Only the new method selectors and `NavigationFollowTurnBurstTests` class were executed.

**Next Task 4 scope remains separate:** original watchdog during pending send/remaining wait, actual tipping/feedback safety revalidation and suspension fencing, then the already-failing broader-exit fixtures. The calibration slice does not certify those boundaries or complete Task 4. Coalesced/dropped frames now fail conservatively instead of inventing calibration; production source delivery and attribution still belong in the remaining integration review. No Task 5/6 work should start from this narrow checkpoint.

### Task 4 runtime watchdog / actual ACK checkpoint — 2026-10-06

Continued only Task 4 under explicit user direction. **Task 4 remains unchecked.** The preceding statement about missing runtime progress/ACK integration is superseded by the implementations and software evidence below, not by a claim of complete Task 4 acceptance. No Task 5/coordinator production changes, Task 6 structured telemetry work, full SDK/app tests/build, device operations, or commits.

#### Runtime changes and policy boundaries

- **`S/Nav/FollowTurnSourceGate.swift`:** `FollowTurnRuntimeState` owns one original `DriveProgressWatchdog(timeout: 2.5, minimumProgress: 0.05)` across the entire frozen-target turn. Its checkpoint begins before the operation's subsequent ACK admission await. Only distinct normal, age-valid, expected-generation actual captures update `abs(wrap(frozenTarget - actualYaw))`; sampled travel, direction changes away from the goal, repeated reads, stops, settle, and frame waits cannot renew progress. Failure is latched. Date is used only for the existing wall watchdog/ACK age; source/host-budget uptime is never compared against a Date epoch.
- **`S/Nav/FollowTurnBurstExecutor.swift`:** the operation loop uses that shared state instead of copying a new epoch into each phase. Pending/send/stop return and source-admission failures resolve before calibration or later correction. Actual send-entry updates commanded state; merely choosing a burst does not impose a new first-command ACK freshness requirement.
- **`S/Nav/NavigationController.swift`:** operation-scoped ingress observes actual goal progress. Pending-send monitoring preserves the epoch through budget expiry/drain, uses bounded source freshness/watchdog/recovery wake deadlines, and only inhibits its own token. Remaining-budget waits and strict stopped-source waits use the same live state; the actual ACK getter is re-read for active safety and evaluated with current Date **after** its await. Ownership, cancellation, stop latch, recovery authorization, source generation/health and strict stop capture fences are revalidated before sender entry and on every transport authorization callback, synchronously against retained facts. No logging or pose-provider await is inserted between final validation and sender invocation.
- Production controller's actual asynchronous feedback boundary is **`currentLastAck = { await control.lastAckAt }`**. There is **no controller IMU-feedback getter** to wire. Historical rotation used `feedback: nil` and `checkForwardObstacle: false`; these policies remain unchanged, including the first-send `requireFreshAck: false` policy. The ACK freshness requirement captured for a first sender/retries stays false until its actual response; remaining wait/subsequent bursts require the real ACK freshness. This checkpoint does not claim new tipping coverage or fabricate `RoverFeedback` metadata.
- Sender return uptime, pending monitor cancellation and drain completion are now captured synchronously inside the actual sender-return closure, before the task-local wrapper can resume on a later actor turn. A retained crossing/tolerance trigger ends monitoring rather than scheduling new timers. `FollowTurnSourceWaitToken` synchronously cancels a queued timer before its cancellation handler's actor hop; cancelled/expired timers cannot invoke a late or zero-duration `sleep`. These changes fix real late timer-entry behavior exposed by the zero-added-wait assertions, rather than weakening those assertions.

#### Compiled behavioral RED → identical-selector GREEN

All evidence is under **`/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`**, verified in the preceding resume. Ran at repository root, selected simulator with `scripts/test-swift-sdk.sh --print-udid`: `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, iPhone 17 Pro / iOS 26.5. Each row used this exact command, substituting the full selector and bundle/log basename below. Individual late-session selectors had a **180000 ms** shell bound; initial pending/ACK/first-ACK runs used **600000 ms**. Each command retained serial **60 s** test limits.

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests/SELECTOR \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BASENAME.xcresult \
  > /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BASENAME.log 2>&1
```

| Selector | Actual assertion RED | RED → GREEN basenames (all end `-20261006`) |
| --- | --- | --- |
| `testOriginalWallWatchdogInhibitsPendingSendBeforeResponseAndDrainsStop` | Pending transport still authorized at 2.5 s Date wall expiry before its independent uptime budget; stop must not overtake suspended sender | `at4-runtime-pending-red-drained` → `at4-runtime-pending-green` |
| `testActualAckGetterRevalidatesCommsBeforeRemainingBudgetWait` | No active actual-ACK reads; no stop at 30 ms despite stale ACK, leaving the remaining 50 ms wait active | `at4-runtime-ack-red` → `at4-runtime-ack-green` |
| `testFirstFollowBurstRetainsExistingNoFreshAckRequirementUntilSenderEntry` | New validation prematurely blocked the first command on historical stale ACK, returning comms loss without sending | `at4-runtime-firstack-red` → `at4-runtime-firstack-green` |
| `testAttemptGateRejectsHealthyCaptureRegressingToStopAcknowledgement` | Real controller's attempt authorization callback accepted a healthy/finite/age-valid regressed capture equal to stop ACK after queue admission | `at4-runtime-attempt-source-red` → `at4-runtime-attempt-source-green` |
| `testPendingFeedbackSuspensionCannotPauseIndependentBudgetAndWallDeadline` | A suspended actual getter prevented any independent budget timer from entering; token remained authorized while sender/getter were both suspended past the original deadlines | `at4-runtime-independent-deadline-red` → `at4-runtime-independent-deadline-green` |

Each listed RED executed **1 failed test** (respectively 1 / 3 / 2 / 3 / 2 assertion failures); each listed GREEN executed **1 passed test / 0 failures**, verified from actual captured XCTest logs. Five method-level production assertion RED → GREEN cycles. The attempt test uses the actual controller-created attempt callback at the serialized sender seam; it does not claim a separate live HTTP probe.

The final independent-deadline regression was added/run RED after the first timer-fixed 46-test checkpoint, before its production fix. A dedicated operation-scoped budget/watchdog/source/recovery deadline monitor now runs **without awaiting the actual ACK getter**, preventing that suspension from pausing inhibition. It reads already-ingested source facts and the original progress epoch, never motors, and is cancelled synchronously at actual sender return. The actual ACK monitor independently revalidates completed metadata; neither monitor creates a motor owner or stop acknowledgement. Both suspended fake continuations/timers are released on RED and GREEN. `at4-runtime-checkpoint-final-timer-20261006` passed **46** before this additional regression/fix, but is superseded by the corrected-tree **47-test** final below.

Additional single-selector coverage for these integrated branches (no separate RED claim):

- `testPendingProgressUsesActualTargetErrorAndRepeatedFramesCannotRenewCheckpoint` — `at4-runtime-progress-20261006`: **1 passed**. Genuine 0.1 rad actual goal progress moves the epoch; repeated capture cannot renew it; later motion away from target is not progress, and expiry inhibits pending sender before drain.
- `testActiveFeedbackAwaitCannotResetWallCheckpointOrAddRemainingMotorWait` — `at4-runtime-feedback-wall-20261006`: **1 passed**. Suspended actual getter consumes the original Date checkpoint; fresh flat source cannot reset it; stop ACK remains at 30 ms host time with no remaining motor wait. Watchdog failure precedes stale ACK evaluation after the await.

The first pending RED (`at4-runtime-pending-red-20261006`) observed the genuine failed assertion but left a synthetic unexpired uptime timer after response release and timed out. Corrected only fixture drain (`uptime = 10.400` after the pending-obligation assertion), reran compiled RED in `...pending-red-drained...` **before** production edits. The timed-out initial run is not counted as a completed method RED cycle.

#### Broader failure classification and fixture migrations

`at4-runtime-class-check-20261006` ran the complete burst/watchdog classes before migrations: burst **30 executed / 3 failed**; the watchdog class encountered three 60 s test timeouts and multiple legacy-source assertion failures across runner restarts. No clean aggregate count is inferred from restart summaries. This is a failed intermediate gate, not a final result.

1. **Legitimate new strict-source fixtures:** follow-only watchdog tests used legacy yaw-only closures and no post-ACK advancing capture. Migrated **`T/NavigationRotationWatchdogTests.swift`** fixtures to store explicit same-generation snapshots and publish actual simulated capture events at timer boundaries through synchronous ingress. Provider reads return stored samples, never fabricate advancement. Fixed-magnitude success reaches the actual frozen target; existing generic rotation/watchdog count assertions, all failure/latch assertions, and exact public cancellation/safety outcomes remain intact.
2. **Actual pending-stop drain semantics:** old pulse-stop cancellation fixtures expected a 60 s `Task.sleep` fake stop to be cancelled by the parent loop. The shared executor deliberately runs stop confirmation independently; a parent cancellation is not a real stop response. A single migrated selector still timed out (`at4-runtime-rotation-cancel-migrated-20261006`) and exposed that fixture assumption. Replaced the pending stop with an explicit response continuation, scheduled independent confirmation, **asserted it cannot overtake the pending stop**, then released the actual cancelled response. Same success/failed-independent-stop outcomes and future-motion latch assertions retained. Identical single selector `testCancelledPulseStopIsSafeOnlyAfterIndependentConfirmedStop` passed in `at4-runtime-rotation-cancel-drained-20261006` (**1 passed**).
3. **Diagnostics cancellation fixture:** ran `NavigationFollowScanDiagnosticsTests/testAbsoluteRecoveryCallerCancellationDrainsStopAndRetainsFailedLatch` alone with 180 s shell / 60 s test bound, capturing its old fixture hang in `at4-runtime-recovery-cancel-diagnosis-20261006`. It supplied a forever-repeated frame at stop ACK time and waited specifically for an obsolete 200 ms sleep. Migrated just this selector in **`T/NavigationFollowScanDiagnosticsTests.swift`** to explicit generation-4 advancing capture events and an actual active-budget wait boundary, retaining all six pre-stop/feedback/active-wait × stop-success/failure outcome assertions, sends counts, blocked retry and latch checks. Identical selector passed in `at4-runtime-recovery-cancel-migrated-20261006` (**1 passed**). No other diagnostics assertions were mass-replaced.
4. **Runtime timer bug, not a weakened test:** intermediate scoped exits `at4-runtime-scoped-check-20261006` (**44 executed / 2 failed**) and `at4-runtime-scoped-final-20261006` (**45 executed / 2 failed**) exposed post-response timer invocation in the production alignment/scan zero-added-wait tests. Retained the actual crossing trigger and moved sender-return capture/cancellation to its real boundary. The test's `ackReturned` flag is now set at the actual fake sender return, not before externally releasing its response continuation. `at4-runtime-scoped-final-return-20261006` passed **45**, but after adding feedback-wall coverage `at4-runtime-checkpoint-final-20261006` exposed the queued timer cancellation race again (**46 executed / 1 failed**). The synchronous source-wait token fixes that race; final identical selector set below passed. Earlier green is not substituted for final corrected-tree evidence.
5. **Source failure specificity:** the existing calibration unhealthy-pending-source test now expects `.trackingLost` rather than later `.rotationResolutionInsufficient`: the active runtime guard latches health loss at the actual invalid capture before reduction. Its unhealthy capture remains unhealthy, its recovered endpoint is unchanged, and its one-send/no-learning/no-resend/confirmed-stop assertions remain. This is stricter immediate source failure, not acceptance of previously invalid evidence.

#### Final corrected-tree scoped exit

```bash
xcodebuild test -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/testAbsoluteRecoveryCallerCancellationDrainsStopAndRetainsFailedLatch \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at4-runtime-checkpoint-independent-final-20261006.xcresult \
  > /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at4-runtime-checkpoint-independent-final-20261006.log 2>&1
git diff --check
```

Shell bound **300000 ms**, serial test bound **60 s**. **47 executed / 0 failed, `TEST SUCCEEDED`**: complete `NavigationFollowTurnBurstTests` **34**, complete `NavigationRotationWatchdogTests` **12**, one diagnostics selector **1** (six cancellation variants). Counts are actual XCTest console summaries. Compilation for this slice emitted the existing mutable `uptime` Sendable recovery-fixture warning, AppIntents metadata-skipped warnings and empty-supported-platforms notice; no final compile error or test timeout. Whitespace check passed.

**Remaining Task 4 blockers / next bounded slice:** full `NavigationFollowScanDiagnosticsTests` has **not** been recaptured green. The earlier known unchanged cancellation/feedback helpers still need explicit strict-source fixtures (e.g. `testAbsoluteRecoveryResolvesAfterAcknowledgedStopAndFeedback`, `testContextualCallerCancellationAloneDrainsScanAndRequiresIndependentStop` and related helpers). Do not rerun that whole known-hanging class with a 600 s unknown-progress limit; migrate/re-run individual selectors first. Prior `testAllFourAdapterRequestsDeliverActualPurposeOnEarlyFailure` `.noPose` versus `.trackingLost` assertions require compatibility investigation, not a blanket expectation change. Old fixed-200-ms trace timings are obsolete, **but missing evaluation/send/settle lifecycle records after new runtime routing are a real observable-runtime/trace integration issue**, not solely a fixture problem; preserve meaningful receipt/source/stop-priority facts while making the active timings truthful. All-suspension owner/session/generation fences and the complete Task 4 four-class exit (including `NavigationSafetyTests`) still need final acceptance. No full three-class diagnostics exit or completed Task 4 claim is made from this 47-test scoped checkpoint. Tasks 5–6 stay blocked.
### Task 4 minimal lifecycle / diagnostics fixture checkpoint — 2026-10-06

**Partial, not Task 4 acceptance.** Continued Task 4 only, preserving the preceding runtime implementation and all unrelated workspace changes. No Task 5/6 completion, full SDK/app gate, independent review, device operation or commit. All edits used `apply_patch`.

#### Production corrections, each preceded by compiled assertion RED

The evidence parent is `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode` (verified). All successful test invocations ran from the repository root on simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, iPhone 17 Pro / iOS 26.5. Each row used the exact command below, substituting its selector and bundle basename. Bundles end in `.xcresult`; basenames below end in `-20261006`.

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 30 -maximum-test-execution-time-allowance 30 \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/SELECTOR \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BASENAME.xcresult
```

| Selector | Assertion RED / narrow correction | RED → GREEN basenames (without date suffix) |
| --- | --- | --- |
| `testRecoveryDiagnosticsRejectSourceAndDeadlineWithoutInventingResolvedMovement` | Missing rejected generation-5 capture and missing-pose reason in recovery completion. Retain the actual stopped ingress sample/read time with unresolved target/segment/movement fields still absent. | `at4-exit-rejection-red-fixture` → `at4-exit-rejection-green` |
| `testRuntimeBurstTraceCapturesLateAckAndOnlyActuallyEnteredWaits` | Missing completed lifecycle record with valid strict source. Wire existing trace calls for both captured purposes at actual burst/send/wait/stop/settled-evaluation boundaries; 100 ms ACK has no invented remaining-wait begin/end. | `at4-exit-lifecycle-red` → `at4-exit-lifecycle-green-compiled` |
| Same selector, extended before the next production change | Trace reported 200 ms for scan and null profile/tolerance for alignment. Project the immutable active burst profile into the compatibility schema: 80 ms maximum, purpose tolerance, 300 ms settle, signed 0.25 magnitude. Historical `RoverConfig.followScanRotationProfile.pulseWait == 0.200` remains unchanged and inactive. | `at4-exit-profile-red` → `at4-exit-profile-green` |
| `testPreflightRejectionLogsAvailableSourceFacts` | Stored stale frame/source age/rejection missing from failure record despite explicit event subscription and actual stop snapshot. Capture the retained rejected sample into trace evidence without provider reads or authorization. | `at4-exit-preflight-red-fixture` → `at4-exit-preflight-green` |

All four RED bundles report **1 total / 0 passed / 1 failed / 0 skipped**; their identical-selector GREEN bundles report **1 total / 1 passed / 0 failed / 0 skipped**, mechanically verified via `xcresulttool get test-results summary`. No production safety threshold, watchdog epoch, transport authorization, latch or stop ownership rule was changed. Trace calls are synchronous; logging uses retained source and actual runtime watchdog snapshots. Existing `follow_scan.*` names are reused for both captured purposes. Detailed formula/attempt/physical-confidence telemetry remains Task 6.

Intermediate dispositions: the first invocation used `swift/` instead of the repository root and created a failed build-result directory; a subsequent root invocation rejected that existing path. Neither is behavioral RED. `at4-exit-rejection-red-valid` failed before fixture subscription repair and is superseded by the valid subscribed-fixture RED above. `at4-exit-lifecycle-green` failed compilation because a private receipt setter was used; corrected to `recordCommandReceipt` and rerun in `...green-compiled`. Build failures are not assertion RED/GREEN.

#### Narrow fixture migrations

- Rejected-recovery/preflight fixtures now subscribe to real injected events and supply a stored stop snapshot. They retain invalid generation, missing pose and stale timestamp; these are never relabeled as healthy.
- The owner-replacement fixture now suspends the actual second stop (the shared executor's burst stop for alignment, terminal ready stop for readiness). It publishes stored explicit same-generation captures at simulated movement/timer boundaries, then replaces ownership while the real stop response is suspended. Both exact `.cancelled` results remain asserted; no skip was added. `at4-exit-owner-fixture-green` passed one selector.
- Recovery stream captures now have one provider read, actual initial post-ACK `4:11` resolution and final stopped `4:13` arrival; arrival capture is explicitly asserted strictly newer than its returned stop ACK. `at4-exit-recovery-capture-green` passed one selector.
- Five early-failure/context tests narrowly reflect strict follow-turn `.trackingLost`, 80 ms maximum and alignment's captured 0.05-rad profile. Ready/goal still expect `.noPose`; legacy conformers still report unknown controller facts. `at4-exit-context-fixtures-before` failed all five; `...context-fixtures-green` passed all five after these test-only migrations.
- A follow-only fixture helper publishes actual simulated captures, never advancement on reads; generic `makeController` is unchanged. Void-receipt, fixed-sign/tolerance and search/reacquisition budget tests now exercise the new policy. The latter is renamed `testFollowAdapterSearchAndReacquisitionRequestAtMost80msThen300ms`. Its exact two post-send waits, one nonzero send, wheel signs and final arrival remain asserted. `at4-exit-basic-fixtures-green` passed all four selectors including unchanged generic scan.
- Completed-pulse trace fixture now uses actual enriched ingress, initial settle, 40 ms send, 40 ms remaining budget, serialized stop and fresh settled evaluation. Exact lifecycle ordering, source clocks, provider count, purpose/context, signed response, profile, receipt availability and final stop assertions remain. Its original epoch legitimately moves on the actual 0.3-rad goal progress, so current watchdog progress is zero at that new checkpoint. `at4-exit-completed-trace-migrated` passed one selector.

#### Final corrected-tree checkpoint and precise remaining failures

The final command used the same flags above, with complete class selectors `NavigationFollowTurnBurstTests`, `NavigationRotationWatchdogTests`, and `NavigationSafetyTests`, plus these 18 method selectors in `NavigationFollowScanDiagnosticsTests`:

```text
testRuntimeBurstTraceCapturesLateAckAndOnlyActuallyEnteredWaits
testRecoveryDiagnosticsRejectSourceAndDeadlineWithoutInventingResolvedMovement
testRecoveryDiagnosticStreamUsesCapturedControllerReadsAndActualFinalYaw
testIncompleteRecoveryFinalStopCannotReturnLateArrivalAfterOwnerReplacement
testOrdinaryRelativeAlignmentRejectsYawOnlyLegacyProvenance
testAbsoluteRecoveryCallerCancellationDrainsStopAndRetainsFailedLatch
testAllFourAdapterRequestsDeliverActualPurposeOnEarlyFailure
testReplacingSuspendedRequestCannotRelabelOldOperation
testCancelledPreStopRetainsRequestAndUnknownTargetWithoutSending
testContextIsReservedBeforePreStopAndBothDeliveriesKeepIt
testLatePreStopFailureKeepsOldContextWhileReplacementFailsClosed
testVoidControllerTransportReportsUnknownMetadataDespiteConfirmedStop
testFollowAdapterSearchAndReacquisitionRequestAtMost80msThen300ms
testFollowFixedSignedMagnitudeOutsideTolerance
testGenericScanKeeps80msAndMinimumFloor
testGenericScanAndAlignmentDoNotConsultFollowSourceClockOrProvider
testCompletedPulseTraceUsesExistingSamplesExactHostTimingAndCapturedContext
testPreflightRejectionLogsAvailableSourceFacts
```

Bundle **`at4-exit-scoped-final-20261006.xcresult`**: **90 total / 90 passed / 0 failed / 0 skipped**, verified by `xcresulttool get test-results summary`. This covers burst **34**, rotation watchdog **12**, safety **26**, diagnostics **18**. `git diff --check` passed. Existing mutable-uptime Sendable fixture warning and Xcode empty-supported-platforms notice remain.

**Confirmed current failed selector:** `PhroverKitTests/NavigationFollowScanDiagnosticsTests/testFailureTracesRetainFailedStageReceiptPrimaryReasonAndLatch`. Exact common command above, bundle **`at4-exit-failure-trace-blocker-20261006.xcresult`**, **1 total / 1 failed / 0 passed / 0 skipped**. `xcresulttool get test-results tests` identifies five assertions: send case receives `.trackingLost` instead of `.commandFailed`, failed stage is `independent_stop` instead of `send`, both reason fields are `trackingLost`, and expected send-ACK record is absent. Its legacy-only fixture fails before reaching the intended send/stop/watchdog branches. Do not change those failure/latch assertions to pass; migrate it to actual controllable enriched movement/source events and then investigate remaining genuine trace failures with assertion RED before any production fix.

The full diagnostics class was attempted in **`at4-exit-diagnostics-inventory-20261006.xcresult`**, using the same command with the class selector and **5-second** test limits, but it did **not** complete within the **360000 ms** shell limit. Xcode's allowance did not bound these suspended async fixtures sufficiently. Its missing `Info.plist` makes it an incomplete bundle; no full-class count, skipped-test claim or failure inventory is inferred. A subsequent controlled single `testIncompleteRecoveryFinalStopCannotReturnLateArrivalAfterOwnerReplacement` invocation (`at4-exit-owner-fixture-before`) also exceeded a **90000 ms** shell limit before its fixture repair; its migrated selector passed as recorded above. `pgrep -fl 'xcodebuild|xctest'` showed no remaining matching processes after the full-class timeout. Do not repeat the full class until the remaining legacy cancellation/final-stop fixtures are controlled.

There are **72 diagnostics selectors** in this tree, of which only the **18** above belong to the final green checkpoint. The other 54 are not certified by this checkpoint; many still contain obsolete 200 ms waits, constant ACK-equal captures, missing event subscriptions or old final-stop counts. One failed selector is isolated above, not an assertion that it is the only remaining failure. Task 4's complete diagnostics/four-class exit remains outstanding; keep Task 4 unchecked and Tasks 5–6 unstarted.

Exact files edited in this continuation: `S/Nav/NavigationController.swift`, `S/Nav/RotationDiagnosticModels.swift`, `T/NavigationFollowScanDiagnosticsTests.swift`, and this plan. `.serena`, `.opencode`, `AGENTS.md`, historical specifications and `.superpowers` assets were preserved.

### Task 4 complete diagnostics / four-class exit — 2026-10-06

**Task 4 is complete at this software gate.** This supersedes the preceding 90-test partial status and its outstanding diagnostics blocker. Continued Task 4 only; Tasks 5–6 remain unchecked and unimplemented by this continuation. No full SDK/app gate, independent implementation review, commit, push, device operation or physical acceptance claim. All edits used `apply_patch`; unrelated working-tree changes and workflow assets were preserved.

#### Controlled fixture inventory and migration

First reran only `NavigationFollowScanDiagnosticsTests/testFailureTracesRetainFailedStageReceiptPrimaryReasonAndLatch` in `at4-diag2-failure-before-20261006.xcresult`: it failed because legacy-only pose was rejected before its intended send. Then supplied stored explicit source provenance, a genuine advancing post-ACK frame at the stopped gate, actual timer captures and a common source-uptime clock. The fixture now reaches all four original send/pulse-stop/independent-stop/watchdog cases; its failed-stage, receipt, primary reason, blocked retry and latch assertions were retained.

Before the full class, enumerated its methods against the preceding incomplete inventory. That old bundle has no readable `Info.plist`, so no executed-selector set can be recovered from it; the 18-selector checkpoint was not treated as a full inventory. Inspected and migrated the known suspension fixtures before retrying the full class: generic replacement drain, queued cancellation cleanup, caller cancellation at ACK/send/remaining wait/pulse stop/settle/terminal confirmation, external cancellation tracing, cancelled pulse-stop receipt, detection stop, interrupted recovery, absolute recovery feedback, enriched replacement and suspended feedback. These controlled selectors now finish normally. No test was skipped or removed.

The fixture blueprint retains source snapshots in storage; providers return those snapshots without advancing IDs or timestamps. Simulated capture/timer/movement boundaries advance the source clock **before** synchronous ingress. Every qualifying post-stop capture is genuinely distinct and strictly beyond the actual ACK/source fence. Invalid generation, stale/future/nonfinite time, absent pose and legacy/unknown provenance remain invalid. The 500 ms age-boundary fixture starts with an actually age-valid frame and then publishes new post-ACK captures, rather than treating the original 500 ms-old frame as post-stop evidence.

Further checks prevented false-positive preflight coverage: final-stop source/generation fixtures now assert one actual nonzero send and two actual stops before injecting their fault. Pre-send age and incomplete recovery feedback fixtures assert that their intended guard/getter was reached. A generation-5 sample from a forbidden second provider read still catches accidental arrival resampling. Generic continuous alignment/scan fixtures keep their original legacy-compatible behavior; the follow alignment test now explicitly asserts its adaptive budget/settle policy. Historical 200 ms configuration stays unchanged, while active profile/timing expectations use the 80 ms maximum with no floor. Absolute target, wraparound, actual opposite-sign adaptation, inclusive tolerance and final stopped source/result pairing assertions remain.

The old `arrival_stop` / `final_confirmation` cancellation scenarios now suspend the actual terminal burst confirmation; they do not invent separate wrapper-stop trace stages. Completed-operation diagnostics explicitly name the actually reached `settle` stage. Stop failure remains `.commandFailed` with blocked motion; cancellation remains contingent on a real independent confirmation. The phase-count/timing changes reflect the new execution path, not reduced stop/latch coverage.

#### Compiled production assertion RED → identical-selector GREEN

Evidence parent: **`/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`**. Repository-root command for every row, with its selector and basename substituted:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests/SELECTOR \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BASENAME.xcresult
```

Each basename below has prefix **`at4-diag2-`** and suffix **`-20261006`**. Every listed RED summary is **1 total / 0 passed / 1 failed / 0 skipped**; each final GREEN summary is **1 total / 1 passed / 0 failed / 0 skipped**, mechanically verified with `xcresulttool get test-results summary`.

| Selector | Actual assertion failure / production correction | RED → final GREEN basename core |
| --- | --- | --- |
| `testFailureTracesRetainFailedStageReceiptPrimaryReasonAndLatch` | Enriched fixture exposed failed `send` stage overwritten by cleanup and terminal watchdog elapsed still zero. Retain actual failed send stage independently of last reached stage; capture the real terminal Date-watchdog snapshot without changing its epoch. | `failure-red-enriched` → `failure-green` |
| `testCancelledPulseStopTraceDefersSafetyToIndependentConfirmation` | Old independently draining pulse response was labeled failed and latched after captured owner replacement. Classify fenced, replaced old work as interrupted; its response stays pending/cancelled and the replacing serialized confirmation alone decides the new latch. Same-owner failed stop still latches. | `stop-cancel-red` → `stop-cancel-green` |
| `testNonzeroAckDoesNotReusePreStopConfirmationAndStopFailureRetainsStall` | Stop failure erased the prior actual stall and stream incorrectly reused initial stop confirmation. Record `.pending` at actual nonzero sender invocation; publish the already-latched runtime cause while stop is pending, before its independent response can fail. Failed stop still blocks motion and takes outcome priority without erasing primary stall. | `stall-stop-red` → `stall-stop-green-pending` |
| `testExpiredPostSampleTraceRetainsActualSourceAndRejectionReason` | Actual rejected ingress was lost when runtime health failure returned before source-selection trace. Retain that immutable rejected capture; later healthy observations/terminal snapshots cannot manufacture current watchdog progress from invalid source. | `post-source-red` → `post-source-green` |
| `testRuntimeBurstTraceCapturesLateAckAndOnlyActuallyEnteredWaits` | After correctly invalidating initial confirmation at nonzero send, the actual successful burst stop did not restore confirmed evidence. Record confirmation only after its real ACK and only for unchanged, unfenced owner. Never clear newer failure from stale work. | `confirmed-red` → `confirmed-green` |
| `testWatchdogCheckpointTimeIsObservationBoundaryNotEarlierPoseRead` | Trace omitted actual elapsed feedback-await time before the burst. Capture the current watchdog snapshot at the real burst boundary; preserve the original checkpoint and threshold. | `checkpoint-red` → `checkpoint-green` |

The intermediate `stall-stop-green` still failed the genuine pending-versus-confirmed assertion; it is not GREEN evidence. Corrected the sender-entry stop state and reran the identical selector in `stall-stop-green-pending`. No assertion was weakened to hide this failure. No new watchdog duration/progress threshold, floor, tolerance, feedback await, motor owner, or stop acknowledgement was introduced.

Production changes in this continuation are limited to `S/Nav/NavigationController.swift` and `S/Nav/FollowScanDiagnosticTrace.swift`. Test migration is in `T/NavigationFollowScanDiagnosticsTests.swift`; this plan records completion. Full formula/attempt/physical-confidence telemetry and independent review remain Task 6, despite these necessary minimal runtime lifecycle corrections.

#### Complete diagnostics inventories and failure dispositions

Each full diagnostics inventory used the command above with the class selector, the same 60-second per-test limits, and a **900000 ms** shell bound:

| Bundle basename | Actual complete result |
| --- | --- |
| `at4-diag2-full-inventory-20261006` | **72 total / 51 passed / 21 failed / 0 skipped**. Legacy/constant-frame fixtures and obsolete pulse timing; old watchdog fixture indexed a missing pulse and crashed. Complete result bundle retained, not claimed green. |
| `at4-diag2-full-inventory2-20261006` | **72 total / 57 passed / 15 failed / 0 skipped**. Exposed pending-to-confirmed stop evidence and remaining trace/fixture issues. |
| `at4-diag2-full-inventory3-20261006` | **72 total / 69 passed / 3 failed / 0 skipped**. Isolated watchdog fake-clock timeout, recovery settle fixture clock ordering, and age-offset source fixture. |

Last three dispositions, verified together in **`at4-diag2-last-fixtures-20261006.xcresult`** (**3 passed / 0 failed / 0 skipped**):

- `testControllerTraceUsesActualWatchdogBoundaryResetAndNegativeErrorProgress`: a synthetic wall clock stopped a fraction below 2.5/5.0 because adding its remaining sub-ULP duration to the independent uptime rounded to the same value. Publish the exact simulated Date deadline tick when that timer fires; production wall semantics/thresholds are unchanged. Preserve the 0.049-versus-0.05 boundary, original checkpoint, negative error progress, two/three sends and exact 2.5-second terminal elapsed assertions. Guard fixture array accesses so an assertion failure cannot crash the runner.
- `testRecoveryDeadlineAndOwnershipAreRecheckedAfterEverySuspension`: advance the exposed common source clock before publishing the simulated capture. Previously publication ran while the exposed clock was old, manufacturing a future sample and failing health before the intended recovery deadline. All eight exact cancellation/send-count outcomes remain.
- `testTraceRetainsExactPrePostSourceProvenanceWithoutExtraReads`: 250 ms source-age offset requires intermediate captures before settle, so timer calls are split at freshness boundaries. Simulate post-stop movement at the actual ACK-plus-settle deadline rather than a single 300 ms sleep argument. Assert exact `8:3` / `8:6` identities, source times 100.05 / 100.43, collection times 100.3 / 100.68, 250 ms ages, source pairing and exactly one provider read.

The final-source boundary pair additionally passed **2 selectors** in `at4-diag2-final-source-fixtures-20261006.xcresult`; the pre-send/feedback source boundary group passed **3 selectors** in `at4-diag2-presend-source-fixtures-20261006.xcresult`. These are fixture/regression coverage, not additional production RED claims.

#### Final corrected-tree Task 4 exit

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationSafetyTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at4-diag2-full-task4-gate-20261006.xcresult
xcrun xcresulttool get test-results summary \
  --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at4-diag2-full-task4-gate-20261006.xcresult
git diff --check
```

Simulator: **iPhone 17 Pro / iOS 26.5**, UDID above. Shell bound **900000 ms**; actual Xcode test operation completed in **6.976 seconds**. Final xcresult summary: **144 total / 144 passed / 0 failed / 0 skipped / 0 expected failures**. Whitespace check passed. Final invocation emitted the existing empty-supported-platforms Xcode notice; the migrated never-mutated-yaw fixture warning was corrected before this gate. The pre-existing mutable-uptime burst fixture warning is not a production change.

Mechanically compared declared `func test...` names in each source file with unique `Test Case` identifiers from `xcresulttool get test-results tests` on this exact final bundle:

| Class | Declared | Executed | Passed | Missing / unexpected |
| --- | ---: | ---: | ---: | --- |
| `NavigationFollowTurnBurstTests` | 34 | 34 | 34 | none / none |
| `NavigationFollowScanDiagnosticsTests` | 72 | 72 | 72 | none / none |
| `NavigationRotationWatchdogTests` | 12 | 12 | 12 | none / none |
| `NavigationSafetyTests` | 26 | 26 | 26 | none / none |

This is the complete Task 4 class exit, not a selected-method checkpoint. No remaining failed selector or incomplete class inventory at this gate. Tasks 5–6 remain separate; no device behavior is inferred from simulator success.

### Task 5 strict matched-source checkpoint — 2026-10-06

**Task 5 remains unchecked and incomplete.** Implemented the boundary slices below under the user's Task-5-only authorization. Used `apply_patch` for every edit. Preserved prior uncommitted Tasks 1–4, other workspace changes, specifications and workflow assets. No Task 6 work, full SDK/app run, commit or device operation.

#### Implemented boundaries

- An optional internal source-clock companion supplies the controller's actual source uptime; original public `FollowMeMotion` conformers acquire no requirements. Missing source-clock/stop-fence facts remain unavailable and stopped. `NavigationFollowMeMotion` requests strict source capture for independent coordinator stops.
- A per-invocation stop-receipt capture forwards the controller's immutable ACK-return fence synchronously at its actual stop-return boundary. The coordinator merges its independent highest ingested sequence/timestamp, including pending/coalesced frames, only for the same generation. It does not look up a later mutable controller receipt or compare ACK uptime with the session clock.
- Initial alignment and final handoff wait for normal-continuity matched person evidence and its paired pose, strictly newer than the ACK, sequence/time high-water fence, and 300 ms settle. A cached detection cannot launch alignment, and an equal-ACK capture cannot authorize ready admission. The wait wakes on source ingress, settle, existing cancellation/outage/deadline handling; it does not poll pose or reset the episode.
- The pending-frame path evaluates association purely while a processor may be suspended, commits its original accepted snapshot, and hands it back to normal processing. Ready admission reuses the accepted decision, with health revalidation, rather than rematching against the adopted lock. Controller pose alone cannot replace matched-person authority.
- Synchronous controller detection inhibition now covers captured alignment as well as scan. The pending response still drains under controller motor ownership; the interrupted alignment returns cancelled instead of old arrival.
- Ready completion requires a distinct strictly post-ACK normal match after its newest final stop before establishing the fixed departure baseline. The ready wheel policy/watchdog and once-only consumed-attempt behavior were not changed. The real-controller fixture was corrected to simulate translation only after an actual forward send, rather than moving during alignment source waits.

#### Assertion RED → GREEN evidence

Commands ran from repository root on iPhone 17 Pro / iOS 26.5, simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Verified evidence parent: `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`. Every single-selector invocation used the exact template below with the row selector and bundle, serial 60-second test limits, and a 600000 ms shell bound:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/CLASS/SELECTOR \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BUNDLE.xcresult
```

Class **A** = `FollowReadyAdmissionIntegrationTests`; **N** = `NavigationFollowTurnBurstTests`.

| Class / selector | Actual behavioral RED | RED → single-selector GREEN bundle |
| --- | --- | --- |
| A / `testNewestAlignmentStopRejectsDeliveredLateAndEqualCaptureBeforeGenuineMatch` | Equal-ACK person capture started one ready preflight instead of zero; delivered-late earlier capture remains rejected, later genuine settled capture passes | `at5-newest-red` → `at5-newest-green` |
| A / `testAlignmentWaitsForPostDetectionStopMatchedSourceAndDoesNotStarvePendingProcessor` | Cached detection launched a second controller stop/operation before a new matched source | `at5-handoff-red` → `at5-handoff-green-source` |
| N / `testDetectionSynchronouslyFencesAlignmentDuringPendingResponse` | Detection-inhibited pending alignment returned arrival instead of cancelled | `at5-detection-red` → `at5-detection-green` |
| A / `testReadyFinalStopRequiresStrictNewCaptureBeforeFixedDepartureBaseline` | Distinct same-time final-ACK capture established waiting-for-movement baseline | `at5-baseline-red-valid` → `at5-baseline-green` |

Every valid RED executed one failed test. Every listed GREEN executed one passed test. The final corrected-tree selector set also reruns all four. `at5-handoff-green` was an intermediate failed run because the fixture omitted the source snapshot at its independent initial stop; explicit stored stop-snapshot provenance fixed the fixture, then the identical selector passed. `at5-baseline-red` failed at the fixture's simulated ready stall before reaching the intended baseline assertion; corrected the premature translation fixture and reran `at5-baseline-red-valid` **before** changing the production baseline gate. The valid RED's sole failure is the equal-ACK baseline assertion. No compile failure is counted as behavioral RED.

#### Final scoped gate, not complete Task 5 acceptance

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests/testNewestAlignmentStopRejectsDeliveredLateAndEqualCaptureBeforeGenuineMatch \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests/testAlignmentWaitsForPostDetectionStopMatchedSourceAndDoesNotStarvePendingProcessor \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests/testReadyFinalStopRequiresStrictNewCaptureBeforeFixedDepartureBaseline \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/FollowReacquisitionPlannerTests \
  -only-testing:PhroverKitTests/FollowReacquisitionDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowPipelineDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowAssociationDiagnosticsTests \
  -only-testing:PhroverKitTests/OperatorCommandRouterTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at5-boundaries-final-restored.xcresult
git diff --check
```

**93 passed / 0 failed / 0 skipped.** Shell bound 600000 ms; actual final test operation 9.187 seconds. `at5-boundaries-checkpoint` had 92 passed / 1 failed: its legacy-ready diagnostic fixture supplied no source stop evidence. `FollowMotionFake(clock:)` now explicitly opts into synthetic ACK uptime/fence facts; the pipeline test supplies genuinely advancing frames 310 ms apart. Legacy transport/controller-first-wheel telemetry stays unknown. The five-selector `at5-regressions-green` passed before the class rerun. `at5-boundaries-final` also passed 93; final-restored bundle above supersedes it after withdrawing the unsuccessful broad admission-fixture experiment.

#### Remaining blockers — do not infer they are all fixture-only

1. **Coordinator class exit is failed:** exact command template above with `-only-testing:PhroverKitTests/FollowMeCoordinatorTests`, bundle `at5-coordinator-checkpoint.xcresult`, 600000 ms shell bound: **107 total / 73 passed / 34 failed / 0 skipped**. Three tests hit the 60-second allowance: `testDetectionAtRealControllerSuspensionsFencesScanBeforeConfirmedAlignment`, `testDetectionFencesSuspendedAckBeforeQueuedAlignmentTaskCanRun`, `testTenSecondReacquisitionDeadlineFencesRealSuspendedPulseWithoutExtension`. The other failures include readiness/baseline/recovery handoffs using old unknown or same-time source, and real-controller fixtures still waiting for obsolete 200 ms pulse semantics. Isolate/migrate these fixtures and investigate each remaining genuine behavioral failure; retain original meaningful assertions.
2. **Complete admission class has no completed result:** command template above with `-only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests`, bundle `at5-admission-fixtures.xcresult`, serial 60-second test limits and **1800000 ms** shell bound. The shell terminated it after 30 minutes. A broad negative-origin/offset-frame setup experiment did not produce a complete result and was withdrawn; the original IDs/episode setup are retained. No admission-class count or successful full Task 5 exit is claimed. Before another full run, migrate individual suspended admission/recovery fixtures to actual stop/source events and release every controlled response.
3. **Further acceptance evidence remains:** highest-ingested pending/coalescing races, distinct source across detection/final-wrapper stops, accepted association/remembered-anchor retention across recovery, original 10-second expiry during every new wait, newest-task versus stale callback, unknown public conformers, and typed pending/confirmed/failed-stop priority need the full corrected coordinator/admission gate. The scoped pass does not certify all of these. Tasks 1–4's historical 144-test gate is not reused as final evidence for the modified tree.

Existing Xcode empty-supported-platforms notice and mutable-uptime Sendable test-fixture warning were observed. No full SDK/app/device gate or independent implementation review was performed. All Task 5 completion criteria remain governed by its unchecked checkbox.

Exact paths edited in this checkpoint: `S/FollowMe/FollowMeCoordinator.swift`, `S/FollowMe/FollowAdmissionSnapshot.swift`, `S/FollowMe/FollowMeDependencies.swift`, `S/FollowMe/NavigationFollowMeMotion.swift`, `S/Nav/NavigationController.swift`, `S/Nav/RotationDiagnosticModels.swift`, `T/FollowReadyAdmissionIntegrationTests.swift`, `T/NavigationFollowTurnBurstTests.swift`, `T/FollowPipelineDiagnosticsTests.swift`, `T/Support/FollowMeTestDoubles.swift`, and this plan.

### Task 5 coordinator complete gate — 2026-10-06

**Coordinator gate closed first, as requested. Task 5 remains unchecked pending admission acceptance.** This continuation supersedes only the preceding coordinator blocker. The full admission class was not rerun. No Task 6/full SDK/app/build/device work or commits. Only `T/FollowMeCoordinatorTests.swift`, `T/Support/FollowMeTestDoubles.swift` and this plan were edited, using `apply_patch`. **No production code was changed, and no new production assertion RED → GREEN cycle is claimed.** Existing class failures were used to identify fixture causes, not relabeled as specific production-bug RED evidence.

#### Actual failure inventory and dispositions

Read `xcresulttool get test-results summary` for `at5-coordinator-checkpoint.xcresult`: 107 executed, 73 passed, **34 failed**, including these three 60-second timeouts:

- `testDetectionAtRealControllerSuspensionsFencesScanBeforeConfirmedAlignment`
- `testDetectionFencesSuspendedAckBeforeQueuedAlignmentTaskCanRun`
- `testTenSecondReacquisitionDeadlineFencesRealSuspendedPulseWithoutExtension`

Inspected their actual source and the other 31 failed selectors before migration. Causes and narrow corrections:

1. **Legacy/contextual fake stopped-source provenance:** affected readiness/recovery setups had no synthetic source clock/fence, and supplied frames at timestamp zero or the same timestamp as their new ACK. The fake can now explicitly bind a `ManualFollowClock`; its contextual/absolute-heading companions forward that same optional source uptime. Unbound fakes continue to report unknown source facts. Stop ACK capture still occurs at actual fake stop return, including suspended-stop release, and coordinator ingress supplies the complete pending sequence/time high-water mark.
2. **Deliberate matched captures:** `matchedBoundaryFrame` emits exactly one requested frame with its paired pose/person after an explicit manual-clock advance. Default advancement is 301 ms, clearing both strict `timestamp > ACK` and 300 ms settle. It has no loop, automatic camera pumping or provider-read advancement. Initial acquisition helpers retain the full five-second pause and provide distinct detection/pre-alignment/final-alignment/final-ready frames. Zero-pause tests keep their explicitly configured zero pause. Downstream timestamps now use the actual updated clock; outage deadlines are measured from the actual first outage and recovery deadlines from the actual first loss, never renewed by helper captures.
3. **Newest pending stop fence:** the held-stop alignment test continues ingesting pre-ACK matched frames, asserts they cannot launch alignment, then explicitly supplies a settled post-ACK frame. Final-stop equality still rejects readiness; a subsequent distinct source permits the once-only signal, and another post-ready-stop source establishes baseline. Pending conflict tests keep ambiguous candidates ambiguous and require an additional post-alignment-stop match before restoration.
4. **Ready/departure semantics:** preserved the exact 0.3 m departure increase, .299 m rejection, approach/lateral nondeparture, original fixed baseline across recovery, range/clearance gates, single ready attempt, cancellation/safety outcomes and terminal failures. Additional source frames legitimately change the restored/reliable frame ID; diagnostics assertions now name that actual newly accepted frame while retaining the original frozen anchor ID and deadline.
5. **Real controller fixtures:** old source providers fabricated timestamps on reads while reusing sequence 100, and timeout fixtures waited for a no-longer-active 200 ms pulse. They now return a stored immutable sample and explicitly ingest actual synthetic captures at controlled timer/command-response boundaries. `CoordinatorTurnSource` has a finite capture bound (sequence below 160), no read-side advancement, and publishes only at an invoked simulation boundary. The watchdog fixture remains flat-yaw and proves it actually sent before the unchanged measured-progress failure. Its Date watchdog advances independently of the common source-uptime clock.
6. **Real finite recovery pass:** preserve the independently asserted `[-90, -75, -105, -60, -120, -45, -135]°` stage list, negative first burst/positive correction, final 7° tolerance and exhausted-pass no-resend. The first synthetic response still overshoots. Later responses complete the frozen controller target, with actual captured crossing before command return. A bounded 20 ms synthetic capture-delivery lag avoids inventing an instantaneous 700 rad/s AR response from adjacent 1 ms fixtures; source frames remain age-valid and strictly post-stop. The original ten-second budget stays active and consumes all settle/source time. This is synthetic response coverage, not physical calibration.
7. **Three timeout boundaries:** use finite yielding reach assertions instead of unbounded `waitUntilEntered` when setting up the intended held response/getter. All held responses are released. Detection tests cover real pending send, remaining ≤80 ms budget wait, pulse-stop ACK and post-burst settle, then explicitly emit two new matched/source frames for detection-stop and controller-initial-stop handoff. The queued ACK test now reaches the actual enriched-source ACK getter and verifies synchronous detection fencing prevents its send. The ten-second test holds the actual burst sender, keeps camera freshness through deliberate scheduled frames, expires at original first-loss +10 s, drains the held sender and asserts no resend or added motor wait.

The old wait assertions were migrated to the actual new lifecycle, not removed: remaining motor wait is positive and ≤80 ms when entered, no 200 ms wait executes, pending-send cancellation enters no motor wait, and only the mandatory initial settle occurs before the deadline test's cancellation. Alignment now also emits captured-purpose operation records; the detection table asserts exactly one scan operation and one alignment operation separately.

#### Bounded selector/group evidence

All invocations ran at repository root, simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, serial **60-second** test limits and **600000 ms** shell bound. Result bundles are under the previously verified evidence directory. Each used this template with the named method selector(s), repeated `-only-testing` for groups:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests/SELECTOR \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BUNDLE.xcresult
```

| Bundle | Covered narrow selectors | Result |
| --- | --- | --- |
| `at5c-ready-fixture` | Once-only ready, strict final baseline and exact departure gate | 1 passed |
| `at5c-fixture-group1` | Too-close, cached/future step-back, healthy clearance, cancelled alignment, expired pause, lateral/toward movement, two-second outage, new generation alignment, local Stop | 9 passed |
| `at5c-fixture-group2` | Contextual purposes/phases, approach during ready, both loss/ready orderings, cancelled/unsafe/stale/local-stopped ready, production fixed baseline sequence | 6 passed |
| `at5c-fixture-group3` | Clearance heading drift, frames across every held stop, delayed/incorrect-heading baseline, scan detection without blocked perception | 4 passed |
| `at5c-fixture-group4` | Incomplete recovery readiness/baseline, inclusive .05 rad, final stop deadline, pending detection conflict, credible restoration phases, original loss deadline, retained departure baseline | 7 passed |
| `at5c-fixture-group5` | Two recovery diagnostics selectors | 1 passed / 1 failed: remaining reliable-frame literal still named old frame 4 instead of the newly required frame 5; corrected test-only |
| `at5c-real-fixture-group` | Corrected diagnostic selector plus two real controller selectors | Diagnostic passed; two real fixtures failed because their synthetic timer/source schedule inflated response latency/rate and reached typed resolution before the intended watchdog/pass |
| `at5c-real-fixture-timed` | Actual flat-yaw watchdog and finite overshoot recovery pass, after controlled timer/capture correction | 2 passed |
| `at5c-deadline-fixture` | Original ten-second expiry during actual pending send | Failed solely because old no-settle assertion excluded mandatory initial settle; corrected to exactly one initial settle |
| `at5c-timeout-fixtures-pair` | Queued actual ACK fencing and corrected pending-send deadline | 2 passed |
| `at5c-detection-phases-fixture` | Four real detection suspension variants | Failed only at pulse-fixture reach assertion: binary floating-point duration slightly exceeded literal .080; phase-selection tolerance corrected by 1 ps, motor-policy assertions unchanged |
| `at5c-detection-phases-green` | Same four variants, identical selector | 1 passed |

These overlapping groups are diagnostic checkpoints, not summed into a fictitious full-suite count. The complete corrected-tree gate below supersedes every intermediate failure.

#### Complete corrected-tree coordinator gate and process check

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at5c-coordinator-full.xcresult
xcrun xcresulttool get test-results summary \
  --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at5c-coordinator-full.xcresult
xcrun xcresulttool get test-results tests \
  --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at5c-coordinator-full.xcresult
rg -c '^    func test' swift/Tests/PhroverKitTests/FollowMeCoordinatorTests.swift
pgrep -fl 'xcodebuild|xctest'
git diff --check
```

**107 total / 107 passed / 0 failed / 0 skipped / 0 expected failures.** Actual Xcode test operation **6.208 seconds**, shell bound 600000 ms. Mechanically traversed xcresult `Test Case` nodes: **107 executed, 107 unique selectors, 107 passed, no nonpassed selector**; source declares **107** test methods. No orphaned `xcodebuild` or `xctest` matched the named check after the call. Whitespace check passed. Existing Xcode empty-supported-platforms notice and mutable-uptime Sendable warning in the separate burst fixture remain.

**Remaining Task 5 gate:** isolated strict-source migration and complete acceptance of `FollowReadyAdmissionIntegrationTests`, with the planned ready/controller companion gate. The historical 93-test scoped boundary pass is not relabeled as a new corrected-tree admission-class result. The earlier incomplete 30-minute admission bundle remains incomplete historical evidence. No new admission full run occurred in this coordinator-first continuation, and Task 5 is not checked from the 107-test result alone.

### Task 5 admission acceptance / complete exit — 2026-10-06

**Task 5 is complete at its scoped software gate. Task 6 is unstarted.** This supersedes all preceding Task 5 partial statuses. Continued only Task 5 after the coordinator's 107-test gate, preserving previous work and repository assets. Changes in this continuation are `S/FollowMe/FollowMeCoordinator.swift`, `T/FollowReadyAdmissionIntegrationTests.swift`, and this plan, all through `apply_patch`. No full SDK/app/build, independent implementation review, commit, push, device execution or physical acceptance.

#### Inventory and isolated diagnosis before full admission execution

Attempted to read the earlier `at5-admission-fixtures.xcresult` with `xcresulttool get test-results summary`. It has no `Info.plist`, so no completed selector inventory/count can be recovered. It remains an incomplete historical 30-minute attempt, not a retryable green gate. Enumerated every admission test from current source instead: **41 existing methods**, then **42** after adding one regression below. Kept the full class unexecuted until every source selector had narrow passing coverage and the known hanging setup was corrected.

Ran `testLatestClosePersonDuringRealReadyFeedbackDefersWithoutSending` alone using serial **10-second diagnostic limits**, 600000 ms shell bound, bundle `at5a-close-diagnosis.xcresult`. Its intended held ready getter never became reachable: the initial detection was at the stop ACK, with no new matched/source frames to clear independent and controller-initial alignment stops. Xcode's overall test operation took 135.813 s despite the individual allowance; no narrow timeout is claimed to be a reliable overall shell bound. Corrected the fixture before rerunning the identical selector with the ordinary serial 60-second limits in `at5a-close-fixture.xcresult` (one passed).

#### Strict source / clock / held-response fixture corrections

- `acquire(aligned:)` explicitly emits two matched/source capture events 301 ms apart to clear independent and controller-initial stops. It asserts the final alignment stop was actually reached and that the controller arrival sample did **not** launch ready. It then advances only the manual clock; the test's next actual person frame is required to clear the final alignment ACK. The three original stop-boundary regressions and first-loss recovery setups opt out and retain individually scripted source captures.
- Camera providers now return a **stored immutable controller sample**. Explicit capture calls, detector delivery and simulated movement boundaries update it; provider reads never advance source IDs/timestamps or reconstruct pose from mutable fields. Controller-only yaw/forward corrections and generation/pairing tests now inject their explicit captured source at the intended post-feedback seam. AR/source uptime is the same injected manual-clock domain; the Date clock remains the existing progress/communications clock.
- Logical test event IDs are mapped once to actual monotonically allocated camera IDs, reserving real IDs for setup and controller-only movement captures. Replayed logical events keep their original ID and do not overwrite a newer camera snapshot. Assertions name the actual emitted IDs. This prevents a baseline test from accidentally replaying the controller's last movement frame. No alias changes source health, source time or admission decisions.
- `fresh` supplies exactly one requested event after a 301 ms clock advance. `recoverReady` scripts detection plus three distinct matched events for detection-stop, controller-initial-stop and final-alignment-stop fences. Neither helper pumps frames indefinitely, invokes the admission callback, assumes acceptance, clears attempt flags, or renews an episode. Ready baseline and restart tests explicitly provide their own new post-final-stop frames.
- Malformed detector batches remain malformed; these admission tests independently provide a known normal controller AR capture, so stale/future/nonfinite/unknown-tracking person authority cannot be rescued by healthy controller pose. Relative stale/future timestamps and 500 ms boundaries now use the actual post-setup clock rather than obsolete zero-time literals. Original first-loss ten-second expiry is retained, and two-second outage tests are measured from the actual first outage.
- Held boundaries use a finite reach assertion rather than an endless `waitUntilEntered` loop. Unexpected setup failure is an XCTest assertion. Intended pending frames resume the held getter at their ingress clock callback, rather than releasing transport before the event is even ingested. Every scripted held command/getter/stop is released.
- Heading deferral supplies new captures for each initial/terminal alignment stop, including a real stored corrected-yaw source, before ready can resume. The test still proves one alignment burst and one ready signal; it does not change the ready wheel speed, measured-progress watchdog or physical motor-stall behavior.

#### Production corrections: new executed assertion RED before edits

New selector: `PhroverKitTests/FollowReadyAdmissionIntegrationTests/testPendingUnknownTrackingReportsNewestFrameHealthAtActualReadyBoundary`.

1. **Snapshot loss on early denial:** `at5a-pending-snapshot-red.xcresult` is a compiled one-test assertion failure: an actual callback reported `pending_frame_evaluation = not_evaluated`, omitting the newest transaction when the frame processor had already replaced the request. Before changing production, the test was executed and the exact failure read from xcresult. The validation closure now captures the actual newest immutable observation snapshot before its authority guards, strictly as evidence. Existing ownership, cancellation, health, newest-stop chronology, generation and episode guards remain mandatory; facts cannot authorize a stale request. Snapshot health/association rejection is evaluated before reporting a generic post-stop chronology rejection, preserving the actual cause.
2. **Observation cause versus ownership cause:** extended the same new selector before the next edit. `at5a-observation-cause-red.xcresult` reports one failed test, with `observation_rejection_condition = nil` instead of `tracking_unknown`. Added that one nullable existing-lifecycle payload fact from `snapshot.rejection`; the primary `rejection_condition` remains the real authority denial. This is minimal Task 5 handoff evidence, not Task 6 burst telemetry or a change to the shared terminal-failure formatter.

Both production edits were preceded by compiled, executed new assertion failures. Final identical **single selector**, using the same 10-second diagnostic test flags, passed in **`at5a-pending-snapshot-final-green.xcresult` (1 passed / 0 failed)**. It is also included in the complete admission/Task 5 gates. Two production assertion iterations in one regression selector; no missing-symbol/build failure is counted as RED.

The test and unsafe-source table now verify the real permitted delivery orderings rather than demanding fabricated callback telemetry after cancellation:

- When admission evaluates a pending frame, require its exact frame ID, evaluated snapshot and specific source/association cause; zero send and unconsumed attempt remain asserted.
- When the processor already stopped/replaced the request but a callback still runs, require `not_pending`, the specific captured observation cause and exact `operation_replaced` authority denial. A processed accepted decision retains its original unique candidate count; rematching against the updated lock would count two and still fails the test.
- If cancellation prevents the controller from reaching admission at all, require an actual additional serialized stop, no authorization/send/consumed attempt, the exact perception issue or recovery phase, and original association candidate rejection facts. Do not invent an `admission_rejected` record for a callback that never ran.

Original motion-blocking, confidence/world/screen/generation rejection, no-fallback, frozen-memory, baseline, range and no-retry assertions remain. No source is relabeled healthy to pass a gate. Failed stop and typed resolution precedence are covered unchanged by the final failure-reduction class.

Intermediate evidence is retained, not counted as completed cycles: initial `at5a-pending-health-red` released the getter before guaranteed ingestion; its assertion exposed that fixture ordering rather than the final snapshot contract. `...pending-health-red-ordered...` and `...pending-snapshot-green...` assumed one particular processor ordering. `...observation-cause-green...` reached cancellation before the callback, so no callback record existed; lifecycle assertions were corrected to require the real independently stopped outcome instead. These failed experiments are not substituted for final acceptance and are not automatic retries of the final gate.

#### Bounded group evidence before the full class

All bundles are in `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`, simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, iPhone 17 Pro / iOS 26.5. Commands used repository root, `xcodebuild test -quiet -scheme astral-sdk-Package`, the same destination, `-parallel-testing-enabled NO -test-timeouts-enabled YES`, both per-test allowances **60**, individual/group `-only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests/SELECTOR`, and 600000 ms shell bounds. Diagnostic single REDs used allowances **10**. Every group used only the named methods, not a full-class shortcut.

| Bundle | Executed group / disposition |
| --- | --- |
| `at5a-admission-group1` | 9 passed: controller-only correction/generation/pairing, exact 500 ms age/heading, expired person versus fresh independent pose, one pending owner |
| `at5a-admission-group2` | 8 passed / 4 failed: identified pending-frame release ordering, the additional ready movement camera ID at baseline, and missing strict source events after interruption |
| `at5a-admission-group2-corrected` | 4 passed / 3 failed: stop-boundary regressions and interruption passed; remaining failures exposed actual snapshot/ownership-reporting behavior and retained processed association counts |
| `at5a-pending-snapshot-group` | 3 passed / 1 failed: unsafe table still released a getter before guaranteed ingestion in one variant |
| `at5a-pending-ordered-fixtures` | 2 passed / 1 failed: unsafe table assumed pending processing after actual outage/ownership stop; motion-blocking assertions remained satisfied |
| `at5a-pending-lifecycle-green` | 3 passed: exact new snapshot/observation-cause contract, unknown tracking, all 14 unsafe-source variants with real pending/processed/cancelled outcomes |
| `at5a-recovery-group` | 5 passed: pending association retention/invalidation, scan/getter detection fencing, original deadline through ready, normal-baseline restoration, unconsumed clearance deferral and frozen memory |
| `at5a-admission-group3` | 11 passed: finalized receipt/full pause, both restart fences, healthy-frame handoff without starvation, shared summary budget/counts, synthetic pipeline/clearance/departure, actual send-boundary diagnostics, no repeated ready after loss, heading correction and exact clearance gate |

The original three strict stop-boundary methods passed again in the corrected narrow group, then every selector—including the one initially isolated—was included in the complete gates below. Intermediate groups overlap; their counts are not summed as independent suite coverage.

#### Full admission class, then complete Task 5 exit

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at5a-admission-full.xcresult

xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  -only-testing:PhroverKitTests/NavigationSafetyTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/FollowPipelineDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowAssociationDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/FollowReacquisitionPlannerTests \
  -only-testing:PhroverKitTests/FollowReacquisitionDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowTargetTrackerTests \
  -only-testing:PhroverKitTests/OperatorCommandRouterTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at5-task5-exit.xcresult
xcrun xcresulttool get test-results summary \
  --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at5-task5-exit.xcresult
pgrep -fl 'xcodebuild|xctest'
git diff --check
```

- **Full admission: 42 passed / 0 failed / 0 skipped / 0 expected failures**, Xcode test operation **6.484 seconds**. No class retry.
- **Complete Task 5 exit: 365 passed / 0 failed / 0 skipped / 0 expected failures**, Xcode test operation **13.601 seconds**. No class retry or test rerun within this bundle. Both shell bounds were 600000 ms, serial per-test bounds 60 s.
- Mechanically extracted declared `func test...` names with `rg --json` from the 15 source files, traversed exact `Test Case` names/results from this final xcresult and compared the sets per class. **No missing, unexpected or duplicate selector in any class.** This is exact name comparison, not inferred coverage from a selected-method checkpoint.

| Class | Declared / executed / passed |
| --- | ---: |
| FollowMeCoordinatorTests | 107 / 107 / 107 |
| FollowReadyAdmissionIntegrationTests | 42 / 42 / 42 |
| NavigationFollowReadySignalTests | 17 / 17 / 17 |
| NavigationFollowTurnBurstTests | 35 / 35 / 35 |
| NavigationFollowScanDiagnosticsTests | 72 / 72 / 72 |
| NavigationRotationWatchdogTests | 12 / 12 / 12 |
| NavigationSafetyTests | 26 / 26 / 26 |
| FollowMotionFailureResolutionTests | 5 / 5 / 5 |
| FollowPipelineDiagnosticsTests | 8 / 8 / 8 |
| FollowAssociationDiagnosticsTests | 7 / 7 / 7 |
| FollowDiagnosticEventTests | 9 / 9 / 9 |
| FollowReacquisitionPlannerTests | 8 / 8 / 8 |
| FollowReacquisitionDiagnosticsTests | 2 / 2 / 2 |
| FollowTargetTrackerTests | 7 / 7 / 7 |
| OperatorCommandRouterTests | 8 / 8 / 8 |
| **Total** | **365 / 365 / 365** |

Named process checks after calls found **no orphaned `xcodebuild` or `xctest`**. `git diff --check` passed. Only documentation and whitespace-only indentation cleanup followed the complete exit; executable Swift tokens were unchanged. Existing Xcode empty-supported-platforms notice and the separate mutable-uptime Sendable burst-test warning remain; no final compile error, failed selector, missing test or timeout.

**Handoff to Task 6:** no remaining Task 5 software gate blocker. Task 6 must still add/verify its structured burst telemetry, obtain genuinely independent implementation review, and run the corrected affected/full non-live SDK/app/unsigned build gates. Simulator source/transport fixtures do not establish physical motor-on timing, coast bounds, reliable 3° correction, or device readiness performance. No unrelated ready-speed/motor-stall change or physical acceptance is claimed by this completion.

### Task 6 telemetry slice only — 2026-10-06

**Partial Task 6.** Implemented the explicitly requested telemetry slice before independent review/final whole-SDK gates. Tasks 1–5 and their historical evidence remain intact. No independent reviewer, whole SDK, app tests/build, commit, push, or device operation is claimed by this continuation. All edits used `apply_patch`; the approved 203-line spec, `CONTEXT.md`, existing workflow assets and unrelated working-tree changes were preserved.

#### Captured diagnostic contract

`FollowTurnBurstDiagnosticTrace` is a bounded, operation-local, read-only projection. It owns no clock/provider, motor authority, wait, retry, or logger await. The controller supplies actual planning, sender entry/return, transport entry, source event, stop admission/fence, and runtime watchdog facts. Structured emission keeps schema version 1, existing `follow_scan.*` events/fields, context/purpose, UTC correlation and legacy stage labels; new lifecycle events are additive. Controller phase is an additional field, distinct from the coordinator's captured phase.

- Both follow purposes capture their selected budget/tolerance, frozen target, fixed signed 0.25 magnitude/floor and inactive gain. Active maximum is 80 ms; the 200 ms value is explicitly historical/inactive, never an active requested wait. No request floor is introduced. Initial 3° alignment logs the worked 1.126758536 ms reference probe, not a 20 ms request or a physical accuracy guarantee.
- Formula/units/provenance, `R0`, retained `R`, net/source interval and maximum consecutive rate, effective response-per-budget rate, separate measured send/stop maxima, `A`, sampled partial/unknown `C`, overshoot excess/distance/ceiling and rejection reasons are captured. Measured host latency without yaw remains reference-only rate confidence, not observed rate or measured zero coast. Rejected/coalesced evidence never learns a rate/coast. Source brackets retain actual frame IDs, capture/collection timestamps, ages, source identity, tracking and health; post-ack endpoints are strictly after the actual stop ACK. Bounds are 128 samples / 127 intervals / three exposed attempts.
- 100 ms ACK for an 80 ms request logs 20 ms overrun and zero requested/actual extra wait. 30 ms ACK requests only remaining 50 ms; source crossing can interrupt after an actual 20 ms wait. Logical budget-expiry obligation and the actual observed wake/return uptime are separate. Pending-send crossing is recorded before response, without admitting a parallel stop. Stop admission, pending drain, acknowledgement return and obligation-to-ACK duration include serialization.
- Source admission records actual stop UUID/generation/frame/time high-water fences, rejection or acceptance, 300 ms settle/ACK-to-evaluation/source-wait intervals and preserved 500 ms / two-second / ten-second limits. Rejection records are deduplicated by reason/fence (maximum 16), rather than full healthy per-frame emission. A 32-frame healthy-ingress fixture proves unchanged diagnostic event count, one provider seed read, and all 34 actual bracket samples retained through the controller. Expired source timestamps/quality are preserved verbatim, never refreshed by diagnostic reads.
- Actual watchdog checkpoint wall milliseconds and Date-based elapsed clock are distinguished from event-lifetime host monotonic timing, AR/system uptime and transport UTC. Recovery cursor indices are immutable correlation-only optional request facts supplied by the coordinator; they do not advance stages or affect authorization. Unavailable indices remain null with `not_supplied`.
- Typed terminal resolution fields survive result/stream/shared failure reduction and generic wrappers, including actual controller phase and explicit unknown correlation. Authoritative stop confirmation alone permits confirmed text; failed stop stays sticky at priority 3 with blocked-motion wording. New burst entry clears earlier per-burst response/stop facts while retaining operation maxima and shrink provenance.
- Added source/tracking labels on planner samples are diagnostic only. The original public initializer and exact-boundary equality semantics are retained; an additive overload supplies labels without altering calibration/motor policy. No attempts, safety/watchdog/outage/recovery thresholds, command law, target policy, or ready-motion policy changed.

#### Compiled assertion RED → identical-selector GREEN

All commands ran at repository root, iPhone 17 Pro simulator / iOS 26.5 / UDID `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Evidence parent was verified: `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`. Every row used this exact narrow command, substituting its full selector and basename, RED before the relevant production patch and then identical selector GREEN (120000 ms shell bound):

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -only-testing:PhroverKitTests/CLASS/METHOD \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BASENAME.xcresult
```

Selector abbreviations: **D** = `NavigationFollowScanDiagnosticsTests`, **C** = `FollowTurnBurstControllerTraceTests`, **F** = `FollowMotionFailureResolutionTests`, **R** = `RoverControlTests`, **E** = `FollowDiagnosticEventTests`. Each listed RED summary is **1 total / 0 passed / 1 failed / 0 skipped**; each authoritative GREEN summary is **1 total / 1 passed / 0 failed / 0 skipped**, mechanically verified with `xcresulttool`. **17 assertion cycles across 14 distinct selectors**; the healthy-ingress fixture additionally verifies the existing bounded-emission contract in the complete exit, without a separate RED claim.

| Selector (`CLASS/METHOD`) | Observed diagnostic assertion RED | RED → authoritative GREEN basename |
| --- | --- | --- |
| D/testRuntimeBurstTraceCapturesLateAckAndOnlyActuallyEnteredWaits | Missing selected budget/overrun/zero-wait/clock/physical-unknown facts | `at6-timing-red` → `at6-timing-green` |
| D/testOvershootTraceRetainsMeasuredAllowancesAndUnknownCoastThroughResolutionFailure | Missing plan/response model record | `at6-model-red` → `at6-model-green-fixed` |
| C/testPendingCrossingRecordsObligationBeforeAckAndSerializedStopFence | Missing pending crossing obligation and serialized confirmed fence | `at6-crossing-red` → `at6-crossing-green` |
| C/testStoppedSourceExpiryKeepsOriginalCaptureAndReportsFenceRejection | Missing actual expired capture/fence rejection record | `at6-source-red` → `at6-source-green` |
| C/testThirtyMillisecondAckRequestsOnlyRemainingBudgetAndSourceWakeRecordsActualWait | Missing requested/actual interrupted wait and wake record | `at6-wait-red` → `at6-wait-green` |
| C/testSampledPostAckTravelReportsActualEndpointSourcesAndIntervals | Missing actual post-ack endpoint IDs/source identities/tracking | `at6-coast-red` → `at6-coast-green-fixed` |
| D/testDroppedResponseFrameCannotBecomeObservedRateOrCoastInTelemetry | Missing explicit ineligible rate bracket status | `at6-invalid-red` → `at6-invalid-green` |
| F/testResolutionTelemetrySurvivesGenericWrapperAndStickyFailedStopWithoutLosingControllerPhase | Shared reducer discarded typed model/phase facts | `at6-failure-red` → `at6-failure-green` |
| R/testControllerTraceRecordsActualAttemptAndExpiredBackoffWithoutRetryOrInventedAck | Missing bounded expired sender outcome/denial despite one actual transport entry | `at6-transport-red` → `at6-transport-green` |
| D/testThreeDegreeProbeTraceUsesReferenceOnlyAndSubMillisecondExcessWithoutInventedFloor | Missing explicit no-floor/reference provenance | `at6-probe-red` → `at6-probe-green` |
| E/testMeasuredHostLatencyWithoutYawCannotBeReportedAsObservedRateOrZeroCoast | Measured host-only response incorrectly labeled observed rate | `at6-confidence-red` → `at6-confidence-green` |
| C/testFeedbackDelayPastDeadlineIsNotReportedAsAdditionalMotorWait | Feedback suspension incorrectly reported 100 ms actual added wait | `at6-feedback-red` → `at6-feedback-green` |
| C/testSampledPostAckTravelReportsActualEndpointSourcesAndIntervals (extended) | Missing maximum consecutive candidate and net source interval | `at6-rate-red` → `at6-rate-green` |
| D/testNextBurstKeepsOperationMaximaButDoesNotRelabelPreviousResponseAsCurrent | Second send inherited previous response/endpoints/outcome instead of unknown current facts | `at6-next-red` → `at6-next-green` |
| D/testRecoveryDiagnosticStreamUsesCapturedControllerReadsAndActualFinalYaw | Missing captured stage/segment cursor indices | `at6-cursor-red` → `at6-cursor-green` |
| D/testRuntimeBurstTraceCapturesLateAckAndOnlyActuallyEnteredWaits (extended) | Missing actual observed obligation uptime separate from logical deadline | `at6-observed-red` → `at6-observed-green` |
| D/testOvershootTraceRetainsMeasuredAllowancesAndUnknownCoastThroughResolutionFailure (extended) | Shared failure delivery omitted explicit null episode/stage/segment correlation | `at6-delivery-red` → `at6-delivery-green` |

Intermediate dispositions: `at6-model-green` failed compilation on an optional Date checkpoint; `at6-coast-green` failed Swift expression type checking. Both were corrected and rerun with the identical selector before accepted GREEN; neither is behavioral RED/GREEN. The source rejection test's expected vocabulary was corrected to the existing verbatim `stale_source` before GREEN, while its RED was genuinely the absent record. The first eight-class exit `at6-telemetry-scoped` reported **181 passed / 1 failed / 0 skipped**, solely the old exact lifecycle list in `testCompletedPulseTraceUsesExistingSamplesExactHostTimingAndCapturedContext`. Its expected order now includes the additive bounded events; all original source, timing, receipt, schema, profile, context and one-read assertions remain. `at6-telemetry-scoped-complete` passed **290 / 0 / 0** but was followed by shared-delivery correlation/API-compatibility completion; it is superseded by the corrected-tree exit below.

#### Complete corrected-tree telemetry exit (before independent review)

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/FollowPipelineDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/FollowTurnBurstControllerTraceTests \
  -only-testing:PhroverKitTests/RoverControlTests \
  -only-testing:PhroverKitTests/FollowTurnBurstPlannerTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-telemetry-exit.xcresult
xcrun xcresulttool get test-results summary --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-telemetry-exit.xcresult
xcrun xcresulttool get test-results tests --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-telemetry-exit.xcresult
git diff --check
```

**Final corrected-tree result: `at6-telemetry-exit.xcresult` — 290 passed / 0 failed / 0 skipped.** Complete class inventory: burst **35**, controller diagnostics **76**, diagnostic envelope **10**, pipeline diagnostics **8**, failure reduction **6**, new controller trace fixtures **6**, real sender **28**, planner **14**, coordinator **107**. Mechanically compared all declared method names with the final xcresult: **290 declared / 290 executed exactly once; no missing, unexpected or duplicate selectors**. `git diff --check` passed. Only this documentation completion record changed after the exit; no executable tokens changed.

Exact files changed by this telemetry slice (pre-existing Task 1–5 changes in these files are preserved):

1. `S/Nav/FollowTurnBurstDiagnosticTrace.swift` — new bounded projection.
2. `S/Nav/FollowScanDiagnosticTrace.swift`
3. `S/Nav/RotationDiagnosticModels.swift`
4. `S/Nav/NavigationController.swift`
5. `S/Nav/FollowTurnBurstExecutor.swift`
6. `S/Nav/FollowTurnBurstPlanner.swift`
7. `S/Nav/FollowTurnBurstObservation.swift`
8. `S/Nav/FollowTurnSourceGate.swift`
9. `S/FollowMe/FollowMotionFailureResolution.swift`
10. `S/FollowMe/FollowMeCoordinator.swift`
11. `S/FollowMe/FollowRecoveryMotion.swift`
12. `T/NavigationFollowScanDiagnosticsTests.swift`
13. `T/FollowTurnBurstControllerTraceTests.swift` — new six-method class.
14. `T/FollowDiagnosticEventTests.swift`
15. `T/FollowMotionFailureResolutionTests.swift`
16. `T/RoverControlTests.swift`
17. `README.md`
18. This plan.

Warnings observed during final compilation: mutable-`uptime` Sendable capture in `T/NavigationFollowTurnBurstTests.swift:510`, unused `allocate()` result in `S/SilentSearch/OpticalProtocolSession.swift:126`, and Xcode's empty-supported-platforms notice. These source locations were not edited by this telemetry slice. No new diagnostic compile warning is claimed. Compile failures above were corrected, not counted as RED. Remaining risks are pending transport drain/serialized stop latency, unknown physical activation and unsampled coast, and conservative terminal small-angle resolution after measured response. Simulator results do not certify physical 80 ms control or universal 3° correction. **Independent review, post-review final affected exit, whole non-live SDK, app tests/unsigned build and device acceptance remain pending.**

### Task 6 independent-review fixes — 2026-10-06

Addressed the two supplied review findings at the user-specified real-controller operation and diagnostic seams. Three sequential compiled behavioral RED → GREEN slices were executed, with each RED run preceding its corresponding production patch.

**High — interruptible actual ACK reads.** Follow-only runtime refresh and stopped-source admission now use an owner-scoped read-only ACK slot. At most one outstanding getter exists for the current operation; concurrent consumers reuse it. The uncooperative getter is not joined on budget/source/authority/caller interruption. Completion fills only its own slot and wakes waiters only if both slot identity and operation owner still match; it never clears a newer slot, mutates runtime, sends motors, or certifies arrival. Completed synchronous reads bypass the read-wait timer. Retained source triggers are checked before reading. The existing executor remains the sole serialized burst-stop owner, and actual pending SEND still drains before STOP. Watchdog remaining time is taken from the current progress epoch, not a copied pre-suspension checkpoint. Date watchdog epochs remain Date-based; source freshness, SEND budget and stop capture remain in the injected AR/system-uptime domain; recovery remaining time is translated from its own authorization clock.

The active regression runs crossing, budget expiry, wall-watchdog expiry and caller cancellation with SEND entry 10.300 / response 10.330 and the getter held. It asserts stop count **before** releasing that getter at 10.600, then drains late completion and asserts one send / two total stops. Its final budget-expiry scenario explicitly releases a held budget timer at 10.381 without another source event. The stopped-source regression asserts watchdog/recovery terminal completion while its getter is still held, before cleanup release. No late read can renew the checkpoint or append motor work.

**Medium — stopped arrival independent of learnability.** After confirmed stop and strict fresh stopped-source admission, the executor rechecks authority/cancellation and runtime failure, retains the calibration reduction diagnostic, and evaluates inclusive actual target error before treating rejected calibration as terminal resolution failure. Missing/coalesced brackets remain rejected and never learn. Outside-tolerance rejected evidence still returns `rotationResolutionInsufficient`, with no calibration retry. Arrival retains its planning diagnostic. The new trace regression covers the supplied frame-2 → frame-4 gap followed by strict post-stop frame 5, exact target arrival, exactly 0.05-rad alignment error, exactly 7-degree scan error, and outside-tolerance rejection. Every case asserts one send / two stops, rejected bracket, zero completed calibrated responses, and unchanged provisional R = 2π/3. Existing unhealthy-source, failed-stop, owner replacement, source freshness and recovery-expiry tests all pass in the complete inventory. Fixed signed wheel magnitude 0.25 and global 0.080-s cap were not tuned; generic navigation paths were not changed.

#### Executed RED → GREEN commands and totals

All commands ran from the repository root on iPhone 17 Pro / iOS Simulator 26.5, UDID `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Verified the evidence parent before running. Each row used the exact command template below with its selector and bundle, first RED then GREEN:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/SELECTOR \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BUNDLE.xcresult
```

| Selector | Observed behavioral RED | RED → GREEN bundles (omit `.xcresult`) |
| --- | --- | --- |
| `NavigationFollowTurnBurstTests/testHeldActiveAckReadCannotDelayCrossingExpiryWatchdogOrCancellationStop` | All four scenarios stopped only after getter release | `at6-review-active-red` → `at6-review-active-green` |
| `NavigationFollowTurnBurstTests/testStoppedSourceWatchdogAndRecoveryExpiryFinishWhileAckReadRemainsHeld` | Both terminal deadlines waited for getter release | `at6-review-stopped-red` → `at6-review-stopped-green` |
| `FollowTurnBurstControllerTraceTests/testCoalescedBracketCannotVetoFreshStoppedArrivalAtInclusivePurposeBoundaries` | Exact target and both inclusive purpose boundaries returned resolution failure | `at6-review-arrival-red` → `at6-review-arrival-green` |

Mechanically read all six `xcresulttool get test-results summary` results: each RED **0 passed / 1 failed / 0 skipped**, each GREEN **1 passed / 0 failed / 0 skipped**. The active expiry test's timer-only strengthening was subsequently verified in the complete corrected exit; no extra historical RED cycle is claimed for that extension.

#### Complete affected exit and intermediate dispositions

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -only-testing:PhroverKitTests/FollowTurnBurstControllerTraceTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-review-affected-corrected.xcresult
xcrun xcresulttool get test-results summary --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-review-affected-corrected.xcresult
xcrun xcresulttool get test-results tests --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-review-affected-corrected.xcresult
git diff --check
```

**Final: 120 passed / 0 failed / 0 skipped.** Inventory: burst **37**, controller trace **7**, diagnostics **76**. Mechanically compared declared `func test…` names against xcresult test-case identifiers: **120 declared / 120 executed exactly once; missing [], unexpected [], duplicates []; all Passed**. Whitespace check passed.

Intermediate `at6-review-affected` was **108 passed / 12 failed**: read-only timers unnecessarily advanced synchronous-getter synthetic clocks, arrival omitted the existing planning event, and the dropped-frame diagnostic still expected the old arrival veto. Production now skips timers for already completed reads and preserves the arrival event; the dropped-frame test now expects actual arrival while preserving all bracket/rate/coast rejection assertions. `at6-review-affected-final` was **117 passed / 3 failed**: two cancellation fixtures counted/advanced the new read-only timer as motor-stage work, and the held-feedback freshness fixture manufactured continuously fresh captures on every timer until wall stall. Those fixture clocks now use cancellable real sleeps during held read-only ACK waits, while their original cancellation/stop/freshness assertions remain. The corrected complete exit above passes all three, so there is no unresolved repeated-failure blocker. These intermediate runs are not presented as successful exits or new TDD RED cycles.

Exact slice file map (all prior uncommitted work preserved):

1. `swift/Sources/PhroverKit/Nav/NavigationController.swift` — owner-scoped interruptible follow ACK read, trigger-first refresh, read-wait completion guard, stopped-source integration.
2. `swift/Sources/PhroverKit/Nav/FollowTurnBurstExecutor.swift` — actual fresh stopped arrival independent of calibration rejection; terminal runtime recheck and retained diagnostic.
3. `swift/Tests/PhroverKitTests/NavigationFollowTurnBurstTests.swift` — two held-getter regressions.
4. `swift/Tests/PhroverKitTests/FollowTurnBurstControllerTraceTests.swift` — coalesced-bracket inclusive arrival/no-learning regression.
5. `swift/Tests/PhroverKitTests/NavigationFollowScanDiagnosticsTests.swift` — dropped-bracket expected arrival plus read-only timer fixture isolation.
6. This plan — evidence and intermediate-run dispositions.

Compiler emitted mutable Sendable-capture warnings in the new recovery-clock/controller test fixtures as well as the pre-existing recovery-clock warning, and the existing empty-supported-platforms notice; no build errors. Full SDK/app/device gates were not run in this review-fix slice, per request. No commit, push or device operations. **Next: follow-up independent review of these fixes before broader final gates.**

### Task 6 follow-up review — pre-send admission ACK interruption — 2026-10-06

Resolved the remaining Medium finding: the `FollowTurnOperationExecutor` admission closure still directly awaited `currentLastAck` after strict initial stopped-source admission, with `state == .driving` and before first SEND. The prior 120-test exit did not prove interruption at that distinct boundary. It is superseded for this corrected tree by the 123-test exit below.

**Production change:** admission now calls the existing `refreshFollowTurnRuntime`, which delegates actual ACK acquisition to `interruptibleFollowTurnAck`. This removes the duplicate source/health/fence/comms validation block from admission. The shared wrapper preserves the original runtime epoch, checks runtime failure, caller cancellation, operation ownership, evidence fencing, source health/generation/freshness and strict stop-source fences, stop latch, and recovery authority around the read. Interruption classification retains cancellation/ownership priority, failed-stop `commandFailed`, and the captured runtime failure. Completed ACKs still undergo the existing fresh-ACK policy before selecting a source sample. `confirmStop` continues to await `previousLoop.value` and actual pending SEND drain; no serial motor-drain safety was bypassed. The loop now exits independently of the read-only getter, permitting physical STOP to run through the existing confirmation owner and sticky failed-stop latch.

**Actual-getter audit:** checked every `currentLastAck` reference and both `performRotate` call sites in `NavigationController.swift`, plus the follow adapter entry points. `NavigationFollowMeMotion` relative scan, alignment and absolute recovery all enter `performFollowMotion` → `rotateForFollowScan`/`rotateForFollowAlignment` → `startFollowTurn`. Its admission and active monitoring share `refreshFollowTurnRuntime`; initial/after-burst stopped-source selection uses `interruptibleFollowTurnAck` directly. The only actual getter task in this adaptive turn path is the owner-scoped read slot. Legacy `performRotate` is called only with `.continuous` and `.scan`, never `.followScan`; its retained follow-scan branch is not a route for the adaptive follow adapter. Other direct reads belong to ready translation, goal driving and legacy rotation and were not changed by this turn-admission slice. No extra ACK wrapper or motor owner was added.

#### Strict behavioral RED before patch

Added three real-controller tests, sharing one fixture at the user-specified admission seam:

- `testHeldPreSendAdmissionAckCannotDelayWatchdogCompletion`
- `testHeldPreSendAdmissionAckCannotDelayRecoveryEpisodeCompletion`
- `testHeldPreSendAdmissionAckCannotDelayExplicitStopConfirmation`

Each holds the getter specifically when `state == .driving && sends == 0`, after initial confirmed stop / 300-ms settle / actual fresh frame admission, and asserts no pending burst. Healthy flat source at the original 2.5-second Date boundary cannot renew progress; original recovery authority expires at its own 10.5 injected deadline. Explicit `stopAndConfirm` must complete its serialized physical STOP while the admission getter remains held. Assertions for terminal completion and stop counts run **before** getter release.

On GREEN, each old getter remains held while a replacement operation obtains its own initial stop and reaches a separately held pre-send ACK. Releasing the old read must leave the new operation driving-but-not-sending, its stop fence unchanged, its terminal result incomplete, and its stop count unchanged. Cancelling the replacement must then complete its independent stop before releasing that replacement's getter. Both late completions produce zero nonzero sends. On RED only, cleanup releases blocked getters after the failing assertions so the suite drains without timeout.

Exact repository-root command used for RED and then identical selectors for GREEN, changing only `BUNDLE`:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests/testHeldPreSendAdmissionAckCannotDelayWatchdogCompletion \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests/testHeldPreSendAdmissionAckCannotDelayRecoveryEpisodeCompletion \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests/testHeldPreSendAdmissionAckCannotDelayExplicitStopConfirmation \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BUNDLE.xcresult
```

- `BUNDLE=at6-followup-admit-red`: **0 passed / 3 failed / 0 skipped**. All three compiled tests failed `terminal completion must precede getter release`; explicit STOP also remained unconfirmed, and replacement cancellation awaited its direct getter. Executed before the admission production patch.
- `BUNDLE=at6-followup-admit-green`: **3 passed / 0 failed / 0 skipped** after the patch. One shared-seam TDD slice with three scenario-specific behavioral RED tests, not three separate production-patch cycles.

#### Complete corrected-tree affected exit

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -only-testing:PhroverKitTests/FollowTurnBurstControllerTraceTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-followup-affected.xcresult
xcrun xcresulttool get test-results summary --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-followup-admit-red.xcresult
xcrun xcresulttool get test-results summary --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-followup-admit-green.xcresult
xcrun xcresulttool get test-results summary --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-followup-affected.xcresult
xcrun xcresulttool get test-results tests --path /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-followup-affected.xcresult
git diff --check
```

**123 passed / 0 failed / 0 skipped**: burst **40**, controller trace **7**, diagnostics **76**. Mechanically compared declared method names to xcresult identifiers: **123 declared / 123 executed exactly once; missing [], unexpected [], duplicates []; all Passed**. Existing failed-stop/sticky latch, unhealthy source, recovery/ownership, actual pending-send drain and generic-path tests in these classes pass. Whitespace check passed. No intermediate GREEN failures, test skips, timeouts or unresolved blockers in this follow-up slice.

Exact files changed by this follow-up:

1. `swift/Sources/PhroverKit/Nav/NavigationController.swift` — pre-send admission routes through the existing interruptible runtime refresh; duplicate safety checks removed from that closure.
2. `swift/Tests/PhroverKitTests/NavigationFollowTurnBurstTests.swift` — three pre-send boundary regressions and shared fixture, including late-old-read/new-owner assertions.
3. This plan — follow-up evidence and getter audit.

Compiler emitted the existing empty-supported-platforms notice and mutable-uptime Sendable-capture warnings in test fixtures, including the new recovery deadline fixture; no compilation failures. Fixed 0.25 magnitude, 0.080-s cap, generic behavior and serialized motor ownership remain unchanged. No full SDK/app suite, commits, pushes or device operations. **Next: follow-up review before broader final gates.**

### Task 6 final software-gate attempt / bounded blocker handoff — 2026-10-06

Scope: final software gates only, with the user's supplied follow-up review outcome (no findings). No new review was performed in this session. HEAD remained `8cbcfe7`. Production code was not edited. Evidence parent **`/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`** was verified; selected simulator remained iPhone 17 Pro / iOS 26.5 / `EEA52712-371D-4FF6-B8EF-A2C78319D57F`.

#### Explicit current inventories

Declared methods were extracted from `func test…` in each XCTest class and compared mechanically with xcresult test-case URLs (target/class/method), not inferred from class names or historical counts. The affected inventory includes planner, source/executor/controller integration, real transport and diagnostics, coordinator/admission/readiness, generic safety/isolation, and adapters.

| Affected class | Declared methods |
| --- | ---: |
| ARFollowMePerceptionSourceTests | 6 |
| ARSessionManagerTests | 6 |
| FollowAssociationDiagnosticsTests | 7 |
| FollowDiagnosticEventTests | 10 |
| FollowMeCoordinatorTests | 107 |
| FollowMotionFailureResolutionTests | 6 |
| FollowPipelineDiagnosticsTests | 8 |
| FollowReacquisitionDiagnosticsTests | 2 |
| FollowReacquisitionPlannerTests | 8 |
| FollowReadyAdmissionIntegrationTests | 42 |
| FollowTargetTrackerTests | 7 |
| FollowTurnBurstControllerTraceTests | 7 |
| FollowTurnBurstPlannerTests | 14 |
| NavigationFollowReadySignalTests | 17 |
| NavigationFollowScanDiagnosticsTests | 76 |
| NavigationFollowTurnBurstTests | 40 |
| NavigationRotationWatchdogTests | 12 |
| NavigationSafetyTests | 26 |
| NavigationSilentSearchMotionTests | 7 |
| OperatorCommandRouterTests | 8 |
| RoverControlTests | 28 |
| **Total** | **444** |

Evidence files with prefix `at6-final-20261006-` in the evidence parent:

- `affected-inventory.json`: all 444 full method selectors and class counts.
- `affected-summary.json`, `affected-tests.json`, `affected-verification.json`: actual xcresult totals/tree and exact-name comparison. **444 declared / 444 executed, missing [], unexpected [], duplicates []; 442 Passed, 2 Failed.** No skips or expected failures.
- `sdk-inventory.json`: complete non-live script targets `RoverNavTests` + `PhroverKitTests`, **755 methods / 51 classes**. This replaces the obsolete 709 count only as a current declaration inventory, not a result.
- `app-inventory.json`: all `PhroverOperatorTests`, **33 methods / 4 classes** (CalibrationPreviewModel 9, ConversationViewModel 13, ManualQRExchangeViewModel 4, SilentSearchMapTransform 7). No app execution claimed.
- `at6-final-gates.py`: temporary gate runner / inventory comparator with actual command printed to tool stdout, captured Xcode stdout/stderr, 840-second child bound and 900000-ms shell bound. All test invocations use serial execution and both test allowances fixed at 60 seconds. No retry/iteration or skip flags.

#### Commands and actual results

From repository root, executed:

```bash
python3 /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-final-gates.py affected
python3 /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/at6-final-gates.py verify affected
```

The runner prints the full actual `xcodebuild test -quiet -scheme astral-sdk-Package` command with destination above, `-parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`, all 21 affected class selectors in the runbook (including controller trace), and result bundle `at6-final-20261006-affected.xcresult`. Captured stdout/stderr: `at6-final-20261006-affected.log`. **Exit 65, elapsed 128.6 s, 442 passed / 2 failed / 0 skipped.** Build phase succeeded; test phase failed.

The two failed selectors were then isolated together, before fixture changes, and repeated unchanged after the narrow migrations. Exact command for both invocations, with `BASENAME` respectively `at6-final-isolated-before` and `at6-final-isolated-migrated`:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/ARSessionManagerTests/testSnapshotUptimeAndResetGenerationFenceRealFollowController \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests/testDetectionAtRealControllerSuspensionsFencesScanBeforeConfirmedAlignment \
  -resultBundlePath "$EVIDENCE/BASENAME.xcresult" > "$EVIDENCE/BASENAME.log" 2>&1
xcrun xcresulttool get test-results summary --path "$EVIDENCE/BASENAME.xcresult"
```

Both isolated calls used a **180000-ms shell bound**, unchanged serial 60-second test limits; no automatic retries. `...isolated-before`: **0 passed / 2 failed / 0 skipped**. `...isolated-migrated`: **1 passed / 1 failed / 0 skipped**. Summaries were read directly with xcresulttool; no assertion GREEN is inferred from the shell tool's empty stdout.

**Disposed failure — coordinator fixture:** two assertion failures at `FollowMeCoordinatorTests.swift:3068` expected exactly one original scan remaining-budget wait but observed zero in stop/settle scenarios. The fixture advanced source uptime by 81 ms immediately after SEND entry, before the new asynchronous ACK read completed; expiry legitimately bypassed remaining wait. Added a bounded yield until the actual `pulse_wait_begin` event plus an explicit assertion that it entered, then advanced to the intended stop/settle boundary. Existing exact wait count, four suspension scenarios, source/stop ordering, send counts and cancellation outcomes remain. The unchanged selector passes in `...isolated-migrated`. This is a test-only boundary synchronization migration, not production tuning or a weakened assertion.

**Repeated blocker — AR reset selector:** `ARSessionManagerTests/testSnapshotUptimeAndResetGenerationFenceRealFollowController` exceeded the **1-minute execution allowance** in affected, isolated-before and isolated-migrated bundles. The fixture uses a frozen source clock, no-op sleeper, provider-only snapshots and a suspended actual ACK getter; reset snapshots do not automatically enter an injected controller's retained event gate. Tried only a cancellable real sleeper and synchronous ingress of the actual new-generation reset snapshot. That did **not** resolve the timeout. Reverted those two experimental edits; no unverified AR migration remains from this session. The exact unresolved suspension (getter entry versus post-reset completion) is not proven by the bundle. Do not classify this as a resolved fixture issue or a production regression without a bounded observation of that seam. **Stopped on repeated blocker as instructed**, without another suite attempt, timeout increase, skip, assertion relaxation or production change.

Whole SDK via `scripts/test-swift-sdk.sh`, all app unit tests, and unsigned generic-iOS Debug build were **not run** after this stop condition. Their runbook remains above. No latest-corrected-tree all-green gate exists; Task 6 remains unchecked. The successful 123-test historical exit is not substituted for this failed 444-test gate.

#### Warnings, compatibility, whitespace and file map

`xcresulttool get build-results` for affected and isolated-migrated reports **0 compiler warnings, 0 analyzer warnings, 0 errors** (incremental builds). Each captured command log contains one Xcode empty-supported-platforms notice. No freshly emitted mutable-uptime warning was observed in these cached invocations. Previously recorded mutable-uptime `@Sendable` capture warnings remain a **known test-fixture concurrency concern**, not production authorization input, and are not declared fixed or absent from a clean compile. No new external downloads or physical operations were requested/run.

README's public compatibility note is present at lines 133–136: additive non-frozen `NavigationFailure.rotationResolutionInsufficient` / stable `rotation_resolution_insufficient` and `SilentSearchMotionFailure.rotationResolutionInsufficient` require downstream exhaustive source switches to handle the new cases.

Session-retained repository changes: **`T/FollowMeCoordinatorTests.swift`** (four-line actual-boundary synchronization) and **this plan** (current inventory, status and failure handoff). The attempted AR edits were reverted; all prior implementation/review edits, `.serena`, `.opencode`, `AGENTS.md`, approved spec and workflow assets were preserved. Evidence tooling/logs/inventories are temporary files in the verified evidence parent. Tracked and untracked implementation/test/plan whitespace checks are recorded by the final git check; no commits or pushes.

Actual whitespace command below **passed with no output**, covering tracked changes plus every untracked source/test file and this untracked plan (not just `git diff --check`):

```bash
bash -c 'git diff --check && while IFS= read -r -d "" file; do git diff --no-index --check /dev/null "$file" || exit $?; done < <(git ls-files --others --exclude-standard -z -- swift/Sources swift/Tests examples/PhroverOperator/PhroverOperator examples/PhroverOperator/PhroverOperatorTests docs/superpowers/plans/2026-10-05-follow-me-adaptive-turn-bursts.md)'
```

Physical acceptance remains separate: **80 ms is a requested host budget, not certified motor-on time**; pending transport drain, serialized STOP latency, physical activation and unsampled coast remain unknown physical limits. The once-only requested **10 cm** ready signal, its **0.05 m/s** speed, existing progress watchdog and fixed departure baseline are unchanged; this gate attempt does not certify physical readiness distance or provide a ready-motion fix.

### Bounded AR blocker diagnosis and correction — 2026-10-06

The preceding unresolved AR handoff is superseded by this focused evidence. Only `T/ARSessionManagerTests.swift` and this plan were edited in this diagnosis. Production code and existing 60-second final-gate allowances were preserved.

**Proven root cause:** the old test waited indefinitely in `FollowDiagnosticSuspension.waitUntilEntered()`, not in `scan.value`. With provider-only injection, `startFollowTurnSourceEvents()` returns at its nil-`sourceEvents` guard before seeding the retained gate. Initial stop has neither `sourceStopSnapshot` nor source high-water injection, so `awaitFollowTurnSource` rejects the absent retained sample and the public controller returns `.failed(.trackingLost)` without ever invoking the ACK getter. One-second XCTest expectations for getter entry and caller completion exposed exactly the missing getter expectation; completion and tracking-loss assertions succeeded. Thus neither increasing timeout nor ingesting only a later reset snapshot can repair the unreachable original suspension.

**Fixture correction:** connect actual `ARSessionManager.snapshots()` through a buffering-newest source stream, actual stop snapshot/high-water and synchronous generation/health access. Source uptime and watchdog Date share controlled elapsed time. Starting capture is timestamp 100 at uptime 100.5 (inclusive 500 ms freshness). After confirmed stop at 100.5, advance to 100.801 and ingest an actual manager frame, generation 1 / sequence 2, timestamp 100.801. Synchronously deliver that exact snapshot to the controller at the controlled clock step, retaining the real stream too. The first event-only attempt showed why this is necessary: a clock jump could stale the old retained frame before the asynchronously forwarded newest event arrived. No fabricated sequence/generation or provider-read advancement is used; no frame is injected inside the stop closure. Suspend the actual ACK getter only after this post-ACK/settle frame, then reset the real manager, assert cache clearing, and ingest generation 2 / sequence 1 at current uptime. Releasing the getter returns `.failed(.trackingLost)` with zero nonzero commands. Entry and completion each remain bounded by a one-second assertion.

Added `testWithheldPostStopARSourceCancellationReturnsToCaller`: actual AR capture and system uptime, real cancellable sleep, deliberately withheld source stream, public follow scan. Assert wait entry within one second, cancel, then assert caller completion within one second, `.cancelled`, and zero commands. This proves cancellation drains a stopped source wait; it does not substitute for the reset test or claim a watchdog defect.

**Executed loop**, repository-root command (same selector for RED and corrected GREEN):

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 3 -maximum-test-execution-time-allowance 3 \
  -only-testing:PhroverKitTests/ARSessionManagerTests/testSnapshotUptimeAndResetGenerationFenceRealFollowController \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/BUNDLE.xcresult
```

- `at6-ar-bounded-red`: **1 failed / 0 passed / 0 skipped**, test duration **1.756 s**, missing “Follow controller enters ACK getter” at the one-second assertion; not an execution-allowance timeout.
- `at6-ar-bounded-green`: event-only intermediate fixture attempt, **1 failed / 0 passed / 0 skipped**, missing the same entry expectation (**1.573 s**); not final GREEN.
- `at6-ar-bounded-ingress`: identical selector, **1 passed / 0 failed / 0 skipped**, **0.015 s**.
- `at6-ar-class-final`: full AR class **7 passed / 0 failed / 0 skipped**; exposed a new mutable-controller capture warning. Replaced the mutable strong capture with a weak source receiver and immutable controller, then reran the class.
- `at6-ar-class-clean`: final corrected full AR class, **7 passed / 0 failed / 0 skipped**, no new compiler warning emitted; only the Xcode empty-supported-platforms notice. The final class command uses the same command above with both allowances **60**, selector `PhroverKitTests/ARSessionManagerTests`, and bundle `at6-ar-class-clean.xcresult`. Every shell test invocation was bounded at **200000 ms**.

The affected exit, whole non-live SDK, app tests and unsigned build are ready to resume, not certified complete. Refresh declared inventories before comparing results (one new AR method). No commits or device operations were performed.

### Resumed final software gates — 2026-10-06

All requested gates were executed serially on the latest tree after the two independent-review fixes, pre-send admission correction, coordinator boundary synchronization and bounded AR fixture correction. No production or test file was changed during this resume. HEAD remained `8cbcfe7`. Only this plan and temporary evidence tooling were edited.

Evidence parent **`/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`**; bundle/log/JSON prefix **`at6-resumed-final-20261006`**. Simulator: iPhone 17 Pro / iOS 26.5 / `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Each gate used an **840-second subprocess bound / 900000-ms shell bound**; every test used `-parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`. No retry, test-iteration or skip/exclusion flags. The SDK script selected its complete non-live targets `PhroverKitTests` and `RoverNavTests`.

| Gate / bundle suffix | Actual results | Local command interval (UTC−07:00) | Wall seconds / exit |
| --- | --- | --- | --- |
| `-affected.xcresult` | **445 passed / 0 failed / 0 skipped**, 21 classes | 12:49:50.178 → 12:50:10.964 | 20.785 / 0 |
| `-sdk.xcresult` | **755 passed / 1 failed / 0 skipped**, 756 methods / 51 classes | 12:50:16.785 → 12:51:05.179 | 48.394 / 65 |
| `-app.xcresult` | **33 passed / 0 failed / 0 skipped**, 4 classes | 12:51:53.779 → 12:52:17.147 | 23.368 / 0 |
| `-build.xcresult` | **Build succeeded**, Debug / generic iOS / `CODE_SIGNING_ALLOWED=NO` | 12:52:24.582 → 12:52:31.674 | 7.093 / 0 |

Each command's exact arguments, working directory, timezone-aware start/end times, elapsed time, exit code and before/after SHA-256 are preserved in `-MODE-command.json`; Xcode stdout/stderr in `-MODE.log`. All four before/after source fingerprints agree:

`f4f2c67d65777ed757ebbab4176502073ed9593459084242e915ad6cf06b068e`

The fingerprint covers all Swift sources/tests plus app project/scheme files. No source change separates affected exit, SDK, app tests or build; no historical pre-review success is substituted for this failed final SDK gate.

#### Current explicit affected inventory

| Class | Declared / executed |
| --- | ---: |
| ARFollowMePerceptionSourceTests | 6 / 6 |
| ARSessionManagerTests | 7 / 7 |
| FollowAssociationDiagnosticsTests | 7 / 7 |
| FollowDiagnosticEventTests | 10 / 10 |
| FollowMeCoordinatorTests | 107 / 107 |
| FollowMotionFailureResolutionTests | 6 / 6 |
| FollowPipelineDiagnosticsTests | 8 / 8 |
| FollowReacquisitionDiagnosticsTests | 2 / 2 |
| FollowReacquisitionPlannerTests | 8 / 8 |
| FollowReadyAdmissionIntegrationTests | 42 / 42 |
| FollowTargetTrackerTests | 7 / 7 |
| FollowTurnBurstControllerTraceTests | 7 / 7 |
| FollowTurnBurstPlannerTests | 14 / 14 |
| NavigationFollowReadySignalTests | 17 / 17 |
| NavigationFollowScanDiagnosticsTests | 76 / 76 |
| NavigationFollowTurnBurstTests | 40 / 40 |
| NavigationRotationWatchdogTests | 12 / 12 |
| NavigationSafetyTests | 26 / 26 |
| NavigationSilentSearchMotionTests | 7 / 7 |
| OperatorCommandRouterTests | 8 / 8 |
| RoverControlTests | 28 / 28 |
| **Total** | **445 / 445** |

Mechanical comparisons for affected, SDK and app each report **missing [], unexpected [], duplicates []**. Complete method selectors and per-class counts are preserved in each `-MODE-inventory.json`; actual case trees in `-MODE-tests.json`; xcresult summaries in `-MODE-summary.json`; exact-name comparison in `-MODE-verification.json`. Full SDK includes **737 PhroverKitTests + 19 RoverNavTests = 756**, not the obsolete historical 709. App includes CalibrationPreviewModel 9, ConversationViewModel 13, ManualQRExchangeViewModel 4 and SilentSearchMapTransform 7. SDK's one non-Passed method is explicitly retained in verification evidence.

#### Actual commands

From repository root, invoked the evidence runner separately for affected, SDK, app and build, with verification before proceeding:

```bash
python3 "$EVIDENCE/at6-final-gates.py" affected
python3 "$EVIDENCE/at6-final-gates.py" verify affected
python3 "$EVIDENCE/at6-final-gates.py" sdk
python3 "$EVIDENCE/at6-final-gates.py" verify sdk
python3 "$EVIDENCE/at6-final-gates.py" app
python3 "$EVIDENCE/at6-final-gates.py" verify app
python3 "$EVIDENCE/at6-final-gates.py" build
python3 "$EVIDENCE/at6-final-gates.py" audit
```

The SDK verification appropriately exited nonzero for the failed method; independent app/build gates were then completed. The runner's full affected command is the 21-class runbook above with fixed flags and `-resultBundlePath "$EVIDENCE/at6-resumed-final-20261006-affected.xcresult"`. Other commands printed to actual tool stdout and saved in command JSON:

```bash
scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -resultBundlePath "$EVIDENCE/at6-resumed-final-20261006-sdk.xcresult"
xcodebuild test -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverOperatorTests \
  -resultBundlePath "$EVIDENCE/at6-resumed-final-20261006-app.xcresult"
xcodebuild build -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/at6-resumed-final-20261006-build.xcresult"
```

#### Fresh failure and bounded diagnosis

**Unresolved SDK failure:** `PhroverKitTests/ARSharedMissionFrameCalibratorTests/testExpectedMarkerDetectionIsObservedBeforeGroundingStarts`, `ARSharedMissionFrameCalibratorTests.swift:244`, `XCTAssertTrue(probe.detectionWasObserved)`. The failed method completed in **0.594 s**, not a timeout. It captures the collector's already-observed events synchronously inside the injected grounder and requires detection to have been consumed before grounding. The producer in `ARSharedMissionFrameCalibrator.events` yields detection to AsyncStream, calls `await Task.yield()`, then invokes the grounder. Task.yield permits but does not guarantee consumer scheduling. This identifies an ordering hazard, not a proven deterministic reproduction or an approved contract change.

Ran one bounded independent diagnostic invocation (180000-ms shell bound, unchanged serial 60-second allowances), not a full-suite retry:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/ARSharedMissionFrameCalibratorTests/testExpectedMarkerDetectionIsObservedBeforeGroundingStarts \
  -resultBundlePath "$EVIDENCE/at6-resumed-calibrator-isolated.xcresult" \
  > "$EVIDENCE/at6-resumed-calibrator-isolated.log" 2>&1
xcrun xcresulttool get test-results summary --path "$EVIDENCE/at6-resumed-calibrator-isolated.xcresult"
```

Isolated result **1 passed / 0 failed / 0 skipped**. This does **not** dispose of the full SDK failure or justify an unchanged suite retry. No fixture expectation was weakened; no calibration production change was made in this final-gate scope. Follow-specific AR reset and coordinator suspension blockers are disposed: both methods pass in the complete affected and full SDK inventories. The calibration assertion remains an accurately reported, scheduling-sensitive final-gate blocker, with failed full-suite bundle retained. **Task 6 remains unchecked.**

#### Exact warnings, whitespace and physical limits

Fresh `xcresulttool get build-results` warning counts: affected **0**, SDK **0**, app **1**, unsigned build **1**; all four report **0 analyzer warnings / 0 build errors**. Both emitted compiler warnings are the same existing `ConversationView.swift:273:58` `UIScreen.main` iOS 26 deprecation. Affected and SDK logs each contain one empty-supported-platforms notice; app/build contain none. Audit evidence is `at6-resumed-final-20261006-audit.json`, including actual warning messages/locations and command metadata. Known mutable-uptime Sendable-capture warnings were not freshly emitted by these incremental package builds; they remain flagged as test-fixture concurrency concerns, not production input, and are not claimed fixed or absent from a clean compile.

The existing README documents additive public `NavigationFailure.rotationResolutionInsufficient` / stable `rotation_resolution_insufficient` and silent-search exhaustive-switch compatibility. Final tracked and untracked source/test/plan whitespace checks passed using the exact git command recorded in the preceding final-gate handoff. Only this plan was changed in the repository by this resume; all prior AR/coordinator fixture and review fixes were retained. No commits, pushes, downloads or device operations.

Physical acceptance remains separate. **80 ms is the requested host budget**, not a measured/certified physical motor-on duration; pending transport drain, serialized stop latency, physical activation and unsampled coast remain physical limits. The separate once-only **10 cm readiness** request, **0.05 m/s** speed, original progress watchdog and fixed departure baseline are unchanged. Simulator gates do not resolve or certify that physical readiness-motion issue.

### Task 6 calibration-order diagnosis and test-only correction — 2026-10-06

**The reported calibration failure is disposed at the focused seam; Task 6 remains unchecked pending the next full SDK gate.** No full-suite retry was performed in this diagnosis. Prior full SDK evidence remains **755 passed / 1 failed**, not retrospectively green.

#### Reproduction, contract and baseline proof

Before editing, ran the original single selector with `-test-iterations 50 -run-tests-until-failure`, serial testing and unchanged 60-second execution allowances. It passed 18 iterations and failed iteration 19 with the same `XCTAssertTrue(probe.detectionWasObserved)` symptom; no retries or timeout occurred. Bundle `calib-order-original-50.xcresult` reports 19 executions, 18 successful / 1 failed, and the original method's assertion failure. This already-minimal repro is one normal-tracking snapshot, one expected-marker scanner result, and the injected grounder returning missing depth. No adaptive turn operation participates.

Read `CONTEXT.md`, the calibration feedback design, actual public stream/scanner/grounder pipeline and its tests. Inspected baseline files with `git show 8cbcfe7:<path>` and confirmed `git diff 8cbcfe7 --` both calibration files was empty before editing. Both the producer's `continuation.yield(detection) → await Task.yield() → grounder(...)` sequence and the consumer-observation assertion predate adaptive-turn changes. Existing progress-acknowledgement stabilization from commit `175285e` is present in the baseline; this separate entry-observation test still relied on scheduler timing.

Ranked hypotheses were (1) consumer scheduling race, (2) late producer emission, (3) incomplete processing from yield-count polling. The original failure had only the entry-probe assertion, while final contextual detection/failure event ordering passed. The source emits detection before grounder entry. `Task.yield()` is a scheduling opportunity, not a consumer acknowledgement; the producer may resume before the collector processes its buffered event.

The approved source of truth is `docs/superpowers/specs/2026-08-14-silent-search-calibration-camera-feedback-design.md`: data-flow steps 4–5 (lines 75–76) and the explicit test requirement (line 135) require **QR-detected feedback emitted before grounding is attempted**. Line 81 explicitly allows asynchronous preview/polygon rendering. These do not require a consumer/UI acknowledgement before depth processing. A strict consumer-observed contract would require a genuine acknowledgement/backpressure boundary; adding that architecture is outside this test-only correction.

#### Correct seam and sensitivity proof

Renamed the test to `testExpectedMarkerDetectionIsEnqueuedBeforeGroundingStarts`. It still runs `events(markerID:sessionGeneration:)`, actual snapshot ingress, scanner payload preflight and injected synchronous grounder. At grounder entry, a test-only probe holds the MainActor producer synchronously while a detached iterator reads the public stream's first buffered event. A lock protects the detached receipt; a semaphore limits the hold to one second. The producer cannot enqueue any late detection, grounding result or QR-expiry event during that hold. The probe never waits for a detection predicate: it reads exactly the first event and compares it to independently specified marker ID, corners and frame context. After entry, the remaining stream is drained and must contain exactly the same contextual missing-depth feedback. Calibration cancellation and reader cancellation clean up both successful and failing paths.

This checks producer ordering, not eventual feedback or physical UI observation, without adding production API. `fulfillment(..., timeout: 1)` acknowledges actual grounder inspection instead of counting scheduler yields; the serial 60-second test allowance was unchanged.

Sensitivity control: temporarily moved the detection emission past grounder invocation in the previously unchanged production file. The identical replacement selector failed **1 test / 0 passed**, with `XCTAssertTrue` on event availability at entry (`calib-enqueue-late-emission-red.xcresult`). Thus an implementation that merely emits detection later cannot satisfy this test. Restored the production source exactly using `apply_patch`; `git diff --exit-code 8cbcfe7 -- swift/Sources/PhroverKit/SilentSearch/Device/ARSharedMissionFrameCalibrator.swift` passed before and after final verification. This is a test-fixture correction plus negative-control RED/restored GREEN evidence, not a new production fix.

#### Actual bounded verification

All bundles are under `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`; commands ran from repository root on iPhone 17 Pro / iOS 26.5 simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, with 600000-ms shell limits. Common exact invocation:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:SELECTOR -resultBundlePath "$EVIDENCE/BUNDLE.xcresult"
```

| Bundle | Selector after `PhroverKitTests/` / added flags | Verified result |
| --- | --- | --- |
| `calib-order-original-50` | `ARSharedMissionFrameCalibratorTests/testExpectedMarkerDetectionIsObservedBeforeGroundingStarts`; `-test-iterations 50 -run-tests-until-failure` | 18 passed, then identical assertion failure on iteration 19 |
| `calib-enqueue-fixture` | `ARSharedMissionFrameCalibratorTests/testExpectedMarkerDetectionIsEnqueuedBeforeGroundingStarts` | 1 passed / 0 failed |
| `calib-enqueue-late-emission-red` | Same replacement method; temporary late-emission negative control | 0 passed / 1 failed |
| `calib-class-restored-50` | `ARSharedMissionFrameCalibratorTests`; `-test-iterations 50 -run-tests-until-failure` | **18 distinct tests × 50 iterations = 900 passed / 0 failed / 0 skipped** |

Counts and assertion text were read using `xcrun xcresulttool get test-results summary --path "$EVIDENCE/BUNDLE.xcresult"`. Repeated-run summaries distinguish 18 distinct methods from 900 successful executions. `git diff --check` passed. Xcode emitted the existing empty-supported-platforms notice.

Only `swift/Tests/PhroverKitTests/ARSharedMissionFrameCalibratorTests.swift` and this plan have lasting edits from this diagnosis. Production calibration remains identical to HEAD `8cbcfe7`; adaptive-turn changes, recovery semantics and existing workflow assets were preserved. No commits or device operations. Next action is the separately requested full SDK gate; the focused result alone does not mark Task 6 complete.

### Latest final-gate attempt — 2026-10-06 (`at6-final-complete20261006`)

**Root:** `/Users/hungmai/Sites/Astral/astral-sdk`. **Evidence:** `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`. Prefix **`at6-final-complete20261006`**. HEAD `8cbcfe7`; calibration producer diff against HEAD is empty. No source/test edits in this attempt. All tests ran serially, with both allowances **60 s**, no retries/iterations/exclusions; shell bound 900000 ms, child bound 840 s (focused diagnostic 180000-ms shell bound). Simulator: iPhone 17 Pro / iOS 26.5 / `EEA52712-371D-4FF6-B8EF-A2C78319D57F`.

| Bundle suffix | Actual result | Command interval, Oct 6 UTC−07:00 | Exit |
| --- | --- | --- | ---: |
| `-sdk.xcresult` | **755 passed / 1 failed / 0 skipped** | 13:00:07.425–13:00:55.477 | 65 |
| `-admission-focused.xcresult` | **1 passed / 0 failed / 0 skipped**, diagnostic only | xcresult 13:01:07.639–13:01:12.689 | summary Passed |
| `-app.xcresult` | **0 unit methods executed**, runner launch failed | 13:01:29.497–13:02:17.821 | 65 |
| `-build.xcresult` | **Unsigned Debug generic-iOS build succeeded** | 13:02:24.593–13:02:29.261 | 0 |

Fresh SDK inventory/xcresult comparison: **756 declared / 756 executed exactly once**, 51 classes, **737 PhroverKitTests + 19 RoverNavTests**; missing [], unexpected [], duplicates []. All **18 calibration methods**, including renamed `testExpectedMarkerDetectionIsEnqueuedBeforeGroundingStarts`, passed; no old selector was excluded. All **445 affected methods** were included exactly once: **444 passed / 1 failed**. The earlier standalone 445/445 was not rerun or substituted for this subset result. App inventory is **33 declared / 0 executed**; all 33 remain missing due to launch failure, not skipped. Its xcresult's single failed “PhroverOperator encountered an error” case is an infrastructure placeholder, not an executed unit method.

**New unresolved SDK assertion:** `PhroverKitTests/FollowReadyAdmissionIntegrationTests/testHealthyFramesArrivingBeforeFeedbackResumesCannotStarveReadyAdmission`, line **580**, telemetry `frame_id` actual **`1:5`**, expected **`1:6`**. Test duration 0.657 s, not timeout. One unchanged focused diagnostic with the same serial 60-second flags passed. Inspection shows `fixture.send(6)` synchronously updates controller capture but yields perception through AsyncStream, then immediately releases feedback without draining frame processing. Receipt into the coordinator versus feedback resumption is scheduling-sensitive; the isolated pass is not a deterministic root-cause proof, fixture fix, or full-suite GREEN. No assertion was relaxed, production changed, or unchanged SDK rerun to hide the failure.

**App infrastructure blocker:** simulator refused `us.astral.phrover` launch with `FBSOpenApplicationServiceErrorDomain`, `RequestDenied`, underlying `Busy — Application failed preflight checks`. No app test ran. No unchanged app retry or simulator/device reset was performed. Independent unsigned build completed after the failed app invocation.

Commands were printed to tool stdout and saved in each `-MODE-command.json` (exact args/root/interval/exit/fingerprint), with stdout/stderr in `-MODE.log`. Expanded final gate commands:

```bash
EVIDENCE=/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode
scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -resultBundlePath "$EVIDENCE/at6-final-complete20261006-sdk.xcresult"
xcodebuild test -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverOperatorTests \
  -resultBundlePath "$EVIDENCE/at6-final-complete20261006-app.xcresult"
xcodebuild build -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO -resultBundlePath "$EVIDENCE/at6-final-complete20261006-build.xcresult"
```

The focused command used `xcodebuild test -quiet -scheme astral-sdk-Package`, same simulator/serial/60-second flags, only the named failed SDK selector, and `-resultBundlePath "$EVIDENCE/at6-final-complete20261006-admission-focused.xcresult"`; stdout/stderr saved to matching `.log`. Summary read directly with `xcresulttool get test-results summary`. Temporary `at6-final-gates.py` regenerated inventories and read all actual summaries/trees/build-results; verification correctly failed for SDK and app. Evidence includes full `-sdk/app/affected-inventory.json` method lists, `-sdk/app-tests.json`, summaries, verification, `-affected-in-sdk.json` and `-audit.json`.

All three gates had identical before/after source fingerprint **`ad4689aa17a2bf3bf70bcac0cc3c04cc7ba600f4a39525bbd85e04acfc7cd5a9`**, covering Swift sources/tests and app project/scheme files, after all review/admission/AR/coordinator/calibration fixture corrections. Build-results warnings: SDK **0**, app **1**, unsigned build **1**; analyzer warnings **0** throughout. App/build warning is the existing cached `ConversationView.swift:273:58` `UIScreen.main` iOS 26 deprecation; **zero fresh `warning:` lines** in all three command logs. SDK has one empty-supported-platforms notice. App build-results contains **2 launch-error diagnostics**; SDK/build have 0 errors. No clean-compilation warning elimination is inferred: historical mutable-uptime Sendable captures remain known **test-fixture** concurrency concerns, not production input.

Final tracked/untracked source/test/plan whitespace checks passed with the previously recorded `git diff --check` plus `git diff --no-index --check /dev/null` loop over untracked files. Only this plan changed in the repository during this attempt. README's public additive `NavigationFailure.rotationResolutionInsufficient` / `SilentSearchMotionFailure.rotationResolutionInsufficient` exhaustive-switch compatibility note remains present. **Task 6 remains unchecked**; historical calibration failure is disposed, latest SDK admission failure and app launch failure are retained honestly. No commits, pushes, downloads or physical-device operations.

Physical acceptance is separate: **80 ms is a requested host budget**, not certified motor-on time; pending send drain, serialized stop latency, activation and unsampled coast remain physical limits. The separate once-only **10 cm readiness request**, **0.05 m/s** speed, original progress watchdog and fixed departure baseline are unchanged and not physically certified by these gates.

### Ready-admission ingress/ACK diagnosis — 2026-10-06

**Finding: test-only scheduling race.** The unchanged selector `PhroverKitTests/FollowReadyAdmissionIntegrationTests/testHealthyFramesArrivingBeforeFeedbackResumesCannotStarveReadyAdmission` reproduced the exact full-SDK assertion: 16 passes followed by run 17 failing `frame_id` actual `1:5`, expected `1:6` (`admission-original-50.xcresult`, requested 50 with stop-on-failure). `Fixture.send(6)` synchronously stores the controller capture, but `FollowPerceptionFake.send` only yields into an unbounded AsyncStream. It does not acknowledge coordinator receipt. Immediately releasing feedback allows the controller to authorize before the perception consumer resumes.

Ranked hypotheses were consumer ingress losing the race to ACK resumption; authorization ignoring an already-ingested pending frame; and fixture source/stop sequencing changing identity. Temporary probes at event ingress and admission snapshot selection distinguished these. Logging every ingress perturbed scheduling and passed 50/50 (`admission-chronology-50.xcresult`), which was not treated as a fix. A sparse probe printed only selection of frame 5 and ingress after the attempt had been consumed. It reproduced the failure with this exact order (`admission-chronology-sparse-50.log`, lines 199–202):

```text
[DEBUG-admission] authorize pending=nil latest=Optional(PhroverKit.ARFrameID(generation: 1, sequence: 5)) selected=Optional(PhroverKit.ARFrameID(generation: 1, sequence: 5))
[DEBUG-admission] late ingress ARFrameID(generation: 1, sequence: 6)
XCTAssertEqual failed: actual 1:5, expected 1:6
```

Thus the observed production boundary selected the newest **known person transaction**, not an ignored newer pending transaction. A newer independently captured controller pose is not evidence that its detector batch has been ingested. If frame 6 is ingested before authorization, the exact intended person frame remains **1:6**.

#### Fixture correction and preserved contract

`Fixture.sendAtIngressAndReleaseFeedback` finishes all synchronous producer clock reads while sending the frame, then arms the existing `ManualFollowClock.onNextRead`. With feedback held and prior work drained, the next read is the coordinator's `receive(event:)` ingress read. The callback releases the held real controller ACK; authorization cannot execute on MainActor until that synchronous ingress turn publishes `pendingFrame`. A one-second XCTest expectation acknowledges the probe rather than interpreting producer yield or a count of scheduler yields as receipt. The probe is cleared and feedback released on failure as well. The existing serial 60-second execution allowances are unchanged.

The original three-attempt scheduling loop is replaced by one admission request: frames 4 and 5 are actual captured sources separated by **0.301 s**, with explicit IDs/timestamps checked; frame 6 is captured 0.1 s later at yaw 0.034 and ingested before ACK continuation. Strict assertions still require person/controller frames **1:6**, controller source age **0**, heading **−0.034**, range **1.68**, exactly one authorized event and exactly one consumed move. Added checks require authorization before command initiation, one completed ready signal, state remaining `signalingReady` until a genuinely fresh post-final-stop frame, then `waitingForMovement` with no second ready command. Full five-second pause and no-turn assertions remain.

An exploratory extra assertion that frame 6 must still be pending at admission proved overconstrained: `admission-ingress-restored-20.xcresult` had 15 passes and 5 failures solely because telemetry said `not_pending`; all 20 selected frame 6. In those five runs the processor legitimately adopted frame 6 before authorization. That newly added queue-state requirement was removed; **no original latest-frame, freshness, heading, range, command-count, or pause assertion was relaxed**. The corrected contract permits either pending evaluation or prior normal processing of the same latest ingested frame.

#### Historical-guard sensitivity

Inspected `040eb15`'s `signalReady` validator: it used `guard self.pendingFrame == nil, let batch = self.latestBatch, ... else { return .deferred(.observation) }`. Temporarily reintroduced **only** that pending-frame denial at the current validator, using the existing rejection formatter; no file was replaced by historical contents and no other working-tree change was overwritten.

- `admission-historical-guard-red.xcresult`: 0 passed / 1 failed. Actual ready sends **0**, required **1**; no authorized event.
- Final fixture with the same temporary control, `admission-historical-guard-20.xcresult`: **18 failed / 2 passed / 0 skipped**. All 18 failures include the original starvation assertion, zero sends instead of one. The two passes are the legitimate processor-first ordering in which the historical guard sees no pending frame. This is measured 90% regression sensitivity, **not a claimed deterministic pending-only schedule or 20/20 RED**.
- Removed the temporary guard and all tagged probes using dedicated mechanical patches. No lasting production edit was made by this diagnosis, so a new independent production review was not triggered.

#### Final scoped evidence

All bundles/logs below are under `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`. Commands ran from repository root, simulator iPhone 17 Pro / iOS 26.5 / `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, shell bound 600000 ms:

```bash
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests/testHealthyFramesArrivingBeforeFeedbackResumesCannotStarveReadyAdmission \
  -test-iterations 20 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/admission-final-20.xcresult
```

The class command uses the same flags with `-only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests`, omits `-test-iterations`, and writes `admission-final-class.xcresult`.

| Final bundle | Verified actual result |
| --- | --- |
| `admission-final-20.xcresult` | **20 passed / 0 failed / 0 skipped executions**, one distinct method |
| `admission-final-class.xcresult` | **42 passed / 0 failed / 0 skipped**, all 42 admission methods |

Read actual `xcresulttool get test-results summary` and class `tests` tree. Whitespace check `git diff --check` passed; production search finds neither `[DEBUG-admission]` nor `pending_frame_not_drained`. Xcode emitted the existing empty-supported-platforms notice. Lasting edits from this diagnosis are the admission test/fixture and this plan. No full-SDK/app retry, commits, or device operations. Task 6 remains unchecked; the next final software gates must run on the corrected tree, and the previously recorded app-launch blocker remains unresolved.

### Task 6 final completion — 2026-10-06

**Root:** `/Users/hungmai/Sites/Astral/astral-sdk`. **Evidence parent:** `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode`. **Prefix:** `at6-final-complete20261006-recovered` (new files; previous failure bundles preserved). HEAD `8cbcfe7`. Only this plan and temporary evidence tooling changed in this final session; all reviewed production and corrected fixture files were retained.

| Gate / bundle suffix | Actual result | Command interval, Oct 6 UTC−07:00 | Wall time / exit |
| --- | --- | --- | --- |
| `-sdk.xcresult` | **756 passed / 0 failed / 0 skipped**, 51 classes | 13:14:18.335–13:14:51.509 | 33.173 s / 0 |
| Affected subset in SDK | **445 passed exactly once**, 21 classes | Same SDK invocation; no redundant affected rerun | Included above |
| `-app.xcresult` | **33 passed / 0 failed / 0 skipped**, 4 classes | 13:15:29.829–13:15:43.484 | 13.654 s / 0 |
| `-build.xcresult` | **Unsigned Debug generic-iOS build succeeded** | 13:15:43.900–13:15:48.877 | 4.977 s / 0 |

SDK inventory is **737 PhroverKitTests + 19 RoverNavTests = 756**, not historical 709. SDK and app each match declared method names to actual xcresult URLs exactly: **missing [], unexpected [], duplicates [], nonPassed []**. Affected class/method inventories are unchanged from the explicit 445-method table above and independently verified as a subset of this all-green SDK. Both corrected ordering selectors executed; calibration **18/18**, admission **42/42**, AR **7/7**, coordinator **107/107**. App declarations/execution: CalibrationPreviewModel 9, ConversationViewModel 13, ManualQRExchangeViewModel 4, SilentSearchMapTransform 7. No exclusions, retries, test iterations or expected failures; all tests serial with fixed **60-second default/maximum allowances**, child timeout 840 s / shell bound 900000 ms.

**Simulator launch recovery before app tests:** after SDK completion, `pgrep -fl 'xcodebuild|xctest'` returned no matches; exact-name checks for each process also found none. The selected simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F` (iPhone 17 Pro / iOS 26.5) was already **Shutdown**. An initial process inspection correctly reported that its launchd session was not booted; no claim of process visibility while shut down. It therefore needed no additional shutdown. Booted only this UDID and waited using `xcrun simctl bootstatus ... -b`; then inspected its `launchctl list` and installed app/test-runner inventory. No matching active Phrover/test-runner processes; installed app `us.astral.phrover` and UI-test runner `us.astral.phrover.uitests.xctrunner` were retained. No process killed, unrelated simulator touched, erase/uninstall performed, or physical phone used. Recovery interval **13:15:18.107–13:15:23.610**; commands/stdout/state saved in `-simulator-recovery.json`. The first app invocation after this setup passed all 33 tests; this is explicit infrastructure recovery, not test-retry semantics or reuse of historical app success.

Exact final commands, from root (stdout/stderr saved in matching `-MODE.log`):

```bash
EVIDENCE=/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode
scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  -resultBundlePath "$EVIDENCE/at6-final-complete20261006-recovered-sdk.xcresult"
# Selected simulator was already shut down; after orphan checks:
xcrun simctl boot EEA52712-371D-4FF6-B8EF-A2C78319D57F
xcrun simctl bootstatus EEA52712-371D-4FF6-B8EF-A2C78319D57F -b
xcrun simctl spawn EEA52712-371D-4FF6-B8EF-A2C78319D57F launchctl list
xcrun simctl listapps EEA52712-371D-4FF6-B8EF-A2C78319D57F
xcodebuild test -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -only-testing:PhroverOperatorTests \
  -resultBundlePath "$EVIDENCE/at6-final-complete20261006-recovered-app.xcresult"
xcodebuild build -quiet -project examples/PhroverOperator/PhroverOperator.xcodeproj \
  -scheme PhroverOperator -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/at6-final-complete20261006-recovered-build.xcresult"
```

The temporary runner `at6-final-gates.py` executed these gates, regenerated inventories and read actual xcresult summaries/trees/build-results. Each `-MODE-command.json` records exact arguments, root, timezone-aware intervals, exits and before/after source fingerprints. `-sdk/app-inventory.json` contains full method lists; `-sdk/app-tests.json`, summaries and verification JSON prove exact execution; `-affected-in-sdk.json` proves all 445 affected methods passed; `-audit.json` records warning messages/counts. All three gates share unchanged before/after fingerprint **`c3870e278a73c33043208b80cfd0b6715707be2ceaa6a24a2ba1596a3fe4a945`**, covering Swift source/tests and app project/scheme files, after the review/admission corrections and all test-only fixture fixes.

**Warnings:** build-results reports SDK **0**, app **1**, unsigned build **1**, all with **0 errors / 0 analyzer warnings**. App/build carry the existing cached `ConversationView.swift:273:58` `UIScreen.main` iOS 26 deprecation. All three logs contain **0 freshly emitted `warning:` lines**; SDK has one empty-supported-platforms notice. These incremental gates do not certify clean-compile warning elimination: historical mutable-uptime Sendable capture concerns remain flagged in test fixtures, not production input.

Tracked/untracked source/test/plan whitespace passed using the previously recorded `git diff --check` plus no-index check over all untracked source/test files and this plan; rerun after the completion edit. README's public additive `NavigationFailure.rotationResolutionInsufficient` / stable `rotation_resolution_insufficient` and silent-search exhaustive-switch compatibility note remains present. All required software gates are now green, so **Task 6 is checked**. Prior failure histories remain intact and are superseded by corrected-tree evidence, not excluded or relabeled as passes. No commits, pushes, downloads or physical-device operations.

Physical acceptance remains separate: **80 ms is a requested host budget**, not certified physical motor-on duration; pending transport drain, serialized stop latency, activation and unsampled coast remain physical limits. The separate once-only **10 cm readiness request**, **0.05 m/s** speed, original progress watchdog and fixed departure baseline remain unchanged; this software completion neither certifies physical readiness travel nor fixes that separate physical issue.
