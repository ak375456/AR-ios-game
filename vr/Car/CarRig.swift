//
//  CarRig.swift
//  vr
//
//  Loads a car, measures it, paints it, and poses it every frame.
//

import Foundation
import OSLog
import RealityKit
import UIKit
import simd

/// Something went wrong turning a bundled USDZ into a usable car.
enum CarAssetError: LocalizedError {
    case missingResource(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "The car model “\(name)” is missing from the app bundle."
        case .loadFailed(let reason):
            return "The car model could not be loaded. \(reason)"
        }
    }
}

/// The placed car.
///
/// ```
/// root      – positioned and rotated from the vehicle state, in anchor space
/// └ lean    – body roll and pitch, pivoting on the contact patch
///   └ scaler– scale to real size, centred, wheels resting on y = 0
///     └ model – the loaded USDZ, already oriented Y-up facing +Z by the converter
/// ```
///
/// Everything the physics needs — wheelbase, track, wheel radius — is measured
/// from the mesh rather than typed into a table, so a car always drives like
/// the shape it is.
@MainActor
final class CarRig {

    /// Attach this to the placement anchor. Driving moves *this* entity, so the
    /// car's world position genuinely changes as it is driven.
    let root = Entity()

    let definition: CarDefinition

    private let lean = Entity()
    private let scaler = Entity()
    private let model: Entity

    /// Prims carrying the car's paint material, named at conversion time.
    /// A wheel, mounted on a pivot at its own measured centre.
    ///
    /// Models place their wheels in wildly different ways: some put the node
    /// origin on the hub, some leave it at the model origin, and several carry
    /// a rotation and a non-uniform scale on the wheel node itself. Rotating
    /// those nodes directly either swings the wheel around the car or shears
    /// it. Everything here is measured in the *model's* space and spun through
    /// a pivot planted at the wheel's true centre, which works whatever the
    /// author did.
    private struct Wheel {
        /// Fresh entity at the wheel's centre; rotating this spins the wheel.
        let pivot: Entity
        /// Centre in the model's space, before the car is scaled.
        let centre: SIMD3<Float>
        /// Rolling radius in the model's space, before the car is scaled.
        let radius: Float
    }

    private var paintMeshes: [Entity] = []
    private var frontWheels: [Wheel] = []
    private var rearWheels: [Wheel] = []

    private(set) var scale: Float = 1
    /// The placed car's bounding box, metres: width, height, length.
    private(set) var bodySize = SIMD3<Float>(0.18, 0.14, 0.42)
    private(set) var wheelBase: Float = 0.22
    private(set) var trackWidth: Float = 0.18
    private(set) var wheelRadius: Float = 0.05
    /// Rear contact patches in the car's own frame, metres, y at ground level.
    private(set) var rearContactPatches: [SIMD3<Float>] = []

    /// False when a model has no separate wheel objects. The app then simply
    /// does not animate wheels rather than faking it.
    var hasArticulatedWheels: Bool { !frontWheels.isEmpty || !rearWheels.isEmpty }

    /// Physics parameters for this car, built from its class and its measurements.
    var tuning: VehicleTuning {
        VehicleTuning.make(carClass: definition.carClass,
                           length: definition.length,
                           wheelBase: wheelBase,
                           trackWidth: trackWidth,
                           wheelRadius: wheelRadius)
    }

    // MARK: - Loading

    static func load(car: CarDefinition, paint: CarPaint) async throws -> CarRig {
        guard let url = Bundle.main.url(forResource: car.assetName, withExtension: "usdz") else {
            throw CarAssetError.missingResource(car.assetName)
        }
        do {
            let entity = try await Entity(contentsOf: url)
            let rig = CarRig(definition: car, model: entity)
            await rig.apply(paint: paint)
            return rig
        } catch let error as CarAssetError {
            throw error
        } catch {
            throw CarAssetError.loadFailed(error.localizedDescription)
        }
    }

    private init(definition: CarDefinition, model: Entity) {
        self.definition = definition
        self.model = model

        scaler.addChild(model)
        lean.addChild(scaler)
        root.addChild(lean)

        measureAndScale()
        findParts()

        AppLog.asset.info("\(definition.displayName, privacy: .public): scale \(self.scale), wheelbase \(self.wheelBase) m, track \(self.trackWidth) m, wheel radius \(self.wheelRadius) m, separate wheels: \(self.hasArticulatedWheels)")
    }

    /// Scales the model to its real length, centres it over the anchor point,
    /// and drops it so the bottom of the tyres rests on the ground plane.
    private func measureAndScale() {
        let bounds = model.visualBounds(relativeTo: model)
        let length = bounds.extents.z

        scale = length > 0 ? definition.length / length : 1
        scaler.scale = SIMD3(repeating: scale)
        scaler.position = SIMD3(-bounds.center.x, -bounds.min.y, -bounds.center.z) * scale
        bodySize = bounds.extents * scale
    }

