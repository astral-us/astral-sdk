import Foundation
import CoreGraphics
import RoverNav

/// Motion surface `MissionAgent` drives. A separate protocol from the concrete
/// `NavigationController` (rather than depending on it directly) so the mission loop can be
/// tested without a live ARKit session.
@MainActor
public protocol RoverMotion: AnyObject {
    var state: NavigationController.State { get }
    func navigate(to goal: Vec2)
    func rotate(by angle: Double) async
    func cancel()
}

extension NavigationController: RoverMotion {}

/// Perception surface `MissionAgent` reads. A separate protocol from `ARSessionManager` +
/// `Detector` so the mission loop can be tested by scripting what's "visible" without a
/// live ARKit session or the bundled CoreML model.
@MainActor
public protocol RoverPerception: AnyObject {
    var pose: Pose2D? { get }
    func detectObjects() -> [PerceivedObject]
    func unproject(normalizedPoint: CGPoint) -> Vec2?
    func capturedFrameJPEG() -> Data?
}

/// Default `RoverPerception`: on-device COCO detection over the live ARKit frame.
@MainActor
public final class ARPerceptionSource: RoverPerception {
    private let ar: ARSessionManager
    private let detector: Detector?

    public init(ar: ARSessionManager, detector: Detector?) {
        self.ar = ar
        self.detector = detector
    }

    public var pose: Pose2D? { ar.pose }

    public func detectObjects() -> [PerceivedObject] {
        guard let detector, let buffer = ar.latestPixelBuffer else { return [] }
        return detector.detect(buffer).map {
            PerceivedObject(label: $0.label,
                            confidence: $0.confidence,
                            normalizedPoint: CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY))
        }
    }

    public func unproject(normalizedPoint: CGPoint) -> Vec2? {
        ar.unproject(normalizedPoint: normalizedPoint)
    }

    public func capturedFrameJPEG() -> Data? {
        FrameEncoder.jpeg(ar.latestPixelBuffer)
    }
}

/// Voice surface `MissionAgent` drives. A separate protocol from `SpeechOut`/`SpeechIn` so
/// the mission loop can be tested by scripting operator replies without real audio I/O.
@MainActor
public protocol RoverVoice: AnyObject {
    func speak(_ text: String)
    /// Ask a question and wait for a reply, honoring `timeout`. `nil` on timeout or no
    /// usable reply — the caller proceeds best-effort.
    func ask(_ question: String, timeout: TimeInterval) async -> String?
}

/// Default `RoverVoice`: on-device TTS/STT.
@MainActor
public final class SpeechRoverVoice: RoverVoice {
    private let out: SpeechOut
    private let speechIn: SpeechIn?

    public init(out: SpeechOut = SpeechOut(), speechIn: SpeechIn? = nil) {
        self.out = out
        self.speechIn = speechIn
    }

    public func speak(_ text: String) { out.speak(text) }

    public func ask(_ question: String, timeout: TimeInterval) async -> String? {
        out.speak(question)
        guard let speechIn else { return nil }
        return await speechIn.listenOnce(timeout: timeout)
    }
}

/// The mission loop: gather context, ask the current `RoverBrain` for the next action,
/// execute it, and repeat — until the brain says `.stop`/`.done`, or it asks a question
/// that goes unanswered and has nothing left to try.
///
/// There is deliberately no special-cased command grammar here (no "and back" parsing, no
/// place-naming syntax). The operator's words and the rover's `MissionMemory` are just
/// inputs to whichever `RoverBrain` is current; behaviors like returning to a remembered
/// pose emerge from the brain reading that memory, not from code in this class.
@Observable
@MainActor
public final class MissionAgent {
    public enum Phase: Equatable { case idle, thinking, acting, waitingForAnswer }

    public private(set) var phase: Phase = .idle
    public private(set) var memory = MissionMemory()

    private let motion: RoverMotion
    private let perception: RoverPerception
    private let voice: RoverVoice
    private let askTimeout: TimeInterval
    private let currentBrain: () -> RoverBrain?

    private var lastAnswerWasInconclusive = false

    /// Hard cap on think-ticks per utterance so a brain that never emits `.stop`/`.done`
    /// can't loop forever (matters most for scripted/fake brains in tests).
    private let maxTicksPerUtterance: Int

    public init(motion: RoverMotion,
                perception: RoverPerception,
                voice: RoverVoice,
                askTimeout: TimeInterval = 8,
                maxTicksPerUtterance: Int = 25,
                currentBrain: @escaping () -> RoverBrain?) {
        self.motion = motion
        self.perception = perception
        self.voice = voice
        self.askTimeout = askTimeout
        self.maxTicksPerUtterance = maxTicksPerUtterance
        self.currentBrain = currentBrain
    }

    /// Handle one operator utterance end-to-end.
    public func handle(_ utterance: String) async {
        guard let pose = perception.pose else {
            voice.speak("I don't have my bearings yet — give me a moment to look around.")
            return
        }
        memory.record(utterance: utterance, at: pose)
        lastAnswerWasInconclusive = false
        await runLoop(firstUtterance: utterance)
    }

    // MARK: - Loop

    private func runLoop(firstUtterance: String?) async {
        var nextUtterance = firstUtterance

        for _ in 0..<maxTicksPerUtterance {
            guard let brain = currentBrain() else {
                voice.speak("Sorry, I can't think right now.")
                break
            }

            phase = .thinking
            let ctx = makeContext(utterance: nextUtterance)
            nextUtterance = nil

            let decision: RoverDecision
            do {
                decision = try await brain.nextAction(ctx)
            } catch {
                voice.speak("Sorry, I'm having trouble thinking right now.")
                break
            }

            phase = .acting
            switch decision {
            case .navigate(let target):
                guard let goal = resolve(target) else {
                    voice.speak("I couldn't quite figure out where that is.")
                    continue
                }
                motion.navigate(to: goal)
                await waitForMotionToSettle()

            case .lookAround(let angle):
                await motion.rotate(by: angle)

            case .ask(let question):
                phase = .waitingForAnswer
                if let reply = await voice.ask(question, timeout: askTimeout) {
                    lastAnswerWasInconclusive = false
                    if let pose = perception.pose { memory.record(utterance: reply, at: pose) }
                    nextUtterance = reply
                } else {
                    lastAnswerWasInconclusive = true
                }

            case .say(let text):
                voice.speak(text)

            case .stop:
                motion.cancel()
                phase = .idle
                return

            case .done:
                phase = .idle
                return
            }
        }
        phase = .idle
    }

    private func resolve(_ target: NavigationTarget) -> Vec2? {
        switch target {
        case .worldPoint(let p): return p
        case .imagePoint(let p): return perception.unproject(normalizedPoint: p)
        }
    }

    private func waitForMotionToSettle() async {
        while motion.state == .driving {
            try? await Task.sleep(for: .seconds(RoverConfig.commandInterval))
        }
    }

    private func makeContext(utterance: String?) -> MissionContext {
        MissionContext(utterance: utterance,
                       frameJPEG: perception.capturedFrameJPEG(),
                       visibleObjects: perception.detectObjects(),
                       pose: perception.pose,
                       navState: motion.state,
                       memory: memory,
                       lastAnswerWasInconclusive: lastAnswerWasInconclusive)
    }
}
