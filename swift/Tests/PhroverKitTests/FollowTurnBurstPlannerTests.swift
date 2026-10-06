import XCTest
import PhroverKit

final class FollowTurnBurstPlannerTests: XCTestCase {
    private typealias Planner = FollowTurnBurstPlanner
    private func plan(target: Double, actual: Double = 0, purpose: Planner.Purpose = .alignment,
                      entry: Double = 100, authorized: Bool = true) -> Planner.Decision {
        Planner.plan(.init(actualYaw: actual, profile: .init(purpose: purpose),
            calibration: .init(operationID: 1, generation: 7, targetYaw: target, clockDomain: "test_uptime"),
            sendEntryUptime: entry, authorized: authorized))
    }

    func testFirstThreeDegreeProbeUsesWorkedSubMillisecondExcessWithoutFloor() {
        guard case let .burst(direction, budget) = plan(target: 0.05235987755982989) else {
            return XCTFail("Unknown response must permit one provisional probe")
        }
        XCTAssertEqual(direction, 1)
        XCTAssertEqual(budget, 0.0011267585362157, accuracy: 1e-14)
    }

    func testCircularErrorUsesInclusivePurposeToleranceAndExactPiNegativeDirection() {
        XCTAssertEqual(plan(target: 0.05), .arrived)
        XCTAssertEqual(plan(target: -0.05), .arrived)
        XCTAssertEqual(plan(target: 7 * .pi / 180, purpose: .scan), .arrived)
        XCTAssertEqual(plan(target: .pi), .burst(direction: -1, budget: 0.080))
        XCTAssertEqual(plan(target: -.pi), .burst(direction: -1, budget: 0.080))
        XCTAssertEqual(plan(target: 0.5235987755982988, purpose: .scan), .burst(direction: 1, budget: 0.080))
        XCTAssertEqual(plan(target: -0.5235987755982988, purpose: .scan), .burst(direction: -1, budget: 0.080))
        for (target, actual, sign) in [(-3.10, 3.10, 1), (3.10, -3.10, -1)] {
            guard case let .burst(direction, budget) = plan(target: target, actual: actual) else { return XCTFail() }
            XCTAssertEqual(direction, sign)
            XCTAssertEqual(budget, 0.015844817026962252, accuracy: 1e-14)
        }
    }

