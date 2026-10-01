# Follow-Me Voice-Only Amendment

**Date:** 2026-09-30
**Status:** Approved in conversation

This amendment overrides the text-entry portions of `2026-09-29-follow-me-design.md` and its implementation plan. The operator now issues **“follow me” by pressing and holding the existing microphone, speaking, then releasing it**. Do not show a typed-request field or Send button on Talk. Do not change the microphone into a tap-to-toggle or always-listening control.

Only finalized speech reaches `OperatorCommandRouter`: follow and stop phrases stay local, while other spoken requests continue to `MissionAgent`. Keep the visible Stop Following control and all rear-camera tracking, distance, cancellation, and safety rules from the original design.

The separately reported **“Pose or depth unavailable”** condition is not solved by removing text input. Follow mode must still stop rather than navigate without a current, normally tracked AR pose and depth observation.

Acceptance: Talk contains the microphone, follow status, and Stop Following when active, but no request field or Send button; finalized “follow me” takes the existing local command path; press-and-hold/release speech interaction remains unchanged. Simulator UI tests can verify controls and the view-model routing seam, but physical voice recognition and AR tracking need device validation.
