# Live Command Draft Design

**Date:** 2026-08-05
**Status:** Approved

## Problem

The operator command card appears only after `SFSpeechRecognizer` finalizes a transcript and `MissionAgent.handle` emits `recognized`. Device logs show on-device recognition may provide no partial result until microphone release, and a no-speech attempt can remain blank for several seconds. The UI therefore looks as though microphone input was not recorded.

## Goals

- Show the command card immediately when microphone capture starts.
- Update the card when non-empty partial speech arrives.
- Send only a final transcript to `MissionAgent`.
- Replace the draft with identified mission status after final recognition.
- Show an actionable failure when no speech is detected.
- Prevent stale callbacks from an older capture overwriting a newer draft or command.

## Non-goals

- Starting missions from partial transcripts.
- Replacing Apple speech recognition.
- Keeping more than one command record.
- Persisting command history across launches.

## Architecture and data flow

`SpeechIn` will expose a live capture callback separate from its final-transcript callback. Typed capture events cover capture start, non-empty partial transcript, and terminal capture failure.

`SpeechIn` assigns each attempt a monotonic `SpeechCaptureID`, included in every live event and the final callback. `ConversationView` routes capture events into `LastCommandState`. On capture start, the reducer creates an immediate draft record displaying `Listening…`; partial events update only the matching active capture. Final recognition closes that capture before `MissionAgent` emits its separate `MissionCommandID`. The first identified command status replaces the closed draft, and later capture callbacks are ignored. This prevents an older attempt from mutating a newer card.

A final transcript continues through the existing path: `SpeechIn` calls the final handler, `MissionAgent` emits identified `MissionCommandStatus` events, and those events replace the draft with `Recognized`, `Working`, and a terminal result. Partial text never reaches mission execution.

If recognition ends without speech, the current draft becomes `Failed` with “No speech detected. Try again.” Other recognition failures receive concise operator messages while retaining detailed runtime telemetry.

## Testing

- Microphone capture start immediately creates a listening card before any transcript exists.
- Non-empty partials update the same draft.
- Empty partials do not erase retained text.
- Final recognition replaces the draft with the identified command lifecycle.
- No-speech timeout produces the actionable failed state.
- A stale partial, failure, or final event cannot overwrite a newer capture or command.
- Existing mission status and speech finalization tests remain green.

## Physical acceptance

On the iPhone, pressing the microphone must immediately display a Listening card. Speaking must update its text when partial recognition is available. Releasing after “Go to other room” must transition the same card into Recognized/Working without starting a mission early. A silent attempt must end with the no-speech message.
