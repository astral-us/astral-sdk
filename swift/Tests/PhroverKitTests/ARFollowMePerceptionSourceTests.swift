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

        let batch = ARFollowMePerceptionSource.batch(from: snapshot, detections: detections)

        XCTAssertEqual(batch.frameID, id)
        XCTAssertEqual(batch.timestamp, 12)
        XCTAssertEqual(batch.people.count, 1)
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
}
