# Ready signal: effective open-loop output with bounded pulses

User requested the next fix from the 18:04 screenshot, `Navigation stopped: insufficient measured progress.` Earlier same-day changes and workflow assets are preserved.

## Evidence

Pulled `phrover-20261008-1804-runtime.log` into the temporary evidence directory. At 2026-10-09 01:03:30 UTC, person acquisition succeeded; alignment completed and readiness admission was authorized at :33. The person remained body-verified and matched. The app repeatedly sent T:1 with **L=R=0.05**, receiving HTTP 200, until the **followReady** progress watchdog failed at :36. Stop was confirmed. This is the readiness translation, not a scan or alignment failure.

WAVE ROVER interprets T:1 L/R as open-loop PWM-scaled values. A 0.05 command is about 10% PWM, not calibrated 0.05 m/s. The observed failure is consistent with a command below static-friction breakaway. The existing 0.25 turning output has produced movement on the device; its efficacy and stopping distance for this forward pulse still require device acceptance.

## Corrected readiness behavior

- Preserve the single admitted 10 cm ready signal, its measured 8–12 cm completion corridor, lateral/heading/path/clearance checks, original 2.5-second progress watchdog and five-second movement limit. Do not bypass readiness or claim success on command acknowledgement.
- Use equal forward output **0.25** in pulses with a **40 ms host budget**, followed by serialized zero-wheel stopping and **100 ms stopped observation**. No taper back into an ineffective low-output command.
- Reuse the existing bounded command executor: sender entry arms the immutable budget; transport queueing, attempts and response consume it; a late response adds no new motor wait; stopping drains any already-entered request. Cancellation/replacement delegates to the existing owning stop path.
- Extend bounded transport authorization to `followReady`. Its validity is additionally capped by the captured source freshness, ACK freshness, remaining overall movement time and existing progress checkpoint. Expired queued readiness commands cannot enter HTTP. An expired readiness send remains a command failure, not a rotation-resolution subtype. Stops remain outside burst authorization.
- With enriched pose input, require a distinct capture strictly after each pulse's stop acknowledgement and post-stop frame boundary before another pulse or arrival. Cached/pre-stop captures cannot demonstrate movement or authorize another nonzero command. Legacy pose-only callers retain their existing compatible pose contract.
- Revalidate the existing geometry and safety conditions each loop. Stop errors, stalled motion, lost tracking and transport failures do not authorize another attempt. Readiness admission remains once per signal; pulses belong to that same move.
- Emit `follow_ready.pulse_stopped` with measured pre-pulse progress, requested budget, output magnitude and send duration/outcome. Explicitly label physical motor duration as unknown: a host budget does not guarantee an on-board timed stop or bound network/physical coast.

## Regression seams

The actual readiness controller was exercised against a motor dead-zone fixture. Before the correction it repeatedly sent 0.05, made no progress and failed with `stalled`. After the correction it issues three effective pulses, stops between them and completes on 9 cm of measured displacement.

Additional checks cover refusal to complete/repeat from a pre-stop capture, real `RoverControl` queue expiry with zero nonzero HTTP requests, actual stop receipts, pre-send pose corrections, cancellation/drain ordering, failed stop, safe path/clearance checks, and once-only readiness admission.

Existing readiness fixtures were updated to advance their source clock and publish fresh capture IDs during pulse waits. A stalled chassis fixture now keeps camera/perception frames fresh while position remains stationary, so it tests progress failure rather than accidental tracking staleness. Final-stop tests measure the fresh-frame boundary relative to actual pulse-stop timing; admission-at-500-ms tests assert the admission event rather than requiring detector data to remain fresh after additional elapsed pulse time. No production freshness threshold, timeout or geometry corridor was relaxed for these migrations.

## Review corrections

Independent review identified two deadline gaps: rejected pre-stop displacement could renew the progress checkpoint, and arrival was evaluated before the overall deadline after a late pulse/stop. Both were reproduced with failing controller regressions. The controller now checks existing deadlines without mutation before the fresh-capture and arrival gates; only eligible captures may update progress. Transport validity uses the watchdog's own timeout property. Follow-up review confirmed both corrected.

A further test-only scenario supplies legitimate progress every 1.75 seconds, isolating the five-second limit from the shorter progress watchdog. It still fails closed after the overall limit, even though displacement has reached 9 cm.

## Executed verification and installation

Artifacts are in `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/`, with matching logs. Counts are extracted from result bundles; overlapping gates are not added together.

| Gate | Result | Bundle |
| --- | --- | --- |
| Original readiness dead-zone regression | 1 failed | `ready-pwm-red.xcresult` |
| Bounded-pulse regression | 1 passed | `ready-pwm-green.xcresult` |
| Readiness/admission after fixture migration | 60 passed | `ready-pwm-integration-fixed.xcresult` |
| Review-discovered deadline regressions before correction | 2 failed | `ready-pwm-review-red.xcresult` |
| Readiness/admission/diagnostics/transport after correction | 188 passed | `ready-pwm-review-green.xcresult` |
| **Final complete non-live SDK** | **832 passed, 0 failed, 0 skipped** | `ready-pwm-sdk-final.xcresult` |
| Isolated overall-deadline scenario extension | 1 passed | `ready-pwm-overall-deadline.xcresult` |
| **Final app unit tests** | **33 passed, 0 failed, 0 skipped** | `ready-pwm-app.xcresult` |
| Signed generic iOS build | Succeeded, no errors | `ready-pwm-device.xcresult` |

The initial focused gate had four outdated simulated-clock/frame expectations; after their explicit migrations it passed. The initial full SDK gate (`ready-pwm-sdk.xcresult`) had 829 passes and one final-stop fixture count mismatch. That fixture now injects its generation fault at readiness's actual third/terminal stop, after the new second/pulse stop, retaining its tracking-loss assertion. Review corrections then required the final full SDK gate. The final test-only overall-deadline extension ran separately after that gate; production code was unchanged. No failed gate was hidden by an unchanged retry.

All tests used iPhone 17 Pro / iOS 26.5, destination `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, serial execution. Focused readiness gates used 15-second allowances to expose fixture hangs promptly; full SDK/app used 60 seconds. SDK command: `./scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -resultBundlePath <bundle>`. App used project/scheme `PhroverOperator`, Debug, the same simulator, `-only-testing:PhroverOperatorTests` and `CODE_SIGNING_ALLOWED=NO`. Signed build used `-destination 'generic/platform=iOS' -allowProvisioningUpdates`.

Installed `us.astral.phrover` successfully on the **iPhone 15 Pro at 18:44 PDT**, device `FC11C836-4978-5B20-9170-16EAD18568BE`, installation sequence **2172**. No app launch or physical movement test was initiated. Existing `UIScreen.main` deprecation and missing launch-configuration warnings remain. Whitespace checks passed.

## Standards review

No hard repository-standard violations. The rejected-capture checkpoint finding was corrected; the optional duplicated-watchdog-constant suggestion was addressed by using `progress.timeout`.

## Spec review

Both deadline findings were corrected and independently rechecked. No remaining correctness findings within the reviewed scope. The subsequent isolated overall-deadline scenario closes the noted coverage limitation.

Review summary: Standards — 0 remaining findings; Spec — 0 remaining findings. Physical forward breakaway and stopping performance remain device acceptance items.
