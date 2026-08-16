# Manual QR Exchange Implementation Plan

> **For agentic workers:** Execute tasks in order with TDD on `codex/silent-search-v1`. Keep each unit focused and commit each green task or cohesive pair.

**Goal:** Replace implicit Silent Search QR display/scan transitions with one explicit operator action at a time while preserving protocol authority, retries, replay protection, safety behavior, and offline operation.

**Architecture:** Add an observed pending optical action to `SilentSearchCoordinator`; gate handshake and rendezvous operations on explicit coordinator commands; give presentations a deterministic 10-second lifecycle; expose a focused live scan-preview model; and project the resulting state through `LiveSilentSearchViewModel` into centered Generate QR, QR display, Scan QR, and camera screens.

**Tech stack:** Swift 6, Observation, SwiftUI, XCTest, ARKit, Vision/Core Image QR scanning, PhroverKit, Xcode iOS Simulator, iPhone 15 Pro, and iPhone 15 Pro Max.

**Approved design:** `docs/superpowers/specs/2026-08-16-manual-qr-exchange-design.md`

## Global constraints

- Keep `OpticalProtocolSession` as the only constructor and validator of protocol messages.
- Generate a new outgoing message only after the operator taps **Generate QR**.
- Show exactly one valid operator action at a time.
- Display QR codes for at most 10 seconds, with early manual completion.
- Scan for at most 30 seconds; cancellation and timeout return to the same pending scan action.
- Treat only the exact latest accepted incoming payload as a retransmission request.
- Retransmission exposes cached-response generation and must not allocate another sequence number.
- Preserve rejection of older, altered, wrong-mission, wrong-marker, wrong-role, wrong-kind, and out-of-order messages.
- Keep payloads and camera images out of telemetry.
- Keep the independent GPS-denied visible-mind search UI out of this implementation.
- The working tree already contains unrelated `.serena/project.yml` and `ARSharedMissionFrameCalibratorTests.swift` edits. Do not stage or overwrite them.
- Reconcile the current uncommitted automatic retransmission changes in `SilentSearchCoordinator.swift` and its tests with the approved manual retransmission behavior rather than layering a second path beside them.

---

### Task 1: Introduce the pending optical-action model

**Files:**
- Create: `swift/Sources/PhroverKit/SilentSearch/SilentSearchOpticalOperatorAction.swift`
- Modify: `swift/Sources/PhroverKit/SilentSearch/SilentSearchCoordinator.swift`
- Modify: `swift/Tests/PhroverKitTests/SilentSearchCoordinatorTests.swift`

**Interfaces:**
- Add a data-only `Equatable`, `Sendable` action enum representing pending generation and pending scan, including the relevant `OpticalMessageKind` and whether generation is a cached retransmission.
- Add observed coordinator state for the pending action and active presentation deadline.
- Add coordinator commands returning `Bool` for accepted/rejected invocation: `generatePendingQR()`, `beginPendingQRScan()`, `completeQRPresentation()`, and `cancelQRScan()`.
- Add one private action gate that can wait for exactly one required command, reject mismatched commands, and unblock cleanly on task cancellation or terminal transition.

- [ ] Write failing tests proving Rover A exposes Generate QR and Rover B exposes Scan QR after `startHandshake()`.
- [ ] Test that no payload is prepared or presented before Generate QR is invoked.
- [ ] Test that mismatched and repeated commands return false and do not mutate session state.
- [ ] Test mission abort, operator stop, safety failure, and task cancellation clear the pending action and unblock the gate.
- [ ] Implement the focused action value and gate without moving protocol validation into UI-facing code.
- [ ] Verify:

```bash
scripts/test-swift-sdk.sh -quiet -only-testing:PhroverKitTests/SilentSearchCoordinatorTests
```

---

### Task 2: Gate the complete handshake and manual retransmission flow

**Files:**
- Modify: `swift/Sources/PhroverKit/SilentSearch/SilentSearchCoordinator.swift`
- Modify: `swift/Tests/PhroverKitTests/SilentSearchCoordinatorTests.swift`
- Modify: `swift/Tests/PhroverKitTests/TwoRoverSilentSearchSimulationTests.swift`

