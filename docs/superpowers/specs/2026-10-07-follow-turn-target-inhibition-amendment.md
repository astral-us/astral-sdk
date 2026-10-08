# Target-Reached Inhibition Is Not a Transport Failure

## Evidence and approved fix

The October 8 04:19 UTC device attempt completed the mandatory 5.06-second pause and one scan segment, then failed during the next segment. A planned 3.6 ms correction was inhibited before HTTP by a fresh pose within angular tolerance. The receipt was `fenced`, with zero attempts, no HTTP status, and stop trigger `tolerance`. Stop succeeded, but the generic send-failure branch terminated search after approximately four seconds.

The user approved correcting this path rather than extending a timeout or weakening stopping. Existing search coverage, startup pause, recovery deadlines, tolerances, freshness, and motion limits remain unchanged.

## Handling

- Record a typed tolerance/crossing reason only when a valid source triggers the first inhibition of a currently authorized, armed burst before its immutable deadline. A later source event cannot relabel earlier expiry, ownership loss, or invalid authority.
- Preserve the real denied receipt. The special path requires typed `fenced`, zero attempts, false acknowledgement, no HTTP status, no captured attempt entry, and the captured target reason. Unknown/custom fences or contradictory evidence retain normal failure handling.
- The executor always confirms stop. A pre-send target trigger is not itself arrival. Only a new post-stop source admitted through existing settle/freshness/generation/ownership gates may establish inclusive target tolerance.
- If that new source remains within tolerance, return ordinary arrival to the existing scan sequencer, allowing search to proceed to its next segment. Do not calibrate an unsent command or manufacture motor travel, HTTP success, or a response bracket.
- If the target no longer holds, fail stopped rather than resend automatically. Tracking loss/staleness, cancellation, deadline/owner invalidation, and failed stops remain authoritative. Expired requests and entered/uncertain transport failures cannot use this path.
- Add `target_inhibition_reason` to sender diagnostics without replacing transport outcome or claiming physical arrival before confirmation.

## Regression evidence

The real navigation-controller/adapter/RoverControl test failed before the production fix with `commandFailed`. With the same URLProtocol seam, tolerance and crossing scenarios now show exactly two HTTP stop requests, zero motion requests, no early completion before a fresh post-stop capture, ordinary arrival afterward, and no calibration response event. Both scan and alignment purposes are covered.

Negative coverage includes post-stop drift outside tolerance, stale post-stop evidence, failed stop, contradictory entered-attempt evidence, actual budget expiry, unknown inhibition, and unhealthy tracking. Locked-token tests prove a target event cannot relabel an earlier expiry/owner fence or expired source validity. Existing full-turn search and cancellation suites retain their bounds and expected outcomes.

Software behavior does not establish physical turn accuracy or human detection quality. No automatic installation, app launch, rover motion, commit, or push is part of this fix.

## Final verification

| Check | Result |
| --- | --- |
| Full non-live SDK | 797 passed, 0 failed, 0 skipped |
| All app unit tests | 33 passed, 0 failed, 0 skipped |
| Unsigned generic-iOS Debug build | Succeeded |
| Whitespace checks | Passed |

Tests ran serially with 60-second allowances. SDK used the repository script; app tests used `PhroverOperatorTests` on simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Fresh result bundles under the approved temporary directory are `unsent-target-fence-sdk-final.xcresult` and `unsent-target-fence-app-final.xcresult`. The original real-controller test executed assertion-red before the fix; a subsequent optional-acknowledgement compile error was corrected before recording green.

Self-review checked typed-denial specificity, first-inhibition priority, no calibration from an unsent request, and post-stop authority checks. No independent review is claimed. Existing older Sendable test-capture, `UIScreen.main`, and launch-configuration warnings remain. The physical iPhone was not launched or moved.
