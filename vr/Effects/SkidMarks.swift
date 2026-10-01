//
//  SkidMarks.swift
//  vr
//
//  Rubber left on the floor where the rear tyres slid.
//

import Foundation
import RealityKit
import UIKit
import simd

/// Dark strips laid down under the rear tyres during a sustained slide.
///
/// Both tyres' trails live in a single mesh that is rebuilt a few times a
/// second rather than once per frame, and the point buffers are capped, so the
/// scene can never accumulate unbounded geometry however long the player
/// drifts. The oldest end of each trail fades out through an opacity ramp
/// instead of ending in a hard edge.
///
/// This is deliberately subordinate to the smoke: it is a single flat mesh on
/// the ground plane with no lighting, and it switches off when the effects
/// setting is turned down.
@MainActor
final class SkidMarks {

    private enum Tuning {
        /// Rear slip speed at which marks start being laid, m/s.
        static let slipThreshold: Float = 0.45
        /// Minimum distance between recorded points, metres.
        static let spacing: Float = 0.012
        /// Points kept per tyre. Two tyres, two triangles per segment.
        static let maxPoints = 90
        /// Height above the ground plane, to avoid z-fighting with the floor.
        static let height: Float = 0.0012
        /// Rebuilds per second.
        static let rebuildRate: Double = 12
        static let opacity: Float = 0.5
    }

    private let entity = ModelEntity()
    private var lanes: [[SIMD3<Float>]] = []
    private var halfWidth: Float = 0.01
    private var isAttached = false
    private var needsRebuild = false
    private var lastRebuild = Date.distantPast
    private var material: UnlitMaterial?

    var isEnabled = true

    // MARK: - Lifecycle

    func attach(to anchor: Entity, rig: CarRig) async {
        detach()
        lanes = Array(repeating: [], count: max(rig.rearContactPatches.count, 2))
        halfWidth = max(rig.wheelRadius * 0.34, 0.004)

        var unlit = UnlitMaterial()
        unlit.color = .init(tint: UIColor(white: 0.07, alpha: 1))
        if let ramp = await EffectTextures.skidFadeRamp() {
            unlit.blending = .transparent(opacity: .init(scale: Tuning.opacity, texture: .init(ramp)))
        } else {
            unlit.blending = .transparent(opacity: .init(floatLiteral: Tuning.opacity))
        }
        unlit.faceCulling = .none
        material = unlit

        anchor.addChild(entity)
        isAttached = true
    }

    func detach() {
        entity.removeFromParent()
        entity.model = nil
        lanes.removeAll()
        isAttached = false
        needsRebuild = false
    }

    /// Wipes the marks but keeps the entity, for "reset car".
    func clear() {
        for index in lanes.indices { lanes[index].removeAll(keepingCapacity: true) }
        entity.model = nil
        needsRebuild = false
    }

    // MARK: - Per-frame

    func update(patches: [SIMD3<Float>], telemetry: VehicleTelemetry, speed: Float) {
        guard isAttached, isEnabled else { return }

        let sliding = telemetry.rearSlipSpeed > Tuning.slipThreshold && speed > 0.2
        if sliding {
            for (index, patch) in patches.enumerated() where index < lanes.count {
                let point = SIMD3(patch.x, Tuning.height, patch.z)
                if let last = lanes[index].last, simd_distance(last, point) < Tuning.spacing { continue }
                lanes[index].append(point)
                if lanes[index].count > Tuning.maxPoints { lanes[index].removeFirst() }
                needsRebuild = true
            }
        } else {
            // A gap in the trail is correct: the tyre stopped sliding.
            for index in lanes.indices where !lanes[index].isEmpty {
                if lanes[index].last != nil { lanes[index].append(.init(repeating: .nan)) }
                needsRebuild = true
            }
        }

        guard needsRebuild,
              Date().timeIntervalSince(lastRebuild) > 1 / Tuning.rebuildRate else { return }
        lastRebuild = Date()
        needsRebuild = false
        rebuild()
    }

    // MARK: - Mesh

    private func rebuild() {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        for lane in lanes {
            let total = lane.count
            guard total > 1 else { continue }
            for i in 0..<(total - 1) {
                let a = lane[i], b = lane[i + 1]
                // NaN marks a break where the tyre regained grip.
                guard a.x.isFinite, b.x.isFinite else { continue }

                var direction = b - a
                direction.y = 0
                let length = simd_length(direction)
                guard length > 1e-5 else { continue }
                direction /= length
                let side = SIMD3(-direction.z, 0, direction.x) * halfWidth

                // u runs from 1 at the oldest end to 0 at the newest, and the
                // ramp texture fades the old end out.
                let uA = 1 - Float(i) / Float(total - 1)
                let uB = 1 - Float(i + 1) / Float(total - 1)

                let base = UInt32(positions.count)
                positions.append(contentsOf: [a - side, a + side, b - side, b + side])
                normals.append(contentsOf: Array(repeating: SIMD3(0, 1, 0), count: 4))
                uvs.append(contentsOf: [SIMD2(uA, 0), SIMD2(uA, 1), SIMD2(uB, 0), SIMD2(uB, 1)])
                indices.append(contentsOf: [base, base + 1, base + 3, base, base + 3, base + 2])
            }
        }

        guard indices.count >= 3, let material else {
            entity.model = nil
            return
        }

        var descriptor = MeshDescriptor(name: "skid")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return }
        entity.model = ModelComponent(mesh: mesh, materials: [material])
    }
}
