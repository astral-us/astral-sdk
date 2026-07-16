import Foundation

/// Simulated team mesh: an in-process message bus standing in for a real wireless mesh
/// between Phrover units. Applies configurable per-link latency and packet loss so the
/// team-coordination layer (claim/bid allocation, heartbeats, re-auction) is exercised
/// against a realistically imperfect network, not an idealized one.
@MainActor
final class SimMesh {
    struct Message {
        let from: String
        let payload: [String: Any]
    }

    private var inboxes: [String: [Message]] = [:]
    private var members: Set<String> = []
    private let latency: TimeInterval
    private let lossRate: Double

    init(latency: TimeInterval = 0.3, lossRate: Double = 0.1) {
        self.latency = latency
        self.lossRate = lossRate
    }

    func join(_ id: String) {
        members.insert(id)
        if inboxes[id] == nil { inboxes[id] = [] }
    }

    func leave(_ id: String) {
        members.remove(id)
    }

    /// Broadcast to all OTHER current members, each independently delayed and possibly
    /// dropped — simulates per-link latency/loss, not one shared channel outage.
    func broadcast(from senderId: String, _ payload: [String: Any]) {
        for member in members where member != senderId {
            Task {
                try? await Task.sleep(for: .seconds(self.latency))
                if Double.random(in: 0..<1) < self.lossRate { return }
                self.inboxes[member, default: []].append(Message(from: senderId, payload: payload))
            }
        }
    }

    /// Drain and clear all messages waiting for `id`.
    func drain(_ id: String) -> [Message] {
        let msgs = inboxes[id] ?? []
        inboxes[id] = []
        return msgs
    }
}
