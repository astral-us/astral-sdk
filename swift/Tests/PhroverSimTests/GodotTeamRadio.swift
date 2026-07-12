import Foundation
import RoverNav
import PhroverKit

/// `RoverTeamRadio` backed by `SimMesh`. Deliberately thin: relays claim announcements
/// and heartbeats between team members and exposes the current team state via
/// `currentTeamContext()` — all ALLOCATION REASONING (who should claim what, what to do
/// when a teammate goes silent) is the real brain's own job via `RoverDecision.claimRoom`
/// (see `MISSION_AGENT_SYSTEM_PROMPT` in aws/src/rover.py). This class only relays
/// messages and tracks claim/heartbeat freshness, matching the boundary
/// `RoverTeamRadio`'s own doc comment describes — it does not decide anything.
@MainActor
final class GodotTeamRadio: RoverTeamRadio {
    let roverId: String
    private let mesh: SimMesh
    let rooms: [TeamContext.Room]
    private let heartbeatInterval: TimeInterval
    private let deadTimeout: TimeInterval

    private var claimedBy: [String: String] = [:]   // roomId -> roverId
    private var lastHeartbeat: [String: Date] = [:]
    private let knownRovers: Set<String>
    private var heartbeatTask: Task<Void, Never>?
    /// Mission start — a teammate we haven't heard from YET is presumed alive until this
    /// long has passed, not presumed dead. Without this, every rover judges every OTHER
    /// rover dead on literally the first tick (nothing has had time to cross the mesh's
    /// latency yet), and all three independently over-claim before ever hearing from each
    /// other. Confirmed live: real CloudBrain instances did self-correct via reconciliation
    /// once claims started arriving, but this grace period makes the negotiation itself
    /// the thing being demonstrated, not a redundant-claim cleanup.
    private let missionStart = Date()

    init(roverId: String, mesh: SimMesh, rooms: [TeamContext.Room], allRoverIds: [String],
         heartbeatInterval: TimeInterval = 1.0, deadTimeout: TimeInterval = 4.0) {
        self.roverId = roverId
        self.mesh = mesh
        self.rooms = rooms
        self.heartbeatInterval = heartbeatInterval
        self.deadTimeout = deadTimeout
        self.knownRovers = Set(allRoverIds)
        mesh.join(roverId)
        lastHeartbeat[roverId] = Date()
        startHeartbeat()
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.mesh.broadcast(from: self.roverId, ["type": "heartbeat", "rover": self.roverId])
                try? await Task.sleep(for: .seconds(self.heartbeatInterval))
            }
        }
    }

    private func drainMesh() {
        for msg in mesh.drain(roverId) {
            switch msg.payload["type"] as? String {
            case "heartbeat":
                if let rover = msg.payload["rover"] as? String { lastHeartbeat[rover] = Date() }
            case "claim":
                if let rover = msg.payload["rover"] as? String, let room = msg.payload["room"] as? String {
                    claimedBy[room] = rover
                }
            default:
                break
            }
        }
    }

    func currentTeamContext() -> TeamContext? {
        drainMesh()
        lastHeartbeat[roverId] = Date()  // I know I'm alive
        let now = Date()
        let teammates = knownRovers.filter { $0 != roverId }.map { rover -> TeamContext.Teammate in
            let alive: Bool
            if let last = lastHeartbeat[rover] {
                alive = now.timeIntervalSince(last) <= deadTimeout
            } else {
                // Never heard from them yet — presume alive until the grace period
                // (mission start + deadTimeout) elapses, not on the very first tick.
                alive = now.timeIntervalSince(missionStart) <= deadTimeout
            }
            let claimed = claimedBy.filter { $0.value == rover }.map { $0.key }
            return TeamContext.Teammate(id: rover, alive: alive, claimedRoomIds: claimed)
        }
        return TeamContext(myId: roverId, rooms: rooms, teammates: teammates)
    }

    func broadcastClaim(_ roomId: String) {
        claimedBy[roomId] = roverId
        mesh.broadcast(from: roverId, ["type": "claim", "rover": roverId, "room": roomId])
    }

    func stop() {
        heartbeatTask?.cancel()
        mesh.leave(roverId)
    }
}
