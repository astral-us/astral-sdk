import XCTest
import ImageIO
import CoreML
import CoreVideo
import RoverNav
import simd
@testable import PhroverKit

final class DetectorTests: XCTestCase {
    func testModelResourcePrefersCompiledModelBundle() {
        let url = Detector.modelResourceURL(modelName: "RoverYOLO")

        XCTAssertEqual(url?.pathExtension, "mlmodelc")
    }

    func testFallbackOrientationsTryPreferredFirstAndDeduplicate() {
        XCTAssertEqual(Detector.detectionOrientations(preferred: .right), [.right, .up, .left, .down])
        XCTAssertEqual(Detector.detectionOrientations(preferred: .up), [.up, .right, .left, .down])
    }

    func testModelConfigurationAvoidsGPUForBackgroundSafety() {
        XCTAssertEqual(Detector.modelConfiguration().computeUnits, .cpuAndNeuralEngine)
    }

    func testCanonicalLabelsExposeOnlyStringModelClassLabels() {
        XCTAssertEqual(Detector.canonicalLabels(from: ["chair", 7, "person", "chair"]), ["chair", "person"] as Set)
    }

    func testFrameDetectionSeamPreservesSnapshotIdentity() {
        let detector = Detector(supportedLabels: ["chair"]) { _ in
            [Detector.Detection(label: "chair", confidence: 0.95,
                                boundingBox: CGRect(x: 0.25, y: 0.5, width: 0.2, height: 0.3))]
        }
        let snapshot = ARFrameSnapshot(
            id: ARFrameID(generation: 4, sequence: 9), timestamp: 12.5, image: makeImage(),
            cameraTransform: matrix_identity_float4x4, cameraIntrinsics: matrix_identity_float3x3,
            imageResolution: CGSize(width: 8, height: 6), depthMap: nil,
            pose: RoverNav.Pose2D(position: RoverNav.Vec2(0, 0), yaw: 0), trackingQuality: .normal
        )

        let result = detector.detect(snapshot)

        XCTAssertEqual(detector.supportedCanonicalLabels, ["chair"])
        XCTAssertEqual(result.frameID, snapshot.id)
        XCTAssertEqual(result.monotonicTimestamp, 12.5)
        XCTAssertEqual(result.detections.map(\.label), ["chair"])
    }

    private func makeImage() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }
}
