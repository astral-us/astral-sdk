import ARKit
import CoreVideo
import RoverNav
import XCTest
@testable import PhroverKit

@MainActor
final class ARSessionManagerTests: XCTestCase {
    func testIngressHighWaterRetainsPendingTimestampEvenWhenNewestSnapshotRegresses() {
        let manager = ARSessionManager()
        manager.resetForTesting()
        let events = manager.snapshots() // Leave the consumer suspended; pending frames still count.
        for time in [100.0, 100.2, 100.1] {
            manager.ingestForTesting(image: makeImage(), timestamp: time, cameraTransform: matrix_identity_float4x4,
                intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 8, height: 6),
                depthMap: nil, trackingQuality: .normal)
        }
        XCTAssertEqual(manager.latestSnapshot?.timestamp, 100.1)
        XCTAssertEqual(manager.sourceHighWater?.frameID, .init(generation: 1, sequence: 3))
        XCTAssertEqual(manager.sourceHighWater?.sourceTimestamp, 100.2)
        manager.resetForTesting()
        XCTAssertNil(manager.sourceHighWater)
        withExtendedLifetime(events) {}
    }
    func testSnapshotIngestionRetainsSelectedDepthConfidencePairAndClearsItOnNextFrame() async throws {
        let manager = ARSessionManager()
        var iterator = manager.snapshots().makeAsyncIterator()
        let depth = makeDepth(2)
        var map: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, kCVPixelFormatType_OneComponent8, nil, &map)
        let confidence = try XCTUnwrap(map)
        manager.ingestForTesting(image: makeImage(), timestamp: 10, cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 8, height: 6),
            depthMap: depth, trackingQuality: .normal, depthConfidenceMap: confidence, depthSource: .smoothedSceneDepth)
        let selectedValue = await iterator.next()
        let selected = try XCTUnwrap(selectedValue)
        XCTAssertTrue(selected.depthMap === depth)
        XCTAssertTrue(selected.depthConfidenceMap === confidence)
        XCTAssertEqual(selected.depthSource, .smoothedSceneDepth)
        manager.ingestForTesting(image: makeImage(), timestamp: 11, cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 8, height: 6),
            depthMap: nil, trackingQuality: .normal)
        let nextValue = await iterator.next()
        let next = try XCTUnwrap(nextValue)
        XCTAssertNil(next.depthConfidenceMap)
        XCTAssertNil(next.depthSource)
        XCTAssertTrue(selected.depthConfidenceMap === confidence, "Retained frame cannot pick up later data")
    }

    func testSnapshotUptimeAndResetGenerationFenceRealFollowController() async {
        let manager = ARSessionManager()
        manager.resetForTesting()
        manager.ingestForTesting(image: makeImage(), timestamp: 100, cameraTransform: transform(x: 1, z: 2),
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 8, height: 6),
            depthMap: nil, trackingQuality: .normal)
        let gate = FollowDiagnosticSuspension()
        let ackEntered = expectation(description: "Follow controller enters ACK getter")
        let completed = expectation(description: "Follow controller returns after AR reset")
        var observedResult: NavigationResult?
        var uptime = 100.5
        var ackSuspended = false
        var commands = 0
        weak var sourceReceiver: NavigationController?
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { 2 },
            plan: { _, goal in [goal] }, lastAckAt: {
                if uptime >= 100.801, !ackSuspended {
                    ackSuspended = true
                    ackEntered.fulfill()
                    await gate.suspend()
                }
                return Date(timeIntervalSince1970: uptime)
            },
            sendCommand: { _ in commands += 1 }, stopRover: {}, sleep: { duration in
                // Model a camera capture after ACK + 300 ms, never inside stopRover.
                if uptime == 100.5 {
                    uptime = 100.801
                    manager.ingestForTesting(image: self.makeImage(), timestamp: uptime,
                        cameraTransform: self.transform(x: 1, z: 2), intrinsics: matrix_identity_float3x3,
                        imageResolution: CGSize(width: 8, height: 6), depthMap: nil, trackingQuality: .normal)
                    sourceReceiver?.ingestFollowTurnSource(.init(snapshot: manager.latestSnapshot!))
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: duration)
                }
            }, now: { Date(timeIntervalSince1970: uptime) },
            poseSample: { manager.latestSnapshot.map(NavigationPoseSample.init(snapshot:)) }, sourceNow: { uptime },
            sourceEvents: {
                let snapshots = manager.snapshots()
                return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                    let task = Task { @MainActor in
                        for await snapshot in snapshots { continuation.yield(.init(snapshot: snapshot)) }
                        continuation.finish()
                    }
                    continuation.onTermination = { @Sendable _ in task.cancel() }
                }
            }, sourceStopSnapshot: { manager.latestSnapshot.map(NavigationPoseSample.init(snapshot:)) },
            sourceHighWater: { manager.sourceHighWater },
            sourceHealth: { .init(generation: manager.sessionGeneration, trackingQuality: manager.trackingQuality) })
        sourceReceiver = controller
        let scan = Task {
            observedResult = await NavigationFollowMeMotion(navigation: controller).rotateForScan(by: 0.3)
            completed.fulfill()
        }
        await fulfillment(of: [ackEntered], timeout: 1)
        XCTAssertEqual(manager.latestSnapshot?.id, ARFrameID(generation: 1, sequence: 2))
        XCTAssertEqual(manager.latestSnapshot?.timestamp, uptime)
        XCTAssertEqual(commands, 0, "Reset is exercised while stopped, before any nonzero send")
        manager.resetForTesting()
        XCTAssertNil(manager.latestSnapshot)
        manager.ingestForTesting(image: makeImage(), timestamp: uptime, cameraTransform: transform(x: 1, z: 2),
            intrinsics: matrix_identity_float3x3, imageResolution: CGSize(width: 8, height: 6),
            depthMap: nil, trackingQuality: .normal)
        gate.release()
        await fulfillment(of: [completed], timeout: 1)
        scan.cancel()
        XCTAssertEqual(observedResult, .failed(.trackingLost), "A fresh reset snapshot cannot join the old AR operation")
        XCTAssertEqual(commands, 0)
        XCTAssertEqual(manager.latestSnapshot?.id, ARFrameID(generation: 2, sequence: 1))
        XCTAssertEqual(manager.latestSnapshot?.timestamp, uptime)
    }

    func testWithheldPostStopARSourceCancellationReturnsToCaller() async {
        let manager = ARSessionManager()
        manager.resetForTesting()
        manager.ingestForTesting(image: makeImage(), timestamp: ProcessInfo.processInfo.systemUptime,
            cameraTransform: transform(x: 1, z: 2), intrinsics: matrix_identity_float3x3,
            imageResolution: CGSize(width: 8, height: 6), depthMap: nil, trackingQuality: .normal)
        let events = AsyncStream<NavigationPoseSample>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { events.continuation.finish() }
        let waiting = expectation(description: "Controller waits with post-stop camera events withheld")
        let completed = expectation(description: "Cancellation drains the stopped source wait")
        var enteredWait = false
        var commands = 0
        var result: NavigationResult?
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { 2 },
            plan: { _, goal in [goal] }, lastAckAt: { Date() }, sendCommand: { _ in commands += 1 },
            stopRover: {}, sleep: { duration in
                if !enteredWait { enteredWait = true; waiting.fulfill() }
                try? await Task.sleep(for: duration)
            }, poseSample: { manager.latestSnapshot.map(NavigationPoseSample.init(snapshot:)) },
            sourceEvents: { events.stream },
            sourceStopSnapshot: { manager.latestSnapshot.map(NavigationPoseSample.init(snapshot:)) },
            sourceHighWater: { manager.sourceHighWater },
            sourceHealth: { .init(generation: manager.sessionGeneration, trackingQuality: manager.trackingQuality) })
        let scan = Task {
            result = await NavigationFollowMeMotion(navigation: controller).rotateForScan(by: 0.3)
            completed.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 1)
        scan.cancel()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(commands, 0)
    }

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
