# Initial search: bounded forward pulses after the stop-protocol correction

User requested the next fix from the 16:12 screenshot. This amendment replaces precision-heading budget selection **only for explicit initial search sweeps**, building on the sweep-completion and supported T:1 zero-wheel stop corrections. Earlier workflow assets remain preserved.

## Evidence

Fresh artifact: `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-20261008-1612-runtime.log`.

Two attempts at 23:12:08–09 and 23:12:35–36 UTC requested a 25 ms first pulse. Net AR responses were respectively **0.017909** and **0.018780 rad** (about one degree). Send-to-stop windows were **115.568** and **62.313 ms**. Valid stopped response brackets were available, with acknowledged commands/stops. Search nevertheless terminated because the precise-heading model's candidate budgets were **-74.119** and **-21.280 ms**.

The provisional rate floor combined with host overhead was being interpreted as a minimum angular response, despite the small measured movement. A directed initial search should continue observing and advancing, not require a precision correction of this residual heading.

## Initial-search policy

- Use a dedicated planner for the existing explicit initial-search sweep intent. Each pulse uses the existing **80 ms maximum host budget** and fixed signed **0.25** wheel magnitude. It never increases the maximum or issues reverse corrections.
- Command/stop latency, learned response gain and precision overshoot ceilings remain diagnostic for this mode; they do not shrink or veto its next pulse. Complete valid attributed response evidence is still required before another pulse.
- Every pulse retains the existing immutable sender deadline, authority/ownership validation, serialized stop, 300 ms settling and fresh-source gates. Actual request/stop latency can exceed the host budget; there is no physical motor-on-time guarantee.
- Require validated cumulative **directed progress covering the full requested arc**, rather than crediting the scan heading tolerance as swept coverage. For a production ten-degree step, five degrees is not completion. Absolute sampled travel continues to feed the existing finite scan account.
- During an initial sweep, source observers stop a burst on crossing the full frozen target (zero heading-tolerance shortcut), budget expiry, or the existing safety/cancellation conditions. They do not inhibit a needed request merely because it entered the seven-degree exact-heading tolerance. The tolerance comes from operation-local runtime state at all observer construction boundaries.
- The original **2.5-second / 0.05-radian progress watchdog** is retained across all pulses. Zero progress cannot refresh it. Wrong-way response, missing evidence, stop failure, invalid geometry and unrepresentable deadlines still fail; a later target pose alone cannot manufacture sweep completion.
- Once the requested arc is covered, the coordinator performs its existing one-second look interval and requires a fresh perception frame before the next step. Person detection can still interrupt immediately. Alignment, unmarked turns and absolute recovery retain their precise-heading planning and tolerances.

## Diagnostics

Explicit sweep plans report `budget_formula=maximum_host_burst_budget` and `allowance_policy=diagnostic_only_for_initial_search`, full required/remaining progress, and `source_stop_tolerance_rad=0`. Exact-heading plans retain `min(maximum,E/R-H,overshootCeiling)` and their original tolerance. Completion wording is derived from typed local policy state rather than inspecting serialized field strings.

## Regression scope

The actual contextual-controller replay failed before the change after one pulse with `rotationResolutionInsufficient`. It now continues with bounded forward pulses and completes after validated full-arc progress. The replay covers both captured timing/response cases and a third response inside the old heading tolerance but short of the requested arc. A separate controller regression requires zero progress to fail at the original watchdog boundary after one send rather than reset the clock.

The simulation clock must advance across a remaining-budget wait. The first post-change replay exposed that fixture omission; the fixture now explicitly advances to the immutable deadline before publishing the post-stop sample. No production timeout was changed. Existing overshoot and target-inhibition fixtures were migrated to the new initial-search budget and full-target crossing; exact-heading fixtures remain intact.

This is a bounded search policy, not physical-device acceptance or a relaxation of person verification.

## Review and verification

Independent Standards review found no hard repository violations, one antipodal (+π) admission boundary defect and one optional duplication smell in the three tolerance fallback expressions. The antipodal defect received an assertion-red controller regression, then a fix honoring the explicit requested direction at ±π. Source observers now receive the actual wheel-command direction to disambiguate their exact half-turn crossing as well; default negative-half-turn semantics remain intact. Follow-up review confirmed the finding resolved. The optional small-expression duplication was left local rather than introducing a broader refactor.

Independent Spec review found no blockers in the bounded production search path, authority checks, progress accounting, diagnostics or termination. Review summary: Standards — 0 remaining correctness findings / 1 optional duplication smell; Spec — 0 findings.

All artifacts below are under `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/`, with corresponding `.log` files. Test counts come from `xcresulttool get test-results summary`.

| Gate | Result | Bundle |
| --- | --- | --- |
| Captured small-response regression before change | 1 failed | `search-pulse-policy-red.xcresult` |
| Corrected simulation-clock replay | 1 passed | `search-pulse-policy-green-clock.xcresult` |
| Focused controller/transport/coordinator/planner/diagnostics | 316 passed | `search-pulse-policy-focused.xcresult` |
| Initial full SDK checkpoint | 818 passed | `search-pulse-policy-sdk.xcresult` |
| Positive-half-turn regression before boundary fix | 1 failed | `search-pulse-pi-red.xcresult` |
| Controller class after boundary fix | 47 passed | `search-pulse-pi-green.xcresult` |
| Final complete non-live SDK | **819 passed, 0 failed, 0 skipped** | `search-pulse-policy-sdk-final.xcresult` |
| Final app unit tests | **33 passed, 0 failed, 0 skipped** | `search-pulse-policy-app.xcresult` |
| Signed generic iOS build | **Succeeded** | `search-pulse-policy-device.xcresult` |

The initial post-change replay (`search-pulse-policy-green.xcresult`) exposed a stalled simulation clock while awaiting the remaining budget; the documented fixture correction, rather than a production timeout change, resolved it. The full SDK was rerun after the review-driven planner/observer change. Gate counts overlap and are not summed.

Simulator: iPhone 17 Pro / iOS 26.5, destination `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, serial tests and 60-second allowances. SDK command: `./scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -resultBundlePath <bundle>`. App gate used the `PhroverOperator` project/scheme, Debug, the same destination/settings, `-only-testing:PhroverOperatorTests CODE_SIGNING_ALLOWED=NO`. Signed build used `-destination 'generic/platform=iOS' -allowProvisioningUpdates`.

Installed `us.astral.phrover` successfully on the paired **iPhone 15 Pro** at **16:40 PDT**, device `FC11C836-4978-5B20-9170-16EAD18568BE`, installation sequence **2156**. No app launch or physical movement test was initiated. Existing `UIScreen.main` deprecation and launch-configuration warnings remain; no build errors. Whitespace checks passed.
