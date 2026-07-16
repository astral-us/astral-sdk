import Foundation
import PhroverKit

/// `RoverBattery` backed by the Godot Depot sim's `phrover_state` battery field (see
/// phrover_manager.gd — drains per second + per metre travelled, accelerated by the
/// `battery_drain` inject). Stands in for `DeviceBattery` (the real iPhone battery) so
/// capability #4 (self-model / calibrated uncertainty) can be exercised deterministically.
@MainActor
final class GodotBattery: RoverBattery {
    private let link: GodotLink
    private let rid: String

    init(link: GodotLink, rid: String) {
        self.link = link
        self.rid = rid
    }

    var percent: Double? {
        let r = link.call(["op": "phrover_state", "id": rid])
        guard r["ok"] as? Bool == true else { return nil }
        return godotDouble(r["battery"])
    }
}
