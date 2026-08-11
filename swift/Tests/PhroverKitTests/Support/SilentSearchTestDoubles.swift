import Foundation
import RoverNav
@testable import PhroverKit

@MainActor
final class ManualSilentSearchClock: SilentSearchClock {
    private struct Waiter {
        let id: UUID
        let deadline: SilentSearchInstant
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var wallNowMilliseconds: Int64
    private(set) var monotonicNow: SilentSearchInstant
    private var waiters: [Waiter] = []

    init(wallNowMilliseconds: Int64 = 0, monotonicNow: SilentSearchInstant = 0) {
        self.wallNowMilliseconds = wallNowMilliseconds
        self.monotonicNow = monotonicNow
    }

    func sleep(until deadline: SilentSearchInstant) async throws {
        if deadline <= monotonicNow { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id) }
        }
    }

    func advance(nanoseconds: Int64) {
        precondition(nanoseconds >= 0)
        monotonicNow += nanoseconds
        wallNowMilliseconds += nanoseconds / 1_000_000
        let ready = waiters.filter { $0.deadline <= monotonicNow }
        waiters.removeAll { $0.deadline <= monotonicNow }
        ready.forEach { $0.continuation.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@MainActor
final class FakeSilentSearchReadiness: SilentSearchReadinessChecking {
    var snapshot: SilentSearchReadiness

    init(_ snapshot: SilentSearchReadiness = .notReady) {
        self.snapshot = snapshot
    }
}

@MainActor
final class FakeSilentSearchCalibration: SilentSearchCalibrating {
    private var continuation: AsyncStream<SilentSearchCalibrationEvent>.Continuation?
    private(set) var requests: [(markerID: String, generation: UInt64)] = []
    private(set) var cancelCount = 0

    func events(markerID: String, sessionGeneration: UInt64) -> AsyncStream<SilentSearchCalibrationEvent> {
        requests.append((markerID, sessionGeneration))
        return AsyncStream { continuation = $0 }
    }

    func send(_ event: SilentSearchCalibrationEvent) {
        continuation?.yield(event)
    }

    func cancel() {
        cancelCount += 1
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
final class FakeSilentSearchOpticalExchange: SilentSearchOpticalExchanging {
    func present(payload: Data) async throws {}
    func scan(until deadline: SilentSearchInstant) async throws -> Data { Data() }
    func cancel() {}
}

@MainActor
final class FakeSilentSearchExplorer: SilentSearchExploring {
    var selection: SectorExplorerSelection = .exhausted
    func nextCandidate() async -> SectorExplorerSelection { selection }
    func markVisited(_ stableID: String) {}
    func markRejected(_ stableID: String, reason: SectorFrontierRejectionReason) {}
}

@MainActor
final class FakeSilentSearchTargetObserver: SilentSearchTargetObserving {
    var result: SilentSearchTargetObservationResult = .pending
    func observeNextFrame(until deadline: SilentSearchInstant) async -> SilentSearchTargetObservationResult {
        result
    }
}

@MainActor
final class FakeSilentSearchMotion: SilentSearchMotion {
    var currentMissionPose: MissionPose?
    var currentMissionPath: [MissionPoint] = []
    var result: SilentSearchMotionResult = .arrived
    private(set) var stopCount = 0
    var onStop: (() -> Void)?

    func navigate(to target: MissionPoint, policy: SilentSearchMotionPolicy) async -> SilentSearchMotionResult {
        result
    }

    func rotate(to heading: Double, tolerance: Double) async -> SilentSearchMotionResult {
        result
    }

    func stop() async {
        stopCount += 1
        onStop?()
    }
}

@MainActor
final class FakeSilentSearchSafetyMonitor: SilentSearchSafetyMonitoring {
    private var continuations: [UUID: AsyncStream<SilentSearchSafetyEvent>.Continuation] = [:]

    func events() -> AsyncStream<SilentSearchSafetyEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    func send(_ event: SilentSearchSafetyEvent) {
        continuations.values.forEach { $0.yield(event) }
    }

    var consumerCount: Int { continuations.count }
}

@MainActor
final class RecordingSilentSearchEventSink: SilentSearchEventSink {
    struct Entry: Equatable {
        let event: String
        let fields: [String: String]
    }

    private(set) var entries: [Entry] = []

    func record(event: String, fields: [String: String]) {
        entries.append(Entry(event: event, fields: fields))
    }
}

@MainActor
struct SilentSearchTestHarness {
    let clock = ManualSilentSearchClock()
    let readiness = FakeSilentSearchReadiness()
    let calibration = FakeSilentSearchCalibration()
    let optical = FakeSilentSearchOpticalExchange()
    let explorer = FakeSilentSearchExplorer()
    let targetObserver = FakeSilentSearchTargetObserver()
    let motion = FakeSilentSearchMotion()
    let safety = FakeSilentSearchSafetyMonitor()
    let events = RecordingSilentSearchEventSink()

    func coordinator() -> SilentSearchCoordinator {
        SilentSearchCoordinator(dependencies: SilentSearchDependencies(
            clock: clock,
            readiness: readiness,
            calibration: calibration,
            opticalExchange: optical,
            explorer: explorer,
            targetObserver: targetObserver,
            motion: motion,
            safety: safety,
            events: events
        ))
    }
}
