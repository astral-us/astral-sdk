import XCTest
import CoreVideo
import simd
import RoverNav
@testable import PhroverKit

@MainActor
final class ARFollowMePerceptionSourceTests: XCTestCase {
    func testPersonFeetProjectFromTheSameSnapshot() {
        var image: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 20, 20, kCVPixelFormatType_32BGRA, nil, &image)
        var depth: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 20, 20, kCVPixelFormatType_DepthFloat32, nil, &depth)
        let map = try! XCTUnwrap(depth)
        CVPixelBufferLockBaseAddress(map, [])
        let base = CVPixelBufferGetBaseAddress(map)!.assumingMemoryBound(to: Float32.self)
        for row in 0..<20 {
            for col in 0..<20 { base[row * CVPixelBufferGetBytesPerRow(map) / 4 + col] = 3 }
        }
        CVPixelBufferUnlockBaseAddress(map, [])
        let id = ARFrameID(generation: 2, sequence: 7)
        let snapshot = ARFrameSnapshot(
            id: id, timestamp: 12, image: try! XCTUnwrap(image),
            cameraTransform: simd_float4x4(1),
            cameraIntrinsics: simd_float3x3(columns: (
                SIMD3<Float>(10, 0, 0), SIMD3<Float>(0, 10, 0), SIMD3<Float>(10, 10, 1))),
            imageResolution: CGSize(width: 20, height: 20), depthMap: map,
            pose: Pose2D(position: .zero, yaw: 0), trackingQuality: .normal)
        let detections = [
            Detector.Detection(label: "person", confidence: 0.9,
                               boundingBox: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6)),
            Detector.Detection(label: "chair", confidence: 0.9,
                               boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        ]

        let batch = ARFollowMePerceptionSource.batch(from: snapshot, detections: detections,
                                                    trackingReason: .excessiveMotion)

        XCTAssertEqual(batch.frameID, id)
        XCTAssertEqual(batch.timestamp, 12)
        XCTAssertEqual(batch.people.count, 1)
        XCTAssertEqual(batch.trackingQuality, .normal)
        XCTAssertEqual(batch.pose, snapshot.pose, "Live diagnostic limitations cannot invalidate a normal snapshot")
        // Vision's portrait y=.2 maps to raw sensor x=16; (16-10)/10 * 3 = 1.8.
        XCTAssertEqual(batch.people[0].position.x, 1.8, accuracy: 0.01)
        XCTAssertEqual(batch.people[0].position.y, -3, accuracy: 0.01)
    }

    func testARInterruptionCannotBeOverwrittenByLaterFrame() async {
        let ar = ARSessionManager()
        let detector = Detector(supportedLabels: ["person"], detectionHandler: { _ in [] })
        let source = ARFollowMePerceptionSource(ar: ar, detector: detector)
        let events = source.events()
        var iterator = events.makeAsyncIterator()
        ar.interruptionBeganForTesting()
        for _ in 0..<20 { await Task.yield() }

        var image: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 20, 20, kCVPixelFormatType_32BGRA, nil, &image)
        ar.ingestForTesting(image: try! XCTUnwrap(image), timestamp: 3,
                            cameraTransform: simd_float4x4(1), intrinsics: simd_float3x3(1),
                            imageResolution: CGSize(width: 20, height: 20), depthMap: nil,
                            trackingQuality: .normal)
        for _ in 0..<20 { await Task.yield() }

        guard case .interrupted? = await iterator.next() else {
            return XCTFail("An AR interruption must never be discarded in favor of a frame")
        }
    }

    func testLimitedSnapshotKeepsItsQualityAndCannotUseDiagnosticNormalTrackingForPerception() throws {
        var image: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 20, 20, kCVPixelFormatType_32BGRA, nil, &image)
        let snapshot = ARFrameSnapshot(
            id: ARFrameID(generation: 1, sequence: 4), timestamp: 8,
            image: try XCTUnwrap(image), cameraTransform: simd_float4x4(1),
            cameraIntrinsics: simd_float3x3(1), imageResolution: CGSize(width: 20, height: 20),
            depthMap: nil, pose: Pose2D(position: Vec2(2, 3), yaw: 0), trackingQuality: .limited)
        let batch = ARFollowMePerceptionSource.batch(from: snapshot, detections: [],
                                                    trackingReason: nil, inferenceDuration: 0.125)
        XCTAssertEqual(batch.trackingQuality, .limited)
        XCTAssertNil(batch.pose)
        XCTAssertTrue(batch.people.isEmpty)
        XCTAssertEqual(batch.inferenceDuration, 0.125)
        XCTAssertEqual(ARFollowMePerceptionSource.trackingReason(from: .limited(.excessiveMotion)), .excessiveMotion)
        XCTAssertEqual(ARFollowMePerceptionSource.trackingReason(from: .limited(.insufficientFeatures)), .insufficientFeatures)
        XCTAssertEqual(ARFollowMePerceptionSource.trackingReason(from: .limited(.initializing)), .initializing)
        XCTAssertEqual(ARFollowMePerceptionSource.trackingReason(from: .limited(.relocalizing)), .relocalizing)
        XCTAssertNil(ARFollowMePerceptionSource.trackingReason(from: .normal))
    }

    func testStreamMeasuresInferenceAndSkipsItForLimitedTracking() async throws {
        let ar = ARSessionManager()
        var inferenceCount = 0
        let detector = Detector(supportedLabels: ["person"], detectionHandler: { _ in
            inferenceCount += 1
            Thread.sleep(forTimeInterval: 0.02)
            return []
        })
        let source = ARFollowMePerceptionSource(ar: ar, detector: detector)
        var iterator = source.events().makeAsyncIterator()
        var image: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 20, 20, kCVPixelFormatType_32BGRA, nil, &image)
        let buffer = try XCTUnwrap(image)
        ar.ingestForTesting(image: buffer, timestamp: 3,
                            cameraTransform: simd_float4x4(1), intrinsics: simd_float3x3(1),
                            imageResolution: CGSize(width: 20, height: 20), depthMap: nil,
                            trackingQuality: .normal)
        guard case .frame(let normal)? = await iterator.next() else { return XCTFail("Expected normal batch") }
        XCTAssertEqual(normal.trackingQuality, .normal)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(normal.inferenceDuration), 0.02)
        XCTAssertEqual(inferenceCount, 1)
        ar.ingestForTesting(image: buffer, timestamp: 4,
                            cameraTransform: simd_float4x4(1), intrinsics: simd_float3x3(1),
                            imageResolution: CGSize(width: 20, height: 20), depthMap: nil,
                            trackingQuality: .limited)
        guard case .frame(let limited)? = await iterator.next() else { return XCTFail("Expected limited batch") }
        XCTAssertEqual(limited.trackingQuality, .limited)
        XCTAssertNil(limited.pose)
        XCTAssertEqual(limited.inferenceDuration, 0)
        XCTAssertEqual(inferenceCount, 1)
    }
}
