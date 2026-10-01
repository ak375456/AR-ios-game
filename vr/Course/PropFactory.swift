//
//  PropFactory.swift
//  vr
//
//  Prepares the course props once, and hands out cheap copies.
//

import Foundation
import OSLog
import RealityKit
import simd
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Loads, measures and prepares every prop once per launch.
///
/// The cone and tyre models are read from disk once, scaled once and their
/// collision hulls are computed once; after that a new prop is a `clone` of
/// prepared entities sharing the same mesh, materials and shapes. The
/// barrier's mesh is generated once in the same way. Nothing here runs per
/// frame.
///
/// Every prop is a `ModelEntity` body carrying the collision and physics
/// components, with its visual as a child. The body's origin is the centre of
/// the prop's footprint on the floor, so placing a prop is placing that point
/// on the ground plane and it can neither float nor sink.
@MainActor
final class PropFactory {

    static let shared = PropFactory()

    /// Collision groups: props hit props and the floor; hit tests for editing
    /// look only at props.
    static let propGroup = CollisionGroup(rawValue: 1 << 12)
    static let groundGroup = CollisionGroup(rawValue: 1 << 13)

    enum ModelSource: Equatable {
        /// The bundled model, rebuilt by Tools/build_props.py.
        case model
        /// RealityKit primitives, used only if the model failed to load.
        case nativeFallback
    }

    /// Where each loaded prop's look came from. The barrier is always drawn
    /// by the app, so it is not listed.
    private(set) var sources: [PropKind: ModelSource] = [:]

    private var visuals: [PropKind: Entity] = [:]
    private var shapes: [PropKind: [ShapeResource]] = [:]
    private var physicsBodies: [PropKind: PhysicsBodyComponent] = [:]
    private var groundBody: PhysicsBodyComponent?

    private var preparing: Task<Void, Never>?

    var isReady: Bool { PropKind.allCases.allSatisfy { visuals[$0] != nil } }

    // MARK: - Preparation

    /// Loads everything. Safe to call repeatedly: it only does the work once,
    /// and concurrent callers wait for the same load.
    func prepare(coneURL: URL? = nil, tyreURL: URL? = nil) async {
        if isReady { return }
        if let preparing { await preparing.value; return }
        let task = Task { @MainActor in
            await self.load(
                coneURL: coneURL ?? Bundle.main.url(forResource: "TrafficCone", withExtension: "usdz"),
                tyreURL: tyreURL ?? Bundle.main.url(forResource: "Tyre", withExtension: "usdz"))
        }
        preparing = task
        await task.value
        preparing = nil
    }

    private func load(coneURL: URL?, tyreURL: URL?) async {
        prepareMaterials()
        prepareBarrier()

        do {
            guard let coneURL else { throw CocoaError(.fileNoSuchFile) }
            try prepareCone(from: try await Entity(contentsOf: coneURL))
            sources[.cone] = .model
        } catch {
            AppLog.asset.error("Cone model failed to load, using the native cone: \(error.localizedDescription, privacy: .public)")
            prepareNativeCone()
            sources[.cone] = .nativeFallback
        }

        do {
            guard let tyreURL else { throw CocoaError(.fileNoSuchFile) }
            try prepareTyre(from: try await Entity(contentsOf: tyreURL))
            sources[.tyre] = .model
        } catch {
            AppLog.asset.error("Tyre model failed to load, using the native tyre: \(error.localizedDescription, privacy: .public)")
            prepareNativeTyre()
            sources[.tyre] = .nativeFallback
        }
    }

    private func prepareMaterials() {
        let cone = PhysicsMaterialResource.generate(staticFriction: CourseSpec.Cone.friction + 0.1,
                                                    dynamicFriction: CourseSpec.Cone.friction,
                                                    restitution: CourseSpec.Cone.restitution)
        var coneBody = PhysicsBodyComponent(massProperties: Self.coneMassProperties, material: cone, mode: .kinematic)
        // Enough to let a tumbling cone come to rest on a smooth floor rather
        // than skating across the room, not so much that it floats.
        coneBody.linearDamping = 0.2
        coneBody.angularDamping = 0.45
        physicsBodies[.cone] = coneBody

        let tyre = PhysicsMaterialResource.generate(staticFriction: CourseSpec.Tyre.friction + 0.1,
                                                    dynamicFriction: CourseSpec.Tyre.friction,
                                                    restitution: CourseSpec.Tyre.restitution)
        var tyreBody = PhysicsBodyComponent(massProperties: Self.tyreMassProperties, material: tyre, mode: .kinematic)
        tyreBody.linearDamping = 0.2
        tyreBody.angularDamping = 0.5
        physicsBodies[.tyre] = tyreBody

        let barrier = PhysicsMaterialResource.generate(staticFriction: 0.5, dynamicFriction: 0.4, restitution: 0.25)
        physicsBodies[.barrier] = PhysicsBodyComponent(massProperties: .default, material: barrier, mode: .static)

        let ground = PhysicsMaterialResource.generate(staticFriction: CourseSpec.Ground.friction + 0.1,
                                                      dynamicFriction: CourseSpec.Ground.friction,
                                                      restitution: CourseSpec.Ground.restitution)
        groundBody = PhysicsBodyComponent(massProperties: .default, material: ground, mode: .static)
    }

