import Foundation
import SceneKit
import simd

/// SceneKit asset measurement in the USD container frame, matching CarRig's
/// RealityKit visualBounds. No asset rebuilding or guessed wheel locations.
struct MeasuredCarGeometry {
    let width: Float
    let base: VehicleTuning
    init(car: CarDefinition, resources: URL) throws {
        let scene = try SCNScene(url:resources.appendingPathComponent(car.assetName+".usdz"),options:nil)
        let holder = scene.rootNode
        func bounds(_ node: SCNNode) -> (SIMD3<Float>,SIMD3<Float>) {
            var low = SIMD3<Float>(repeating:.infinity), high = SIMD3<Float>(repeating:-.infinity)
            func walk(_ n: SCNNode) {
                if n.geometry != nil {
                    let (a,b) = n.boundingBox
                    for x in 0...1 { for y in 0...1 { for z in 0...1 {
                        let p = holder.convertPosition(SCNVector3(x == 0 ? a.x : b.x,y == 0 ? a.y : b.y,z == 0 ? a.z : b.z),from:n)
                        let v = SIMD3<Float>(Float(p.x),Float(p.y),Float(p.z))
                        low = simd_min(low,v); high = simd_max(high,v)
                    } } }
                }
                n.childNodes.forEach(walk)
            }
            walk(node); return ((low+high)/2,high-low)
        }
        let (center,size) = bounds(holder), scale = car.length/size.z
        var wheels: [(SIMD3<Float>,SIMD3<Float>)] = []
        func visit(_ n: SCNNode, inside: Bool) {
            let name = (n.name ?? "").lowercased()
            let match = !inside && ["wheel","tire","tyre"].contains(where:name.contains)
                && !["support","arch","well","guard","fender","mount","cover","axle","axel","hubcap","spare"].contains(where:name.contains)
            if match { let b = bounds(n); if b.1.max() > 0 { wheels.append(b) } }
            n.childNodes.forEach { visit($0,inside:inside || match) }
        }
        visit(holder,inside:false)
        let front = wheels.filter{$0.0.z > center.z}, rear = wheels.filter{$0.0.z <= center.z}
        let all = front+rear
        let wheelbase: Float = front.first != nil && rear.first != nil ? abs(front[0].0.z-rear[0].0.z)*scale : car.length*0.58
        var track: Float = 0.18
        if all.count >= 2 { let xs = all.map{$0.0.x}; let spread = xs.max()!-xs.min()!; if spread > 0 { track = spread*scale } }
        if track < 0.02 { track = size.x*scale*0.82 }
        let radius = all.first.map{max($0.1.y,$0.1.z)/2*scale} ?? car.length*0.115
        width = size.x*scale
        base = VehicleTuning.make(carClass:car.carClass,length:car.length,wheelBase:wheelbase,trackWidth:track,wheelRadius:radius)
    }
}
