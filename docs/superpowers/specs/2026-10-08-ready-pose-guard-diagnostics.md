# Ready signal: distinguish pose-envelope rejection from missing progress

User requested diagnosis/fix for the 19:59 screenshot. This is a diagnostic/reporting correction; the physical cause of the latest readiness deviation is not yet established. It does not relax motion limits or change pulse settings.

## Evidence and remaining uncertainty

Artifact: `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-20261008-1959-runtime.log`.

- Search and alignment succeeded; readiness was pending at uptime **162562.432953** and authorized at approximately **162562.525108**.
- Two 0.25-output, 40 ms readiness pulses completed with confirmed stops at **162562.586850** and **162562.748831**. Pre-pulse longitudinal readings were approximately **0.000023 m** and **0.000790 m**.
- Failure occurred at **162562.900313**, less than half a second after readiness preparation. Stable UTC/monotonic timestamps rule out the normal 2.5-second progress or five-second overall timeout for this run.
- The readiness controller also returned `.stalled` for travel beyond 12 cm, backward displacement beyond 2 cm, sideways drift beyond 2 cm, or heading change beyond 0.10 rad. All were formatted as “insufficient measured progress.”
- The failing controller pose and individual violated bounds were not logged. Earlier detector-paired poses cannot substitute for the later controller sample. The old artifact therefore cannot establish which envelope bound fired or whether motion came from the chassis, phone handling or a pose correction.

Further motor tuning from this artifact would be a guess. The next device run must capture the rejected pose; asking whether the rover veered/turned or the phone was moved provides useful additional physical context.

## Diagnostic correction

Preserve public `NavigationFailure.stalled` and existing stop behavior, but carry a typed internal cause for each readiness guard: travel limit, backward movement, lateral deviation, heading deviation, progress timeout, overall timeout, pre-send pose shift and invalid computed geometry. Rename the internal shared cause enum to `FollowMotionFailureCause` because it now covers readiness as well as turns.

Split the existing compound geometry check without changing its limits. Capture immutable start/current poses, signed and absolute displacements, heading change, source frame/timestamp/read time/age, elapsed time, progress checkpoint age, pulse index and every relevant limit at the exact rejected evaluation. Emit `follow_ready.failure` and carry those same measurements through stream/result/confirmation failure deliveries. Cleanup must not replace the rejected sample with a later camera pose.

The operator message names the actual guard and stop state. A confirmed failed stop retains highest-priority “Motion is blocked” wording. Generic wrappers cannot erase an already captured typed cause or measurements. Unrelated generic navigation failures retain their existing wording.

Add start/stop-return pose snapshots and pulse index to `follow_ready.pulse_stopped`; explicitly distinguish capture timestamp from stop-return time. These readings are diagnostics, not new motion authority or a claim of physical rest.

## Regression and completion boundary

The controller-seam regression independently triggers travel, backward, lateral and heading limits. Before the correction all reported `stalled` with no captured metrics; after it, they retain their original public failure and confirmed stop while reporting distinct causes and exact poses/limits. Reducer coverage verifies preservation across generic delivery and failed-stop precedence. Existing timeout and pre-send pose-correction tests retain behavior with more precise wording.

Completion of this software correction is not completion of the physical investigation. The installed diagnostic build and a further device run are required before selecting any underlying motion-control change.

## Verification and installation

Artifacts are under `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/`, with matching logs. Counts were extracted from result bundles; overlapping gates are not summed.

| Gate | Result | Bundle |
| --- | --- | --- |
| Actual controller guard-reporting regression before correction | 1 failed | `ready-guard-reporting-red.xcresult` |
| Focused readiness/reducer/admission classes | 73 passed | `ready-guard-reporting-focused.xcresult` |
| First full non-live SDK checkpoint | 834 passed | `ready-guard-reporting-sdk.xcresult` |
| Stop-return timing regression before refinement | 1 failed | `ready-stop-timing-red.xcresult` |
| Readiness controller class after refinement | 22 passed | `ready-stop-timing-green.xcresult` |
| **Final full non-live SDK** | **834 passed, 0 failed, 0 skipped** | `ready-guard-reporting-sdk-final.xcresult` |
| **Final app unit tests** | **33 passed, 0 failed, 0 skipped** | `ready-guard-reporting-app.xcresult` |
| Signed generic iOS build | Succeeded, no errors | `ready-guard-reporting-device.xcresult` |

An initial focused run (`ready-guard-reporting-green.xcresult`) had two expected old-message assertions; their behavior assertions remained unchanged while the expected text was updated for true progress timeout and pre-send pose shift. Tests now assert exact rejected/start pose objects and thresholds, and mutate the live pose during cleanup to ensure frozen failure evidence survives.

All simulator tests ran serially on iPhone 17 Pro / iOS 26.5 (`EEA52712-371D-4FF6-B8EF-A2C78319D57F`) with 60-second allowances. SDK used `./scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -resultBundlePath <bundle>`. App used the `PhroverOperator` project/scheme, Debug, that simulator and `-only-testing:PhroverOperatorTests CODE_SIGNING_ALLOWED=NO`. Signed build used `-destination 'generic/platform=iOS' -allowProvisioningUpdates`.

Installed `us.astral.phrover` on the **iPhone 15 Pro at 20:29 PDT**, device `FC11C836-4978-5B20-9170-16EAD18568BE`, installation sequence **2180**. This is a diagnostic correction, not validated resolution of the physical deviation. No app launch or motion test was initiated. Existing `UIScreen.main` deprecation and launch-configuration warnings remain; whitespace checks passed.

## Standards review

No hard standards violations or blocking correctness findings. Exact-pose/threshold assertions and cleanup-mutation coverage were added as suggested. Optional duplicated threshold knowledge between formatter descriptions and controller limits remains; current values agree.

## Spec review

Review requested separate stop ACK, pulse-return, pose-read and capture timestamps/frame identity. These are now recorded separately; a cached-capture regression proves `capture < ACK <= return <= read`. Follow-up review confirmed the timing finding resolved with no remaining correctness issue in scope.

Review summary: Standards — 0 hard violations / 1 optional duplication smell; Spec — 0 remaining findings. **Physical investigation is blocked awaiting a new rejected-pose capture and operator context about the phone/chassis motion.**
