import Foundation
import RealityKit
import SceneKit

// Does RealityKit's visualBounds include a rotation baked onto the USD's root
// prim? SceneKit's node-local boundingBox does not, which is what broke the
// render checks and the garage preview. CarRig relies on RealityKit getting
// this right, so it is worth proving rather than assuming.
let resources = URL(fileURLWithPath: CommandLine.arguments[1])
var worst: Float = 0

for name in CommandLine.arguments.dropFirst(2) {
    let url = resources.appendingPathComponent("\(name).usdz")

    // SceneKit, wrapped in a holder: known-good world-space extents.
    guard let scene = try? SCNScene(url: url, options: nil),
          let node = scene.rootNode.childNodes.first else { continue }
    let holder = SCNNode(); node.removeFromParentNode(); holder.addChildNode(node)
    let (lo, hi) = holder.boundingBox
    let reference = SIMD3<Float>(Float(hi.x-lo.x), Float(hi.y-lo.y), Float(hi.z-lo.z))

    // RealityKit, measured exactly the way CarRig does it.
    let entity = try await Entity(contentsOf: url)
    let measured = entity.visualBounds(relativeTo: entity).extents

    let error = simd_length(measured - reference) / max(simd_length(reference), 1e-5)
    worst = max(worst, error)
    print(String(format: "%@  SceneKit (%.2f, %.2f, %.2f)  RealityKit (%.2f, %.2f, %.2f)  %@",
                 name.padding(toLength: 15, withPad: " ", startingAt: 0),
                 reference.x, reference.y, reference.z,
                 measured.x, measured.y, measured.z,
                 error < 0.02 ? "match" : "MISMATCH"))
}
print(String(format: "\nworst disagreement %.2f%%", worst * 100))
