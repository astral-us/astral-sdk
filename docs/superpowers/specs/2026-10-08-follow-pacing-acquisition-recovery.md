# Follow pacing, edge acquisition and small recovery responses

The user approved fixing all three findings from the 16:53 log analysis. This amendment supplements the earlier same-day turn/stop corrections and preserves their workflow assets.

## Evidence and scope

`phrover-20261008-1653-runtime.log` under the temporary evidence directory recorded 154.5 degrees of completed initial-search progress in 41.9 seconds: 52 pulses, approximately 20.2 seconds settling and 15.2 seconds looking. At 23:52:20 UTC, a person at about 1.4 m was repeatedly accepted and rejected as `invalid_person_box`. Accepted boxes ended at 99.94–99.95% of image width; rejected bounds were not logged, so numerical overrun was a hypothesis rather than a proven coordinate value. At :21, exact-heading recovery measured a small valid response but failed with a negative host-overhead-derived budget.

## Perception geometry

`PersonBodyVerifier` may intersect an otherwise positive finite detector box with the unit image only when no edge exceeds it by more than **0.002 normalized units (0.2%)**. It still requires exactly one matching independent torso with valid shoulders/hips and confidence. Material out-of-frame boxes remain invalid. Decisions now include raw input bounds, normalized bounds and a specific box issue; no images or pixel arrays are logged.

The same normalized box flows into depth projection and tracking. Explicit same-frame body verification permits normalized side/top boundaries at 0 or 1; legacy/unverified inputs retain strict interior-box requirements. Feet must remain strictly above the bottom edge, the full depth neighborhood must be in bounds, and all original depth/confidence/geometry/association checks remain. No inward epsilon or manufactured feet are used to disguise clipping.

## Brief acquisition misses

Only an **aligning**, previously body-verified lock with an otherwise healthy frame and raw person verification rejected as `invalid_person_box` or `no_matching_body` receives grace. The coordinator inhibits motion, cancels alignment and confirms stopping; it remains aligning without displaying a current matched target or authorizing motion on missing evidence.

Grace has a **fixed first-miss deadline of at most 500 ms**, capped by any existing recovery deadline. Repeated misses do not renew it. A healthy, body-verified continuity match clearing the newest stop/freshness/settling fence releases the hold. Expiry enters normal recovery. Ambiguity, a different projected candidate, actual absence of a raw person, inference failure or tracking failure do not acquire this grace. Stop failure remains terminal. Stop, lifecycle inhibition and alignment cancellation clear the hold and its timer.

## Faster initial-search cadence

- The default post-step look interval is **100 ms**, reduced from one second. The existing healthy processed-capture-after-interval and advancing-frame requirements remain; callers can still configure a longer look interval.
- Between initial-search bursts, source admission may finish early after **100 ms** of contiguous advancing AR evidence after the stop ACK. Over the retained window, yaw drift is at most **0.01 rad**, position drift at most **0.01 m**, and adjacent capture gaps at most **100 ms**. Duplicate immutable frames do not advance the window; gaps, changed generations, invalid sources or excessive drift reset it.
- If early stable evidence is unavailable, preserve the existing **300 ms** settling path. Initial preflight and precise alignment/recovery retain their normal 300 ms waits. This is sampled pose stability, not a certificate of physical rest.
- Pulse limits, wheel magnitude, stop serialization, source/owner fences, detection cancellation and the original progress watchdog remain unchanged. Diagnostics distinguish the minimum observation wait from actual elapsed settling and record the early/fallback policy.

## Recovery/precise-heading repeat rule

Host round-trip overhead does not prove a physical minimum turn. Retain the last complete valid burst's requested budget, signed response and absolute sampled travel. When the precision model would shrink below that budget or return a negative candidate, that **same successful budget** may be repeated only if:

1. The response made nonzero progress in the current target direction.
2. Its full absolute sampled travel fits within `abs(current heading error) + purpose tolerance`.
3. There is no terminal evidence fault or retained overshoot ceiling.

The repeated budget is never enlarged and remains at most 80 ms. The frozen heading, absolute recovery stage/segment arrival checks, unchanged purpose tolerance, recovery deadline, source validity and progress watchdog still determine completion. Missing/incomplete, zero or wrong-way response cannot justify this repeat; overshoot ceilings are never bypassed. This empirical reuse is not a guaranteed bound on future physical motion. Diagnostic candidate budget retains the inverse-model value, while `repeatable_observed_budget_s` and `budget_selection_reason` explain the actual choice.

## Regression seams

Each requested behavior received assertion-red evidence before its change:

