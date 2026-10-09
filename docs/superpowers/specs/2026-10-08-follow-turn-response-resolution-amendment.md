# Follow turn response resolution

User-approved follow-up to the October 8 screenshot/log diagnosis. Supplements the whole-response and stop/look amendments; preserves the existing workflow assets and `CONTEXT.md` terminology.

## Captured failure

The iPhone 15 Pro log at 2026-10-08 20:34:47 UTC recorded a search request shrinking from 4.755 ms to 0.495 ms to 56.409 µs. The last transport eligibility check took 92.125 µs from sender entry; no HTTP attempt entered and stop was confirmed. Prior HTTP responses took approximately 29–30 ms, followed by approximately 33–34 ms stop admission-to-ack. Sampled AR travel divided by the tiny requested duration inflated the retained effective gain to 750.958 rad/s; this was not a physical angular speed.

Artifact: `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-20261008-screenshot-runtime.log`, lines 387705–387807.

## Resolution-aware model

For each complete valid response, define a command/stop window `W = max(requestedBudget, stopAcknowledgement - sendEntry)`. Retain the maximum sampled absolute AR travel divided by W as gain R, never below the provisional reference or compatible inherited search gain. Retain maximum observed overhead `H = max(W - requestedBudget)` separately. Both learn only from complete, valid attributed brackets.

Predict sampled response with `R * (budget + H)`. Plan `min(80 ms, E/R - H, overshootCeiling)`, where E is the heading error outside the unchanged purpose tolerance. A nonpositive or unrepresentable budget resolves as `rotationResolutionInsufficient` while stopped; it does not send a doomed correction, round up the budget, retry, or report arrival. Confirmed stopped observations inside tolerance still complete successfully. Valid corrections above the modeled limit remain supported.

This replaces normalization by requested budget alone. Pending response drain and stopping are measured once in W. Overlapping send/stop diagnostic durations are not added to planning. Sampled coast remains included in angular response and is not subtracted again. Inherited search seeds carry the normalized gain only, as before; target, frames and timing history remain operation-local.

The model is empirical, not a measured physical minimum or proof of future response. Unknown initial operations still permit their existing single provisional probe, and unexpected pre-send expiry retains its honest typed failure. Wheel magnitude, immutable sender deadlines, ownership/freshness fences, watchdogs, stop confirmation and purpose tolerances are unchanged.

## Diagnostics and UI

Publish command/stop window, normalized window gain, retained overhead, modeled zero-budget travel and the revised formula. Keep the old raw travel/requested-budget ratio separately labeled for comparison; clear per-response fields before a subsequent send. Existing resolution-failure wording identifies observed response as too coarse, while actual pre-send expiry keeps its distinct wording.

Talk status wraps vertically in a scrollable layout. Remove the negative microphone offset, and suppress the independent MissionAgent badge when Follow Me or an error already supplies status. Camera/detector details remain visible.

## Regression and verification

The controller-seam replay `NavigationFollowTurnBurstTests/testRecordedSearchOverrunStopsBeforeSubmillisecondCorrection` first failed on the original code: two commands were sent instead of one. With the model correction it passes, returns `rotationResolutionInsufficient` with confirmed stop, and does not classify the event as pre-send expiry. Existing tests retain coverage of executable corrections, frozen targets, overshoot reversal, incomplete evidence, canceled/failed responses, freshness and safety boundaries. Old formula-specific expectations are migrated explicitly.

Physical-device acceptance must separately verify response under the current rover load/link. This change prevents the demonstrated request-budget collapse; it does not claim that all small-angle turns are physically achievable.

### Executed checks

All simulator tests used iPhone 17 Pro / iOS 26.5, destination `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, serial execution and a 60-second per-test allowance. Counts below are from `xcresulttool get test-results summary`; every passing gate had zero failures and skips. Artifacts are in `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/` with matching `.log` files.

| Gate | Result | Bundle |
| --- | --- | --- |
| Original controller replay | 1 failed, 0 passed | DerivedData `Test-astral-sdk-Package-2026.10.08_13-59-28--0700.xcresult` |
| Fixed controller replay | 1 passed | `response-resolution-green.xcresult` |
| Full non-live SDK | 809 passed | `response-resolution-sdk.xcresult` |
| Full app unit tests | 33 passed | `response-resolution-app.xcresult` |
| Post-review planner class and controller replay | 20 passed | `response-resolution-review-boundaries.xcresult` |
| Existing Talk microphone and leave-to-Drive UI tests | 2 passed | `response-resolution-ui.xcresult` |
| Unsigned generic iOS device build | Succeeded | `response-resolution-build.xcresult` |

The full SDK gate used `./scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -resultBundlePath <bundle>`. App/UI gates used the `PhroverOperator` project/scheme, Debug configuration, the same simulator and timeout settings, and `CODE_SIGNING_ALLOWED=NO`; selectors were `PhroverOperatorTests` and the two named `PhroverOperatorUITests` methods. Generic build used `-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`.

The SDK gate preceded one additional planner boundary test, extra assertions and a behavior-neutral local variable rename. The subsequent 20-test gate covers those changes; counts overlap and are not summed. Initial scoped gates exposed obsolete formula-specific expectations (4 failures, then 1 remaining expectation); these were explicitly migrated, not hidden by retries. The final remaining fixture passed before the full SDK gate.

Existing build warnings: deprecated `UIScreen.main` in the camera preview, missing launch configuration/storyboard for non-full-screen apps; package test compilation also reported existing Sendable mutable-clock fixture warnings. `git diff --check` passed. No device installation or physical execution was performed.

## Standards review

Independent read-only review found no documented-standard violations or blocking correctness concerns. Two optional smells: misleading local `budgetRate` name (renamed `windowResponseRate`) and duplication of the small window calculation between planner and diagnostic projection (left local; no broader refactor).

## Spec review

Independent read-only review found no blocking deviations or scope creep. Two non-blocking coverage requests were addressed: exact zero/negative/positive/unrepresentable learned-overhead boundaries, and lower/higher/incomplete overhead retention. Follow-up review confirmed both resolved with no new concerns.

Review summary: Standards — 0 hard violations, 1 remaining optional duplication smell; Spec — 0 remaining findings.
