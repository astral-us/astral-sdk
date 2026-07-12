import Foundation
import RoverNav

/// Decodes Godot's `phrover_grid` response (occupancy + observed byte grids, base64,
/// row-major u8) into the real RoverNav `Costmap`/`ObservedGrid` types — so planning and
/// frontier detection in the sim run the identical algorithms as on-device, just fed
/// simulated geometry instead of an ARKit mesh.
enum GodotGrid {
    struct Grids {
        let costmap: Costmap
        let observed: ObservedGrid
    }

    static func fetch(link: GodotLink, rid: String, robotRadius: Double) -> Grids? {
        let r = link.call(["op": "phrover_grid", "id": rid])
        guard r["ok"] as? Bool == true,
              let res = godotDouble(r["res"]),
              let originArr = godotDoubleArray(r["origin"]), originArr.count == 2,
              let w = godotInt(r["w"]), let h = godotInt(r["h"]),
              let occB64 = r["occ"] as? String, let obsB64 = r["obs"] as? String,
              let occData = Data(base64Encoded: occB64), let obsData = Data(base64Encoded: obsB64),
              occData.count == w * h, obsData.count == w * h
        else { return nil }

        let origin = Vec2(originArr[0], originArr[1])
        var costmap = Costmap(width: w, height: h, resolution: res, origin: origin)
        // Only mark a cell lethal if it's BOTH truly occupied AND already observed by
        // this rover — mirrors the real on-device CostmapBuilder, which only knows about
        // geometry ARKit has actually meshed. `phrover_grid`'s `occ` is full ground truth
        // (the whole building), so using it unfiltered would give the planner map
        // knowledge the rover could never really have (a wall in a room it's never
        // entered), and periodic replanning would never actually discover anything new.
        for cy in 0..<h {
            for cx in 0..<w where occData[cy * w + cx] != 0 && obsData[cy * w + cx] != 0 {
                costmap.setCost(cx, cy, Costmap.lethal)
            }
        }
        costmap.inflate(radius: robotRadius)

        var observed = ObservedGrid(matching: costmap)
        for cy in 0..<h {
            for cx in 0..<w where obsData[cy * w + cx] != 0 {
                observed.markObserved(at: costmap.cellCenter(cx, cy))
            }
        }
        return Grids(costmap: costmap, observed: observed)
    }
}
