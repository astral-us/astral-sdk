import ARKit
import CoreVideo
import RoverNav
import XCTest
@testable import PhroverKit

@MainActor
final class ARSessionManagerTests: XCTestCase {
    func testResetAdvancesGenerationAndFramesAdvanceSequenceOnce() throws {
        let manager = ARSessionManager()

        manager.resetForTesting()
        XCTAssertEqual(manager.sessionGeneration, 1)
        XCTAssertNil(manager.latestSnapshot)

        manager.ingestForTesting(image: makeImage(), timestamp: 10, cameraTransform: transform(x: 1, z: 2),
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 8, height: 6),
            depthMap: makeDepth(2), trackingQuality: .normal)
        manager.ingestForTesting(image: makeImage(), timestamp: 11, cameraTransform: transform(x: 3, z: 4),
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 8, height: 6),
            depthMap: nil, trackingQuality: .limited)

        XCTAssertEqual(manager.latestSnapshot?.id, ARFrameID(generation: 1, sequence: 2))
        XCTAssertEqual(manager.latestSnapshot?.timestamp, 11)
        XCTAssertEqual(manager.pose, Pose2D(position: Vec2(3, 4), yaw: -.pi / 2))
        XCTAssertEqual(manager.trackingQuality, .limited)
        XCTAssertNil(manager.latestDepthMap, "a color frame without depth must clear stale depth")

        manager.resetForTesting()
        XCTAssertEqual(manager.sessionGeneration, 2)
        manager.ingestForTesting(image: makeImage(), timestamp: 12, cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 8, height: 6),
            depthMap: nil, trackingQuality: .normal)
        XCTAssertEqual(manager.latestSnapshot?.id, ARFrameID(generation: 2, sequence: 1))
    }

    func testSnapshotStreamsAreIndependentAndBufferOnlyNewestFrame() async throws {
        let manager = ARSessionManager()
        manager.resetForTesting()
        let firstStream = manager.snapshots()
        let secondStream = manager.snapshots()
        manager.ingestForTesting(image: makeImage(), timestamp: 1, cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 8, height: 6),
            depthMap: nil, trackingQuality: .normal)
        manager.ingestForTesting(image: makeImage(), timestamp: 2, cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 8, height: 6),
            depthMap: nil, trackingQuality: .normal)

        var first = firstStream.makeAsyncIterator()
        var second = secondStream.makeAsyncIterator()
        let firstValue = await first.next()
        let secondValue = await second.next()
        XCTAssertEqual(firstValue?.id.sequence, 2)
        XCTAssertEqual(secondValue?.id.sequence, 2)
    }

    func testLifecycleStreamsRetainResetInterruptionAndFailureEventsPerSubscriber() async {
        let manager = ARSessionManager()
        let firstStream = manager.lifecycleEvents()
        let secondStream = manager.lifecycleEvents()

        manager.resetForTesting()
        manager.interruptionBeganForTesting()
        manager.interruptionEndedForTesting()
        manager.failureForTesting(description: "camera unavailable")

        var first = firstStream.makeAsyncIterator()
        var second = secondStream.makeAsyncIterator()
        var firstEvents: [ARSessionLifecycleEvent] = []
        var secondEvents: [ARSessionLifecycleEvent] = []
        for _ in 0..<4 {
            if let event = await first.next() { firstEvents.append(event) }
            if let event = await second.next() { secondEvents.append(event) }
        }
        let expected: [ARSessionLifecycleEvent] = [
            .reset(generation: 1), .interrupted(generation: 1),
            .interruptionEnded(generation: 1), .failed(generation: 1, description: "camera unavailable"),
        ]
        XCTAssertEqual(firstEvents, expected)
        XCTAssertEqual(secondEvents, expected)
        XCTAssertNil(manager.latestSnapshot)
        XCTAssertNil(manager.latestDepthMap)
        XCTAssertNil(manager.pose)
        XCTAssertEqual(manager.trackingQuality, .unavailable)
    }

    private func makeImage() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }

    private func makeDepth(_ value: Float) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_DepthFloat32, nil, &buffer)
        let result = buffer!
        CVPixelBufferLockBaseAddress(result, [])
        CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: Float.self)
            .initialize(repeating: value, count: 4)
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }

    private func transform(x: Float, z: Float) -> simd_float4x4 {
        var value = matrix_identity_float4x4
        value.columns.3 = SIMD4<Float>(x, 0, z, 1)
        return value
    }
}
