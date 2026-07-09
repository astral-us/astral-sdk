import XCTest
import CoreVideo
import simd
import RoverNav
@testable import PhroverKit

/// `ARCamera`/`ARDepthData` have no public initializers, so ARKit can never hand a test a
/// real one — these tests exercise the pure-math helpers `ARSessionManager` factors its
/// `unproject(normalizedPoint:)` through (`sensorPixel`/`sampleDepth`/`unprojectPoint`)
/// against synthetic intrinsics/transforms/depth instead. Runs on the iOS Simulator; the
/// one thing this can't cover is whether the `.right`-orientation assumption actually
/// matches a real device's camera buffer — see rover/README.md status notes.
@MainActor
final class UnprojectionTests: XCTestCase {
    func testSensorPixelHandlesCorners() {
        let imageSize = CGSize(width: 1920, height: 1440) // raw (landscape) sensor space

        let bottomLeft = ARSessionManager.sensorPixel(forVisionNormalizedPoint: .zero, imageSize: imageSize)
        XCTAssertEqual(bottomLeft.x, 1920, accuracy: 0.01)
        XCTAssertEqual(bottomLeft.y, 1440, accuracy: 0.01)

        let topRight = ARSessionManager.sensorPixel(forVisionNormalizedPoint: CGPoint(x: 1, y: 1), imageSize: imageSize)
        XCTAssertEqual(topRight.x, 0, accuracy: 0.01)
        XCTAssertEqual(topRight.y, 0, accuracy: 0.01)
    }

    func testSampleDepthReadsConstantValue() {
        let imageSize = CGSize(width: 100, height: 100)
        let depthMap = Self.makeDepthBuffer(width: 20, height: 20, constantDepth: 2.5)

        let depth = ARSessionManager.sampleDepth(depthMap, atVisionNormalizedPoint: CGPoint(x: 0.5, y: 0.5), imageSize: imageSize)

        XCTAssertEqual(depth, 2.5)
    }

    func testSampleDepthRejectsInvalidReadings() {
        let imageSize = CGSize(width: 100, height: 100)
        let depthMap = Self.makeDepthBuffer(width: 20, height: 20, constantDepth: 0)

        XCTAssertNil(ARSessionManager.sampleDepth(depthMap, atVisionNormalizedPoint: CGPoint(x: 0.5, y: 0.5), imageSize: imageSize))
    }

    func testForwardClearanceCatchesOffCenterObstacleInDrivingCorridor() {
        let depthMap = Self.makeDepthBuffer(width: 20, height: 20, constantDepth: 3.5)
        for y in 9...11 {
            for x in 12...14 {
                Self.setDepth(0.35, x: x, y: y, in: depthMap)
            }
        }

        let clearance = ARSessionManager.forwardClearance(fromDepthMap: depthMap)

        XCTAssertEqual(clearance, 0.35, accuracy: 0.001)
    }

    func testForwardClearanceIgnoresSingleNearOutlierInDrivingCorridor() {
        let depthMap = Self.makeDepthBuffer(width: 20, height: 20, constantDepth: 3.5)
        Self.setDepth(0.35, x: 10, y: 10, in: depthMap)

        let clearance = ARSessionManager.forwardClearance(fromDepthMap: depthMap)

        XCTAssertEqual(clearance, 3.5, accuracy: 0.001)
    }

    func testUnprojectPointAtIdentityTransform() {
        // fx = fy = 500, principal point (cx, cy) = (400, 300), raw sensor 600x800.
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(500, 0, 0),
            SIMD3<Float>(0, 500, 0),
            SIMD3<Float>(400, 300, 1)
        ))
        let identity = simd_float4x4(1) // camera at world origin, no rotation, looking down -Z
        let imageSize = CGSize(width: 600, height: 800)
        // The normalized point whose sensor-space position is exactly the principal point.
        let normalized = CGPoint(x: 1 - 300.0 / 800.0, y: 1 - 400.0 / 600.0)

        let goal = ARSessionManager.unprojectPoint(normalized, imageSize: imageSize,
                                                    intrinsics: intrinsics, cameraTransform: identity, depth: 3.0)

        // A ray through the principal point has no lateral offset: straight down -Z at
        // depth 3 from the origin flattens to nav-plane (world x, world z) = (0, -3).
        XCTAssertEqual(goal.x, 0, accuracy: 0.01)
        XCTAssertEqual(goal.y, -3, accuracy: 0.01)
    }

    func testUnprojectPointTranslatesWithCameraPose() {
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(500, 0, 0),
            SIMD3<Float>(0, 500, 0),
            SIMD3<Float>(400, 300, 1)
        ))
        var transform = simd_float4x4(1)
        transform.columns.3 = SIMD4<Float>(2, 0, 5, 1) // camera translated to world (2, _, 5)
        let imageSize = CGSize(width: 600, height: 800)
        let normalized = CGPoint(x: 1 - 300.0 / 800.0, y: 1 - 400.0 / 600.0)

        let goal = ARSessionManager.unprojectPoint(normalized, imageSize: imageSize,
                                                    intrinsics: intrinsics, cameraTransform: transform, depth: 3.0)

        // Same ray, but the camera itself is offset by (2, 0, 5): world = (2,0,5) + (0,0,-3).
        XCTAssertEqual(goal.x, 2, accuracy: 0.01)
        XCTAssertEqual(goal.y, 2, accuracy: 0.01)
    }

    // MARK: - Helpers

    private static func makeDepthBuffer(width: Int, height: Int, constantDepth: Float) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_DepthFloat32,
                            attrs as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer else { fatalError("failed to create synthetic depth buffer") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.size
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: Float32.self)
        for y in 0..<height {
            for x in 0..<width {
                base[y * stride + x] = constantDepth
            }
        }
        return buffer
    }

    private static func setDepth(_ depth: Float, x: Int, y: Int, in depthMap: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(depthMap, [])
        defer { CVPixelBufferUnlockBaseAddress(depthMap, []) }
        let stride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let base = CVPixelBufferGetBaseAddress(depthMap)!.assumingMemoryBound(to: Float32.self)
        base[y * stride + x] = depth
    }
}
