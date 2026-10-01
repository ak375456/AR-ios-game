//
//  ManualOccluders.swift
//  vr
//
//  Hand-placed invisible shapes that hide the car behind real furniture.
//

import ARKit
import Foundation
import RealityKit
import UIKit
import simd

/// Which measurement of a selected occluder the editor is adjusting.
enum OccluderDimension: String, CaseIterable, Identifiable {
    case width, height, depth, lift, turn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .width:  return "Width"
        case .height: return "Height"
        case .depth:  return "Depth"
        case .lift:   return "Lift"
        case .turn:   return "Turn"
        }
    }

    /// Slider range, in metres for the sizes and degrees for the rotation.
    var range: ClosedRange<Float> {
        switch self {
        case .width, .depth: return 0.05...3.0
        case .height:        return 0.05...2.6
        case .lift:          return 0.0...2.0
        case .turn:          return -180...180
        }
    }

    func formatted(_ value: Float) -> String {
        switch self {
        case .turn: return "\(Int(value.rounded()))°"
        default:    return String(format: "%.2f m", value)
        }
    }
}

/// One hand-placed box.
///
/// The shape is described in real-world metres — this stands for a real coffee
/// table, not for something the size of the toy car — and it is rendered with
/// `OcclusionMaterial`, which writes depth and no colour. The camera feed shows
/// straight through it; only virtual things behind it are hidden. That is the
/// whole trick, and it is why this is not a screen-space cut-out: the box is a
/// real object in the scene at a real distance, so the car, its wheels, the
/// tyre smoke and the skid marks are each hidden exactly to the extent they are
/// actually behind it.
@MainActor
final class Occluder: Identifiable {

    let id = UUID()

    /// Metres, before rotation.
    fileprivate(set) var size = SIMD3<Float>(0.5, 0.5, 0.5)
    /// Radians about the world's up axis.
    fileprivate(set) var yaw: Float = 0
    /// Gap between the floor and the underside of the box.
    fileprivate(set) var lift: Float = 0

    /// The ARKit anchor the box stands on, so ARKit keeps refining where it is
    /// as it learns more about the room.
    fileprivate var anchor: ARAnchor
    fileprivate var anchorEntity: AnchorEntity
    /// Everything below this moves with the box; kept across re-anchoring.
    fileprivate let body = Entity()
    fileprivate let shell: ModelEntity
    fileprivate let outline = Entity()
    fileprivate var edges: [ModelEntity] = []

    fileprivate init(anchor: ARAnchor, anchorEntity: AnchorEntity, shell: ModelEntity) {
        self.anchor = anchor
        self.anchorEntity = anchorEntity
        self.shell = shell
    }

    func value(for dimension: OccluderDimension) -> Float {
        switch dimension {
        case .width:  return size.x
        case .height: return size.y
        case .depth:  return size.z
        case .lift:   return lift
        case .turn:   return yaw * 180 / .pi
        }
    }

    fileprivate func setValue(_ value: Float, for dimension: OccluderDimension) {
        switch dimension {
        case .width:  size.x = value
        case .height: size.y = value
        case .depth:  size.z = value
        case .lift:   lift = value
        case .turn:   yaw = value * .pi / 180
        }
    }
}

/// The hand-placed occluders, and the editing session that maintains them.
///
/// This is the path for iPhones with no LiDAR scanner. It makes no attempt to
/// recognise furniture — it cannot, and the interface says so. The player marks
/// out the few real things that matter by hand, and those shapes are then
/// honest, stable occluders anchored in the room.
///
/// Nothing here has a `CollisionComponent`. Occlusion and collision are kept
/// deliberately apart: an occluder changes what you can *see* and never what
/// the car can *hit*, so the driving model never learns these exist and the car
/// drives through the marked area exactly as it did before. Even picking a box
/// by tapping it goes through screen projection rather than a collision
/// raycast, so there is no collision shape in the scene at all.
@MainActor
final class ManualOccluders {

    private(set) var boxes: [Occluder] = []
    private(set) var selectedID: UUID?

    /// Outlines are drawn only while editing, so a photo or a recording never
    /// shows the scaffolding.
    var isEditing = false { didSet { refreshOutlines() } }

    /// Suppresses outlines during a capture even if editing is somehow on.
    var isCapturing = false { didSet { refreshOutlines() } }

    /// Fired whenever the boxes or the selection change, so the interface can
    /// follow along — including selections made by tapping the scene.
    var onChange: (() -> Void)?

    private weak var arView: ARView?

    /// One unit cube, shared by every shell and every outline bar; the shapes
    /// differ only by scale, so there is no mesh to rebuild when a slider moves.
    private let unitBox = MeshResource.generateBox(size: 1)
    private let edgeThickness: Float = 0.009

    var selected: Occluder? {
        guard let selectedID else { return nil }
        return boxes.first { $0.id == selectedID }
    }

    var isEmpty: Bool { boxes.isEmpty }

    func attach(to arView: ARView) {
        self.arView = arView
    }

    // MARK: - Adding and removing