    /// Weight low in the base, like the real thing. The inertia is that of a
    /// 7 cm cone with most of its mass in a 6 cm plate.
    private static var coneMassProperties: PhysicsMassProperties {
        PhysicsMassProperties(mass: CourseSpec.Cone.mass,
                              inertia: SIMD3(4.0e-5, 3.0e-5, 4.0e-5),
                              centerOfMass: (SIMD3(0, CourseSpec.Cone.centreOfMassHeight, 0),
                                             simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))))
    }

    /// A ring more than a disc: most of a tyre's weight is out in the tread,
    /// which is why one spins on so readily once it is knocked.
    private static var tyreMassProperties: PhysicsMassProperties {
        let m = CourseSpec.Tyre.mass
        let outer = CourseSpec.Tyre.radius, inner = outer * 0.6, height = CourseSpec.Tyre.height
        let axial = m * (outer * outer + inner * inner) / 2
        let across = m * (3 * (outer * outer + inner * inner) + height * height) / 12
        return PhysicsMassProperties(mass: m, inertia: SIMD3(across, axial, across),
                                     centerOfMass: (SIMD3(0, height / 2, 0),
                                                    simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))))
    }

    /// Wraps a loaded model so it stands on y = 0, centred, at `scale`.
    private static func fit(_ loaded: Entity, name: String, bounds: BoundingBox, scale: Float) -> Entity {
        let visual = Entity()
        visual.name = name
        loaded.scale = SIMD3(repeating: scale)
        loaded.position = SIMD3(-bounds.center.x, -bounds.min.y, -bounds.center.z) * scale
        visual.addChild(loaded)
        return visual
    }

    /// Every vertex of the named parts (all of them if `names` is empty), in
    /// `visual`'s space.
    private static func points(in visual: Entity, named names: Set<String>) -> [SIMD3<Float>] {
        var found: [SIMD3<Float>] = []
        func visit(_ entity: Entity, inside: Bool) {
            let included = inside || names.contains(entity.name)
            if included, let model = entity.components[ModelComponent.self] {
                let toVisual = entity.transformMatrix(relativeTo: visual)
                for instance in model.mesh.contents.instances {
                    guard let mesh = model.mesh.contents.models[instance.model] else { continue }
                    let transform = toVisual * instance.transform
                    for part in mesh.parts {
                        for p in part.positions.elements {
                            let world = transform * SIMD4(p, 1)
                            found.append(SIMD3(world.x, world.y, world.z))
                        }
                    }
                }
            }
            for child in entity.children { visit(child, inside: included) }
        }
        visit(visual, inside: names.isEmpty)
        return found
    }

    /// Scales the bundled cone to size and builds its collision from its own
    /// vertices: a hull round the base plate and another round the shell. Two
    /// hulls rather than one, because a single hull would fill in the step
    /// between the wide plate and the narrow shell — the cone would then lie
    /// propped up on an invisible ramp once knocked over.
    private func prepareCone(from loaded: Entity) throws {
        let bounds = loaded.visualBounds(relativeTo: loaded)
        guard bounds.extents.y > 1e-5 else { throw CocoaError(.fileReadCorruptFile) }
        let visual = Self.fit(loaded, name: "cone-visual", bounds: bounds,
                              scale: CourseSpec.Cone.height / bounds.extents.y)

        let base = Self.points(in: visual, named: ["Base"])
        let shell = Self.points(in: visual, named: ["Shell", "Band"])
        if base.count >= 4, shell.count >= 4 {
            shapes[.cone] = [ShapeResource.generateConvex(from: base), ShapeResource.generateConvex(from: shell)]
        } else {
            let all = Self.points(in: visual, named: [])
            guard all.count >= 4 else { throw CocoaError(.fileReadCorruptFile) }
            shapes[.cone] = [ShapeResource.generateConvex(from: all)]
        }
        visuals[.cone] = visual
    }

    /// Scales the bundled tyre to size. Its collision is one hull round every
    /// vertex of the model, measured rather than typed in.
    ///
    /// All of it, not just the tread: this wheel's back face stands 1.7 mm
    /// proud of the sidewall, so lying flat the tyre really rests on its hub,
    /// with the tread just clear of the floor. A hull of the tread alone let
    /// the tyre sink by exactly that much. The hull cannot be hollow, so the
    /// recess round the wheel nuts is filled in; nothing ever lands in there.
    private func prepareTyre(from loaded: Entity) throws {
        let bounds = loaded.visualBounds(relativeTo: loaded)
        let across = max(bounds.extents.x, bounds.extents.z)
        guard across > 1e-5, bounds.extents.y > 1e-5 else { throw CocoaError(.fileReadCorruptFile) }
        let visual = Self.fit(loaded, name: "tyre-visual", bounds: bounds, scale: CourseSpec.Tyre.diameter / across)

        let outline = Self.points(in: visual, named: [])
        guard outline.count >= 4 else { throw CocoaError(.fileReadCorruptFile) }
        shapes[.tyre] = [ShapeResource.generateConvex(from: outline)]
        visuals[.tyre] = visual
    }

    private static func paint(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, roughness: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .init(red: r, green: g, blue: b, alpha: 1))
        material.roughness = .init(floatLiteral: roughness)
        return material
    }

    /// Only if the bundled model could not be read: a cone of the same size
    /// and weight built from RealityKit's own primitives, so the course still
    /// works.
    private func prepareNativeCone() {
        let height = CourseSpec.Cone.height
        let plateHeight = height * 0.07
        let visual = Entity()

        let plate = ModelEntity(mesh: .generateBox(width: CourseSpec.Cone.footprintRadius * 1.9, height: plateHeight,
                                                   depth: CourseSpec.Cone.footprintRadius * 1.9, cornerRadius: 0.003),
                                materials: [Self.paint(0.08, 0.08, 0.08, roughness: 0.8)])
        plate.position.y = plateHeight / 2
        let shellHeight = height - plateHeight
        let shell = ModelEntity(mesh: .generateCone(height: shellHeight, radius: CourseSpec.Cone.contactRadius),
                                materials: [Self.paint(0.95, 0.36, 0.05, roughness: 0.5)])
        shell.position.y = plateHeight + shellHeight / 2
        visual.addChild(plate)
        visual.addChild(shell)
        visuals[.cone] = visual

        let ring = (0..<12).map { i -> SIMD3<Float> in
            let a = Float(i) / 12 * 2 * .pi
            return SIMD3(cos(a) * CourseSpec.Cone.contactRadius, plateHeight, sin(a) * CourseSpec.Cone.contactRadius)
        }
        shapes[.cone] = [
            ShapeResource.generateBox(width: CourseSpec.Cone.footprintRadius * 1.9, height: plateHeight,
                                      depth: CourseSpec.Cone.footprintRadius * 1.9)
                .offsetBy(translation: SIMD3(0, plateHeight / 2, 0)),
            ShapeResource.generateConvex(from: ring + [SIMD3(0, height, 0)]),
        ]
    }

    /// Only if the bundled model could not be read: a flat tyre of the same
    /// size and weight from RealityKit's own cylinders.
    private func prepareNativeTyre() {
        let radius = CourseSpec.Tyre.radius, height = CourseSpec.Tyre.height
        let visual = Entity()
        let rubber = ModelEntity(mesh: .generateCylinder(height: height, radius: radius),
                                 materials: [Self.paint(0.05, 0.05, 0.05, roughness: 0.95)])
        rubber.position.y = height / 2
        let hub = ModelEntity(mesh: .generateCylinder(height: 0.001, radius: radius * 0.55),
                              materials: [Self.paint(0.35, 0.35, 0.36, roughness: 0.6)])
        hub.position.y = height + 0.0005
        visual.addChild(rubber)
        visual.addChild(hub)
        visuals[.tyre] = visual
        let rim = (0..<24).flatMap { i -> [SIMD3<Float>] in
            let a = Float(i) / 24 * 2 * .pi
            return [SIMD3(cos(a) * radius, 0, sin(a) * radius), SIMD3(cos(a) * radius, height, sin(a) * radius)]
        }
        shapes[.tyre] = [ShapeResource.generateConvex(from: rim)]
    }

    private func prepareBarrier() {
        do {
            let visual = ModelEntity(mesh: try BarrierMesh.makeMesh(), materials: BarrierMesh.makeMaterials())
            visual.name = "barrier-visual"
            visuals[.barrier] = visual
        } catch {
            // The mesh is generated from constants, so this cannot fail in
            // practice; a plain block keeps the course usable if it ever does.
            AppLog.asset.error("Barrier mesh failed: \(error.localizedDescription, privacy: .public)")
            let size = SIMD3(CourseSpec.Barrier.length, CourseSpec.Barrier.height, CourseSpec.Barrier.baseWidth)
            let block = ModelEntity(mesh: .generateBox(size: size, cornerRadius: 0.004),
                                    materials: [BarrierMesh.makeMaterials()[0]])
            block.position.y = size.y / 2
            let visual = ModelEntity()
            visual.addChild(block)
            visuals[.barrier] = visual
        }
        shapes[.barrier] = [ShapeResource.generateConvex(from: BarrierMesh.hullPoints)]
    }

    // MARK: - Instances

    /// A new prop, ready to be parented under the course. Cones and tyres
    /// start kinematic, so nothing moves until driving starts.
    func makeProp(_ kind: PropKind) -> ModelEntity {
        let body = ModelEntity()
        body.name = "prop-\(kind.rawValue)"
        if let visual = visuals[kind] { body.addChild(visual.clone(recursive: true)) }
        body.components.set(CollisionComponent(shapes: shapes[kind] ?? [], mode: .default,
                                               filter: CollisionFilter(group: Self.propGroup,
                                                                       mask: [Self.propGroup, Self.groundGroup])))
        if let physics = physicsBodies[kind] { body.components.set(physics) }
        if kind.isLoose { body.components.set(PhysicsMotionComponent()) }
        return body
    }

    /// Switches a cone or tyre between held still (editing) and free
    /// (driving). Either way it leaves at rest, so a mode change never flicks
    /// it.
    static func setFree(_ prop: ModelEntity, _ free: Bool) {
        guard var body = prop.components[PhysicsBodyComponent.self], body.mode != .static else { return }
        body.mode = free ? .dynamic : .kinematic
        // A small prop can cross its own width in a frame when it is hit, so
        // it needs continuous collision detection while it is free. PhysX does
        // not allow it on kinematic bodies, so it goes off again for editing.
        body.isContinuousCollisionDetectionEnabled = free
        prop.components.set(body)
        prop.components.set(PhysicsMotionComponent())
    }

    /// The invisible floor props land on: a thin slab whose top face is the
    /// stage's ground plane, far larger than any room.
    func makeGround() -> Entity {
        let ground = Entity()
        ground.name = "course-ground"
        let half = CourseSpec.Ground.halfSize
        ground.components.set(CollisionComponent(
            shapes: [ShapeResource.generateBox(width: half * 2, height: 0.2, depth: half * 2)
                .offsetBy(translation: SIMD3(0, -0.1, 0))],
            mode: .default,
            filter: CollisionFilter(group: Self.groundGroup, mask: Self.propGroup)))
        if let groundBody { ground.components.set(groundBody) }
        return ground
    }

    // MARK: - Editing visuals

    /// A see-through copy of a prop for previewing where it will go. It has
    /// no collision or physics, so it can never be hit, picked or pushed.
    func makeGhost(_ kind: PropKind) -> Entity {
        let ghost = Entity()
        ghost.name = "ghost-\(kind.rawValue)"
        if let source = visuals[kind] {
            let copy = source.clone(recursive: true)
            copy.components.remove(CollisionComponent.self)
            copy.components.remove(PhysicsBodyComponent.self)
            ghost.addChild(copy)
        }
        ghost.addChild(makeOutline(kind, colour: .white, opacity: 0.9))
        return ghost
    }

    /// Recolours a ghost for a valid or an invalid spot.
    static func tintGhost(_ ghost: Entity, valid: Bool) {
        let body = UnlitMaterial.translucent(valid ? Self.validColour : Self.invalidColour, opacity: 0.5)
        let rim = UnlitMaterial.translucent(valid ? Self.validColour : Self.invalidColour, opacity: 0.95)
        func visit(_ entity: Entity) {
            if var model = entity.components[ModelComponent.self] {
                let isOutline = entity.name == "outline"
                model.materials = Array(repeating: isOutline ? rim : body, count: max(model.materials.count, 1))
                entity.components.set(model)
            }
            entity.children.forEach(visit)
        }
        visit(ghost)
    }

    static let validColour = Material.Color(red: 0.55, green: 0.95, blue: 0.75, alpha: 1)
    static let invalidColour = Material.Color(red: 1.0, green: 0.33, blue: 0.3, alpha: 1)
    static let selectionColour = Material.Color(red: 1.0, green: 0.78, blue: 0.22, alpha: 1)

    /// A thin line round a prop's footprint, just above the floor: a ring for
    /// a cone or a tyre, a frame for a barrier.
    func makeOutline(_ kind: PropKind, colour: Material.Color, opacity: Float) -> ModelEntity {
        let mesh: MeshResource
        switch kind {
        case .cone:
            let radius = CourseSpec.Cone.footprintRadius + 0.008
            mesh = .groundRing(inner: radius, outer: radius + 0.0045, segments: 40)
        case .tyre:
            let radius = CourseSpec.Tyre.radius + 0.008
            mesh = .groundRing(inner: radius, outer: radius + 0.0045, segments: 48)
        case .barrier:
            let half = SIMD2(CourseSpec.Barrier.length, CourseSpec.Barrier.baseWidth) / 2 + 0.008
            mesh = .groundFrame(halfExtents: half, width: 0.0045)
        }
        let outline = ModelEntity(mesh: mesh, materials: [UnlitMaterial.translucent(colour, opacity: opacity)])
        outline.name = "outline"
        outline.position.y = 0.0015
        return outline
    }

    /// Where the car starts: its footprint and which way it faces.
    func makeStartMarker(halfExtents: SIMD2<Float>) -> Entity {
        let marker = Entity()
        marker.name = "start-marker"
        let frame = ModelEntity(mesh: .groundFrame(halfExtents: halfExtents + 0.012, width: 0.004),
                                materials: [UnlitMaterial.translucent(.white, opacity: 0.55)])
        let arrow = ModelEntity(mesh: .groundChevron(width: halfExtents.x * 0.9, length: halfExtents.x * 0.7,
                                                     thickness: 0.006),
                                materials: [UnlitMaterial.translucent(.white, opacity: 0.55)])
        arrow.position.z = halfExtents.y * 0.35
        frame.position.y = 0.0012
        arrow.position.y = 0.0012
        marker.addChild(frame)
        marker.addChild(arrow)
        return marker
    }
}

