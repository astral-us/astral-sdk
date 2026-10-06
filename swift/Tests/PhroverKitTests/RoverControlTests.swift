import XCTest
import ARKit
import CoreVideo
@testable import PhroverKit

final class RoverControlTests: XCTestCase {
    @MainActor
    func testControllerTraceRecordsActualAttemptAndExpiredBackoffWithoutRetryOrInventedAck() async throws {
        StubURLProtocol.results = Array(repeating: .failure(URLError(.timedOut)), count: 3)
        let clock = BurstTestClock(20)
        let control = RoverControl(session: URLSession(configuration: .stubbed), retrySleep: { _ in clock.set(20.080) })
        let sink = FollowDiagnosticRecordingSink()
        let emitter = FollowDiagnosticEmitter(streamID: "backoff", monotonic: { 1000 }, utc: { Date() }, sink: sink.append)
        let evidence = FollowMotionOperationEvidence(context: .init(request:
            .init(sessionGeneration: 23, requestToken: 47, purpose: .followScan, phase: "scanning"),
            controllerOperationID: 99, purpose: .followScan, profile: .turnBurst(purpose: .followScan)))
        evidence.scanTrace = .init(emitter: emitter)
        evidence.burstTrace = .init()
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { .infinity },
            plan: { _, _ in nil }, lastAckAt: { nil }, sendCommand: { _ in }, stopRover: {},
            sleep: { try? await Task.sleep(for: $0) }, sendCommandReceipt: { command in
                clock.set(20.005)
                return await control.sendNavigationWithReceipt(command)
            }, diagnosticEmitter: emitter, sourceNow: { clock.now }, transportUptime: { clock.now })
        let receipt = try await FollowMotionTaskScope.$evidence.withValue(evidence) {
            try await controller.executeFollowTurnBurst(.init(left: -0.25, right: 0.25), requestedBudget: 0.080, purpose: .followScan)
        }
        XCTAssertEqual(receipt.send.result.receipt.outcome, "expired")
        XCTAssertEqual(receipt.send.result.receipt.acknowledged, false)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        let record = try XCTUnwrap(sink.records.first { $0.event == "follow_scan.send_ack" })
        let ack = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(record.fields["payload"]).utf8)) as? [String: Any])
        XCTAssertEqual(ack["sender_outcome"] as? String, "expired")
        XCTAssertEqual(ack["sender_failure_reason"] as? String, "expired")
        XCTAssertEqual(ack["transport_entry_uptime_s"] as? Double, 20.005)
        XCTAssertEqual(ack["attempts"] as? Int, 1)
        XCTAssertEqual(ack["operation_id"] as? Int, 99)
        XCTAssertEqual(ack["session_generation"] as? Int, 23)
        XCTAssertEqual((ack["transport_attempt_entries"] as? [Any])?.count, 1)
        XCTAssertEqual(ack["requested_additional_wait_s"] as? Double, 0)
    }

    @MainActor
    func testProductionSourceWaitCannotUseCachedNormalFrameAfterARInterruption() async throws {
        let ar = ARSessionManager()
        ar.resetForTesting()
        var image: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, kCVPixelFormatType_32BGRA, nil, &image)
        let pixels = try XCTUnwrap(image)
        func ingest() {
            ar.ingestForTesting(image: pixels, timestamp: ProcessInfo.processInfo.systemUptime,
                cameraTransform: matrix_identity_float4x4, intrinsics: matrix_identity_float3x3,
                imageResolution: CGSize(width: 8, height: 6), depthMap: nil, trackingQuality: .normal)
        }
        ingest()
        StubURLProtocol.results = [.success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!))]
        let controller = NavigationController(ar: ar, control: RoverControl(session: URLSession(configuration: .stubbed)))
        let wait = Task { await controller.prepareFollowTurnSource() }
        for _ in 0..<1000 where controller.followTurnStopFence == nil { await Task.yield() }
        XCTAssertNotNil(controller.followTurnStopFence)
        ingest() // A genuine post-ack capture during settle, still normal/fresh in the cache.
        for _ in 0..<30 { await Task.yield() }
        ar.interruptionBeganForTesting()
        let result = await wait.value
        guard case .failed(let reason) = result else { XCTFail("Current AR interruption must invalidate cached normal evidence"); return }
        XCTAssertEqual(reason, .trackingLost)
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "Only the initial authoritative stop, no motion")
    }
    func testExpiryDuringRetryBackoffPreventsTheSecondHTTPAttempt() async {
        StubURLProtocol.results = Array(repeating: .failure(URLError(.timedOut)), count: 3)
        let clock = BurstTestClock(10)
        let backoffs = BurstTestClock(0)
        let control = RoverControl(session: URLSession(configuration: .stubbed), retrySleep: { _ in
            backoffs.set(backoffs.now + 1)
            clock.set(10.080)
        })
        let authorization = FollowTurnBurstAuthorization(operationID: 13, sendEntryUptime: 10,
            requestedBudget: 0.080, uptime: { clock.now })
        let result = await control.sendNavigationWithReceipt(.init(left: -0.25, right: 0.25), authorization: authorization)
        XCTAssertEqual(backoffs.now, 1)
        XCTAssertEqual(result.receipt.outcome, "expired")
        XCTAssertEqual(result.receipt.attempts, 1)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }
    func testExpiredResponseDrainsWithoutAddingRetryBackoffBeforeStopAdmission() async {
        StubURLProtocol.results = Array(repeating: .failure(URLError(.timedOut)), count: 3)
        let clock = BurstTestClock(10)
        let backoffs = BurstTestClock(0)
        StubURLProtocol.onRequest = { clock.set(10.100) }
        let control = RoverControl(session: URLSession(configuration: .stubbed), retrySleep: { _ in
            backoffs.set(backoffs.now + 1)
        })
        let authorization = FollowTurnBurstAuthorization(operationID: 12, sendEntryUptime: 10,
            requestedBudget: 0.080, uptime: { clock.now })
        let result = await control.sendNavigationWithReceipt(.init(left: -0.25, right: 0.25), authorization: authorization)
        XCTAssertEqual(backoffs.now, 0, "Known expiry adds no deliberate backoff before serialized stop")
        XCTAssertEqual(result.receipt.outcome, "expired")
        XCTAssertEqual(result.receipt.attempts, 1)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }
    func testCancellationAtAuthorizationBoundaryIsCancelledRatherThanFenced() async {
        let entered = expectation(description: "authorization actor boundary")
        let suspension = AsyncStream<Void>.makeStream()
        let authorization = FollowTurnBurstAuthorization(operationID: 11, sendEntryUptime: 10,
            requestedBudget: 0.080, uptime: { 10.01 }, authorizeAttempt: {
                entered.fulfill()
                var iterator = suspension.stream.makeAsyncIterator()
                _ = await iterator.next()
                return false
            })
        let control = RoverControl(session: URLSession(configuration: .stubbed))
        let task = Task { await control.sendNavigationWithReceipt(.init(left: -0.25, right: 0.25), authorization: authorization) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        suspension.continuation.yield(())
        let result = await task.value
        XCTAssertEqual(result.receipt.outcome, "cancelled")
        XCTAssertEqual(result.receipt.attempts, 0)
        XCTAssertEqual(result.receipt.acknowledged, false)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        suspension.continuation.finish()
    }
    @MainActor
    func testPublicCancelWaitsForPendingBurstBeforeItsIndependentStop() async {
        let accepted = (Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!)
        StubURLProtocol.results = [.success(accepted), .success(accepted)]
        StubURLProtocol.suspendFirst = true
        let entered = expectation(description: "pending send")
        entered.assertForOverFulfill = false
        StubURLProtocol.onRequest = { entered.fulfill() }
        var stopReturned = false
        let control = RoverControl(session: URLSession(configuration: .stubbed))
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { .infinity },
            plan: { _, _ in nil }, lastAckAt: { nil }, sendCommand: { _ in },
            stopRover: { _ = try await control.stopWithReceipt().get(); stopReturned = true },
            sleep: { try? await Task.sleep(for: $0) },
            sendCommandReceipt: { await control.sendNavigationWithReceipt($0) },
            sourceNow: { 10 }, transportUptime: { 10 })
        let send = Task { await controller.sendFollowTurnBurst(.init(left: -0.25, right: 0.25),
            requestedBudget: 0.080, purpose: .followScan) }
        await fulfillment(of: [entered], timeout: 2)
        controller.cancel()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(stopReturned)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        StubURLProtocol.releaseFirst()
        _ = await send.value
        for _ in 0..<1000 where !stopReturned { await Task.yield() }
        XCTAssertTrue(stopReturned)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testGenericAndStopStillUseThreeAttemptsDespiteExpiredFollowContext() async {
        let authorization = FollowTurnBurstAuthorization(operationID: 9, sendEntryUptime: 10,
            requestedBudget: 0.080, uptime: { 11 }, isAuthorized: { false })
        for stopping in [false, true] {
            StubURLProtocol.reset()
            StubURLProtocol.results = [.failure(URLError(.timedOut)), .failure(URLError(.timedOut)),
                .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!))]
            let control = RoverControl(session: URLSession(configuration: .stubbed))
            await FollowTurnBurstTransportScope.$authorization.withValue(authorization) {
                if stopping {
                    let result = await control.stopWithReceipt()
                    XCTAssertEqual(result.receipt.attempts, 3)
                    XCTAssertEqual(result.receipt.acknowledged, true)
                } else {
                    do { try await control.send(.init(left: 0.1, right: 0.1)) }
                    catch { XCTFail("Generic retry behavior changed: \(error)") }
                }
            }
            XCTAssertEqual(StubURLProtocol.requestCount, 3)
        }
    }
    @MainActor
    func testControllerRecordsActualTransportEntrySeparatelyFromSenderQueueAndLateAck() async {
        StubURLProtocol.results = [.success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!))]
        let clock = BurstTestClock(10)
        StubURLProtocol.onRequest = { clock.set(10.100) }
        let control = RoverControl(session: URLSession(configuration: .stubbed))
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { .infinity },
            plan: { _, _ in nil }, lastAckAt: { nil }, sendCommand: { _ in }, stopRover: {},
            sleep: { try? await Task.sleep(for: $0) }, sendCommandReceipt: { command in
                clock.set(10.030)
                return await control.sendNavigationWithReceipt(command)
            }, sourceNow: { clock.now }, transportUptime: { clock.now })
        let receipt = await controller.sendFollowTurnBurst(.init(left: -0.25, right: 0.25),
            requestedBudget: 0.080, purpose: .followAlignment)
        XCTAssertEqual(receipt.sendEntryUptime, 10)
        XCTAssertEqual(receipt.deadline, 10.080)
        XCTAssertEqual(receipt.transportAttempts.count, 1)
        XCTAssertEqual(receipt.transportAttempts.first?.entryUptime, 10.030)
        XCTAssertEqual(receipt.transportAttempts.first?.attempt, 1)
        XCTAssertEqual(receipt.responseUptime, 10.100)
        XCTAssertEqual(receipt.result.receipt.acknowledged, true)
        XCTAssertEqual(receipt.result.receipt.outcome, "acknowledged")
        XCTAssertTrue(receipt.stopObligation)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }
    @MainActor
    func testPendingBurstCannotBeOverwrittenByNewSenderEntry() async {
        let accepted = (Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!)
        StubURLProtocol.results = [.success(accepted), .success(accepted)]
        StubURLProtocol.suspendFirst = true
        let entered = expectation(description: "first sender entered")
        entered.assertForOverFulfill = false
        StubURLProtocol.onRequest = { entered.fulfill() }
        let control = RoverControl(session: URLSession(configuration: .stubbed))
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { .infinity },
            plan: { _, _ in nil }, lastAckAt: { nil }, sendCommand: { _ in }, stopRover: {},
            sleep: { try? await Task.sleep(for: $0) },
            sendCommandReceipt: { await control.sendNavigationWithReceipt($0) },
            sourceNow: { 10 }, transportUptime: { 10 })
        let first = Task { await controller.sendFollowTurnBurst(.init(left: -0.25, right: 0.25),
            requestedBudget: 0.080, purpose: .followScan) }
        await fulfillment(of: [entered], timeout: 2)
        let identity = controller.followTurnBurstPendingStatus?.operationID
        let second = await controller.sendFollowTurnBurst(.init(left: 0.25, right: -0.25),
            requestedBudget: 0.080, purpose: .followAlignment)
        XCTAssertEqual(second.result.receipt.outcome, "fenced")
        XCTAssertEqual(second.result.receipt.attempts, 0)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertEqual(controller.followTurnBurstPendingStatus?.operationID, identity)
        StubURLProtocol.releaseFirst()
        _ = await first.value
        XCTAssertNil(controller.followTurnBurstPendingStatus)
    }
    @MainActor
    func testControllerRejectsInvalidOrUnrepresentableBudgetWithoutRoundingToFloor() async {
        let accepted = (Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!)
        let control = RoverControl(session: URLSession(configuration: .stubbed))
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { .infinity },
            plan: { _, _ in nil }, lastAckAt: { nil }, sendCommand: { _ in }, stopRover: {},
            sleep: { _ in }, sendCommandReceipt: { await control.sendNavigationWithReceipt($0) },
            sourceNow: { 10 }, transportUptime: { 10 })
        // Zero first: it already has a valid Duration and exposes the missing validation without a crash.
        for budget in [0.0, -0.01, Double.leastNonzeroMagnitude, 0.081, .nan, .infinity] {
            StubURLProtocol.reset()
            StubURLProtocol.results = [.success(accepted)]
            let receipt = await controller.sendFollowTurnBurst(.init(left: -0.25, right: 0.25),
                requestedBudget: budget, purpose: .followAlignment)
            XCTAssertEqual(StubURLProtocol.requestCount, 0)
            XCTAssertEqual(receipt.result.receipt.outcome, "invalid_budget")
            XCTAssertEqual(receipt.result.receipt.acknowledged, false)
        }
        StubURLProtocol.reset()
        StubURLProtocol.results = [.success(accepted)]
        let tiny = await controller.sendFollowTurnBurst(.init(left: -0.25, right: 0.25),
            requestedBudget: 0.001, purpose: .followAlignment)
        XCTAssertEqual(tiny.deadline, 10.001)
        XCTAssertEqual(tiny.result.receipt.attempts, 1)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }
    @MainActor
    func testPendingBurstExpiryOnlyMarksObligationAndStopDrainsActualHTTP() async {
        let accepted = (Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!)
        StubURLProtocol.results = [.success(accepted), .success(accepted)]
        StubURLProtocol.suspendFirst = true
        let entered = expectation(description: "pending first HTTP")
        entered.assertForOverFulfill = false
        StubURLProtocol.onRequest = { entered.fulfill() }
        let clock = BurstTestClock(10)
        var budgetWait: CheckedContinuation<Void, Never>?
        let control = RoverControl(session: URLSession(configuration: .stubbed))
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { .infinity },
            plan: { _, _ in nil }, lastAckAt: { nil }, sendCommand: { _ in },
            stopRover: { _ = try await control.stopWithReceipt().get() },
            sleep: { _ in await withCheckedContinuation { budgetWait = $0 } },
            sendCommandReceipt: { await control.sendNavigationWithReceipt($0) },
            sourceNow: { clock.now }, transportUptime: { clock.now })
        let send = Task { await controller.sendFollowTurnBurst(.init(left: -0.25, right: 0.25),
            requestedBudget: 0.080, purpose: .followScan) }
        await fulfillment(of: [entered], timeout: 2)
        clock.set(10.100)
        for _ in 0..<100 where budgetWait == nil { await Task.yield() }
        budgetWait?.resume(); budgetWait = nil
        for _ in 0..<100 where controller.followTurnBurstPendingStatus?.stopObligation != true { await Task.yield() }
        XCTAssertEqual(controller.followTurnBurstPendingStatus?.stopObligation, true)
        let stop = Task { try? await controller.stopAndConfirm() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "No stop may overtake pending nonzero HTTP")
        StubURLProtocol.releaseFirst()
        let receipt = await send.value
        _ = await stop.value
        XCTAssertTrue(receipt.stopObligation)
        XCTAssertEqual(receipt.result.receipt.outcome, "acknowledged", "Real late ACK remains truthful")
        XCTAssertEqual(receipt.result.receipt.attempts, 1)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }
    @MainActor
    func testControllerSenderQueueConsumesWhole80msBudgetBeforeHTTPEntry() async {
        StubURLProtocol.results = [.success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!))]
        let clock = BurstTestClock(10)
        let control = RoverControl(session: URLSession(configuration: .stubbed))
        let controller = NavigationController(currentPose: { nil }, forwardClearance: { .infinity },
            plan: { _, _ in nil }, lastAckAt: { nil }, sendCommand: { _ in }, stopRover: {},
            sleep: { try? await Task.sleep(for: $0) }, sendCommandReceipt: { command in
                clock.set(10.080)
                return await control.sendNavigationWithReceipt(command)
            }, sourceNow: { clock.now }, transportUptime: { clock.now })
        let receipt = await controller.sendFollowTurnBurst(.init(left: -0.25, right: 0.25),
            requestedBudget: 0.080, purpose: .followAlignment)
        XCTAssertEqual(receipt.sendEntryUptime, 10)
        XCTAssertEqual(receipt.deadline, 10.080)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        XCTAssertEqual(receipt.result.receipt.attempts, 0)
        XCTAssertEqual(receipt.result.receipt.outcome, "expired")
        XCTAssertTrue(receipt.stopObligation)
        XCTAssertEqual(receipt.result.receipt.acknowledged, false)
    }
    func testAttemptRechecksDeadlineAndFenceAfterAuthorizationActorBoundary() async {
        for expires in [true, false] {
            StubURLProtocol.reset()
            StubURLProtocol.results = [.failure(URLError(.timedOut))]
            let clock = BurstTestClock(10)
            let authority = BurstTestClock(1)
            let authorization = FollowTurnBurstAuthorization(operationID: 8, sendEntryUptime: 10,
                requestedBudget: 0.080, uptime: { clock.now }, isAuthorized: { authority.now == 1 },
                authorizeAttempt: {
                    if expires { clock.set(10.080) } else { authority.set(0) }
                    return true
                })
            let control = RoverControl(session: URLSession(configuration: .stubbed))
            let result = await control.sendNavigationWithReceipt(.init(left: -0.25, right: 0.25), authorization: authorization)
            XCTAssertEqual(StubURLProtocol.requestCount, 0)
            XCTAssertEqual(result.receipt.attempts, 0)
            XCTAssertEqual(result.receipt.outcome, expires ? "expired" : "fenced")
            XCTAssertEqual(result.receipt.acknowledged, false)
        }
    }
    func testFollowBurstCancellationDuringBackoffCannotBeSwallowedIntoRetry() async {
        StubURLProtocol.results = Array(repeating: .failure(URLError(.timedOut)), count: 3)
        let entered = expectation(description: "first HTTP attempt")
        entered.assertForOverFulfill = false
        StubURLProtocol.onRequest = { entered.fulfill() }
        let control = RoverControl(session: URLSession(configuration: .stubbed))
        let authorization = FollowTurnBurstAuthorization(operationID: 4, sendEntryUptime: 10,
            requestedBudget: 0.080, uptime: { 10.01 })
        let task = Task {
            await control.sendNavigationWithReceipt(.init(left: -0.25, right: 0.25), authorization: authorization)
        }
        await fulfillment(of: [entered], timeout: 2)
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let result = await task.value
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertEqual(result.receipt.attempts, 1)
        XCTAssertEqual(result.receipt.outcome, "cancelled")
        XCTAssertEqual(result.receipt.acknowledged, false)
    }
    func testFollowBurstAuthorityLossBeforeFirstAttemptAndDuringBackoff() async {
        for beforeFirst in [true, false] {
            StubURLProtocol.reset()
            StubURLProtocol.results = Array(repeating: .failure(URLError(.timedOut)), count: 3)
            let authority = BurstTestClock(beforeFirst ? 0 : 1)
            StubURLProtocol.onRequest = { authority.set(0) }
            let control = RoverControl(session: URLSession(configuration: .stubbed))
            let authorization = FollowTurnBurstAuthorization(operationID: 3, sendEntryUptime: 10,
                requestedBudget: 0.080, uptime: { 10.01 }, isAuthorized: { authority.now == 1 })
            let result = await control.sendNavigationWithReceipt(.init(left: -0.25, right: 0.25), authorization: authorization)
            XCTAssertEqual(StubURLProtocol.requestCount, beforeFirst ? 0 : 1)
            XCTAssertEqual(result.receipt.attempts, beforeFirst ? 0 : 1)
            XCTAssertEqual(result.receipt.outcome, "fenced")
            XCTAssertEqual(result.receipt.acknowledged, false)
        }
    }
    func testFollowBurstFirstTimeoutAt100msCannotRetryAn80msDeadline() async {
        StubURLProtocol.results = [.failure(URLError(.timedOut)), .failure(URLError(.timedOut)), .failure(URLError(.timedOut))]
        let clock = BurstTestClock(10)
        StubURLProtocol.onRequest = { clock.set(10.100) }
        let control = RoverControl(session: URLSession(configuration: .stubbed))
        let authorization = FollowTurnBurstAuthorization(operationID: 1, sendEntryUptime: 10,
            requestedBudget: 0.080, uptime: { clock.now })
        let result = await control.sendNavigationWithReceipt(.init(left: -0.25, right: 0.25), authorization: authorization)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertEqual(result.receipt.attempts, 1)
        XCTAssertEqual(result.receipt.acknowledged, false)
        XCTAssertEqual(result.receipt.outcome, "expired")
        XCTAssertTrue(result.failure is FollowTurnBurstTransportDenial)
        let ack = await control.lastAckAt
        XCTAssertNil(ack)
    }
    func testUnknownReceiptDoesNotClaimTransportFacts() {
        XCTAssertNil(RoverCommandDiagnosticReceipt.unknown.httpStatus)
        XCTAssertNil(RoverCommandDiagnosticReceipt.unknown.acknowledged)
        XCTAssertNil(RoverCommandDiagnosticReceipt.unknown.acknowledgementUTC)
        XCTAssertNil(RoverCommandDiagnosticReceipt.unknown.attempts)
        XCTAssertEqual(RoverCommandDiagnosticReceipt.unknown.outcome, "unknown")
    }

    func testReceiptsPreserveRealAcceptedStatusAndAckClock() async throws {
        for status in [200, 204, 299] {
            StubURLProtocol.reset()
            StubURLProtocol.results = [.success((Data(), HTTPURLResponse(
                url: URL(string: "http://192.168.4.1/js")!, statusCode: status,
                httpVersion: nil, headerFields: nil)!))]
            let control = RoverControl(session: URLSession(configuration: .stubbed))
            let result = await control.sendNavigationWithReceipt(.init(left: -0.1, right: 0.1))
            XCTAssertNil(result.failure)
            XCTAssertEqual(result.receipt.httpStatus, status)
            XCTAssertEqual(result.receipt.acknowledged, true)
            XCTAssertEqual(result.receipt.attempts, 1)
            let ack = await control.lastAckAt
            XCTAssertEqual(result.receipt.acknowledgementUTC, ack)
            XCTAssertNotNil(ack)
        }
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testFailureReceiptsKeepActualStatusAttemptsAndOriginalErrors() async throws {
        let url = URL(string: "http://192.168.4.1/js")!
        let cases: [(Result<(Data, URLResponse), Error>, Int?, Int, String)] = [
            (.success((Data(), HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!)), 503, 1, "failed"),
            (.success((Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))), nil, 1, "failed"),
            (.failure(URLError(.timedOut)), nil, 3, "failed"),
            (.failure(URLError(.cancelled)), nil, 1, "cancelled")
        ]
        for (response, status, attempts, outcome) in cases {
            StubURLProtocol.reset()
            StubURLProtocol.results = Array(repeating: response, count: attempts)
            let control = RoverControl(session: URLSession(configuration: .stubbed))
            let result = await control.sendNavigationWithReceipt(.init(left: -0.1, right: 0.1))
            XCTAssertNotNil(result.failure)
            XCTAssertThrowsError(try result.get())
            XCTAssertEqual(result.receipt.httpStatus, status)
            XCTAssertEqual(result.receipt.attempts, attempts)
            XCTAssertEqual(result.receipt.outcome, outcome)
            XCTAssertEqual(result.receipt.acknowledged, false)
            XCTAssertNil(result.receipt.acknowledgementUTC)
            XCTAssertEqual(StubURLProtocol.requestCount, attempts)
            let ack = await control.lastAckAt
            XCTAssertNil(ack)
        }
    }

    func testStopAndRetryReceiptsDescribeTheirOwnAcknowledgement() async throws {
        StubURLProtocol.results = [.failure(URLError(.timedOut)), .success((Data(), HTTPURLResponse(
            url: URL(string: "http://192.168.4.1/js")!, statusCode: 204, httpVersion: nil, headerFields: nil)!))]
        let control = RoverControl(session: URLSession(configuration: .stubbed))
        let result = await control.stopWithReceipt()
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.receipt.httpStatus, 204)
        XCTAssertEqual(result.receipt.attempts, 2)
        XCTAssertEqual(result.receipt.acknowledged, true)
        XCTAssertEqual(result.receipt.outcome, "acknowledged")
        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        let json = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["T"] as? Int, 0)
        XCTAssertNil(payload["L"])
    }

    func testRetriesTransientCommandTimeoutBeforeFailingNavigationLink() async throws {
        StubURLProtocol.results = [
            .failure(URLError(.timedOut)),
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        try await control.send(.init(left: 0.1, right: 0.1))

        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        let lastAckAt = await control.lastAckAt
        XCTAssertNotNil(lastAckAt)
    }

    func testDoesNotRetryServerErrors() async {
        StubURLProtocol.results = [
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 500,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        do {
            try await control.send(.init(left: 0.1, right: 0.1))
            XCTFail("Expected server error")
        } catch RoverControlError.serverError(let code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Expected server error, got \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testRetriesTwoTransientTimeoutsBeforeFailingNavigationLink() async throws {
        StubURLProtocol.results = [
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        try await control.send(.init(left: 0.1, right: 0.1))

        XCTAssertEqual(StubURLProtocol.requestCount, 3)
        let lastAckAt = await control.lastAckAt
        XCTAssertNotNil(lastAckAt)
    }

    func testRequestLogFieldsIncludeURLAndHTTPStatus() {
        let fields = RoverControl.requestLogFields(url: URL(string: "http://192.168.4.1/js?json=%7B%7D")!,
                                                   attempt: 2,
                                                   maxAttempts: 3,
                                                   statusCode: 200,
                                                   error: nil)

        XCTAssertEqual(fields["url"], "http://192.168.4.1/js?json=%7B%7D")
        XCTAssertEqual(fields["attempt"], "2")
        XCTAssertEqual(fields["max"], "3")
        XCTAssertEqual(fields["status"], "200")
        XCTAssertNil(fields["error"])
    }

    func testCommandRequestsDisableStaleConnectionReuse() async throws {
        StubURLProtocol.results = [
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        try await control.send(.init(left: 0.1, right: 0.1))

        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Connection"), "close")
        XCTAssertEqual(StubURLProtocol.lastRequest?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testCommandMapsNavigationYawToWaveRoverWheelDirection() async throws {
        StubURLProtocol.results = [
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        try await control.sendNavigation(.init(left: -0.25, right: 0.25))

        let requestURL = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        let json = try XCTUnwrap(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "json" })?.value)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["L"] as? Double, 0.25)
        XCTAssertEqual(payload["R"] as? Double, -0.25)
    }

    func testManualCommandPreservesPhysicalWheelDirection() async throws {
        StubURLProtocol.results = [
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        try await control.send(.init(left: -0.25, right: 0.25))

        let requestURL = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        let json = try XCTUnwrap(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "json" })?.value)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["L"] as? Double, -0.25)
        XCTAssertEqual(payload["R"] as? Double, 0.25)
    }

    func testProbeLinkUsesFeedbackFlowCommandAndRefreshesAcknowledgement() async throws {
        StubURLProtocol.results = [
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 204,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let control = RoverControl(session: URLSession(configuration: .stubbed))

        try await control.probeLink()

        let requestURL = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        let json = try XCTUnwrap(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "json" })?.value)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["T"] as? Int, 131)
        XCTAssertEqual(payload["cmd"] as? Int, 1)
        XCTAssertNil(payload["L"])
        XCTAssertNil(payload["R"])
        let lastAckAt = await control.lastAckAt
        XCTAssertNotNil(lastAckAt)
    }
}

private extension URLSessionConfiguration {
    static var stubbed: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var suspendFirst = false
    nonisolated(unsafe) static var suspended: StubURLProtocol?
    nonisolated(unsafe) static var onRequest: (@Sendable () -> Void)?
    nonisolated(unsafe) static var results: [Result<(Data, URLResponse), Error>] = []
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        suspendFirst = false
        suspended = nil
        onRequest = nil
        results = []
        requestCount = 0
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request
        Self.onRequest?()
        if Self.suspendFirst, Self.requestCount == 1 {
            Self.suspended = self
            return
        }
        deliverNextResult()
    }

    static func releaseFirst() {
        let first = suspended
        suspended = nil
        first?.deliverNextResult()
    }

    private func deliverNextResult() {
        guard !Self.results.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        switch Self.results.removeFirst() {
        case .success(let result):
            client?.urlProtocol(self, didReceive: result.1, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.0)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class BurstTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ value: Double) { self.value = value }
    var now: Double { lock.withLock { value } }
    func set(_ value: Double) { lock.withLock { self.value = value } }
}