    /// Half the footprint the course collides with: `x` across, `y` along.
    ///
    /// A shade inside the bounding box, because bodywork is rounded at the
    /// corners and mirrors stick out above bumper height: a box the full size
    /// of the bounds would register touches the player could see had missed.
    var collisionHalfExtents: SIMD2<Float> {
        SIMD2(bodySize.x * 0.94, bodySize.z * 0.97) / 2
    }

    /// What counts as a wheel.
    ///
    /// This has to stay in step with `is_wheel` in `Tools/glb_to_usdz.py`: the
    /// converter uses the same rule to decide which meshes get re-centred on
    /// their hubs. When the two disagreed, a kart whose wheels are named "tire"
    /// had them re-centred by nobody and spun by the app, so they swung around
    /// the middle of the model and flew off.
    static func isWheel(_ name: String) -> Bool {
        let lower = name.lowercased()
        let isWheelish = ["wheel", "tire", "tyre"].contains(where: lower.contains)
        // Arches, supports, fenders — and a spare bolted to the tailgate —
        // mention a wheel but are bodywork.
        let isBodywork = ["support", "arch", "well", "guard", "fender", "mount",
                          "cover", "axle", "axel", "hubcap", "spare"].contains(where: lower.contains)
        return isWheelish && !isBodywork
    }

    /// Sorts the model into wheels, repaintable prims, and everything that must
    /// be left alone.
    ///
    /// Wheel names vary between kits — `wheel-front-left`, `BackWheels`,
    /// `Brand_Model_Wheel_FL` — so the search matches on words
    /// anywhere in the name and carries the match down to child prims. Front
    /// and rear come from each wheel's actual position, never its name.
    private func findParts() {
        var wheels: [Entity] = []

        func visit(_ entity: Entity, insideWheel: Bool) {
            let name = entity.name
            let startsWheel = !insideWheel && Self.isWheel(name)
            let isWheel = insideWheel || startsWheel

            // The outermost prim of a wheel carries the hub pivot, so that is
            // what gets rotated.
            if startsWheel { wheels.append(entity) }
            if !isWheel, name.lowercased().hasPrefix("paint") { paintMeshes.append(entity) }
            for child in entity.children { visit(child, insideWheel: isWheel) }
        }
        visit(model, insideWheel: false)

        let bounds = model.visualBounds(relativeTo: model)
        for wheel in wheels {
            guard let entry = mount(wheel) else { continue }
            if entry.centre.z > bounds.center.z {
                frontWheels.append(entry)
            } else {
                rearWheels.append(entry)
            }
        }

        measureWheels(bounds: bounds)
    }

    /// Hangs a pivot off the model at the wheel's measured hub and moves the
    /// wheel under it, so rotating the pivot spins the wheel on its hub no
    /// matter how the model was built.
    ///
    /// The pivot belongs to the model rather than to the wheel's own group
    /// because a group's frame is not always square: the 4x4 scales
    /// its wheel group by (0.48, 3.66, 3.66) and stands it on its side, and a
    /// rotation applied in a frame like that shears the tyre into a slab
    /// instead of turning it. A carrier under the pivot replays the group's
    /// transform, so the wheel keeps the pose its author gave it — including
    /// the slight shear the 4x4's left wheels are authored with, which
    /// survives only because the wheel's own transform is never touched.
    private func mount(_ wheel: Entity) -> Wheel? {
        guard let parent = wheel.parent else { return nil }

        // Measured in the model's space, so it includes every transform
        // between the wheel and the car.
        let inModel = wheel.visualBounds(relativeTo: model)
        guard inModel.extents.max() > 0 else { return nil }
        let centre = inModel.center

        // Square frame: no rotation, no scale, just the hub's position.
        let pivot = Entity()
        pivot.position = centre
        model.addChild(pivot)

        // The group's own transform, shifted back by the hub so that the two
        // together come out exactly where the group was.
        let group = Transform(matrix: parent.transformMatrix(relativeTo: model))
        let carrier = Entity()
        carrier.transform = Transform(scale: group.scale,
                                      rotation: group.rotation,
                                      translation: group.translation - centre)
        pivot.addChild(carrier)

        // Keeps the wheel's authored transform: RealityKit only rewrites it
        // when asked to preserve the world transform instead.
        carrier.addChild(wheel)

        // Axles run along the car's X, so the diameter is the larger of the
        // two extents across it.
        let diameter = max(inModel.extents.y, inModel.extents.z)
        return Wheel(pivot: pivot, centre: centre, radius: diameter / 2)
    }

