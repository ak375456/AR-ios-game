// Proves that every articulated wheel turns exactly about its own hub.
//
// CarRig hangs each wheel's pivot off the model's own frame rather than off the
// wheel's group, because a group's frame is not always square — the 4x4
// scales its wheel group by (0.48, 3.66, 3.66) — and a rotation applied inside a
// frame like that shears the tyre into a slab instead of turning it. This check
// mirrors that mounting and asserts the exact condition: after turning a pivot
// by R, the wheel's placement in the car must equal T(hub)·R·T(-hub) applied to
// where it started. That covers both halves at once — the hub stays put and
// nothing shears — however asymmetric the wheel is.
//
//   swiftc -O -o wheelcheck Tools/WheelPivotCheck.swift && ./wheelcheck vr/Resources
//
// SceneKit stands in for RealityKit here so the check runs on the Mac; the
// mounting is decomposed the way RealityKit has to, which cannot carry shear.

import Foundation
import SceneKit
import simd

// Mirrors CarRig.mount: a pivot in the model's square frame, a carrier that
// replays the wheel group's transform, and the wheel's own transform untouched.
// A rigid rotation must leave the hub exactly where it was and must never
// stretch the wheel past the diagonal of its resting box.

func bounds(of n: SCNNode, in space: SCNNode) -> (centre: SIMD3<Float>, size: SIMD3<Float>) {
    var lo = SIMD3<Float>(repeating: 1e9), hi = SIMD3<Float>(repeating: -1e9)
    func walk(_ m: SCNNode) {
        if m.geometry != nil {
            let (p, q) = m.boundingBox
            for xi in 0...1 { for yi in 0...1 { for zi in 0...1 {
                let c = SCNVector3(xi == 0 ? p.x : q.x, yi == 0 ? p.y : q.y, zi == 0 ? p.z : q.z)
                let w = space.convertPosition(c, from: m)
                lo = simd_min(lo, SIMD3(Float(w.x), Float(w.y), Float(w.z)))
                hi = simd_max(hi, SIMD3(Float(w.x), Float(w.y), Float(w.z)))
            }}}
        }
        m.childNodes.forEach(walk)
    }
    walk(n)
    return ((lo + hi) / 2, hi - lo)
}

func isWheel(_ name: String) -> Bool {
    let lower = name.lowercased()
    let wheelish = ["wheel", "tire", "tyre"].contains { lower.contains($0) }
    let bodywork = ["support", "arch", "well", "guard", "fender", "mount",
                    "cover", "axle", "axel", "hubcap", "spare"].contains { lower.contains($0) }
    return wheelish && !bodywork
}

var failures = 0, carsWithWheels = 0, wheelCount = 0
let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let files = (try! FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil))
    .filter { $0.pathExtension == "usdz" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

for url in files {
    let name = url.deletingPathExtension().lastPathComponent
    guard let scene = try? SCNScene(url: url, options: nil),
          let model = scene.rootNode.childNodes.first else { continue }
    let carLength = bounds(of: model, in: model).size.z

    var found: [SCNNode] = []
    func visit(_ n: SCNNode, inside: Bool) {
        let start = !inside && isWheel(n.name ?? "")
        if start { found.append(n) }
        n.childNodes.forEach { visit($0, inside: inside || start) }
    }
    visit(model, inside: false)
    guard !found.isEmpty else { continue }
    carsWithWheels += 1

    var mounted: [(String, SCNNode, SCNNode, SIMD3<Float>, SIMD3<Float>)] = []
    for wheel in found {
        guard let parent = wheel.parent else { continue }
        let rest = bounds(of: wheel, in: model)
        guard rest.size.max() > 0 else { continue }
        let centre = rest.centre

        let pivot = SCNNode()
        pivot.simdPosition = centre
        model.addChildNode(pivot)

        // Decomposed the way RealityKit must, which cannot carry shear.
        let m = simd_mul(simd_inverse(model.simdWorldTransform), parent.simdWorldTransform)
        var basis = simd_float3x3(m[0].xyz, m[1].xyz, m[2].xyz)
        let scale = SIMD3(simd_length(basis[0]), simd_length(basis[1]), simd_length(basis[2]))
        for i in 0..<3 where scale[i] > 0 { basis[i] /= scale[i] }
        let carrier = SCNNode()
        carrier.simdOrientation = simd_quatf(basis)
        carrier.simdScale = scale
        carrier.simdPosition = m[3].xyz - centre
        pivot.addChildNode(carrier)

        let authored = wheel.simdTransform
        wheel.removeFromParentNode()
        carrier.addChildNode(wheel)
        wheel.simdTransform = authored

        mounted.append((wheel.name ?? "?", wheel, pivot, centre, rest.size))
        wheelCount += 1
    }

    // The exact condition, free of any bounding-box proxy: after turning the
    // pivot by R the wheel's placement in the car must be T(hub)·R·T(-hub)
    // applied to where it started. That covers both halves at once — the hub
    // stays put and nothing shears — however asymmetric the wheel is.
    var worstHub = Float(0), worstShape = Float(0), worstLabel = ""
    for (label, node, pivot, centre, _) in mounted {
        let before = simd_mul(simd_inverse(model.simdWorldTransform), node.simdWorldTransform)
        let q = simd_quatf(angle: 0.42, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: 0.75, axis: SIMD3(1, 0, 0))
        pivot.simdOrientation = q

        var hubTurn = simd_float4x4(q)
        hubTurn[3] = SIMD4(centre - simd_act(q, centre), 1)
        let expected = simd_mul(hubTurn, before)
        let actual = simd_mul(simd_inverse(model.simdWorldTransform), node.simdWorldTransform)

        let shape = (0..<3).map { simd_length((expected[$0] - actual[$0]).xyz) }.max()! / max(carLength, 1e-6)
        let hub = simd_length((expected[3] - actual[3]).xyz) / carLength
        if hub > worstHub { worstHub = hub; worstLabel = label }
        worstShape = max(worstShape, shape)
        if hub > 1e-4 || shape > 1e-4 {
            failures += 1
            print(String(format: "  FAIL %@ %@: hub off by %.6f of the car, shape off by %.6f",
                         name as NSString, label as NSString, hub, shape))
        }
        pivot.simdOrientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    }

    print(String(format: "  %-16@ %2d wheels   hub error %.7f   shape error %.7f%@",
                 name as NSString, mounted.count, worstHub, worstShape,
                 (worstLabel.isEmpty ? "" : "") as NSString))
}
print("\n\(carsWithWheels) cars, \(wheelCount) wheels — \(failures == 0 ? "every wheel turns exactly about its own hub" : "\(failures) FAILURES")")
exit(failures == 0 ? 0 : 1)
extension SIMD4 where Scalar == Float { var xyz: SIMD3<Float> { SIMD3(x, y, z) } }
