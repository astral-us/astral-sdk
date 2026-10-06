import Foundation

/// Immutable, operation-scoped sender entry facts. The synchronous final guard has no actor hop.
struct FollowTurnBurstAuthorization: Sendable {
    let operationID: UInt64
    let sendEntryUptime: TimeInterval
    let deadline: TimeInterval
    let uptime: @Sendable () -> TimeInterval
    let isAuthorized: @Sendable () -> Bool
    let authorizeAttempt: (@Sendable () async -> Bool)?
    let didEnterAttempt: (@Sendable (FollowTurnTransportAttempt) -> Void)?

    init(operationID: UInt64, sendEntryUptime: TimeInterval, requestedBudget: TimeInterval,
         uptime: @escaping @Sendable () -> TimeInterval,
         isAuthorized: @escaping @Sendable () -> Bool = { true },
         authorizeAttempt: (@Sendable () async -> Bool)? = nil,
         didEnterAttempt: (@Sendable (FollowTurnTransportAttempt) -> Void)? = nil) {
        self.operationID = operationID
        self.sendEntryUptime = sendEntryUptime
        self.deadline = sendEntryUptime + requestedBudget
        self.uptime = uptime
        self.isAuthorized = isAuthorized
        self.authorizeAttempt = authorizeAttempt
        self.didEnterAttempt = didEnterAttempt
    }
}

enum FollowTurnBurstTransportDenial: Error {
    case expired, fenced, cancelled, invalidBudget
}

struct FollowTurnBurstSendReceipt {
    let transportAttempts: [FollowTurnTransportAttempt]
    let sendEntryUptime: TimeInterval
    let deadline: TimeInterval
    let responseUptime: TimeInterval
    let result: RoverCommandDiagnosticResult
    let stopObligation: Bool
    let stopObligationUptime: Double?

    init(transportAttempts: [FollowTurnTransportAttempt] = [], sendEntryUptime: TimeInterval,
         deadline: TimeInterval, responseUptime: TimeInterval, result: RoverCommandDiagnosticResult,
          stopObligation: Bool, stopObligationUptime: Double? = nil) {
        self.transportAttempts = transportAttempts
        self.sendEntryUptime = sendEntryUptime
        self.deadline = deadline
        self.responseUptime = responseUptime
        self.result = result
        self.stopObligation = stopObligation
        self.stopObligationUptime = stopObligationUptime
    }
}

struct FollowTurnTransportAttempt: Sendable {
    let operationID: UInt64
    let attempt: Int
    let entryUptime: TimeInterval
}

final class FollowTurnTransportCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [FollowTurnTransportAttempt] = []
    func record(_ entry: FollowTurnTransportAttempt) { lock.withLock { entries.append(entry) } }
    var attempts: [FollowTurnTransportAttempt] { lock.withLock { entries } }
}

struct FollowTurnBurstPendingStatus: Sendable {
    let operationID: UUID
    let deadline: TimeInterval
    let stopObligation: Bool
}

/// Synchronous invalidation can cross the sender's actor boundary without an authorizing await.
final class FollowTurnBurstFence: @unchecked Sendable {
    let identity = UUID()
    let deadline: TimeInterval
    private let lock = NSLock()
    private var permitted = true
    private var obligated = false
    private var obligationTime: Double?
    init(deadline: TimeInterval) { self.deadline = deadline }
    var authorized: Bool { lock.withLock { permitted } }
    var status: FollowTurnBurstPendingStatus {
        lock.withLock { .init(operationID: identity, deadline: deadline, stopObligation: obligated) }
    }
    var stopObligationUptime: Double? { lock.withLock { obligationTime } }
    func inhibit(at uptime: Double? = nil) {
        lock.withLock {
            permitted = false
            obligated = true
            if let uptime { obligationTime = min(obligationTime ?? .infinity, uptime) }
        }
    }
}

@MainActor
final class FollowTurnBurstDrain {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if completed { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish() {
        completed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

enum FollowTurnBurstTransportScope {
    @TaskLocal static var authorization: FollowTurnBurstAuthorization?
}
