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

public struct SilentSearchCalibrationFrameContext: Equatable, Sendable {
    public let frameID: ARFrameID
    public let monotonicTimestamp: TimeInterval

    public init(frameID: ARFrameID, monotonicTimestamp: TimeInterval) {
        self.frameID = frameID
        self.monotonicTimestamp = monotonicTimestamp
    }
}

public enum SilentSearchCalibrationFeedback: Equatable, Sendable {
    case trackingNotNormal(context: SilentSearchCalibrationFrameContext)
    case expectedMarkerDetected(
        context: SilentSearchCalibrationFrameContext,
        markerID: String,
        corners: OrientedMarkerCorners
    )
    case qrLost(context: SilentSearchCalibrationFrameContext)
    case scannerFailed(context: SilentSearchCalibrationFrameContext)
    case groundingFailed(
        context: SilentSearchCalibrationFrameContext,
        reason: SilentSearchCalibrationGroundingFailure
    )
    case allCornersGrounded(context: SilentSearchCalibrationFrameContext)
}

public enum SilentSearchCalibrationIssue: Equatable, Sendable {
    case trackingNotNormal
    case scannerFailure
    case groundingFailure(SilentSearchCalibrationGroundingFailure)
    case calibrationRejection(SharedMissionCalibrationDiagnostic)
}

public struct SilentSearchCalibrationVisualState: Equatable, Sendable {
    public var qrDecoded = false
    public var cornersGrounded = false
    public var sampleAccepted = false
    public var currentMarkerID: String?
    public var currentCorners: OrientedMarkerCorners?
    public var currentFrameContext: SilentSearchCalibrationFrameContext?
    public var lastDetectionTimestamp: TimeInterval?
    public var currentIssue: SilentSearchCalibrationIssue?

    public init() {}
}
