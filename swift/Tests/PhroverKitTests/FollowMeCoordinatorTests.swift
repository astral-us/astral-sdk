import Foundation
import RoverNav
import XCTest
@testable import PhroverKit

@MainActor
final class FollowMeCoordinatorTests: XCTestCase {
    func testPersonApproachingDuringReadySignalCancelsBeforeHoldClearanceIsCrossed() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        motion.suspendReadySignal = true
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5, y: 1.6)]))
        await drain()
        perception.send(frame(2, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(2, at: 5, y: 1.6)]))
        await drain()
        let stops = motion.stops
        perception.send(frame(3, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(3, at: 5, y: 1.3)]))
        await drain()
        XCTAssertGreaterThan(motion.stops, stops)
        XCTAssertFalse(coordinator.isActive)
        motion.releaseReadySignal()
        await drain()
        XCTAssertNotEqual(coordinator.state, .waitingForMovement)
        XCTAssertEqual(motion.readySignals, 1)
    }

    func testTooClosePersonCannotAuthorizeReadySignalAcrossHoldClearance() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5, y: 1.3)]))
        await drain()
        perception.send(frame(2, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(2, at: 5, y: 1.3)]))
        await drain()
        XCTAssertEqual(motion.readySignals, 0)
        XCTAssertEqual(coordinator.state, .failed("Not enough person clearance for the 10 cm ready signal. Step back and start following again."))
        XCTAssertTrue(motion.goals.isEmpty)
    }

    func testLossAfterSignalStopBeforeBaselineReacquiresWithoutSecondMoveAndCanDepart() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        motion.suspendRotation = true
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5)]))
        await drain()
        perception.send(frame(2, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(2, at: 5)]))
        await drain()
        perception.send(frame(3, at: 5))
        await drain()
        for sequence in UInt64(4)...6 {
            perception.send(frame(sequence, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(sequence, at: 5)]))
            await drain()
        }
        XCTAssertEqual(coordinator.state, .waitingForMovement)
        perception.send(frame(7, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(7, at: 5, y: 4.3)]))
        await drain()
        XCTAssertEqual(motion.goals.count, 1, "A confirmed signal without its baseline must not leave departure permanently gated")
        XCTAssertEqual(motion.readySignals, 1)
        motion.releaseRotation()
        _ = await coordinator.stop()
    }

    func testLossDuringReadySignalCannotRepeatMoveOrBecomeReadyAfterReacquisition() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        motion.suspendReadySignal = true
        motion.suspendRotation = true
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5)]))
        await drain()
        perception.send(frame(2, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(2, at: 5)]))
        await drain()
        perception.send(frame(3, at: 5))
        await drain()
        motion.releaseReadySignal()
        perception.send(frame(4, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(4, at: 5)]))
        await drain()
        perception.send(frame(5, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(5, at: 5)]))
        await drain()
        XCTAssertEqual(motion.readySignals, 1)
        XCTAssertEqual(coordinator.state, .failed("Ready signal interrupted. Stop and start following again."))
        XCTAssertTrue(motion.goals.isEmpty)
        motion.releaseRotation()
        _ = await coordinator.stop()
    }

    func testCancelledUnsafeStaleAndOperatorStoppedReadySignalNeverMarksReady() async {
        for scenario in 0..<4 {
            let (coordinator, perception, motion, clock) = productionSetup()
            motion.suspendReadySignal = true
            _ = await coordinator.start()
            await drain()
            clock.advance(to: 5)
            perception.send(frame(1, at: 5, people: [person(1, at: 5)]))
            await drain()
            perception.send(frame(2, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(2, at: 5)]))
            await drain()
            if scenario == 0 { motion.readySignalResult = .cancelled }
            if scenario == 1 { motion.readySignalResult = .failed(.obstacle) }
            if scenario == 2 { clock.advance(to: 5.501); await drain() }
            if scenario == 3 { coordinator.inhibitMotion(); _ = await coordinator.stop() }
            motion.releaseReadySignal()
            await drain()
            perception.send(frame(3, at: clock.now, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(3, at: clock.now)]))
            await drain()
            XCTAssertNotEqual(coordinator.state, .waitingForMovement)
            XCTAssertEqual(motion.readySignals, 1)
            XCTAssertTrue(motion.goals.isEmpty)
            _ = await coordinator.stop()
        }
    }

    func testReadySignalOnceThenFreshPostStopBaselineBeforeWaiting() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        motion.suspendReadySignal = true
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5)]))
        await drain()
        perception.send(frame(2, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2), people: [person(2, at: 5)]))
        await drain()
        XCTAssertEqual(motion.readySignals, 1)
        XCTAssertEqual(String(describing: coordinator.state), "signalingReady")
        XCTAssertTrue(motion.goals.isEmpty)
        motion.releaseReadySignal()
        await drain()
        XCTAssertEqual(String(describing: coordinator.state), "signalingReady", "Completion needs a new post-stop frame")
        perception.send(frame(3, at: 5, pose: Pose2D(position: Vec2(0, 0.1), yaw: .pi / 2), people: [person(3, at: 5)]))
        await drain()
        XCTAssertEqual(coordinator.state, .waitingForMovement)
        perception.send(frame(4, at: 5, pose: Pose2D(position: Vec2(0, 0.1), yaw: .pi / 2), people: [person(4, at: 5, y: 4.299)]))
        await drain()
        XCTAssertTrue(motion.goals.isEmpty)
        perception.send(frame(5, at: 5, pose: Pose2D(position: Vec2(0, 0.1), yaw: .pi / 2), people: [person(5, at: 5, y: 4.3)]))
        await drain()
        XCTAssertEqual(motion.goals.count, 1)
        XCTAssertEqual(motion.readySignals, 1)
        _ = await coordinator.stop()
    }

    func testAlignmentProgressesWithNewMatchedFramesDuringEveryStopAcknowledgement() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        motion.suspendStop = true
        motion.suspendAlignment = true
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5, x: 1)]))
        await drain()
        XCTAssertEqual(motion.stops, 1)
        XCTAssertTrue(motion.alignments.isEmpty)
        for sequence in UInt64(2)...3 {
            let time = 5 + Double(sequence - 1) / 10
            clock.advance(to: time)
            perception.send(frame(sequence, at: time,
                                  pose: Pose2D(position: Vec2(1, time - 5), yaw: sequence == 2 ? .pi / 4 : .pi / 3),
                                  people: [person(sequence, at: time, x: 1, y: 4 + time - 5)]))
            await drain()
        }
        motion.releaseStop()
        await drain()
        XCTAssertEqual(motion.alignments.count, 1, "Healthy 100 ms arrivals must not starve a 200 ms stop acknowledgement")
        if let angle = motion.alignments.first { XCTAssertEqual(angle, .pi / 6, accuracy: 0.0001, "Use newest matched person and its same-snapshot rover pose") }
        for sequence in UInt64(4)...5 {
            let time = 5 + Double(sequence - 1) / 10
            clock.advance(to: time)
            perception.send(frame(sequence, at: time,
                                  pose: Pose2D(position: Vec2(1, time - 5), yaw: .pi / 2),
                                  people: [person(sequence, at: time, x: 1, y: 4.2)]))
            await drain()
        }
        motion.releaseAlignment()
        await drain()
        XCTAssertEqual(motion.stops, 2)
        clock.advance(to: 5.5)
        perception.send(frame(6, at: 5.5, pose: Pose2D(position: Vec2(1, 0.5), yaw: .pi / 2),
                              people: [person(6, at: 5.5, x: 1, y: 4.2)]))
        await drain()
        clock.advance(to: 5.6)
        motion.suspendStop = false
        motion.releaseStop()
        await drain()
        perception.send(frame(7, at: 5.6, pose: Pose2D(position: Vec2(1, 0.6), yaw: .pi / 2),
                              people: [person(7, at: 5.6, x: 1, y: 4.2)]))
        await drain()
        perception.send(frame(8, at: 5.6, pose: Pose2D(position: Vec2(1, 0.7), yaw: .pi / 2),
                              people: [person(8, at: 5.6, x: 1, y: 4.2)]))
        await drain()
        XCTAssertEqual(coordinator.state, .waitingForMovement)
        XCTAssertEqual(motion.alignments.count, 1, "Repeated arrivals across both acknowledgements must allow alignment to complete")
        XCTAssertTrue(motion.goals.isEmpty)
        _ = await coordinator.stop()
        motion.releaseAlignment()
    }

    func testHealthyFrameAtReadinessDeadlineCannotBeatTimeoutTask() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        await drain()
        clock.advance(to: 10, wakeSleepers: false)
        perception.send(frame(1, at: 10, people: [person(1, at: 10)]))
        await drain()
        XCTAssertEqual(coordinator.state, .failed(FollowPerceptionIssue.noFrames.message))
        XCTAssertTrue(motion.alignments.isEmpty)
        XCTAssertTrue(motion.goals.isEmpty)
        clock.advance(to: 10)
        await drain()
    }

    func testCancelledAlignmentStillConfirmsStopAndCannotEstablishBaseline() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        motion.alignmentResult = .cancelled
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5)]))
        await drain()
        XCTAssertEqual(motion.stops, 2, "Even a cancelled alignment must confirm stationary motors afterward")
        XCTAssertEqual(coordinator.state, .aligning)
        XCTAssertTrue(motion.goals.isEmpty)
        _ = await coordinator.stop()
    }

    func testProductionReadinessWindowStartsAfterPauseAndFailsAtTenSeconds() async {
        let (coordinator, _, motion, clock) = productionSetup()
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 4.999)
        await drain()
        XCTAssertEqual(coordinator.state, .pausing)
        clock.advance(to: 5)
        await drain()
        XCTAssertEqual(coordinator.state, .searching)
        clock.advance(to: 9.999)
        await drain()
        XCTAssertTrue(coordinator.isActive)
        clock.advance(to: 10)
        await drain()
        XCTAssertEqual(coordinator.state, .failed(FollowPerceptionIssue.noFrames.message))
        XCTAssertTrue(motion.rotations.isEmpty)
        XCTAssertTrue(motion.alignments.isEmpty)
        XCTAssertTrue(motion.goals.isEmpty)
    }

    func testExpiredPauseFrameCannotStartScanAlignmentOrTranslation() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        clock.advance(to: 5)
        await drain()
        XCTAssertEqual(coordinator.state, .searching)
        XCTAssertEqual(coordinator.perceptionIssue, .staleFrame)
        XCTAssertTrue(motion.rotations.isEmpty)
        XCTAssertTrue(motion.alignments.isEmpty)
        XCTAssertTrue(motion.goals.isEmpty)
        perception.send(frame(2, at: 5, people: [person(2, at: 5)]))
        await drain()
        XCTAssertEqual(motion.alignments, [.pi / 2])
        XCTAssertTrue(motion.goals.isEmpty)
        _ = await coordinator.stop()
    }

    func testStopDuringPauseAndWaitingPreventsCallbacksAndTranslation() async {
        for waiting in [false, true] {
            let (coordinator, perception, motion, clock) = productionSetup()
            if waiting { await acquireWaiting(coordinator, perception, clock) }
            else { _ = await coordinator.start(); await drain() }
            coordinator.inhibitMotion()
            _ = await coordinator.stop()
            clock.advance(to: 10)
            perception.send(frame(99, at: 10, people: [person(99, at: 10, y: 4.5)]))
            await drain()
            XCTAssertEqual(coordinator.state, .stopped)
            XCTAssertTrue(motion.goals.isEmpty)
            XCTAssertEqual(motion.alignments.count, waiting ? 1 : 0)
            XCTAssertTrue(motion.rotations.isEmpty)
        }
    }

    func testOutdatedAlignmentStopAcknowledgementCannotTurnOrTranslate() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        motion.suspendStop = true
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5)]))
        await drain()
        XCTAssertEqual(motion.stops, 1)
        clock.advance(to: 5.501)
        await drain()
        motion.suspendStop = false
        motion.releaseStop()
        await drain()
        XCTAssertTrue(motion.alignments.isEmpty)
        XCTAssertTrue(motion.goals.isEmpty)
        XCTAssertEqual(coordinator.perceptionIssue, .staleFrame)
        _ = await coordinator.stop()
    }

    func testWaitingTracksSamePersonAndLateralOrTowardMotionDoesNotDepart() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        await acquireWaiting(coordinator, perception, clock)
        for (sequence, x, y) in [(UInt64(4), 0.5, sqrt(16 - 0.25)), (5, 0.0, 3.5), (6, 0.0, 4.0)] {
            perception.send(frame(sequence, at: 5,
                                  people: [person(sequence, at: 5, x: x, y: y, screen: 0.65),
                                           person(sequence, at: 5, x: 6, y: 6, screen: 0.5)]))
            await drain()
            XCTAssertEqual(coordinator.state, .waitingForMovement)
            XCTAssertTrue(motion.goals.isEmpty)
        }
        _ = await coordinator.stop()
    }

    func testWaitingOutageStopsOnceAndFailsAfterTwoSecondsWithoutDeparture() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        await acquireWaiting(coordinator, perception, clock)
        let stops = motion.stops
        perception.send(frame(4, at: 5, depth: false))
        await drain()
        clock.advance(to: 6)
        perception.send(frame(5, at: 6, pose: nil))
        await drain()
        XCTAssertEqual(motion.stops, stops + 1)
        clock.advance(to: 7)
        await drain()
        XCTAssertEqual(coordinator.state, .failed(FollowPerceptionIssue.poseUnavailable.message))
        XCTAssertTrue(motion.goals.isEmpty)
    }

    func testProductionSearchNeverExceedsOneRoundEvenWithNonDividingScanIncrement() async {
        for increment in [Double.pi / 6, 0.7] {
            let perception = FollowPerceptionFake()
            let motion = FollowMotionFake()
            let clock = ManualFollowClock()
            var config = FollowMeConfiguration()
            config.scanIncrement = increment
            let coordinator = FollowMeCoordinator(perception: perception, motion: motion, clock: clock,
                                                  configuration: config, eventSink: { _, _ in })
            _ = await coordinator.start()
            await drain()
            clock.advance(to: 5)
            perception.send(frame(1, at: 5))
            for _ in 0..<20 { await drain() }
            XCTAssertEqual(coordinator.state, .failed("No person found."))
            XCTAssertEqual(motion.rotations.reduce(0, +), 2 * .pi, accuracy: 0.00001)
            XCTAssertTrue(motion.goals.isEmpty)
            XCTAssertGreaterThan(motion.stops, 0)
        }
    }

    func testBaselineRejectsDelayedPreCompletionFrameAndIncorrectHeading() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        motion.suspendAlignment = true
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5)]))
        await drain()
        clock.advance(to: 5.2)
        motion.releaseAlignment()
        await drain()
        perception.send(frame(2, at: 5.1, pose: Pose2D(position: .zero, yaw: .pi / 2),
                              people: [person(2, at: 5.1)]))
        await drain()
        XCTAssertEqual(coordinator.state, .aligning, "Delayed in-turn observation cannot establish baseline")
        XCTAssertEqual(motion.alignments.count, 1, "Wait for a post-completion frame")
        perception.send(frame(3, at: 5.2, people: [person(3, at: 5.2)]))
        await drain()
        XCTAssertEqual(coordinator.state, .aligning, "Arrival alone cannot certify heading")
        XCTAssertEqual(motion.alignments.count, 2)
        motion.releaseAlignment()
        await drain()
        perception.send(frame(4, at: 5.2, pose: Pose2D(position: .zero, yaw: .pi / 2),
                              people: [person(4, at: 5.2)]))
        await drain()
        perception.send(frame(5, at: 5.2, pose: Pose2D(position: .zero, yaw: .pi / 2),
                              people: [person(5, at: 5.2)]))
        await drain()
        XCTAssertEqual(coordinator.state, .waitingForMovement)
        XCTAssertTrue(motion.goals.isEmpty)
        _ = await coordinator.stop()
    }

    private func productionSetup() -> (FollowMeCoordinator, FollowPerceptionFake, FollowMotionFake, ManualFollowClock) {
        let perception = FollowPerceptionFake()
        let motion = FollowMotionFake()
        let clock = ManualFollowClock()
        return (FollowMeCoordinator(perception: perception, motion: motion, clock: clock,
                                    eventSink: { _, _ in }), perception, motion, clock)
    }

    private func acquireWaiting(_ coordinator: FollowMeCoordinator, _ perception: FollowPerceptionFake,
                                _ clock: ManualFollowClock) async {
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5)]))
        await drain()
        perception.send(frame(2, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2),
                              people: [person(2, at: 5)]))
        await drain()
        perception.send(frame(3, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2),
                              people: [person(3, at: 5)]))
        await drain()
        XCTAssertEqual(coordinator.state, .waitingForMovement)
    }

    func testLossBeforeDepartureReacquiresAndRetainsFixedBaseline() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        motion.suspendRotation = true
        await acquireWaiting(coordinator, perception, clock)
        perception.send(frame(4, at: 5))
        await drain()
        XCTAssertEqual(coordinator.state, .reacquiring)
        perception.send(frame(5, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2),
                              people: [person(5, at: 5, y: 4.2)]))
        await drain()
        XCTAssertEqual(coordinator.state, .aligning)
        XCTAssertTrue(motion.goals.isEmpty, "Reacquisition cannot bypass departure")
        perception.send(frame(6, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2),
                              people: [person(6, at: 5, y: 4.2)]))
        await drain()
        XCTAssertEqual(coordinator.state, .waitingForMovement)
        perception.send(frame(7, at: 5, people: [person(7, at: 5, y: 4.299)]))
        await drain()
        XCTAssertTrue(motion.goals.isEmpty)
        perception.send(frame(8, at: 5, people: [person(8, at: 5, y: 4.3)]))
        await drain()
        XCTAssertEqual(motion.goals.count, 1, "The original baseline survives reacquisition")
        XCTAssertEqual(motion.readySignals, 1, "Reacquisition cannot repeat the ready move")
        _ = await coordinator.stop()
        motion.releaseRotation()
    }

    func testStopDuringAlignmentAllowsNewGenerationToAlignBeforeOldTurnCompletes() async {
        let (coordinator, perception, motion, clock) = productionSetup()
        motion.suspendAlignment = true
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5)]))
        await drain()
        XCTAssertEqual(motion.alignments.count, 1)
        _ = await coordinator.stop()
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 10)
        perception.send(frame(1, at: 10, people: [person(1, at: 10)]))
        await drain()
        XCTAssertEqual(motion.alignments.count, 2, "An old suspended alignment cannot block a new generation")
        motion.releaseAlignment()
        await drain()
        XCTAssertTrue(motion.goals.isEmpty)
        _ = await coordinator.stop()
    }

    func testProductionSequenceRequiresFreshAlignedBaselineAndPointThreeRangeDeparture() async {
        let perception = FollowPerceptionFake()
        let motion = FollowMotionFake()
        let clock = ManualFollowClock()
        motion.suspendAlignment = true
        let coordinator = FollowMeCoordinator(perception: perception, motion: motion, clock: clock)
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5, people: [person(1, at: 5)]))
        await drain()
        XCTAssertEqual(motion.alignments, [.pi / 2])
        perception.send(frame(2, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2),
                              people: [person(2, at: 5, y: 4.5)]))
        await drain()
        XCTAssertTrue(motion.goals.isEmpty)
        motion.releaseAlignment()
        await drain()
        XCTAssertEqual(coordinator.state, .aligning, "An in-turn frame cannot establish the baseline")
        perception.send(frame(3, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2),
                              people: [person(3, at: 5, y: 4.5)]))
        await drain()
        perception.send(frame(4, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2),
                              people: [person(4, at: 5, y: 4.5)]))
        await drain()
        XCTAssertEqual(String(describing: coordinator.state), "waitingForMovement")
        XCTAssertEqual(motion.stops, 3, "Alignment and ready signal end with confirmed stops")
        for (sequence, distance) in [(UInt64(5), 4.5), (6, 4.3), (7, 4.799)] {
            perception.send(frame(sequence, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2),
                                  people: [person(sequence, at: 5, y: distance)]))
            await drain()
            XCTAssertTrue(motion.goals.isEmpty, "Stationary, toward, and .299-away observations must hold")
        }
        perception.send(frame(8, at: 5, pose: Pose2D(position: .zero, yaw: .pi / 2),
                              people: [person(8, at: 5, y: 4.8)]))
        await drain()
        XCTAssertEqual(coordinator.state, .following)
        XCTAssertEqual(motion.goals.count, 1)
        XCTAssertEqual(motion.goals.first?.y ?? 0, 3.3, accuracy: 0.0001)
        _ = await coordinator.stop()
    }

    func testProductionDetectionStopsScanImmediatelyAndAlignsWithoutBlockingFrames() async {
        let perception = FollowPerceptionFake()
        let motion = FollowMotionFake()
        let clock = ManualFollowClock()
        motion.suspendRotation = true
        motion.suspendAlignment = true
        let coordinator = FollowMeCoordinator(perception: perception, motion: motion, clock: clock)
        _ = await coordinator.start()
        await drain()
        clock.advance(to: 5)
        perception.send(frame(1, at: 5))
        await drain()
        XCTAssertEqual(motion.rotations.count, 1)
        perception.send(frame(2, at: 5, pose: Pose2D(position: Vec2(1, 1), yaw: -3 * .pi / 4),
                              people: [person(2, at: 5, x: -3, y: 1)]))
        await drain()
        XCTAssertEqual(motion.alignments.count, 1)
        if let angle = motion.alignments.first { XCTAssertEqual(angle, -.pi / 4, accuracy: 0.0001) }
        XCTAssertEqual(String(describing: coordinator.state), "aligning")
        XCTAssertTrue(motion.goals.isEmpty)
        XCTAssertGreaterThanOrEqual(motion.stops, 1)
        perception.send(frame(3, at: 5, depth: false))
        await drain()
        XCTAssertEqual(coordinator.perceptionIssue, .depthUnavailable, "Alignment cannot block perception")
        motion.releaseRotation()
        motion.releaseAlignment()
        await drain()
        XCTAssertEqual(motion.rotations.count, 1, "Detection ends the initial round immediately")
        XCTAssertTrue(motion.goals.isEmpty)
        _ = await coordinator.stop()
    }

    func testProductionPauseProcessesPerceptionButNeverMovesBeforeFiveSeconds() async {
        let perception = FollowPerceptionFake()
        let motion = FollowMotionFake()
        let clock = ManualFollowClock()
        motion.suspendRotation = true
        let coordinator = FollowMeCoordinator(perception: perception, motion: motion, clock: clock)
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        XCTAssertNil(coordinator.perceptionIssue)
        XCTAssertEqual(String(describing: coordinator.state), "pausing")
        XCTAssertTrue(motion.goals.isEmpty)
        XCTAssertTrue(motion.rotations.isEmpty)
        clock.advance(to: 4.999)
        perception.send(frame(2, at: 4.999))
        await drain()
        XCTAssertEqual(String(describing: coordinator.state), "pausing")
        XCTAssertTrue(motion.rotations.isEmpty)
        clock.advance(to: 5)
        await drain()
        XCTAssertEqual(coordinator.state, .searching)
        XCTAssertEqual(motion.rotations.count, 1)
        XCTAssertTrue(motion.goals.isEmpty, "Old pause person must not initiate translation")
        _ = await coordinator.stop()
        motion.releaseRotation()
    }

    private func setup() -> (FollowMeCoordinator, FollowPerceptionFake, FollowMotionFake, ManualFollowClock) {
        let perception = FollowPerceptionFake()
        let motion = FollowMotionFake()
        let clock = ManualFollowClock()
        // These tests exercise downstream legacy follow/readiness policies directly.
        var config = FollowMeConfiguration()
        config.stationaryPauseSeconds = 0
        config.departureRangeIncrease = 0
        return (FollowMeCoordinator(perception: perception, motion: motion, clock: clock,
                                    configuration: config,
                                    eventSink: { _, _ in }), perception, motion, clock)
    }

    private func frame(_ sequence: UInt64, at time: TimeInterval = 0, pose: Pose2D? = Pose2D(position: .zero, yaw: 0), depth: Bool = true, people: [FollowPersonObservation] = [], quality: ARTrackingQuality? = .normal) -> FollowPerceptionEvent {
        .frame(FollowFrameBatch(frameID: ARFrameID(generation: 1, sequence: sequence), timestamp: time, pose: pose, depthAvailable: depth, people: people, trackingQuality: quality))
    }

    private func person(_ sequence: UInt64, at time: TimeInterval = 0, x: Double = 0, y: Double = 4, screen: CGFloat = 0.5) -> FollowPersonObservation {
        FollowPersonObservation(frameID: ARFrameID(generation: 1, sequence: sequence), timestamp: time, confidence: 0.9, boundingBox: CGRect(x: screen - 0.05, y: 0.4, width: 0.1, height: 0.2), position: Vec2(x, y), pose: Pose2D(position: .zero, yaw: 0))
    }

    private func drain() async { for _ in 0..<30 { await Task.yield() } }

    func testStartupWaitsForHealthyFrameUntilJustBeforeFiveSeconds() async {
        let unhealthy = [frame(1, pose: nil), frame(1, depth: false),
                         frame(1, quality: .limited), frame(1, quality: .unavailable),
                         frame(1, at: -1), frame(1, quality: nil)]
        for event in unhealthy {
            let (coordinator, perception, motion, clock) = setup()
            motion.suspendRotation = true
            _ = await coordinator.start()
            perception.send(event)
            await drain()
            XCTAssertTrue(motion.rotations.isEmpty)
            XCTAssertTrue(motion.goals.isEmpty)
            XCTAssertEqual(motion.stops, 0, "Startup is already stationary")
            clock.advance(to: 4.999)
            await drain()
            XCTAssertEqual(coordinator.state, .searching)
            perception.send(frame(2, at: 4.999))
            await drain()
            XCTAssertNil(coordinator.perceptionIssue)
            XCTAssertEqual(motion.rotations.count, 1, "Readiness starts searching immediately")
            _ = await coordinator.stop()
            motion.releaseRotation()
        }
    }

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

    func testStartupDeadlineReportsLatestTrackingReasonAtFiveSeconds() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, depth: false))
        await drain()
        clock.advance(to: 4.9)
        perception.send(.frame(FollowFrameBatch(
            frameID: ARFrameID(generation: 1, sequence: 2), timestamp: 4.9,
            pose: nil, depthAvailable: true, people: [],
            trackingQuality: .limited, trackingReason: .excessiveMotion)))
        await drain()
        XCTAssertEqual(coordinator.state, .searching)
        clock.advance(to: 5)
        await drain()
        XCTAssertEqual(coordinator.state, .failed("AR tracking limited (excessiveMotion). Move the camera slowly and keep it steady."))
        XCTAssertTrue(motion.rotations.isEmpty)
        XCTAssertTrue(motion.goals.isEmpty)
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
        clock.advance(to: 0.5)
        perception.send(frame(3, at: 0.5))
        await drain()
        clock.advance(to: 1)
        perception.send(frame(4, at: 1, people: [person(4, at: 1, x: 6, screen: 0.5)]))
        await drain()
        XCTAssertEqual(coordinator.state, .reacquiring)
        for step in 3...19 {
            let time = Double(step) / 2
            let sequence = UInt64(step + 2)
            clock.advance(to: time)
            perception.send(frame(sequence, at: time,
                                  people: [person(sequence, at: time, x: 6, screen: 0.5)]))
            await drain()
        }
        clock.advance(to: 9.999)
        perception.send(frame(22, at: 9.999, people: [person(22, at: 9.999, y: 4.2, screen: 0.8)]))
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
        for step in 1...19 {
            let time = Double(step) / 2
            clock.advance(to: time)
            perception.send(frame(UInt64(step + 2), at: time))
            await drain()
        }
        clock.advance(to: 9.999)
        await drain()
        XCTAssertEqual(coordinator.state, .reacquiring)
        clock.advance(to: 10)
        perception.send(frame(22, at: 10, people: [person(22, at: 10)]))
        await drain()
        XCTAssertFalse(coordinator.isActive)
        XCTAssertTrue(motion.goals.count == 1)
        motion.releaseRotation()
    }

    func testReacquisitionScansRequireFreshPerceptionAfterStopAndCompletion() async {
        for delayedStop in [true, false] {
            let (coordinator, perception, motion, clock) = setup()
            motion.suspendRotation = true
            _ = await coordinator.start()
            perception.send(frame(1, people: [person(1)]))
            await drain()
            motion.suspendStop = delayedStop
            perception.send(frame(2))
            await drain()
            XCTAssertEqual(coordinator.state, .reacquiring)
            XCTAssertEqual(motion.rotations.count, delayedStop ? 0 : 1)
            clock.advance(to: 0.6)
            await drain()
            if delayedStop {
                motion.suspendStop = false
                motion.releaseStop()
            } else {
                motion.releaseRotation()
            }
            await drain()
            XCTAssertEqual(motion.rotations.count, delayedStop ? 0 : 1,
                           "Neither acknowledgement nor scan completion may launch a stale scan")
            XCTAssertEqual(coordinator.perceptionIssue, .staleFrame)
            let rotations = motion.rotations.count
            perception.send(frame(3, at: 0.6))
            await drain()
            XCTAssertNil(coordinator.perceptionIssue)
            XCTAssertEqual(motion.rotations.count, rotations + 1, "Fresh perception resumes reacquisition")
            _ = await coordinator.stop()
            motion.releaseRotation()
        }
    }

    func testReacquisitionWithoutFramesStopsAndFailsBeforeTenSecondTargetDeadline() async {
        let (coordinator, perception, motion, clock) = setup()
        motion.suspendRotation = true
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        perception.send(frame(2))
        await drain()
        XCTAssertEqual(motion.rotations.count, 1)
        let stops = motion.stops
        clock.advance(to: 0.501)
        await drain()
        XCTAssertEqual(motion.stops, stops + 1)
        XCTAssertEqual(coordinator.perceptionIssue, .staleFrame)
        motion.releaseRotation()
        await drain()
        XCTAssertEqual(motion.rotations.count, 1)
        clock.advance(to: 2.5)
        await drain()
        XCTAssertTrue(coordinator.isActive)
        clock.advance(to: 2.501)
        await drain()
        XCTAssertEqual(coordinator.state, .failed(FollowPerceptionIssue.staleFrame.message))
        XCTAssertEqual(motion.rotations.count, 1)
        XCTAssertEqual(motion.goals.count, 1)
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

    func testOutageDeadlineExpiresWhileStopIsPendingAndRejectsLateHealthyFrame() async {
        for drainBeforeRelease in [true, false] {
            let (coordinator, perception, motion, clock) = setup()
            _ = await coordinator.start()
            perception.send(frame(1, people: [person(1, y: 2)]))
            await drain()
            motion.suspendStop = true
            clock.advance(to: 0.1)
            perception.send(frame(2, at: 0.1, depth: false))
            await drain()
            XCTAssertEqual(motion.stops, 2)
            clock.advance(to: 2.099)
            await drain()
            XCTAssertTrue(coordinator.isActive)
            clock.advance(to: 2.1)
            perception.send(frame(3, at: 2.1, people: [person(3, at: 2.1, y: 1.5)]))
            if drainBeforeRelease {
                await drain()
                XCTAssertEqual(coordinator.state, .failed(FollowPerceptionIssue.depthUnavailable.message),
                               "Recovery enforcement cannot wait for motor acknowledgement")
            }
            motion.suspendStop = false
            motion.releaseStop()
            await drain()
            XCTAssertEqual(coordinator.state, .failed(FollowPerceptionIssue.depthUnavailable.message),
                           "A late healthy frame cannot cancel an elapsed outage deadline")
            XCTAssertEqual(motion.goals.count, 1)
            XCTAssertTrue(motion.rotations.isEmpty)
            XCTAssertEqual(motion.stops, 3, "Terminal cleanup still confirms stopping")
        }
    }

    func testContinuousOutageStopsOnceAndKeepsOriginalRecoveryDeadline() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1, y: 1.5)]))
        await drain()
        clock.advance(to: 0.1)
        perception.send(frame(2, at: 0.1, depth: false))
        await drain()
        XCTAssertEqual(motion.stops, 1)
        clock.advance(to: 0.5)
        perception.send(frame(3, at: 0.5, pose: nil))
        await drain()
        clock.advance(to: 1.9)
        perception.send(frame(4, at: 1.9, quality: .unavailable))
        await drain()
        XCTAssertEqual(motion.stops, 1, "One continuous outage requests one confirmed stop")
        clock.advance(to: 2.099)
        await drain()
        XCTAssertTrue(coordinator.isActive)
        clock.advance(to: 2.1)
        await drain()
        XCTAssertEqual(coordinator.state, .failed(FollowPerceptionIssue.trackingUnavailable.message))
        XCTAssertTrue(motion.goals.isEmpty)
        XCTAssertTrue(motion.rotations.isEmpty)
    }

    func testUnhealthyFrameDuringWatchdogStopRetainsRecoveryDeadline() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1, y: 1.5)]))
        await drain()
        motion.suspendStop = true
        clock.advance(to: 0.501)
        await drain()
        XCTAssertEqual(motion.stops, 1)
        clock.advance(to: 0.6)
        perception.send(frame(2, at: 0.6, depth: false))
        await drain()
        motion.suspendStop = false
        motion.releaseStop()
        await drain()
        clock.advance(to: 2.5)
        await drain()
        XCTAssertTrue(coordinator.isActive)
        clock.advance(to: 2.501)
        await drain()
        XCTAssertEqual(coordinator.state, .failed(FollowPerceptionIssue.depthUnavailable.message))
        XCTAssertTrue(motion.goals.isEmpty)
    }

    func testHealthyRecoveryAllowsOneStopForASecondOutage() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1, y: 1.5)]))
        await drain()
        perception.send(frame(2, depth: false))
        await drain()
        XCTAssertEqual(motion.stops, 1)
        clock.advance(to: 0.5)
        perception.send(frame(3, at: 0.5, people: [person(3, at: 0.5, y: 1.5)]))
        await drain()
        XCTAssertNil(coordinator.perceptionIssue)
        clock.advance(to: 0.6)
        perception.send(frame(4, at: 0.6, depth: false))
        await drain()
        XCTAssertEqual(motion.stops, 2)
        clock.advance(to: 2)
        await drain()
        XCTAssertTrue(coordinator.isActive, "First outage's cancelled timer must not terminate the second")
        clock.advance(to: 2.6)
        await drain()
        XCTAssertEqual(coordinator.state, .failed(FollowPerceptionIssue.depthUnavailable.message))
    }

    func testHealthySearchFrameDuringWatchdogStopResumesScanOnlyAfterConfirmation() async {
        let (coordinator, perception, motion, clock) = setup()
        motion.suspendRotation = true
        _ = await coordinator.start()
        perception.send(frame(1))
        await drain()
        XCTAssertEqual(motion.rotations.count, 1)
        motion.suspendStop = true
        clock.advance(to: 0.501)
        await drain()
        motion.releaseRotation()
        perception.send(frame(2, at: 0.501))
        await drain()
        XCTAssertEqual(motion.rotations.count, 1, "Pending stop confirmation gates scanning")
        motion.suspendStop = false
        motion.releaseStop()
        await drain()
        XCTAssertEqual(motion.rotations.count, 2, "Healthy recovery resumes searching")
        _ = await coordinator.stop()
        motion.releaseRotation()
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

    func testSuspendedFrameWorkProcessesOnlyNewestPendingFrame() async {
        let perception = FollowPerceptionFake()
        let motion = FollowMotionFake()
        let clock = ManualFollowClock()
        var issues: [String] = []
        var config = FollowMeConfiguration()
        config.stationaryPauseSeconds = 0
        config.departureRangeIncrease = 0
        let coordinator = FollowMeCoordinator(perception: perception, motion: motion, clock: clock,
            configuration: config,
            eventSink: { event, fields in
                if event == "follow_perception_unavailable", let issue = fields["issue"] { issues.append(issue) }
            })
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1, y: 2)]))
        await drain()
        motion.suspendStop = true
        clock.advance(to: 0.334)
        perception.send(frame(2, at: 0.334, depth: false))
        await drain()
        XCTAssertEqual(motion.stops, 2)
        for sequence in 3...5 {
            clock.advance(to: Double(sequence) / 10 + 0.1)
            perception.send(frame(UInt64(sequence), at: clock.now, pose: nil))
            await drain()
        }
        clock.advance(to: 1.2)
        perception.send(frame(6, at: 1.2, people: [person(6, at: 1.2, y: 1.5)]))
        await drain()
        XCTAssertEqual(motion.goals.count, 1)
        motion.suspendStop = false
        motion.releaseStop()
        await drain()
        XCTAssertEqual(coordinator.state, .holdingDistance)
        XCTAssertNil(coordinator.perceptionIssue)
        XCTAssertEqual(motion.stops, 2)
        XCTAssertFalse(issues.contains("staleFrame"), "Superseded frames must not cause a stale outage")
        XCTAssertFalse(issues.contains("poseUnavailable"), "Obsolete pending frames must not be processed")
        _ = await coordinator.stop()
    }

    func testLifecycleEventsBypassSuspendedFrameStop() async {
        for (event, message) in [(FollowPerceptionEvent.interrupted, "AR session interrupted."),
                                 (.failed("AR session failed."), "AR session failed.")] {
            let (coordinator, perception, motion, clock) = setup()
            _ = await coordinator.start()
            perception.send(frame(1, people: [person(1)]))
            await drain()
            motion.suspendStop = true
            clock.advance(to: 0.334)
            perception.send(frame(2, at: 0.334, people: [person(2, at: 0.334, y: 4.5)]))
            await drain()
            perception.send(frame(3, at: 0.334))
            perception.send(event)
            perception.send(frame(4, at: 0.334, people: [person(4, at: 0.334)]))
            await drain()
            XCTAssertEqual(coordinator.state, .failed(message), "Lifecycle failure must fence motion before acknowledgement")
            XCTAssertEqual(motion.stops, 2, "Terminal cleanup waits for the in-flight confirmation")
            XCTAssertEqual(motion.goals.count, 1)
            motion.suspendStop = false
            motion.releaseStop()
            await drain()
            XCTAssertEqual(coordinator.state, .failed(message))
            XCTAssertEqual(motion.stops, 3, "Terminal stop remains confirmed")
            XCTAssertEqual(motion.goals.count, 1)
        }
    }

    func testLifecycleFailureDuringStopRemainsBlockedWhenConfirmationFails() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        motion.suspendStop = true
        clock.advance(to: 0.334)
        perception.send(frame(2, at: 0.334, people: [person(2, at: 0.334, y: 4.5)]))
        await drain()
        perception.send(.interrupted)
        perception.send(frame(3, at: 0.334, people: [person(3, at: 0.334)]))
        await drain()
        XCTAssertEqual(coordinator.state, .failed("AR session interrupted."))
        motion.stopError = true
        motion.suspendStop = false
        motion.releaseStop()
        await drain()
        XCTAssertEqual(coordinator.state, .failed("Rover stop could not be confirmed."))
        let restarted = await coordinator.start()
        XCTAssertFalse(restarted)
        XCTAssertEqual(motion.stops, 2, "An unconfirmed pending stop cannot be treated as confirmed by terminal cleanup")
        XCTAssertEqual(motion.goals.count, 1)
        motion.stopError = false
        let stopped = await coordinator.stop()
        XCTAssertTrue(stopped)
    }

    func testRestartDiscardsOldPendingFramesAndCancelledTimers() async {
        let (coordinator, perception, motion, clock) = setup()
        _ = await coordinator.start()
        perception.send(frame(1, people: [person(1)]))
        await drain()
        motion.suspendStop = true
        clock.advance(to: 0.334)
        perception.send(frame(2, at: 0.334, people: [person(2, at: 0.334, y: 4.5)]))
        await drain()
        perception.send(frame(99, at: 0.334, depth: false))
        await drain()
        let stopping = Task { await coordinator.stop() }
        await drain()
        motion.suspendStop = false
        motion.releaseStop()
        let stopped = await stopping.value
        XCTAssertTrue(stopped)
        let restarted = await coordinator.start()
        XCTAssertTrue(restarted)
        perception.send(frame(1, at: 0.334, people: [person(1, at: 0.334, y: 1.5)]))
        await drain()
        XCTAssertEqual(coordinator.state, .holdingDistance)
        XCTAssertNil(coordinator.perceptionIssue)
        for (index, time) in [0.8, 1.3, 1.8, 2.3, 2.8, 3.3, 3.8, 4.3, 4.8, 5.0, 5.334].enumerated() {
            clock.advance(to: time)
            perception.send(frame(UInt64(index + 2), at: time,
                                  people: [person(UInt64(index + 2), at: time, y: 1.5)]))
            await drain()
        }
        XCTAssertEqual(coordinator.state, .holdingDistance)
        XCTAssertNil(coordinator.perceptionIssue)
        XCTAssertEqual(motion.goals.count, 1)
        _ = await coordinator.stop()
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

    func testNearAgedFrameWatchdogExpiresFromObservationTimestamp() async {
        for searching in [false, true] {
            let (coordinator, perception, motion, clock) = setup()
            motion.suspendNavigation = true
            motion.suspendRotation = true
            _ = await coordinator.start()
            await drain()
            clock.advance(to: 0.49)
            perception.send(frame(1, people: searching ? [] : [person(1)]))
            await drain()
            XCTAssertEqual(searching ? motion.rotations.count : motion.goals.count, 1)
            let stops = motion.stops
            clock.advance(to: 0.5)
            await drain()
            XCTAssertEqual(motion.stops, stops, "The inclusive freshness boundary remains usable")
            clock.advance(to: 0.501)
            await drain()
            XCTAssertEqual(motion.stops, stops + 1, "Watchdog must use frame expiry, not processing time")
            XCTAssertEqual(coordinator.perceptionIssue, .staleFrame)
            motion.releaseNavigation()
            motion.releaseRotation()
            await drain()
            XCTAssertEqual(motion.rotations.count, searching ? 1 : 0)
            _ = await coordinator.stop()
        }
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
        clock.advance(to: 4.999)
        await drain()
        XCTAssertEqual(coordinator.state, .searching)
        clock.advance(to: 5)
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
            clock.advance(to: 5)
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
        perception.send(frame(1, people: [person(1, y: 1.5)]))
        await drain()
        perception.send(frame(2, depth: false))
        await drain()
        clock.advance(to: 1.5)
        perception.send(.frame(FollowFrameBatch(
            frameID: ARFrameID(generation: 1, sequence: 3), timestamp: 1.5,
            pose: nil, depthAvailable: true, people: [],
            trackingQuality: .limited, trackingReason: .initializing)))
        await drain()
        XCTAssertEqual(coordinator.perceptionIssue, .trackingLimited)
        clock.advance(to: 1.9)
        perception.send(.frame(FollowFrameBatch(
            frameID: ARFrameID(generation: 1, sequence: 4), timestamp: 1.9,
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
        var config = FollowMeConfiguration()
        config.stationaryPauseSeconds = 0
        config.departureRangeIncrease = 0
        let coordinator = FollowMeCoordinator(perception: perception, motion: motion, clock: clock,
                                             configuration: config,
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
