import XCTest
import ImageIO
import CoreML
import CoreVideo
import RoverNav
import simd
@testable import PhroverKit

final class DetectorTests: XCTestCase {
    @MainActor
    func testPreviewAlreadyDispatchedButNotStartedYieldsToNewFollowConsumer() async {
        let queue = DispatchQueue(label: "test.follow.preview-dispatch")
        queue.suspend()
        let calls = FollowInferenceCallCounter()
        let detector = calls.makeDetector(inferenceQueue: queue)
        let snapshot = ARFrameSnapshot(id: .init(generation: 1, sequence: 1), timestamp: 100,
            image: makeImage(), cameraTransform: matrix_identity_float4x4, cameraIntrinsics: matrix_identity_float3x3,
            imageResolution: CGSize(width: 8, height: 6), depthMap: nil, pose: .init(position: .zero, yaw: 0), trackingQuality: .normal)
        let preview = Task { await detector.followPreviewEvaluationAsync(snapshot, at: 100) }
        for _ in 0..<30 { await Task.yield() }
        let ar = ARSessionManager()
        let stream = ARFollowMePerceptionSource(ar: ar, detector: detector).events()
        let consumer = Task { for await _ in stream {} }
        queue.resume()
        let result = await preview.value
        XCTAssertNil(result)
        XCTAssertEqual(calls.value, 0, "Dispatching a preview closure is not starting native inference")
        consumer.cancel(); await consumer.value
    }

    @MainActor
    func testActiveFollowConsumersKeepPreviewCacheMissesOffTheInferenceQueue() async {
        let calls = FollowInferenceCallCounter()
        let detector = calls.makeDetector()
        let ar = ARSessionManager()
        let source = ARFollowMePerceptionSource(ar: ar, detector: detector)
        let firstStream = source.events()
        let secondStream = source.events()
        let first = Task { for await _ in firstStream {} }
        let second = Task { for await _ in secondStream {} }
        for _ in 0..<20 { await Task.yield() }
        let snapshot = ARFrameSnapshot(id: .init(generation: 1, sequence: 1), timestamp: 100,
            image: makeImage(), cameraTransform: matrix_identity_float4x4, cameraIntrinsics: matrix_identity_float3x3,
            imageResolution: CGSize(width: 8, height: 6), depthMap: nil, pose: .init(position: .zero, yaw: 0), trackingQuality: .normal)
        let unavailable = await detector.followPreviewEvaluationAsync(snapshot, at: 100)
        XCTAssertNil(unavailable, "A preview cache miss cannot compete with an active follow consumer")
        XCTAssertEqual(calls.value, 0)
        let control = await detector.evaluateForFollowAsync(snapshot)
        XCTAssertEqual(control?.frame.frameID, snapshot.id)
        let cached = await detector.followPreviewEvaluationAsync(snapshot, at: 100.1)
        XCTAssertEqual(cached?.snapshot.id, snapshot.id)
        XCTAssertEqual(calls.value, 1, "Active control still infers; preview only reuses its exact fresh result")
        first.cancel(); await first.value
        let stillUnavailable = await detector.followPreviewEvaluationAsync(snapshot, at: 101)
        XCTAssertNil(stillUnavailable)
        XCTAssertEqual(calls.value, 1, "Ending one consumer must not release another's priority")
        second.cancel(); await second.value
        let preview = await detector.followPreviewEvaluationAsync(snapshot, at: 102)
        XCTAssertNotNil(preview)
        XCTAssertEqual(calls.value, 2, "Preview inference resumes after the last follow stream terminates")
    }

