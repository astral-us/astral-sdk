import XCTest
import ImageIO
import CoreML
import CoreVideo
import RoverNav
import simd
@testable import PhroverKit

final class DetectorTests: XCTestCase {
    func testFollowReceiptCapturesActualRightOrientationWithoutFallbackOnEmptyOrError() {
        let snapshot = ARFrameSnapshot(id: .init(generation: 1, sequence: 1), timestamp: 100,
            image: makeImage(), cameraTransform: matrix_identity_float4x4, cameraIntrinsics: matrix_identity_float3x3,
            imageResolution: CGSize(width: 8, height: 6), depthMap: nil,
            pose: .init(position: .zero, yaw: 0), trackingQuality: .normal)
        for scenario in 0..<3 {
            var attempts: [CGImagePropertyOrientation] = []
            let detector = Detector(supportedLabels: ["person"], visionHandler: { _, orientation in
                attempts.append(orientation)
                if scenario == 2 && orientation == .right { throw URLError(.cannotDecodeContentData) }
                if scenario == 0 && orientation == .right { return [] }
                return [.init(label: "person", confidence: 0.99,
                    boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.3))]
            })
            let receipt = detector.evaluateForFollow(snapshot)
            XCTAssertEqual(attempts, [.right])
            XCTAssertEqual(receipt.status, scenario == 2 ? .failed : .executed)
            XCTAssertEqual(receipt.orientation, scenario == 2 ? nil : .right)
            XCTAssertEqual(receipt.frame.detections.count, scenario == 1 ? 1 : 0)
            XCTAssertEqual(receipt.failureReason, scenario == 2 ? .inferenceFailed : nil)
            attempts.removeAll()
            let generic = detector.evaluate(snapshot)
            XCTAssertEqual(attempts, scenario == 1 ? [.right] : [.right, .up])
            XCTAssertEqual(generic.status, .executed)
            XCTAssertEqual(generic.orientation, scenario == 1 ? .right : .up)
            XCTAssertEqual(generic.frame.detections.count, 1)
        }
    }
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
