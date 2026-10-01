import Foundation
import RoverNav
import XCTest
@testable import PhroverKit

@MainActor
final class FollowMeCoordinatorTests: XCTestCase {
    private func setup() -> (FollowMeCoordinator, FollowPerceptionFake, FollowMotionFake, ManualFollowClock) {
        let perception = FollowPerceptionFake()
        let motion = FollowMotionFake()
        let clock = ManualFollowClock()
        return (FollowMeCoordinator(perception: perception, motion: motion, clock: clock,
                                    eventSink: { _, _ in }), perception, motion, clock)
    }

    private func frame(_ sequence: UInt64, at time: TimeInterval = 0, pose: Pose2D? = Pose2D(position: .zero, yaw: 0), depth: Bool = true, people: [FollowPersonObservation] = []) -> FollowPerceptionEvent {
        .frame(FollowFrameBatch(frameID: ARFrameID(generation: 1, sequence: sequence), timestamp: time, pose: pose, depthAvailable: depth, people: people))
    }

    private func person(_ sequence: UInt64, at time: TimeInterval = 0, x: Double = 0, y: Double = 4, screen: CGFloat = 0.5) -> FollowPersonObservation {
        FollowPersonObservation(frameID: ARFrameID(generation: 1, sequence: sequence), timestamp: time, confidence: 0.9, boundingBox: CGRect(x: screen - 0.05, y: 0.4, width: 0.1, height: 0.2), position: Vec2(x, y), pose: Pose2D(position: .zero, yaw: 0))
    }

    private func drain() async { for _ in 0..<30 { await Task.yield() } }

    func testReadinessFailsBeforeAnyMotion() async {
        for unavailable in 0..<2 {
            let (coordinator, perception, motion, _) = setup()
            if unavailable == 0 { perception.detectorReady = false } else { perception.personLabelAvailable = false }
            let started = await coordinator.start()
            XCTAssertFalse(started)
            XCTAssertTrue(motion.rotations.isEmpty)
            XCTAssertTrue(motion.goals.isEmpty)
        }
    }

    func testInitialAcquisitionNavigatesToStandOffGoal() async {
        let (coordinator, perception, motion, _) = setup()
        let started = await coordinator.start()
        XCTAssertTrue(started)
        perception.send(frame(1, people: [person(1)]))
        await drain()
        XCTAssertEqual(coordinator.state, .following)
        XCTAssertEqual(motion.goals, [Vec2(0, 2.5)])
    }

    func testMissingPoseOrDepthFailsBeforeMovement() async {
        for missingPose in [false, true] {
            let (coordinator, perception, motion, _) = setup()
            let started = await coordinator.start()
            XCTAssertTrue(started)
            perception.send(frame(1, pose: missingPose ? nil : Pose2D(position: .zero, yaw: 0), depth: missingPose))
            await drain()
            XCTAssertTrue(motion.goals.isEmpty)
            XCTAssertTrue(motion.rotations.isEmpty)
            XCTAssertEqual(coordinator.state, .searching)
        }
    }

    func testSearchStopsAfterTwelveThirtyDegreeRotations() async {
        let (coordinator, perception, motion, _) = setup()
        _ = await coordinator.start()
        perception.send(frame(1))
        await drain()
        for _ in 0..<20 where coordinator.isActive { await drain() }
        XCTAssertEqual(motion.rotations.count, 12)
        XCTAssertTrue(motion.rotations.allSatisfy { abs($0 - .pi / 6) < 0.0001 })
        XCTAssertEqual(coordinator.state, .failed("No person found."))
    }

    func testSearchEvaluatesFramesWhileRotationIsInFlight() async {
        let (coordinator, perception, motion, _) = setup()
        motion.suspendRotation = true
        _ = await coordinator.start()
        perception.send(frame(1))
        await drain()
        XCTAssertEqual(motion.rotations.count, 1)
        perception.send(frame(2, people: [person(2)]))
        await drain()
        XCTAssertEqual(motion.goals, [Vec2(0, 2.5)])
        XCTAssertEqual(motion.rotations.count, 1)
        motion.releaseRotation()
    }

