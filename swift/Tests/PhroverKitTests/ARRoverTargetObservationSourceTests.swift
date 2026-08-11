import CoreVideo
import RoverNav
import simd
import XCTest
@testable import PhroverKit

@MainActor
final class ARRoverTargetObservationSourceTests: XCTestCase {
    func testGroundsAllDetectionsFromSameFrameAndBestUngroundedBoxDoesNotFallThrough() throws {
        let snapshot = makeSnapshot()
        let sink = TargetAdapterSink()
        let source = ARRoverTargetObservationSource(sessionManager: ARSessionManager(),
            clock: RuntimeSilentSearchClock(), canonicalLabel: "chair",
            sharedFrame: SharedMissionFrame(localOrigin: Vec2(0, 0), localNorthHeading: 0,
                                            sessionGeneration: 5)!, eventSink: sink,
            detector: { snapshot in
                Detector.FrameDetections(frameID: snapshot.id, monotonicTimestamp: snapshot.timestamp,
                    detections: [
                        Detector.Detection(label: "chair", confidence: 0.99,
                            boundingBox: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)),
                        Detector.Detection(label: "chair", confidence: 0.91,
                            boundingBox: CGRect(x: 0.75, y: 0.75, width: 0.1, height: 0.1)),
                    ])
            })

        let observation = try XCTUnwrap(source.frameObservation(in: snapshot))

        XCTAssertEqual(observation.frameID, 11)
        XCTAssertNil(observation.detections[0].localGroundedPoint)
        XCTAssertNotNil(observation.detections[1].localGroundedPoint)
        XCTAssertEqual(source.process(snapshot), .pending)
        XCTAssertEqual(sink.rejections, [.invalidGrounding])
    }

    func testRejectsDetectionResultFromDifferentFrameAndGeneration() {
        let frame = SharedMissionFrame(localOrigin: Vec2(0, 0), localNorthHeading: 0,
                                       sessionGeneration: 5)!
        let wrongIdentity = ARRoverTargetObservationSource(sessionManager: ARSessionManager(),
            clock: RuntimeSilentSearchClock(), canonicalLabel: "chair", sharedFrame: frame,
            detector: { snapshot in
                Detector.FrameDetections(frameID: ARFrameID(generation: 5, sequence: 12),
                    monotonicTimestamp: snapshot.timestamp, detections: [])
            })
        XCTAssertNil(wrongIdentity.frameObservation(in: makeSnapshot()))

        let correctDetector: ARRoverTargetObservationSource.DetectorFunction = { snapshot in
            Detector.FrameDetections(frameID: snapshot.id, monotonicTimestamp: snapshot.timestamp,
                                     detections: [])
        }
        let wrongGeneration = ARRoverTargetObservationSource(sessionManager: ARSessionManager(),
            clock: RuntimeSilentSearchClock(), canonicalLabel: "chair", sharedFrame: frame,
            detector: correctDetector)
        XCTAssertNil(wrongGeneration.frameObservation(in: makeSnapshot(generation: 6)))
    }

    private func makeSnapshot(generation: UInt64 = 5) -> ARFrameSnapshot {
        var image: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &image)
        var depth: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 10, 10, kCVPixelFormatType_DepthFloat32, nil, &depth)
        CVPixelBufferLockBaseAddress(depth!, [])
        let stride = CVPixelBufferGetBytesPerRow(depth!) / MemoryLayout<Float>.size
        let values = CVPixelBufferGetBaseAddress(depth!)!.assumingMemoryBound(to: Float.self)
        for y in 0..<10 { for x in 0..<10 { values[y * stride + x] = 2 } }
        values[5 * stride + 5] = 0
        CVPixelBufferUnlockBaseAddress(depth!, [])
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(100, 0, 0), SIMD3<Float>(0, 100, 0), SIMD3<Float>(50, 50, 1)
        ))
        return ARFrameSnapshot(id: ARFrameID(generation: generation, sequence: 11), timestamp: 7,
            image: image!, cameraTransform: matrix_identity_float4x4, cameraIntrinsics: intrinsics,
            imageResolution: CGSize(width: 100, height: 100), depthMap: depth!,
            pose: Pose2D(position: Vec2(0, 0), yaw: 0), trackingQuality: .normal)
    }
}

private final class TargetAdapterSink: TargetTrackerEventSink {
    var rejections: [TargetRejectionReason] = []
    func record(_ event: TargetTrackerEvent) {
        if case let .rejected(_, reason) = event { rejections.append(reason) }
    }
}