- Body verification → actual depth projection → tracker: alternating 0.9995/1.0005/1.0 right edges preserve a valid torso track; material clipping, absent torso and unavailable feet remain rejected.
- Coordinator: brief misses hold stopped, restored matched evidence resumes acquisition, repeated misses cannot extend the original deadline, failed stopping stays failed, and cancellation prevents late recovery.
- Controller: replay the recorded 1.2-degree response and repeat the same 25 ms budget toward the frozen exact heading instead of declaring a minimum-resolution failure.
- Production coordinator: fresh perception after the short look can authorize the next step; a pre-boundary capture cannot.
- Controller/source admission: stable post-stop poses release the extra wait; insufficient history, drift, duplicate frames and gaps do not obtain early admission.

Old tests tied specifically to the one-second default now explicitly configure that long interval; production-default pacing has its own regression. Old formula-specific terminal expectations were migrated to measured-repeat expectations. Initial compilation needed an explicit `[FollowProjectionEvidence]` annotation after adding a multi-statement mapping closure; no production behavior was relaxed to address that compiler error.

## Review refinements

An additional first-miss deadline regression delivered a valid matched frame after the deadline without waking timer sleepers. It failed before inline checks were added. Both matched and repeated-miss paths now enforce the original deadline independently of timer delivery; cancellation and stop failure remain covered.

Independent reviewers found two early-settling defects: pre-ACK pose history could supply part of the required observation duration, and comparing each pose only to an anchor allowed opposite excursions larger than the stated drift bound. Both received assertion-red regressions. The final gate retains at most **32 contiguous immutable poses**, checks each new pose against **all** retained poses, and starts its timing window at an actual capture strictly past the ACK and frame/time fences. Follow-up review confirmed both resolved. Insufficient history falls back to the existing 300 ms path rather than inventing stable evidence.

## Executed verification

Artifacts are under `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/`, with matching logs. Counts below were extracted from result bundles; overlapping suites are not summed.

| Gate | Result | Bundle |
| --- | --- | --- |
| Edge acquisition regression before fix | 1 failed | `edge-acquisition-red.xcresult` |
| Perception/projection/tracker classes | 43 passed | `edge-acquisition-green-valid.xcresult` |
| Acquisition hold regression before fix | 1 failed | `acquisition-hold-red.xcresult` |
| Coordinator class after hold fix | 113 passed | `acquisition-hold-green.xcresult` |
| Small recovery response before/after fix | 1 failed → 1 passed | `recovery-small-response-{red,green}.xcresult` |
| Short look / early settling before fix | 1 failed each | `search-look-red.xcresult`, `search-settle-red.xcresult` |
| Pacing regressions after fix | 2 passed | `search-pacing-green.xcresult` |
| Focused classes after expectation migrations | 370 passed | `follow-stability-focused-final.xcresult` |
| Inline grace-deadline regression before correction | 1 failed | `acquisition-hold-deadline-red.xcresult` |
| First full SDK checkpoint | 825 passed | `follow-stability-sdk.xcresult` |
| Review-discovered settling boundaries before correction | 2 failed | `stable-window-review-red.xcresult` |
| Controller/coordinator classes after correction | 166 passed | `stable-window-review-green.xcresult` |
| **Final full non-live SDK** | **827 passed, 0 failed, 0 skipped** | `follow-stability-sdk-final.xcresult` |
| **Final app unit tests** | **33 passed, 0 failed, 0 skipped** | `follow-stability-app.xcresult` |
| Signed generic iOS build | Succeeded, no errors | `follow-stability-device.xcresult` |

The initial geometry build failure (`edge-acquisition-green.xcresult`) executed zero tests and is not counted as verification. An initial broad focused gate (`follow-stability-focused.xcresult`) had seven obsolete timing/formula expectations; their explicit migrations are described above. No failed gate was hidden by an unchanged retry.

Simulator: iPhone 17 Pro / iOS 26.5, `EEA52712-371D-4FF6-B8EF-A2C78319D57F`; all gates ran serially with 60-second test allowances. SDK command: `./scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -resultBundlePath <bundle>`. App gate used project/scheme `PhroverOperator`, Debug, that simulator, `-only-testing:PhroverOperatorTests`, the same serial/timeouts and `CODE_SIGNING_ALLOWED=NO`. Signed build used `-destination 'generic/platform=iOS' -allowProvisioningUpdates`.

Installed `us.astral.phrover` successfully on the **iPhone 15 Pro** at **17:57 PDT**, device `FC11C836-4978-5B20-9170-16EAD18568BE`, installation sequence **2164**. No app launch or physical movement test was initiated. The next device run must measure actual cadence and acquisition stability. Existing `UIScreen.main` deprecation and launch-configuration warnings remain; whitespace checks passed.

## Standards review

No hard repository-standard violations. The two concrete settling findings were corrected and independently rechecked. One optional duplication smell remains in the explicit verified-edge predicate shared in shape by projection and tracking; a broad geometry refactor was not introduced.

## Spec review

No remaining actionable correctness findings after follow-up review. Normalization/provenance, grace deadlines, measured-budget reuse and bounded settling meet the amended scope; no physical performance guarantee is claimed.

Review summary: Standards — 0 remaining correctness findings / 1 optional duplication smell; Spec — 0 remaining findings.