    func testInvalidAuthorityAndNonfiniteInputsAreUnavailableNotZeroError() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(plan(target: value), .unavailable)
            XCTAssertEqual(plan(target: 0, actual: value), .unavailable)
            XCTAssertEqual(plan(target: 1, entry: value), .unavailable)
        }
        XCTAssertEqual(plan(target: Double.greatestFiniteMagnitude, actual: -Double.greatestFiniteMagnitude), .unavailable)
        XCTAssertEqual(plan(target: 0, authorized: false), .unavailable)
        XCTAssertEqual(plan(target: 1, entry: -1), .unavailable)
    }

    private func initial(_ target: Double = 0.05235987755982989) -> Planner.Calibration {
        .init(operationID: 1, generation: 7, targetYaw: target, clockDomain: "test_uptime")
    }
    private func response(_ calibration: Planner.Calibration, budget: Double = 0.080,
                          samples: [Planner.Sample] = [], send: Double = 0.010,
                          stop: Double = 0.010, completion: Planner.Completion = .completed,
                          unambiguous: Bool = true, entry: Double = 100) -> Planner.Response {
        .init(operationID: calibration.operationID, generation: calibration.generation,
            targetYaw: calibration.targetYaw, clockDomain: calibration.clockDomain, completion: completion,
            requestedBudget: budget, sendEntryUptime: entry, sendResponseUptime: entry + send,
            stopObligationUptime: entry + 0.080, stopAcknowledgementUptime: entry + 0.080 + stop,
            samples: samples, traversalUnambiguous: unambiguous)
    }

    func testCompletedLatencyIsRetainedWithUnknownYawAndCoast() {
        let calibration = initial()
        let reduced = Planner.recording(response(calibration), in: calibration, profile: .init(purpose: .alignment))
        XCTAssertNil(reduced.rejection)
        XCTAssertEqual(reduced.calibration.completedResponses, 1)
        XCTAssertEqual(reduced.calibration.maximumSendDuration ?? -1, 0.010, accuracy: 1e-12)
        XCTAssertEqual(reduced.calibration.maximumStopDuration ?? -1, 0.010, accuracy: 1e-12)
        XCTAssertNil(reduced.calibration.observedPostAckTravel, "Unknown does not mean measured zero")
        XCTAssertEqual(reduced.calibration.responseRate, 2.0943951023931953, accuracy: 1e-14)
    }

    func testMeasuredLatencyTerminatesSmallCorrectionAndUnrepresentableDeadlineWithoutRetry() {
        let calibration = initial()
        let reduced = Planner.recording(response(calibration), in: calibration, profile: .init(purpose: .alignment)).calibration
        XCTAssertEqual(Planner.plan(.init(actualYaw: 0, profile: .init(purpose: .alignment), calibration: reduced,
            sendEntryUptime: 100)), .resolutionFailure(.rotationResolutionInsufficient))
        XCTAssertEqual(Planner.plan(.init(actualYaw: 0, profile: .init(purpose: .alignment), calibration: calibration,
            sendEntryUptime: 1e20)), .resolutionFailure(.rotationResolutionInsufficient))
        XCTAssertEqual(Planner.plan(.init(actualYaw: 0, profile: .init(purpose: .alignment), calibration: calibration,
            sendEntryUptime: 100, provisionalProbeIssued: true)), .resolutionFailure(.rotationResolutionInsufficient))
        XCTAssertEqual(Planner.plan(.init(actualYaw: calibration.targetYaw, profile: .init(purpose: .alignment),
            calibration: reduced, sendEntryUptime: 100)), .arrived)
    }

    private func sample(_ yaw: Double, _ sequence: UInt64? = 1, _ time: Double? = 99.9,
                        collected: Double? = nil, generation: UInt64? = 7,
                        domain: String? = "test_uptime", healthy: Bool = true) -> Planner.Sample {
        .init(yaw: yaw, sequence: sequence, generation: generation, sourceTimestamp: time,
            collectedUptime: collected ?? time ?? 99.9, clockDomain: domain, healthy: healthy)
    }

    func testInvalidResponseBracketsNeverLearnOrEraseOperationEvidence() {
        let calibration = initial(1)
        let profile = Planner.Profile(purpose: .alignment)
        let first = sample(0)
        let last = sample(0.1, 2, 100.4)
        var invalid: [Planner.Response] = []
        for completion: Planner.Completion in [.cancelled, .failed, .replaced, .ambiguous] {
            invalid.append(response(calibration, samples: [first, last], completion: completion))
        }
        for bad in [sample(.nan), sample(.infinity), sample(0, nil), sample(0, generation: nil),
                    sample(0, generation: 8), sample(0, domain: nil), sample(0, domain: "private_clock"),
                    sample(0, healthy: false), sample(0, 1, nil), sample(0, 1, .nan),
                    sample(0, collected: .infinity), sample(0, collected: 99.8), sample(0, collected: 100.401)] {
            invalid.append(response(calibration, samples: [bad, last]))
        }
        invalid.append(response(calibration, samples: [first, sample(0.1, 1, 100.4)]))
        invalid.append(response(calibration, samples: [first, sample(0.1, 2, 99.9)]))
        invalid.append(response(calibration, samples: [last, first]))
        invalid.append(response(calibration, samples: [first, last], unambiguous: false))
        invalid.append(response(calibration, budget: 0))
        invalid.append(response(calibration, budget: .nan))
        invalid.append(response(calibration, send: -0.01))
        invalid.append(response(calibration, stop: .infinity))
        invalid.append(response(initial(2), samples: [first, last]))
        invalid.append(.init(operationID: 2, generation: 7, targetYaw: 1, clockDomain: "test_uptime",
            requestedBudget: 0.08, sendEntryUptime: 100, sendResponseUptime: 100.01,
            stopObligationUptime: 100.08, stopAcknowledgementUptime: 100.09, samples: [first, last]))
        for evidence in invalid {
            let result = Planner.recording(evidence, in: calibration, profile: profile)
            XCTAssertNotNil(result.rejection)
            XCTAssertEqual(result.calibration, calibration, "Rejected evidence must not learn latency, rate, or coast")
        }
        let inclusive = Planner.recording(response(calibration, samples: [sample(0, 1, 99.5, collected: 100), last]),
            in: calibration, profile: profile)
        XCTAssertNil(inclusive.rejection, "Age 0.500 at collection is valid even when retained evidence ages")
    }

    func testWrappedSampledResponseRetainsRateLatencyAndPartialTravelMaxima() {
        let calibration = initial(0)
        let profile = Planner.Profile(purpose: .alignment)
        let wrapped = [sample(3.1), sample(-2.983185307179586, 2, 100.1), sample(-2.883185307179586, 3, 100.4)]
        let first = Planner.recording(response(calibration, samples: wrapped), in: calibration, profile: profile)
        XCTAssertNil(first.rejection)
        XCTAssertEqual(first.calibration.responseRate, 3.75, accuracy: 1e-12)
        XCTAssertEqual(first.calibration.observedPostAckTravel ?? -1, 0.1, accuracy: 1e-12)
        guard case let .burst(direction, budget) = Planner.plan(.init(actualYaw: -0.4, profile: profile,
            calibration: first.calibration, sendEntryUptime: 101)) else { return XCTFail() }
        XCTAssertEqual(direction, 1)
        XCTAssertEqual(budget, 0.04666666666666667, accuracy: 1e-12)
        let low = Planner.recording(response(calibration, samples: [sample(0, 4, 100.9), sample(0, 5, 101.4)],
            send: 0.001, stop: 0.001, entry: 101), in: first.calibration, profile: profile)
        XCTAssertNil(low.rejection)
        XCTAssertEqual(low.calibration.responseRate, first.calibration.responseRate)
        XCTAssertEqual(low.calibration.maximumSendDuration, first.calibration.maximumSendDuration)
        XCTAssertEqual(low.calibration.maximumStopDuration, first.calibration.maximumStopDuration)
        XCTAssertEqual(low.calibration.observedPostAckTravel, first.calibration.observedPostAckTravel)
        let single = Planner.recording(response(calibration, samples: [sample(0, 2, 100.4)]), in: calibration, profile: profile)
        XCTAssertNil(single.calibration.observedPostAckTravel, "A single post-ack frame cannot establish zero coast")
        let consecutive = Planner.recording(response(calibration, samples: [sample(0), sample(0.5, 2, 100),
            sample(0.2, 3, 100.4)]), in: calibration, profile: profile)
        XCTAssertEqual(consecutive.calibration.responseRate, 5, accuracy: 1e-10)
        let negative = Planner.recording(response(calibration, samples: [sample(-3.1), sample(2.983185307179586, 2, 100.1),
            sample(2.883185307179586, 3, 100.4)]), in: calibration, profile: profile)
        XCTAssertEqual(negative.calibration.responseRate, 3.75, accuracy: 1e-12)
    }

    func testDirectedOvershootShrinksNextCeilingWithoutMistakingPiSeamForCrossing() {
        let profile = Planner.Profile(purpose: .alignment)
        for sign in [1.0, -1.0] {
            let calibration = initial(sign * 0.1)
            let reduced = Planner.recording(response(calibration, samples: [sample(0), sample(sign * 0.2, 2, 100.4)],
                send: 0, stop: 0), in: calibration, profile: profile)
            XCTAssertNil(reduced.rejection)
            XCTAssertEqual(reduced.calibration.overshootCeiling ?? -1, 0.020, accuracy: 1e-12)
            guard case let .burst(direction, budget) = Planner.plan(.init(actualYaw: sign * 0.2, profile: profile,
                calibration: reduced.calibration, sendEntryUptime: 101)) else { return XCTFail() }
            XCTAssertEqual(direction, sign > 0 ? -1 : 1)
            XCTAssertEqual(budget, 0.020, accuracy: 1e-12)
            guard case let .burst(_, largerBudget) = Planner.plan(.init(actualYaw: -sign, profile: profile,
                calibration: reduced.calibration, sendEntryUptime: 101)) else { return XCTFail() }
            XCTAssertEqual(largerBudget, 0.020, accuracy: 1e-12)
        }
        let seam = initial(-3.0)
        let notCrossed = Planner.recording(response(seam, samples: [sample(0), sample(0.2, 2, 100.4)],
            send: 0, stop: 0), in: seam, profile: profile)
        XCTAssertNil(notCrossed.calibration.overshootCeiling, "Normalized error changes sign here without directed target crossing")
        let ambiguous = Planner.recording(response(initial(0.1), samples: [sample(0), sample(.pi, 2, 100.4)]),
            in: initial(0.1), profile: profile)
        XCTAssertNotNil(ambiguous.rejection)
        XCTAssertEqual(Planner.plan(.init(actualYaw: 0.2, profile: profile, calibration: ambiguous.calibration,
            sendEntryUptime: 101, provisionalProbeIssued: true)), .resolutionFailure(.rotationResolutionInsufficient))
    }

    func testReplayedResponseAndFramesCannotCalibrateANewerBurst() {
        let calibration = initial(1)
        let profile = Planner.Profile(purpose: .alignment)
        let old = response(calibration, samples: [sample(0), sample(0.1, 2, 100.4)])
        let retained = Planner.recording(old, in: calibration, profile: profile).calibration
        let replay = Planner.recording(old, in: retained, profile: profile)
        XCTAssertNotNil(replay.rejection)
        XCTAssertEqual(replay.calibration, retained)
        let oldIDs = Planner.recording(response(calibration, samples: [sample(0.1, 2, 100.9), sample(0.2, 3, 101.4)],
            entry: 101), in: retained, profile: profile)
        XCTAssertNotNil(oldIDs.rejection)
        XCTAssertEqual(oldIDs.calibration, retained)
        let staleSourceTime = Planner.recording(response(calibration, samples: [sample(0.1, 3, 100.4, collected: 100.9),
            sample(0.2, 4, 101.4)], entry: 101), in: retained, profile: profile)
        XCTAssertNotNil(staleSourceTime.rejection)
        XCTAssertEqual(staleSourceTime.calibration, retained)
    }

    func testSampledTravelPreservesReversalsAndRejectsNonfiniteRateWithoutFullTurnInference() {
        let calibration = initial(1)
        let profile = Planner.Profile(purpose: .alignment)
        let reduced = Planner.recording(response(calibration, samples: [sample(0), sample(0.5, 2, 100),
            sample(0.2, 3, 100.4)]), in: calibration, profile: profile)
        XCTAssertEqual(reduced.signedResponse ?? -1, 0.2, accuracy: 1e-12)
        XCTAssertEqual(reduced.sampledAbsoluteTravel ?? -1, 0.8, accuracy: 1e-12)
        let nonfinite = Planner.recording(response(calibration, budget: Double.leastNonzeroMagnitude,
            samples: [sample(0), sample(1, 2, 100.4)]), in: calibration, profile: profile)
        XCTAssertNotNil(nonfinite.rejection)
        XCTAssertEqual(nonfinite.calibration, calibration)
        let unknown = Planner.recording(response(calibration), in: calibration, profile: profile)
        XCTAssertNil(unknown.signedResponse)
        XCTAssertNil(unknown.sampledAbsoluteTravel)
    }

    func testAdjacentBurstsMayShareTheExactSettledBoundaryWithoutFabricatedAdvancement() {
        let calibration = initial(1)
        let profile = Planner.Profile(purpose: .alignment)
        let settled = sample(0.1, 2, 100.4)
        let first = Planner.recording(response(calibration, samples: [sample(0), settled]), in: calibration, profile: profile)
        let next = Planner.recording(response(calibration, samples: [settled, sample(0.2, 3, 101.4)], entry: 101),
            in: first.calibration, profile: profile)
        XCTAssertNil(next.rejection)
        XCTAssertEqual(next.calibration.completedResponses, 2)
        let forged = Planner.recording(response(calibration, samples: [sample(0.15, 2, 100.4), sample(0.2, 3, 101.4)],
            entry: 101), in: first.calibration, profile: profile)
        XCTAssertNotNil(forged.rejection)
        XCTAssertEqual(forged.calibration, first.calibration)
    }

    func testExactlyZeroCandidateIsTerminalAndStopAllowanceIncludesPendingSendDrain() {
        let calibration = initial(0.3625)
        let profile = Planner.Profile(purpose: .alignment)
        let measured = Planner.recording(response(calibration, samples: [sample(0), sample(0.2, 2, 100.6)],
            send: 0, stop: 0.125), in: calibration, profile: profile)
        XCTAssertNil(measured.rejection)
        XCTAssertEqual(Planner.plan(.init(actualYaw: 0, profile: profile, calibration: measured.calibration,
            sendEntryUptime: 101)), .resolutionFailure(.rotationResolutionInsufficient))
        let drain = Planner.Response(operationID: 1, generation: 7, targetYaw: 1, clockDomain: "test_uptime",
            requestedBudget: 0.080, sendEntryUptime: 100, sendResponseUptime: 100.2,
            stopObligationUptime: 100.08, stopAcknowledgementUptime: 100.23, samples: [])
        let result = Planner.recording(drain, in: initial(1), profile: profile)
        XCTAssertNil(result.rejection)
        XCTAssertEqual(result.calibration.maximumSendDuration ?? -1, 0.2, accuracy: 1e-12)
        XCTAssertEqual(result.calibration.maximumStopDuration ?? -1, 0.15, accuracy: 1e-12)
    }

    func testFiniteEndpointValuesCannotHideAnOverflowedTargetError() {
        let calibration = initial(Double.greatestFiniteMagnitude)
        let result = Planner.recording(response(calibration, samples: [sample(-Double.greatestFiniteMagnitude),
            sample(-Double.greatestFiniteMagnitude, 2, 100.4)]), in: calibration, profile: .init(purpose: .alignment))
        XCTAssertNotNil(result.rejection)
        XCTAssertEqual(result.calibration, calibration)
    }

    func testPartialPostAckBracketMeasuresTravelWithoutInventingNetBurstResponse() {
        let calibration = initial(1)
        let reduced = Planner.recording(response(calibration, samples: [sample(0.1, 2, 100.1), sample(0.2, 3, 100.4)]),
            in: calibration, profile: .init(purpose: .alignment))
        XCTAssertNil(reduced.rejection)
        XCTAssertEqual(reduced.calibration.completedResponses, 1)
        XCTAssertEqual(reduced.calibration.maximumSendDuration ?? -1, 0.010, accuracy: 1e-12)
        XCTAssertEqual(reduced.calibration.observedPostAckTravel ?? -1, 0.1, accuracy: 1e-12)
        XCTAssertEqual(reduced.calibration.responseRate, 2.0943951023931953, accuracy: 1e-12)
        XCTAssertNil(reduced.signedResponse, "No pre-send endpoint means no measured net burst response")
    }
}
