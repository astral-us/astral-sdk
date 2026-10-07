# Follow-turn pre-send expiry: narrow amendment and evidence

Date: 2026-10-06. Base revision: `dc86497`.

This user-approved amendment supplements the [adaptive turn-burst design](2026-10-05-follow-me-adaptive-turn-bursts-design.md), particularly its sender-entry timing and failure-delivery requirements. It does not replace the earlier assets. Terminology follows `CONTEXT.md`.

## Classification and operator behavior

Only a typed transport `.expired` denial with an explicitly expired, unacknowledged receipt, exactly zero attempts, no HTTP status, and no captured transport attempt is definite pre-send expiry. Cancellation, owner/recovery fencing, runtime health/watchdog failure, and unconfirmed motor stop retain precedence. An entered request with a failed/expired response remains uncertain motion and `.commandFailed`; contradictory receipt/attempt facts do not qualify as not-started. Successful responses and rejected calibration brackets do not acquire this subtype.

Reuse public `NavigationFailure.rotationResolutionInsufficient`. An internal typed `FollowTurnFailureCause.burstPreSendExpired` travels in captured operation context through contextual results, stream deliveries, and the coordinator's keyed reducer. The stable diagnostic reason is `burst_pre_send_expired`; the existing observed-resolution reason/text remains the default when that cause is absent.

Operator messages:

- Pending: **Turn not started: command scheduling exceeded burst budget. Confirming motor stop…**
- Confirmed: **Turn not started: command scheduling exceeded burst budget. Stop confirmed. Restart following to try again.**
- Failed stop, highest priority and sticky: **Motor stop could not be confirmed. Motion is blocked.**

The specific cause is available before an actual held stop acknowledgement returns. Generic wrappers, delivery ordering, cancellation, and stale success cannot erase it or authorize restart. No learning, arrival, automatic retry, or readiness handoff follows this terminal expiry.

## Prepare, then arm

Prepare trace buffers, source observers, transport capture, authorization closures, and both controller-owned monitor tasks before the sender epoch. Monitors wait for an explicit operation-local arming signal; abandoning preparation releases their bounded waiters. There is no artificial zero deadline or unarmed authorization.

`send_begin` is a preparation event: its sender-entry/deadline fields are null and availability is `not_armed`. Synchronous formatting and sink I/O finish before final validation. Revalidate cancellation, owner, stop latch, recovery authority, cached ACK, source freshness/generation/stop fence, current health, and the prepared source yaw. A changed yaw invalidates that prepared direction/budget rather than rebasing the frozen target. Unarmed source observers cannot publish a crossing/budget claim. Repeat the cheap ownership/source-yaw fences after the last clock/provider read.

Capture the entry uptime, arm exactly one immutable epoch/deadline, perform only synchronous token/timing bookkeeping, and immediately invoke the sender. No logger I/O, task creation, ACK refresh, or suspension is inserted between arm and invocation. Queueing to `RoverControl`, request preparation, the necessary MainActor eligibility hop, request latency, and retries after invocation still consume that same budget. The deadline is never moved to HTTP start or authorization completion.

After sender return, retain precise captured entry/response and preparation-duration facts in chronological diagnostic emission. Add bounded transport stamps for actor entry, authorization start/end, final eligibility, and request start. Legacy senders expose null timing with `not_exposed_by_sender`, rather than invented measurements. These stamps use the shared uptime domain and capture facts without logger I/O inside eligibility.

## Evidence and limits

Read-only device artifact: `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-dc86497-runtime-backgrounded.log`.

| UTC window, 2026-10-06 | Requested budget | Entry-to-return | Attempts | Sender result |
| --- | ---: | ---: | ---: | --- |
| 22:00:43, lines 312639–312654 | 32.545 ms | 116.931 ms | 0 | expired, subsequently stop-confirmed |
| 22:01:40, lines 312790–312800 | 2.374 ms | 133.080 ms | 0 | expired, subsequently stop-confirmed |

Both were incorrectly reported as `.commandFailed` / `transport_failed`. The operation executor's blanket sender-failure mapping confirmed the classification defect. A deterministic 100 ms synchronous diagnostic-cost test confirmed that setup incorrectly consumed the sender budget. The log does not separately measure how much of device delay was logging, actor scheduling, or competing MainActor work. At this revision, the attempt gate already validates cached ACK synchronously; a separate monitor performs asynchronous ACK refresh.

