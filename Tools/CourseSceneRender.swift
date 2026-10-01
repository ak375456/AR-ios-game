import AppKit
import Foundation
import Metal
import RealityKit

// Renders the course props exactly as the app builds them — through
// PropFactory, at in-game size — next to a real car scaled the way CarRig
// scales it, so proportions, materials and winding can be judged together.
//
//   xcrun swiftc -parse-as-library -O -o /tmp/coursescene \
//     vr/Support/AppLog.swift vr/Course/CourseSpec.swift vr/Course/CourseGeometry.swift \
//     vr/Course/BarrierMesh.swift vr/Course/PropFactory.swift Tools/CourseSceneRender.swift
//   /tmp/coursescene out.png vr/Resources/TrafficCone.usdz vr/Resources/Tyre.usdz \
//     vr/Resources/HotHatch.usdz 0.40 [portrait]

@main @MainActor
struct CourseSceneRender {

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 6 else {
            print("usage: coursescene <out.png> <cone.usdz> <tyre.usdz> <car.usdz> <car length> [portrait]"); exit(2)
        }
        let output = URL(fileURLWithPath: args[1])
        let factory = PropFactory.shared
        await factory.prepare(coneURL: URL(fileURLWithPath: args[2]), tyreURL: URL(fileURLWithPath: args[3]))
        print("sources: \(factory.sources)")

        let carLength = Float(args[5]) ?? 0.42
        let car = try await Entity(contentsOf: URL(fileURLWithPath: args[4]))
        let bounds = car.visualBounds(relativeTo: car)
        let scale = carLength / bounds.extents.z
        car.scale = SIMD3(repeating: scale)
        car.position = SIMD3(-bounds.center.x, -bounds.min.y, -bounds.center.z) * scale
        let carRoot = Entity()
        carRoot.addChild(car)
        carRoot.orientation = simd_quatf(angle: 0.5, axis: SIMD3(0, 1, 0))
        let carBox = carRoot.visualBounds(relativeTo: nil)
        print(String(format: "car %.3f long, %.3f wide, %.3f tall", carLength, bounds.extents.x * scale, bounds.extents.y * scale))

        let scene = Entity()
        scene.addChild(carRoot)
        _ = carBox

        // A few cones in a line, one knocked over, and a short wall.
        for (i, x) in [Float(-0.25), 0.05, 0.35].enumerated() {
            let cone = factory.makeProp(.cone)
            cone.position = SIMD3(x, 0, 0.42 + Float(i) * 0.05)
            scene.addChild(cone)
        }
        let tipped = factory.makeProp(.cone)
        tipped.position = SIMD3(0.28, CourseSpec.Cone.footprintRadius * 0.9, 0.12)
        tipped.orientation = simd_quatf(angle: -1.2, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: 0.7, axis: SIMD3(0, 1, 0))
        scene.addChild(tipped)
        for i in 0..<2 {
            let barrier = factory.makeProp(.barrier)
            barrier.position = SIMD3(-0.32 + Float(i) * (CourseSpec.Barrier.length + 0.004), 0, -0.3)
            scene.addChild(barrier)
        }
        // Three tyres shoulder to shoulder, as Copy lays them, and one alone.
        for i in 0..<3 {
            let tyre = factory.makeProp(.tyre)
            tyre.position = SIMD3(0.42, 0, 0.05 + Float(i) * (CourseSpec.Tyre.diameter + 0.004))
            scene.addChild(tyre)
        }
        let loneTyre = factory.makeProp(.tyre)
        loneTyre.position = SIMD3(-0.34, 0, 0.3)
        scene.addChild(loneTyre)
        let tyreGhost = factory.makeGhost(.tyre)
        PropFactory.tintGhost(tyreGhost, valid: true)
        tyreGhost.position = SIMD3(-0.2, 0, 0.36)
        scene.addChild(tyreGhost)

