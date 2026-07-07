import Foundation
import CoreGraphics
import RoverNav

/// One perceived object, as seen by whichever detector produced it — the on-device COCO
/// `Detector`, or a cloud VLM's open-vocabulary grounding.
public struct PerceivedObject: Equatable {
    public var label: String
    public var confidence: Float
    /// Normalized Vision-space point (bottom-left origin), suitable for
    /// `ARSessionManager.unproject(normalizedPoint:)`.
    public var normalizedPoint: CGPoint

    public init(label: String, confidence: Float, normalizedPoint: CGPoint) {
        self.label = label
        self.confidence = confidence
        self.normalizedPoint = normalizedPoint
    }
}

/// The rover's only "place memory": what the operator said, and where the rover was when
/// they said it. There's no naming grammar and no special-cased return-to-origin — a brain
/// reads this list itself to work out things like "go home" or "and back".
public struct MissionMemory {
    public struct Turn {
        public var utterance: String
        public var pose: Pose2D
        public var timestamp: Date

        public init(utterance: String, pose: Pose2D, timestamp: Date = Date()) {
            self.utterance = utterance
            self.pose = pose
            self.timestamp = timestamp
        }
    }

    public private(set) var turns: [Turn] = []
    /// Where the rover was when the very first utterance of the mission was recorded.
    public private(set) var missionStartPose: Pose2D?

    public init() {}

    public mutating func record(utterance: String, at pose: Pose2D) {
        if missionStartPose == nil { missionStartPose = pose }
        turns.append(Turn(utterance: utterance, pose: pose))
    }
}

/// Where a `navigate` decision should go.
public enum NavigationTarget: Equatable {
    /// A point in the current camera frame to unproject via LiDAR depth — how a brain
    /// points at something it just grounded (on-device closed-set or cloud open-vocab).
    case imagePoint(CGPoint)
    /// An already-resolved world-plane point — e.g. read back out of `MissionMemory` for
    /// "go home"/"and back", or a goal computed earlier.
    case worldPoint(Vec2)
}

/// The one action a `RoverBrain` chooses per think-tick. Deliberately small and closed so
/// `MissionAgent` remains the sole place that turns a decision into motor commands — no
/// brain output reaches `RoverControl` directly.
public enum RoverDecision: Equatable {
    case navigate(NavigationTarget)
    /// Turn to look for something not currently in view. Radians, CCW positive; a brain can
    /// ask for more than one look (each up to `2 * .pi`) across successive ticks.
    case lookAround(angle: Double)
    /// Speak a clarifying question, then wait for a reply before the next decision.
    case ask(String)
    /// Speak, with no expectation of a reply.
    case say(String)
    case stop
    /// The mission is satisfied; stop and go idle.
    case done
}

/// Snapshot of the world + conversation handed to a `RoverBrain` each think-tick.
/// Deliberately data-only so different brains — an on-device text reasoner, a cloud vision
/// reasoner — can consume the same shape, each using whatever subset it can.
public struct MissionContext {
    /// What the operator just said, if this tick was triggered by a fresh utterance.
    public var utterance: String?
    /// Downscaled JPEG of the rover's current view, for brains that can see. `nil` when no
    /// frame is available yet (or offline brains that don't use it).
    public var frameJPEG: Data?
    /// Closed-set objects detected on-device right now — always available; feeds
    /// `OnDeviceBrain` directly and gives a cloud brain a cheap candidate list alongside
    /// the raw frame.
    public var visibleObjects: [PerceivedObject]
    public var pose: Pose2D?
    public var navState: NavigationController.State
    public var memory: MissionMemory
    /// Set when a prior `.ask` produced no usable reply (timeout, or "I don't know") — lets
    /// a brain proceed best-effort instead of repeating the same question.
    public var lastAnswerWasInconclusive: Bool

    public init(utterance: String? = nil,
                frameJPEG: Data? = nil,
                visibleObjects: [PerceivedObject] = [],
                pose: Pose2D? = nil,
                navState: NavigationController.State = .idle,
                memory: MissionMemory = MissionMemory(),
                lastAnswerWasInconclusive: Bool = false) {
        self.utterance = utterance
        self.frameJPEG = frameJPEG
        self.visibleObjects = visibleObjects
        self.pose = pose
        self.navState = navState
        self.memory = memory
        self.lastAnswerWasInconclusive = lastAnswerWasInconclusive
    }
}

/// A reasoner that turns a `MissionContext` into the next `RoverDecision`. Two
/// implementations, chosen by `MissionAgent` per think-tick based on connectivity:
/// `CloudBrain` (primary, open-vocabulary) and `OnDeviceBrain` (fallback, best-effort).
@MainActor
public protocol RoverBrain: AnyObject {
    func nextAction(_ context: MissionContext) async throws -> RoverDecision
}

public enum RoverBrainError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        "This brain is not available right now."
    }
}