    /// Every measurement comes from the wheels' measured centres and radii in
    /// the model's space, never from node positions or local-space bounds —
    /// both of which lie on models that transform their wheel nodes.
    private func measureWheels(bounds: BoundingBox) {
        let all = frontWheels + rearWheels

        if let front = frontWheels.first, let rear = rearWheels.first {
            let separation = abs(front.centre.z - rear.centre.z)
            if separation > 0 { wheelBase = separation * scale }
        } else {
            // No separate wheels: assume a typical wheelbase for the body.
            wheelBase = definition.length * 0.58
        }

        if all.count >= 2 {
            let xs = all.map(\.centre.x)
            let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
            if spread > 0 { trackWidth = spread * scale }
        }
        if trackWidth < 0.02 { trackWidth = bounds.extents.x * scale * 0.82 }

        if let wheel = all.first, wheel.radius > 0 {
            wheelRadius = wheel.radius * scale
        } else {
            wheelRadius = definition.length * 0.115
        }

        // Rear contact patches, in the car's own frame with y on the ground.
        // Effects hang off these, so they follow each model's real wheels.
        let halfTrack = trackWidth / 2
        if rearWheels.isEmpty {
            let z = -wheelBase / 2
            rearContactPatches = [SIMD3(halfTrack, 0, z), SIMD3(-halfTrack, 0, z)]
        } else if rearWheels.count == 1 {
            // One rear prim is either both wheels modelled together or a single
            // wheel on a three-wheeler. How wide it is tells them apart.
            let wheel = rearWheels[0]
            let centre = wheel.centre * scale
            let width = wheel.pivot.visualBounds(relativeTo: model).extents.x * scale
            if width > trackWidth * 0.6 {
                rearContactPatches = [SIMD3(halfTrack, 0, centre.z), SIMD3(-halfTrack, 0, centre.z)]
            } else {
                rearContactPatches = [SIMD3(centre.x, 0, centre.z)]
            }
        } else {
            rearContactPatches = rearWheels.map { SIMD3($0.centre.x * scale, 0, $0.centre.z * scale) }
        }
    }

    // MARK: - Paint

    /// Repaints the car.
    ///
    /// Only prims the converter identified as carrying the paint material are
    /// touched, so glass, tyres, lights and trim keep the materials they were
    /// authored with. Cars whose paint could not be identified keep their
    /// original colours entirely.
    func apply(paint: CarPaint) async {
        guard paint.id != "factory" else { return }
        guard !paintMeshes.isEmpty else { return }

        var material = PhysicallyBasedMaterial()
        material.roughness = .init(floatLiteral: 0.45)
        material.metallic = .init(floatLiteral: 0.05)

        switch definition.paintSource {
        case .texture:
            guard let texture = await PaintShop.shared.texture(for: definition, paint: paint) else { return }
            material.baseColor = .init(tint: .white, texture: .init(texture))
        case .materialColour:
            let shifted = PaintShop.shared.shiftedColour(for: paint)
            material.baseColor = .init(tint: shifted)
        case .fixed:
            return
        }

        for mesh in paintMeshes {
            guard var component = mesh.components[ModelComponent.self] else { continue }
            component.materials = Array(repeating: material, count: max(component.materials.count, 1))
            mesh.components.set(component)
        }
    }

    // MARK: - Per-frame pose

    /// Pushes a rendered vehicle state onto the entity hierarchy.
    func apply(_ pose: VehicleState, roll: Float, pitch: Float) {
        root.position = SIMD3(pose.position.x, 0, pose.position.y)
        root.orientation = simd_quatf(angle: pose.heading, axis: SIMD3(0, 1, 0))

        lean.orientation = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: roll, axis: SIMD3(0, 0, 1))

        guard hasArticulatedWheels else { return }

        // The pivots sit in the model's frame, where the axles run along X and
        // up is Y, so rolling and steering are rotations about those axes.
        let steer = simd_quatf(angle: pose.steerAngle, axis: SIMD3(0, 1, 0))
        let frontRoll = simd_quatf(angle: pose.frontWheelSpin, axis: SIMD3(1, 0, 0))
        let rearRoll = simd_quatf(angle: pose.rearWheelSpin, axis: SIMD3(1, 0, 0))

        for wheel in frontWheels { wheel.pivot.orientation = steer * frontRoll }
        for wheel in rearWheels { wheel.pivot.orientation = rearRoll }
    }

    /// Rear contact patches in the parent anchor's space, for effects.
    func rearContactPatchesInAnchorSpace(pose: VehicleState) -> [SIMD3<Float>] {
        let cosine = cos(pose.heading)
        let sine = sin(pose.heading)
        return rearContactPatches.map { local in
            // Rotate the local offset by the heading, then translate.
            let x = local.x * cosine + local.z * sine
            let z = -local.x * sine + local.z * cosine
            return SIMD3(pose.position.x + x, 0, pose.position.y + z)
        }
    }

    /// Returns every part to its rest pose.
    func resetPose() {
        root.position = .zero
        root.orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        lean.orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        for wheel in frontWheels + rearWheels {
            wheel.pivot.orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        }
    }
}
