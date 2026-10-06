import Foundation
import RoverNav

struct FollowTurnBurstExecutionReceipt {
    let send: FollowTurnBurstSendReceipt
    let confirmedStopFence: FollowTurnStopFence?
    var stopObligationUptime: Double? = nil
}

/// One serialized burst. The controller supplies operation-fenced boundaries;
/// this executor never creates another motor owner or interprets a stop as arrival.
@MainActor
enum FollowTurnBurstExecutor {
    static func execute(command: WheelCommand, budget: Double,
                        send: (WheelCommand, Double) async -> FollowTurnBurstSendReceipt,
                        waitRemaining: (FollowTurnBurstSendReceipt) async -> Void,
                        stop: () async throws -> FollowTurnStopFence?) async throws -> FollowTurnBurstExecutionReceipt {
        let receipt = await send(command, budget)
        if receipt.result.failure == nil, !receipt.stopObligation {
            await waitRemaining(receipt)
        }
        let fence = try await stop()
        return .init(send: receipt, confirmedStopFence: fence)
    }
}

/// Shared follow operation loop. Its target and progress epoch are never rebased
/// at burst stops. Controller closures retain source, safety and motor ownership.
@MainActor
enum FollowTurnOperationExecutor {
    static func execute(targetYaw: Double, generation: UInt64, operationID: UInt64,
                         profile: FollowTurnBurstPlanner.Profile,
                         runtime: FollowTurnRuntimeState,
                        uptime: () -> Double, now: () -> Date, authorized: () -> Bool,
                        admit: (FollowTurnWaitingProgress) async -> FollowTurnSourceResult,
                         burst: (WheelCommand, Double, FollowTurnWaitingProgress, FollowTurnBurstPlanner.Sample?) async throws -> FollowTurnBurstExecutionReceipt,
                          stoppedSource: (FollowTurnStopFence, FollowTurnWaitingProgress) async -> FollowTurnSourceResult,
                          diagnostic: (FollowTurnBurstPlanner.Calibration, NavigationPoseSample, FollowTurnBurstPlanner.Decision, Double) -> Void,
                          reduced: (FollowTurnBurstPlanner.Response, FollowTurnBurstPlanner.Reduction) -> Void,
                         response: (FollowTurnBurstExecutionReceipt, Double, NavigationPoseSample) -> FollowTurnBurstPlanner.Response?) async -> NavigationResult {
        var calibration = FollowTurnBurstPlanner.Calibration(operationID: operationID, generation: generation,
            targetYaw: targetYaw, clockDomain: "ar_system_uptime")
        var progress: FollowTurnWaitingProgress {
            get { runtime.progress }
            set { runtime.progress = newValue }
        }
        var probeIssued = false
        while authorized(), !Task.isCancelled {
            let selection = await admit(progress)
            guard authorized(), !Task.isCancelled else { return .cancelled }
            if let failure = runtime.failure { return .failed(failure) }
            let sample: NavigationPoseSample
            switch selection {
            case .sample(let value): sample = value
            case .failed(let reason): return .failed(reason)
            case .cancelled: return .cancelled
            }
            guard let pose = sample.pose else { return .failed(.trackingLost) }
            progress.distanceToGoal = abs(FollowReacquisitionPlanner.wrap(targetYaw - pose.yaw))
            let planningUptime = uptime()
            let decision = FollowTurnBurstPlanner.plan(.init(actualYaw: pose.yaw, profile: profile,
                calibration: calibration, sendEntryUptime: planningUptime, provisionalProbeIssued: probeIssued))
            diagnostic(calibration, sample, decision, planningUptime)
            switch decision {
            case .arrived: return .arrived
            case .resolutionFailure(let reason): return .failed(reason)
            case .unavailable: return .failed(.trackingLost)
            case .burst(let direction, let budget):
                if progress.watchdog.observe(distanceToGoal: progress.distanceToGoal, now: now(), commanded: true) {
                    return .failed(.stalled)
                }
                let signed = Double(direction) * profile.fixedWheelMagnitude
                let receipt: FollowTurnBurstExecutionReceipt
                do { receipt = try await burst(.init(left: -signed, right: signed), budget, progress, calibration.lastSourceSample) }
                catch {
                    return authorized() && !Task.isCancelled ? .failed(.commandFailed) : .cancelled
                }
                probeIssued = true
                guard authorized(), !Task.isCancelled else { return .cancelled }
                guard let fence = receipt.confirmedStopFence else { return .failed(.commandFailed) }
                runtime.expire(at: now())
                if let failure = runtime.failure { return .failed(failure) }
                if receipt.send.result.failure != nil { return .failed(.commandFailed) }
                let settled: NavigationPoseSample
                switch await stoppedSource(fence, progress) {
                case .sample(let sample): settled = sample
                case .failed(let reason): return .failed(reason)
                case .cancelled: return .cancelled
                }
                guard authorized(), !Task.isCancelled else { return .cancelled }
                runtime.expire(at: now())
                if let failure = runtime.failure { return .failed(failure) }
                // Calibration validity and actual stopped arrival are independent.
                // Preserve rejected-bracket diagnostics without learning or retrying.
                let reduction = response(receipt, budget, settled).map { captured in
                    let reduction = FollowTurnBurstPlanner.recording(captured, in: calibration, profile: profile)
                    reduced(captured, reduction)
                    return reduction
                }
                guard let pose = settled.pose else { return .failed(.trackingLost) }
                let error = abs(FollowReacquisitionPlanner.wrap(targetYaw - pose.yaw))
                guard error.isFinite else { return .failed(.trackingLost) }
                if error <= profile.tolerance {
                    diagnostic(reduction?.calibration ?? calibration, settled, .arrived, uptime())
                    return .arrived
                }
                guard let reduction else { return .failed(.rotationResolutionInsufficient) }
                guard reduction.rejection == nil else { return .failed(.rotationResolutionInsufficient) }
                calibration = reduction.calibration
            }
        }
        return .cancelled
    }
}
