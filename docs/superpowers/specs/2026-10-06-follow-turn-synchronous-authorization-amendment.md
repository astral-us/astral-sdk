# Follow-Turn Synchronous Transport Authorization

## Approved scope and evidence

The user approved replacing the per-attempt MainActor round trip with a thread-safe, expiring snapshot. This is a narrow amendment to the adaptive-burst and pre-send-expiry specifications. It does not change burst duration, speed, tolerances, retry policy, or failure precedence.

The post-install runtime capture `phrover-scheduling-backgrounded-latest.log` records a 15.229 ms alignment budget. Sender-to-RoverControl actor entry took approximately 0.050 ms; authorization start to completion took 64.862 ms. The first HTTP attempt was refused as expired. Subsequent stopping was acknowledged. These facts identify authorization latency, not network response time or physical wheel motion.

## Implementation contract

- Validate controller ownership, cancellation, stop latch, recovery authorization, source provenance, stopped-frame fence, progress watchdog, and cached ACK policy on MainActor before arming.
- Publish only an immutable validity interval into an operation-owned locked fence. Production transport authorization has no asynchronous MainActor callback.
- Derive the interval's exclusive upper bound from the earliest source-freshness, existing progress, required ACK-freshness, and recovery-deadline boundary. Inclusive source/ACK freshness is represented with the next representable boundary; watchdog and recovery expiry remain exclusive. Date-based remaining intervals are projected at validation onto the common system-uptime clock; the existing runtime monitors continue checking their original clocks.
- Source ingress validates new facts before refreshing the interval. Unhealthy source, invalid stopped-frame provenance, target crossing/tolerance, cancelled ownership, or failed recovery authorization revokes the same token. Revocation is irreversible.
- Each HTTP attempt checks the locked interval and inhibition state synchronously. Unvalidated authority, nonfinite/retrograde time, or expired validity cannot enter HTTP, even if the burst budget itself remains available.
- The original immutable send-entry deadline still includes queueing and request preparation. Transport cancellation, expiry, and authorization checks remain immediately before HTTP entry and after retry backoff. Generic sends and STOP retries are unchanged.
- An asynchronous callback remains available for legacy/custom authorization callers; the production prepared-controller path does not use it. No thread outside MainActor reads mutable controller state.
- Never treat a denied send as motion, learn a response from it, claim arrival, retry an expired command, or downgrade failed-stop inhibition.

## Regression evidence

`RoverControlTests/testPreparedControllerAuthorityDoesNotSpendBurstBudgetOnActorReauthorization` first failed with zero requests and an expired receipt against the old callback path, then passed with exactly one acknowledged request and the unchanged 15.229 ms deadline. The initial test compilation issue was resolved before recording the behavioral red.

Additional coverage checks unvalidated/inhibited authority, expiry before HTTP and after retry backoff, and a real controller's source aging beyond 500 ms without delivering another MainActor observer event. The existing stopped-frame regression now invokes the synchronous transport predicate instead of force-unwrapping the removed production async callback; its stale-source and no-send assertions remain.

## Limits

This removes the measured MainActor authorization scheduling bottleneck. It does not promise that every tiny burst can enter transport, that a pending send can be overtaken, or that host timing bounds physical motor-on duration. Expiry still refuses the command and requires serialized stop confirmation. Physical validation is a separate operator-authorized step.

Changes remain uncommitted and are not installed by this task. Unrelated workspace changes and prior workflow assets are preserved.

## Review corrections and final verification

- Cancellation/detection revokes the locked token before any synchronous diagnostic callback. A regression observed still-valid authority inside the old cancellation callback, then passed for detection, explicit Stop, and cancel after the correction.
- The predicate checks both its snapshot validity interval and the immutable armed burst deadline using its final sampled time. A scripted pre-deadline eligibility read followed by a post-deadline predicate read now produces zero HTTP attempts and an expired receipt.
- Naming uses `publishValidity` to distinguish publication from transport-side validation. Independent review found no remaining high/medium safety finding; the minor repeated denial-result construction remains an optional maintainability suggestion.
- The first full suite exposed an existing concurrent-stop cleanup race: a follower overwrote the owner's contextual stop-failure message. The existing regression failed before the correction. One designated cleanup owner now publishes terminal state and clears the stop task; other waiters only await its result. The regression passed five executions, and scoped review found no blocking issue.

Final checks ran serially with 60-second per-test limits:

| Check | Result |
| --- | --- |
| Full SDK | 774 passed, 0 failed, 0 skipped |
| All app unit tests | 33 passed, 0 failed, 0 skipped |
| Unsigned generic-iOS Debug build | Succeeded |
| Whitespace | Passed |

The SDK command was `scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`, with a fresh result bundle. App verification used `xcodebuild test` for `PhroverOperatorTests` on simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`; the build used `generic/platform=iOS` and `CODE_SIGNING_ALLOWED=NO`.

Final result bundles: `synchronous-authority-sdk-verified.xcresult` and `synchronous-authority-app-verified.xcresult` under the approved temporary evidence directory. The initial failed full-suite bundle is retained as `synchronous-authority-sdk-final.xcresult`.

Existing warnings remain: mutable-uptime Sendable captures in older test fixtures, `UIScreen.main` deprecation, missing launch configuration, and Xcode's package supported-platform notice. No warning is claimed fixed by this change. Software verification does not establish physical response or braking accuracy.
