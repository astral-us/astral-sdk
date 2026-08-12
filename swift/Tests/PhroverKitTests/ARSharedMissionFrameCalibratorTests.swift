import CoreVideo
import RoverNav
import simd
import XCTest
@testable import PhroverKit

@MainActor
final class ARSharedMissionFrameCalibratorTests: XCTestCase {
    func testIgnoresSnapshotsUntilTrackingIsNormal() async throws {
        let manager = ARSessionManager()
        let scans = ScanCounter()
        let calibrator = ARSharedMissionFrameCalibrator(sessionManager: manager) { _ in
            scans.increment()
            return []
        }
        let stream = calibrator.events(markerID: "SILENT_SEARCH_01", sessionGeneration: 0)
        let consumer = Task {
            for await _ in stream {}
        }
        await Task.yield()

        manager.ingestForTesting(
            image: makeImage(), timestamp: 1, cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 100, height: 100),
            depthMap: nil, trackingQuality: .limited
        )
        manager.ingestForTesting(
            image: makeImage(), timestamp: 2, cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 100, height: 100),
            depthMap: nil, trackingQuality: .unavailable
        )
        await taskTurn()
        XCTAssertEqual(scans.value, 0)

        manager.ingestForTesting(
            image: makeImage(), timestamp: 3, cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 100, height: 100),
            depthMap: nil, trackingQuality: .normal
        )
        await eventually { scans.value == 1 }
        consumer.cancel()
    }

    func testGroundsOrientedCornersWithTheObservationSnapshot() throws {
        let snapshot = makeSnapshot(generation: 7, sequence: 3)
        let observation = OpticalObservation(
            payload: Data("PHROVER-CAL|1|SILENT_SEARCH_01".utf8), frameID: 3,
            monotonicTimestamp: 4.5,
            corners: OrientedMarkerCorners(topLeft: Vec2(0.6, 0.6), topRight: Vec2(0.6, 0.4),
                                           bottomLeft: Vec2(0.4, 0.6), bottomRight: Vec2(0.4, 0.4))
        )

        let grounded = try XCTUnwrap(ARSharedMissionFrameCalibrator.ground(
            observation: observation, in: snapshot, expectedMarkerID: "SILENT_SEARCH_01"
        ))

        XCTAssertEqual(grounded.sessionGeneration, 7)
        XCTAssertEqual(grounded.frameID, 3)
        XCTAssertEqual(grounded.monotonicTimestamp, 4.5)
        XCTAssertGreaterThan(grounded.corners.topLeft.y, grounded.corners.bottomLeft.y)
        XCTAssertEqual(grounded.corners.topLeft.x, -0.1, accuracy: 0.001)
        XCTAssertEqual(grounded.corners.topRight.x, 0.1, accuracy: 0.001)
    }

    func testRejectsMismatchedFrameMarkerAndMissingCornerDepth() {
        let snapshot = makeSnapshot(generation: 7, sequence: 3, missingTopLeftDepth: true)
        let corners = OrientedMarkerCorners(topLeft: Vec2(0.6, 0.6), topRight: Vec2(0.6, 0.4),
                                            bottomLeft: Vec2(0.4, 0.6), bottomRight: Vec2(0.4, 0.4))
        XCTAssertNil(ARSharedMissionFrameCalibrator.ground(observation: OpticalObservation(
            payload: Data("PHROVER-CAL|1|SILENT_SEARCH_01".utf8), frameID: 2,
            monotonicTimestamp: 1, corners: corners
        ), in: snapshot, expectedMarkerID: "SILENT_SEARCH_01"))
        XCTAssertNil(ARSharedMissionFrameCalibrator.ground(observation: OpticalObservation(
            payload: Data("PHROVER-CAL|1|OTHER".utf8), frameID: 3,
            monotonicTimestamp: 1, corners: corners
        ), in: snapshot, expectedMarkerID: "SILENT_SEARCH_01"))
        XCTAssertNil(ARSharedMissionFrameCalibrator.ground(observation: OpticalObservation(
            payload: Data("PHROVER-CAL|1|SILENT_SEARCH_01".utf8), frameID: 3,
            monotonicTimestamp: 1, corners: corners
        ), in: snapshot, expectedMarkerID: "SILENT_SEARCH_01"))
    }

    private func makeSnapshot(generation: UInt64, sequence: UInt64,
                              missingTopLeftDepth: Bool = false) -> ARFrameSnapshot {
        let image = makeImage()
        var depth: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 10, 10, kCVPixelFormatType_DepthFloat32, nil, &depth)
        CVPixelBufferLockBaseAddress(depth!, [])
        let stride = CVPixelBufferGetBytesPerRow(depth!) / MemoryLayout<Float>.size
        let values = CVPixelBufferGetBaseAddress(depth!)!.assumingMemoryBound(to: Float.self)
        for y in 0..<10 {
            for x in 0..<10 { values[y * stride + x] = y < 5 ? 2 : 2.2 }
        }
        if missingTopLeftDepth { values[4 * stride + 4] = 0 }
        CVPixelBufferUnlockBaseAddress(depth!, [])
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(200, 0, 0), SIMD3<Float>(0, 200, 0), SIMD3<Float>(50, 50, 1)
        ))
        return ARFrameSnapshot(id: ARFrameID(generation: generation, sequence: sequence), timestamp: 4.5,
            image: image, cameraTransform: matrix_identity_float4x4, cameraIntrinsics: intrinsics,
            imageResolution: CGSize(width: 100, height: 100), depthMap: depth!,
            pose: Pose2D(position: Vec2(0, 0), yaw: 0), trackingQuality: .normal)
    }

    private func makeImage() -> CVPixelBuffer {
        var image: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &image)
        return image!
    }

    private func taskTurn() async {
        await Task.yield()
        await Task.yield()
    }

    private func eventually(_ condition: @escaping () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
    }
}

private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