    func testHoldBandAndTooCloseNeverNavigateBackward() async {
        for distance in [1.0, 1.25, 1.5, 1.75] {
            let (coordinator, perception, motion, _) = setup()
            _ = await coordinator.start()
            perception.send(frame(1, people: [person(1, y: distance)]))
            await drain()
            XCTAssertEqual(coordinator.state, .holdingDistance)
            XCTAssertTrue(motion.goals.isEmpty)
        }
    }

    func testGoalReplacementRequiresDisplacementAndThreeHertzAndStopsFirst() async {
        let (coordinator, perception, motion, clock) = setup()
        motion.suspendNavigation = true
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        perception.send(frame(2, people: [person(2, y: 4.5)]))
        await drain()
        XCTAssertEqual(motion.goals.count, 1)
        clock.advance(to: 0.334)
        perception.send(frame(3, at: 0.334, people: [person(3, at: 0.334, y: 4.1)]))
        await drain()
        XCTAssertEqual(motion.goals.count, 1)
        perception.send(frame(4, at: 0.334, people: [person(4, at: 0.334, y: 4.5)]))
        await drain()
        XCTAssertEqual(motion.goals, [Vec2(0, 2.5), Vec2(0, 3)])
        XCTAssertGreaterThanOrEqual(motion.stops, 2)
        motion.releaseNavigation()
    }

    func testLossStopsBeforeReacquisitionRotationAndRejectsCentralNewcomer() async {
        let (coordinator, perception, motion, clock) = setup()
        motion.suspendRotation = true
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        let stops = motion.stops
        perception.send(frame(2))
        await drain()
        XCTAssertEqual(coordinator.state, .reacquiring)
        XCTAssertGreaterThan(motion.stops, stops)
        XCTAssertEqual(motion.rotations.count, 1)
        clock.advance(to: 1)
        perception.send(frame(3, at: 1, people: [person(3, at: 1, x: 6, screen: 0.5)]))
        await drain()
        XCTAssertEqual(coordinator.state, .reacquiring)
        clock.advance(to: 9.999)
        perception.send(frame(4, at: 9.999, people: [person(4, at: 9.999, y: 4.2, screen: 0.8)]))
        await drain()
        XCTAssertEqual(coordinator.state, .following)
        motion.releaseRotation()
    }

    func testReacquisitionExpiresAtTenSeconds() async {
        let (coordinator, perception, motion, clock) = setup()
        motion.suspendRotation = true
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        perception.send(frame(2))
        await drain()
        clock.advance(to: 9.999)
        await drain()
        XCTAssertEqual(coordinator.state, .reacquiring)
        clock.advance(to: 10)
        perception.send(frame(3, at: 10, people: [person(3, at: 10)]))
        await drain()
        XCTAssertFalse(coordinator.isActive)
        XCTAssertTrue(motion.goals.count == 1)
        motion.releaseRotation()
    }