**Behavior:**
- Before `prepareOutgoing`, wait for Generate QR.
- Before `scan`, wait for Scan QR.
- After a valid scan, expose the next protocol-required action rather than immediately starting it.
- When the scanned payload exactly equals `lastIncomingPayload`, leave protocol state unchanged and expose Generate QR for `session.retryOutgoing()`.
- Do not automatically present the cached response.

- [ ] Convert the two-rover handshake fixture to drive explicit Generate QR and Scan QR commands for offer, acceptance, search commitment, and acknowledgment.
- [ ] Add a red simulation proving both rovers remain paused indefinitely when no operator command is sent.
- [ ] Add a red simulation proving a repeated offer exposes cached acceptance generation, and that tapping Generate QR reuses the canonical acceptance bytes and sequence.
- [ ] Test scan timeout and scan cancellation return to the same expected-message action.
- [ ] Keep stale older and out-of-order same-session handshake messages as terminal protocol rejections; only an exact repeat of the latest accepted payload is recoverable.
- [ ] Remove or adapt the current automatic `retransmissionResponse` presentation path so there is one manual retransmission path.
- [ ] Verify:

```bash
scripts/test-swift-sdk.sh -quiet -only-testing:PhroverKitTests/SilentSearchCoordinatorTests
scripts/test-swift-sdk.sh -quiet -only-testing:PhroverKitTests/TwoRoverSilentSearchSimulationTests
```

---

### Task 3: Gate rendezvous exchanges with the same action seam

**Files:**
- Modify: `swift/Sources/PhroverKit/SilentSearch/SilentSearchCoordinator.swift`
- Modify: `swift/Tests/PhroverKitTests/TwoRoverSilentSearchSimulationTests.swift`

**Behavior:**
- Preserve required rover rotation and heading tolerance before exposing the action.
- Require explicit actions for status, decision, convergence, and convergence acknowledgment.
- A repeated latest rendezvous message exposes cached-response generation at the same heading.
- Partner and convergence deadlines remain mission deadlines; operator inactivity does not silently advance protocol state.

- [ ] Extend the simulation driver to complete all rendezvous exchanges through coordinator commands.
- [ ] Test the pending action appears only after optical alignment succeeds.
- [ ] Test repeated latest status, decision, and convergence messages offer the cached response without moving phase or sequence.
- [ ] Test old acknowledgments and other out-of-order messages still fail to advance.
- [ ] Test tracking-limited suspension clears active camera/display work and restores the same pending action after normal tracking returns.
- [ ] Verify:

```bash
scripts/test-swift-sdk.sh -quiet -only-testing:PhroverKitTests/TwoRoverSilentSearchSimulationTests
```

---

### Task 4: Add deterministic presentation completion and scan cancellation

**Files:**
- Modify: `swift/Sources/PhroverKit/SilentSearch/SilentSearchDependencies.swift`
- Modify: `swift/Sources/PhroverKit/SilentSearch/Device/AROpticalExchangeService.swift`
- Modify: `swift/Sources/PhroverKit/SilentSearch/SilentSearchCoordinator.swift`
- Modify: `swift/Tests/PhroverKitTests/AROpticalExchangeServiceTests.swift`
- Modify: `swift/Tests/PhroverKitTests/Support/SilentSearchTestDoubles.swift`
- Modify: `swift/Tests/PhroverKitTests/SilentSearchCoordinatorTests.swift`
- Modify: `examples/PhroverOperator/PhroverOperator/App/SilentSearchViewModel.swift`

**Interfaces:**
- Extend the optical-exchange seam with clean presentation completion distinct from cancellation.
- Wire the live implementation to `LiveOpticalPresentation.complete()` and the fake implementation to its suspended presentation continuation.
- Let the coordinator arm a 10-second presentation task using `SilentSearchClock`; both deadline expiry and `completeQRPresentation()` complete successfully.
- Make `cancelQRScan()` cancel only the active scan and restore the pending scan action without producing a terminal protocol failure.

