import Foundation
import PhroverKit

/// Wraps any `RoverBrain` to log every tick's decision + plan to the `EventLog` — the
/// harness scores capstone beats from these `decision` events, not by asking the brain
/// to self-report. Mirrors `TranscriptRecorder` in
/// PhroverKitLiveProbes/CloudBrainLiveMissionTests.swift.
@MainActor
final class RecordingBrain: RoverBrain {
    private let inner: RoverBrain
    private let events: EventLog

    init(wrapping inner: RoverBrain, events: EventLog) {
        self.inner = inner
        self.events = events
    }

    func nextAction(_ context: MissionContext) async throws -> BrainOutput {
        let output = try await inner.nextAction(context)
        events.log("decision", [
            "decision": String(describing: output.decision),
            "plan": output.updatedPlan ?? NSNull(),
            "utterance": context.utterance ?? NSNull(),
        ])
        return output
    }
}
