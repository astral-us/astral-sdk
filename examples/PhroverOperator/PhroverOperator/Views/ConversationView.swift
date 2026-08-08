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
    let topology: SessionRoomTopology
    let cloudBrain: CloudBrain?
    let doorwayEvidenceProvider: CloudDoorwayEvidenceProvider?

    @State private var speechIn = SpeechIn()
    @State private var speechOut = SpeechOut()
    @State private var agent: MissionAgent?
    @State private var missionPhase: MissionAgent.Phase = .idle
    @State private var lastCommand = LastCommandState()
    @State private var authorized = false
    @State private var navigationDebug = NavigationDebugSummary()

    var body: some View {
        VStack(spacing: 18) {
            if !statusLabel.isEmpty {
                Text(statusLabel).font(.headline)
            }

            LiveCameraDebugPanel(ar: ar, summary: navigationDebug)
                .frame(maxWidth: 320)

            Text(speechIn.partialTranscript)
                .foregroundStyle(.secondary)
                .frame(minHeight: 40)
                .multilineTextAlignment(.center)

            if let record = lastCommand.record {
                VStack(alignment: .leading, spacing: 8) {
                    Text(record.command)
                        .font(.headline)
                        .accessibilityIdentifier("last-command-text")
                    Text(record.status.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor(record.status))
                        .accessibilityIdentifier("last-command-status")
                    Text(record.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("last-command-message")
                }
                .frame(maxWidth: 320, alignment: .leading)
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("last-command-card")
            }

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
            authorized = await speechIn.requestAuthorization()
            let detector = await Detector()
            let perception = ARPerceptionSource(ar: ar, detector: detector)
            let voice = SpeechRoverVoice(out: speechOut, speechIn: speechIn)
            let onDevice = OnDeviceBrain()
            let brain: RoverBrain = cloudBrain.map { HybridBrain(cloud: $0, onDevice: onDevice) } ?? onDevice
            agent = MissionAgent(
                motion: nav,
                perception: perception,
                voice: voice,
                roomTopology: topology,
                doorwayEvidenceProvider: doorwayEvidenceProvider,
                phaseDidChange: { phase in
                    missionPhase = phase
                },
                roomTransitionStateDidChange: { state in
                    navigationDebug.apply(state)
                },
                commandStatusDidChange: { status in
                    lastCommand.reduce(status)
                }
            ) { brain }
        }
    }

    private var statusLabel: String {
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
        if speechIn.state == .processing { return "Processing speech…" }
        return phaseLabel(missionPhase)
    }

    private func statusColor(_ status: LastCommandState.DisplayStatus) -> Color {
        switch status {
        case .listening, .recognized, .working: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private func startListening() {
        guard authorized, agent != nil, speechIn.state != .listening else { return }
        do {
            try speechIn.start(onEvent: { event in
                lastCommand.reduce(event)
            }) { captureID, utterance in
                lastCommand.finalizeCapture(captureID)
                Task { @MainActor in
                    await agent?.handle(utterance)
                }
            }
        } catch {
            RuntimeFileLog.append("speech_capture_ui_error", fields: [
                "error": String(describing: error)
            ])
        }
    }
}

private struct LiveCameraDebugPanel: View {
    let ar: ARSessionManager
    let summary: NavigationDebugSummary

    @State private var previewImage: UIImage?

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
                Text("Openings: \(summary.openingsText)")
                Text("Doorway candidates: \(summary.doorwayCandidatesText)")
                Text("Target: \(summary.targetText)")
                Text("Transition: \(summary.transitionText)")
                    .lineLimit(2)
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .task {
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
            return
        }
        previewImage = Self.previewImage(from: buffer)
    }

    private static func previewImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .right)
    }
}
