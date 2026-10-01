//
//  CourseBuilder.swift
//  vr
//
//  The props on the floor: laying them out, and running them while driving.
//

import Foundation
import RealityKit
import UIKit
import simd

/// Why a prop cannot go where the player is aiming or dragging it.
enum PlacementProblem: Equatable {
    case noSurface
    case otherSurface
    case unscannedFloor
    case tooCloseToCar
    case overlapsProp
    case courseFull
    case trackingLimited

    var message: String {
        switch self {
        case .noSurface:       return "Aim at the floor near your car."
        case .otherSurface:    return "That's a different surface — keep props on the car's floor."
        case .unscannedFloor:  return "Scan a little more floor there first."
        case .tooCloseToCar:   return "Too close to the car."
        case .overlapsProp:    return "Too close to another prop."
        case .courseFull:      return "The course is full — \(CourseSpec.maxProps) props at most."
        case .trackingLimited: return "Hold steady while tracking catches up."
        }
    }
}

/// Everything the interface shows about the course.
struct CourseStatus: Equatable {
    var coneCount = 0
    var barrierCount = 0
    var tyreCount = 0
    /// What a tap on the floor will place, if anything.
    var tool: PropKind?
    var selected: PropKind?
    /// What is wrong with the spot being aimed at or dragged to.
    var problem: PlacementProblem?
    var canUndo = false
    /// A finger is moving or turning a prop.
    var isAdjusting = false

    var count: Int { coneCount + barrierCount + tyreCount }
    var isFull: Bool { count >= CourseSpec.maxProps }
}

/// A short message about something that has just happened.
struct CourseNotice: Equatable {
    let id = UUID()
    let text: String
    let isWarning: Bool
}

/// What the builder needs to know about the world to judge a spot.
struct CourseEnvironment {
    var surfaces: DetectedSurfaces
    /// The car where it is now, and where it restarts from.
    var carFootprints: [Footprint2D]
    var trackingAllowsPlacement: Bool
}

/// Where the player is aiming, from an AR raycast.
struct CourseAim {
    var world: SIMD3<Float>
    /// The ray hit a detected plane's outline rather than an estimate.
    var onDetectedPlane: Bool
    /// Which way the camera faces, in world space.
    var viewDirection: SIMD3<Float>
}

/// The course: its layout, its entities, editing it and running it.
///
/// **Layout and bodies.** `layout` is the design — where each prop was put.
/// Each prop also has a live body in the scene, and while driving a cone's
/// body goes wherever the car knocks it. Editing and resetting put the bodies
/// back on their marks, so a knocked-over course is never lost.
///
/// **Anchoring.** Everything hangs off the same ARKit anchor as the car, so
/// ARKit's refinements move the car and the course together and they cannot
/// drift apart as the player walks round them. The course's own root is a
/// localised physics simulation in that anchor's space: gravity is the
/// anchor's down, and the anchor being nudged never throws a cone.
///
/// **Two physics worlds, one boundary.** RealityKit simulates the cones and tyres
/// against the invisible floor, the barriers and each other. The car is not a
/// RealityKit body — `VehicleDynamics` moves it — so its collisions with the
/// course are solved by `CourseContacts` inside the vehicle step, and only the
/// impulse a cone receives crosses over into RealityKit.
///
/// Nothing here collides with real furniture. Without LiDAR the phone cannot
/// know where a sofa is; the course is a virtual set on the real floor.
struct CourseSnapshot {
    var layout: [PropLayout]
    var undo: [[PropLayout]]
}

@MainActor
final class CourseBuilder {

    var onStatusChange: ((CourseStatus) -> Void)?
    var onNotice: ((CourseNotice) -> Void)?