        let ghost = factory.makeGhost(.barrier)
        PropFactory.tintGhost(ghost, valid: true)
        ghost.position = SIMD3(0.28, 0, -0.34)
        scene.addChild(ghost)
        let bad = factory.makeGhost(.cone)
        PropFactory.tintGhost(bad, valid: false)
        bad.position = SIMD3(-0.1, 0, 0.1)
        scene.addChild(bad)
        let selected = factory.makeOutline(.cone, colour: PropFactory.selectionColour, opacity: 1)
        selected.position = SIMD3(0.05, 0.0015, 0.47)
        scene.addChild(selected)
        let start = factory.makeStartMarker(halfExtents: SIMD2(0.087, 0.204))
        start.orientation = carRoot.orientation
        scene.addChild(start)

        // A floor so contact and scale read properly.
        let floor = ModelEntity(mesh: .generatePlane(width: 2, depth: 2),
                                materials: [SimpleMaterial(color: .init(white: 0.62, alpha: 1), roughness: 0.9, isMetallic: false)])
        scene.addChild(floor)

        let views: [(SIMD3<Float>, SIMD3<Float>, Float)] = [
            (SIMD3(0.55, 0.42, 1.05), SIMD3(0.02, 0.02, 0.05), 38),
            (SIMD3(-0.05, 0.10, 0.9), SIMD3(0.02, 0.03, 0.3), 30),
            (SIMD3(-0.62, 0.11, -0.12), SIMD3(-0.36, 0.03, -0.3), 34),
            // The tyres beside the car, to judge them against its own wheels.
            (SIMD3(0.95, 0.12, 0.05), SIMD3(0.15, 0.04, 0.1), 32),
        ]
        // `portrait` renders one phone-shaped frame, as the camera would see
        // the course while driving, instead of the comparison sheet.
        let portrait = args.count >= 7 && args[6] == "portrait"
        let tile = 560
        let sheet: NSImage
        if portrait {
            sheet = NSImage(size: NSSize(width: 786, height: 1704))
            sheet.lockFocus()
            let image = try await render(scene.clone(recursive: true), eye: SIMD3(0.05, 0.62, 1.05),
                                         target: SIMD3(0.0, 0.0, 0.08), fov: 58, width: 786, height: 1704)
            image.draw(in: NSRect(x: 0, y: 0, width: 786, height: 1704))
        } else {
            sheet = NSImage(size: NSSize(width: tile * views.count, height: tile))
            sheet.lockFocus()
            for (i, view) in views.enumerated() {
                let image = try await render(scene.clone(recursive: true), eye: view.0, target: view.1, fov: view.2,
                                             width: tile, height: tile)
                image.draw(in: NSRect(x: i * tile, y: 0, width: tile, height: tile))
            }
        }
        sheet.unlockFocus()
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: output)
        print("wrote \(output.path)")
    }

    static func render(_ scene: Entity, eye: SIMD3<Float>, target: SIMD3<Float>, fov: Float,
                       width: Int, height: Int) async throws -> NSImage {
        let renderer = try RealityRenderer()
        renderer.entities.append(scene)
        let key = DirectionalLight(); key.light.intensity = 4200
        key.look(at: .zero, from: SIMD3(0.8, 2.0, 1.2), relativeTo: nil)
        let fill = DirectionalLight(); fill.light.intensity = 1600
        fill.look(at: .zero, from: SIMD3(-1.4, 0.8, -0.6), relativeTo: nil)
        renderer.entities.append(contentsOf: [key, fill])
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = fov
        camera.camera.near = 0.01
        camera.look(at: target, from: eye, relativeTo: nil)
        renderer.entities.append(camera)
        renderer.activeCamera = camera

        let device = MTLCreateSystemDefaultDevice()!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime: 1 / 60, cameraOutput: output, onComplete: { _ in c.resume() }) }
            catch { c.resume(throwing: error) }
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Float(bytes[i + 3]) / 255, bg = 0.85 * 255 * (1 - a)
            let b = Float(bytes[i]), g = Float(bytes[i + 1]), r = Float(bytes[i + 2])
            bytes[i] = UInt8(min(r + bg, 255)); bytes[i + 1] = UInt8(min(g + bg, 255))
            bytes[i + 2] = UInt8(min(b + bg, 255)); bytes[i + 3] = 255
        }
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                         shouldInterpolate: false, intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
