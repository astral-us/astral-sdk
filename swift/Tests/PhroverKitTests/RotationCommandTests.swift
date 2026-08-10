import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class RotationCommandTests: XCTestCase {
    func testCancellingScanAwaitCancelsIndependentRotationAndAwaitsStop() async {
        let rotationCancelled = expectation(description: "independent rotation cancelled")
        let stopCompleted = expectation(description: "transport stop completed")
        let rotation = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch is CancellationError {
                rotationCancelled.fulfill()
            } catch {
                XCTFail("Unexpected scan task error: \(error)")
            }
        }
        let scanAwait = Task { @MainActor in
            await NavigationController.awaitScanRotationTask(rotation) {
                stopCompleted.fulfill()
            }
        }

        await Task.yield()
        scanAwait.cancel()

        await fulfillment(of: [rotationCancelled, stopCompleted], timeout: 1)
        _ = await scanAwait.value
    }

    func testCancellingScanRunsSuspendingTransportStopInFreshTask() async {
        let rotationCancelled = expectation(description: "independent rotation cancelled")
        let stopCompleted = expectation(description: "suspending transport stop completed")
        let rotation = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                rotationCancelled.fulfill()
            } catch {
                XCTFail("Unexpected scan task error: \(error)")
            }
        }
        let scanAwait = Task { @MainActor in
            _ = await NavigationController.awaitScanRotationTask(
                rotation,
                isCurrentOperation: { true }
            ) {
                XCTAssertFalse(Task.isCancelled)
                do {
                    try await Task.sleep(for: .milliseconds(20))
                    stopCompleted.fulfill()
                } catch {
                    XCTFail("Transport stop inherited caller cancellation: \(error)")
                }
            }
        }

        await Task.yield()
        scanAwait.cancel()

        await fulfillment(of: [rotationCancelled, stopCompleted], timeout: 1)
        await scanAwait.value
    }

    func testStaleScanCompletionDoesNotStopOrIdleReplacementOperation() async {
        let rotationCancelled = expectation(description: "stale rotation cancelled")
        let replacementStarted = expectation(description: "replacement operation started")
        var activeOperation = 1
        var state = NavigationController.State.driving
        var stopCallCount = 0
        let rotation = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                rotationCancelled.fulfill()
                try? await Task.sleep(for: .milliseconds(30))
            } catch {
                XCTFail("Unexpected scan task error: \(error)")
            }
        }
        let scanAwait = Task { @MainActor in
            let stillOwnsOperation = await NavigationController.awaitScanRotationTask(
                rotation,
                isCurrentOperation: { activeOperation == 1 }
            ) {
                stopCallCount += 1
            }
            if Task.isCancelled, stillOwnsOperation {
                state = .idle
            }
        }

        await Task.yield()
        scanAwait.cancel()
        activeOperation = 2
        state = .driving
        replacementStarted.fulfill()

        await fulfillment(of: [rotationCancelled, replacementStarted], timeout: 1)
        await scanAwait.value

        XCTAssertEqual(stopCallCount, 0)
        XCTAssertEqual(state, .driving)
    }

    func testScanFailureWithoutTrackedPoseAwaitsTransportStop() async {
        TestURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let navigation = NavigationController(
            ar: ARSessionManager(),
            control: RoverControl(host: "rover.test", session: URLSession(configuration: configuration)),
            trackingRecoveryTimeout: 0
        )

        await navigation.rotateForScan(by: .pi / 6)

        XCTAssertEqual(TestURLProtocol.requestCount, 2)
        XCTAssertEqual(
            navigation.state,
            .failed("AR tracking is not ready — keep the phone still and try again.")
        )
    }

    func testLeftRotationUsesMinimumPhysicalTurnSpeed() {
        let command = RotationCommand.command(forYawError: .pi / 2)

        XCTAssertEqual(command.left, -RoverConfig.minimumRotateWheelSpeed, accuracy: 1e-9)
        XCTAssertEqual(command.right, RoverConfig.minimumRotateWheelSpeed, accuracy: 1e-9)
    }

    func testRightRotationUsesMinimumPhysicalTurnSpeed() {
        let command = RotationCommand.command(forYawError: -.pi / 2)

        XCTAssertEqual(command.left, RoverConfig.minimumRotateWheelSpeed, accuracy: 1e-9)
        XCTAssertEqual(command.right, -RoverConfig.minimumRotateWheelSpeed, accuracy: 1e-9)
    }

    func testBlindLeftScanUsesForwardDepthVisibleArc() {
        let command = RotationCommand.depthVisibleArc(forYawError: .pi / 6)

        XCTAssertGreaterThanOrEqual(command.left, 0)
        XCTAssertGreaterThan(command.right, command.left)
        XCTAssertEqual(command.right, RoverConfig.minimumRotateWheelSpeed, accuracy: 1e-9)
        XCTAssertEqual(DepthSafetyMotionClass.classify(command), .curved)
    }

    func testBlindRightScanUsesForwardDepthVisibleArc() {
        let command = RotationCommand.depthVisibleArc(forYawError: -.pi / 6)

        XCTAssertGreaterThan(command.left, command.right)
        XCTAssertGreaterThanOrEqual(command.right, 0)
        XCTAssertEqual(command.left, RoverConfig.minimumRotateWheelSpeed, accuracy: 1e-9)
        XCTAssertEqual(DepthSafetyMotionClass.classify(command), .curved)
    }

    func testScanCompletionUsesZeroBasedRelativeRotation() {
        XCTAssertFalse(NavigationController.scanTurnReachedRelativeTarget(
            requestedAngle: .pi / 6,
            accumulatedAngle: 18 * .pi / 180,
            tolerance: RoverConfig.scanTurnYawTolerance
        ))
        XCTAssertTrue(NavigationController.scanTurnReachedRelativeTarget(
            requestedAngle: .pi / 6,
            accumulatedAngle: 24 * .pi / 180,
            tolerance: RoverConfig.scanTurnYawTolerance
        ))
        XCTAssertFalse(NavigationController.scanTurnReachedRelativeTarget(
            requestedAngle: .pi / 6,
            accumulatedAngle: -24 * .pi / 180,
            tolerance: RoverConfig.scanTurnYawTolerance
        ))
        XCTAssertTrue(NavigationController.scanTurnReachedRelativeTarget(
            requestedAngle: -.pi / 6,
            accumulatedAngle: -24 * .pi / 180,
            tolerance: RoverConfig.scanTurnYawTolerance
        ))
    }

    func testCorrectDirectionOvershootCompletesScan() {
        XCTAssertTrue(NavigationController.scanTurnReachedRelativeTarget(
            requestedAngle: .pi / 6,
            accumulatedAngle: 71 * .pi / 180,
            tolerance: RoverConfig.scanTurnYawTolerance
        ))
    }

    func testOppositeDirectionRotationIsRejectedWithoutReversal() {
        XCTAssertTrue(NavigationController.scanTurnMovedOppositeDirection(
            requestedAngle: .pi / 6,
            accumulatedAngle: -3 * .pi / 180
        ))
        XCTAssertFalse(NavigationController.scanTurnMovedOppositeDirection(
            requestedAngle: .pi / 6,
            accumulatedAngle: 3 * .pi / 180
        ))
    }

    func testScanPulseAlwaysUsesMinimumDuration() {
        XCTAssertEqual(
            NavigationController.scanPulseDuration(),
            RoverConfig.scanTurnPulseDuration,
            accuracy: 0.000_001
        )
        XCTAssertEqual(RoverConfig.scanTurnPulseDuration, 0.02, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(RoverConfig.scanTurnSettleDuration, 0.75)
    }

    func testFreshNormalARFrameIsReadyAfterRelativeHeadingPulse() {
        XCTAssertTrue(NavigationController.isScanFrameReady(
            baselineFrame: 10,
            currentFrame: 11,
            isTrackingNormal: true,
            hasPose: true
        ))
        XCTAssertFalse(NavigationController.isScanFrameReady(
            baselineFrame: 10,
            currentFrame: 10,
            isTrackingNormal: true,
            hasPose: true
        ))
        XCTAssertFalse(NavigationController.isScanFrameReady(
            baselineFrame: 10,
            currentFrame: 11,
            isTrackingNormal: false,
            hasPose: true
        ))
    }

    func testExpectedCommandedYawIsConsistentWithRelativeHeading() {
        let before = Pose2D(position: Vec2(1, 1), yaw: 0)
        let after = Pose2D(position: Vec2(1.02, 1.01), yaw: 70 * .pi / 180)

        XCTAssertTrue(NavigationController.isSettledScanPoseConsistent(
            from: before,
            to: after,
            accumulatedAngle: 70 * .pi / 180
        ))
    }

    func testTranslationJumpAndHeadingDisagreementAreInconsistent() {
        let start = Pose2D(position: .zero, yaw: 0)
        XCTAssertFalse(NavigationController.isSettledScanPoseConsistent(
            from: start,
            to: Pose2D(position: Vec2(0.11, 0), yaw: 30 * .pi / 180),
            accumulatedAngle: 30 * .pi / 180
        ))
        XCTAssertFalse(NavigationController.isSettledScanPoseConsistent(
            from: start,
            to: Pose2D(position: Vec2(0.01, 0), yaw: 55 * .pi / 180),
            accumulatedAngle: 30 * .pi / 180
        ))
    }

    func testScanPulseLimitStopsBeforeUnboundedRotation() {
        XCTAssertFalse(NavigationController.scanPulseLimitReached(
            RoverConfig.scanTurnMaxPulseCount - 1
        ))
        XCTAssertTrue(NavigationController.scanPulseLimitReached(
            RoverConfig.scanTurnMaxPulseCount
        ))
        XCTAssertGreaterThan(
            RoverConfig.blockedHeadingRecoveryTimeout,
            RoverConfig.maximumScanTurnDuration
        )
    }
}
