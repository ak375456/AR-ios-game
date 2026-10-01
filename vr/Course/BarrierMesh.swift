//
//  BarrierMesh.swift
//  vr
//
//  A low-poly race barrier, built from native geometry.
//

import Foundation
import RealityKit
import simd
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A water-filled race barrier: a Jersey profile — wide rubber toe, steep
/// lower slope, near-vertical upper face — extruded along its length and
/// painted in alternating red and white sections.
///
/// Nothing suitable shipped with the project or came with the cone, and a
/// barrier is simple enough that drawing it here beats depending on another
/// download: every face is flat-shaded, so it reads as deliberately low-poly
/// next to the cone rather than as a placeholder box.
///
/// Its long axis is the entity's local X and its faces look along ±Z, so a
/// barrier turned to the placement heading presents its broad side to the
/// player. The base sits on y = 0.
enum BarrierMesh {

    enum Part: Int, CaseIterable {
        case red, white, toe
    }

    /// Sections along the length, alternating red and white, red at the ends.
    static let sections = 5

    /// One side of the profile, bottom to top, as (half-width, height).
    static var profile: [SIMD2<Float>] {
        let base = CourseSpec.Barrier.baseWidth / 2
        let top = CourseSpec.Barrier.topWidth / 2
        let height = CourseSpec.Barrier.height
        return [
            SIMD2(base, 0),
            SIMD2(base, height * 0.087),          // rubber toe
            SIMD2(base * 0.936, height * 0.12),   // chamfer off the toe
            SIMD2(base * 0.68, height * 0.333),   // the steep lower slope
            SIMD2(top * 1.24, height * 0.933),    // the upper face
            SIMD2(top, height),                   // bevel onto the top
        ]
    }

    /// Everything the mesh is made of, before RealityKit sees it.
    struct Buffers {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        /// A flat quad, wound anticlockwise seen from `normal`'s side.
        mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                           normal: SIMD3<Float>) {
            let start = UInt32(positions.count)
            positions += [a, b, c, d]
            normals += Array(repeating: normal, count: 4)
            let facing = simd_dot(simd_cross(b - a, c - a), normal) >= 0
            indices += facing ? [start, start + 1, start + 2, start, start + 2, start + 3]
                              : [start, start + 2, start + 1, start, start + 3, start + 2]
        }

        /// A flat outline as a fan round its centre, each triangle wound to
        /// face `normal`. The end profile is not quite convex — there is a
        /// notch where the toe meets the slope — so fanning from a corner
        /// would fold one sliver over; from the centre every triangle is fine.
        mutating func polygon(_ points: [SIMD3<Float>], normal: SIMD3<Float>) {
            guard points.count >= 3 else { return }
            let centre = UInt32(positions.count)
            positions.append(points.reduce(.zero, +) / Float(points.count))
            positions += points
            normals += Array(repeating: normal, count: points.count + 1)
            for i in 0..<points.count {
                let a = points[i], b = points[(i + 1) % points.count]
                let ia = centre + 1 + UInt32(i), ib = centre + 1 + UInt32((i + 1) % points.count)
                let facing = simd_dot(simd_cross(a - positions[Int(centre)], b - positions[Int(centre)]), normal) >= 0
                indices += facing ? [centre, ia, ib] : [centre, ib, ia]
            }
        }
    }

    /// The barrier's triangles, grouped by paint.
    static func buffers() -> [Part: Buffers] {
        var parts = Dictionary(uniqueKeysWithValues: Part.allCases.map { ($0, Buffers()) })
        let profile = profile
        let length = CourseSpec.Barrier.length
        let step = length / Float(sections)

        func point(_ x: Float, _ p: SIMD2<Float>, side: Float) -> SIMD3<Float> { SIMD3(x, p.y, p.x * side) }

        for section in 0..<sections {
            let x0 = -length / 2 + Float(section) * step
            let x1 = x0 + step
            let paint: Part = section.isMultiple(of: 2) ? .red : .white

            for side: Float in [1, -1] {
                for i in 0..<(profile.count - 1) {
                    let lower = profile[i], upper = profile[i + 1]
                    let rise = upper - lower
                    let normal = simd_normalize(SIMD3<Float>(0, -rise.x, rise.y * side))
                    parts[i == 0 ? .toe : paint]!.quad(point(x0, lower, side: side), point(x1, lower, side: side),
                                                       point(x1, upper, side: side), point(x0, upper, side: side),
                                                       normal: normal)
                }
            }

            let top = profile.last!
            parts[paint]!.quad(point(x0, top, side: 1), point(x1, top, side: 1),
                               point(x1, top, side: -1), point(x0, top, side: -1), normal: SIMD3(0, 1, 0))
            let bottom = profile[0]
            parts[.toe]!.quad(point(x0, bottom, side: 1), point(x0, bottom, side: -1),
                              point(x1, bottom, side: -1), point(x1, bottom, side: 1), normal: SIMD3(0, -1, 0))
        }

        // End caps: the toe in rubber, the rest in the end section's red.
        for end: Float in [1, -1] {
            let x = end * length / 2
            let normal = SIMD3<Float>(end, 0, 0)
            parts[.toe]!.quad(point(x, profile[0], side: 1), point(x, profile[1], side: 1),
                              point(x, profile[1], side: -1), point(x, profile[0], side: -1), normal: normal)
            let upper = profile.dropFirst().map { point(x, $0, side: 1) }
                + profile.dropFirst().reversed().map { point(x, $0, side: -1) }
            parts[.red]!.polygon(upper, normal: normal)
        }
        return parts
    }

    /// The outline of the barrier, for its convex collision hull. The profile
    /// has one shallow notch where the toe meets the slope; the hull bridges
    /// it by a couple of millimetres, which nothing can see.
    static var hullPoints: [SIMD3<Float>] {
        let half = CourseSpec.Barrier.length / 2
        return profile.flatMap { p in
            [SIMD3(-half, p.y, p.x), SIMD3(half, p.y, p.x), SIMD3(-half, p.y, -p.x), SIMD3(half, p.y, -p.x)]
        }
    }

    // MARK: - RealityKit

    static func makeMesh() throws -> MeshResource {
        let parts = buffers()
        let descriptors: [MeshDescriptor] = Part.allCases.map { part in
            let buffers = parts[part]!
            var descriptor = MeshDescriptor(name: "barrier-\(part)")
            descriptor.positions = MeshBuffers.Positions(buffers.positions)
            descriptor.normals = MeshBuffers.Normals(buffers.normals)
            descriptor.primitives = .triangles(buffers.indices)
            descriptor.materials = .allFaces(UInt32(part.rawValue))
            return descriptor
        }
        return try MeshResource.generate(from: descriptors)
    }

    /// Moulded plastic for the body, dull rubber for the toe. Indexed to
    /// match `Part`.
    static func makeMaterials() -> [RealityKit.Material] {
        func plastic(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, roughness: Float) -> PhysicallyBasedMaterial {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: .init(red: r, green: g, blue: b, alpha: 1))
            material.roughness = .init(floatLiteral: roughness)
            material.metallic = .init(floatLiteral: 0)
            return material
        }
        return [
            plastic(0.80, 0.09, 0.07, roughness: 0.42),
            plastic(0.93, 0.93, 0.91, roughness: 0.45),
            plastic(0.11, 0.11, 0.12, roughness: 0.85),
        ]
    }
}