    func testPoseRecoveryEndsAtTwoSeconds() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        perception.send(frame(2, depth: false))
        await drain()
        clock.advance(to: 1.999)
        await drain()
        XCTAssertTrue(coordinator.isActive)
        clock.advance(to: 2)
        await drain()
        XCTAssertEqual(coordinator.state, .failed("Depth unavailable. Check LiDAR visibility and depth support."))
        XCTAssertGreaterThanOrEqual(motion.stops, 2)
    }

    func testFailedStopBlocksFurtherGoalsAndStarts() async {
        let (coordinator, perception, motion, _) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        motion.stopError = true
        perception.send(frame(2))
        await drain()
        XCTAssertEqual(coordinator.state, .failed("Rover stop could not be confirmed."))
        perception.send(frame(3, people: [person(3)]))
        let stopped = await coordinator.stop()
        XCTAssertFalse(stopped)
        let restarted = await coordinator.start()
        XCTAssertFalse(restarted)
        XCTAssertEqual(motion.goals.count, 1)
    }

    func testFailedStopCanBeRetriedWithoutRestartingFollow() async {
        let (coordinator, perception, motion, _) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        motion.stopError = true
        let first = await coordinator.stop()
        XCTAssertFalse(first)
        motion.stopError = false
        let retry = await coordinator.stop()
        XCTAssertTrue(retry)
        XCTAssertEqual(coordinator.state, .stopped)
        XCTAssertEqual(motion.goals.count, 1)
    }

    func testStopAndSafetyFailureInvalidateOldNavigationCompletions() async {
        for safety in [false, true] {
            let (coordinator, perception, motion, _) = setup()
            motion.suspendNavigation = true
            _ = await coordinator.start()
            perception.send(frame(1, people: [person(1)]))
            await drain()
            if safety { motion.safety(.failed(.obstacle)) }
            else { _ = await coordinator.stop() }
            await drain()
            motion.releaseNavigation()
            perception.send(frame(2, people: [person(2)]))
            await drain()
            XCTAssertFalse(coordinator.isActive)
            XCTAssertEqual(motion.goals.count, 1)
            XCTAssertGreaterThanOrEqual(motion.stops, 2)
        }
    }

    func testStopAcknowledgementGatesReplacementAndConcurrentFrames() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        motion.suspendStop = true
        clock.advance(to: 0.5)
        perception.send(frame(2, at: 0.5, people: [person(2, at: 0.5, y: 4.5)]))
        await drain()
        perception.send(frame(3, at: 0.5, people: [person(3, at: 0.5, y: 5)]))
        await drain()
        XCTAssertEqual(motion.stops, 2, "Only one stop may be outstanding")
        XCTAssertEqual(motion.goals.count, 1)
        motion.releaseStop()
        await drain()
        XCTAssertLessThanOrEqual(motion.goals.count, 2)
    }

    func testInterruptionStopsAndTeardownIsIdempotent() async {
        let (coordinator, perception, motion, _) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        perception.send(.interrupted)
        await drain()
        XCTAssertEqual(coordinator.state, .failed("AR session interrupted."))
        let stops = motion.stops
        let first = await coordinator.stop()
        let second = await coordinator.stop()
        XCTAssertTrue(first && second)
        XCTAssertEqual(motion.stops, stops)
        XCTAssertEqual(motion.goals.count, 1)
    }

    func testStopDuringSuspendedGoalReplacementPreventsStaleMotion() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        motion.suspendStop = true
        clock.advance(to: 0.5)
        perception.send(frame(2, at: 0.5, people: [person(2, at: 0.5, y: 4.5)]))
        await drain()
        let stopping = Task { await coordinator.stop() }
        await drain()
        XCTAssertEqual(motion.stops, 2, "Terminal stop waits for the outstanding acknowledgement")
        motion.releaseStop()
        await drain()
        motion.releaseStop()
        let stopped = await stopping.value
        XCTAssertTrue(stopped)
        XCTAssertEqual(coordinator.state, .stopped)
        XCTAssertEqual(motion.goals.count, 1)
    }

    func testInhibitingFollowImmediatelyPreventsNewGoalsBeforeStopCompletes() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        motion.suspendStop = true

        coordinator.inhibitMotion()
        XCTAssertFalse(coordinator.isActive)
        clock.advance(to: 1)
        perception.send(frame(2, at: 1, people: [person(2, at: 1, y: 6)]))
        await drain()
        XCTAssertEqual(motion.goals.count, 1)
        motion.releaseStop()
        let stopped = await coordinator.stop()
        XCTAssertTrue(stopped)
    }

    func testStalledCameraStreamStopsMotionBeforeDrivingOnStaleTarget() async {
        let (coordinator, perception, motion, clock) = setup()
        motion.suspendNavigation = true
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        XCTAssertEqual(motion.goals.count, 1)
        let stops = motion.stops

        clock.advance(to: 0.501)
        await drain()

        XCTAssertGreaterThan(motion.stops, stops)
        XCTAssertEqual(motion.goals.count, 1)
        motion.releaseNavigation()
    }

    func testDelayedMotorStopCannotLaunchGoalFromExpiredFrame() async {
        let (coordinator, perception, motion, clock) = setup()
        motion.suspendStop = true
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        XCTAssertTrue(motion.goals.isEmpty)
        clock.advance(to: 0.6)
        await drain()
        motion.releaseStop()
        await drain()
        XCTAssertTrue(motion.goals.isEmpty)
    }

    func testNoFirstCameraFrameFailsInsteadOfSearchingForever() async {
        let (coordinator, _, motion, clock) = setup()
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 1.999)
        await drain()
        XCTAssertEqual(coordinator.state, .searching)
        clock.advance(to: 2)
        await drain()
        XCTAssertEqual(coordinator.state, .failed("No camera frames received. Check the AR session and camera access."))
        XCTAssertGreaterThanOrEqual(motion.stops, 1)
    }

    func testMissingPoseAndExpiredFrameHaveDistinctActionableFailures() async {
        for missingPose in [true, false] {
            let (coordinator, perception, motion, clock) = setup()
            _ = await coordinator.start()
            perception.send(frame(1, at: missingPose ? 0 : -1,
                                  pose: missingPose ? nil : Pose2D(position: .zero, yaw: 0)))
            await drain()
            clock.advance(to: 2)
            await drain()
            XCTAssertEqual(coordinator.state, .failed(missingPose
                ? "Rover pose unavailable. Wait for AR tracking to recover."
                : "Camera frame stale or timestamp invalid. Check camera delivery and inference latency."))
            XCTAssertTrue(motion.goals.isEmpty)
            XCTAssertTrue(motion.rotations.isEmpty)
        }
    }

    func testRecoveryDeadlineUsesLatestPersistentTrackingIssueAndReason() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, depth: false))
        await drain()
        clock.advance(to: 1.5)
        perception.send(.frame(FollowFrameBatch(
            frameID: ARFrameID(generation: 1, sequence: 2), timestamp: 1.5,
            pose: nil, depthAvailable: true, people: [],
            trackingQuality: .limited, trackingReason: .initializing)))
        await drain()
        XCTAssertEqual(coordinator.perceptionIssue, .trackingLimited)
        clock.advance(to: 1.9)
        perception.send(.frame(FollowFrameBatch(
            frameID: ARFrameID(generation: 1, sequence: 3), timestamp: 1.9,
            pose: nil, depthAvailable: true, people: [],
            trackingQuality: .limited, trackingReason: .excessiveMotion)))
        await drain()
        clock.advance(to: 2)
        await drain()
        XCTAssertEqual(coordinator.state, .failed("AR tracking limited (excessiveMotion). Move the camera slowly and keep it steady."))
        XCTAssertTrue(motion.goals.isEmpty)
        XCTAssertTrue(motion.rotations.isEmpty)
    }

    func testDiagnosticsAreThrottledAndReportUnavailableReasonChangesAndRecovery() async {
        let perception = FollowPerceptionFake()
        let motion = FollowMotionFake()
        let clock = ManualFollowClock()
        var logs: [(String, [String: String])] = []
        let coordinator = FollowMeCoordinator(perception: perception, motion: motion, clock: clock,
                                             eventSink: { logs.append(($0, $1)) })
        _ = await coordinator.start()
        for sequence in 1...3 {
            perception.send(.frame(FollowFrameBatch(
                frameID: ARFrameID(generation: 4, sequence: UInt64(sequence)), timestamp: 0,
                pose: nil, depthAvailable: true, people: [], trackingQuality: .limited,
                trackingReason: .initializing, inferenceDuration: 0)))
            await drain()
        }
        XCTAssertEqual(logs.filter { $0.0 == "follow_frame" }.count, 1)
        XCTAssertEqual(logs.filter { $0.0 == "follow_perception_unavailable" }.count, 2, "No frames then limited, not every frame")
        clock.advance(to: 0.2)
        perception.send(.frame(FollowFrameBatch(
            frameID: ARFrameID(generation: 4, sequence: 4), timestamp: 0.1,
            pose: nil, depthAvailable: true, people: [], trackingQuality: .limited,
            trackingReason: .insufficientFeatures, inferenceDuration: 0.08)))
        await drain()
        let changed = logs.last { $0.0 == "follow_perception_unavailable" }?.1
        XCTAssertEqual(changed?["issue"], "trackingLimited")
        XCTAssertEqual(changed?["frame_id"], "4:4")
        XCTAssertEqual(changed?["frame_timestamp"], "0.1")
        XCTAssertEqual(changed?["frame_age_seconds"], "0.1")
        XCTAssertEqual(changed?["tracking_quality"], "limited")
        XCTAssertEqual(changed?["tracking_reason"], "insufficientFeatures")
        XCTAssertEqual(changed?["depth_available"], "true")
        XCTAssertEqual(changed?["inference_duration_seconds"], "0.08")
        perception.send(frame(5, at: 0.2, people: [person(5, at: 0.2, y: 1.5)]))
        await drain()
        XCTAssertNil(coordinator.perceptionIssue)
        XCTAssertEqual(coordinator.state, .holdingDistance)
        XCTAssertEqual(logs.filter { $0.0 == "follow_perception_recovered" }.count, 1)
        perception.send(frame(6, at: 0.2, people: [person(6, at: 0.2, y: 1.5)]))
        await drain()
        XCTAssertEqual(logs.filter { $0.0 == "follow_state" }.count, 2, "Searching and holding, not repeated states")
        clock.advance(to: 0.3)
        perception.send(frame(7, at: 0.3, depth: false))
        await drain()
        clock.advance(to: 1.3)
        perception.send(frame(8, at: 1.3, depth: false))
        await drain()
        XCTAssertEqual(logs.filter { $0.0 == "follow_frame" }.count, 2)
        _ = await coordinator.stop()
    }

    func testFreshFrameDuringWatchdogStopCannotResurrectOldRecoveryTimer() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1, y: 2)]))
        await drain()
        motion.suspendStop = true
        clock.advance(to: 0.501)
        await drain()
        XCTAssertEqual(coordinator.perceptionIssue, .staleFrame)
        perception.send(frame(2, at: 0.501, people: [person(2, at: 0.501, y: 1.5)]))
        await drain()
        XCTAssertNil(coordinator.perceptionIssue)
        motion.suspendStop = false
        motion.releaseStop()
        await drain()
        XCTAssertEqual(coordinator.state, .holdingDistance)
        // Wake cancelled sleepers while continuing to provide usable camera frames.
        for (index, time) in [1.0, 1.5, 2.0, 2.5, 2.501].enumerated() {
            clock.advance(to: time)
            perception.send(frame(UInt64(index + 3), at: time,
                                  people: [person(UInt64(index + 3), at: time, y: 1.5)]))
            await drain()
        }
        XCTAssertEqual(coordinator.state, .holdingDistance)
        XCTAssertNil(coordinator.perceptionIssue)
        _ = await coordinator.stop()
    }

    func testCancelledSafetyFailureDuringReplacementStillStopsFollow() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        motion.suspendStop = true
        clock.advance(to: 0.334)
        perception.send(frame(2, at: 0.334, people: [person(2, at: 0.334, y: 4.5)]))
        await drain()
        motion.safety(.failed(.cancelled))
        perception.send(frame(3, at: 0.334, people: [person(3, at: 0.334, y: 5)]))
        await drain()
        XCTAssertEqual(coordinator.state, .failed("Navigation safety failure."))
        XCTAssertEqual(motion.goals.count, 1)
        motion.suspendStop = false
        motion.releaseStop()
        await drain()
        XCTAssertEqual(coordinator.state, .failed("Navigation safety failure."))
        XCTAssertGreaterThanOrEqual(motion.stops, 3)
    }

    func testFreshnessBoundaryAndUnavailableTrackingRemainFailClosed() async {
        for quality in [ARTrackingQuality.normal, .unavailable] {
            let (coordinator, perception, motion, clock) = setup()
            _ = await coordinator.start()
            clock.advance(to: 0.5)
            perception.send(.frame(FollowFrameBatch(
                frameID: ARFrameID(generation: 1, sequence: 1), timestamp: 0,
                pose: quality == .normal ? Pose2D(position: .zero, yaw: 0) : nil,
                depthAvailable: true, people: [person(1)], trackingQuality: quality)))
            await drain()
            if quality == .normal {
                XCTAssertEqual(coordinator.state, .following)
                XCTAssertEqual(motion.goals.count, 1, "Exactly 0.5 seconds remains usable")
                clock.advance(to: 0.501)
                perception.send(frame(2, people: [person(2)]))
                await drain()
                XCTAssertEqual(coordinator.perceptionIssue, .staleFrame)
            } else {
                XCTAssertEqual(coordinator.perceptionIssue, .trackingUnavailable)
                XCTAssertTrue(motion.goals.isEmpty)
                XCTAssertTrue(motion.rotations.isEmpty)
            }
            _ = await coordinator.stop()
        }
    }
}
