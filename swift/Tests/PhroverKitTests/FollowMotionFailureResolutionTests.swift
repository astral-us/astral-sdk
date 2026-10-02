import XCTest
@testable import PhroverKit

final class FollowMotionFailureResolutionTests: XCTestCase {
    private let pending = "Search rotation stopped: insufficient measured yaw progress. Confirming motor stop…"
    private let confirmed = "Search rotation stopped: insufficient measured yaw progress. Stop confirmed. Restart following to try again."
    private let blocked = "Motor stop could not be confirmed. Motion is blocked."

    private func delivery(_ source: FollowMotionDeliverySource, reason: NavigationFailure = .stalled,
                          stop: FollowMotionStopOutcome = .pending, stale: Bool = false,
                          purpose: FollowMotionPurpose? = .followScan) -> FollowMotionFailureDelivery {
        .init(context: .init(request: .init(sessionGeneration: 7, requestToken: 2, purpose: .followScan,
              phase: "searching"), controllerOperationID: 91, purpose: purpose,
              profile: nil), reason: reason, stopOutcome: stop, source: source, stale: stale)
    }

    func testBothOrdersRetainStallThroughWrapperCancellationAndAuthoritativeStop() {
        for order: [FollowMotionDeliverySource] in [[.stream, .result], [.result, .stream]] {
            var record = FollowMotionFailureResolution(delivery(order[0]))
            XCTAssertEqual(record.message, pending)
            record.consume(delivery(order[1], reason: .commandFailed))
            record.consume(delivery(.result, reason: .cancelled))
            XCTAssertEqual(record.primaryReason, .stalled)
            XCTAssertEqual(record.diagnosticReason, "no_yaw_progress")
            XCTAssertEqual(record.message, pending)
            record.consume(delivery(.confirmation, stop: .confirmed))
            XCTAssertEqual(record.message, confirmed)
            record.consume(delivery(.confirmation, reason: .commandFailed, stop: .failed))
            record.consume(delivery(.result, stop: .confirmed, stale: true))
            XCTAssertEqual(record.primaryReason, .stalled)
            XCTAssertEqual(record.stopOutcome, .failed)
            XCTAssertEqual(record.message, blocked)
            XCTAssertEqual(record.priority, 3)
        }
    }

    func testOperationKeyIsolationUnknownFactsAndStaleAcknowledgement() {
        let initial = delivery(.stream)
        var record = FollowMotionFailureResolution(initial)
        XCTAssertEqual(record.key, .init(generation: 7, operationID: 91))
        for (generation, operation) in [(UInt64(8), UInt64(91)), (7, 92)] {
            let foreign = FollowMotionOperationContext(request: .init(sessionGeneration: generation,
                requestToken: 2, purpose: .followAlignment, phase: "aligning"),
                controllerOperationID: operation, purpose: .followAlignment, profile: nil)
            record.consume(.init(context: foreign, reason: .commandFailed, stopOutcome: .failed, source: .stream))
            XCTAssertEqual(record.stopOutcome, .pending)
            XCTAssertEqual(record.context.request?.phase, "searching")
        }
        record.consume(delivery(.result, stop: .confirmed, stale: true))
        XCTAssertEqual(record.message, pending, "Stale success is not authoritative stop acknowledgement")
        let unknown = FollowMotionFailureResolution(delivery(.result, stop: .unknown, purpose: nil))
        XCTAssertEqual(unknown.diagnosticReason, "stalled")
        XCTAssertEqual(unknown.message, "Navigation stopped: insufficient measured progress.")
        XCTAssertNil(unknown.context.purpose)
    }

    func testLegacyRequestMappingDoesNotMergeUnknownControllerOperations() {
        let request = FollowMotionRequestContext(sessionGeneration: 7, requestToken: 2,
            purpose: .followScan, phase: "searching")
        let context = FollowMotionOperationContext(request: request, controllerOperationID: nil,
            purpose: nil, profile: nil)
        var record = FollowMotionFailureResolution(.init(context: context, reason: .stalled,
            stopOutcome: .unknown, source: .result))
        let other = FollowMotionOperationContext(request: .init(sessionGeneration: 7, requestToken: 3,
            purpose: .followReady, phase: "signalingReady"), controllerOperationID: nil, purpose: nil, profile: nil)
        record.consume(.init(context: other, reason: .commandFailed, stopOutcome: .failed, source: .stream))
        XCTAssertEqual(record.stopOutcome, .unknown)
        XCTAssertNil(record.key)
        XCTAssertEqual(record.diagnosticReason, "stalled")
    }
}
