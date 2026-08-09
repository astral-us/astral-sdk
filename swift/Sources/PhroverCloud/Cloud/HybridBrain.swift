import Foundation
import PhroverKit

/// Wraps an on-device-primary/cloud-fallback pair behind a single `RoverBrain`, so
/// `MissionAgent` doesn't need to know anything about connectivity or failure recovery.
/// The local Apple Intelligence brain always gets a bounded first chance; cloud is an
/// optional second stage for online missions when that primary stage cannot respond.
@MainActor
public final class HybridBrain: RoverBrain {
    private let cloud: RoverBrain?
    private let onDevice: RoverBrain
    private let primaryTimeout: Duration
    private let isOnline: () -> Bool

    public init(
        cloud: RoverBrain?,
        onDevice: RoverBrain,
        primaryTimeout: Duration = .seconds(1.5),
        isOnline: @escaping () -> Bool = { NetworkMonitor.shared.isOnline }
    ) {
        self.cloud = cloud
        self.onDevice = onDevice
        self.primaryTimeout = primaryTimeout
        self.isOnline = isOnline
    }

    public func nextAction(_ context: MissionContext) async throws -> BrainOutput {
        switch await PrimaryStageRace.run(brain: onDevice, context: context, timeout: primaryTimeout) {
        case .output(let output):
            logSelection("on_device", reason: "primary")
            return output
        case .failure(let error):
            return try await cloudAction(context, reason: "on_device_failed", primaryError: error)
        case .timedOut:
            return try await cloudAction(
                context,
                reason: "on_device_timed_out",
                primaryError: PrimaryStageTimeoutError(timeout: primaryTimeout)
            )
        }
    }

    private func cloudAction(
        _ context: MissionContext,
        reason: String,
        primaryError: Error
    ) async throws -> BrainOutput {
        guard let cloud, isOnline() else {
            logSelection("on_device", reason: reason, error: primaryError)
            throw primaryError
        }

        do {
            let output = try await cloud.nextAction(context)
            logSelection("cloud", reason: reason, error: primaryError)
            return output
        } catch {
            logSelection("cloud", reason: "cloud_failed", error: error)
            throw error
        }
    }

    private func logSelection(_ brain: String, reason: String, error: Error? = nil) {
        var fields = ["brain": brain, "reason": reason]
        if let error {
            fields["error"] = error.localizedDescription
        }
        RuntimeFileLog.append("mission_brain_selected", fields: fields)
    }
}

private enum PrimaryStageResult {
    case output(BrainOutput)
    case failure(Error)
    case timedOut
}

@MainActor
private final class PrimaryStageRace {
    private var continuation: CheckedContinuation<PrimaryStageResult, Never>?
    private var tasks: [Task<Void, Never>] = []

    static func run(brain: RoverBrain, context: MissionContext, timeout: Duration) async -> PrimaryStageResult {
        let race = PrimaryStageRace()
        let result = await withCheckedContinuation { continuation in
            race.continuation = continuation
            race.tasks = [
                Task { @MainActor in
                    do {
                        race.finish(.output(try await brain.nextAction(context)))
                    } catch {
                        race.finish(.failure(error))
                    }
                },
                Task { @MainActor in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    race.finish(.timedOut)
                }
            ]
        }
        for task in race.tasks {
            await task.value
        }
        return result
    }

    private func finish(_ result: PrimaryStageResult) {
        guard let continuation else { return }
        self.continuation = nil
        tasks.forEach { $0.cancel() }
        continuation.resume(returning: result)
    }
}

private struct PrimaryStageTimeoutError: LocalizedError {
    let timeout: Duration

    var errorDescription: String? {
        "On-device brain did not respond within \(timeout)."
    }
}
