import Foundation
import RoverNav

/// One depth-projected person detection and rover pose from the same AR frame.
public struct FollowPersonObservation {
    public let frameID: ARFrameID
    public let timestamp: TimeInterval
    public let confidence: Float
    /// Normalized Vision coordinates.
    public let boundingBox: CGRect
    public let position: Vec2
    public let pose: Pose2D

    public init(frameID: ARFrameID, timestamp: TimeInterval, confidence: Float,
                boundingBox: CGRect, position: Vec2, pose: Pose2D) {
        self.frameID = frameID
        self.timestamp = timestamp
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.position = position
        self.pose = pose
    }
}

public enum FollowTrackMatch {
    case matched(FollowPersonObservation)
    case lost
    case ambiguous
}

/// Shared follow thresholds in metres, seconds, radians, and normalized image units.
public struct FollowMeConfiguration {
    public var minimumConfidence: Float = 0.50
    public var maximumObservationAge: TimeInterval = 0.5
    public var maximumWorldDistance: Double = 0.75
    public var minimumBoxIoU: CGFloat = 0.10
    public var maximumScreenCenterDistance: CGFloat = 0.25
    public var reacquisitionDistance: Double = 1.5
    public var standOffDistance: Double = 1.5
    public var minimumHoldDistance: Double = 1.25
    public var maximumHoldDistance: Double = 1.75
    public var scanIncrement: Double = .pi / 6
    public var maximumScanRotation: Double = 2 * .pi
    public var minimumGoalChange: Double = 0.30
    public var maximumGoalUpdatesPerSecond: Double = 3
    public var perceptionRecoverySeconds: TimeInterval = 2
    public var reacquisitionSeconds: TimeInterval = 10

    public init() {}
}
