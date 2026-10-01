import AppKit
import Foundation
import RealityKit

// Runs the course props through RealityKit's own physics (PhysX), built by
// the app's PropFactory exactly as on the phone, and checks the things only a
// 3D solver can get wrong: props that fall over untouched, props that twitch
// on the floor for ever, and props that sink into it or pass through a barrier.
//
// The impulses are the ones CourseContacts hands over for a car hitting a prop
// at a range of speeds, applied where CourseBuilder applies them: at bumper
// height for a cone, through the middle for a tyre.
//
//   xcrun swiftc -parse-as-library -O -o /tmp/propphysics \
//     vr/Support/AppLog.swift vr/Course/CourseSpec.swift vr/Course/CourseGeometry.swift \
//     vr/Course/BarrierMesh.swift vr/Course/PropFactory.swift Tools/PropPhysicsCheck.swift
//   /tmp/propphysics vr/Resources/TrafficCone.usdz vr/Resources/Tyre.usdz [settled.png]

@main @MainActor
struct PropPhysicsCheck {

    static var failures = 0
    static func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
        if !ok { failures += 1 }
    }

    /// A course root with the invisible floor, as CourseBuilder builds it.
    static func makeWorld() -> Entity {
        let root = Entity()
        root.components.set(PhysicsSimulationComponent())
        root.addChild(PropFactory.shared.makeGround())
        return root
    }

    static func cone(at position: SIMD3<Float>, in root: Entity) -> ModelEntity {
        prop(.cone, at: position, in: root)
    }

    static func prop(_ kind: PropKind, at position: SIMD3<Float>, in root: Entity) -> ModelEntity {
        let prop = PropFactory.shared.makeProp(kind)
        prop.position = position
        root.addChild(prop)
        PropFactory.setFree(prop, true)
        return prop
    }

    struct Sample {
        var position: SIMD3<Float>
        var up: SIMD3<Float>
        var speed: Float
        var spin: Float
    }

    static func sample(_ cone: ModelEntity) -> Sample {
        let motion = cone.components[PhysicsMotionComponent.self] ?? PhysicsMotionComponent()
        return Sample(position: cone.position, up: cone.orientation.act(SIMD3(0, 1, 0)),
                      speed: simd_length(motion.linearVelocity), spin: simd_length(motion.angularVelocity))
    }

    /// Steps the world through RealityRenderer, which runs RealityKit's
    /// systems — physics included — for each frame it draws.
    static func run(_ root: Entity, seconds: Float, renderer: RealityRenderer, output: RealityRenderer.CameraOutput,
                    each: (Int) -> Void = { _ in }) async throws {
        let frames = Int(seconds * 60)
        for frame in 0..<frames {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                do { try renderer.updateAndRender(deltaTime: 1 / 60, cameraOutput: output, onComplete: { _ in c.resume() }) }
                catch { c.resume(throwing: error) }
            }
            each(frame)
        }
    }

    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else {
            print("usage: propphysics <TrafficCone.usdz> <Tyre.usdz> [settled.png]"); exit(2)
        }
        await PropFactory.shared.prepare(coneURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                                         tyreURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("sources: cone \(PropFactory.shared.sources[.cone].map { "\($0)" } ?? "none"), "
              + "tyre \(PropFactory.shared.sources[.tyre].map { "\($0)" } ?? "none")")

        let device = MTLCreateSystemDefaultDevice()!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = device.makeTexture(descriptor: descriptor)!
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))

        func freshRenderer(_ root: Entity) throws -> RealityRenderer {
            let renderer = try RealityRenderer()
            renderer.entities.append(root)
            let camera = PerspectiveCamera()
            camera.look(at: .zero, from: SIMD3(0.5, 0.5, 0.5), relativeTo: nil)
            renderer.entities.append(camera)
            renderer.activeCamera = camera
            return renderer
        }

        // 0. Does this renderer step physics at all? A cone dropped from 5 cm
        //    must land; if it hangs in the air nothing below means anything.
        do {
            let root = makeWorld()
            let probe = cone(at: SIMD3(0, 0.05, 0), in: root)
            let renderer = try freshRenderer(root)
            try await run(root, seconds: 1, renderer: renderer, output: output)
            let landed = probe.position.y < 0.01
            check("physics runs headless", landed, String(format: "dropped cone now at y = %.4f m", probe.position.y))
            if !landed { print("RealityRenderer does not simulate physics here; nothing further to check."); exit(3) }
        }

        // 1. Twelve cones stood on the floor and left alone for ten seconds.
        do {
            let root = makeWorld()
            let cones = (0..<12).map { cone(at: SIMD3(Float($0 % 4) * 0.12, 0, Float($0 / 4) * 0.12), in: root) }
            let starts = cones.map(\.position)
            let renderer = try freshRenderer(root)
            var lateSpeed: Float = 0, worstTilt: Float = 0, worstDrift: Float = 0, lowest: Float = 0
            try await run(root, seconds: 10, renderer: renderer, output: output) { frame in
                for (cone, start) in zip(cones, starts) {
                    let s = sample(cone)
                    worstTilt = max(worstTilt, acos(min(max(s.up.y, -1), 1)) * 180 / .pi)
                    worstDrift = max(worstDrift, simd_distance(SIMD2(s.position.x, s.position.z), SIMD2(start.x, start.z)))
                    lowest = min(lowest, s.position.y)
                    if frame > 60 * 5 { lateSpeed = max(lateSpeed, s.speed + s.spin * 0.03) }
                }
            }
            check("untouched cones stay standing", worstTilt < 1 && worstDrift < 0.001,
                  String(format: "worst tilt %.2f°, worst drift %.2f mm", worstTilt, worstDrift * 1000))
            check("untouched cones rest on the floor, not in it", lowest > -0.0015,
                  String(format: "lowest base %.2f mm", lowest * 1000))
            check("untouched cones do not twitch", lateSpeed < 0.002,
                  String(format: "fastest movement after 5 s: %.4f m/s", lateSpeed))
        }

        // 2. Hit at a range of car speeds: knocked, then settled.
        var tippedAt: [Float] = []
        for carSpeed: Float in [0.2, 0.5, 1.0, 1.6, 2.3] {
            let root = makeWorld()
            let target = cone(at: .zero, in: root)
            let renderer = try freshRenderer(root)
            // What CourseContacts gives a cone in a head-on hit: its mass times
            // a closing speed a little over the car's own.
            let impulse = CourseSpec.Cone.mass * carSpeed * 1.12
            let bumper: Float = 0.154 * 0.17
            target.applyImpulse(SIMD3(0, 0, impulse), at: SIMD3(0, bumper, -CourseSpec.Cone.contactRadius), relativeTo: root)

            var lowest: Float = 0, lastMoving = 0
            var resting = 0
            try await run(root, seconds: 6, renderer: renderer, output: output) { frame in
                let s = sample(target)
                lowest = min(lowest, s.position.y)
                if s.speed > 0.01 || s.spin > 0.15 { lastMoving = frame; resting = 0 } else { resting += 1 }
            }
            let end = sample(target)
            let tipped = end.up.y < 0.7
            if tipped { tippedAt.append(carSpeed) }
            let travelled = simd_length(SIMD2(end.position.x, end.position.z))
            check(String(format: "hit at %.1f m/s: settles", carSpeed), lastMoving < 60 * 4 && resting > 60,
                  String(format: "%@, slid %.2f m, still after %.1f s", tipped ? "knocked over" : "stayed up",
                         travelled, Float(lastMoving) / 60))
            check(String(format: "hit at %.1f m/s: never sinks", carSpeed), lowest > -0.003,
                  String(format: "lowest %.1f mm", lowest * 1000))
        }
        check("gentle bumps rock, hard hits knock over",
              !tippedAt.contains(0.2) && tippedAt.contains(2.3),
              "knocked over at " + tippedAt.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " m/s")

        // 3. A cone sent at a barrier bounces off it rather than through it.
        do {
            let root = makeWorld()
            let barrier = PropFactory.shared.makeProp(.barrier)
            barrier.position = SIMD3(0, 0, 0.3)
            root.addChild(barrier)
            let thrown = cone(at: .zero, in: root)
            let renderer = try freshRenderer(root)
            thrown.applyImpulse(SIMD3(0, 0, CourseSpec.Cone.mass * 3.0), at: SIMD3(0, 0.016, 0), relativeTo: root)
            var furthest: Float = 0
            try await run(root, seconds: 3, renderer: renderer, output: output) { _ in
                furthest = max(furthest, thrown.position.z)
            }
            let face = 0.3 - CourseSpec.Barrier.baseWidth / 2
            check("barrier stops a flying cone", furthest < 0.3,
                  String(format: "got to z = %.3f m (barrier face %.3f, centre 0.300)", furthest, face))
        }

        // 4. One cone knocked into another passes the knock on.
        do {
            let root = makeWorld()
            let first = cone(at: .zero, in: root)
            let second = cone(at: SIMD3(0, 0, 0.1), in: root)
            let renderer = try freshRenderer(root)
            first.applyImpulse(SIMD3(0, 0, CourseSpec.Cone.mass * 1.5), at: SIMD3(0, 0.016, 0), relativeTo: root)
            try await run(root, seconds: 3, renderer: renderer, output: output)
            let moved = simd_distance(second.position, SIMD3(0, 0, 0.1))
            check("cones knock each other on", moved > 0.01, String(format: "second cone moved %.3f m", moved))
        }

        // 5. Editing moves props by their transforms: a barrier moved while
        //    static must collide where it now is, and a cone moved while held
        //    kinematic must stay there once it is let go for driving.
        do {
            let root = makeWorld()
            let barrier = PropFactory.shared.makeProp(.barrier)
            barrier.position = SIMD3(0, 0, 0.3)
            root.addChild(barrier)
            let held = PropFactory.shared.makeProp(.cone)
            held.position = SIMD3(0.4, 0, 0)
            root.addChild(held)
            let renderer = try freshRenderer(root)
            try await run(root, seconds: 0.5, renderer: renderer, output: output)

            // The edit: the barrier across to x = 1, the cone to (0.6, 0, 0.2).
            barrier.position = SIMD3(1.0, 0, 0.3)
            held.position = SIMD3(0.6, 0, 0.2)
            held.resetPhysicsTransform(recursive: false)
            try await run(root, seconds: 0.3, renderer: renderer, output: output)
            PropFactory.setFree(held, true)
            held.resetPhysicsTransform(recursive: false)

            // One cone fired where the barrier used to be, one where it is now.
            let throughOld = cone(at: SIMD3(0, 0, 0), in: root)
            let intoNew = cone(at: SIMD3(1.0, 0, 0), in: root)
            throughOld.applyImpulse(SIMD3(0, 0, CourseSpec.Cone.mass * 2.5), at: SIMD3(0, 0.016, 0), relativeTo: root)
            intoNew.applyImpulse(SIMD3(0, 0, CourseSpec.Cone.mass * 2.5), at: SIMD3(1.0, 0.016, 0), relativeTo: root)
            var oldReach: Float = 0, newReach: Float = 0
            try await run(root, seconds: 3, renderer: renderer, output: output) { _ in
                oldReach = max(oldReach, throughOld.position.z)
                newReach = max(newReach, intoNew.position.z)
            }
            check("a moved barrier collides where it now is", oldReach > 0.35 && newReach < 0.3,
                  String(format: "cone at the old spot reached z = %.2f, at the new spot %.2f", oldReach, newReach))
            let drift = simd_distance(held.position, SIMD3(0.6, 0, 0.2))
            check("a moved cone stays put when driving starts", drift < 0.001 && held.orientation.act(SIMD3(0, 1, 0)).y > 0.999,
                  String(format: "drifted %.2f mm", drift * 1000))
        }

        // 6. Tyres left alone for ten seconds.
        do {
            let root = makeWorld()
            let tyres = (0..<8).map { prop(.tyre, at: SIMD3(Float($0 % 4) * 0.1, 0, Float($0 / 4) * 0.1), in: root) }
            let starts = tyres.map(\.position)
            let renderer = try freshRenderer(root)
            var lateSpeed: Float = 0, worstTilt: Float = 0, worstDrift: Float = 0, lowest: Float = 0
            try await run(root, seconds: 10, renderer: renderer, output: output) { frame in
                for (tyre, start) in zip(tyres, starts) {
                    let s = sample(tyre)
                    worstTilt = max(worstTilt, acos(min(max(s.up.y, -1), 1)) * 180 / .pi)
                    worstDrift = max(worstDrift, simd_distance(SIMD2(s.position.x, s.position.z), SIMD2(start.x, start.z)))
                    lowest = min(lowest, s.position.y)
                    if frame > 60 * 5 { lateSpeed = max(lateSpeed, s.speed + s.spin * 0.03) }
                }
            }
            check("untouched tyres lie still", worstTilt < 1 && worstDrift < 0.001 && lateSpeed < 0.002,
                  String(format: "worst tilt %.2f°, drift %.2f mm, fastest after 5 s %.4f m/s",
                         worstTilt, worstDrift * 1000, lateSpeed))
            check("untouched tyres rest on the floor, not in it", lowest > -0.0015,
                  String(format: "lowest %.2f mm", lowest * 1000))
        }

        // 7. Tyres hit at a range of car speeds, through the middle and a
        //    little off it: they skid and spin, and come to rest lying flat.
        for carSpeed: Float in [0.3, 0.8, 1.5, 2.3] {
            let root = makeWorld()
            let target = prop(.tyre, at: .zero, in: root)
            let renderer = try freshRenderer(root)
            let impulse = CourseSpec.Tyre.mass * carSpeed * 1.1
            let height = CourseSpec.Tyre.height / 2 + 0.002
            target.applyImpulse(SIMD3(0.15 * impulse, 0, impulse),
                                at: SIMD3(0.012, height, -CourseSpec.Tyre.contactRadius), relativeTo: root)
            var lowest: Float = 0, lastMoving = 0, turned: Float = 0
            try await run(root, seconds: 6, renderer: renderer, output: output) { frame in
                let s = sample(target)
                lowest = min(lowest, s.position.y)
                turned = max(turned, s.spin)
                if s.speed > 0.01 || s.spin > 0.15 { lastMoving = frame }
            }
            let end = sample(target)
            let flat = end.up.y > 0.97
            let travelled = simd_length(SIMD2(end.position.x, end.position.z))
            check(String(format: "tyre hit at %.1f m/s: skids, spins and settles flat", carSpeed),
                  flat && lastMoving < 60 * 4 && lowest > -0.003,
                  String(format: "slid %.2f m, spun up to %.1f rad/s, still after %.1f s, %@, lowest %.1f mm",
                         travelled, turned, Float(lastMoving) / 60, flat ? "flat" : "NOT flat", lowest * 1000))
        }

        // 8. A tyre sent at a barrier stops at it; a cone knocked into a tyre
        //    moves it a little.
        do {
            let root = makeWorld()
            let barrier = PropFactory.shared.makeProp(.barrier)
            barrier.position = SIMD3(0, 0, 0.3)
            root.addChild(barrier)
            let thrown = prop(.tyre, at: .zero, in: root)
            let struck = prop(.tyre, at: SIMD3(0.5, 0, 0.12), in: root)
            let bullet = cone(at: SIMD3(0.5, 0, 0), in: root)
            let renderer = try freshRenderer(root)
            thrown.applyImpulse(SIMD3(0, 0, CourseSpec.Tyre.mass * 3.0),
                                at: SIMD3(0, CourseSpec.Tyre.height / 2, 0), relativeTo: root)
            bullet.applyImpulse(SIMD3(0, 0, CourseSpec.Cone.mass * 2.0), at: SIMD3(0.5, 0.016, 0), relativeTo: root)
            var furthest: Float = 0
            try await run(root, seconds: 3, renderer: renderer, output: output) { _ in
                furthest = max(furthest, thrown.position.z)
            }
            check("barrier stops a sliding tyre", furthest < 0.3 - CourseSpec.Barrier.baseWidth / 2,
                  String(format: "tyre got to z = %.3f m (barrier face %.3f)", furthest, 0.3 - CourseSpec.Barrier.baseWidth / 2))
            let moved = simd_distance(struck.position, SIMD3(0.5, 0, 0.12))
            check("a flying cone nudges a tyre", moved > 0.002 && sample(struck).up.y > 0.97,
                  String(format: "tyre moved %.1f mm and stayed flat", moved * 1000))
        }

        // 9. Optionally, a picture of a row of cones and tyres after being hit
        //    at increasing speeds, to see how knocked props come to rest.
        if CommandLine.arguments.count >= 4 {
            let root = makeWorld()
            let floor = ModelEntity(mesh: .generatePlane(width: 3, depth: 3),
                                    materials: [SimpleMaterial(color: .init(white: 0.6, alpha: 1), roughness: 0.9, isMetallic: false)])
            root.addChild(floor)
            let barrier = PropFactory.shared.makeProp(.barrier)
            barrier.position = SIMD3(0.28, 0, 0.62)
            root.addChild(barrier)
            let speeds: [Float] = [0.3, 0.8, 1.3, 1.8, 2.3]
            let cones = speeds.enumerated().map { cone(at: SIMD3(Float($0.offset) * 0.14, 0, 0), in: root) }
            let tyres = speeds.enumerated().map { prop(.tyre, at: SIMD3(Float($0.offset) * 0.14, 0, -0.2), in: root) }
            let renderer = try freshRenderer(root)
            for (cone, speed) in zip(cones, speeds) {
                cone.applyImpulse(SIMD3(0.02 * speed, 0, CourseSpec.Cone.mass * speed * 1.12),
                                  at: cone.position + SIMD3(0.004, 0.026, -0.021), relativeTo: root)
            }
            for (tyre, speed) in zip(tyres, speeds) {
                tyre.applyImpulse(SIMD3(0.1 * speed * CourseSpec.Tyre.mass, 0, CourseSpec.Tyre.mass * speed * 1.1),
                                  at: tyre.position + SIMD3(0.012, 0.012, -0.03), relativeTo: root)
            }
            try await run(root, seconds: 4, renderer: renderer, output: output)
            for (cone, speed) in zip(cones, speeds) {
                let s = sample(cone)
                print(String(format: "  %.1f m/s: at (%.3f, %.3f, %.3f), up.y %.2f", speed, s.position.x, s.position.y, s.position.z, s.up.y))
            }
            let big = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 900, height: 560, mipmapped: false)
            big.usage = [.renderTarget, .shaderRead]; big.storageMode = .shared
            let shot = device.makeTexture(descriptor: big)!
            let light = DirectionalLight(); light.light.intensity = 4000
            light.look(at: .zero, from: SIMD3(-0.8, 1.6, -0.6), relativeTo: nil)
            renderer.entities.append(light)
            let camera = PerspectiveCamera(); camera.camera.fieldOfViewInDegrees = 42
            camera.look(at: SIMD3(0.3, 0, 0.3), from: SIMD3(-0.25, 0.42, -0.35), relativeTo: nil)
            renderer.entities.append(camera); renderer.activeCamera = camera
            let out = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: shot))
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                do { try renderer.updateAndRender(deltaTime: 1 / 60, cameraOutput: out, onComplete: { _ in c.resume() }) }
                catch { c.resume(throwing: error) }
            }
            var bytes = [UInt8](repeating: 0, count: 900 * 560 * 4)
            shot.getBytes(&bytes, bytesPerRow: 900 * 4, from: MTLRegionMake2D(0, 0, 900, 560), mipmapLevel: 0)
            for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2); bytes[i + 3] = 255 }
            let cg = CGImage(width: 900, height: 560, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 900 * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                             provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                             shouldInterpolate: false, intent: .defaultIntent)!
            let rep = NSBitmapImageRep(cgImage: cg)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            print("wrote \(CommandLine.arguments[3])")
        }

        print(failures == 0 ? "\nAll prop physics checks passed." : "\n\(failures) prop physics check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