Moving preparation fixes the epoch violation; it does not guarantee that a 2.374 ms budget can admit an HTTP command. Residual queue expiry must remain an honest terminal scheduling-resolution failure. Host budget is not physical motor-on duration or a guarantee of small-angle accuracy.

## TDD and verification

All tests run on the existing iOS simulator, with serial selectors through `astral-sdk-Package` and no live rover requests.

- Original three-test reproduction: **2 RED, 1 PASS**, then **3 GREEN**. Real `RoverControl` plus URLProtocol verifies zero-attempt expiry, HTTP 503, timeout after one entered request, and the 100 ms preparation-cost model against the recorded 2.374 ms budget.
- Held real stop: RED without pending typed delivery, then GREEN with the cause available before confirmation.
- Transport boundary measurements: RED for missing actor/authorization/eligibility/request stamps, then GREEN.
- Actual coordinator + contextual controller + real `RoverControl`: RED when controller diagnostic fields were dropped, then GREEN retaining cause, epoch and timing through stream/result/confirmation, with every actual HTTP request a stop.
- Preparation-duration diagnostics: RED for missing measurements, then GREEN.
- Pre-arm source ingress/stale-yaw plan: RED, then GREEN with no synchronous crossing claim and no sender invocation.
- Final clock-read owner replacement: RED, then GREEN with no old-owner arm/send.
- Additional regression gates cover preparation cancellation/replacement, sticky failed stop, contradictory zero-attempt receipts with captured entry, and entered-request uncertainty.

The initial scoped verification below did not include the full SDK. The subsequent final verification includes the full non-live SDK and app gates. No commit, push, physical-device installation, or physical-device execution was performed.

### Initial scoped results

**243 passed, 0 failed, 0 skipped.** Final result bundle:

`/Users/hungmai/Library/Developer/Xcode/DerivedData/astral-sdk-evvqlzefexgiypdjbmqhfzwkkuht/Logs/Test/Test-astral-sdk-Package-2026.10.06_15-43-47--0700.xcresult`

| Selected suite | Passed |
| --- | ---: |
| RoverControlTests | 38 |
| NavigationFollowTurnBurstTests | 40 |
| FollowTurnBurstControllerTraceTests | 9 |
| FollowMotionFailureResolutionTests | 7 |
| FollowMeCoordinatorTests | 107 |
| FollowReadyAdmissionIntegrationTests | 42 |

Final command, from the repository root:

```sh
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -only-testing:PhroverKitTests/RoverControlTests \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -only-testing:PhroverKitTests/FollowTurnBurstControllerTraceTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests
```

Additional regression assertions passed for both stream/result orders with cause-absent generic wrappers, stale confirmation rejection, and health precedence over a real zero-attempt expiry. A further RED test exposed early preparation health failure being flattened by the executor's catch; its minimal correction checks owner/cancellation first, runtime failure next, then transport fallback. The controller's failed-stop latch still overrides.

### Independent review

Separate read-only Standards and Spec reviewers inspected the working diff against `dc86497`. Initial findings were corrected and reviewed again:

- Preserve the actual admitted planning source **before** `burst_plan` and pulse diagnostics, not a later sender-time yaw. Expanded RED coverage now checks all three preparation events. Standalone source bootstrap remains compatible; the three regressions found in the first expanded run were corrected.
- Capture the request-start clock before the final transport gate. A RED clock-expiry regression proves no HTTP creation or invented entered attempt after that read. Only concrete bounded locked bookkeeping follows final eligibility; injected attempt observers are notified after actual request drain using the retained entry stamp.
- Protect URLProtocol fixture configuration, request history, counters, held requests and result removal with a lock; all client/injected callbacks run outside it.

Both independent follow-up reports found **no blocking correctness/spec deviations**. The final three-line health-precedence correction also received a separate independent read-only review with no blockers. Optional duplication/style smells were not expanded into a broad redesign. Existing unrelated `.serena`, `.opencode`, `AGENTS.md`, and workflow assets were preserved. `git diff --check` passed.

## Latest-source final verification

Completed 2026-10-06 after the latest zero-attempt expiry implementation and reviewed fixes, with HEAD still **`dc86497`** and the implementation uncommitted. This verification session changed only this amendment; no production/test edits were needed. The earlier 243-test result is historical evidence, not substituted for these fresh gates. Independent review above is retained; no new independent review is claimed.

