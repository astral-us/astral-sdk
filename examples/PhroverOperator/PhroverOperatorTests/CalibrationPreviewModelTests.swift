import CoreVideo
import PhroverKit
import RoverNav
import simd
import UIKit
import XCTest
@testable import PhroverOperator

@MainActor
final class CalibrationPreviewModelTests: XCTestCase {
    func testPreviewRendersFirstAndNewestEligibleFrame() async throws {
        let frames = AsyncStream.makeStream(of: ARFrameSnapshot.self)
        let firstImage = UIImage()
        let secondImage = UIImage()
        var renderedSequences: [UInt64] = []
        let model = CalibrationPreviewModel(frames: { frames.stream }) { snapshot in
            renderedSequences.append(snapshot.id.sequence)
            return snapshot.id.sequence == 1 ? firstImage : secondImage
        }

        model.start()
        frames.continuation.yield(try snapshot(sequence: 1, timestamp: 10))
        frames.continuation.yield(try snapshot(sequence: 2, timestamp: 10.099))
        frames.continuation.yield(try snapshot(sequence: 3, timestamp: 10.101))
        await waitUntil { model.image === secondImage }

        XCTAssertEqual(renderedSequences, [1, 3])
        XCTAssertTrue(model.image === secondImage)
    }

    func testStopCancelsConsumptionAndReleasesImage() async throws {
        let frames = AsyncStream.makeStream(of: ARFrameSnapshot.self)
        var renderCount = 0
        let model = CalibrationPreviewModel(frames: { frames.stream }) { _ in
            renderCount += 1
            return UIImage()
        }
        model.start()
        frames.continuation.yield(try snapshot(sequence: 1, timestamp: 1))
        await waitUntil { model.image != nil }

        model.stop()
        frames.continuation.yield(try snapshot(sequence: 2, timestamp: 2))
        await Task.yield()

        XCTAssertNil(model.image)
        XCTAssertEqual(renderCount, 1)
    }

    func testRepeatedStartAndStopDoesNotCreateDuplicateConsumers() async throws {
        var frames = AsyncStream.makeStream(of: ARFrameSnapshot.self)
        var renderCount = 0
        let model = CalibrationPreviewModel(frames: { frames.stream }) { _ in
            renderCount += 1
            return UIImage()
        }

        model.start()
        model.start()
        frames.continuation.yield(try snapshot(sequence: 1, timestamp: 1))
        await waitUntil { renderCount == 1 }
        model.stop()
        frames = AsyncStream.makeStream(of: ARFrameSnapshot.self)
        model.start()
        frames.continuation.yield(try snapshot(sequence: 2, timestamp: 2))
        await waitUntil { renderCount == 2 }

        XCTAssertEqual(renderCount, 2)
    }

    func testTransformAspectFitsPortraitImageAndConvertsScannerCoordinates() {
        let transform = CalibrationPreviewTransform(
            imageSize: CGSize(width: 300, height: 600),
            previewBounds: CGRect(x: 0, y: 0, width: 400, height: 400)
        )

        XCTAssertEqual(transform.imageRect, CGRect(x: 100, y: 0, width: 200, height: 400))
        assertPoint(transform.point(for: Vec2(0, 1)), x: 100, y: 0)
        assertPoint(transform.point(for: Vec2(1, 1)), x: 300, y: 0)
        assertPoint(transform.point(for: Vec2(0, 0)), x: 100, y: 400)
        assertPoint(transform.point(for: Vec2(1, 0)), x: 300, y: 400)
    }

    func testTransformClampsOutOfRangeCoordinates() {
        let transform = CalibrationPreviewTransform(
            imageSize: CGSize(width: 200, height: 100),
            previewBounds: CGRect(x: 10, y: 20, width: 100, height: 100)
        )

        XCTAssertEqual(transform.imageRect, CGRect(x: 10, y: 45, width: 100, height: 50))
        assertPoint(transform.point(for: Vec2(-2, 4)), x: 10, y: 45)
        assertPoint(transform.point(for: Vec2(3, -1)), x: 110, y: 95)
    }

    func testProjectionMapsLatchedStagesAndGuidance() {
        var state = SilentSearchCalibrationVisualState()
        XCTAssertEqual(CalibrationViewProjection(state: state).stages, [.pending, .waiting, .waiting])
        XCTAssertEqual(
            CalibrationViewProjection(state: state).guidance,
            "Center the complete marker with its white border visible."
        )

        state.qrDecoded = true
        state.currentMarkerID = "SILENT_SEARCH_01"
        state.currentCorners = markerCorners
        XCTAssertEqual(CalibrationViewProjection(state: state).stages, [.succeeded, .pending, .waiting])
        XCTAssertEqual(CalibrationViewProjection(state: state).markerText, "Marker SILENT_SEARCH_01")

        state.currentCorners = nil
        state.currentMarkerID = nil
        XCTAssertEqual(CalibrationViewProjection(state: state).stages, [.succeeded, .pending, .waiting])
        XCTAssertEqual(CalibrationViewProjection(state: state).markerText, "Marker SILENT_SEARCH_01")

        state.cornersGrounded = true
        XCTAssertEqual(CalibrationViewProjection(state: state).stages, [.succeeded, .succeeded, .pending])
        XCTAssertEqual(CalibrationViewProjection(state: state).guidance, "Hold steady while samples are collected.")

        state.sampleAccepted = true
        XCTAssertEqual(CalibrationViewProjection(state: state).stages, [.succeeded, .succeeded, .succeeded])
    }

    func testProjectionUsesExactIssueGuidancePrecedence() {
        var state = SilentSearchCalibrationVisualState()
        state.qrDecoded = true

        state.currentIssue = .groundingFailure(.cornerUnavailable(.topLeft))
        XCTAssertEqual(
            CalibrationViewProjection(state: state).guidance,
            "Move the marker toward center or adjust the camera angle."
        )
        state.currentIssue = .groundingFailure(.wrongMarkerID)
        XCTAssertEqual(CalibrationViewProjection(state: state).guidance, "Show marker SILENT_SEARCH_01.")
        state.currentIssue = .scannerFailure
        XCTAssertEqual(CalibrationViewProjection(state: state).guidance, "QR scanner unavailable. Reframe and try again.")
        state.currentIssue = .groundingFailure(.trackingNotNormal)
        XCTAssertEqual(CalibrationViewProjection(state: state).guidance, "Restore normal AR tracking before calibrating.")
    }

    private var markerCorners: OrientedMarkerCorners {
        OrientedMarkerCorners(
            topLeft: Vec2(0.2, 0.8), topRight: Vec2(0.8, 0.8),
            bottomLeft: Vec2(0.2, 0.2), bottomRight: Vec2(0.8, 0.2)
        )
    }

    private func snapshot(sequence: UInt64, timestamp: TimeInterval) throws -> ARFrameSnapshot {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(nil, 1, 1, kCVPixelFormatType_32BGRA, nil, &buffer),
            kCVReturnSuccess
        )
        return ARFrameSnapshot(
            id: ARFrameID(generation: 1, sequence: sequence), timestamp: timestamp,
            image: try XCTUnwrap(buffer), cameraTransform: matrix_identity_float4x4,
            cameraIntrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 1, height: 1),
            depthMap: nil, pose: Pose2D(position: .zero, yaw: 0), trackingQuality: .normal
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
    }

    private func assertPoint(
        _ point: CGPoint, x: CGFloat, y: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(point.x, x, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(point.y, y, accuracy: 0.000_001, file: file, line: line)
    }
}
