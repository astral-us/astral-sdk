import Foundation
import ARKit
import RoverNav

/// Turns the ARKit LiDAR scene mesh into a 2D `Costmap` for the RoverNav planner.
/// Vertices in an "obstacle height band" above the floor (i.e. things the rover would
/// hit — walls, furniture legs, people) are projected down onto the ground grid.
public enum CostmapBuilder {
    public struct Params: Sendable {
        public var resolution: Double        // m/cell
        public var size: Double              // m — square window centered on the robot
        public var floorBand: Double         // ignore anything below this above the floor
        public var ceilingBand: Double       // ignore anything above this (ceilings/overheads)
        public var inflationRadius: Double   // robot radius + safety margin

        public init(resolution: Double = 0.10,
                    size: Double = 12.0,
                    floorBand: Double = 0.10,
                    ceilingBand: Double = 1.8,
                    inflationRadius: Double = 0.25) {
            self.resolution = resolution
            self.size = size
            self.floorBand = floorBand
            self.ceilingBand = ceilingBand
            self.inflationRadius = inflationRadius
        }
    }

    /// Build a costmap centered on `center` (nav-plane coords) from the mesh anchors.
    public static func build(from meshAnchors: [ARMeshAnchor],
                             center: Vec2,
                             params: Params = Params()) -> Costmap {
        buildWithObserved(from: meshAnchors, center: center, params: params).map
    }

    /// Same as `build`, but also reports which cells have any mesh evidence at all —
    /// including the bare-floor vertices the obstacle pass filters out. That "observed"
    /// signal is what distinguishes open floor the rover has actually seen from unmapped
    /// space beyond a doorway (`Costmap` alone can't: both read as free), and is the input
    /// `FrontierFinder` needs to propose exploration candidates.
    public static func buildWithObserved(from meshAnchors: [ARMeshAnchor],
                                         center: Vec2,
                                         params: Params = Params()) -> (map: Costmap, observed: ObservedGrid) {
        let cells = Int((params.size / params.resolution).rounded())
        let origin = Vec2(center.x - params.size / 2, center.y - params.size / 2)
        var map = Costmap(width: cells, height: cells, resolution: params.resolution, origin: origin)
        var observed = ObservedGrid(matching: map)

        // Estimate floor height as the lowest vertex we see (ARKit Y is up).
        var floorY = Float.infinity
        for anchor in meshAnchors {
            floorY = min(floorY, anchor.transform.columns.3.y - 2.0) // rough; refined below
        }

        for anchor in meshAnchors {
            let geom = anchor.geometry
            let verts = geom.vertices
            let vbuf = verts.buffer.contents()
            let t = anchor.transform
            for i in 0..<verts.count {
                let vp = vbuf.advanced(by: verts.offset + verts.stride * i)
                    .assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let local = SIMD4<Float>(vp.0, vp.1, vp.2, 1)
                let world = t * local
                let groundPoint = Vec2(Double(world.x), Double(world.z))
                observed.markObserved(at: groundPoint)
                let heightAboveFloor = world.y - floorY
                guard heightAboveFloor > Float(params.floorBand),
                      heightAboveFloor < Float(params.ceilingBand) else { continue }
                map.markObstacle(at: groundPoint)
            }
        }

        map.inflate(radius: params.inflationRadius)
        return (map, observed)
    }
}
