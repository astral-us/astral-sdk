import Foundation
import PhroverKit

/// Wraps a cloud-primary/on-device-fallback pair behind a single `RoverBrain`, so
/// `MissionAgent` doesn't need to know anything about connectivity or failure recovery —
/// it just calls `nextAction` on whatever brain it was handed. Offline, or when the cloud
/// call fails mid-mission, falls through to the on-device brain so the mission keeps going
/// (best-effort, with reduced grounding) rather than stalling.
@MainActor
public final class HybridBrain: RoverBrain {
    private let cloud: RoverBrain
    private let onDevice: RoverBrain
    private let isOnline: () -> Bool

    public init(cloud: RoverBrain, onDevice: RoverBrain, isOnline: @escaping () -> Bool = { NetworkMonitor.shared.isOnline }) {
        self.cloud = cloud
        self.onDevice = onDevice
        self.isOnline = isOnline
    }

    public func nextAction(_ context: MissionContext) async throws -> BrainOutput {
        guard isOnline() else {
            RuntimeFileLog.append("mission_brain_selected", fields: ["brain": "on_device", "reason": "offline"])
            return try await onDevice.nextAction(context)
        }
        do {
            let output = try await cloud.nextAction(context)
            RuntimeFileLog.append("mission_brain_selected", fields: ["brain": "cloud"])
            return output
        } catch {
            RuntimeFileLog.append("mission_brain_selected", fields: [
                "brain": "on_device",
                "reason": "cloud_failed",
                "error": error.localizedDescription
            ])
            return try await onDevice.nextAction(context)
        }
    }
}
