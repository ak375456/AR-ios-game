//
//  DetectedSurfaces.swift
//  vr
//
//  The floor ARKit has actually found, as outlines.
//

import ARKit
import simd

/// Where it is safe to stand a prop.
///
/// "Detected" means inside the outline of a horizontal plane ARKit has
/// mapped — not an estimated plane, and not the infinite extension of one.
/// Those are good enough to aim a reticle at but not to promise that a row of
/// cones two metres away is standing on floor rather than under a sofa. No
/// LiDAR is involved: plane outlines are what every ARKit iPhone produces.
///
/// Only planes at the course's own height count, so a coffee table next to
/// the car is never mistaken for more floor.
struct DetectedSurfaces {

    private struct Patch {
        let fromWorld: simd_float4x4
        let outline: [SIMD2<Float>]
        let lower: SIMD2<Float>
        let upper: SIMD2<Float>
    }

    private var patches: [Patch] = []

    var isEmpty: Bool { patches.isEmpty }

    init() {}

    /// Horizontal planes within `tolerance` of the world height `height`.
    init(anchors: [ARAnchor], height: Float, tolerance: Float) {
        for case let plane as ARPlaneAnchor in anchors where plane.alignment == .horizontal {
            if plane.classification == .ceiling { continue }
            guard abs(plane.transform.columns.3.y - height) <= tolerance else { continue }
            let outline = plane.geometry.boundaryVertices.map { SIMD2($0.x, $0.z) }
            guard outline.count >= 3 else { continue }
            let lower = outline.reduce(SIMD2(repeating: .infinity)) { simd_min($0, $1) }
            let upper = outline.reduce(SIMD2(repeating: -.infinity)) { simd_max($0, $1) }
            patches.append(Patch(fromWorld: plane.transform.inverse, outline: outline, lower: lower, upper: upper))
        }
    }

    /// True when `world` lies over detected floor.
    func contains(_ world: SIMD3<Float>) -> Bool {
        for patch in patches {
            let local = patch.fromWorld * SIMD4(world, 1)
            let point = SIMD2(local.x, local.z)
            guard point.x >= patch.lower.x, point.y >= patch.lower.y,
                  point.x <= patch.upper.x, point.y <= patch.upper.y else { continue }
            if Self.polygon(patch.outline, contains: point) { return true }
        }
        return false
    }

    /// Even-odd test; plane outlines are not always convex.
    private static func polygon(_ outline: [SIMD2<Float>], contains point: SIMD2<Float>) -> Bool {
        var inside = false
        var j = outline.count - 1
        for i in outline.indices {
            let a = outline[i], b = outline[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
