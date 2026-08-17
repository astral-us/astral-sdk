import CoreVideo
import simd
import XCTest
import RoverNav
@testable import PhroverKit

@MainActor
final class SilentSearchCoordinatorTests: XCTestCase {
    private let wallNow: Int64 = 1_786_406_400_000

    func testHandshakePublishesOneManualActionAndCreatesOfferAtGenerateTime() async throws {
        let a = SilentSearchTestHarness()
        let b = SilentSearchTestHarness()
        a.clock.advance(nanoseconds: wallNow * 1_000_000)
        b.clock.advance(nanoseconds: wallNow * 1_000_000)
        let coordinatorA = try await calibratedCoordinator(a, role: .a)
        let coordinatorB = try await calibratedCoordinator(b, role: .b)

        XCTAssertTrue(coordinatorA.startHandshake())
        XCTAssertTrue(coordinatorB.startHandshake())
        await eventually {
            coordinatorA.pendingOpticalAction == .generate(messageKind: .offer, isRetransmission: false) &&
                coordinatorB.pendingOpticalAction == .scan(expectedMessageKind: .offer)
        }

        XCTAssertTrue(a.optical.presentedPayloads.isEmpty)
        XCTAssertFalse(coordinatorA.beginPendingQRScan())
        XCTAssertFalse(coordinatorB.generatePendingQR())
        a.clock.advance(nanoseconds: 2_000_000_000)
        XCTAssertTrue(coordinatorA.generatePendingQR())
        await eventually { a.optical.presentedPayloads.count == 1 }
        XCTAssertEqual(
            try OpticalMessageCodec().decode(a.optical.presentedPayloads[0]).timestampMilliseconds,
            wallNow + 2_000
        )
    }

    func testScanCancellationReturnsToSamePendingActionWithoutProtocolMutation() async throws {
        let harness = SilentSearchTestHarness()
        let coordinator = try await calibratedCoordinator(harness, role: .b)
        XCTAssertTrue(coordinator.startHandshake())
        await eventually { coordinator.pendingOpticalAction == .scan(expectedMessageKind: .offer) }

        XCTAssertTrue(coordinator.beginPendingQRScan())
        await eventually { coordinator.phase == .handshake(.scanning) }
        XCTAssertTrue(coordinator.cancelQRScan())
        XCTAssertFalse(coordinator.cancelQRScan())
        await eventually { coordinator.pendingOpticalAction == .scan(expectedMessageKind: .offer) }

        XCTAssertTrue(harness.optical.presentedPayloads.isEmpty)
        XCTAssertNil(coordinator.diagnostic)
    }

    func testScanTimeoutOffersCachedOutboundGenerationThenReturnsToScan() async throws {
        let harness = SilentSearchTestHarness()
        harness.clock.advance(nanoseconds: wallNow * 1_000_000)
        let coordinator = try await calibratedCoordinator(harness, role: .a)
        XCTAssertTrue(coordinator.startHandshake())
        await eventually { coordinator.pendingOpticalAction == .generate(messageKind: .offer, isRetransmission: false) }
        XCTAssertTrue(coordinator.generatePendingQR())
        await eventually { coordinator.pendingOpticalAction == .scan(expectedMessageKind: .accept) }
        let offer = try XCTUnwrap(harness.optical.presentedPayloads.first)
        XCTAssertTrue(coordinator.beginPendingQRScan())
        await eventually { coordinator.phase == .handshake(.scanning) }
        await eventually { harness.clock.pendingDeadlines.contains(harness.clock.monotonicNow + 30_000_000_000) }

        harness.clock.advance(nanoseconds: 30_000_000_000)
        await eventually {
            coordinator.pendingOpticalAction == .generate(messageKind: .offer, isRetransmission: true)
        }
        XCTAssertEqual(coordinator.pendingOpticalAction, .generate(messageKind: .offer, isRetransmission: true))
        XCTAssertEqual(harness.optical.presentedPayloads.count, 1)

        XCTAssertTrue(coordinator.generatePendingQR())
        await eventually { harness.optical.presentedPayloads.count == 2 }
        XCTAssertEqual(try XCTUnwrap(harness.optical.presentedPayloads.last), offer)
        XCTAssertEqual(try OpticalMessageCodec().decode(offer).sequence, 1)
        await eventually { coordinator.pendingOpticalAction == .scan(expectedMessageKind: .accept) }
    }

    func testTrackingSuspensionCancelsActiveDisplayAndRestoresGenerateQR() async throws {
        let harness = SilentSearchTestHarness()
        harness.optical.suspendPresent = true
        let coordinator = try await calibratedCoordinator(harness, role: .a)
        XCTAssertTrue(coordinator.startHandshake())
        await eventually {
            coordinator.pendingOpticalAction == .generate(messageKind: .offer, isRetransmission: false)
        }
        XCTAssertTrue(coordinator.generatePendingQR())
        await eventually { harness.optical.suspendedPresentationCount == 1 }

        harness.safety.send(.trackingLimited(generation: 1))
        await eventually { coordinator.isTrackingSuspended && harness.optical.suspendedPresentationCount == 0 }
        harness.safety.send(.trackingNormal(generation: 1))
        await eventually {
            coordinator.pendingOpticalAction == .generate(messageKind: .offer, isRetransmission: true)
        }

        XCTAssertEqual(harness.optical.presentedPayloads.count, 1)
        XCTAssertTrue(coordinator.generatePendingQR())
        await eventually { harness.optical.presentedPayloads.count == 2 }
        XCTAssertEqual(harness.optical.presentedPayloads[0], harness.optical.presentedPayloads[1])
    }

