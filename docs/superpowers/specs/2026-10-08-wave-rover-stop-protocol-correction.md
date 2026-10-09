# WAVE ROVER wheel-stop protocol correction

User requested a fix after the 15:52 screenshot: the rover scanned past the person repeatedly and ended with `Person lost.` This corrects the shared hardware command boundary, not the detection threshold or recovery timeout. Earlier workflow assets remain preserved.

## Device evidence

Fresh artifact: `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/phrover-20261008-1552-runtime.log`.

- 22:52:21 UTC: body-verified person acquired in frame `1:1391`, range about 1.46 m; state became aligning.
- 22:52:22: person left the eligible field of view and recovery began. The person was reacquired at 22:52:24, :26, :27, :29 and :32; the original ten-second recovery episode expired at :32 before normal following was restored.
- Camera yaw continued changing after successful stop HTTP responses: paired yaw was 1.420649 rad at source time 148798.859441 and 1.979519 rad at 148799.259471, despite acknowledged stop requests in that interval. Alignment operation 3 had not sent a nonzero wheel command before losing the person.
- Every stop request used `{"T":0}` (for example lines 419912 and 419938). HTTP 200 was being treated as stop-command acknowledgement.

AR evidence does not identify installed firmware version or independently prove physical wheel state. It does establish repeated acquisition and continuing observed rotation despite acknowledged stop requests. The supported-protocol mismatch below is independently reproducible.

## Primary-source protocol evidence

Vendor documentation: <https://www.waveshare.com/wiki/WAVE_ROVER>, particularly “Left and right wheel speed control — CMD_SPEED_CTRL”. It documents T:1 with L/R and notes that this encoderless product maps values to PWM, not calibrated wheel velocity.

Vendor firmware archive linked by that page: <https://files.waveshare.com/upload/e/e6/WAVE_ROVER_demo.zip>, extracted read-only under the temporary evidence directory `waveshare-stop-protocol/WAVE_ROVER_V0.9/`.

- `json_cmd.h:55`: `CMD_SPEED_CTRL` is **1**.
- `uart_ctrl.h:1–15`: T:1 dispatches L/R to `setGoalSpeed`. The dispatcher contains no T:0 chassis-stop case.
- `http_server.h:13–21`: `/js` returns HTTP **200** after dispatch, including an unhandled opcode.
- `movtion_module.h:292–321`: `setGoalSpeed` updates setpoints for encoder bases or calls left/right PWM control for WAVE ROVER.
- `movtion_module.h:393–400`: the firmware heartbeat stop itself uses `setGoalSpeed(0, 0)`.
- `web_page.h:321,764–773`: the vendor STOP button calls `movtionButton(0,0)`, which emits T:1 with L/R.

## Corrected contract

`RoverControl.stop()` and `stopWithReceipt()` send one supported chassis command: `{"T":1,"L":0,"R":0}`. It remains outside expired/revoked turn-burst authorization and retains existing serialized stop ordering, retries, receipt reporting and failure propagation. This fixes all clients of the shared stop API, including search, detection handoff, alignment, cancellation and watchdog stopping.

The public legacy `Opcode.emergencyStop = 0` constant is retained only for source compatibility and deprecated with guidance to call `RoverControl.stop()`. It is no longer used by production stop dispatch. Comments now accurately identify WAVE ROVER commands as open-loop PWM inputs and HTTP acknowledgement as distinct from physical rest.

No person-verification gate, purpose tolerance, motor magnitude, recovery deadline or readiness condition is relaxed. The app must still receive fresh valid perception before moving again.

## Regression

`RoverControlTests/testStopClearsWaveRoverWheelOutputsEvenWhenUnknownOpcodesReturnHTTP200` exercises the actual client, captures its requests and replays the vendor dispatch semantics (T:1 updates both outputs; unknown commands preserve them) while every HTTP response succeeds. The sequence is a turn, public stop, then link probe.

Before the fix, the asserted output history was `[[0.25,-0.25],[0.25,-0.25],[0.25,-0.25]]` rather than `[[0.25,-0.25],[0,0],[0,0]]`. This is assertion-red evidence that HTTP success alone concealed an ineffective stop. After the correction, both outputs clear at the stop and remain zero during the probe. Existing receipt tests now assert the supported opcode and both zero outputs rather than assuming T:0 is effective.

The fixture checks vendor command semantics, not physical braking distance. A device run must verify that the base now stops when a person is acquired.

## Verification and installation

All result bundles below are under `/var/folders/g0/7vt60mh93ygg84tph_tyb6gw0000gn/T/opencode/`, with matching `.log` files. Counts were obtained with `xcresulttool get test-results summary`; builds with `get build-results`.

| Gate | Result | Bundle |
| --- | --- | --- |
| Original stop-protocol regression | 1 failed, 0 passed | `wave-stop-protocol-red.xcresult` |
| Transport class after fixture migration | 48 passed, 0 failed, 0 skipped | `wave-stop-protocol-focused.xcresult` |
| Full non-live SDK | **816 passed, 0 failed, 0 skipped** | `wave-stop-protocol-sdk.xcresult` |
| Full app unit tests | **33 passed, 0 failed, 0 skipped** | `wave-stop-protocol-app.xcresult` |
| Signed generic iOS build | **Succeeded** | `wave-stop-protocol-device.xcresult` |

The initial transport class run (`wave-stop-protocol-green.xcresult`) had the new regression passing but one obsolete assertion that a stop lacks an L field; it was removed because both zero wheel fields are now required. No failure was hidden by retrying unchanged tests.

Simulator: iPhone 17 Pro / iOS 26.5, `EEA52712-371D-4FF6-B8EF-A2C78319D57F`, serial tests and 60-second allowances. SDK ran `./scripts/test-swift-sdk.sh -quiet -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 -resultBundlePath <bundle>`. App ran the `PhroverOperator` project/scheme in Debug with `-only-testing:PhroverOperatorTests` and the same test settings, unsigned simulator execution. Device build used `-destination 'generic/platform=iOS' -allowProvisioningUpdates`.

Installed `us.astral.phrover` successfully on the iPhone 15 Pro at **16:07 PDT**, device `FC11C836-4978-5B20-9170-16EAD18568BE`, installation sequence **2148**. No physical movement test or app launch was initiated. Existing `UIScreen.main` deprecation and missing launch-configuration warnings remain; no build errors. Working-tree whitespace check passed.

## Standards review

Independent read-only review found no hard violations, actionable smells or blocking correctness issues in the scoped correction. The deprecated public constant preserves compatibility and the stop keeps the existing nil-authorization transport path.

## Spec review

Independent read-only review checked the vendor dispatcher, HTTP handler, motor mapping and STOP button. It found no missing requirements, scope creep or implementation blockers. The regression exercises the production client and verifies the command's effect under vendor dispatch semantics, rather than merely accepting HTTP 200.

Review summary: Standards — 0 findings; Spec — 0 findings. Prevention: hardware protocol fixtures must model ignored commands and actuator state, not just HTTP success.
