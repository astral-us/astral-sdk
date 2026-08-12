import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class SilentSearchCoordinatorTests: XCTestCase {
    private let wallNow: Int64 = 1_786_406_400_000

    func testBothRolesCompleteRealProtocolHandshakeAndWaitForAcknowledgedStart() async throws {
        let opticalA = FakeSilentSearchOpticalExchange()
        let opticalB = FakeSilentSearchOpticalExchange()
        opticalA.peer = opticalB
        opticalB.peer = opticalA
        let a = SilentSearchTestHarness(optical: opticalA)
        let b = SilentSearchTestHarness(optical: opticalB)
        a.clock.advance(nanoseconds: wallNow * 1_000_000)
        b.clock.advance(nanoseconds: wallNow * 1_000_000)
        let coordinatorA = try await calibratedCoordinator(a, role: .a)
        let coordinatorB = try await calibratedCoordinator(b, role: .b)

        XCTAssertTrue(coordinatorA.startHandshake())
        XCTAssertTrue(coordinatorB.startHandshake())
        await eventually { coordinatorA.phase == .waitingForSearch && coordinatorB.phase == .waitingForSearch }

        XCTAssertEqual(opticalA.presentedPayloads.count, 2)
        XCTAssertEqual(opticalB.presentedPayloads.count, 2)
        XCTAssertEqual(coordinatorA.phase, .waitingForSearch)
        a.clock.advance(nanoseconds: 34_999_000_000)
        b.clock.advance(nanoseconds: 34_999_000_000)
        await taskTurn()
        XCTAssertEqual(coordinatorA.phase, .waitingForSearch)

        a.clock.advance(nanoseconds: 1_000_000)
        b.clock.advance(nanoseconds: 1_000_000)
        await eventually { coordinatorA.phase == .searching && coordinatorB.phase == .searching }
    }

    func testRoverBAdoptsValidatedOfferMissionAndRejectsAnotherMissionAfterBinding() async throws {
        let opticalA = FakeSilentSearchOpticalExchange()
        let opticalB = FakeSilentSearchOpticalExchange()
        opticalA.peer = opticalB
        opticalB.peer = opticalA
        let a = SilentSearchTestHarness(optical: opticalA)
        let b = SilentSearchTestHarness(optical: opticalB)
        a.clock.advance(nanoseconds: wallNow * 1_000_000)
        b.clock.advance(nanoseconds: wallNow * 1_000_000)
        let coordinatorA = try await calibratedCoordinator(a, role: .a, label: "table", duration: 240)
        let coordinatorB = try await calibratedCoordinator(b, role: .b, label: "chair", duration: 120)
        var adopted: SilentSearchMission?
        coordinatorB.missionDidChange = { adopted = $0 }

        XCTAssertTrue(coordinatorA.startHandshake())
        XCTAssertTrue(coordinatorB.startHandshake())
        await eventually { adopted != nil }

        XCTAssertEqual(coordinatorB.mission?.id, coordinatorA.mission?.id)
        XCTAssertEqual(coordinatorB.mission?.targetLabel, "table")
        XCTAssertEqual(coordinatorB.mission?.searchDurationSeconds, 240)
        XCTAssertEqual(adopted, coordinatorB.mission)

        await eventually { coordinatorB.phase == .waitingForSearch }
    }

    func testTrackingRecoveryRecreatesWaitingForSearchSleepAndStartsWhenExpired() async throws {
        let opticalA = FakeSilentSearchOpticalExchange()
        let opticalB = FakeSilentSearchOpticalExchange()
        opticalA.peer = opticalB
        opticalB.peer = opticalA
        let a = SilentSearchTestHarness(optical: opticalA)
        let b = SilentSearchTestHarness(optical: opticalB)
        a.clock.advance(nanoseconds: wallNow * 1_000_000)
        b.clock.advance(nanoseconds: wallNow * 1_000_000)
        let coordinatorA = try await calibratedCoordinator(a, role: .a)
        let coordinatorB = try await calibratedCoordinator(b, role: .b)
        XCTAssertTrue(coordinatorA.startHandshake())
        XCTAssertTrue(coordinatorB.startHandshake())
        await eventually { coordinatorA.phase == .waitingForSearch }

        a.safety.send(.trackingLimited(generation: 1))
        await eventually { a.motion.stopCount == 1 }
        a.clock.advance(nanoseconds: 35_000_000_000)
        a.safety.send(.trackingNormal(generation: 1))
        await eventually { coordinatorA.phase == .searching }
    }

    func testOpticalTimeoutRetryReusesIdenticalPayloadAndAbortStops() async throws {
        let harness = SilentSearchTestHarness()
        harness.clock.advance(nanoseconds: wallNow * 1_000_000)
        harness.optical.suspendPresent = true
        let coordinator = try await calibratedCoordinator(harness, role: .a)

        XCTAssertTrue(coordinator.startHandshake())
        await eventually { harness.optical.presentedPayloads.count == 1 }
        harness.clock.advance(nanoseconds: 30_000_000_000)
        await eventually { coordinator.diagnostic == .opticalTimedOut }
        let first = try XCTUnwrap(harness.optical.presentedPayloads.first)

        XCTAssertTrue(coordinator.retryOpticalExchange())
        await eventually { harness.optical.presentedPayloads.count == 2 }
        XCTAssertEqual(harness.optical.presentedPayloads[1], first)
        await coordinator.abort()
        XCTAssertEqual(coordinator.phase, .terminal(.operatorAborted))
        XCTAssertEqual(harness.motion.stopCount, 1)
    }

    func testClockMismatchAndLateAcknowledgementAreHandledByRealSession() async throws {
        let opticalA = FakeSilentSearchOpticalExchange()
        let opticalB = FakeSilentSearchOpticalExchange()
        opticalA.peer = opticalB
        opticalB.peer = opticalA
        let a = SilentSearchTestHarness(optical: opticalA)
        let b = SilentSearchTestHarness(optical: opticalB)
        a.clock.advance(nanoseconds: wallNow * 1_000_000)
        b.clock.advance(nanoseconds: (wallNow + 2_001) * 1_000_000)
        let coordinatorA = try await calibratedCoordinator(a, role: .a)
        let coordinatorB = try await calibratedCoordinator(b, role: .b)
        XCTAssertTrue(coordinatorA.startHandshake())
        XCTAssertTrue(coordinatorB.startHandshake())
        await eventually {
            coordinatorB.phase == .terminal(.protocolFailure(.clockDisagreement))
        }

        XCTAssertEqual(coordinatorB.phase, .terminal(.protocolFailure(.clockDisagreement)))
    }

    func testLateAcknowledgementCausesANewSearchCommit() async throws {
        let harness = SilentSearchTestHarness()
        harness.clock.advance(nanoseconds: wallNow * 1_000_000)
        let coordinator = try await calibratedCoordinator(harness, role: .a)
        XCTAssertTrue(coordinator.startHandshake())
        await eventually { harness.optical.presentedPayloads.count == 1 }

        var roverB = OpticalProtocolSession(context: OpticalProtocolContext(
            missionID: try mission(role: .a).id,
            markerID: "SILENT_SEARCH_01",
            localRole: .b
        ))
        let offer = harness.optical.presentedPayloads[0]
        try roverB.receive(offer, at: wallNow)
        let accept = try roverB.prepareOutgoing(body: .accept(AcceptBody(
            offerHash: OpticalMessageCodec().messageLinkHash(for: offer),
            roverBWallTimeMilliseconds: wallNow
        )), at: wallNow)
        harness.optical.sendToScanner(accept)
        await eventually { harness.optical.presentedPayloads.count == 2 }

        let firstCommit = harness.optical.presentedPayloads[1]
        try roverB.receive(firstCommit, at: wallNow)
        let acknowledgement = try roverB.prepareOutgoing(body: .searchAck(HashAcknowledgementBody(
            hash: OpticalMessageCodec().messageLinkHash(for: firstCommit)
        )), at: wallNow)
        harness.clock.advance(nanoseconds: 30_001_000_000)
        harness.optical.sendToScanner(acknowledgement)
        await eventually { harness.optical.presentedPayloads.count == 3 }

        let replacement = harness.optical.presentedPayloads[2]
        XCTAssertNotEqual(replacement, firstCommit)
        XCTAssertEqual(try OpticalMessageCodec().decode(replacement).sequence, 3)
        XCTAssertEqual(coordinator.phase, .handshake(.scanning))
    }

    func testLimitedTrackingStopsBeforeRecoveryReplanAndInvalidatesAfterFiveSeconds() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 7)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission(role: .a))
        XCTAssertTrue(coordinator.startCalibration())
        harness.calibration.send(.accepted(try frame(generation: 7)))
        await eventually { coordinator.phase == .handshake(.ready) }
        try coordinator.transition(to: .waitingForSearch)
        try coordinator.transition(to: .searching)
        harness.motion.currentMissionPath = [try XCTUnwrap(MissionPoint(x: -1, y: 2))]

        harness.safety.send(.trackingLimited(generation: 7))
        await eventually { harness.motion.stopCount == 1 }
        XCTAssertTrue(harness.motion.navigationRequests.isEmpty)
        harness.clock.advance(nanoseconds: 4_999_000_000)
        harness.safety.send(.trackingNormal(generation: 7))
        await eventually { harness.motion.navigationRequests.count == 1 }
        XCTAssertEqual(harness.motion.navigationRequests.first?.0, MissionPoint(x: -1, y: 2))
        XCTAssertEqual(harness.motion.navigationRequests.first?.1, .sectorConstrained(.west))

        harness.safety.send(.trackingLimited(generation: 7))
        await eventually { harness.motion.stopCount == 2 }
        harness.clock.advance(nanoseconds: 5_000_000_000)
        await eventually { coordinator.phase == .terminal(.calibrationInvalidated) }
        XCTAssertNil(coordinator.sharedFrame)
    }

    func testLimitedTrackingDuringCalibrationRemainsCalibratingUntilStopped() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 7)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())

        harness.safety.send(.trackingLimited(generation: 7))
        harness.clock.advance(nanoseconds: 5_000_000_000)
        await taskTurn()

        XCTAssertEqual(coordinator.phase, .calibrating)
        XCTAssertNil(coordinator.sharedFrame)
        await coordinator.stop()
        XCTAssertEqual(coordinator.phase, .terminal(.operatorStopped))
    }

    func testTrackingRecoveryCapturesNavigationBeforeStopClearsPath() async throws {
        let harness = SilentSearchTestHarness()
        let goal = try XCTUnwrap(MissionPoint(x: -1, y: 2))
        _ = try await searchingCoordinator(harness, deadline: 100_000_000_000)
        harness.motion.currentMissionPath = [goal]
        harness.motion.clearPathOnStop = true

        harness.safety.send(.trackingLimited(generation: 1))
        await eventually { harness.motion.stopCount == 2 }
        harness.safety.send(.trackingNormal(generation: 1))
        await eventually { harness.motion.navigationRequests.contains { $0.0 == goal } }

        XCTAssertTrue(harness.motion.currentMissionPath.isEmpty)
    }

    func testTrackingRecoveryReturnsToFixedStagingWhenInterruptedPathWasCleared() async throws {
        let harness = SilentSearchTestHarness()
        harness.motion.suspendNavigation = true
        let coordinator = try await searchingCoordinator(harness, role: .b, deadline: 100_000_000_000)
        await eventually { coordinator.phase == .returning }
        let staging = SilentSearchGeometry.rendezvousPoint(for: .b)
        harness.motion.currentMissionPath = [staging]
        harness.motion.clearPathOnStop = true

        harness.safety.send(.trackingLimited(generation: 1))
        await eventually { harness.motion.stopCount == 3 }
        harness.safety.send(.trackingNormal(generation: 1))
        await eventually { harness.motion.navigationRequests.count == 2 }

        XCTAssertEqual(harness.motion.navigationRequests.last?.0, staging)
        XCTAssertEqual(harness.motion.navigationRequests.last?.1, .sectorConstrained(.east))
    }

    func testTrackingRecoveryResumesInterruptedInitialSearchScan() async throws {
        let harness = SilentSearchTestHarness()
        harness.targetObserver.suspend = true
        let coordinator = try await searchingCoordinator(harness, deadline: 100_000_000_000)
        harness.clock.advance(nanoseconds: 750_000_000)
        await eventually { harness.targetObserver.deadlines.count == 1 }

        harness.safety.send(.trackingLimited(generation: 1))
        await eventually { harness.motion.stopCount == 2 }
        harness.targetObserver.suspend = false
        harness.safety.send(.trackingNormal(generation: 1))
        harness.clock.advance(nanoseconds: 750_000_000)
        await eventually { harness.targetObserver.deadlines.count == 2 }
        harness.clock.advance(nanoseconds: 2_000_000_000)
        await eventually { coordinator.phase == .rendezvous(.waiting) }
    }

    func testSearchDeadlineDoesNotReturnWhileTrackingIsLimited() async throws {
        let harness = SilentSearchTestHarness()
        harness.targetObserver.suspend = true
        let coordinator = try await searchingCoordinator(harness, deadline: 1_000_000_000)

        harness.safety.send(.trackingLimited(generation: 1))
        await eventually { harness.motion.stopCount == 2 }
        harness.clock.advance(nanoseconds: 1_000_000_000)
        await taskTurn()

        XCTAssertEqual(coordinator.phase, .searching)
        XCTAssertTrue(harness.motion.navigationRequests.isEmpty)

        harness.safety.send(.trackingNormal(generation: 1))
        await eventually { coordinator.phase == .rendezvous(.waiting) }
        XCTAssertEqual(harness.motion.navigationRequests.map(\.0), [SilentSearchGeometry.rendezvousPoint(for: .a)])
    }

    func testTrackingLossWhileDeadlineIsStoppingCannotStartReturn() async throws {
        let harness = SilentSearchTestHarness()
        harness.targetObserver.suspend = true
        let coordinator = try await searchingCoordinator(harness, deadline: 1_000_000_000)
        harness.motion.suspendStop = true

        harness.clock.advance(nanoseconds: 1_000_000_000)
        await eventually { harness.motion.stopCount == 2 }
        harness.safety.send(.trackingLimited(generation: 1))
        await eventually { harness.motion.stopCount == 3 }
        harness.motion.suspendStop = false
        harness.motion.resumeStops()
        await taskTurn()

        XCTAssertEqual(coordinator.phase, .searching)
        XCTAssertTrue(harness.motion.navigationRequests.isEmpty)

        harness.safety.send(.trackingNormal(generation: 1))
        await eventually { coordinator.phase == .rendezvous(.waiting) }
    }

    func testTrackingRecoveryBeforeSearchDeadlineRecreatesWaitAndResumesSearch() async throws {
        let harness = SilentSearchTestHarness()
        harness.targetObserver.suspend = true
        let coordinator = try await searchingCoordinator(harness, deadline: 4_000_000_000)

        harness.safety.send(.trackingLimited(generation: 1))
        await eventually { harness.motion.stopCount == 2 }
        await eventually { !harness.clock.pendingDeadlines.contains(4_000_000_000) }

        harness.clock.advance(nanoseconds: 1_000_000_000)
        harness.safety.send(.trackingNormal(generation: 1))
        await eventually {
            harness.clock.pendingDeadlines.contains(4_000_000_000) &&
                harness.targetObserver.deadlines.count == 1
        }

        XCTAssertEqual(coordinator.phase, .searching)
        XCTAssertTrue(harness.motion.navigationRequests.isEmpty)

        harness.clock.advance(nanoseconds: 3_000_000_000)
        await eventually { coordinator.phase == .rendezvous(.waiting) }
    }

    func testTrackingRecoveryTimeoutInvalidationWinsSearchDeadlineAndNormalRecoveryRace() async throws {
        let harness = SilentSearchTestHarness()
        harness.targetObserver.suspend = true
        let coordinator = try await searchingCoordinator(harness, deadline: 5_000_000_000)

        harness.safety.send(.trackingLimited(generation: 1))
        await eventually { harness.motion.stopCount == 2 }
        harness.clock.advance(nanoseconds: 5_000_000_000)
        harness.safety.send(.trackingNormal(generation: 1))
        await eventually { coordinator.phase == .terminal(.calibrationInvalidated) }

        XCTAssertNil(coordinator.sharedFrame)
        XCTAssertTrue(harness.motion.navigationRequests.isEmpty)
    }

    func testPartnerDeadlineWaitIsSuspendedUntilNormalTrackingRecovers() async throws {
        let harness = SilentSearchTestHarness()
        let coordinator = try await searchingCoordinator(harness, deadline: -56_000_000_000)
        await eventually { coordinator.phase == .rendezvous(.waiting) }
        await eventually { harness.clock.pendingDeadlines.contains(4_000_000_000) }

        harness.safety.send(.trackingLimited(generation: 1))
        await eventually { !harness.clock.pendingDeadlines.contains(4_000_000_000) }
        harness.clock.advance(nanoseconds: 4_000_000_000)
        await taskTurn()

        XCTAssertEqual(coordinator.phase, .rendezvous(.waiting))

        harness.safety.send(.trackingNormal(generation: 1))
        await eventually { coordinator.phase == .terminal(.partnerTimeout) }
    }

    func testTrackingRecoveryInvalidationWinsEqualPartnerDeadlineAndNormalRecoveryRace() async throws {
        let harness = SilentSearchTestHarness()
        let coordinator = try await searchingCoordinator(harness, deadline: -55_000_000_000)
        await eventually { coordinator.phase == .rendezvous(.waiting) }
        await eventually { harness.clock.pendingDeadlines.contains(5_000_000_000) }

        harness.safety.send(.trackingLimited(generation: 1))
        await eventually { !harness.clock.pendingDeadlines.contains(5_000_000_000) }
        harness.clock.advance(nanoseconds: 5_000_000_000)
        harness.safety.send(.trackingNormal(generation: 1))
        await eventually { coordinator.phase == .terminal(.calibrationInvalidated) }

        XCTAssertNil(coordinator.sharedFrame)
        XCTAssertNotEqual(coordinator.phase, .terminal(.partnerTimeout))
    }

    func testGenerationChangeAlwaysStopsAndInvalidatesCalibration() async throws {
        let harness = SilentSearchTestHarness()
        let coordinator = try await calibratedCoordinator(harness, role: .a, generation: 3)

        harness.safety.send(.generationChanged)
        await eventually { coordinator.phase == .terminal(.calibrationInvalidated) }

        XCTAssertEqual(harness.motion.stopCount, 1)
        XCTAssertNil(coordinator.sharedFrame)
    }

    func testSearchPerformsInitialSettledScanThenVisitsCandidatesInExplorerOrder() async throws {
        let harness = SilentSearchTestHarness()
        let first = candidate("frontier_2", x: -2, y: 0)
        let second = candidate("frontier_1", x: -1, y: 0)
        harness.explorer.selections = [.candidate(first), .candidate(second), .exhausted]
        harness.targetObserver.results = [.pending, .pending, .pending]
        let coordinator = try await searchingCoordinator(harness, deadline: 100_000_000_000)

        await eventually { harness.motion.stopCount == 1 }
        XCTAssertTrue(harness.targetObserver.deadlines.isEmpty)
        harness.clock.advance(nanoseconds: 749_000_000)
        await taskTurn()
        XCTAssertTrue(harness.targetObserver.deadlines.isEmpty)

        harness.clock.advance(nanoseconds: 1_000_000)
        await eventually { harness.motion.navigationRequests.count == 1 }
        XCTAssertEqual(harness.motion.navigationRequests[0].0, first.missionCentroid)
        XCTAssertEqual(harness.motion.navigationRequests[0].1, .sectorConstrained(.west))
        XCTAssertTrue(harness.explorer.visitedIDs.isEmpty)

        harness.clock.advance(nanoseconds: 750_000_000)
        await eventually { harness.motion.navigationRequests.count == 2 }
        XCTAssertEqual(harness.explorer.visitedIDs, ["frontier_2"])
        XCTAssertEqual(harness.motion.navigationRequests[1].0, second.missionCentroid)

        harness.clock.advance(nanoseconds: 750_000_000)
        await eventually { coordinator.phase == .rendezvous(.waiting) }
        XCTAssertEqual(harness.explorer.visitedIDs, ["frontier_2", "frontier_1"])
        XCTAssertEqual(harness.motion.navigationRequests.last?.0, SilentSearchGeometry.rendezvousPoint(for: .a))
        XCTAssertEqual(harness.motion.navigationRequests.last?.1, .sectorConstrained(.west))
    }

    func testSettledScanConsumesMoreThanThreeFramesUntilConfirmationWithoutMoving() async throws {
        let harness = SilentSearchTestHarness()
        let target = TargetConfirmation(
            label: "chair", coordinate: MissionPoint(x: -1, y: 2)!, sampleCount: 3, meanConfidence: 0.96
        )
        harness.targetObserver.results = [.pending, .pending, .pending, .pending, .confirmed(target)]
        harness.targetObserver.pendingFrameInterval = 100_000_000
        let coordinator = try await searchingCoordinator(harness, deadline: 100_000_000_000)

        harness.clock.advance(nanoseconds: 750_000_000)
        await eventually { coordinator.phase == .rendezvous(.waiting) }

        XCTAssertEqual(harness.targetObserver.deadlines.count, 5)
        XCTAssertEqual(Set(harness.targetObserver.deadlines), [2_750_000_000])
        XCTAssertEqual(harness.motion.navigationRequests.map(\.0), [SilentSearchGeometry.rendezvousPoint(for: .a)])
        XCTAssertEqual(coordinator.targetConfirmation, target)
    }

    func testSettledScanStopsAtTwoSecondWindowAndContinuesSearch() async throws {
        let harness = SilentSearchTestHarness()
        harness.targetObserver.suspend = true
        let coordinator = try await searchingCoordinator(harness, deadline: 100_000_000_000)

        harness.clock.advance(nanoseconds: 750_000_000)
        await eventually { harness.targetObserver.deadlines == [2_750_000_000] }
        harness.clock.advance(nanoseconds: 2_000_000_000)
        harness.targetObserver.resume()
        await eventually { coordinator.phase == .rendezvous(.waiting) }

        XCTAssertEqual(harness.targetObserver.deadlines, [2_750_000_000])
    }

    func testCrossSectorTargetReturnsToFixedRoleStagingWithoutReleasingSectorPolicy() async throws {
        let harness = SilentSearchTestHarness()
        let target = TargetConfirmation(
            label: "chair", coordinate: MissionPoint(x: 3, y: 2)!, sampleCount: 3, meanConfidence: 0.95
        )
        harness.targetObserver.result = .confirmed(target)
        let coordinator = try await searchingCoordinator(harness, role: .b, deadline: 100_000_000_000)

        harness.clock.advance(nanoseconds: 750_000_000)
        await eventually { coordinator.phase == .rendezvous(.waiting) }

        XCTAssertEqual(coordinator.targetConfirmation, target)
        XCTAssertEqual(harness.motion.navigationRequests.map(\.0), [SilentSearchGeometry.rendezvousPoint(for: .b)])
        XCTAssertEqual(harness.motion.navigationRequests.map(\.1), [.sectorConstrained(.east)])
        XCTAssertFalse(harness.motion.navigationRequests.contains { $0.1 == .unrestrictedConvergence })
        XCTAssertGreaterThan(target.coordinate.x, SilentSearchGeometry.centerBandHalfWidth)
    }

    func testTargetConfirmedAfterArrivalMarksCandidateVisitedBeforeReturn() async throws {
        let harness = SilentSearchTestHarness()
        let visited = candidate("frontier_1", x: -2, y: 0)
        let target = TargetConfirmation(
            label: "chair", coordinate: MissionPoint(x: -2, y: 0)!, sampleCount: 3, meanConfidence: 0.97
        )
        harness.explorer.selection = .candidate(visited)
        harness.targetObserver.results = [.pending, .pending, .pending, .confirmed(target)]
        let coordinator = try await searchingCoordinator(harness, deadline: 100_000_000_000)

        harness.clock.advance(nanoseconds: 750_000_000)
        await eventually { harness.motion.navigationRequests.count == 1 }
        harness.clock.advance(nanoseconds: 750_000_000)
        await eventually { coordinator.phase == .rendezvous(.waiting) }

        XCTAssertEqual(harness.explorer.visitedIDs, ["frontier_1"])
        XCTAssertEqual(coordinator.targetConfirmation, target)
    }

    func testCandidateNoPathIsRejectedButActiveSafetyFailureIsTerminal() async throws {
        let noPathHarness = SilentSearchTestHarness()
        let blocked = candidate("frontier_1", x: -2, y: 0)
        let unsafe = candidate("frontier_2", x: -3, y: 0)
        noPathHarness.explorer.selections = [.candidate(blocked), .candidate(unsafe)]
        noPathHarness.motion.results = [.failed(.noPath), .failed(.obstacle)]
        let coordinator = try await searchingCoordinator(noPathHarness, deadline: 100_000_000_000)

        noPathHarness.clock.advance(nanoseconds: 750_000_000)
        await eventually { coordinator.phase == .terminal(.motionFailure(.obstacle)) }

        XCTAssertEqual(noPathHarness.explorer.rejections.count, 1)
        XCTAssertEqual(noPathHarness.explorer.rejections.first?.0, "frontier_1")
        XCTAssertEqual(noPathHarness.explorer.rejections.first?.1, .unreachable)
        XCTAssertEqual(noPathHarness.motion.navigationRequests.count, 2)
    }

    func testExhaustionReturnsAndUnsafeFixedStagingFailsWithoutAlternate() async throws {
        let harness = SilentSearchTestHarness()
        harness.explorer.selection = .exhausted
        harness.motion.result = .failed(.pathRejected(.outsideSector(pointIndex: 2)))
        let coordinator = try await searchingCoordinator(harness, deadline: 100_000_000_000)

        harness.clock.advance(nanoseconds: 750_000_000)
        await eventually {
            coordinator.phase == .terminal(.motionFailure(.pathRejected(.outsideSector(pointIndex: 2))))
        }

        XCTAssertEqual(harness.motion.navigationRequests.count, 1)
        XCTAssertEqual(harness.motion.navigationRequests[0].0, SilentSearchGeometry.rendezvousPoint(for: .a))
        XCTAssertEqual(harness.motion.navigationRequests[0].1, .sectorConstrained(.west))
    }

    func testDeadlineAwaitsStopBeforeReturningToFixedStaging() async throws {
        let harness = SilentSearchTestHarness()
        harness.targetObserver.suspend = true
        let coordinator = try await searchingCoordinator(harness, deadline: 1_000_000_000)

        harness.clock.advance(nanoseconds: 750_000_000)
        await eventually { harness.targetObserver.deadlines == [1_000_000_000] }
        harness.motion.suspendStop = true
        harness.clock.advance(nanoseconds: 250_000_000)
        await eventually { harness.motion.stopCount == 2 }

        XCTAssertEqual(coordinator.phase, .searching)
        XCTAssertTrue(harness.motion.navigationRequests.isEmpty)
        harness.motion.resumeStops()
        await eventually { coordinator.phase == .rendezvous(.waiting) }

        XCTAssertEqual(harness.motion.navigationRequests.count, 1)
        XCTAssertEqual(harness.motion.navigationRequests[0].0, SilentSearchGeometry.rendezvousPoint(for: .a))
        XCTAssertEqual(harness.motion.navigationRequests[0].1, .sectorConstrained(.west))
    }

    func testCalibrationRequiresCompleteReadiness() async throws {
        let harness = SilentSearchTestHarness()
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())

        XCTAssertFalse(coordinator.startCalibration())
        XCTAssertEqual(coordinator.phase, .setup)
        XCTAssertEqual(coordinator.diagnostic, .notReady([.tracking, .detector, .commandLink]))
        XCTAssertTrue(harness.calibration.requests.isEmpty)

        harness.readiness.snapshot = SilentSearchReadiness(
            tracking: .normal(sessionGeneration: 9),
            detectorLoaded: true,
            commandLinkAvailable: true
        )
        coordinator.refreshReadiness()

        XCTAssertTrue(coordinator.startCalibration())
        XCTAssertEqual(coordinator.phase, .calibrating)
        XCTAssertEqual(harness.calibration.requests.count, 1)
        XCTAssertEqual(harness.calibration.requests.first?.markerID, "SILENT_SEARCH_01")
        XCTAssertEqual(harness.calibration.requests.first?.generation, 9)
    }

    func testCalibrationProgressRejectionAndAcceptanceUpdatePublicState() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())

        harness.calibration.send(.progress(acceptedFrameCount: 2))
        await eventually { coordinator.calibrationProgress == 2 }
        XCTAssertEqual(coordinator.calibrationProgress, 2)

        harness.calibration.send(.rejected(.headingDeviationExceeded))
        await eventually { coordinator.diagnostic == .calibrationRejected(.headingDeviationExceeded) }
        XCTAssertEqual(coordinator.phase, .calibrating)
        XCTAssertEqual(coordinator.diagnostic, .calibrationRejected(.headingDeviationExceeded))

        let wrongGeneration = try XCTUnwrap(SharedMissionFrame(
            localOrigin: Vec2(1, 2), localNorthHeading: 0.3, sessionGeneration: 5
        ))
        harness.calibration.send(.accepted(wrongGeneration))
        await eventually { coordinator.diagnostic == .calibrationRejected(.generationMismatch) }
        XCTAssertEqual(coordinator.phase, .calibrating)
        XCTAssertEqual(coordinator.diagnostic, .calibrationRejected(.generationMismatch))

        let frame = try XCTUnwrap(SharedMissionFrame(
            localOrigin: Vec2(1, 2), localNorthHeading: 0.3, sessionGeneration: 4
        ))
        harness.calibration.send(.accepted(frame))
        await eventually { coordinator.phase == .handshake(.ready) }

        XCTAssertEqual(coordinator.sharedFrame, frame)
        XCTAssertEqual(coordinator.phase, .handshake(.ready))
        XCTAssertNil(coordinator.diagnostic)

        let calibrationEvents = harness.events.entries.filter { $0.event.hasPrefix("silent_search_calibration") }
        XCTAssertEqual(calibrationEvents.map(\.event), [
            "silent_search_calibration_progress",
            "silent_search_calibration_rejected",
            "silent_search_calibration_rejected",
            "silent_search_calibration_accepted",
        ])
        XCTAssertEqual(calibrationEvents.last?.fields["mission"], coordinator.mission?.id.uuidString.lowercased())
        XCTAssertEqual(calibrationEvents.last?.fields["marker"], "SILENT_SEARCH_01")
        XCTAssertEqual(calibrationEvents.last?.fields["role"], "a")
        XCTAssertEqual(calibrationEvents.last?.fields["sample_count"], "3")
    }

    func testSafetyAndTerminalTelemetryAreStructuredAndContextual() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 7)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        harness.calibration.send(.accepted(try frame(generation: 7)))
        await eventually { coordinator.phase == .handshake(.ready) }

        harness.safety.send(.reactiveSafetyFailed)
        await eventually { coordinator.phase == .terminal(.safetyFailure(.reactiveSafety)) }

        let safety = try XCTUnwrap(harness.events.entries.first { $0.event == "silent_search_safety" })
        XCTAssertEqual(safety.fields["reason"], "reactive_safety_failed")
        let terminal = try XCTUnwrap(harness.events.entries.first { $0.event == "silent_search_terminal" })
        XCTAssertEqual(terminal.fields["result"], "safety_reactive_safety")
        XCTAssertEqual(terminal.fields["role"], "a")
        XCTAssertNil(terminal.fields["payload"])
        XCTAssertNil(terminal.fields["image"])
    }

    func testTransportFailureTerminatesWhileOpticalExchangeIsWaiting() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 7)
        harness.optical.suspendPresent = true
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        harness.calibration.send(.accepted(try frame(generation: 7)))
        await eventually { coordinator.phase == .handshake(.ready) }
        XCTAssertTrue(coordinator.startHandshake())
        await eventually { coordinator.phase == .handshake(.presenting) }

        harness.safety.send(.transportFailed)

        await eventually { coordinator.phase == .terminal(.safetyFailure(.transport)) }
        XCTAssertEqual(harness.motion.stopCount, 1)
    }

    func testTransitionTableAcceptsLegalEdgesAndRejectsIllegalEdges() throws {
        let coordinator = SilentSearchTestHarness().coordinator()

        XCTAssertThrowsError(try coordinator.transition(to: .searching)) {
            XCTAssertEqual($0 as? SilentSearchTransitionError, .illegal(from: .setup, to: .searching))
        }
        XCTAssertEqual(coordinator.phase, .setup)

        try coordinator.transition(to: .calibrating)
        try coordinator.transition(to: .handshake(.ready))
        try coordinator.transition(to: .handshake(.scanning))
        try coordinator.transition(to: .waitingForSearch)
        try coordinator.transition(to: .searching)
        try coordinator.transition(to: .returning)
        try coordinator.transition(to: .rendezvous(.ready))
        try coordinator.transition(to: .waitingForConvergence)
        try coordinator.transition(to: .converging)
        try coordinator.transition(to: .terminal(.success))
        try coordinator.transition(to: .setup)

        XCTAssertEqual(coordinator.phase, .setup)
    }

    func testMissionRejectsInvalidSetupValues() {
        XCTAssertNil(SilentSearchMission(
            role: .a, targetLabel: " chair", searchDurationSeconds: 120, markerID: "SILENT_SEARCH_01"
        ))
        XCTAssertNil(SilentSearchMission(
            role: .a, targetLabel: "chair", searchDurationSeconds: 0, markerID: "SILENT_SEARCH_01"
        ))
        XCTAssertNil(SilentSearchMission(
            role: .a, targetLabel: "chair", searchDurationSeconds: 120, markerID: "not canonical"
        ))
    }

    func testStopAwaitsMotionBeforePublishingStableTerminalState() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 1)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        harness.motion.onStop = { XCTAssertNotEqual(coordinator.phase, .terminal(.operatorStopped)) }

        await coordinator.stop()

        XCTAssertEqual(harness.motion.stopCount, 1)
        XCTAssertEqual(coordinator.phase, .terminal(.operatorStopped))
        XCTAssertEqual(harness.events.entries.last?.event, "silent_search_phase_transition")

        await coordinator.abort()
        XCTAssertEqual(harness.motion.stopCount, 1)
        XCTAssertEqual(coordinator.phase, .terminal(.operatorStopped))
    }

    func testAbortCancelsCalibrationAndStopsBeforeTerminal() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 2)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())

        await coordinator.abort()

        XCTAssertEqual(harness.calibration.cancelCount, 1)
        XCTAssertEqual(harness.motion.stopCount, 1)
        XCTAssertEqual(coordinator.phase, .terminal(.operatorAborted))
    }

    func testResetClearsMissionCalibrationAndTerminalResult() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 3)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        await coordinator.stop()

        await coordinator.reset()

        XCTAssertEqual(coordinator.phase, .setup)
        XCTAssertNil(coordinator.mission)
        XCTAssertNil(coordinator.sharedFrame)
        XCTAssertEqual(coordinator.calibrationProgress, 0)
        XCTAssertNil(coordinator.diagnostic)
    }

    func testManualClockResumesOnlyReachedDeadlinesAndSafetyStreamIsMulticast() async throws {
        let harness = SilentSearchTestHarness()
        var resumed: [String] = []
        let first = Task { try await harness.clock.sleep(until: 10); resumed.append("first") }
        let second = Task { try await harness.clock.sleep(until: 20); resumed.append("second") }
        let cancelled = Task {
            do {
                try await harness.clock.sleep(until: 30)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await eventually { Set(harness.clock.pendingDeadlines) == [10, 20, 30] }
        cancelled.cancel()
        let cancellationObserved = await cancelled.value
        XCTAssertTrue(cancellationObserved)

        harness.clock.advance(nanoseconds: 10)
        await taskTurn()
        XCTAssertEqual(resumed, ["first"])

        let leftTask = Task {
            var iterator = harness.safety.events().makeAsyncIterator()
            return await iterator.next()
        }
        let rightTask = Task {
            var iterator = harness.safety.events().makeAsyncIterator()
            return await iterator.next()
        }
        await taskTurn()
        harness.safety.send(.operatorStop)
        let left = await leftTask.value
        let right = await rightTask.value
        XCTAssertEqual(left, .operatorStop)
        XCTAssertEqual(right, .operatorStop)

        harness.clock.advance(nanoseconds: 10)
        _ = try await (first.value, second.value)
    }

    private func calibratedCoordinator(
        _ harness: SilentSearchTestHarness,
        role: RoverRole,
        generation: UInt64 = 1,
        label: String = "chair",
        duration: UInt32 = 120
    ) async throws -> SilentSearchCoordinator {
        harness.readiness.snapshot = .ready(sessionGeneration: generation)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission(role: role, label: label, duration: duration))
        XCTAssertTrue(coordinator.startCalibration())
        harness.calibration.send(.accepted(try frame(generation: generation)))
        await eventually { coordinator.phase == .handshake(.ready) }
        return coordinator
    }

    private func searchingCoordinator(
        _ harness: SilentSearchTestHarness,
        role: RoverRole = .a,
        deadline: SilentSearchInstant
    ) async throws -> SilentSearchCoordinator {
        let coordinator = try await calibratedCoordinator(harness, role: role)
        try coordinator.transition(to: .waitingForSearch)
        try coordinator.transition(to: .searching)
        coordinator.startSearch(until: deadline)
        await eventually { harness.motion.stopCount == 1 }
        return coordinator
    }

    private func candidate(_ id: String, x: Double, y: Double) -> SectorFrontierCandidate {
        let point = MissionPoint(x: x, y: y)!
        return SectorFrontierCandidate(
            stableID: id,
            localCentroid: Vec2(x, y),
            missionCentroid: point,
            width: 1,
            status: .available,
            rejectionReason: nil,
            safePath: [Vec2(x, y)],
            pathLength: hypot(x, y)
        )
    }

    private func frame(generation: UInt64) throws -> SharedMissionFrame {
        try XCTUnwrap(SharedMissionFrame(
            localOrigin: Vec2(0, 0), localNorthHeading: 0, sessionGeneration: generation
        ))
    }

    private func mission(role: RoverRole = .a, label: String = "chair", duration: UInt32 = 120) throws -> SilentSearchMission {
        try XCTUnwrap(SilentSearchMission(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            role: role,
            targetLabel: label,
            searchDurationSeconds: duration,
            markerID: "SILENT_SEARCH_01"
        ))
    }

    private func taskTurn() async {
        await Task.yield()
        await Task.yield()
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
    }
}