    /// Stands a new box on the floor at `position`, turned to face the viewer.
    @discardableResult
    func add(at position: SIMD3<Float>, facing yaw: Float) -> Occluder? {
        guard let arView else { return nil }

        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(position, 1)
        let anchor = ARAnchor(name: "occluder", transform: transform)
        arView.session.add(anchor: anchor)

        let anchorEntity = AnchorEntity(anchor: anchor)
        arView.scene.addAnchor(anchorEntity)

        // Depth only, no colour: the room shows through, the car does not.
        let shell = ModelEntity(mesh: unitBox, materials: [OcclusionMaterial()])

        let box = Occluder(anchor: anchor, anchorEntity: anchorEntity, shell: shell)
        box.yaw = yaw

        box.body.addChild(shell)
        box.body.addChild(box.outline)
        anchorEntity.addChild(box.body)

        box.edges = (0..<12).map { _ in
            let bar = ModelEntity(mesh: unitBox, materials: [Self.edgeMaterial(isSelected: false)])
            box.outline.addChild(bar)
            return bar
        }

        boxes.append(box)
        selectedID = box.id
        layout(box)
        refreshOutlines()
        onChange?()
        return box
    }

    func select(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id
        refreshOutlines()
        onChange?()
    }

    /// The box nearest a tap, or `nil` when the tap missed everything.
    ///
    /// Screen projection rather than a collision raycast, so the scene stays
    /// free of collision shapes — see the note on this type.
    func box(near point: CGPoint, within radius: CGFloat = 90) -> Occluder? {
        guard let arView else { return nil }
        var best: (box: Occluder, distance: CGFloat)?
        for box in boxes {
            let centre = box.body.position(relativeTo: nil)
            guard let projected = arView.project(centre) else { continue }
            let distance = hypot(projected.x - point.x, projected.y - point.y)
            guard distance <= radius else { continue }
            if best == nil || distance < best!.distance { best = (box, distance) }
        }
        return best?.box
    }

    func deleteSelected() {
        guard let box = selected else { return }
        remove(box)
        selectedID = boxes.last?.id
        refreshOutlines()
        onChange?()
    }

    /// Clears every box the player put down.
    func removeAll() {
        for box in boxes { remove(box) }
        boxes.removeAll()
        selectedID = nil
        onChange?()
    }

    private func remove(_ box: Occluder) {
        arView?.session.remove(anchor: box.anchor)
        arView?.scene.removeAnchor(box.anchorEntity)
        boxes.removeAll { $0 === box }
    }

    // MARK: - Editing

    func setValue(_ value: Float, for dimension: OccluderDimension) {
        guard let box = selected else { return }
        box.setValue(value, for: dimension)
        layout(box)
        onChange?()
    }

    /// Slides the selected box across the floor while a finger is down.
    ///
    /// The box keeps its existing anchor during the drag and is given a local
    /// offset, so nothing churns through ARKit sixty times a second; it is
    /// re-anchored once, at the end.
    func dragSelected(to position: SIMD3<Float>) {
        guard let box = selected else { return }
        let anchorOrigin = box.anchorEntity.position(relativeTo: nil)
        let offset = position - anchorOrigin
        box.body.position = SIMD3(offset.x, offset.y + box.lift + box.size.y / 2, offset.z)
    }

    /// Re-anchors the selected box where the drag left it.
    func endDrag() {
        guard let arView, let box = selected else { return }
        let resting = box.body.position(relativeTo: nil)
        let floor = SIMD3(resting.x, resting.y - box.lift - box.size.y / 2, resting.z)

        arView.session.remove(anchor: box.anchor)
        arView.scene.removeAnchor(box.anchorEntity)

        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(floor, 1)
        let anchor = ARAnchor(name: "occluder", transform: transform)
        arView.session.add(anchor: anchor)
        let anchorEntity = AnchorEntity(anchor: anchor)
        arView.scene.addAnchor(anchorEntity)
        anchorEntity.addChild(box.body)

        box.anchor = anchor
        box.anchorEntity = anchorEntity
        layout(box)
    }

    // MARK: - Geometry

    /// Pushes a box's numbers into its entities. Transforms only — the meshes
    /// are shared and never rebuilt.
    private func layout(_ box: Occluder) {
        box.body.position = SIMD3(0, box.lift + box.size.y / 2, 0)
        box.body.orientation = simd_quatf(angle: box.yaw, axis: SIMD3(0, 1, 0))
        box.shell.scale = box.size

        let half = box.size / 2
        let t = edgeThickness
        // Twelve bars on the twelve edges. Each is scaled in world units rather
        // than inheriting the box's scale, so a wide flat panel's outline stays
        // as thin as a cube's instead of smearing out with it.
        var index = 0
        for y in [-half.y, half.y] {
            for z in [-half.z, half.z] {
                place(box.edges[index], at: SIMD3(0, y, z), scale: SIMD3(box.size.x + t, t, t))
                index += 1
            }
        }
        for x in [-half.x, half.x] {
            for z in [-half.z, half.z] {
                place(box.edges[index], at: SIMD3(x, 0, z), scale: SIMD3(t, box.size.y + t, t))
                index += 1
            }
        }
        for x in [-half.x, half.x] {
            for y in [-half.y, half.y] {
                place(box.edges[index], at: SIMD3(x, y, 0), scale: SIMD3(t, t, box.size.z + t))
                index += 1
            }
        }
    }

    private func place(_ bar: ModelEntity, at position: SIMD3<Float>, scale: SIMD3<Float>) {
        bar.position = position
        bar.scale = scale
    }

    private func refreshOutlines() {
        let visible = isEditing && !isCapturing
        for box in boxes {
            box.outline.isEnabled = visible
            let material = Self.edgeMaterial(isSelected: box.id == selectedID)
            for bar in box.edges { bar.model?.materials = [material] }
        }
    }

    private static func edgeMaterial(isSelected: Bool) -> UnlitMaterial {
        UnlitMaterial(color: isSelected
                      ? UIColor(red: 1.0, green: 0.78, blue: 0.22, alpha: 1)
                      : UIColor(red: 0.36, green: 0.82, blue: 1.0, alpha: 1))
    }
}
