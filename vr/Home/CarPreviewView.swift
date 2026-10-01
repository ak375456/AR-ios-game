//
//  CarPreviewView.swift
//  vr
//
//  The turntable in the garage.
//

import OSLog
import SceneKit
import SwiftUI
import UIKit

/// How far along the preview is, so the garage can say something useful while
/// a model loads and can cope when one will not load at all.
enum CarPreviewStatus: Equatable {
    case loading, ready, failed
}

/// A slowly rotating 3D view of the selected car, in the selected colour.
///
/// SceneKit rather than RealityKit: this is an ordinary offline 3D view with no
/// camera feed behind it, and SceneKit gives direct control of the lights and
/// the turntable without an AR session. The AR part of the app stays RealityKit.
///
/// The view is transparent and casts a real contact shadow onto a shadow-only
/// floor, so the painted pit bay behind it
/// — is drawn once in SwiftUI rather than rebuilt in 3D for every car.
struct CarPreviewView: UIViewRepresentable {

    let car: CarDefinition
    let paint: CarPaint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onStatusChange: (CarPreviewStatus) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 60
        view.isUserInteractionEnabled = false
        view.rendersContinuously = true
        view.scene = context.coordinator.scene
        // SCNView does not pick a camera on its own, and without `isPlaying`
        // it renders a single frame and never runs the turntable action.
        view.pointOfView = context.coordinator.camera
        view.isPlaying = !reduceMotion
        context.coordinator.onStatusChange = onStatusChange
        context.coordinator.show(car: car, paint: paint)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.onStatusChange = onStatusChange
        context.coordinator.show(car: car, paint: paint)
        uiView.isPlaying = !reduceMotion
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        // Stop the render loop and let the scene go, so browsing in and out of
        // the garage cannot leave turntables running behind the AR view.
        uiView.isPlaying = false
        uiView.rendersContinuously = false
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {

        let scene = SCNScene()
        let camera = SCNNode()
        var onStatusChange: ((CarPreviewStatus) -> Void)?

        private let turntable = SCNNode()
        private var loadedCarID: String?
        private var appliedPaintID: String?
        private var carNode: SCNNode?

        /// Bumped on every request, so a slow load for a car the player has
        /// already scrolled past is dropped instead of appearing late.
        private var generation = 0

        init() {
            scene.rootNode.addChildNode(turntable)
            turntable.runAction(.repeatForever(
                .rotateBy(x: 0, y: .pi * 2, z: 0, duration: 22)
            ))

            // Three directional lights plus a little ambient: enough to read the
            // shape from any angle as the car turns, with no environment map.
            // The key light is the only one that casts, so the car gets a single
            // soft shadow rather than three crossing ones.
            for (direction, intensity, casts) in [(SCNVector3(2, 3, 2), 780.0, true),
                                                  (SCNVector3(-2.5, 1.5, -1.5), 620.0, false),
                                                  (SCNVector3(0, 0.6, -3), 520.0, false)] {
                let node = SCNNode()
                let light = SCNLight()
                light.type = .directional
                light.intensity = CGFloat(intensity)
                if casts {
                    light.castsShadow = true
                    // Forward rather than deferred: deferred shadows are a
                    // screen-space pass and do not land on a shadow-only
                    // material, which is what keeps the backdrop showing
                    // through everywhere the shadow is not.
                    light.shadowMode = .forward
                    light.shadowRadius = 9
                    light.shadowSampleCount = 16
                    light.shadowColor = UIColor.black.withAlphaComponent(0.55)
                    light.orthographicScale = 1.1
                    light.zNear = 0.1
                    light.zFar = 20
                }
                node.light = light
                node.position = direction
                scene.rootNode.addChildNode(node)
                node.look(at: SCNVector3Zero)
            }
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 380
            scene.rootNode.addChildNode(ambient)


            // Catches the key light's shadow and draws nothing else, so the
            // studio behind the view shows through everywhere else.
            let floor = SCNNode(geometry: SCNPlane(width: 6, height: 6))
            floor.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
            floor.castsShadow = false
            floor.geometry?.firstMaterial?.lightingModel = .shadowOnly
            floor.geometry?.firstMaterial?.isDoubleSided = true
            floor.geometry?.firstMaterial?.writesToDepthBuffer = false
            scene.rootNode.addChildNode(floor)

            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 30
            camera.camera?.zNear = 0.01
            camera.camera?.zFar = 40
            camera.position = SCNVector3(1.22, 0.67, 1.60)
            scene.rootNode.addChildNode(camera)
            camera.look(at: SCNVector3(0, 0.14, 0))
        }

        /// One still render, released immediately. Collection never owns live SCNViews.
        static func thumbnail(car: CarDefinition) -> UIImage? {
            guard let url = Bundle.main.url(forResource: car.assetName, withExtension: "usdz"),
                  let model = try? SCNScene(url: url).rootNode.childNodes.first else { return nil }
            let coordinator = Coordinator()
            coordinator.turntable.removeAllActions()
            model.removeFromParentNode()
            let framed = coordinator.framed(model)
            framed.eulerAngles.y = -.pi * 0.03
            coordinator.swap(to: framed)
            let renderer = SCNRenderer(device: nil, options: nil)
            renderer.scene = coordinator.scene; renderer.pointOfView = coordinator.camera
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 360, height: 260), antialiasingMode: .multisampling2X)
            coordinator.tearDown()
            return image
        }

        func tearDown() {
            generation += 1
            carNode?.removeFromParentNode()
            carNode = nil
            turntable.removeAllActions()
            onStatusChange = nil
        }

        func show(car: CarDefinition, paint: CarPaint) {
            if loadedCarID != car.id || (paint.id == "factory" && appliedPaintID != "factory") {
                loadedCarID = car.id
                appliedPaintID = nil
                load(car, paint: paint)
                return
            }
            if appliedPaintID != paint.id {
                repaint(car: car, paint: paint)
                appliedPaintID = paint.id
            }
        }

        /// Reports asynchronously: this runs from `updateUIView`, and changing
        /// a SwiftUI `@State` in the middle of a view update is not allowed.
        private func report(_ status: CarPreviewStatus) {
            let callback = onStatusChange
            Task { @MainActor in callback?(status) }
        }

        private func load(_ car: CarDefinition, paint: CarPaint) {
            generation += 1
            let token = generation
            report(.loading)

            guard let url = Bundle.main.url(forResource: car.assetName, withExtension: "usdz") else {
                AppLog.asset.error("Preview: \(car.assetName, privacy: .public).usdz is not in the bundle")
                swap(to: nil)
                report(.failed)
                return
            }

            // Parsed on the main actor after a yield, which gives the previous
            // car one more frame and lets a spinner appear if the parse is
            // slow. The parse deliberately does not move to a background
            // thread: SceneKit geometry parsed off the main thread reports the
            // right bounds but draws nothing once it is parented into a scene
            // built on the main thread, which is exactly how the garage ended
            // up showing an empty stage. These models are small enough that
            // the pause is a frame or two.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, token == self.generation else { return }

                let model: SCNNode?
                do {
                    model = try SCNScene(url: url, options: nil).rootNode.childNodes.first
                    if model == nil {
                        AppLog.asset.error("Preview: \(car.assetName, privacy: .public) has no content")
                    }
                } catch {
                    AppLog.asset.error("Preview: \(car.assetName, privacy: .public) failed to load — \(error.localizedDescription, privacy: .public)")
                    model = nil
                }

                guard token == self.generation else { return }
                guard let model else {
                    self.swap(to: nil)
                    self.report(.failed)
                    return
                }

                model.removeFromParentNode()
                self.swap(to: self.framed(model))
                self.repaint(car: car, paint: paint)
                self.appliedPaintID = paint.id
                self.report(.ready)
            }
        }

        /// Puts the new car in and takes the old one out together, so the
        /// stage is never briefly empty and two cars can never overlap.
        private func swap(to node: SCNNode?) {
            if let outgoing = carNode {
                outgoing.removeFromParentNode()
                // Detaching the node is not enough: SceneKit holds the
                // geometry, its materials and their uploaded textures until
                // the references are dropped, so browsing the garage grew by
                // a few megabytes per car and never gave any of it back —
                // even for cars that had been shown before.
                outgoing.enumerateHierarchy { child, _ in
                    child.geometry?.materials = []
                    child.geometry = nil
                }
            }
            carNode = node
            if let node { turntable.addChildNode(node) }
        }

        /// Normalises the model to one unit long, centred, resting on the
        /// floor, so the camera framing works for every car regardless of its
        /// source units.
        private func framed(_ model: SCNNode) -> SCNNode {
            // The model has to be inside the holder *before* it is measured.
            // `SCNNode.boundingBox` is expressed in the node's own space and
            // does not include the node's own transform, and these cars carry a
            // corrective rotation baked onto their root prim — measuring the
            // model directly reports its pre-rotation box, which for a car
            // turned 90 degrees means scaling it by its width instead of its
            // length. That is what made the supercar burst out of its card.
            let holder = SCNNode()
            holder.addChildNode(model)

            let (lo, hi) = holder.boundingBox
            // Frame on the larger ground-plane extent so every car fills the
            // stage by a similar amount, whatever its proportions.
            let footprint = max(CGFloat(hi.z - lo.z), CGFloat(hi.x - lo.x), CGFloat(hi.y - lo.y) * 1.65)
            let scale = 1 / max(footprint, 0.0001)
            holder.scale = SCNVector3(scale, scale, scale)
            holder.position = SCNVector3(-CGFloat(lo.x + hi.x) / 2 * scale,
                                         -CGFloat(lo.y) * scale,
                                         -CGFloat(lo.z + hi.z) / 2 * scale)

            // Face the camera three-quarters on rather than straight down +Z.
            let pivot = SCNNode()
            pivot.eulerAngles = SCNVector3(0, CGFloat.pi * 0.12, 0)
            pivot.addChildNode(holder)

            return pivot
        }

        /// Mirrors `CarRig.apply(paint:)`: only prims the converter tagged as
        /// carrying the paint material are touched, and cars whose paint is a
        /// flat material get re-tinted rather than re-textured. Without the
        /// second case the garage showed a supercar in its original red while
        /// the AR view showed it in the colour the player had picked.
        private func repaint(car: CarDefinition, paint: CarPaint) {
            guard let carNode, paint.id != "factory" else { return }

            let contents: Any?
            switch car.paintSource {
            case .texture:
                contents = PaintShop.shared.uiImage(for: car, paint: paint)
            case .materialColour:
                contents = PaintShop.shared.shiftedColour(for: paint)
            case .fixed:
                return
            }
            guard let contents else { return }

            func visit(_ node: SCNNode) {
                if node.name?.lowercased().hasPrefix("paint") == true, let geometry = node.geometry {
                    // Materials are shared between prims in a loaded scene, so
                    // copy before touching one.
                    let copy = geometry.copy() as? SCNGeometry ?? geometry
                    copy.materials = copy.materials.map { material in
                        guard let duplicate = material.copy() as? SCNMaterial else { return material }
                        duplicate.diffuse.contents = contents
                        return duplicate
                    }
                    node.geometry = copy
                }
                node.childNodes.forEach(visit)
            }
            visit(carNode)
        }
    }
}