All test gates ran serially on **iPhone 17 Pro / iOS Simulator 26.5**, UDID `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, with both default and maximum execution allowances **60 seconds**, no retries, and no skipped tests. Package selection is the repository's complete non-live `PhroverKitTests` + `RoverNavTests` script selection. No live rover requests or physical-device operations were performed. Simulator test execution uses Xcode's simulator test hosting; the generic-iOS build was build-only, unsigned, with no device installation.

### Actual result-bundle totals

Evidence parent: `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/`. Each row has a corresponding same-stem `.log`.

| Gate / result bundle | Actual passed | Failed | Skipped | Expected failures | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| `zeroexpiry-final-affected-valid.xcresult` | 414 | 0 | 0 | 0 | Passed |
| `zeroexpiry-final-sdk.xcresult` | 769 | 0 | 0 | 0 | Passed |
| `zeroexpiry-final-app.xcresult` | 33 | 0 | 0 | 0 | Passed |
| `zeroexpiry-final-build.xcresult` | — | — | — | — | Build succeeded |

Counts come from `xcresulttool get test-results summary`, not inferred source counts. Traversing `get test-results tests` confirmed **414 / 769 / 33 unique executed selectors**, respectively, all `Passed`, with no duplicate test iterations. Full SDK comprises **750 PhroverKitTests + 19 RoverNavTests**. The 414 affected tests overlap the full SDK; these are not 1,216 distinct tests.

Complete affected-class inventory:

| Class | Passed |
| --- | ---: |
| RoverControlTests | 38 |
| NavigationFollowTurnBurstTests | 40 |
| FollowTurnBurstControllerTraceTests | 9 |
| FollowMotionFailureResolutionTests | 7 |
| FollowMeCoordinatorTests | 107 |
| FollowReadyAdmissionIntegrationTests | 42 |
| FollowTurnBurstPlannerTests | 14 |
| NavigationFollowScanDiagnosticsTests | 76 |
| FollowDiagnosticEventTests | 10 |
| FollowPipelineDiagnosticsTests | 8 |
| FollowReacquisitionDiagnosticsTests | 2 |
| ARFollowMePerceptionSourceTests | 6 |
| NavigationFollowReadySignalTests | 17 |
| NavigationSafetyTests | 26 |
| NavigationRotationWatchdogTests | 12 |

This covers transport, burst planning/execution, source ingress, diagnostic traces, failure reduction, coordinator phases, admission and shared fake-source fixtures through their consuming classes. Phase tests were unchanged but included because the new typed cause/message crosses contextual stream/result/confirmation delivery. App tests were unchanged; its exhaustive `ConversationViewModel.followStatusText` switch forwards `.failed(let message)`, and all four app unit classes passed.

Known prior fixture dispositions remain current: the full SDK passed `ARSharedMissionFrameCalibratorTests/testExpectedMarkerDetectionIsEnqueuedBeforeGroundingStarts`, which checks producer enqueue ordering rather than consumer scheduling; no old calibration failure was hidden by a retry. `FollowReadyAdmissionIntegrationTests/testHealthyFramesArrivingBeforeFeedbackResumesCannotStarveReadyAdmission` passed in both class scope and full SDK with its existing bounded ingress synchronization and exact **`1:6`** expectations for both admission and controller pose frame. No assertion, timeout or fixture was changed here.

### Exact executed gate commands

Affected and SDK commands ran from `/Users/hungmai/Sites/Astral/astral-sdk`; app/build commands ran from `/Users/hungmai/Sites/Astral/astral-sdk/examples/PhroverOperator`.

```sh
xcodebuild test -quiet -scheme astral-sdk-Package \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/zeroexpiry-final-affected-valid.xcresult \
  -only-testing:PhroverKitTests/RoverControlTests \
  -only-testing:PhroverKitTests/NavigationFollowTurnBurstTests \
  -only-testing:PhroverKitTests/FollowTurnBurstControllerTraceTests \
  -only-testing:PhroverKitTests/FollowMotionFailureResolutionTests \
  -only-testing:PhroverKitTests/FollowMeCoordinatorTests \
  -only-testing:PhroverKitTests/FollowReadyAdmissionIntegrationTests \
  -only-testing:PhroverKitTests/FollowTurnBurstPlannerTests \
  -only-testing:PhroverKitTests/NavigationFollowScanDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowDiagnosticEventTests \
  -only-testing:PhroverKitTests/FollowPipelineDiagnosticsTests \
  -only-testing:PhroverKitTests/FollowReacquisitionDiagnosticsTests \
  -only-testing:PhroverKitTests/ARFollowMePerceptionSourceTests \
  -only-testing:PhroverKitTests/NavigationFollowReadySignalTests \
  -only-testing:PhroverKitTests/NavigationSafetyTests \
  -only-testing:PhroverKitTests/NavigationRotationWatchdogTests \
  > /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/zeroexpiry-final-affected-valid.log 2>&1

