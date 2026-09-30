import Foundation
import RoverNav
@testable import PhroverKit

@MainActor
final class ManualFollowClock: FollowMeClock {
    private(set) var now: TimeInterval = 0
    private var sleepers: [(TimeInterval, CheckedContinuation<Void, Never>)] = []

    func sleep(seconds: Double) async {
        await withCheckedContinuation { sleepers.append((now + seconds, $0)) }
    }

    func advance(to time: TimeInterval) {
        now = time
        let ready = sleepers.filter { $0.0 <= time }
        sleepers.removeAll { $0.0 <= time }
        for (_, continuation) in ready { continuation.resume() }
    }
}

@MainActor
final class FollowPerceptionFake: FollowMePerception {
    var detectorReady = true
    var personLabelAvailable = true
    private var continuation: AsyncStream<FollowPerceptionEvent>.Continuation?
    func events() -> AsyncStream<FollowPerceptionEvent> {
        AsyncStream { continuation = $0 }
    }
    func send(_ event: FollowPerceptionEvent) { continuation?.yield(event) }
}

@MainActor
final class FollowMotionFake: FollowMeMotion {
    private(set) var rotations: [Double] = []
    private(set) var goals: [Vec2] = []
    private(set) var clearances: [Double] = []
    private(set) var stops = 0
    var stopError = false
    var suspendStop = false
    var suspendRotation = false
    var suspendNavigation = false
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var rotationWaiter: CheckedContinuation<Void, Never>?
    private var navigationWaiter: CheckedContinuation<Void, Never>?
    private var safetyContinuation: AsyncStream<NavigationSafetyState>.Continuation?

    func rotateForScan(by angle: Double) async -> NavigationResult {
        rotations.append(angle)
        if suspendRotation { await withCheckedContinuation { rotationWaiter = $0 } }
        return .arrived
    }
    func navigate(to goal: Vec2, stoppingAtForwardClearance clearance: Double) async -> NavigationResult {
        goals.append(goal)
        clearances.append(clearance)
        if suspendNavigation { await withCheckedContinuation { navigationWaiter = $0 } }
        return .arrived
    }
    func stopAndConfirm() async throws {
        stops += 1
        if suspendStop { await withCheckedContinuation { stopWaiter = $0 } }
        if stopError { throw StopError.unconfirmed }
    }
    func releaseStop() { stopWaiter?.resume(); stopWaiter = nil }
    func releaseRotation() { rotationWaiter?.resume(); rotationWaiter = nil }
    func releaseNavigation() { navigationWaiter?.resume(); navigationWaiter = nil }
    func safetyStates() -> AsyncStream<NavigationSafetyState> {
        AsyncStream { safetyContinuation = $0 }
    }
    func safety(_ state: NavigationSafetyState) { safetyContinuation?.yield(state) }
    private enum StopError: Error { case unconfirmed }
}
