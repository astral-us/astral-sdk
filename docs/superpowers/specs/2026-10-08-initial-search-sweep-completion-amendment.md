# Initial person search: directed sweep completion

User-requested follow-up to the 15:17 screenshot after installing the response-resolution correction. This amendment narrows completion semantics for initial person search; alignment and absolute recovery retain their heading gates. Earlier workflow documents are preserved.

## Device evidence and reproduction

Pulled iPhone 15 Pro `Documents/phrover-runtime.log` to `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-20261008-1517-runtime.log`.

At 2026-10-08 22:16:41 UTC (15:16:41 PDT), the second initial-search step requested 10 degrees with a 13.269 ms budget. The HTTP request succeeded; send-to-response was 52.204 ms and the complete command/stop window was 87.538 ms. Valid AR evidence measured 0.483189 rad (27.68 degrees) of forward travel. Motor stop was confirmed. Exact-heading correction then failed with a -40.484 ms candidate budget, producing the screenshot's coarse-response error.

This is not another pre-send expiry or failed stop. Initial search was treating an already swept arc as an exact-heading destination and terminating the whole search. The controller replay failed before the change with `rotationResolutionInsufficient` instead of sweep completion. A second coordinator regression failed before enabling sweep intent and measured overshoot accounting.

## Completion contract

- The coordinator explicitly marks **initial searching** requests as directed search sweeps. It does not derive motion policy from a diagnostic phase string. Default/unmarked calls, alignment, and absolute recovery remain exact-heading operations. Recovery task-local heading or authorization also prevents sweep mode.
- The target and sender timing remain frozen. Each motor burst uses the existing 80 ms maximum, fixed wheel magnitude, transport authorization, cancellation/ownership fences, source health, watchdog and confirmed-stop boundaries.
- After an acknowledged send, confirmed stop and fresh settled source, a complete valid attributed response bracket contributes signed progress and absolute sampled travel. Once progress in the requested direction reaches the requested arc less the unchanged 7-degree scan tolerance, the search operation completes. It never reverses to correct overshoot of an initial search arc.
- Missing/rejected response evidence, wrong-way progress, unconfirmed stop, runtime failure and cancellation do not acquire this completion. An initial increment already inside tolerance may finish without sending, as before.
- `NavigationResult.arrived` means this **search operation completed**, not exact-heading arrival or person acquisition. Explicit `completion_policy`, `completion_reason`, `heading_within_tolerance` and signed/absolute sweep measurements distinguish these facts in diagnostics. A later pose by itself cannot manufacture directed sweep evidence after a burst.

## Search continuation and limits

The coordinator remains `searching`, performs the existing stationary look interval and requires a fresh post-interval perception frame before another step. It only acquires a person through the existing detection/body/projection gates.

Each request already reserves its requested angle. A matching, successful, stop-confirmed result with same-generation valid calibration additionally charges `max(0, sampledTravel - reservedStep)` against the finite scan budget. Undershoot never refunds the reservation. This prevents overshoot from extending a requested revolution into many physical revolutions. The account saturates at the configured limit (at most 2π) and does not claim a hard bound on unsampled physical motion. After budget exhaustion and the look interval, an empty search ends with `No person found.` rather than launching more turns.

Failed, stale, canceled, mismatched or unconfirmed results cannot contribute successful sweep accounting or learned search gains. Recovery retains its original deadline and absolute segment/stage checks.

## Regression seams

- Actual contextual navigation controller: replay captured 13.269 ms request / 27.68-degree overshoot and confirm one forward burst, successful search completion, measured travel and confirmed stop. Also exercise negative requested direction, wrong-way movement, missing response archive and failed stopping.
- Existing exact-heading controller regression still resolves excessive response without an ineffective microsecond retry.
- Coordinator with contextual motion boundary: initial sweep intent, measured overshoot charges the next remaining request, full look/fresh-frame requirement, still-searching state and finite exhaustion without extra turns.

The change does not weaken person verification or claim physical-device success without a subsequent rover run.

## Verification and deployment

Artifacts are under `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/`; bundles have matching `.log` files. Simulator gates used iPhone 17 Pro / iOS 26.5 (`EEA52712-371D-4FF6-B8EF-A2C78319D57F`), serial execution and 60-second test allowances. Counts were read with `xcresulttool get test-results summary`.

| Gate | Result | Bundle |
| --- | --- | --- |
| Captured controller replay before fix | 1 failed | `search-sweep-red.xcresult` |
| Captured replay plus preserved exact-heading behavior | 2 passed | `search-sweep-green.xcresult` |
| Coordinator intent/coverage regression before fix | 1 failed | `search-sweep-coordinator-red.xcresult` |
| Coordinator regression after fix | 1 passed | `search-sweep-coordinator-green.xcresult` |
| Initial focused classes | 247 passed | `search-sweep-focused.xcresult` |
| Initial SDK checkpoint | 814 passed | `search-sweep-sdk.xcresult` |
| Review-discovered completion bypasses before fix | 2 failed | `search-sweep-review-red.xcresult` |
| Controller, coordinator, real transport classes after review fixes | 203 passed | `search-sweep-review-green.xcresult` |
| Final full non-live SDK | **815 passed, 0 failed, 0 skipped** | `search-sweep-sdk-final.xcresult` |
| Final app unit tests | **33 passed, 0 failed, 0 skipped** | `search-sweep-app.xcresult` |
| Signed generic iOS build | **Succeeded** | `search-sweep-device.xcresult` |

SDK command: `./scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -resultBundlePath <bundle>`. App command: `xcodebuild test -quiet -project PhroverOperator.xcodeproj -scheme PhroverOperator -configuration Debug -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' -only-testing:PhroverOperatorTests` with the same serial/timeout flags and `CODE_SIGNING_ALLOWED=NO`. Signed build: `xcodebuild build -quiet -project PhroverOperator.xcodeproj -scheme PhroverOperator -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates -resultBundlePath <bundle>`.

Installed successfully at 15:39 PDT on the paired iPhone 15 Pro (`FC11C836-4978-5B20-9170-16EAD18568BE`) using `xcrun devicectl device install app`, bundle `us.astral.phrover`, installation database sequence **2140**. No app launch or rover motion was initiated. Existing `UIScreen.main` deprecation and launch-configuration warnings remain; no build errors. Working-tree whitespace check passed.

## Standards review

Independent read-only review found no hard repository-standard violations. It identified the unsent-target completion bypass described below and one optional diagnostic-projection smell (completion wording reads locally populated fields); no broad diagnostic refactor was introduced.

## Spec review

Independent review identified two correctness gaps: heading-only success on a zero-attempt target-inhibited retry, and allowing wrong-way response to be overcome by later forward travel. Both received failing controller-seam regressions before fixes. The first uses real `RoverControl` with stubbed HTTP and a valid partial response followed by a target-inhibited retry; the second supplies a valid subsequent forward response if the controller erroneously retries. The executor now refuses sweep success on the unsent path and rejects opposing signed response before accumulating travel. Exact-heading behavior remains unchanged. Follow-up review confirmed both resolved with no remaining correctness concerns in scope.

Review summary: Standards — 0 hard violations, 1 optional diagnostic-projection smell; Spec — 0 remaining correctness findings.
