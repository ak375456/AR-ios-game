import Foundation
import SceneKit
import AppKit

// Shows each car's +Z end and -Z end side by side, measured with the model
// wrapped in a holder so its own baked rotation is included.
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let files = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
let panel = CGSize(width: 420, height: 320)
let sheet = NSImage(size: CGSize(width: panel.width * 2, height: panel.height * CGFloat(files.count)))
sheet.lockFocus()

func render(_ url: URL, fromPlusZ: Bool, size: CGSize) -> NSImage? {
    guard let scene = try? SCNScene(url: url, options: nil),
          let model = scene.rootNode.childNodes.first else { return nil }
    let holder = SCNNode()
    model.removeFromParentNode(); holder.addChildNode(model)
    scene.rootNode.addChildNode(holder)

    let (lo, hi) = holder.boundingBox
    let extent = SCNVector3(hi.x-lo.x, hi.y-lo.y, hi.z-lo.z)
    let centre = SCNVector3((lo.x+hi.x)/2, (lo.y+hi.y)/2, (lo.z+hi.z)/2)
    let radius = CGFloat(sqrt(pow(extent.x,2)+pow(extent.y,2)+pow(extent.z,2)))/2
    let side: CGFloat = fromPlusZ ? 1 : -1

    let cam = SCNNode(); cam.camera = SCNCamera()
    cam.camera!.usesOrthographicProjection = true
    cam.camera!.orthographicScale = Double(max(extent.x, extent.y)) * 0.6
    cam.camera!.zNear = 0.001; cam.camera!.zFar = Double(radius) * 40
    cam.position = SCNVector3(centre.x, centre.y + radius * 0.3, centre.z + side * radius * 6)
    scene.rootNode.addChildNode(cam); cam.look(at: centre)

    for p in [SCNVector3(1.5, 2.5, 3*side), SCNVector3(-2, 1.5, 2*side), SCNVector3(0, 1, -3*side)] {
        let l = SCNNode(); l.light = SCNLight(); l.light!.type = .directional; l.light!.intensity = 780
        l.position = SCNVector3(centre.x+p.x*radius, centre.y+p.y*radius, centre.z+p.z*radius)
        scene.rootNode.addChildNode(l); l.look(at: centre)
    }
    let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 500
    scene.rootNode.addChildNode(amb)
    scene.background.contents = NSColor(calibratedWhite: 0.92, alpha: 1)

    let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    r.scene = scene; r.pointOfView = cam
    return r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
}

for (i, url) in files.enumerated() {
    let name = url.deletingPathExtension().lastPathComponent
    let y = sheet.size.height - CGFloat(i + 1) * panel.height
    for (j, plus) in [true, false].enumerated() {
        guard let img = render(url, fromPlusZ: plus, size: CGSize(width: panel.width, height: panel.height - 30)) else { continue }
        img.draw(in: CGRect(x: CGFloat(j) * panel.width, y: y + 30, width: panel.width, height: panel.height - 30))
        let label = "\(name) — \(plus ? "+Z end (should be the FRONT)" : "-Z end (should be the BACK)")"
        (label as NSString).draw(at: CGPoint(x: CGFloat(j) * panel.width + 8, y: y + 7),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold),
                             .foregroundColor: plus ? NSColor.systemBlue : NSColor.darkGray])
    }
}
sheet.unlockFocus()
try NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