- [ ] Write exact boundary tests at 9.999 seconds and 10.000 seconds with `ManualSilentSearchClock`.
- [ ] Test manual completion wins the race and deadline completion is idempotent.
- [ ] Test abort and safety cancellation do not look like successful presentation completion.
- [ ] Test scan cancellation is distinguishable from timeout and transport failure.
- [ ] Verify:

```bash
scripts/test-swift-sdk.sh -quiet -only-testing:PhroverKitTests/AROpticalExchangeServiceTests
scripts/test-swift-sdk.sh -quiet -only-testing:PhroverKitTests/SilentSearchCoordinatorTests
```

---

### Task 5: Add live scan preview and manual exchange projections

**Files:**
- Create: `examples/PhroverOperator/PhroverOperator/App/OpticalScanPreviewModel.swift`
- Modify: `examples/PhroverOperator/PhroverOperator/App/SilentSearchViewModel.swift`
- Modify: `examples/PhroverOperator/PhroverOperator/Views/SilentSearchView.swift`
- Modify: `examples/PhroverOperator/PhroverOperatorUITests/SilentSearchUITests.swift`
- Add or modify focused app-unit tests under: `examples/PhroverOperator/PhroverOperatorTests/`

**View-model surface:**
- Add pending Generate QR and pending Scan QR operator phases distinct from active display and active scan.
- Add the expected/outgoing message label, presentation seconds remaining, scan preview image, and commands for generate, scan, display completion, and scan cancellation.
- Update `ScriptedSilentSearchViewModel` scenarios for deterministic previews and UI tests.

**UI behavior:**
- Pending outbound: centered context plus only **Generate QR**.
- Active display: centered QR, visible 10-second countdown, **Partner scanned it**, and Abort.
- Pending inbound: centered expected-message context plus only **Scan QR**.
- Active scan: live camera frame, centered QR target overlay, expected-message text, **Cancel scan**, and Abort.
- Hide the map in every pending or active optical-exchange screen.

- [ ] Write failing view-model tests for all four projections and command forwarding.
- [ ] Write failing UI tests proving only the valid action button exists in each state.
- [ ] Test countdown text begins at 10 and manual completion remains enabled.
- [ ] Test the scan screen exposes a live-preview accessibility element and targeting overlay.
- [ ] Build a focused `OpticalScanPreviewModel` from AR snapshots without importing calibration grounding responsibilities.
- [ ] Verify:

```bash
xcodebuild test   -project examples/PhroverOperator/PhroverOperator.xcodeproj   -scheme PhroverOperator   -destination "platform=iOS Simulator,name=iPhone 16 Pro"
```

---

### Task 6: Regression and physical two-rover proof

- [ ] Run the automated gate:

```bash
scripts/test-swift-sdk.sh
git diff --check
git status --short
xcodebuild build   -project examples/PhroverOperator/PhroverOperator.xcodeproj   -scheme PhroverOperator   -destination "generic/platform=iOS"
```

- [ ] Build and install the same revision on the iPhone 15 Pro and iPhone 15 Pro Max.
- [ ] Connect each phone to its rover-local network and verify readiness without internet.
- [ ] Calibrate both rovers against `SILENT_SEARCH_01`.
- [ ] Complete offer, acceptance, search commitment, and acknowledgment using only the visible required-action buttons.
- [ ] Verify every QR starts at 10 seconds, can finish early, and disappears at zero.
- [ ] During scanning, verify the live preview stays responsive and a valid QR advances automatically.
- [ ] Leave one QR visible after the partner moves on; verify the partner offers Generate QR for its cached response instead of terminating.
- [ ] Complete one status/decision/convergence rendezvous exchange manually.
- [ ] Pull both runtime logs and confirm no `protocol_unexpectedPhase`, no `protocol_clockDisagreement` within the supported window, no payload/image telemetry, and no unintended automatic optical operation.

## Completion criteria

- The full two-rover protocol can be completed with one explicit action shown at a time.
- No outgoing timestamp is created before Generate QR is tapped.
- Countdown, early completion, scanner timeout, scanner cancellation, retransmission, tracking suspension, and safety failure have deterministic tests.
- Invalid and out-of-order messages cannot advance state.
- Both physical phones run the same verified revision offline.
