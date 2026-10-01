//
//  PlacementReticle.swift
//  vr
//
//  The subtle ring that shows where the car will land.
//

import Foundation
import RealityKit
import UIKit
import simd

/// A flat ring plus a centre dot, drawn on the detected floor.
///
/// It is deliberately unlit and semi-transparent so it reads as a guide rather
/// than as an object in the scene.
@MainActor
final class PlacementReticle {

    /// Add this to the RealityKit scene once; the reticle repositions itself.
    let anchor = AnchorEntity(world: .zero)

    private let content = Entity()
    private var parts: [ModelEntity] = []
    private var isShowing = false
    private var isValid = true

    init() {
        let ring = ModelEntity(
            mesh: .generateRing(innerRadius: 0.082, outerRadius: 0.1, segments: 72),
            materials: [Self.material(opacity: 0.85)]
        )
        let dot = ModelEntity(
            mesh: .generateRing(innerRadius: 0, outerRadius: 0.01, segments: 24),
            materials: [Self.material(opacity: 0.9)]
        )

        // A chevron showing which way the car will be facing, so the
        // direction is obvious before committing to it.
        let chevron = ModelEntity(
            mesh: .generateChevron(width: 0.05, length: 0.042, thickness: 0.016),
            materials: [Self.material(opacity: 0.9)]
        )
        chevron.position = SIMD3(0, 0, 0.115)

        parts = [ring, dot, chevron]
        content.addChild(ring)
        content.addChild(dot)
        content.addChild(chevron)
        anchor.addChild(content)
        anchor.isEnabled = false
    }

    private static func material(opacity: Float, valid: Bool = true) -> UnlitMaterial {
        var material = UnlitMaterial(color: valid ? .white : UIColor(red: 1, green: 0.33, blue: 0.3, alpha: 1))
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.faceCulling = .none
        return material
    }

    /// Places the reticle flat on the floor at `position`, keeping it level
    /// regardless of how the detected plane happens to be oriented. `valid`
    /// turns it red where the car cannot go — on top of a course prop, say.
    func show(at position: SIMD3<Float>, heading: Float, pulse: Float, valid: Bool = true) {
        if valid != isValid {
            isValid = valid
            for (part, opacity) in zip(parts, [Float(0.85), 0.9, 0.9]) {
                part.model?.materials = [Self.material(opacity: opacity, valid: valid)]
            }
        }

        var transform = Transform.identity
        transform.translation = position + SIMD3(0, 0.001, 0)   // avoid z-fighting with the floor
        transform.rotation = simd_quatf(angle: heading, axis: SIMD3(0, 1, 0))
        anchor.setTransformMatrix(transform.matrix, relativeTo: nil)

        // A slow breath so the reticle looks alive without drawing attention.
        let breathe = 1 + 0.04 * sin(pulse * 2.2)
        content.scale = SIMD3(repeating: breathe)

        if !isShowing {
            isShowing = true
            anchor.isEnabled = true
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        anchor.isEnabled = false
    }
}

private extension MeshResource {

    /// A flat chevron in the XZ plane, pointing along +Z.
    static func generateChevron(width: Float, length: Float, thickness: Float) -> MeshResource {
        let half = width / 2
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, length),                          // tip
            SIMD3(-half, 0, 0),                           // left wing
            SIMD3(-half + thickness, 0, 0),
            SIMD3(0, 0, length - thickness * 1.9),        // inner tip
            SIMD3(half - thickness, 0, 0),
            SIMD3(half, 0, 0),                            // right wing
        ]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 5]

        var descriptor = MeshDescriptor(name: "chevron")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(Array(repeating: SIMD3(0, 1, 0), count: positions.count))
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor]))
            ?? .generatePlane(width: width, depth: length)
    }

    /// A flat annulus in the XZ plane, facing up.
    ///
    /// RealityKit ships primitives for boxes, spheres and planes but not rings,
    /// and a ring reads far better on a floor than a filled disc.
    static func generateRing(innerRadius: Float, outerRadius: Float, segments: Int) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for step in 0...segments {
            let angle = 2 * Float.pi * Float(step) / Float(segments)
            let direction = SIMD3(sin(angle), 0, cos(angle))
            positions.append(direction * innerRadius)
            positions.append(direction * outerRadius)
            normals.append(SIMD3(0, 1, 0))
            normals.append(SIMD3(0, 1, 0))
        }

        for step in 0..<segments {
            let inner = UInt32(step * 2)
            let outer = inner + 1
            let nextInner = inner + 2
            let nextOuter = inner + 3
            indices.append(contentsOf: [inner, outer, nextOuter])
            indices.append(contentsOf: [inner, nextOuter, nextInner])
        }

        var descriptor = MeshDescriptor(name: "ring")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)

        // A ring is simple enough that generation cannot realistically fail,
        // but fall back to a small plane rather than trapping if it ever does.
        return (try? MeshResource.generate(from: [descriptor]))
            ?? .generatePlane(width: outerRadius * 2, depth: outerRadius * 2, cornerRadius: outerRadius)
    }
}
