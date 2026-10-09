# Follow departure continuity, torso depth and interrupted search accounting

User approved the fixes identified in the complete 20:54–20:56 PDT device log. Earlier same-day workflow assets remain preserved. Source artifact: `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-person-lost-complete.log` (approximately 113.5 MB; obtained over USB AFC after CoreDevice copies truncated at 110 MB).

## Evidence

Readiness succeeded after 14 pulses. The baseline range was 1.602 m, so the unchanged +0.30 m departure gate was about 1.902 m. One `no_matching_body` frame at 20:55:02.422 immediately left waitingForMovement. A valid target returned approximately 471 ms later at 1.963 m, but recovery restarted initial alignment rather than following. Repeated body/depth gaps prevented restoration until the original ten-second recovery deadline expired. During recovery, verified-person feet patches failed the unchanged depth-spread/inlier tests.

The later retry had only three completed search operations and 32 logged cancellations, mostly during stale-frame churn around 0.51–0.56 s. Reserving the requested angle before dispatch consumed the scan budget for canceled work and produced `No person found.`

## Completed-readiness handoff

- The existing bounded stopped verification grace also applies in waitingForMovement when readiness has succeeded and the fixed departure baseline exists. Its original 500 ms cap, nonrenewing deadline, stop/freshness gates, failure precedence and cancellation behavior remain.
- A provisional reacquisition still first stops. It cannot clear its own stop fence or immediately issue a following goal.
- Once a distinct, healthy, same-generation matched observation clears the acknowledged stop/settle boundary, completed readiness resumes the original departure gate. Beyond baseline + departure increment, resume normal following; below it, restore waitingForMovement with the original baseline.
- Do not repeat initial precision alignment or readiness when both readiness and its baseline already exist. If readiness is incomplete or its post-ready baseline is absent, preserve the original alignment/readiness route.
- The post-stop departure/recovery handoff can reuse the coordinator's captured current stop-fence identity rather than introducing another coordinator stop/await that ages its matched frame. This includes a match returning during waiting-for-movement grace. Normal navigation retains its own motion/path/clearance checks. Any stale fence, newer pending frame, changed generation, unconfirmed stop or expired original recovery episode prevents restoration.
- Clear `departurePending` only after restoration succeeds, not on entry to a potentially suspended/failed follow request.

## Verified torso depth

For exactly one independently verified torso, retain the same-frame centroid of its validated shoulders and hips as the depth anchor. Use that coherent torso patch as the primary sample location; project its actual 3D camera ray into world XZ. This avoids mixing moving legs with floor/background at a bounding-box feet midpoint.

Legacy/unverified inputs retain feet sampling. Keep original box/feet visibility, full depth-window bounds, confidence, median/MAD/inlier requirements, calibration and association checks. Invalid torso depth remains rejected; do not silently fall back to a plausible background patch. Diagnostics distinguish `verified_torso` from `box_feet` and include the selected anchor. No cross-frame body evidence, synthetic ground point or threshold relaxation is introduced.

## Perception scheduling

Each live follow perception stream holds an independently releasable inference-consumer token. While any consumer is active, the async UI preview may reuse a valid cached follow result but cannot enqueue inference on a cache miss. Beginning follow also drops a queued preview job; an already-running native request is allowed to drain. Callbacks/continuation resumptions run outside the job lock. Ending one stream cannot release another's priority; terminating the final stream permits preview inference again.

Body inference selects an advertised Neural Engine device when available, otherwise CPU; GPU remains excluded under the existing background-wind-down policy. Actual throughput depends on device support and thermal/load conditions and requires device measurement. The 500 ms freshness limit remains unchanged.

## Search progress versus interruptions

Do not commit an entire requested angle at dispatch. Successful stopped arrivals commit completed requested progress or validated directed measured progress, whichever is greater; legacy pose-only motion retains its arrival contract. Canceled work contributes only same-generation, confirmed-stop, validated **net directed** progress when supplied. Absolute sampled travel is diagnostic, not distinct angular coverage; jitter/reversals must not inflate coverage.

The result's captured request/session identifies the attempt. Same-session accounting may finish after a perception stop replaced its motor owner, but it never grants motion authority or mutates a new session. Terminal result handling remains separate.

Bound search independently by **72 attempts** and **8 interruptions** by default. Reaching the interruption/attempt limit before completing coverage reports `Search interrupted before the scan completed. Wait for stable perception and restart following.` Only a completed rotation budget reports `No person found.` Reject invalid search configuration and generation-fence scheduled terminal actions. These are bounded software budgets, not a hard physical revolution guarantee.

## Regression seams

