import SwiftUI
import PhroverKit
import PhroverCloud

/// Voice UI. Push-to-talk (hold the mic button) rather than always-on wake-word
/// listening — simpler and more reliable in noisy environments.
///
/// Backed by `MissionAgent`: there's no command grammar here, just "say whatever you
/// want" — the agent looks around, asks questions, and navigates as it decides it needs
/// to. Uses the cloud brain (open-vocabulary grounding) with on-device fallback when a
/// `PhroverCloud.plist` is configured; on-device only otherwise.
struct ConversationView: View {
    let ar: ARSessionManager
    let nav: NavigationController
    let cloudBrain: CloudBrain?

    @State private var speechIn = SpeechIn()
    @State private var speechOut = SpeechOut()
    @State private var agent: MissionAgent?
    @State private var authorized = false

    var body: some View {
        VStack(spacing: 20) {
            Text(statusLabel).font(.headline)

            Text(speechIn.partialTranscript)
                .foregroundStyle(.secondary)
                .frame(minHeight: 40)
                .multilineTextAlignment(.center)

            Image(systemName: "mic.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(speechIn.state == .listening ? .red : .accentColor)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in startListening() }
                        .onEnded { _ in speechIn.stop() }
                )

            if let agent {
                Text(phaseLabel(agent.phase))
                    .font(.body)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            Spacer()
        }
        .padding()
        .task {
            authorized = await speechIn.requestAuthorization()
            let detector = await Detector()
            let perception = ARPerceptionSource(ar: ar, detector: detector)
            let voice = SpeechRoverVoice(out: speechOut, speechIn: speechIn)
            let onDevice = OnDeviceBrain()
            let brain: RoverBrain = cloudBrain.map { HybridBrain(cloud: $0, onDevice: onDevice) } ?? onDevice
            agent = MissionAgent(motion: nav, perception: perception, voice: voice) { brain }
        }
    }

    private var statusLabel: String {
        if !authorized { return "Enable Speech Recognition in Settings" }
        switch speechIn.state {
        case .listening: return "Listening…"
        case .unavailable: return "Speech recognition unavailable"
        case .idle: return "Hold to talk"
        }
    }

    private func phaseLabel(_ phase: MissionAgent.Phase) -> String {
        switch phase {
        case .idle: return "Ready"
        case .thinking: return "Thinking…"
        case .acting: return "On it…"
        case .waitingForAnswer: return "Waiting for your answer…"
        }
    }

    private func startListening() {
        guard authorized, speechIn.state != .listening else { return }
        try? speechIn.start { utterance in
            Task {
                await agent?.handle(utterance)
            }
        }
    }
}
