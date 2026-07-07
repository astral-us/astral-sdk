import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text. `requiresOnDeviceRecognition = true` so the rover keeps
/// understanding its operator with no WiFi — matches the all-on-device, offline-first
/// voice stack.
@Observable
@MainActor
public final class SpeechIn {
    public enum State: Equatable { case idle, listening, unavailable }

    public private(set) var state: State = .idle
    public private(set) var partialTranscript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var isStarting = false

    public init() {}

    public nonisolated func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
    }

    /// Start listening; invokes `onFinal` once a completed utterance is recognized.
    /// Push-to-talk is the intended usage — always-on listening risks false wake triggers
    /// in noisy environments.
    public func start(onFinal: @escaping (String) -> Void) throws {
        guard !isStarting, state != .listening else { return }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable
            throw SpeechError.recognizerUnavailable
        }
        isStarting = true
        defer { isStarting = false }

        stop()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        request = req

        Self.installTap(on: audioEngine.inputNode, request: req)
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
        state = .listening

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.partialTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        let text = result.bestTranscription.formattedString
                        self.finishRecognition(cancelTask: false)
                        onFinal(text)
                    }
                }
                if error != nil { self.finishRecognition(cancelTask: false) }
            }
        }
    }

    /// Listen for a single utterance and return it, or `nil` on timeout / recognizer
    /// failure. Convenience over `start(onFinal:)` for a mission agent's ask-then-listen
    /// turns, where "no answer" must be a normal, handled outcome rather than an error.
    public func listenOnce(timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var didResume = false
            let resumeOnce: (String?) -> Void = { [weak self] text in
                guard !didResume else { return }
                didResume = true
                self?.finishRecognition(cancelTask: true)
                continuation.resume(returning: text)
            }

            do {
                try start { text in resumeOnce(text) }
            } catch {
                resumeOnce(nil)
                return
            }

            Task {
                try? await Task.sleep(for: .seconds(timeout))
                resumeOnce(nil)
            }
        }
    }

    public func stop() {
        finishRecognition(cancelTask: true)
    }

    private func finishRecognition(cancelTask: Bool) {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        if cancelTask { task?.cancel() }
        task = nil
        request = nil
        isStarting = false
        if state != .unavailable { state = .idle }
    }

    private nonisolated static func installTap(
        on node: AVAudioInputNode,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }
}

public enum SpeechError: Error { case recognizerUnavailable }