    private(set) var status = CourseStatus() {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    /// Handed to `VehicleDynamics` every frame.
    let contacts = CourseContacts()

    private let factory = PropFactory.shared
    private weak var stage: Entity?
    private let root = Entity()
    private let overlays = Entity()
    private var ground: Entity?

    private(set) var layout: [PropLayout] = []
    private var bodies: [UUID: ModelEntity] = [:]
    private var outlines: [UUID: ModelEntity] = [:]
    private var propForEntity: [ObjectIdentifier: UUID] = [:]
    private var barrierBoxes: [OrientedBox2D] = []

    private var undoStack: [[PropLayout]] = []
    private static let undoDepth = 40

    /// Cones that left the room; back on the next reset.
    private var lost: Set<UUID> = []
    /// How long each cone has been nearly still.
    private var restingFor: [UUID: Float] = [:]

    private(set) var isEditing = false
    private var tool: PropKind?
    private var selectedID: UUID?
    private var problem: PlacementProblem?

    private var ghosts: [PropKind: Entity] = [:]
    private var ghostPose: (position: SIMD2<Float>, yaw: Float)?
    private var ghostValid: Bool?
    private var startMarker: Entity?

    private struct Adjustment {
        let id: UUID
        let original: PropLayout
        var lastValid: PropLayout
        /// Prop position minus the finger's floor point, so a grabbed prop
        /// does not jump to sit under the finger.
        var grabOffset: SIMD2<Float>
        let before: [PropLayout]
    }
    private var adjustment: Adjustment?

    private let restingOutline = UnlitMaterial.translucent(.white, opacity: 0.4)
    private let selectedOutline = UnlitMaterial.translucent(PropFactory.selectionColour, opacity: 1)
    private let invalidOutline = UnlitMaterial.translucent(PropFactory.invalidColour, opacity: 1)

    /// Hides every editing aid regardless of mode, while a photo or a video
    /// is being taken.
    var overlaysSuppressed = false { didSet { refreshOverlays() } }

    var isEmpty: Bool { layout.isEmpty }
    var isAttached: Bool { stage != nil }

    init() {
        root.name = "course"
        overlays.name = "course-editing-aids"
        root.addChild(overlays)
        overlays.isEnabled = false
    }

    // MARK: - Attaching

    /// Hangs the course off the car's anchor. Needs `PropFactory` prepared.
    func attach(to stage: Entity) {
        guard self.stage !== stage else { return }
        root.removeFromParent()
        self.stage = stage
        if root.components[PhysicsSimulationComponent.self] == nil {
            root.components.set(PhysicsSimulationComponent())
        }
        if ground == nil {
            let floor = factory.makeGround()
            root.addChild(floor)
            ground = floor
        }
        stage.addChild(root)
    }

    /// Removes every prop and lets go of the anchor, for when the anchor
    /// itself is going: a restart, ARKit dropping it, or leaving the screen.
    func tearDown() {
        cancelAdjustment()
        for prop in layout { removeEntities(for: prop.id) }
        layout.removeAll()
        undoStack.removeAll()
        lost.removeAll()
        restingFor.removeAll()
        barrierBoxes.removeAll()
        contacts.barriers.removeAll()
        contacts.looseProps.removeAll()
        tool = nil
        selectedID = nil
        problem = nil
        isEditing = false
        hideGhosts()
        startMarker?.removeFromParent()
        startMarker = nil
        root.removeFromParent()
        stage = nil
        refreshOverlays()
        publish()
    }

    func snapshot() -> CourseSnapshot { CourseSnapshot(layout: layout, undo: undoStack) }
    func restore(_ snapshot: CourseSnapshot) {
        apply(snapshot.layout); undoStack = snapshot.undo; putPropsBack(); publish()
    }
    func replaceForChallenge(_ props: [PropLayout]) {
        guard props.count <= CourseSpec.maxProps else { return }
        cancelAdjustment(); apply(props); undoStack.removeAll(); putPropsBack(); publish()
    }

    // MARK: - Modes

    /// Editing holds every cone still on its mark and shows the editing aids;
    /// driving lets the cones and tyres go.
    func setEditing(_ editing: Bool) {
        guard editing != isEditing else { return }
        cancelAdjustment()
        isEditing = editing
        if editing {
            putPropsBack(free: false)
        } else {
            tool = nil
            selectedID = nil
            problem = nil
            hideGhosts()
            putPropsBack(free: true)
        }
        refreshOutlines()
        refreshOverlays()
        publish()
    }

    /// Stands every prop back on its mark: for a reset, and on entering
    /// editing.
    func putPropsBack(free: Bool? = nil) {
        let free = free ?? !isEditing
        for prop in layout {
            guard let body = bodies[prop.id] else { continue }
            body.stopAllAnimations()
            body.isEnabled = true
            body.transform = transform(for: prop)
            if prop.kind.isLoose {
                PropFactory.setFree(body, free)
                body.resetPhysicsTransform(recursive: false)
            }
        }
        lost.removeAll()
        restingFor.removeAll()
    }

    /// Where the car starts, drawn as a box while editing so it is clear why
    /// props cannot go there.
    func setCarStart(position: SIMD2<Float>, heading: Float, halfExtents: SIMD2<Float>) {
        startMarker?.removeFromParent()
        let marker = factory.makeStartMarker(halfExtents: halfExtents)
        marker.position = SIMD3(position.x, 0, position.y)
        marker.orientation = simd_quatf(angle: heading, axis: SIMD3(0, 1, 0))
        overlays.addChild(marker)
        startMarker = marker
    }

    // MARK: - Tools and selection

    func setTool(_ kind: PropKind?) {
        cancelAdjustment()
        tool = kind
        if kind != nil { selectedID = nil }
        ghostPose = nil
        ghostValid = nil
        hideGhosts()
        problem = nil
        refreshOutlines()
        publish()
    }

    func select(_ id: UUID?) {
        guard selectedID != id || (id != nil && tool != nil) else { return }
        selectedID = id
        if id != nil {
            tool = nil
            hideGhosts()
        }
        problem = nil
        refreshOutlines()
        publish()
    }

    var selectedProp: PropLayout? {
        guard let selectedID else { return nil }
        return layout.first { $0.id == selectedID }
    }

    /// The prop under a screen point: the exact collision shape first, then
    /// the nearest one within a fingertip, because a 7 cm cone two metres away
    /// is a very small target.
    func prop(at point: CGPoint, in view: ARView) -> UUID? {
        for hit in view.hitTest(point, query: .all, mask: PropFactory.propGroup) {
            var entity: Entity? = hit.entity
            while let current = entity {
                if let id = propForEntity[ObjectIdentifier(current)] { return id }
                entity = current.parent
            }
        }

        var best: (id: UUID, distance: CGFloat)?
        for prop in layout {
            guard let body = bodies[prop.id], body.isEnabled else { continue }
            let samples: [SIMD3<Float>]
            switch prop.kind {
            case .cone:
                samples = [SIMD3(0, CourseSpec.Cone.height * 0.45, 0)]
            case .tyre:
                samples = [SIMD3(0, CourseSpec.Tyre.height / 2, 0)]
            case .barrier:
                let reach = CourseSpec.Barrier.length * 0.42
                samples = [SIMD3(-reach, CourseSpec.Barrier.height / 2, 0), SIMD3(reach, CourseSpec.Barrier.height / 2, 0)]
            }
            let projected = samples.compactMap { view.project(body.convert(position: $0, to: nil)) }
            guard !projected.isEmpty else { continue }
            let distance = projected.count == 2
                ? Self.distance(from: point, toSegment: projected[0], projected[1])
                : hypot(projected[0].x - point.x, projected[0].y - point.y)
            if distance < 46, best == nil || distance < best!.distance { best = (prop.id, distance) }
        }
        return best?.id
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Aiming and placing

    /// Moves the placement preview to where the player is aiming and judges
    /// the spot. Called every frame while a tool is active.
    func updateAim(_ aim: CourseAim?, environment: CourseEnvironment, deltaTime: Float) {
        guard isEditing, let tool, adjustment == nil, stage != nil else {
            hideGhosts()
            return
        }
        guard let aim else {
            hideGhosts()
            ghostPose = nil
            setProblem(environment.trackingAllowsPlacement ? .noSurface : .trackingLimited)
            return
        }

        let local = root.convert(position: aim.world, from: nil)
        let target = SIMD2(local.x, local.z)
        let direction = root.convert(direction: aim.viewDirection, from: nil)
        let targetYaw = simd_length(SIMD2(direction.x, direction.z)) > 1e-4 ? atan2(direction.x, direction.z) : 0

        // A little smoothing so the preview glides rather than trembling with
        // the raycast; a big jump (the aim moving to another patch) snaps.
        var pose = ghostPose ?? (target, targetYaw)
        if simd_distance(pose.position, target) > 0.25 {
            pose = (target, targetYaw)
        } else {
            let blend = min(deltaTime * 18, 1)
            pose.position += (target - pose.position) * blend
            pose.yaw += Self.shortestAngle(from: pose.yaw, to: targetYaw) * blend
        }
        ghostPose = pose

        let candidate = PropLayout(kind: tool, position: pose.position, yaw: pose.yaw)
        var found: PlacementProblem?
        if abs(local.y) > CourseSpec.sameSurfaceTolerance {
            found = .otherSurface
        } else if !aim.onDetectedPlane {
            found = .unscannedFloor
        } else {
            found = problem(for: candidate, ignoring: nil, adding: true, environment: environment)
        }

        let ghost = ghostEntity(for: tool)
        ghost.position = SIMD3(pose.position.x, abs(local.y) > CourseSpec.sameSurfaceTolerance ? local.y : 0,
                               pose.position.y)
        ghost.orientation = simd_quatf(angle: pose.yaw, axis: SIMD3(0, 1, 0))
        ghost.isEnabled = true
        let valid = found == nil
        if ghostValid != valid {
            ghostValid = valid
            PropFactory.tintGhost(ghost, valid: valid)
        }
        setProblem(found)
    }

    /// Puts a prop down where the preview is. Returns what went wrong, if
    /// anything.
    func placeAtAim(environment: CourseEnvironment) -> PlacementProblem? {
        guard isEditing, let tool else { return nil }
        guard let pose = ghostPose, ghostValid == true else { return problem ?? .noSurface }
        let prop = PropLayout(kind: tool, position: pose.position, yaw: pose.yaw)
        if let found = problem(for: prop, ignoring: nil, adding: true, environment: environment) { return found }
        pushUndo()
        add(prop, animated: true)
        publish()
        return nil
    }

    // MARK: - Moving and turning

    /// Starts dragging the prop under `point`, if there is one.
    func beginDrag(at point: CGPoint, in view: ARView, floor: SIMD3<Float>?) -> Bool {
        guard isEditing, adjustment == nil, let id = prop(at: point, in: view),
              let prop = layout.first(where: { $0.id == id }) else { return false }
        select(id)
        var offset = SIMD2<Float>.zero
        if let floor {
            let local = root.convert(position: floor, from: nil)
            offset = prop.position - SIMD2(local.x, local.z)
            // A grab from far off the prop's footprint (a forgiving pick on a
            // small cone) should not leave it trailing a long way behind.
            if simd_length(offset) > 0.12 { offset = .zero }
        }
        adjustment = Adjustment(id: id, original: prop, lastValid: prop, grabOffset: offset, before: layout)
        publish()
        return true
    }

    func drag(to floor: SIMD3<Float>?, onDetectedPlane: Bool, environment: CourseEnvironment) {
        guard let adjusting = adjustment, let index = layout.firstIndex(where: { $0.id == adjusting.id }),
              let floor else { return }
        let local = root.convert(position: floor, from: nil)
        var candidate = layout[index]
        candidate.position = SIMD2(local.x, local.z) + adjusting.grabOffset

        var found: PlacementProblem?
        if abs(local.y) > CourseSpec.sameSurfaceTolerance {
            found = .otherSurface
        } else if !onDetectedPlane {
            found = .unscannedFloor
        } else {
            found = problem(for: candidate, ignoring: candidate.id, adding: false, environment: environment)
        }
        adjust(to: candidate, at: index, problem: found)
    }

    func beginTwist() -> Bool {
        guard isEditing, adjustment == nil, let prop = selectedProp else { return false }
        adjustment = Adjustment(id: prop.id, original: prop, lastValid: prop, grabOffset: .zero, before: layout)
        publish()
        return true
    }

    /// `rotation` is the gesture's own, clockwise-positive on screen. Seen
    /// from above that is a turn towards negative yaw.
    func twist(by rotation: Float, environment: CourseEnvironment) {
        guard let adjusting = adjustment, let index = layout.firstIndex(where: { $0.id == adjusting.id }) else { return }
        var candidate = layout[index]
        candidate.yaw = Self.normalise(adjusting.original.yaw - rotation)
        let found = problem(for: candidate, ignoring: candidate.id, adding: false, environment: environment)
        adjust(to: candidate, at: index, problem: found)
    }

    private func adjust(to candidate: PropLayout, at index: Int, problem found: PlacementProblem?) {
        layout[index] = candidate
        if let body = bodies[candidate.id] { body.transform = transform(for: candidate) }
        if let outline = outlines[candidate.id] {
            outline.transform = transform(for: candidate)
            outline.position.y = 0.0015
            outline.model?.materials = [found == nil ? selectedOutline : invalidOutline]
        }
        if found == nil { adjustment?.lastValid = candidate }
        setProblem(found)
    }

    /// Finishes a drag or a twist. A prop let go somewhere it cannot stay
    /// goes back to the last place it could.
    func endAdjustment() {
        guard let finished = adjustment else { return }
        adjustment = nil
        if let index = layout.firstIndex(where: { $0.id == finished.id }) {
            if layout[index] != finished.lastValid {
                if let reason = problem { notify(reason.message, warning: true) }
                layout[index] = finished.lastValid
                if let body = bodies[finished.id] {
                    body.move(to: transform(for: finished.lastValid), relativeTo: root, duration: 0.2,
                              timingFunction: .easeOut)
                }
                if let outline = outlines[finished.id] { place(outline, at: finished.lastValid) }
            }
        }
        if layout != finished.before { pushUndo(finished.before) }
        problem = nil
        rebuildBarriers()
        refreshOutlines()
        publish()
    }

    /// Abandons a drag or twist where it started — for the app going to the
    /// background, tracking being lost, or a mode change mid-gesture.
    func cancelAdjustment() {
        guard let cancelled = adjustment else { return }
        adjustment = nil
        if let index = layout.firstIndex(where: { $0.id == cancelled.id }) {
            layout[index] = cancelled.original
            if let body = bodies[cancelled.id] { body.transform = transform(for: cancelled.original) }
            if let outline = outlines[cancelled.id] { place(outline, at: cancelled.original) }
        }
        problem = nil
        refreshOutlines()
        publish()
    }

    /// Turns the selection by a step, onto a tidy multiple of that step so a
    /// row of barriers lines up.
    func rotateSelected(by step: Float, environment: CourseEnvironment) {
        guard let prop = selectedProp, let index = layout.firstIndex(of: prop), adjustment == nil else { return }
        var candidate = prop
        let size = abs(step)
        candidate.yaw = Self.normalise(((prop.yaw + step) / size).rounded() * size)
        if let found = problem(for: candidate, ignoring: prop.id, adding: false, environment: environment) {
            notify(found == .tooCloseToCar || found == .overlapsProp ? "No room to turn it there." : found.message,
                   warning: true)
            return
        }
        pushUndo()
        layout[index] = candidate
        bodies[prop.id]?.move(to: transform(for: candidate), relativeTo: root, duration: 0.15, timingFunction: .easeOut)
        if let outline = outlines[prop.id] { place(outline, at: candidate) }
        rebuildBarriers()
        publish()
    }

    /// A copy of the selection beside it: end to end for a barrier, so a few
    /// taps make a wall; alongside for a cone; touching for a tyre.
    func duplicateSelected(environment: CourseEnvironment) {
        guard let source = selectedProp, adjustment == nil else { return }
        guard layout.count < CourseSpec.maxProps else {
            notify(PlacementProblem.courseFull.message, warning: true)
            return
        }
        let offsets: [SIMD2<Float>]
        switch source.kind {
        case .barrier:
            let step = CourseSpec.Barrier.length + 0.006
            let row = CourseSpec.Barrier.baseWidth + 0.05
            offsets = [SIMD2(step, 0), SIMD2(-step, 0), SIMD2(0, row), SIMD2(0, -row),
                       SIMD2(step * 2, 0), SIMD2(-step * 2, 0)]
        case .cone, .tyre:
            // Cones stand a little apart; tyres go shoulder to shoulder, so a
            // few copies make the tyre wall a drift course is edged with.
            // A hair over the placement clearance, so rounding can never
            // reject the spot right beside it.
            let step: Float = source.kind == .tyre ? CourseSpec.Tyre.diameter + CourseSpec.propClearance + 0.002 : 0.11
            offsets = [SIMD2(step, 0), SIMD2(-step, 0), SIMD2(0, step), SIMD2(0, -step),
                       SIMD2(step, step), SIMD2(-step, step), SIMD2(step, -step), SIMD2(-step, -step),
                       SIMD2(step * 2, 0), SIMD2(-step * 2, 0)]
        }
        let axisX = Plane2D.axisX(source.yaw), axisZ = Plane2D.axisZ(source.yaw)
        for offset in offsets {
            let copy = PropLayout(kind: source.kind, position: source.position + axisX * offset.x + axisZ * offset.y,
                                  yaw: source.yaw)
            guard problem(for: copy, ignoring: nil, adding: true, environment: environment) == nil else { continue }
            pushUndo()
            add(copy, animated: true)
            select(copy.id)
            return
        }
        notify("No free floor beside it — move it, or place a new one.", warning: true)
    }

    func deleteSelected() {
        guard let id = selectedID, adjustment == nil else { return }
        pushUndo()
        remove(id)
        selectedID = nil
        problem = nil
        refreshOutlines()
        publish()
    }

    /// Removes everything. Undoable, so a slip costs nothing.
    func clear() {
        guard !layout.isEmpty else { return }
        cancelAdjustment()
        pushUndo()
        for prop in layout { remove(prop.id) }
        selectedID = nil
        problem = nil
        publish()
    }

    func undo() {
        cancelAdjustment()
        guard let previous = undoStack.popLast() else { return }
        apply(previous)
        if let selectedID, !layout.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        problem = nil
        refreshOutlines()
        publish()
    }

    // MARK: - Slalom

    /// Lays a row of cones in front of the car. Every cone passes the same
    /// test a hand-placed one would; if a full row will not fit, fewer cones
    /// go down, and if three will not, nothing does and the player is told why.
    func addSlalom(carPosition: SIMD2<Float>, carHeading: Float, carHalfExtents: SIMD2<Float>,
                   carLength: Float, environment: CourseEnvironment) {
        guard isEditing, adjustment == nil else { return }
        guard environment.trackingAllowsPlacement else {
            notify(PlacementProblem.trackingLimited.message, warning: true)
            return
        }
        let plan = SlalomPlanner.plan(
            carPosition: carPosition, carHeading: carHeading, carHalfExtents: carHalfExtents,
            carLength: carLength, capacity: CourseSpec.maxProps - layout.count,
            canStand: { [self] position in
                problem(for: PropLayout(kind: .cone, position: position, yaw: carHeading),
                        ignoring: nil, adding: false, environment: environment) == nil
            })

        switch plan {
        case .success(let slalom):
            pushUndo()
            tool = nil
            selectedID = nil
            hideGhosts()
            for (index, position) in slalom.positions.enumerated() {
                add(PropLayout(kind: .cone, position: position, yaw: slalom.heading), animated: true,
                    delay: Double(index) * 0.06)
            }
            let count = slalom.positions.count
            notify(count < SlalomPlanner.preferredCount
                   ? "Room for \(count) cones here — scan more floor for a longer slalom."
                   : "Slalom added — weave through all \(count).",
                   warning: false)
            refreshOutlines()
            publish()
        case .failure(.courseFull):
            notify("Not enough room left in the course for a slalom — remove a few props first.", warning: true)
        case .failure(.noRoom):
            notify("Not enough clear, scanned floor near the car for a slalom. Scan more floor, or move the car.",
                   warning: true)
        }
    }

    // MARK: - Driving

    /// Fills the contact solver with where everything is right now. Called
    /// once per frame, before the car is advanced.
    func prepareContacts() {
        guard !isEditing, !layout.isEmpty else {
            contacts.barriers.removeAll(keepingCapacity: true)
            contacts.looseProps.removeAll(keepingCapacity: true)
            return
        }
        contacts.barriers = barrierBoxes

        var loose: [CourseContacts.LooseProp] = []
        loose.reserveCapacity(layout.count)
        for prop in layout where prop.kind.isLoose && !lost.contains(prop.id) {
            guard let body = bodies[prop.id] else { continue }
            let base = body.position
            let up = body.orientation.act(SIMD3(0, 1, 0))
            let circles: [SIMD3<Float>]
            let lowest: Float
            switch prop.kind {
            case .tyre:
                let height = CourseSpec.Tyre.height, radius = CourseSpec.Tyre.radius
                let centre = base + up * (height / 2)
                let flat = abs(up.y)
                if flat > 0.7 {
                    circles = [SIMD3(centre.x, centre.z, CourseSpec.Tyre.contactRadius)]
                } else {
                    // Up on its edge: a short row along the floor, in the
                    // tyre's own plane.
                    let across = simd_cross(up, SIMD3<Float>(0, 1, 0))
                    let along = simd_length(across) > 1e-4 ? simd_normalize(across) : SIMD3<Float>(1, 0, 0)
                    circles = [Float(-0.6), 0, 0.6].map { fraction -> SIMD3<Float> in
                        let point = centre + along * (radius * fraction)
                        return SIMD3(point.x, point.z, height / 2 + 0.004)
                    }
                }
                lowest = centre.y - (flat * height / 2 + (1 - flat * flat).squareRoot() * radius)
            case .cone, .barrier:
                // Three sections down the axis, narrowing to the tip. Upright
                // they stack into one circle; lying down they trace its length.
                let height = CourseSpec.Cone.height
                let sections: [(Float, Float)] = [(0.1, CourseSpec.Cone.contactRadius), (0.42, 0.015), (0.72, 0.009)]
                circles = sections.map { fraction, radius -> SIMD3<Float> in
                    let centre = base + up * (height * fraction)
                    return SIMD3(centre.x, centre.z, radius)
                }
                lowest = min(base.y, base.y + up.y * height)
            }
            let velocity = body.components[PhysicsMotionComponent.self]?.linearVelocity ?? .zero
            loose.append(CourseContacts.LooseProp(id: prop.id, kind: prop.kind, circles: circles,
                                                  velocity: SIMD2(velocity.x, velocity.z), lowestPoint: lowest))
        }
        contacts.looseProps = loose
    }

    /// Hands every cone and tyre the impulse the car gave it, for RealityKit
    /// to turn into sliding, tipping and tumbling. Called once per frame,
    /// after the car is advanced.
    func applyContactImpulses() {
        guard !isEditing else { return }
        // About where a bumper is. That is above a cone's centre of mass, so a
        // real hit tips a cone over as well as shoving it. A tyre lying flat is
        // lower than a bumper and is pushed through its middle instead: it
        // skids and spins away rather than flipping.
        let bumper = contacts.carHeight * 0.17
        for prop in contacts.looseProps {
            guard let point = prop.impulsePoint, let body = bodies[prop.id] else { continue }
            let up = body.orientation.act(SIMD3(0, 1, 0))
            let height: Float
            switch prop.kind {
            case .tyre:
                height = body.position.y + up.y * CourseSpec.Tyre.height / 2 + 0.002
            case .cone, .barrier:
                let top = max(body.position.y, body.position.y + up.y * CourseSpec.Cone.height) + 0.012
                height = min(bumper, top)
            }
            body.applyImpulse(SIMD3(prop.impulse.x, 0, prop.impulse.y),
                              at: SIMD3(point.x, height, point.y), relativeTo: root)
            restingFor[prop.id] = 0
        }
    }

    /// Housekeeping for loose props: puts away any that have left the room,
    /// and settles any that have all but stopped, so nothing twitches on the
    /// floor for ever.
    func updateDriving(deltaTime: Float) {
        guard !isEditing, !layout.isEmpty else { return }
        for prop in layout where prop.kind.isLoose && !lost.contains(prop.id) {
            guard let body = bodies[prop.id] else { continue }
            let position = body.position
            if simd_length(SIMD2(position.x, position.z)) > CourseSpec.lostPropDistance
                || position.y < CourseSpec.lostPropDepth {
                body.isEnabled = false
                lost.insert(prop.id)
                continue
            }
            guard let motion = body.components[PhysicsMotionComponent.self] else { continue }
            let still = simd_length(motion.linearVelocity) < 0.012 && simd_length(motion.angularVelocity) < 0.1
            let before = restingFor[prop.id] ?? 0
            let now = still ? before + deltaTime : 0
            restingFor[prop.id] = now
            // Once, as it comes to rest — setting it every frame would keep
            // waking the body up.
            if before < 0.6 && now >= 0.6 { body.components.set(PhysicsMotionComponent()) }
        }
    }

    // MARK: - Checking a spot

    /// What is wrong with standing `candidate` where it is, if anything.
    func problem(for candidate: PropLayout, ignoring: UUID?, adding: Bool,
                 environment: CourseEnvironment) -> PlacementProblem? {
        if adding && layout.count >= CourseSpec.maxProps { return .courseFull }
        if !environment.trackingAllowsPlacement { return .trackingLimited }

        let footprint = candidate.footprint
        let toWorld = root.transformMatrix(relativeTo: nil)
        for point in footprint.supportPoints {
            let world = toWorld * SIMD4(point.x, 0, point.y, 1)
            if !environment.surfaces.contains(SIMD3(world.x, world.y, world.z)) { return .unscannedFloor }
        }
        for car in environment.carFootprints where footprint.overlaps(car, margin: CourseSpec.carClearance) {
            return .tooCloseToCar
        }
        for other in layout where other.id != ignoring && other.id != candidate.id {
            if footprint.overlaps(other.footprint, margin: CourseSpec.propClearance) { return .overlapsProp }
        }
        return nil
    }

    // MARK: - Entities

    private func add(_ prop: PropLayout, animated: Bool, delay: TimeInterval = 0) {
        layout.append(prop)
        let body = factory.makeProp(prop.kind)
        body.transform = transform(for: prop)
        if prop.kind.isLoose { PropFactory.setFree(body, !isEditing) }
        root.addChild(body)
        bodies[prop.id] = body
        propForEntity[ObjectIdentifier(body)] = prop.id

        let outline = factory.makeOutline(prop.kind, colour: .white, opacity: 0.4)
        place(outline, at: prop)
        overlays.addChild(outline)
        outlines[prop.id] = outline

        if animated {
            // Drops the last few millimetres into place: enough to show it has
            // landed, too little to ever read as floating.
            let final = body.transform
            var start = final
            start.translation.y += 0.012
            start.scale = SIMD3(repeating: 0.9)
            body.transform = start
            Task { @MainActor [weak body] in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let body, body.parent != nil else { return }
                body.move(to: final, relativeTo: body.parent, duration: 0.16, timingFunction: .easeOut)
            }
        }
        if prop.kind == .barrier { rebuildBarriers() }
        refreshOutlines()
    }

    private func remove(_ id: UUID) {
        let wasBarrier = layout.first { $0.id == id }?.kind == .barrier
        layout.removeAll { $0.id == id }
        removeEntities(for: id)
        lost.remove(id)
        restingFor[id] = nil
        if wasBarrier { rebuildBarriers() }
    }

    private func removeEntities(for id: UUID) {
        if let body = bodies.removeValue(forKey: id) {
            propForEntity[ObjectIdentifier(body)] = nil
            body.stopAllAnimations()
            body.removeFromParent()
        }
        outlines.removeValue(forKey: id)?.removeFromParent()
    }

    /// Makes the scene match a remembered layout, touching only what differs.
    private func apply(_ target: [PropLayout]) {
        let wanted = Set(target.map(\.id))
        for prop in layout where !wanted.contains(prop.id) { remove(prop.id) }
        for prop in target {
            if let index = layout.firstIndex(where: { $0.id == prop.id }) {
                layout[index] = prop
                bodies[prop.id]?.transform = transform(for: prop)
                if let outline = outlines[prop.id] { place(outline, at: prop) }
            } else {
                add(prop, animated: false)
            }
        }
        // Keep the remembered order, so a second undo lines up with the first.
        layout = target
        rebuildBarriers()
    }

    private func transform(for prop: PropLayout) -> Transform {
        Transform(scale: .one, rotation: simd_quatf(angle: prop.yaw, axis: SIMD3(0, 1, 0)),
                  translation: SIMD3(prop.position.x, 0, prop.position.y))
    }

    private func place(_ outline: Entity, at prop: PropLayout) {
        outline.transform = transform(for: prop)
        outline.position.y = 0.0015
    }

    private func rebuildBarriers() {
        barrierBoxes = layout.filter { $0.kind == .barrier }.map { prop in
            OrientedBox2D(centre: prop.position,
                          halfExtents: SIMD2(CourseSpec.Barrier.length, CourseSpec.Barrier.contactWidth) / 2,
                          angle: prop.yaw)
        }
    }

    private func ghostEntity(for kind: PropKind) -> Entity {
        if let ghost = ghosts[kind] { return ghost }
        let ghost = factory.makeGhost(kind)
        ghost.isEnabled = false
        overlays.addChild(ghost)
        ghosts[kind] = ghost
        ghostValid = nil
        return ghost
    }

    private func hideGhosts() {
        for ghost in ghosts.values { ghost.isEnabled = false }
    }

    private func refreshOverlays() {
        overlays.isEnabled = isEditing && !overlaysSuppressed
    }

    private func refreshOutlines() {
        for (id, outline) in outlines {
            outline.model?.materials = [id == selectedID ? selectedOutline : restingOutline]
        }
    }

    // MARK: - Undo and publishing

    private func pushUndo(_ snapshot: [PropLayout]? = nil) {
        undoStack.append(snapshot ?? layout)
        if undoStack.count > Self.undoDepth { undoStack.removeFirst(undoStack.count - Self.undoDepth) }
    }

    private func setProblem(_ found: PlacementProblem?) {
        guard problem != found else { return }
        problem = found
        publish()
    }

    private func notify(_ text: String, warning: Bool) {
        onNotice?(CourseNotice(text: text, isWarning: warning))
    }

    private func publish() {
        status = CourseStatus(
            coneCount: layout.count { $0.kind == .cone },
            barrierCount: layout.count { $0.kind == .barrier },
            tyreCount: layout.count { $0.kind == .tyre },
            tool: isEditing ? tool : nil,
            selected: isEditing ? selectedProp?.kind : nil,
            problem: isEditing ? problem : nil,
            canUndo: isEditing && !undoStack.isEmpty,
            isAdjusting: adjustment != nil)
    }

    // MARK: - Angles

    private static func normalise(_ angle: Float) -> Float {
        var result = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if result > .pi { result -= 2 * .pi }
        if result < -.pi { result += 2 * .pi }
        return result
    }

    private static func shortestAngle(from: Float, to: Float) -> Float {
        normalise(to - from)
    }
}
