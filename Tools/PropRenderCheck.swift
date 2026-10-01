import AppKit
import Foundation
import Metal
import RealityKit

// Renders USDZ props through RealityKit itself — the renderer the app uses,
// with its own back-face culling and material binding — rather than trusting
// SceneKit or Quick Look to behave the same way. Each file is drawn upright
// from the side and then knocked over and seen from below, which is the view
// that exposes inside-out or missing faces on a cone.
//
//   xcrun swiftc -parse-as-library -O -o /tmp/proprender Tools/PropRenderCheck.swift
//   /tmp/proprender out.png vr/Resources/TrafficCone.usdz ~/Downloads/Low_Poly_Traffic_Cone.usdz
//
// Also prints each file's measured size and how many of its model components
// arrived with a material RealityKit could use.

@main @MainActor
struct PropRenderCheck {

    static let tile = 360

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            print("usage: proprender <out.png> <model.usdz>...")
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[1])
        let files = arguments.dropFirst(2).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
        let sheet = NSImage(size: NSSize(width: tile * 2, height: (tile + 28) * files.count))
        sheet.lockFocus()
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()

        for (row, url) in files.enumerated() {
            let entity = try await Entity(contentsOf: url)
            let bounds = entity.visualBounds(relativeTo: nil)
            report(url: url, entity: entity, bounds: bounds)

            for (column, tipped) in [false, true].enumerated() {
                let image = try await render(entity.clone(recursive: true), bounds: bounds,
                                             tipped: tipped, device: device)
                let y = CGFloat((files.count - 1 - row) * (tile + 28))
                image.draw(in: NSRect(x: CGFloat(column * tile), y: y + 28, width: CGFloat(tile), height: CGFloat(tile)))
                let label = "\(url.lastPathComponent) — \(tipped ? "knocked over, from below" : "upright")"
                (label as NSString).draw(at: NSPoint(x: CGFloat(column * tile) + 8, y: y + 7),
                                         withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            }
        }
        sheet.unlockFocus()
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: output)
        print("wrote \(output.path)")
    }

    static func report(url: URL, entity: Entity, bounds: BoundingBox) {
        var models = 0, withMaterials = 0
        func visit(_ e: Entity) {
            if let model = e.components[ModelComponent.self] {
                models += 1
                if !model.materials.isEmpty { withMaterials += 1 }
            }
            e.children.forEach(visit)
        }
        visit(entity)
        let e = bounds.extents
        print(String(format: "%@: %.3f x %.3f x %.3f (w x h x d, scene units), base at y = %.4f, %d/%d parts with materials",
                     url.lastPathComponent, e.x, e.y, e.z, bounds.min.y, withMaterials, models))
    }

    static func render(_ entity: Entity, bounds: BoundingBox, tipped: Bool, device: MTLDevice) async throws -> NSImage {
        let renderer = try RealityRenderer()

        // Normalise whatever units the file uses so every tile is framed alike.
        let holder = Entity()
        let size = max(bounds.extents.max(), 1e-5)
        holder.scale = SIMD3(repeating: 1 / size)
        entity.position = -bounds.center
        holder.addChild(entity)
        if tipped {
            // Base turned towards the camera, tip away from it.
            holder.orientation = simd_quatf(angle: -(.pi / 2 + 0.35), axis: SIMD3(1, 0, 0))
        }
        renderer.entities.append(holder)

        let key = DirectionalLight()
        key.light.intensity = 5200
        key.look(at: .zero, from: SIMD3(1.2, 2.0, 1.6), relativeTo: nil)
        let fill = DirectionalLight()
        fill.light.intensity = 1800
        fill.look(at: .zero, from: SIMD3(-1.6, 0.4, -0.8), relativeTo: nil)
        let under = DirectionalLight()
        under.light.intensity = 2600
        under.look(at: .zero, from: SIMD3(0.4, -1.5, 1.4), relativeTo: nil)
        renderer.entities.append(contentsOf: [key, fill, under])

        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 34
        let eye: SIMD3<Float> = tipped ? SIMD3(0.35, -1.1, 1.75) : SIMD3(1.3, 0.55, 1.5)
        camera.look(at: .zero, from: eye, relativeTo: nil)
        renderer.entities.append(camera)
        renderer.activeCamera = camera

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: tile, height: tile, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { fatalError("texture") }

        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: output, onComplete: { _ in
                    continuation.resume()
                })
            } catch {
                continuation.resume(throwing: error)
            }
        }
        return image(from: texture)
    }

    static func image(from texture: MTLTexture) -> NSImage {
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // BGRA over a light background, so a transparent (missing) face reads
        // as a hole rather than as black.
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Float(bytes[i + 3]) / 255
            let bg: Float = 0.93 * 255 * (1 - a)
            let b = Float(bytes[i]), g = Float(bytes[i + 1]), r = Float(bytes[i + 2])
            bytes[i] = UInt8(min(r + bg, 255)); bytes[i + 1] = UInt8(min(g + bg, 255))
            bytes[i + 2] = UInt8(min(b + bg, 255)); bytes[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