    func testRecoverableInvalidScanShowsGuidanceAndPreservesExpectedProtocolStep() async throws {
        let harness = SilentSearchTestHarness()
        let coordinator = try await calibratedCoordinator(harness, role: .b)
        XCTAssertTrue(coordinator.startHandshake())
        await eventually { coordinator.pendingOpticalAction == .scan(expectedMessageKind: .offer) }

        harness.optical.sendToScanner(Data("not a protocol payload".utf8))
        XCTAssertTrue(coordinator.beginPendingQRScan())
        await eventually {
            coordinator.opticalValidationDiagnostic == .invalidPayload &&
                coordinator.pendingOpticalAction == .scan(expectedMessageKind: .offer)
        }

        XCTAssertEqual(coordinator.phase, .handshake(.ready))
        XCTAssertFalse(coordinator.generatePendingQR())
        XCTAssertFalse(coordinator.isTrackingSuspended)
    }

    func testRecoverableEnvelopeRejectionsKeepOfferScanPending() async throws {
        let mission = try mission(role: .a)
        let body = OpticalMessageBody.offer(OfferBody(
            searchDurationSeconds: 120,
            centerHalfWidthMillimeters: 250,
            targetLabel: "chair",
            markerWidthMillimeters: 200,
            roverARendezvous: OpticalPose(x: -1_000, y: 0, headingMillidegrees: 0),
            roverBRendezvous: OpticalPose(x: 1_000, y: 0, headingMillidegrees: 0)
        ))
        let cases: [(OpticalMessage, SilentSearchOpticalValidationDiagnostic)] = [
            (OpticalMessage(missionID: mission.id, kind: .offer, sequence: 1, role: .a,
                            markerID: "OTHER_MARKER", timestampMilliseconds: wallNow, body: body), .wrongMarker),
            (OpticalMessage(missionID: mission.id, kind: .offer, sequence: 1, role: .b,
                            markerID: mission.markerID, timestampMilliseconds: wallNow, body: body), .wrongRole),
            (OpticalMessage(missionID: mission.id, kind: .status, sequence: 1, role: .a,
                            markerID: mission.markerID, timestampMilliseconds: wallNow,
                            body: .status(StatusBody(found: false))), .unexpectedMessage),
            (OpticalMessage(missionID: mission.id, kind: .offer, sequence: 1, role: .a,
                            markerID: mission.markerID,
                            timestampMilliseconds: wallNow - OpticalMessageCodec.maximumAgeMilliseconds - 1,
                            body: body), .invalidPayload),
            (OpticalMessage(missionID: mission.id, kind: .offer, sequence: 1, role: .a,
                            markerID: mission.markerID,
                            timestampMilliseconds: wallNow + OpticalMessageCodec.maximumFutureMilliseconds + 1,
                            body: body), .invalidPayload),
        ]

        for (message, diagnostic) in cases {
            let payload = try OpticalMessageCodec().encode(message)
            try await assertRecoverableOfferRejection(payload, diagnostic: diagnostic)
        }
    }

    func testNonIncreasingExpectedSequenceDoesNotAdvanceProtocol() async throws {
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
        await eventually { coordinatorA.pendingOpticalAction != nil && coordinatorB.pendingOpticalAction != nil }
        XCTAssertTrue(coordinatorA.generatePendingQR())
        XCTAssertTrue(coordinatorB.beginPendingQRScan())
        await eventually { coordinatorB.pendingOpticalAction == .generate(messageKind: .accept, isRetransmission: false) }
        XCTAssertTrue(coordinatorB.generatePendingQR())
        await eventually { coordinatorB.pendingOpticalAction == .scan(expectedMessageKind: .searchCommit) }

        let acceptance = try XCTUnwrap(opticalB.presentedPayloads.first)
        let commit = OpticalMessage(
            missionID: try mission(role: .a).id,
            kind: .searchCommit,
            sequence: 1,
            role: .a,
            markerID: "SILENT_SEARCH_01",
            timestampMilliseconds: wallNow,
            body: .searchCommit(SearchCommitBody(
                deadlineMilliseconds: wallNow + 155_000,
                acceptanceHash: OpticalMessageCodec().messageLinkHash(for: acceptance),
                startMilliseconds: wallNow + 35_000
            ))
        )
        opticalB.sendToScanner(try OpticalMessageCodec().encode(commit))
        XCTAssertTrue(coordinatorB.beginPendingQRScan())
        await eventually {
            coordinatorB.opticalValidationDiagnostic == .nonIncreasingSequence &&
                coordinatorB.pendingOpticalAction == .scan(expectedMessageKind: .searchCommit)
        }

        XCTAssertEqual(opticalB.presentedPayloads.count, 1)
        if case .terminal = coordinatorB.phase {
            XCTFail("Recoverable sequence rejection terminated the mission")
        }
    }

