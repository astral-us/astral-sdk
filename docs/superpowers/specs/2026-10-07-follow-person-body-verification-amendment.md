# Raw Predictions, Body Verification, and Follow Preview

## Approved fix

The user reported an empty-room preview labeled “person 100%” and approved correcting preview/follow mismatch and requiring stronger person evidence. The October 7 log showed one raw 99.0% person candidate rejected for its depth window, with most upright follow frames reporting no raw person. The preview independently used generic fallback orientations and rounded model scores to integer percentages.

## Production behavior

- Follow inference and preview use only the same upright `.right` orientation. Generic detection APIs preserve their historical orientation fallback for unrelated consumers.
- Before a live raw person can reach depth projection and follow acquisition, a same-image Vision human-body request must find exactly one plausible body in its box. Raw YOLO confidence, even 1.0, is not sufficient.
- Body verification requires both shoulders and both hips: finite normalized coordinates, joint confidence at least 0.30, points inside the raw box plus a 0.02 normalized margin, shoulder and hip horizontal spans at least 0.02, and shoulder mean height at least 0.05 above hip mean height. Ambiguity, missing/low-confidence/degenerate geometry, unavailable verification, and errors reject the candidate.
- These are conservative engineering selections, not device-calibrated thresholds. The torso must be visible. Verification detects body geometry, not identity or proof of a physical human: pictures/screens and model false positives remain possible.
- Native requests explicitly select supported CPU compute devices to preserve the existing no-GPU background-wind-down policy. Unsupported setup fails closed; no raw-score fallback is permitted. Native Vision setup returned Code 9 on this simulator, so its failure handling—not positive live-camera recognition—is verified here.
- Live source events always supply explicit verification decisions, including an empty or failed set. The public static batch projection helper retains its trusted-input legacy contract for geometric callers; it is not a person-verification boundary. External perception providers remain responsible for their observations.
- Raw detection counts are unchanged. Logs separately report per-person body decisions and verified counts, preserving frame-local raw-person IDs and actual projection-attempt counts. No joint arrays, images, or identity data are logged.

## Preview and status

Preview image, raw boxes, scores, and verification receipt refer to one immutable snapshot. A fresh follow evaluation is reused for up to 500 ms to avoid duplicate inference; generation/sequence/timestamp regression forces a new evaluation. Only one last image/receipt is retained.

The UI says “Raw predictions,” uses decimal model scores rather than “person 100%,” and labels unverified person predictions. Orange raw rectangles carry object labels; green rectangles mean body-check passed, not a confirmed identity or depth-qualified target. Frame ID and age are displayed. Verification unavailability is distinct from no body-verified candidate.

“Follow target: none/acquired” comes from the coordinator's display-only fresh matched-frame provenance, not a prediction score. Failed, stopped, searching, stale, unhealthy, and provisional recovery states cannot present a current target. Existing motion authorization and phase logic remain unchanged.

## Regression evidence

Executed assertion-red before production changes for high-score/no-body rejection, malformed/low-confidence body geometry, live perfect-score acquisition without body evidence, raw-score wording, cached same-frame preview, and target status. Initial target-status fixture lacked shared stop-clock provenance; it was corrected to use the existing production-like fixture without relaxing stopped-frame rules.

Scoped verification passed 29 tests across verifier, detector, live source, pipeline/summary, and target status. Cases include a matching torso, no body, body inference error, unavailable handler, right-only evaluation, exact cached image/receipt, expiry/reset, and source freshness. The native uniform-image check exercises actual Vision through the production catch path and cannot authorize a raw-score person when setup is unavailable.

No tolerances, burst budgets, stop gates, projection rules, recovery deadlines, or readiness retry policy are relaxed. The separate coarse turn response and 10 cm readiness-progress limitations are not addressed by this feature.

Changes remain uncommitted. No physical device was launched or moved. Final review, full-suite, app, and build evidence will be appended after execution.

## Final review and verification

Spec/safety review found no blocking high/medium issue. Standards found no hard breach and suggested sharing prediction-index lookup and availability classification; both presentation paths now use the same lookup, and decisions expose verification availability centrally.

| Gate | Result |
| --- | --- |
| Full SDK | 790 passed, 0 failed, 0 skipped |
| All app unit tests | 33 passed, 0 failed, 0 skipped |
| Unsigned generic-iOS Debug build | Succeeded |
| Whitespace | Passed |

All final tests ran serially with 60-second per-test allowances and no exclusions. SDK used the repository script; app tests used `PhroverOperatorTests` on simulator `EEA52712-371D-4FF6-B8EF-A2C78319D57F`. Build used Debug, `generic/platform=iOS`, and `CODE_SIGNING_ALLOWED=NO`.

Fresh bundles in the approved temporary evidence directory: `person-body-preview-sdk-final.xcresult`, `person-body-preview-app-final.xcresult`, and `person-verification-scoped-verified.xcresult`.

Initial native-body testing demanded successful Vision setup and failed with Code 9. The final integration check retains the raw perfect-score fixture but invokes the native handler through the production receipt/catch path, asserting that native unavailability or absence of a body cannot qualify that prediction. No test is skipped and no on-device positive recognition is claimed. Existing `UIScreen.main`, older Sendable test-capture, and launch-configuration warnings remain.

Live-camera acceptance must separately verify empty-room rejection, valid full-torso recognition, actual compute-device availability, body-inference latency/freshness, and projection/track behavior. Printed bodies/screens or model errors may still pass body geometry; it is not identity or physical-presence proof.
