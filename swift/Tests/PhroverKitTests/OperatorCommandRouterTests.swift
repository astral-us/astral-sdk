import XCTest
@testable import PhroverKit

@MainActor
final class OperatorCommandRouterTests: XCTestCase {
    func testFollowPhraseCancelsMissionBeforeStartingFollow() async {
        let mission = RecordingOperatorMission()
        let follow = RecordingOperatorFollow()
        let router = OperatorCommandRouter(mission: mission, follow: follow)

        let response = await router.submit(" Follow Me! ")

        XCTAssertEqual(response, .accepted)
        XCTAssertEqual(mission.events, ["stop"])
        XCTAssertEqual(follow.starts, 1)
        XCTAssertEqual(follow.missionStopsAtStart, 1)
    }

    func testOrdinaryCommandIsForwardedUnchanged() async {
        let mission = RecordingOperatorMission()
        let follow = RecordingOperatorFollow()
        let router = OperatorCommandRouter(mission: mission, follow: follow)

        let response = await router.submit("  please stop at the door  ")
        XCTAssertEqual(response, .accepted)
        await Task.yield()
        XCTAssertEqual(mission.events, ["handle:  please stop at the door  "])
        XCTAssertEqual(follow.starts, 0)
    }

    func testStopPreemptsDelayedFollowStart() async {
        let mission = RecordingOperatorMission()
        mission.suspendStop = true
        let follow = RecordingOperatorFollow()
        let router = OperatorCommandRouter(mission: mission, follow: follow)

        let starting = Task { await router.submit("follow me") }
        await mission.waitForStop()
        XCTAssertEqual(follow.starts, 0)
        let stopping = Task { await router.submit("stop") }
        await Task.yield()
        mission.releaseStop()
        _ = await starting.value
        _ = await stopping.value
        XCTAssertEqual(follow.starts, 0)
    }

    func testBlankAndOrdinaryDuringFollowAreRejected() async {
        let mission = RecordingOperatorMission()
        let follow = RecordingOperatorFollow()
        let router = OperatorCommandRouter(mission: mission, follow: follow)
        let blank = await router.submit("  ")
        let followRequest = await router.submit("follow me")
        let ordinary = await router.submit("go to the kitchen")
        XCTAssertNotEqual(blank, .accepted)
        XCTAssertEqual(followRequest, .accepted)
        XCTAssertNotEqual(ordinary, .accepted)
        XCTAssertEqual(follow.starts, 1)
        XCTAssertEqual(mission.events, ["stop"])
    }

    func testFollowDoesNotStartWhileAnotherTabOwnsMotion() async {
        let mission = RecordingOperatorMission()
        let follow = RecordingOperatorFollow()
        let router = OperatorCommandRouter(mission: mission, follow: follow,
                                           mayStartFollow: { false })
        let response = await router.submit("follow me")
        XCTAssertNotEqual(response, .accepted)
        XCTAssertEqual(follow.starts, 0)
        XCTAssertTrue(mission.events.isEmpty)
    }

    func testRepeatedStopWaitsForMotorAcknowledgement() async {
        let mission = RecordingOperatorMission()
        let follow = RecordingOperatorFollow()
        let router = OperatorCommandRouter(mission: mission, follow: follow)
        _ = await router.submit("follow me")
        follow.suspendStop = true
        let first = Task { await router.stop() }
        await follow.waitForStop()
        var secondFinished = false
        let second = Task { let result = await router.stop(); secondFinished = true; return result }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(secondFinished, "A second tab request must not assume stop is confirmed")
        follow.releaseStop()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, .accepted)
        XCTAssertEqual(secondResult, .accepted)
    }

    func testFailedStopCanBeRetriedAfterMotorLinkRecovers() async {
        let follow = RecordingOperatorFollow()
        let router = OperatorCommandRouter(mission: RecordingOperatorMission(), follow: follow)
        _ = await router.submit("follow me")
        follow.stopSucceeds = false
        let failed = await router.stop()
        XCTAssertNotEqual(failed, .accepted)
        follow.stopSucceeds = true
        let retried = await router.stop()
        XCTAssertEqual(retried, .accepted)
        XCTAssertEqual(follow.stopAttempts, 2)
    }
}

@MainActor
private final class RecordingOperatorMission: OperatorMission {
    var events: [String] = []
    var suspendStop = false
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var requestedWaiter: CheckedContinuation<Void, Never>?
    private var stopRequested = false

    func handle(_ text: String) async { events.append("handle:\(text)") }
    func cancelCurrentMissionAndWait() async throws {
        events.append("stop")
        stopRequested = true
        requestedWaiter?.resume()
        requestedWaiter = nil
        if suspendStop { await withCheckedContinuation { stopWaiter = $0 } }
    }
    func waitForStop() async {
        if stopRequested { return }
        await withCheckedContinuation { requestedWaiter = $0 }
    }
    func releaseStop() { suspendStop = false; stopWaiter?.resume(); stopWaiter = nil }
}

@MainActor
private final class RecordingOperatorFollow: OperatorFollow {
    var state: FollowMeState = .idle
    var starts = 0
    var missionStopsAtStart = 1
    var suspendStop = false
    var stopSucceeds = true
    private(set) var stopAttempts = 0
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var requestedWaiter: CheckedContinuation<Void, Never>?
    private var stopRequested = false
    func start() async -> Bool { starts += 1; state = .searching; return true }
    func stop() async -> Bool {
        stopAttempts += 1
        stopRequested = true
        requestedWaiter?.resume()
        requestedWaiter = nil
        if suspendStop { await withCheckedContinuation { stopWaiter = $0 } }
        if stopSucceeds { state = .stopped }
        return stopSucceeds
    }
    func waitForStop() async {
        if stopRequested { return }
        await withCheckedContinuation { requestedWaiter = $0 }
    }
    func releaseStop() { suspendStop = false; stopWaiter?.resume(); stopWaiter = nil }
}
