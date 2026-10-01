//
//  RoadCoins.swift
//  vr
//
//  Coins that turn up on the scanned floor while the player drives.
//

import RealityKit
import UIKit
import simd

/// A steady scatter of collectable 1, 2, 5 and 10 coins around the car.
///
/// Cheap by construction: a fixed pool of entities built once from shared
/// meshes and materials (one face texture per denomination), so driving never
/// allocates scene content. Per frame it moves at most `maxLive` transforms and
/// runs one box test per coin; the expensive spot check (detected floor, props,
/// camera view) runs only when a coin is due.
///
/// Pacing: the spawn clock only runs while the car is actually moving, so
/// coins reward driving rather than leaving the phone on the floor. An active
/// driver picks up around ten coins a minute, averaging a little over 2 each.
@MainActor
final class RoadCoins {

    /// What a coin is worth; the number is printed on both faces.
    enum Denomination: Int, CaseIterable {
        case one = 1, two = 2, five = 5, ten = 10

        /// Relative spawn chance. 1 common, 2 fairly common, 5 and 10 rare.
        var weight: Float {
            switch self { case .one: return 58; case .two: return 27; case .five: return 10; case .ten: return 5 }
        }
        var isRare: Bool { self == .five || self == .ten }
        var scale: Float {
            switch self { case .one: return 1; case .two: return 1.06; case .five: return 1.2; case .ten: return 1.32 }
        }
        /// Rim metal and the deep tone the number is stamped in. Value climbs
        /// bronze, silver, gold, then cyan crystal.
        var colors: (metal: UIColor, stamp: UIColor) {
            switch self {
            case .one: return (UIColor(red: 0.93, green: 0.6, blue: 0.36, alpha: 1), UIColor(red: 0.3, green: 0.12, blue: 0.03, alpha: 1))
            case .two: return (UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1), UIColor(red: 0.07, green: 0.14, blue: 0.3, alpha: 1))
            case .five: return (UIColor(red: 1, green: 0.8, blue: 0.2, alpha: 1), UIColor(red: 0.42, green: 0.2, blue: 0, alpha: 1))
            case .ten: return (UIColor(red: 0.35, green: 0.9, blue: 1, alpha: 1), UIColor(red: 0.01, green: 0.16, blue: 0.36, alpha: 1))
            }
        }
        /// Stars around the face and a glow on the floor mark the valuable ones.
        var stars: Int { switch self { case .one, .two: return 0; case .five: return 5; case .ten: return 8 } }
        var glows: Bool { isRare }
    }

    enum Tuning {
        /// Coins standing at once.
        static let maxLive = 4
        /// Seconds of driving before the first coin of a drive.
        static let firstDelay: ClosedRange<Float> = 1.5...2.5
        /// Seconds of driving between coins.
        static let spawnDelay: ClosedRange<Float> = 2.5...4.5
        /// Retry soon when no open spot was found, rather than a full delay.
        static let retryDelay: Float = 0.75
        static let candidatesPerTry = 10
        /// Distance from the car, metres. Rare coins land closer, so they are
        /// worth chasing without being a test of skill.
        static let ring: ClosedRange<Float> = 0.45...1.5
        static let rareRing: ClosedRange<Float> = 0.35...0.9
        static let spacing: Float = 0.25
        /// Seconds a coin waits; it blinks for the final stretch.
        static let lifetime: Float = 14
        static let rareLifetime: Float = 22
        static let blinkTime: Float = 3
        /// Bad-luck protection: a 5-or-better and a 10 are guaranteed after
        /// this many coins without one.
        static let fivePity = 12
        static let tenPity = 25
        static let radius: Float = 0.032
        static let thickness: Float = 0.007
        static let hover: Float = 0.045
        static let bob: Float = 0.006
        static let spinRate: Float = 2.4
        /// Below this rendered speed the car is not "driving" for the spawn clock.
        static let movingSpeed: Float = 0.12
        static let pickupMargin: Float = 0.012
        static let appearTime: Float = 0.25
        static let collectTime: Float = 0.35
    }

    private enum Phase { case appearing, waiting, collecting, leaving }

    private struct Slot {
        let root: Entity
        let spinner: Entity
        let shadow: Entity
        let rim: ModelEntity
        let front: ModelEntity
        let back: ModelEntity
        let glow: ModelEntity
        var live = false
        var phase = Phase.waiting
        var position = SIMD2<Float>.zero
        var age: Float = 0
        var phaseTime: Float = 0
        var spin: Float = 0
        var kind = Denomination.one
        var lifetime: Float { kind.isRare ? Tuning.rareLifetime : Tuning.lifetime }
    }

    private struct Look {
        let rim: PhysicallyBasedMaterial
        /// Unlit, so the value stays readable in a dim room.
        let face: UnlitMaterial
        let glow: UnlitMaterial
    }

    private struct Assets {
        let rim: MeshResource
        let face: MeshResource
        let shadow: MeshResource
        let glow: MeshResource
        let shade: UnlitMaterial
        let looks: [Denomination: Look]
    }

    /// Built once per launch and shared by every drive.
    private static var sharedAssets: Assets?

    private var slots: [Slot] = []
    private var countdown: Float = 0
    private var clock: Float = 0
    private var sinceFive = 0
    private var sinceTen = 0

    /// Called with the coins earned and whether it was a rare (5 or 10) coin.
    var onCollect: ((_ coins: Int, _ rare: Bool) -> Void)?
    /// Called when a coin runs out of time uncollected. Clearing coins on a
    /// reset or edit is not a miss.
    var onMiss: (() -> Void)?

    // MARK: - Lifecycle

    func attach(to anchor: Entity) {
        detach()
        if slots.isEmpty { slots = (0..<Tuning.maxLive).map { _ in Self.makeSlot() } }
        for slot in slots { anchor.addChild(slot.root) }
        clear()
    }

    func detach() {
        for slot in slots { slot.root.removeFromParent() }
        clear()
    }

    /// Hides every coin and restarts the first-coin delay, e.g. on reset.
    func clear() {
        for i in slots.indices {
            slots[i].live = false
            slots[i].root.isEnabled = false
        }
        countdown = Float.random(in: Tuning.firstDelay)
    }

    // MARK: - Per frame

    /// - Parameters:
    ///   - running: driving is live; coins age, animate and can be collected.
    ///   - spawning: new coins may appear (free drive with an owned car).
    ///   - isOpen: whether a stage-local floor point can hold a coin. Only
    ///     called when a coin is due.
    func update(deltaTime dt: Float, car: OrientedBox2D, speed: Float,
                running: Bool, spawning: Bool, isOpen: (SIMD2<Float>) -> Bool) {
        guard running, !slots.isEmpty else { return }
        clock += dt

        for i in slots.indices where slots[i].live {
            advance(&slots[i], dt: dt, car: car)
        }

        guard spawning else { return }
        if speed > Tuning.movingSpeed { countdown -= dt }
        guard countdown <= 0 else { return }
        guard let free = slots.firstIndex(where: { !$0.live }) else {
            countdown = Tuning.retryDelay
            return
        }
        let kind = nextDenomination()
        if let spot = findSpot(near: car, ring: kind.isRare ? Tuning.rareRing : Tuning.ring, isOpen: isOpen) {
            spawn(&slots[free], kind: kind, at: spot)
            countdown = Float.random(in: Tuning.spawnDelay)
        } else {
            countdown = Tuning.retryDelay
        }
    }

    private func advance(_ slot: inout Slot, dt: Float, car: OrientedBox2D) {
        slot.age += dt
        slot.phaseTime += dt
        let size = slot.kind.scale

        switch slot.phase {
        case .appearing, .waiting:
            if slot.phase == .appearing {
                let t = min(slot.phaseTime / Tuning.appearTime, 1)
                slot.spinner.scale = SIMD3(repeating: size * Self.overshoot(t))
                if t >= 1 { slot.phase = .waiting }
            }
            if car.contains(slot.position, margin: Tuning.radius * size + Tuning.pickupMargin) {
                slot.phase = .collecting
                slot.phaseTime = 0
                slot.spinner.isEnabled = true
                onCollect?(slot.kind.rawValue, slot.kind.isRare)
            } else if slot.age >= slot.lifetime {
                slot.phase = .leaving
                slot.phaseTime = 0
                slot.spinner.isEnabled = true
                onMiss?()
            } else if slot.age >= slot.lifetime - Tuning.blinkTime {
                // Blink faster as time runs out.
                let rate: Float = slot.age >= slot.lifetime - 1 ? 12 : 6
                slot.spinner.isEnabled = Int(slot.age * rate) % 2 == 0
            }
            slot.spin += Tuning.spinRate * dt
            if slot.kind.glows {
                slot.glow.scale = SIMD3(repeating: size * (1 + 0.12 * sin(clock * 4 + slot.position.y * 7)))
            }
            let bob = sin(clock * 3 + slot.position.x * 9) * Tuning.bob
            place(slot, height: Tuning.hover * size + bob)

        case .collecting:
            // Lifts, spins up and pops: the "got it" beat.
            let t = min(slot.phaseTime / Tuning.collectTime, 1)
            slot.spin += Tuning.spinRate * 6 * dt
            slot.spinner.scale = SIMD3(repeating: size * (t < 0.4 ? 1 + t * 0.75 : 1.3 * (1 - (t - 0.4) / 0.6)))
            slot.shadow.scale = SIMD3(repeating: max(size * (1 - t), 0.001))
            slot.glow.scale = SIMD3(repeating: max(size * (1 + t), 0.001))
            place(slot, height: Tuning.hover * size + t * 0.07)
            if t >= 1 { retire(&slot) }

        case .leaving:
            let t = min(slot.phaseTime / 0.2, 1)
            slot.spinner.scale = SIMD3(repeating: max(size * (1 - t), 0.001))
            slot.shadow.scale = SIMD3(repeating: max(size * (1 - t), 0.001))
            slot.glow.scale = slot.shadow.scale
            if t >= 1 { retire(&slot) }
        }
    }

    private func place(_ slot: Slot, height: Float) {
        slot.spinner.position = SIMD3(0, height, 0)
        slot.spinner.orientation = simd_quatf(angle: slot.spin, axis: SIMD3(0, 1, 0))
    }

    private func retire(_ slot: inout Slot) {
        slot.live = false
        slot.root.isEnabled = false
    }

    // MARK: - Spawning

    /// Weighted pick with bad-luck protection, so rare coins never dry up.
    private func nextDenomination() -> Denomination {
        var kind: Denomination
        if sinceTen + 1 >= Tuning.tenPity {
            kind = .ten
        } else if sinceFive + 1 >= Tuning.fivePity {
            kind = .five
        } else {
            let total = Denomination.allCases.reduce(0) { $0 + $1.weight }
            var roll = Float.random(in: 0..<total)
            kind = .one
            for candidate in Denomination.allCases {
                if roll < candidate.weight { kind = candidate; break }
                roll -= candidate.weight
            }
        }
        sinceTen = kind == .ten ? 0 : sinceTen + 1
        sinceFive = kind.isRare ? 0 : sinceFive + 1
        return kind
    }

    private func findSpot(near car: OrientedBox2D, ring: ClosedRange<Float>,
                          isOpen: (SIMD2<Float>) -> Bool) -> SIMD2<Float>? {
        let others = slots.filter(\.live).map(\.position)
        for attempt in 0..<Tuning.candidatesPerTry {
            // Mostly ahead of the car, where the player is already looking.
            let spread: Float = attempt < 6 ? 1.2 : .pi
            let angle = car.angle + Float.random(in: -spread...spread)
            let point = car.centre + Plane2D.axisZ(angle) * Float.random(in: ring)
            guard !others.contains(where: { simd_distance($0, point) < Tuning.spacing }) else { continue }
            if isOpen(point) { return point }
        }
        return nil
    }

    private func spawn(_ slot: inout Slot, kind: Denomination, at point: SIMD2<Float>) {
        slot.live = true
        slot.phase = .appearing
        slot.kind = kind
        slot.position = point
        slot.age = 0
        slot.phaseTime = 0
        slot.spin = Float.random(in: 0...(2 * .pi))
        if let look = Self.sharedAssets?.looks[kind] {
            slot.rim.model?.materials = [look.rim]
            slot.front.model?.materials = [look.face]
            slot.back.model?.materials = [look.face]
            slot.glow.model?.materials = [look.glow]
        }
        slot.glow.isEnabled = kind.glows
        slot.glow.scale = SIMD3(repeating: kind.scale)
        slot.root.position = SIMD3(point.x, 0.0015, point.y)
        slot.spinner.scale = SIMD3(repeating: 0.001)
        slot.shadow.scale = SIMD3(repeating: kind.scale)
        slot.spinner.isEnabled = true
        slot.root.isEnabled = true
        place(slot, height: Tuning.hover * kind.scale)
    }

    /// Ease-out with a small overshoot, so a coin pops in rather than fades.
    private static func overshoot(_ t: Float) -> Float {
        let s: Float = 1.7, u = t - 1
        return max(1 + (s + 1) * u * u * u + s * u * u, 0.001)
    }

    // MARK: - Entities

    private static func makeSlot() -> Slot {
        let assets = sharedAssets ?? makeAssets()
        sharedAssets = assets
        let look = assets.looks[.one]!

        // The cylinder stands along Y; tip it onto its edge so it spins about
        // the vertical. Its caps then face ±Z, where the printed faces sit.
        let rim = ModelEntity(mesh: assets.rim, materials: [look.rim])
        rim.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        let offset = Tuning.thickness / 2 + 0.0004
        let front = ModelEntity(mesh: assets.face, materials: [look.face])
        front.position = SIMD3(0, 0, offset)
        let back = ModelEntity(mesh: assets.face, materials: [look.face])
        back.position = SIMD3(0, 0, -offset)
        back.orientation = simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))

        let spinner = Entity()
        spinner.addChild(rim)
        spinner.addChild(front)
        spinner.addChild(back)
        let shadow = ModelEntity(mesh: assets.shadow, materials: [assets.shade])
        let glow = ModelEntity(mesh: assets.glow, materials: [look.glow])
        glow.position = SIMD3(0, 0.0005, 0)

        let root = Entity()
        root.name = "road-coin"
        root.addChild(shadow)
        root.addChild(glow)
        root.addChild(spinner)
        root.isEnabled = false
        return Slot(root: root, spinner: spinner, shadow: shadow, rim: rim, front: front, back: back, glow: glow)
    }

    private static func makeAssets() -> Assets {
        let halo = haloTexture()
        var looks: [Denomination: Look] = [:]
        for kind in Denomination.allCases {
            var rim = PhysicallyBasedMaterial()
            rim.baseColor = .init(tint: kind.colors.metal)
            rim.metallic = .init(floatLiteral: 1)
            rim.roughness = .init(floatLiteral: 0.25)
            // Self-light keeps the edge bright in dim rooms; rare coins shine more.
            rim.emissiveColor = .init(color: kind.colors.metal)
            rim.emissiveIntensity = kind.isRare ? 0.6 : 0.4

            var face = UnlitMaterial(color: kind.colors.metal)
            if let image = faceImage(kind),
               let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
                face.color = .init(tint: .white, texture: .init(texture))
            }

            var glow = UnlitMaterial(color: kind.colors.metal)
            if let halo {
                glow.color = .init(tint: kind.colors.metal, texture: .init(halo))
                glow.blending = .transparent(opacity: .init(scale: 0.85, texture: .init(halo)))
            } else {
                glow.blending = .transparent(opacity: 0.3)
            }
            looks[kind] = Look(rim: rim, face: face, glow: glow)
        }

        var shade = UnlitMaterial(color: .black)
        shade.blending = .transparent(opacity: 0.28)

        let r = Tuning.radius
        let face = r * 1.84
        return Assets(
            rim: .generateCylinder(height: Tuning.thickness, radius: r),
            face: .generatePlane(width: face, height: face, cornerRadius: face / 2),
            shadow: .generatePlane(width: r * 1.8, depth: r * 1.8, cornerRadius: r * 0.9),
            glow: .generatePlane(width: r * 5, depth: r * 5),
            shade: shade,
            looks: looks)
    }

    /// Soft white-to-clear disc, tinted per coin for the floor glow.
    private static func haloTexture() -> TextureResource? {
        let size: CGFloat = 128
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.35).cgColor, UIColor.black.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 1]) else { return }
            let centre = CGPoint(x: size / 2, y: size / 2)
            context.cgContext.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                                                 endCenter: centre, endRadius: size / 2, options: [])
        }
        guard let cg = image.cgImage else { return nil }
        return try? TextureResource(image: cg, options: .init(semantic: .color))
    }

    /// A stamped coin face: shaded metal, a bevelled ring, stars on the
    /// valuable ones, and a large outlined value that reads at a glance.
    private static func faceImage(_ kind: Denomination) -> CGImage? {
        let size: CGFloat = 256
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let centre = CGPoint(x: size / 2, y: size / 2)
        let (metal, stamp) = kind.colors
        let highlight = metal.mixed(with: .white, amount: 0.6)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            let cg = context.cgContext
            metal.mixed(with: stamp, amount: 0.3).setFill()
            cg.fill(bounds)
            let colors = [highlight.cgColor, metal.cgColor, metal.mixed(with: stamp, amount: 0.25).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                cg.drawRadialGradient(gradient, startCenter: CGPoint(x: size * 0.35, y: size * 0.28), startRadius: 0,
                                      endCenter: centre, endRadius: size * 0.72, options: [.drawsAfterEndLocation])
            }
            // Bevelled ring: a dark groove with a bright lip inside it.
            cg.setLineWidth(8)
            cg.setStrokeColor(stamp.withAlphaComponent(0.6).cgColor)
            cg.strokeEllipse(in: bounds.insetBy(dx: 14, dy: 14))
            cg.setLineWidth(3)
            cg.setStrokeColor(highlight.cgColor)
            cg.strokeEllipse(in: bounds.insetBy(dx: 21, dy: 21))

            if kind.stars > 0 {
                stamp.withAlphaComponent(0.85).setFill()
                for i in 0..<kind.stars {
                    let angle = CGFloat(i) / CGFloat(kind.stars) * 2 * .pi - .pi / 2
                    let point = CGPoint(x: centre.x + cos(angle) * size * 0.385, y: centre.y + sin(angle) * size * 0.385)
                    sparkle(at: point, radius: 9, in: cg)
                }
            }

            let text = "\(kind.rawValue)" as NSString
            let points: CGFloat = kind == .ten ? 150 : 185
            let font = UIFont(name: "LilitaOne", size: points) ?? .systemFont(ofSize: points, weight: .black)
            let measured = text.size(withAttributes: [.font: font])
            let origin = CGPoint(x: (size - measured.width) / 2, y: (size - measured.height) / 2)
            // Drop shadow, then the value with a bright outline so it holds
            // against the metal from any angle.
            text.draw(at: CGPoint(x: origin.x + 3, y: origin.y + 5),
                      withAttributes: [.font: font, .foregroundColor: stamp.withAlphaComponent(0.45)])
            text.draw(at: origin, withAttributes: [.font: font, .foregroundColor: stamp,
                                                   .strokeColor: highlight, .strokeWidth: -7])
        }
        return image.cgImage
    }

    /// A four-pointed twinkle.
    private static func sparkle(at point: CGPoint, radius r: CGFloat, in cg: CGContext) {
        let inner = r * 0.32
        cg.beginPath()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4 - .pi / 2
            let length = i.isMultiple(of: 2) ? r : inner
            let p = CGPoint(x: point.x + cos(angle) * length, y: point.y + sin(angle) * length)
            if i == 0 { cg.move(to: p) } else { cg.addLine(to: p) }
        }
        cg.closePath()
        cg.fillPath()
    }
}

private extension UIColor {
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                       blue: b1 + (b2 - b1) * amount, alpha: 1)
    }
}
