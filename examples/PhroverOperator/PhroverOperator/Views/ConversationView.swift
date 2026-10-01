import SwiftUI
import PhroverKit
import PhroverCloud
import CoreImage
import UIKit

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
    private let scripted: Bool
    private let otherMotionActive: @MainActor () -> Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ConversationViewModel

    init(ar: ARSessionManager, nav: NavigationController, cloudBrain: CloudBrain?,
         model: ConversationViewModel? = nil, scripted: Bool = false,
         otherMotionActive: @escaping @MainActor () -> Bool = { false }) {
        self.ar = ar
        self.nav = nav
        self.cloudBrain = cloudBrain
        self.scripted = scripted
        self.otherMotionActive = otherMotionActive
        _model = State(initialValue: model ?? ConversationViewModel())
    }

    @State private var speechIn = SpeechIn()
    @State private var speechOut = SpeechOut()
    @State private var agent: MissionAgent?
    @State private var missionPhase: MissionAgent.Phase = .idle
    @State private var authorized = false
    @State private var detector: Detector?

    var body: some View {
        VStack(spacing: 18) {
            if !statusLabel.isEmpty {
                Text(statusLabel).font(.headline)
            }

            if !scripted {
                LiveCameraDebugPanel(ar: ar, detector: detector)
                    .frame(maxWidth: 320)
            }

            if !model.status.isEmpty {
                Text(model.status).accessibilityIdentifier("talk_follow_status")
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if model.showsStopFollowing {
                Button("Stop Following", role: .destructive) {
                    Task { await model.stopFollowing() }
                }
                .accessibilityIdentifier("talk_stop_following")
            }

            Text(speechIn.partialTranscript)
                .foregroundStyle(.secondary)
                .frame(minHeight: 40)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                if agent != nil {
                    Text(phaseStatusLabel)
                        .font(.subheadline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(speechIn.state == .listening ? .red : .accentColor)
                    .accessibilityIdentifier("talk_microphone")
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in startListening() }
                            .onEnded { _ in speechIn.finish() }
                    )
            }
            .offset(y: -36)
            .padding(.bottom, 40)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 44)
        .padding(.bottom, 12)
        .task {
            guard !scripted else { return }
            let detector = await Detector()
            self.detector = detector
            let perception = ARPerceptionSource(ar: ar, detector: detector)
            let voice = SpeechRoverVoice(out: speechOut, speechIn: speechIn)
            let onDevice = OnDeviceBrain()
            let brain: RoverBrain = cloudBrain.map { HybridBrain(cloud: $0, onDevice: onDevice) } ?? onDevice
            agent = MissionAgent(motion: nav, perception: perception, voice: voice, phaseDidChange: { phase in
                missionPhase = phase
            }) { brain }
            let follow = FollowMeCoordinator(
                perception: ARFollowMePerceptionSource(ar: ar, detector: detector),
                motion: NavigationFollowMeMotion(navigation: nav), clock: SystemFollowClock()
            )
            guard let agent else { return }
            let router = OperatorCommandRouter(mission: agent, follow: follow,
                                               mayStartFollow: otherMotionActive)
            model.configure(submit: { await router.submit($0) },
                            stop: { await router.stop() }, followState: { follow.state },
                            inhibit: { follow.inhibitMotion() })
            authorized = await speechIn.requestAuthorization()
        }
        .onDisappear {
            model.prepareToLeave()
            Task { _ = await model.leaveTalk() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                model.prepareToLeave()
                Task { _ = await model.leaveTalk() }
            }
        }
    }

    private var statusLabel: String {
        if scripted { return "" }
        if !authorized { return "Enable Speech Recognition in Settings" }
        switch speechIn.state {
        case .listening: return "Listening…"
        case .processing: return "Processing speech…"
        case .unavailable: return "Speech recognition unavailable"
        case .idle: return ""
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

    private var phaseStatusLabel: String {
        if speechIn.state == .listening {
            return speechIn.partialTranscript.isEmpty ? "Listening…" : "Processing speech…"
        }
        if speechIn.state == .processing { return "Thinking…" }
        return phaseLabel(missionPhase)
    }

    private func startListening() {
        guard authorized, speechIn.state != .listening else { return }
        try? speechIn.start { utterance in
            Task { @MainActor in
                missionPhase = .thinking
                await model.submitFinalSpeech(utterance)
            }
        }
    }
}

private struct LiveCameraDebugPanel: View {
    let ar: ARSessionManager
    let detector: Detector?

    @State private var previewImage: UIImage?
    @State private var visibleObjects: [PerceivedObject] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    ZStack {
                        Color.black.opacity(0.08)
                        Image(systemName: "camera")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .background(.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                Text("Live")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Tracking: \(trackingLabel)")
                Text(String(format: "Clearance: %.2f m", ar.forwardClearance))
                Text("Detector: \(detectorStatus)")
                Text("Visible: \(PerceptionDebugSummary.visibleObjects(visibleObjects))")
                    .lineLimit(2)
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .task(id: detector != nil) {
            await refreshLoop()
        }
    }

    private var trackingLabel: String {
        switch ar.trackingState {
        case .normal: return "normal"
        case .limited: return "limited"
        case .notAvailable: return "none"
        @unknown default: return "?"
        }
    }

    private var detectorStatus: String {
        guard let detector else { return "loading" }
        return detector.isLoaded ? "loaded" : "unavailable"
    }

    @MainActor
    private func refreshLoop() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    @MainActor
    private func refresh() {
        guard let buffer = ar.latestPixelBuffer else {
            previewImage = nil
            visibleObjects = []
            return
        }

        previewImage = Self.previewImage(from: buffer)

        guard let detector else {
            visibleObjects = []
            return
        }

        visibleObjects = detector.detect(buffer).map {
            PerceivedObject(label: $0.label,
                            confidence: $0.confidence,
                            normalizedPoint: CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY))
        }
    }

    private static func previewImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .right)
    }
}