    func testTrackingLimitedStopsActiveScanAndRecoveryRestoresPendingScan() async throws {
        let harness = SilentSearchTestHarness()
        let coordinator = try await calibratedCoordinator(harness, role: .b)
        XCTAssertTrue(coordinator.startHandshake())
        await eventually { coordinator.pendingOpticalAction == .scan(expectedMessageKind: .offer) }
        XCTAssertTrue(coordinator.beginPendingQRScan())
        await eventually { coordinator.phase == .handshake(.scanning) }

        harness.safety.send(.trackingLimited(generation: 1))
        await eventually { coordinator.isTrackingSuspended }
        XCTAssertNil(coordinator.pendingOpticalAction)
        XCTAssertNil(coordinator.activeOpticalMessageKind)

        harness.safety.send(.trackingNormal(generation: 1))
        await eventually {
            !coordinator.isTrackingSuspended &&
                coordinator.pendingOpticalAction == .scan(expectedMessageKind: .offer)
        }
        XCTAssertNil(coordinator.opticalValidationDiagnostic)
    }

    func testRepeatedLatestOfferRequiresManualCachedAcceptanceGeneration() async throws {
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

        await eventually { coordinatorA.pendingOpticalAction != nil && coordinatorB.pendingOpticalAction != nil }
        XCTAssertTrue(coordinatorA.generatePendingQR())
        XCTAssertTrue(coordinatorB.beginPendingQRScan())
        await eventually { coordinatorB.pendingOpticalAction == .generate(messageKind: .accept, isRetransmission: false) }
        XCTAssertTrue(coordinatorB.generatePendingQR())
        await eventually { opticalB.presentedPayloads.count == 1 }
        let acceptance = opticalB.presentedPayloads[0]
        let offer = opticalA.presentedPayloads[0]

        await eventually { coordinatorB.pendingOpticalAction == .scan(expectedMessageKind: .searchCommit) }
        opticalB.sendToScanner(offer)
        XCTAssertTrue(coordinatorB.beginPendingQRScan())
        await eventually {
            coordinatorB.pendingOpticalAction == .generate(messageKind: .accept, isRetransmission: true)
        }
        XCTAssertEqual(opticalB.presentedPayloads.count, 1)

        XCTAssertTrue(coordinatorB.generatePendingQR())
        await eventually { opticalB.presentedPayloads.count == 2 }
        XCTAssertEqual(opticalB.presentedPayloads[1], acceptance)
        XCTAssertEqual(try OpticalMessageCodec().decode(opticalB.presentedPayloads[1]).sequence, 1)
    }

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
        await driveOpticalExchange([coordinatorA, coordinatorB]) {
            coordinatorA.phase == .waitingForSearch && coordinatorB.phase == .waitingForSearch
        }
        await eventually { coordinatorA.phase == .waitingForSearch && coordinatorB.phase == .waitingForSearch }

        XCTAssertEqual(opticalA.presentedPayloads.count, 2)
        XCTAssertEqual(opticalB.presentedPayloads.count, 2)
        XCTAssertEqual(coordinatorA.phase, .waitingForSearch)
        a.clock.advance(nanoseconds: 64_999_000_000)
        b.clock.advance(nanoseconds: 64_999_000_000)
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
        await driveOpticalExchange([coordinatorA, coordinatorB]) { adopted != nil }
        await eventually { adopted != nil }

        XCTAssertEqual(coordinatorB.mission?.id, coordinatorA.mission?.id)
        XCTAssertEqual(coordinatorB.mission?.targetLabel, "table")
        XCTAssertEqual(coordinatorB.mission?.searchDurationSeconds, 240)
        XCTAssertEqual(adopted, coordinatorB.mission)

        await driveOpticalExchange([coordinatorA, coordinatorB]) { coordinatorB.phase == .waitingForSearch }
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
        await driveOpticalExchange([coordinatorA, coordinatorB]) {
            coordinatorA.phase == .waitingForSearch && coordinatorB.phase == .waitingForSearch
        }
        await eventually { coordinatorA.phase == .waitingForSearch }

