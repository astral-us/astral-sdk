# Separate Follow-Turn Ingress and Control Evaluation Times

## Confirmed bug and approved correction

The user approved fixing the October 7 post-install calibration rejection. Complete healthy archives were rejected as `nonadvancing_source`: the first ingress witness was replaced with its later control-read collection time, while the next witness kept its original earlier ingress time. Camera/source timestamps themselves advanced normally.

In the captured alignment, frame 1705 was relabeled with collection uptime 80668.199795 while frame 1706 retained actual ingress uptime 80667.998658. The scan showed the same mixing. This was an evidence-assembly defect, not proof of a backwards camera clock.

## Contract

- Every ingress witness keeps its original collection timestamp, source timestamp, frame/generation, yaw, and collection-health facts. The ordered archive is never rewritten to represent control reads.
- Planning and stopped evaluation are separate immutable response facts. Their frame, source timestamp, yaw, generation, and clock must exactly match the corresponding ingress endpoints.
- Each control read must be healthy, finite, no earlier than actual ingress, and source-age-valid at the read (0 through 500 ms inclusive). Planning must precede sender entry. Stopped evaluation must follow acknowledged stop plus the unchanged 300 ms settle; its source capture must be strictly after acknowledgement.
- Ingress monotonicity, operation attribution, complete contiguous ranges, non-repairable unhealthy collection evidence, and existing stop/source gates remain intact.
- Adjacent response brackets reuse the exact archived endpoint, not a rewritten evaluation-time sample. A reused endpoint does not become a new source observation or refresh its timestamp.
- Optional response evaluation fields are additive and default to nil, preserving legacy consumer-sampled response construction. Production archive-backed responses always supply both read facts.
- Diagnostics keep original `source_bracket.collection_uptime_s` and log separate `planning_control_evaluation` / `stopped_control_evaluation` objects with `evaluation_uptime_s`.

The change does not relax turning tolerances, change wheel speeds, extend budgets/deadlines, bypass stopped admission, or retry a partial readiness move. Small-angle latency/coast can still yield a genuine resolution failure after valid evidence is learned.

## Regression evidence

Before the production correction, both a delayed-read response test and a real-controller coalesced-delivery test failed. They reproduce a first control read after subsequent ingress captures, preserving healthy same-generation data.

After correction, the same selectors pass, including exact ingress timestamps in diagnostics. Additional checks cover stale/early/mismatched evaluations, true collection/source-time regression, and a second response sharing the prior ingress endpoint without replay or timestamp rewriting.

Changes remain uncommitted and are not installed by this task. Final review and verification evidence will be added after execution.

## Final verification

Both reproductions executed assertion-red before the production correction and passed with the same selectors afterward. The controller fixture now models archive captures occurring before delayed planning reads, instead of giving archive and control the same collection time. Diagnostic assertions require the unchanged ingress timestamps and separately recorded evaluation times.

Additional tests preserve genuine source/collection monotonicity, reject stale/premature/mismatched read facts, and accept the second response sharing its exact canonical archived boundary. Existing unhealthy-collection, missing-archive, failure-priority, and stopped-arrival coverage remains intact.

| Gate | Result |
| --- | --- |
| Full SDK | 783 passed, 0 failed, 0 skipped |
| All app unit tests | 33 passed, 0 failed, 0 skipped |
| Unsigned generic-iOS Debug build | Succeeded |
| Whitespace | Passed |

Tests ran serially with unchanged 60-second per-test allowances and no exclusions. SDK used `scripts/test-swift-sdk.sh`; app used `PhroverOperatorTests` on simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Build used Debug, `generic/platform=iOS`, and `CODE_SIGNING_ALLOWED=NO`.

Fresh bundles in the approved temporary directory: `ingress-boundary-time-sdk-final.xcresult`, `ingress-boundary-time-app-final.xcresult`, and `ingress-boundary-time-scoped.xcresult`.

Spec/safety review found no high/medium issue in scope. Standards found no hard breach and requested clarification of the reused sample type's evaluation-time health semantics; those comments were updated. Existing older test-capture warnings and launch-configuration warning remain. The physical iPhone was not launched or moved.