- Coordinator red/green: completed readiness survives a brief waiting miss; fresh post-stop reacquisition beyond the fixed gate starts following without extra alignment/readiness, and without a redundant coordinator stop.
- Body verification → depth projection → tracker red/green: mixed feet depth is rejected while a verified coherent torso patch grounds correctly; corrupt torso depth remains rejected.
- Live perception stream/async preview red/green: active consumers prevent preview cache misses from adding inference, control still runs, fresh cache identity is retained, and cancellation releases each token independently.
- Coordinator red/green: a canceled request does not consume completed coverage; net progress differs from absolute travel; repeated stale-frame cancellation is bounded with an interruption-specific result.

An initial priority test had an invalid MainActor-isolated native callback and crashed; it was replaced by a lock-protected nonisolated fixture, then replayed with the priority guard disabled to establish an assertion-red before restoring the guard. The crash is not counted as reproduction evidence. Earlier tests requiring another alignment after already completed readiness were migrated while retaining post-stop frame exclusion, fixed-baseline and original-deadline assertions.

## Review refinements

Independent review identified three boundary defects: a preview already dispatched but not started could escape priority, waiting-grace restoration still performed a redundant coordinator stop, and nonpositive scan budgets were silently coerced to one. All three received assertion-red regressions before correction.

The worker now acquires the inference lock and atomically arbitrates preview eligibility against follow consumers immediately before synchronous inference. It releases locks before resuming continuations. A suspended injected worker queue makes this boundary deterministic in tests. Waiting departures and recovery departures share captured-stop identity validation, including pending-frame and stop-latch checks. Scan attempt/interruption budgets must be positive before dispatch. Follow-up review confirmed all three resolved with no new actionable findings in scope.

## Executed verification

Artifacts are under `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/`, with matching `.log` files. Counts come from result bundles; overlapping gates are not summed.

| Gate | Result | Bundle |
| --- | --- | --- |
| Departure/grace regressions before correction | 2 failed | `departure-handoff-red.xcresult` |
| Departure/grace regressions after correction | 2 passed | `departure-handoff-green.xcresult` |
| Torso-depth regression before correction | 1 failed | `torso-depth-red.xcresult` |
| Corrected inference-priority regression with guard disabled | 1 assertion failure | `follow-inference-priority-red-valid.xcresult` |
| Canceled-coverage regression before correction | 1 failed | `scan-coverage-red.xcresult` |
| Detector/source/scan-accounting checks | 21 passed | `scan-priority-focused.xcresult` |
| Broad focused classes | 292 passed | `departure-perception-focused.xcresult` |
| Redundant-stop recovery regression before correction | 1 failed | `departure-extra-stop-red.xcresult` |
| Redundant-stop recovery regression after correction | 1 passed | `departure-extra-stop-green.xcresult` |
| First full SDK checkpoint | 839 passed | `departure-continuity-sdk.xcresult` |
| Review boundary regressions before correction | 3 failed | `departure-review-red.xcresult` |
| Detector/coordinator/admission after review correction | 174 passed | `departure-review-green.xcresult` |
| **Final full non-live SDK** | **841 passed, 0 failed, 0 skipped** | `departure-continuity-sdk-final.xcresult` |
| **Final app unit tests** | **33 passed, 0 failed, 0 skipped** | `departure-continuity-app.xcresult` |
| Signed generic iOS build | Succeeded, no errors | `departure-continuity-device.xcresult` |

An initial combined depth/coordinator gate had four old re-alignment phase expectations; their migrations preserved the important deadline/baseline/fence assertions. The initial and first post-change inference-priority runs exposed the invalid actor-isolated test callback described above. Neither crash is claimed as an assertion-red or a passing test. No failing gate was hidden by an unchanged retry.

All simulator gates used iPhone 17 Pro / iOS 26.5, destination `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, serial execution and 60-second allowances. SDK command: `./scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -resultBundlePath <bundle>`. App used project/scheme `PhroverOperator`, Debug, the same simulator, `-only-testing:PhroverOperatorTests CODE_SIGNING_ALLOWED=NO`. Signed build used `-destination 'generic/platform=iOS' -allowProvisioningUpdates`.

Installed `us.astral.phrover` successfully on the **iPhone 15 Pro at 22:40 PDT**, device `FC11C836-4978-5B20-9170-16EAD18568BE`, installation sequence **2188**. No app launch or physical movement test was initiated. The next rover run must confirm actual following and inference latency. Existing `UIScreen.main` deprecation and launch-configuration warnings remain; whitespace checks passed.

## Standards review

No hard repository-standard violations. The scan-budget validation finding was corrected. One optional design smell remains: search accounting is embedded in the generic movement-dispatch helper; a broader extraction was deferred.

## Spec review

All three actionable findings were corrected and independently rechecked. No remaining correctness findings in the reviewed scope; physical performance is not claimed from simulator tests.

Review summary: Standards — 0 remaining correctness findings / 1 optional maintainability smell; Spec — 0 remaining findings.