env SIM_UDID=EEA52712-371D-4FF6-B8EF-A2C78319D57F ./scripts/test-swift-sdk.sh -quiet \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/zeroexpiry-final-sdk.xcresult \
  > /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/zeroexpiry-final-sdk.log 2>&1

xcodebuild test -quiet -project PhroverOperator.xcodeproj -scheme PhroverOperator -configuration Debug \
  -destination 'id=EEA52712-371D-4FF6-B8EF-A2C78319D57F' -only-testing:PhroverOperatorTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/zeroexpiry-final-app.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  > /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/zeroexpiry-final-app.log 2>&1

xcodebuild build -quiet -project PhroverOperator.xcodeproj -scheme PhroverOperator -configuration Debug \
  -destination 'generic/platform=iOS' \
  -resultBundlePath /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/zeroexpiry-final-build.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  > /var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/zeroexpiry-final-build.log 2>&1
```

All four valid gate commands completed successfully. One initial affected command was identical to the valid affected command except it also supplied `-test-iterations 1` and used `zeroexpiry-final-affected.{xcresult,log}`. Xcode rejected that option before compilation/testing: **“Must specify -test-iterations with more than 1 iteration.”** Its bundle reports **0 tests / unknown**, not a failed or passed suite. Removing the unsupported option uses Xcode's default single execution; neither `-retry-tests-on-failure` nor `-run-tests-until-failure` was used. The rejected launch is disclosed and not counted as verification. No valid suite failed, and no optional repeat rounds were run.

Result extraction used these exact command forms with the full bundle paths above:

```sh
xcrun xcresulttool get test-results summary --path <bundle> --format json
xcrun xcresulttool get test-results tests --path <bundle> --format json
xcrun xcresulttool get build-results --path <bundle> --format json
```

### Warnings, whitespace and limits

Actual `get build-results` reports **0 / 0 / 1 / 2 compiler/build warnings** for affected / SDK / app / unsigned build, respectively, and **0 analyzer warnings / 0 errors** in all four. App and build emitted the existing `ConversationView.swift:273:58` **`UIScreen.main` deprecated in iOS 26** warning. Generic-iOS build additionally emitted **“A launch configuration or launch storyboard or xib must be provided unless the app requires full screen.”** Package logs include the existing empty-supported-platforms notice. The known mutable-uptime **Sendable test-fixture capture concern** documented in the adaptive-burst plan was not freshly emitted by these incremental package builds; it remains known and is not claimed fixed or absent from a clean compilation. Warning cleanup was outside this verification scope.

`git diff --check` passed (exit 0, no diagnostics); the new untracked amendment was also checked separately with `git diff --no-index --check -- /dev/null docs/superpowers/specs/2026-10-06-follow-turn-pre-send-expiry-amendment.md` (exit 1 for a new-file difference, no whitespace diagnostics), because ordinary tracked-diff checking does not cover it. Existing unrelated configuration and workflow assets were preserved.

Profile limits remain **fixed signed 0.25 wheel magnitude**, **80 ms maximum host burst budget**, **0.05 rad alignment tolerance** and **7° scan tolerance**. Preparation is outside the sender epoch, but queueing/actor admission/request work after invocation remains inside it. An approximately **2.374 ms** budget can still expire with zero HTTP attempts; that must honestly report terminal scheduling-resolution failure and confirm the serialized stop, not learn motion, retry automatically or claim arrival. These simulator/software results do **not** establish physical motor-on duration, breakaway, braking/coast accuracy, universal small-angle resolution, or overall resolution of the observed physical-device problem. Supervised physical acceptance remains unverified.