    @MainActor
    func testGenericImagePointProjectionDoesNotDependOnLocalInferenceCache() throws {
        let ar = ARSessionManager()
        var depth: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, kCVPixelFormatType_DepthFloat32, nil, &depth)
        let map = try XCTUnwrap(depth)
        CVPixelBufferLockBaseAddress(map, [])
        let values = CVPixelBufferGetBaseAddress(map)!.assumingMemoryBound(to: Float.self)
        for row in 0..<6 { for col in 0..<8 { values[row * CVPixelBufferGetBytesPerRow(map) / 4 + col] = 2 } }
        CVPixelBufferUnlockBaseAddress(map, [])
        ar.ingestForTesting(image: makeImage(), timestamp: ProcessInfo.processInfo.systemUptime,
            cameraTransform: matrix_identity_float4x4, intrinsics: matrix_identity_float3x3,
            imageResolution: CGSize(width: 8, height: 6), depthMap: map, trackingQuality: .normal)
        let perception = ARPerceptionSource(ar: ar, detector: nil)
        XCTAssertTrue(perception.detectObjects().isEmpty)
        XCTAssertNotNil(perception.unproject(normalizedPoint: CGPoint(x: 0.5, y: 0.5)),
            "Generic normalized image-point projection must not require a local object detector receipt")
    }
    @MainActor
    func testSlowInferenceDoesNotBlockControlAndOnlyNewestQueuedFrameSurvives() async {
        let entered = expectation(description: "inference held off actor")
        let gate = DispatchSemaphore(value: 0)
        let detector = Detector(supportedLabels: ["person"], detectionHandler: { _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return []
        })
        entered.expectedFulfillmentCount = 1
        entered.assertForOverFulfill = false
        func snapshot(_ sequence: UInt64) -> ARFrameSnapshot {
            .init(id: .init(generation: 1, sequence: sequence), timestamp: Double(sequence),
                image: makeImage(), cameraTransform: matrix_identity_float4x4, cameraIntrinsics: matrix_identity_float3x3,
                imageResolution: CGSize(width: 8, height: 6), depthMap: nil,
                pose: .init(position: .zero, yaw: 0), trackingQuality: .normal)
        }
        let first = Task { await detector.evaluateForFollowAsync(snapshot(1)) }
        await fulfillment(of: [entered], timeout: 1)
        // These actor operations must remain runnable while native inference is held.
        XCTAssertNil(detector.latestFollowEvaluation)
        let second = Task { await detector.evaluateForFollowAsync(snapshot(2)) }
        for _ in 0..<20 { await Task.yield() }
        let third = Task { await detector.evaluateForFollowAsync(snapshot(3)) }
        for _ in 0..<20 { await Task.yield() }
        first.cancel()
        gate.signal(); gate.signal()
        let a = await first.value
        let b = await second.value
        let c = await third.value
        XCTAssertNil(a, "Cancelled inference cannot be handed to the control loop")
        XCTAssertNil(b, "Superseded queued work is dropped rather than building a frame backlog")
        XCTAssertEqual(c?.frame.frameID.sequence, 3)
    }

    @MainActor
    func testMissionPerceptionDoesNotWaitForBusyPreviewInferenceLock() async {
        let entered = expectation(description: "preview busy")
        let gate = DispatchSemaphore(value: 0)
        let detector = Detector(supportedLabels: ["chair"], detectionHandler: { _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 0.5)
            return []
        })
        entered.assertForOverFulfill = false
        let ar = ARSessionManager()
        ar.ingestForTesting(image: makeImage(), timestamp: ProcessInfo.processInfo.systemUptime,
            cameraTransform: matrix_identity_float4x4, intrinsics: matrix_identity_float3x3,
            imageResolution: CGSize(width: 8, height: 6), depthMap: nil, trackingQuality: .normal)
        let preview = Task { await detector.evaluateForFollowAsync(ar.latestSnapshot!) }
        await fulfillment(of: [entered], timeout: 1)
        let perception = ARPerceptionSource(ar: ar, detector: detector)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(perception.detectObjects().isEmpty)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.1,
            "Synchronous mission reads must use cached facts, never join inference")
        gate.signal()
        _ = await preview.value
    }
    @MainActor
    func testFollowInferenceRunsAwayFromMainThreadAndKeepsSnapshotIdentity() async throws {
        let detector = Detector(supportedLabels: ["person"], detectionHandler: { _ in
            XCTAssertFalse(Thread.isMainThread, "Inference must not occupy the control/UI actor")
            return []
        })
        let snapshot = ARFrameSnapshot(id: .init(generation: 1, sequence: 7), timestamp: 100,
            image: makeImage(), cameraTransform: matrix_identity_float4x4, cameraIntrinsics: matrix_identity_float3x3,
            imageResolution: CGSize(width: 8, height: 6), depthMap: nil,
            pose: .init(position: .zero, yaw: 0), trackingQuality: .normal)
        let result = await detector.evaluateForFollowAsync(snapshot)
        XCTAssertEqual(result?.frame.frameID, snapshot.id)
        XCTAssertEqual(result?.frame.monotonicTimestamp, 100)
    }
    func testNativeBodyRequestDoesNotVerifyUniformEmptyImage() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nil, &buffer)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        let detector = Detector(supportedLabels: ["person"], detectionHandler: { _ in
            [.init(label: "person", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))]
        }, bodyPoseHandler: Detector.humanBodies)
        let snapshot = ARFrameSnapshot(id: .init(generation: 1, sequence: 1), timestamp: 100, image: image,
            cameraTransform: matrix_identity_float4x4, cameraIntrinsics: matrix_identity_float3x3,
            imageResolution: CGSize(width: 640, height: 480), depthMap: nil,
            pose: .init(position: .zero, yaw: 0), trackingQuality: .normal)
        let receipt = detector.evaluateForFollow(snapshot)
        XCTAssertEqual(receipt.frame.detections.first?.confidence, 1, "Raw prediction remains visible for diagnosis")
        let decision = try XCTUnwrap(receipt.personVerification?.first)
        XCTAssertFalse(decision.accepted)
        XCTAssertTrue(["body_verification_failed", "no_matching_body"].contains(decision.reason),
            "Native unavailability or no body must both fail closed, never trust the raw score")
    }
    func testPreviewReusesExactFreshFollowImageAndReceiptWithoutFallbackOrDuplicateInference() {
        var orientations: [CGImagePropertyOrientation] = []
        let detector = Detector(supportedLabels: ["person"], visionHandler: { _, orientation in
            orientations.append(orientation)
            return [.init(label: "person", confidence: 1, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))]
        })
        func snapshot(_ sequence: UInt64, _ time: Double, generation: UInt64 = 1) -> ARFrameSnapshot {
            .init(id: .init(generation: generation, sequence: sequence), timestamp: time, image: makeImage(),
                cameraTransform: matrix_identity_float4x4, cameraIntrinsics: matrix_identity_float3x3,
                imageResolution: CGSize(width: 8, height: 6), depthMap: nil, pose: .init(position: .zero, yaw: 0), trackingQuality: .normal)
        }
        let original = snapshot(1, 100)
        _ = detector.evaluateForFollow(original)
        let newer = snapshot(2, 100.1)
        let preview = detector.followPreviewEvaluation(newer, at: 100.2)
        XCTAssertEqual(orientations, [.right])
        XCTAssertEqual(preview.snapshot.id, original.id)
        XCTAssertEqual(preview.receipt.frame.frameID, original.id)
        XCTAssertTrue(preview.snapshot.image === original.image)
        XCTAssertFalse(preview.receipt.personVerification?.first?.accepted ?? true)
        let refreshed = detector.followPreviewEvaluation(newer, at: 100.6)
        XCTAssertEqual(orientations, [.right, .right])
        XCTAssertEqual(refreshed.snapshot.id, newer.id)
        let reset = snapshot(1, 100.61, generation: 2)
        let generationChanged = detector.followPreviewEvaluation(reset, at: 100.62)
        XCTAssertEqual(generationChanged.snapshot.id, reset.id)
        XCTAssertEqual(orientations, [.right, .right, .right])
    }
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