        a.safety.send(.trackingLimited(generation: 1))
        await eventually { a.motion.stopCount == 1 }
        a.clock.advance(nanoseconds: 65_000_000_000)
        a.safety.send(.trackingNormal(generation: 1))
        await eventually { coordinatorA.phase == .searching }
    }

    func testPresentationCompletesAtTenSecondsAndCanCompleteEarly() async throws {
        let harness = SilentSearchTestHarness()
        harness.clock.advance(nanoseconds: wallNow * 1_000_000)
        harness.optical.suspendPresent = true
        let coordinator = try await calibratedCoordinator(harness, role: .a)

        XCTAssertTrue(coordinator.startHandshake())
        await eventually { coordinator.pendingOpticalAction == .generate(messageKind: .offer, isRetransmission: false) }
        XCTAssertTrue(harness.optical.presentedPayloads.isEmpty)
        XCTAssertTrue(coordinator.generatePendingQR())
        await eventually { harness.optical.presentedPayloads.count == 1 }
        XCTAssertEqual(coordinator.activePresentationDeadline, harness.clock.monotonicNow + 10_000_000_000)

        harness.clock.advance(nanoseconds: 9_999_000_000)
        await taskTurn()
        XCTAssertEqual(harness.optical.suspendedPresentationCount, 1)
        harness.clock.advance(nanoseconds: 1_000_000)
        await eventually { coordinator.pendingOpticalAction == .scan(expectedMessageKind: .accept) }

        await coordinator.abort()

        let earlyHarness = SilentSearchTestHarness()
        earlyHarness.clock.advance(nanoseconds: wallNow * 1_000_000)
        earlyHarness.optical.suspendPresent = true
        let early = try await calibratedCoordinator(earlyHarness, role: .a)
        XCTAssertTrue(early.startHandshake())
        await eventually { early.pendingOpticalAction != nil }
        XCTAssertTrue(early.generatePendingQR())
        await eventually { early.activePresentationDeadline != nil }
        XCTAssertTrue(early.completeQRPresentation())
        XCTAssertFalse(early.completeQRPresentation())
        await eventually { early.pendingOpticalAction == .scan(expectedMessageKind: .accept) }
        XCTAssertFalse(early.completeQRPresentation())
    }

    func testClockMismatchReturnsToPendingOfferScan() async throws {
        let opticalA = FakeSilentSearchOpticalExchange()
        let opticalB = FakeSilentSearchOpticalExchange()
        opticalA.peer = opticalB
        opticalB.peer = opticalA
        let a = SilentSearchTestHarness(optical: opticalA)
        let b = SilentSearchTestHarness(optical: opticalB)
        a.clock.advance(nanoseconds: wallNow * 1_000_000)
        b.clock.advance(nanoseconds: (wallNow + 30_001) * 1_000_000)
        let coordinatorA = try await calibratedCoordinator(a, role: .a)
        let coordinatorB = try await calibratedCoordinator(b, role: .b)
        XCTAssertTrue(coordinatorA.startHandshake())
        XCTAssertTrue(coordinatorB.startHandshake())
        await driveOpticalExchange([coordinatorA, coordinatorB]) {
            coordinatorB.opticalValidationDiagnostic == .clockMismatch
        }
        await eventually {
            coordinatorB.opticalValidationDiagnostic == .clockMismatch &&
                coordinatorB.pendingOpticalAction == .scan(expectedMessageKind: .offer)
        }

        XCTAssertEqual(coordinatorB.phase, .handshake(.ready))
    }

    func testLateAcknowledgementCausesANewSearchCommit() async throws {
        let harness = SilentSearchTestHarness()
        harness.clock.advance(nanoseconds: wallNow * 1_000_000)
        let coordinator = try await calibratedCoordinator(harness, role: .a)
        XCTAssertTrue(coordinator.startHandshake())
        await eventually { coordinator.pendingOpticalAction != nil }
        XCTAssertTrue(coordinator.generatePendingQR())
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
        await eventually { coordinator.pendingOpticalAction == .scan(expectedMessageKind: .accept) }
        XCTAssertTrue(coordinator.beginPendingQRScan())
        await eventually { coordinator.pendingOpticalAction == .generate(messageKind: .searchCommit, isRetransmission: false) }
        XCTAssertTrue(coordinator.generatePendingQR())
        await eventually { harness.optical.presentedPayloads.count == 2 }

        let firstCommit = harness.optical.presentedPayloads[1]
        try roverB.receive(firstCommit, at: wallNow)
        let acknowledgement = try roverB.prepareOutgoing(body: .searchAck(HashAcknowledgementBody(
            hash: OpticalMessageCodec().messageLinkHash(for: firstCommit)
        )), at: wallNow)
        harness.clock.advance(nanoseconds: 60_001_000_000)
        harness.optical.sendToScanner(acknowledgement)
        await eventually { coordinator.pendingOpticalAction == .scan(expectedMessageKind: .searchAck) }
        XCTAssertTrue(coordinator.beginPendingQRScan())
        await eventually { coordinator.pendingOpticalAction == .generate(messageKind: .searchCommit, isRetransmission: false) }
        XCTAssertTrue(coordinator.generatePendingQR())
        await eventually { harness.optical.presentedPayloads.count == 3 }

        let replacement = harness.optical.presentedPayloads[2]
        XCTAssertNotEqual(replacement, firstCommit)
        XCTAssertEqual(try OpticalMessageCodec().decode(replacement).sequence, 3)
        await eventually { coordinator.pendingOpticalAction == .scan(expectedMessageKind: .searchAck) }
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

        harness.calibration.send(.progress(
            context: .init(
                frameID: ARFrameID(generation: 4, sequence: 12), monotonicTimestamp: 1.25
            ),
            acceptedFrameCount: 2
        ))
        await eventually { coordinator.calibrationProgress == 2 }
        XCTAssertEqual(coordinator.calibrationProgress, 2)

        harness.calibration.send(.rejected(.headingDeviationExceeded))
        await eventually { coordinator.diagnostic == .calibrationRejected(.headingDeviationExceeded) }
        XCTAssertEqual(coordinator.phase, .calibrating)
        XCTAssertEqual(coordinator.diagnostic, .calibrationRejected(.headingDeviationExceeded))
        XCTAssertEqual(
            coordinator.calibrationVisualState.currentIssue,
            .calibrationRejection(.headingDeviationExceeded)
        )

        let wrongGeneration = try XCTUnwrap(SharedMissionFrame(
            localOrigin: Vec2(1, 2), localNorthHeading: 0.3, sessionGeneration: 5
        ))
        harness.calibration.send(.accepted(wrongGeneration))
        await eventually { coordinator.diagnostic == .calibrationRejected(.generationMismatch) }
        XCTAssertEqual(coordinator.phase, .calibrating)
        XCTAssertEqual(coordinator.diagnostic, .calibrationRejected(.generationMismatch))
        XCTAssertEqual(
            coordinator.calibrationVisualState.currentIssue,
            .calibrationRejection(.generationMismatch)
        )

        let frame = try XCTUnwrap(SharedMissionFrame(
            localOrigin: Vec2(1, 2), localNorthHeading: 0.3, sessionGeneration: 4
        ))
        harness.calibration.send(.accepted(frame))
        await eventually { coordinator.phase == .handshake(.ready) }

        XCTAssertEqual(coordinator.sharedFrame, frame)
        XCTAssertEqual(coordinator.phase, .handshake(.ready))
        XCTAssertNil(coordinator.diagnostic)
        XCTAssertEqual(coordinator.calibrationVisualState, SilentSearchCalibrationVisualState())

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
        XCTAssertEqual(calibrationEvents.first?.fields["generation"], "4")
        XCTAssertEqual(calibrationEvents.first?.fields["frame_sequence"], "12")
        XCTAssertEqual(calibrationEvents.first?.fields["monotonic_timestamp"], "1.25")
    }

    func testAcceptedCalibrationTelemetryPreservesThirdSampleContext() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())

        let context = SilentSearchCalibrationFrameContext(
            frameID: ARFrameID(generation: 4, sequence: 14), monotonicTimestamp: 1.75
        )
        harness.calibration.send(.progress(context: context, acceptedFrameCount: 3))
        let frame = try XCTUnwrap(SharedMissionFrame(
            localOrigin: Vec2(1, 2), localNorthHeading: 0.3, sessionGeneration: 4
        ))
        harness.calibration.send(.accepted(frame))
        await eventually { coordinator.phase == .handshake(.ready) }

        XCTAssertEqual(coordinator.calibrationProgress, 3)
        let entries = harness.events.entries.filter { $0.event.hasPrefix("silent_search_calibration_") }
        XCTAssertEqual(entries.map(\.event), [
            "silent_search_calibration_progress",
            "silent_search_calibration_accepted",
        ])
        for entry in entries {
            XCTAssertEqual(entry.fields["generation"], "4")
            XCTAssertEqual(entry.fields["frame_sequence"], "14")
            XCTAssertEqual(entry.fields["monotonic_timestamp"], "1.75")
            XCTAssertEqual(entry.fields["sample_count"], "3")
        }
    }

    func testCalibrationVisualStagesLatchWhileQRPresentationCanExpire() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        let frameID = ARFrameID(generation: 4, sequence: 12)
        let corners = OrientedMarkerCorners(
            topLeft: Vec2(0.2, 0.8), topRight: Vec2(0.8, 0.8),
            bottomLeft: Vec2(0.2, 0.2), bottomRight: Vec2(0.8, 0.2)
        )

        harness.calibration.send(.feedback(.expectedMarkerDetected(
            context: .init(frameID: frameID, monotonicTimestamp: 1),
            markerID: "SILENT_SEARCH_01", corners: corners
        )))
        await eventually { coordinator.calibrationVisualState.qrDecoded }
        XCTAssertEqual(coordinator.calibrationVisualState.recentDetections.map(\.context), [
            SilentSearchCalibrationFrameContext(frameID: frameID, monotonicTimestamp: 1),
        ])
        harness.calibration.send(.progress(
            context: .init(frameID: frameID, monotonicTimestamp: 1), acceptedFrameCount: 1
        ))
        await eventually { coordinator.calibrationVisualState.sampleAccepted }
        harness.calibration.send(.feedback(.qrLost(
            context: .init(
                frameID: ARFrameID(generation: 4, sequence: 13), monotonicTimestamp: 1.6
            )
        )))
        await eventually { coordinator.calibrationVisualState.recentDetections.isEmpty }

        XCTAssertTrue(coordinator.calibrationVisualState.qrDecoded)
        XCTAssertTrue(coordinator.calibrationVisualState.sampleAccepted)
        XCTAssertNil(coordinator.calibrationVisualState.currentIssue)
    }

    func testCalibrationKeepsRecentTypedDetectionsAndClearsThemOnAttemptReset() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())

        for sequence in 1...40 {
            harness.calibration.send(.feedback(.expectedMarkerDetected(
                context: .init(
                    frameID: ARFrameID(generation: 4, sequence: UInt64(sequence)),
                    monotonicTimestamp: Double(sequence) / 60
                ),
                markerID: "SILENT_SEARCH_01",
                corners: OrientedMarkerCorners(
                    topLeft: Vec2(0.2, 0.8), topRight: Vec2(0.8, 0.8),
                    bottomLeft: Vec2(0.2, 0.2), bottomRight: Vec2(0.8, 0.2)
                )
            )))
        }
        await eventually { coordinator.calibrationVisualState.recentDetections.last?.context.frameID.sequence == 40 }

        XCTAssertEqual(coordinator.calibrationVisualState.recentDetections.count, 31)
        XCTAssertEqual(coordinator.calibrationVisualState.recentDetections.first?.context.frameID.sequence, 10)

        await coordinator.stop()
        await coordinator.reset()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        XCTAssertTrue(coordinator.calibrationVisualState.recentDetections.isEmpty)
    }

    func testQRLossPreservesScannerFailureUntilSuccessfulEmptyScan() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        let context = SilentSearchCalibrationFrameContext(
            frameID: ARFrameID(generation: 4, sequence: 1), monotonicTimestamp: 1
        )

        harness.calibration.send(.feedback(.scannerFailed(context: context)))
        await eventually { coordinator.calibrationVisualState.currentIssue == .scannerFailure }
        harness.calibration.send(.feedback(.qrLost(context: context)))
        await taskTurn()
        XCTAssertEqual(coordinator.calibrationVisualState.currentIssue, .scannerFailure)
        harness.calibration.send(.feedback(.waitingForMarker(context: context)))
        await eventually { coordinator.calibrationVisualState.currentIssue == nil }
    }

    func testQRLossPreservesWrongMarkerUntilSuccessfulEmptyScan() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        let context = SilentSearchCalibrationFrameContext(
            frameID: ARFrameID(generation: 4, sequence: 1), monotonicTimestamp: 1
        )

        harness.calibration.send(.feedback(.groundingFailed(
            context: context, reason: .wrongMarkerID
        )))
        await eventually {
            coordinator.calibrationVisualState.currentIssue == .groundingFailure(.wrongMarkerID)
        }
        harness.calibration.send(.feedback(.qrLost(context: context)))
        await taskTurn()
        XCTAssertEqual(
            coordinator.calibrationVisualState.currentIssue, .groundingFailure(.wrongMarkerID)
        )
        harness.calibration.send(.feedback(.waitingForMarker(context: context)))
        await eventually { coordinator.calibrationVisualState.currentIssue == nil }
    }

    func testQRLossClearsExpectedMarkerGroundingFailure() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        let context = SilentSearchCalibrationFrameContext(
            frameID: ARFrameID(generation: 4, sequence: 1), monotonicTimestamp: 1
        )

        harness.calibration.send(.feedback(.groundingFailed(
            context: context, reason: .missingDepthMap
        )))
        await eventually {
            coordinator.calibrationVisualState.currentIssue == .groundingFailure(.missingDepthMap)
        }
        harness.calibration.send(.feedback(.qrLost(context: context)))
        await eventually { coordinator.calibrationVisualState.currentIssue == nil }
    }

    func testCalibrationFeedbackTelemetryRecordsTransitionsOnly() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        let frameID = ARFrameID(generation: 4, sequence: 12)
        let corners = OrientedMarkerCorners(
            topLeft: Vec2(0.2, 0.8), topRight: Vec2(0.8, 0.8),
            bottomLeft: Vec2(0.2, 0.2), bottomRight: Vec2(0.8, 0.2)
        )
        let detected = SilentSearchCalibrationEvent.feedback(.expectedMarkerDetected(
            context: .init(frameID: frameID, monotonicTimestamp: 1),
            markerID: "SILENT_SEARCH_01", corners: corners
        ))
        let failed = SilentSearchCalibrationEvent.feedback(.groundingFailed(
            context: .init(frameID: frameID, monotonicTimestamp: 1),
            reason: .cornerUnavailable(.topRight)
        ))
        let grounded = SilentSearchCalibrationEvent.feedback(.allCornersGrounded(
            context: .init(frameID: frameID, monotonicTimestamp: 1)
        ))
        let lost = SilentSearchCalibrationEvent.feedback(.qrLost(
            context: .init(
                frameID: ARFrameID(generation: 4, sequence: 13), monotonicTimestamp: 1.6
            )
        ))

        [detected, detected, failed, failed, grounded, grounded, lost, lost].forEach {
            harness.calibration.send($0)
        }
        await eventually {
            harness.events.entries.filter { $0.event.hasPrefix("silent_search_qr_") ||
                $0.event.hasPrefix("silent_search_grounding_") ||
                $0.event == "silent_search_corners_grounded" }.count == 4
        }

        let entries = harness.events.entries.filter {
            $0.event.hasPrefix("silent_search_qr_") ||
                $0.event.hasPrefix("silent_search_grounding_") ||
                $0.event == "silent_search_corners_grounded"
        }
        XCTAssertEqual(entries.map(\.event), [
            "silent_search_qr_detected",
            "silent_search_grounding_failed",
            "silent_search_corners_grounded",
            "silent_search_qr_lost",
        ])
        XCTAssertEqual(entries[0].fields["generation"], "4")
        XCTAssertEqual(entries[0].fields["frame_sequence"], "12")
        XCTAssertEqual(entries[0].fields["marker"], "SILENT_SEARCH_01")
        XCTAssertEqual(entries[1].fields["reason"], "corner_unavailable")
        XCTAssertEqual(entries[1].fields["corner"], "top_right")
        XCTAssertEqual(entries[3].fields["frame_sequence"], "13")
        XCTAssertTrue(entries.allSatisfy {
            $0.fields["payload"] == nil && $0.fields["image"] == nil &&
                $0.fields["corners"] == nil
        })
    }

    func testScannerBackendTelemetryDeduplicatesByScanCycleWithoutClearingSuccessState() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        let corners = OrientedMarkerCorners(
            topLeft: Vec2(0.2, 0.8), topRight: Vec2(0.8, 0.8),
            bottomLeft: Vec2(0.2, 0.2), bottomRight: Vec2(0.8, 0.2)
        )
        func context(_ sequence: UInt64) -> SilentSearchCalibrationFrameContext {
            .init(frameID: ARFrameID(generation: 4, sequence: sequence),
                  monotonicTimestamp: Double(sequence))
        }
        let right = OpticalScannerBackendDiagnostic(
            backend: .vision, orientation: .right,
            errorDomain: "VisionStableDomain", errorCode: 17
        )
        let up = OpticalScannerBackendDiagnostic(
            backend: .vision, orientation: .up,
            errorDomain: "VisionStableDomain", errorCode: 17
        )
        let changedDomain = OpticalScannerBackendDiagnostic(
            backend: .vision, orientation: .right,
            errorDomain: "VisionChangedDomain", errorCode: 18
        )

        harness.calibration.send(.feedback(.expectedMarkerDetected(
            context: context(1), markerID: "SILENT_SEARCH_01", corners: corners
        )))
        harness.calibration.send(.feedback(.allCornersGrounded(context: context(1))))
        harness.calibration.send(.progress(context: context(1), acceptedFrameCount: 1))
        harness.calibration.send(.feedback(.scannerBackendFailed(
            context: context(2), diagnostic: right
        )))
        harness.calibration.send(.feedback(.scannerBackendFailed(
            context: context(2), diagnostic: right
        )))
        harness.calibration.send(.feedback(.scannerBackendFailed(
            context: context(3), diagnostic: right
        )))
        harness.calibration.send(.feedback(.scannerBackendFailed(
            context: context(3), diagnostic: up
        )))
        harness.calibration.send(.feedback(.waitingForMarker(context: context(4))))
        harness.calibration.send(.feedback(.scannerBackendFailed(
            context: context(5), diagnostic: right
        )))
        harness.calibration.send(.feedback(.scannerBackendFailed(
            context: context(6), diagnostic: changedDomain
        )))

        await eventually {
            harness.events.entries.filter {
                $0.event == "silent_search_scanner_backend_failed"
            }.count >= 4
        }
        let entries = harness.events.entries.filter {
            $0.event == "silent_search_scanner_backend_failed"
        }
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries.map { $0.fields["orientation"] }, ["right", "up", "right", "right"])
        XCTAssertEqual(entries.map { $0.fields["error_domain"] }, [
            "VisionStableDomain", "VisionStableDomain", "VisionStableDomain", "VisionChangedDomain",
        ])
        XCTAssertEqual(entries.map { $0.fields["error_code"] }, ["17", "17", "17", "18"])
        XCTAssertTrue(coordinator.calibrationVisualState.qrDecoded)
        XCTAssertTrue(coordinator.calibrationVisualState.cornersGrounded)
        XCTAssertTrue(coordinator.calibrationVisualState.sampleAccepted)
        XCTAssertNil(coordinator.calibrationVisualState.currentIssue)
        XCTAssertFalse(entries.contains { $0.fields["reason"] == "scanner_failure" })
    }

    func testCleanCalibratorScanAllowsBackendDiagnosticRecurrenceToBeRecorded() async throws {
        let manager = ARSessionManager()
        let scans = CoordinatorScanCounter()
        let diagnostic = OpticalScannerBackendDiagnostic(
            backend: .vision, orientation: .right,
            errorDomain: "VisionStableDomain", errorCode: 17
        )
        let calibrator = ARSharedMissionFrameCalibrator(
            sessionManager: manager,
            detailedScanner: { _ in
                scans.increment()
                return OpticalScanOutcome(
                    observations: [],
                    diagnostics: scans.value == 2 ? [] : [diagnostic]
                )
            }
        )
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 0)
        let coordinator = harness.coordinator(calibration: calibrator)
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        await Task.yield()

        for timestamp in [1.0, 2.0, 3.0] {
            manager.ingestForTesting(
                image: makeImage(), timestamp: timestamp,
                cameraTransform: matrix_identity_float4x4,
                intrinsics: matrix_identity_float3x3,
                imageResolution: CGSize(width: 100, height: 100), depthMap: nil,
                trackingQuality: .normal
            )
            await eventually { scans.value == Int(timestamp) }
        }

        await eventually {
            harness.events.entries.filter {
                $0.event == "silent_search_scanner_backend_failed"
            }.count == 2
        }
        XCTAssertEqual(harness.events.entries.filter {
            $0.event == "silent_search_scanner_backend_failed"
        }.count, 2)
        XCTAssertNil(coordinator.calibrationVisualState.currentIssue)
    }

    func testCalibrationRejectionTelemetryRecordsTransitionsOnly() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())

        harness.calibration.send(.rejected(.headingDeviationExceeded))
        harness.calibration.send(.feedback(.allCornersGrounded(context: .init(
            frameID: ARFrameID(generation: 4, sequence: 12), monotonicTimestamp: 1
        ))))
        harness.calibration.send(.rejected(.headingDeviationExceeded))
        harness.calibration.send(.feedback(.allCornersGrounded(context: .init(
            frameID: ARFrameID(generation: 4, sequence: 13), monotonicTimestamp: 2
        ))))
        harness.calibration.send(.rejected(.originDeviationExceeded))
        await eventually {
            coordinator.diagnostic == .calibrationRejected(.originDeviationExceeded)
        }

        let entries = harness.events.entries.filter {
            $0.event == "silent_search_calibration_rejected"
        }
        XCTAssertEqual(entries.map { $0.fields["reason"] }, [
            "headingDeviationExceeded",
            "originDeviationExceeded",
        ])
        XCTAssertEqual(
            coordinator.calibrationVisualState.currentIssue,
            .calibrationRejection(.originDeviationExceeded)
        )
    }

    func testCalibrationFailuresDoNotLatchExpectedMarkerSuccess() async throws {
        let harness = SilentSearchTestHarness()
        harness.readiness.snapshot = .ready(sessionGeneration: 4)
        let coordinator = harness.coordinator()
        coordinator.configure(try mission())
        XCTAssertTrue(coordinator.startCalibration())
        let frameID = ARFrameID(generation: 4, sequence: 12)

        harness.calibration.send(.feedback(.trackingNotNormal(
            context: .init(frameID: frameID, monotonicTimestamp: 0.9)
        )))
        await eventually { coordinator.calibrationVisualState.currentIssue == .trackingNotNormal }
        XCTAssertFalse(coordinator.calibrationVisualState.qrDecoded)

        harness.calibration.send(.feedback(.groundingFailed(
            context: .init(frameID: frameID, monotonicTimestamp: 1), reason: .wrongMarkerID
        )))
        await eventually {
            coordinator.calibrationVisualState.currentIssue == .groundingFailure(.wrongMarkerID)
        }
        XCTAssertFalse(coordinator.calibrationVisualState.qrDecoded)
        XCTAssertEqual(coordinator.calibrationVisualState.currentIssue,
                       .groundingFailure(.wrongMarkerID))

        harness.calibration.send(.feedback(.scannerFailed(
            context: .init(frameID: frameID, monotonicTimestamp: 1.1)
        )))
        await eventually { coordinator.calibrationVisualState.currentIssue == .scannerFailure }
        XCTAssertFalse(coordinator.calibrationVisualState.qrDecoded)
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
        await eventually { coordinator.pendingOpticalAction != nil }
        XCTAssertTrue(coordinator.generatePendingQR())
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
        XCTAssertEqual(coordinator.calibrationVisualState, SilentSearchCalibrationVisualState())
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
        XCTAssertEqual(coordinator.calibrationVisualState, SilentSearchCalibrationVisualState())
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

    private func makeImage() -> CVPixelBuffer {
        var image: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &image)
        return image!
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

    private func driveOpticalExchange(
        _ coordinators: [SilentSearchCoordinator],
        until complete: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 where !complete() {
            for coordinator in coordinators {
                switch coordinator.pendingOpticalAction {
                case .generate: _ = coordinator.generatePendingQR()
                case .scan: _ = coordinator.beginPendingQRScan()
                case nil: break
                }
            }
            await Task.yield()
        }
    }

    private func assertRecoverableOfferRejection(
        _ payload: Data,
        diagnostic: SilentSearchOpticalValidationDiagnostic
    ) async throws {
        let harness = SilentSearchTestHarness()
        harness.clock.advance(nanoseconds: wallNow * 1_000_000)
        let coordinator = try await calibratedCoordinator(harness, role: .b)
        XCTAssertTrue(coordinator.startHandshake())
        await eventually { coordinator.pendingOpticalAction == .scan(expectedMessageKind: .offer) }
        harness.optical.sendToScanner(payload)
        XCTAssertTrue(coordinator.beginPendingQRScan())
        await eventually {
            coordinator.opticalValidationDiagnostic == diagnostic &&
                coordinator.pendingOpticalAction == .scan(expectedMessageKind: .offer)
        }
        XCTAssertTrue(harness.optical.presentedPayloads.isEmpty)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
    }
}

private final class CoordinatorScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
