import Foundation
import CoreGraphics
import RoverNav
import PhroverKit

/// `RoverPerception` backed by the Godot Depot sim. `nx` is a bearing-angle approximation
/// (0.5 = boresight, 0/1 = the edges of the detection FOV cone), not a true camera
/// projection — see phrover_manager.gd's `detect()` doc comment. Fine for a text/label
/// reasoner (ScriptedBrain, OnDeviceBrain); a real per-phrover camera + proper
/// `unproject_position` is needed before this can feed a vision brain meaningfully
/// (tracked as a Phase-3 gap, not built yet).
@MainActor
final class GodotPerception: RoverPerception {
    private let link: GodotLink
    private let rid: String
    private let robotRadius: Double

    init(link: GodotLink, rid: String, robotRadius: Double = 0.3) {
        self.link = link
        self.rid = rid
        self.robotRadius = robotRadius
    }

    var pose: Pose2D? {
        let r = link.call(["op": "phrover_state", "id": rid])
        guard r["ok"] as? Bool == true,
              let p = godotDoubleArray(r["pose"]), p.count == 3
        else { return nil }
        return Pose2D(position: Vec2(p[0], p[1]), yaw: p[2])
    }

    func detectObjects() -> [PerceivedObject] {
        let r = link.call(["op": "phrover_detect", "id": rid])
        guard let objs = r["objects"] as? [[String: Any]] else { return [] }
        var out: [PerceivedObject] = []
        for o in objs {
            guard let label = o["label"] as? String,
                  let nx = godotDouble(o["nx"]), let ny = godotDouble(o["ny"])
            else { continue }
            let confidence = godotDouble(o["confidence"]) ?? 0.5
            out.append(PerceivedObject(label: label, confidence: Float(confidence),
                                        normalizedPoint: CGPoint(x: nx, y: ny)))
        }
        return out
    }

    func unproject(normalizedPoint: CGPoint) -> Vec2? {
        let r = link.call(["op": "phrover_unproject", "id": rid,
                            "nx": Double(normalizedPoint.x), "ny": Double(normalizedPoint.y)])
        guard r["ok"] as? Bool == true,
              let world = godotDoubleArray(r["world"]), world.count == 2
        else { return nil }
        return Vec2(world[0], world[1])
    }

    func capturedFrameJPEG() -> Data? {
        nil  // no dedicated phrover POV camera in Godot yet — see type doc comment above
    }

    func explorationFrontiers() -> [Frontier] {
        guard let grids = GodotGrid.fetch(link: link, rid: rid, robotRadius: robotRadius) else { return [] }
        return FrontierFinder.candidates(costmap: grids.costmap, observed: grids.observed)
    }
}
