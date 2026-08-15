import Foundation

public enum SilentSearchCalibrationCorner: String, Equatable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

public enum SilentSearchCalibrationGroundingFailure: Error, Equatable, Sendable {
    case trackingNotNormal
    case generationMismatch
    case frameMismatch
    case timestampMismatch
    case invalidPayload
    case wrongMarkerID
    case missingDepthMap
    case cornerUnavailable(SilentSearchCalibrationCorner)
}

public enum SilentSearchCalibrationFeedback: Equatable, Sendable {
    case expectedMarkerDetected(
        frameID: ARFrameID,
        monotonicTimestamp: TimeInterval,
        markerID: String,
        corners: OrientedMarkerCorners
    )
    case qrLost(frameID: ARFrameID, monotonicTimestamp: TimeInterval)
    case scannerFailed(frameID: ARFrameID, monotonicTimestamp: TimeInterval)
    case groundingFailed(
        frameID: ARFrameID,
        monotonicTimestamp: TimeInterval,
        reason: SilentSearchCalibrationGroundingFailure
    )
    case allCornersGrounded(frameID: ARFrameID, monotonicTimestamp: TimeInterval)
}

public enum SilentSearchCalibrationIssue: Equatable, Sendable {
    case scannerFailure
    case groundingFailure(SilentSearchCalibrationGroundingFailure)
}

public struct SilentSearchCalibrationVisualState: Equatable, Sendable {
    public var qrDecoded = false
    public var cornersGrounded = false
    public var sampleAccepted = false
    public var currentMarkerID: String?
    public var currentCorners: OrientedMarkerCorners?
    public var lastDetectionTimestamp: TimeInterval?
    public var currentIssue: SilentSearchCalibrationIssue?

    public init() {}
}