extension UnlitMaterial {
    static func translucent(_ colour: Material.Color, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(color: colour)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.faceCulling = .none
        return material
    }
}

extension MeshResource {

    /// A flat annulus lying on the floor, facing up.
    static func groundRing(inner: Float, outer: Float, segments: Int) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for step in 0...segments {
            let angle = 2 * Float.pi * Float(step) / Float(segments)
            let direction = SIMD3(sin(angle), 0, cos(angle))
            positions += [direction * inner, direction * outer]
        }
        for step in 0..<segments {
            let i = UInt32(step * 2)
            indices += [i, i + 1, i + 3, i, i + 3, i + 2]
        }
        return flat(positions: positions, indices: indices, name: "ring")
    }

    /// A rectangular outline lying on the floor, `width` wide.
    static func groundFrame(halfExtents: SIMD2<Float>, width: Float) -> MeshResource {
        let outer = halfExtents
        let inner = halfExtents - width
        let corners: [SIMD2<Float>] = [SIMD2(1, 1), SIMD2(-1, 1), SIMD2(-1, -1), SIMD2(1, -1)]
        var positions: [SIMD3<Float>] = []
        for corner in corners {
            positions.append(SIMD3(corner.x * inner.x, 0, corner.y * inner.y))
            positions.append(SIMD3(corner.x * outer.x, 0, corner.y * outer.y))
        }
        var indices: [UInt32] = []
        for side in 0..<4 {
            let a = UInt32(side * 2), b = UInt32(((side + 1) % 4) * 2)
            indices += [a, a + 1, b + 1, a, b + 1, b]
        }
        return flat(positions: positions, indices: indices, name: "frame")
    }

    /// A flat chevron pointing along +Z.
    static func groundChevron(width: Float, length: Float, thickness: Float) -> MeshResource {
        let half = width / 2
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, length), SIMD3(-half, 0, 0), SIMD3(-half + thickness, 0, 0),
            SIMD3(0, 0, length - thickness * 1.9), SIMD3(half - thickness, 0, 0), SIMD3(half, 0, 0),
        ]
        return flat(positions: positions, indices: [0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 5], name: "chevron")
    }

    private static func flat(positions: [SIMD3<Float>], indices: [UInt32], name: String) -> MeshResource {
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(Array(repeating: SIMD3(0, 1, 0), count: positions.count))
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generatePlane(width: 0.01, depth: 0.01)
    }
}
