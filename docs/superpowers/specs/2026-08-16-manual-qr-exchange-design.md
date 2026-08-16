# Manual QR Exchange Design

## Purpose

Make each Silent Search optical exchange explicit and operator-controlled. Each rover presents only the action required by its protocol state: generate the next QR code or scan the partner QR code. This removes ambiguous automatic transitions while preserving the existing offline optical protocol and its safety checks.

The latest iPhone 15 Pro Max run completed calibration, accepted the Rover A offer, and generated the Rover B acceptance. It then timed out because Rover B never received the next search-commit QR. The manual flow makes each exchange step visible and deliberate.

## Scope

This design covers manual QR exchange during the Silent Search handshake and rendezvous phases.

A separate follow-up project will cover independent GPS-denied sector search with ARKit visual-inertial odometry, on-device CoreML detection, and a split-screen camera/map visible-mind interface. That work does not expand this specification.

## Interaction model

`SilentSearchCoordinator` remains the protocol authority and exposes one pending optical action:

- **Generate QR** when the protocol is ready to send its next message.
- **Scan QR** when the protocol expects a partner message.
- **None** while calibrating, searching, moving, converging, terminal, or otherwise unable to exchange a message.

Only the currently valid action is shown. The UI does not allow an operator to choose an action that contradicts protocol state.

### Generate flow

1. The operator taps **Generate QR**.
2. The coordinator creates the outgoing protocol payload at that moment so its wall-clock timestamp is fresh.
3. The QR code appears large and centered, with the map hidden.
4. A 10-second countdown begins immediately.
5. The operator may tap **Partner scanned it** to finish early.
6. At zero, presentation completes normally and the coordinator exposes the next required action.

The 10-second presentation duration stays inside the 15-second handshake clock-difference limit.

### Scan flow

1. The operator taps **Scan QR**.
2. A live camera preview with a centered targeting frame replaces the action screen.
3. Scanning continues for up to 30 seconds.
4. A valid expected message advances the protocol automatically.
5. Cancellation returns to the pending **Scan QR** action without changing protocol state.
6. Timeout returns to **Scan QR** with retry guidance rather than terminating the mission.

## Architecture

### Coordinator

`SilentSearchCoordinator` owns the pending optical action and exposes commands equivalent to:

- `generatePendingQR()`
- `beginPendingQRScan()`
- `completeQRPresentation()`
- `cancelQRScan()`

The coordinator pauses before each optical operation until the matching command is invoked. It continues to own protocol-session mutation, retries, safety suspension, deadlines, and phase transitions.

QR generation must occur after `generatePendingQR()` rather than when the pending action first becomes visible. This prevents operator delay from producing an already-expired message.

### Protocol session

`OpticalProtocolSession` remains responsible for constructing and validating canonical messages, linked hashes, roles, mission identifiers, markers, sequence numbers, timestamps, schedules, decisions, and convergence messages. No payload schema or protocol-version change is required.

### View model

`LiveSilentSearchViewModel` projects coordinator state into:

- the single currently valid action button;
- the expected or outgoing message label;
- the rendered QR image;
- the remaining presentation countdown;
- the live scanner preview;
- timeout, cancellation, tracking, and validation guidance.

The view model must not construct, decode, or validate protocol payloads.

### UI

`SilentSearchView` hides the map during optical exchange and centers the active content:

- pending outbound step: message context and **Generate QR**;
- active presentation: large QR, countdown, and **Partner scanned it**;
- pending inbound step: expected message context and **Scan QR**;
- active scanning: live camera preview, targeting frame, status text, and **Cancel scan**.

The UI renders one required action at a time. Abort remains available as a destructive secondary action.

### Scanner preview

A focused optical-scan preview component consumes AR camera snapshots and publishes display-ready frames. It is separate from calibration grounding logic so scanner presentation can evolve without coupling it to `ARSharedMissionFrameCalibrator`.

## Message flow

```text
Protocol ready to send
  -> operator taps Generate QR
  -> QR displays for up to 10 seconds
  -> protocol waits for incoming message
  -> operator taps Scan QR
  -> scanner validates partner message
  -> protocol advances to its next action
```

This cycle applies to offer, acceptance, search commitment, acknowledgment, status, decision, convergence, and convergence acknowledgment messages.

## Retransmission behavior

An exact repeat of the most recently accepted incoming payload is a retransmission request, not a new protocol message.

- The protocol state does not advance.
- The coordinator exposes **Generate QR** for the cached last outgoing response.
- The response is not displayed automatically in manual mode.
- Replaying that cached response does not allocate a new sequence number.

Only the exact most recently accepted payload receives this treatment. Older, altered, or out-of-order messages remain subject to normal rejection.

## Error handling

- **No QR within 30 seconds:** return to **Scan QR** and show retry guidance.
- **Scan cancelled:** return to **Scan QR** without protocol mutation.
- **Presentation countdown expires:** complete presentation normally and expose the next action.
- **Exact latest incoming payload repeated:** expose **Generate QR** for the cached response.
- **Wrong marker, role, mission, kind, or sequence:** reject it. Recoverable scans keep the same pending scan action and show concise guidance.
- **Malformed or malicious payload:** reject without logging or displaying payload contents.
- **Tracking limited:** suspend active scanning and request restored tracking; resume from the same pending action when safe.
- **Generation change:** invalidate calibration and require recalibration.
- **Transport or reactive-safety failure:** stop motion and terminate using the existing safety result.

## Testing

### Coordinator and protocol tests

- Every valid operator command starts exactly one matching operation.
- Commands that do not match the pending action are ignored or rejected without protocol mutation.
- Outgoing timestamps are generated at button-tap time.
- Presentation completes at exactly 10 seconds and can complete early.
- Cancellation and scanner timeout return to the same pending scan action.
- Exact latest-message repetition exposes cached-response generation without advancing sequence state.
- Older and altered messages remain rejected.
- Tracking suspension and recovery preserve the pending action.

### Two-rover simulations

- Complete every handshake message using explicit generate and scan commands.
- Complete rendezvous status, decision, and convergence exchanges manually.
- Drop each message once and prove retry can recover.
- Repeat each latest message and prove the cached response is offered again.
- Inject older and out-of-order messages and prove they do not advance the protocol.

### View-model and UI tests

- Only the currently valid action appears.
- The QR is centered and the map is hidden during presentation.
- The countdown begins immediately at 10 seconds.
- **Partner scanned it** completes presentation early.
- The scanning screen shows live preview, targeting frame, expected message, and cancel control.
- Timeout and validation guidance are visible and actionable.

## Success criteria

- An operator can complete the full two-rover optical protocol without relying on implicit display/scan transitions.
- Each screen clearly states which rover action is required next.
- A missed or repeated QR does not terminate an otherwise valid mission.
- Invalid and out-of-order messages cannot advance protocol state.
- The workflow remains fully offline and runs on the existing iPhone 15 Pro and iPhone 15 Pro Max hardware.
