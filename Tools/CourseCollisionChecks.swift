import Foundation
import simd

// Headless checks for the course: the car against barriers, cones and tyres, driven
// by the real vehicle model at the real 180 Hz step, plus the slalom planner.
//
//   xcrun swiftc -parse-as-library -O -o /tmp/coursetest \
//     vr/Car/DrivingInput.swift vr/Car/VehicleTuning.swift vr/Car/Drivetrain.swift \
//     vr/Car/VehicleDynamics.swift vr/Car/SimulationScale.swift \
//     vr/Course/CourseSpec.swift vr/Course/CourseGeometry.swift \
//     vr/Course/CourseContacts.swift vr/Course/SlalomPlanner.swift \
//     Tools/CourseCollisionChecks.swift && /tmp/coursetest
//
// Cones are stood in for by a point that slides to a stop under floor
// friction; on the phone RealityKit does that part, and tips them over too.

@main
struct CourseChecks {

    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
        if !ok { failures += 1 }
    }

    static func car(_ c: CarClass, length: Float = 0.42, at position: SIMD2<Float> = .zero,
                    heading: Float = 0) -> VehicleDynamics {
        let t = VehicleTuning.make(carClass: c, length: length,
                                   wheelBase: length * 0.55, trackWidth: length * 0.44,
                                   wheelRadius: length * 0.115)
        var d = VehicleDynamics(tuning: t)
        d.place(at: position, heading: heading)
        return d
    }

    /// The car footprint the app builds from a car's measured bounds.
    static func contacts(length: Float = 0.42) -> CourseContacts {
        let c = CourseContacts()
        c.carHalfExtents = SIMD2(length * 0.44 * 0.94, length * 0.97) / 2
        c.carHeight = length * 0.33
        return c
    }

    static func barrier(at centre: SIMD2<Float>, angle: Float) -> OrientedBox2D {
        OrientedBox2D(centre: centre,
                      halfExtents: SIMD2(CourseSpec.Barrier.length, CourseSpec.Barrier.contactWidth) / 2,
                      angle: angle)
    }

    /// Deepest the car gets into any barrier, measured independently of the
    /// solver: the overlap along the barrier's own thin axis while the two
    /// shapes intersect.
    static func penetration(_ c: CourseContacts, _ d: VehicleDynamics) -> Float {
        let box = c.carBox(for: d.state)
        var worst: Float = 0
        for b in c.barriers where box.overlaps(b) {
            if let contact = ContactGeometry.contact(car: box, obstacle: b, carCameFrom: d.state.position) {
                worst = max(worst, contact.depth)
            }
        }
        return worst
    }

    /// One slide-to-a-stop cone or tyre, as RealityKit would hand it over
    /// each frame.
    struct TestProp {
        var position: SIMD2<Float>
        var kind: PropKind = .cone
        var velocity: SIMD2<Float> = .zero

        var radius: Float { kind == .tyre ? CourseSpec.Tyre.contactRadius : CourseSpec.Cone.contactRadius }
        var mass: Float { kind == .tyre ? CourseSpec.Tyre.mass : CourseSpec.Cone.mass }
        var friction: Float { kind == .tyre ? CourseSpec.Tyre.friction : CourseSpec.Cone.friction }

        func body() -> CourseContacts.LooseProp {
            CourseContacts.LooseProp(id: UUID(), kind: kind, circles: [SIMD3(position.x, position.y, radius)],
                                     velocity: velocity, lowestPoint: 0)
        }

        mutating func advance(after solved: CourseContacts.LooseProp, dt: Float) {
            velocity += solved.impulse / mass
            position += velocity * dt
            let speed = simd_length(velocity)
            let slowed = max(speed - friction * 9.81 * dt, 0)
            velocity = speed > 1e-6 ? velocity * (slowed / speed) : .zero
        }
    }

    static func main() {
        let input = DrivingInput(); input.isEnabled = true

        // 1. Head-on into a barrier at speed.
        do {
            var d = car(.sports)
            var c = contacts()
            let wall = barrier(at: SIMD2(0, 3.0), angle: 0)
            c.barriers = [wall]
            input.releaseAll(); input.throttle = 1
            var deepest: Float = 0, impactSpeed: Float = 0, rebound: Float = 0, crossed = false
            let dt: Float = 1 / 120
            for frame in 0..<Int(6 / dt) {
                let before = d.state.forwardSpeed
                d.advance(deltaTime: dt, input: input, contacts: &c)
                deepest = max(deepest, penetration(c, d))
                if c.takeImpacts().barrier > 0, impactSpeed == 0 { impactSpeed = before }
                if d.state.position.y > wall.centre.y { crossed = true }
                if frame > Int(4.5 / dt) { input.throttle = 0 }
                if impactSpeed > 0 { rebound = min(rebound, d.state.forwardSpeed) }
            }
            check("barrier: stops a head-on hit", impactSpeed > 1.5 && !crossed,
                  String(format: "hit at %.2f m/s, car centre stayed short: %@", impactSpeed, crossed ? "no" : "yes"))
            check("barrier: no visible penetration", deepest < 0.004, String(format: "deepest %.1f mm", deepest * 1000))
            check("barrier: small rebound, no violent bounce", rebound > -0.45 && rebound < -0.05,
                  String(format: "rebound %.2f m/s from %.2f m/s", -rebound, impactSpeed))
        }

        // 2. Same hit at 30, 60 and 120 Hz ends in the same place.
        do {
            var finals: [Float] = [], deepest: Float = 0
            for hz in [30.0, 60.0, 120.0] {
                var d = car(.sports)
                var c = contacts()
                c.barriers = [barrier(at: SIMD2(0, 3.0), angle: 0)]
                input.releaseAll(); input.throttle = 1
                let dt = Float(1 / hz)
                for frame in 0..<Int(5 * hz) {
                    if frame == Int(4 * hz) { input.throttle = 0 }
                    d.advance(deltaTime: dt, input: input, contacts: &c)
                    deepest = max(deepest, penetration(c, d))
                }
                finals.append(d.state.position.y)
            }
            let spread = finals.max()! - finals.min()!
            check("barrier: frame-rate independent", spread < 0.01 && deepest < 0.004,
                  finals.map { String(format: "%.3f", $0) }.joined(separator: " / ")
                  + String(format: " m (spread %.1f mm, deepest %.1f mm)", spread * 1000, deepest * 1000))
        }

        // 3. Glancing blow along a wall of barriers: scrape, don't stick.
        do {
            let angle: Float = 15 * .pi / 180
            var d = car(.sports, heading: angle)
            var c = contacts()
            let wallX: Float = 0.9 + CourseSpec.Barrier.contactWidth / 2
            c.barriers = (0..<24).map { barrier(at: SIMD2(wallX, 1.0 + Float($0) * CourseSpec.Barrier.length), angle: -.pi / 2) }
            input.releaseAll(); input.throttle = 1
            let dt: Float = 1 / 120
            var firstContact: Int?, speedAtContact: Float = 0, deepest: Float = 0
            var awaySpeed: Float = 0, slowestInContact: Float = .infinity, speedAfter: Float = 0
            for frame in 0..<Int(6 / dt) {
                let speed = d.state.speed
                d.advance(deltaTime: dt, input: input, contacts: &c)
                deepest = max(deepest, penetration(c, d))
                let hit = c.takeImpacts().barrier > 0
                if hit && firstContact == nil { firstContact = frame; speedAtContact = speed }
                if let first = firstContact {
                    awaySpeed = max(awaySpeed, -d.state.velocity.x)
                    if frame < first + Int(0.6 / dt) { slowestInContact = min(slowestInContact, d.state.speed) }
                    if frame == first + Int(0.6 / dt) { speedAfter = d.state.speed }
                }
            }
            check("glancing: keeps most of its speed", firstContact != nil && speedAfter > speedAtContact * 0.7,
                  String(format: "%.2f m/s at contact, %.2f m/s 0.6 s later", speedAtContact, speedAfter))
            check("glancing: slides along instead of sticking", slowestInContact > speedAtContact * 0.6,
                  String(format: "slowest %.2f m/s while scraping", slowestInContact))
            check("glancing: no bounce off the wall", awaySpeed < 0.3, String(format: "%.2f m/s away from the wall", awaySpeed))
            check("glancing: no penetration", deepest < 0.004, String(format: "deepest %.1f mm", deepest * 1000))
        }

        // 4. Sideways in a drift, into a barrier across the slide.
        do {
            func drift(with c: CourseContacts?) -> [VehicleState] {
                var d = car(.drift)
                var states: [VehicleState] = []
                input.releaseAll(); input.throttle = 1
                let dt: Float = 1 / 120
                for frame in 0..<Int(5.5 / dt) {
                    if frame == Int(2.5 / dt) { input.steering = 1; input.handbrake = 1 }
                    if frame == Int(2.9 / dt) { input.handbrake = 0 }
                    if var c { d.advance(deltaTime: dt, input: input, contacts: &c) } else { d.advance(deltaTime: dt, input: input) }
                    states.append(d.state)
                }
                return states
            }
            let free = drift(with: nil)
            let peak = free.map { abs($0.lateralSpeed) }.max() ?? 0
            let moment = free.indices.first(where: { $0 > 300 && abs(free[$0].lateralSpeed) > peak * 0.8 }) ?? 0
            check("drift: slide develops", peak > 0.3, String(format: "peak sideways speed %.2f m/s", peak))
            let s = free[moment]
            let along = simd_normalize(s.velocity)
            let centre = s.position + along * 0.36
            var c = contacts()
            let wall = barrier(at: centre, angle: atan2(along.x, along.y))
            c.barriers = [wall]
            let hitStates = drift(with: c)
            var deepest: Float = 0, crossed = false, bounce: Float = 0, maxInto: Float = 0
            for (i, st) in hitStates.enumerated() {
                if simd_dot(st.position - wall.centre, along) > 0 { crossed = true }
                if i > moment {
                    bounce = max(bounce, -simd_dot(st.velocity, along))
                    maxInto = max(maxInto, simd_dot(st.velocity, along))
                }
                let box = c.carBox(for: st)
                if box.overlaps(wall), let ct = ContactGeometry.contact(car: box, obstacle: wall, carCameFrom: st.position) {
                    deepest = max(deepest, ct.depth)
                }
            }
            let finite = hitStates.allSatisfy(\.isFinite)
            check("drift: sliding car cannot pass through", !crossed && finite,
                  String(format: "sideways at %.2f m/s when it reached the barrier", abs(s.lateralSpeed)))
            check("drift: no penetration while sliding", deepest < 0.004, String(format: "deepest %.1f mm", deepest * 1000))
            check("drift: stays calm after the hit", bounce < 0.6,
                  String(format: "%.2f m/s back off the barrier", bounce))
        }

        // 5. Parked against a barrier with the throttle pinned: no creep, no jitter.
        do {
            var d = car(.truck, length: 0.52)
            var c = contacts(length: 0.52)
            let wall = barrier(at: SIMD2(0, c.carHalfExtents.y + CourseSpec.Barrier.contactWidth / 2 + 0.02), angle: 0)
            c.barriers = [wall]
            input.releaseAll(); input.throttle = 1
            var late: [Float] = [], crossed = false
            for frame in 0..<(60 * 4) {
                d.advance(deltaTime: 1 / 60, input: input, contacts: &c)
                if frame > 120 { late.append(d.state.position.y) }
                if d.state.position.y > wall.centre.y { crossed = true }
            }
            let wander = late.max()! - late.min()!
            check("pushing a barrier: holds still", wander < 0.002 && !crossed,
                  String(format: "moved %.2f mm over the last two seconds", wander * 1000))
        }

        // 6. Tunnelling: the fastest car into thin barriers at every angle.
        do {
            var worstDepth: Float = 0, crossings = 0
            for degrees in stride(from: 0, through: 85, by: 17) {
                var d = car(.openWheel, length: 0.46)
                var c = contacts(length: 0.46)
                let wall = barrier(at: SIMD2(0, 4.0), angle: Float(degrees) * .pi / 180)
                c.barriers = [wall]
                input.releaseAll(); input.throttle = 1
                for _ in 0..<(120 * 6) {
                    d.advance(deltaTime: 1 / 120, input: input, contacts: &c)
                    worstDepth = max(worstDepth, penetration(c, d))
                    if simd_dot(d.state.position - wall.centre, wall.axisZ) > 0 { crossings += 1; break }
                }
            }
            check("tunnelling: never through a barrier", crossings == 0 && worstDepth < 0.005,
                  String(format: "%d crossings, deepest %.1f mm", crossings, worstDepth * 1000))
        }

        // 7. Cones and tyres: the car loses some speed, the prop takes the
        //    rest. Each car is run twice with the throttle held, once with the
        //    prop in its path and once without. Lighter cars lose more, as they
        //    should, and a tyre always costs more than a cone.
        var coneLosses: [String: Float] = [:]
        for kind in [PropKind.cone, .tyre] {
            let ceiling: Float = kind == .tyre ? 0.35 : 0.2
            for (label, cls, length) in [("compact", CarClass.compact, Float(0.36)), ("sports", .sports, 0.44), ("truck", .truck, 0.52)] {
                var results: [String] = [], ok = true
                for distance: Float in [0.45, 1.2, 3.4] {
                    let dt: Float = 1 / 120
                    let propPosition = SIMD2<Float>(0, distance + length / 2)
                    func run(prop: Bool) -> (speeds: [Float], impactFrame: Int?, impactSpeed: Float, propSpeeds: [Float]) {
                        var d = car(cls, length: length)
                        var c = contacts(length: length)
                        var tp = TestProp(position: propPosition, kind: kind)
                        input.releaseAll(); input.throttle = 1
                        var speeds: [Float] = [], propSpeeds: [Float] = []
                        var impactFrame: Int?, impactSpeed: Float = 0
                        for frame in 0..<Int(6 / dt) {
                            if prop { c.looseProps = [tp.body()] }
                            let before = d.state.speed
                            d.advance(deltaTime: dt, input: input, contacts: &c)
                            if prop {
                                tp.advance(after: c.looseProps[0], dt: dt)
                                let impacts = c.takeImpacts()
                                if max(impacts.cone, impacts.tyre) > 0, impactFrame == nil {
                                    impactFrame = frame; impactSpeed = before
                                }
                            }
                            speeds.append(d.state.speed)
                            propSpeeds.append(simd_length(tp.velocity))
                        }
                        return (speeds, impactFrame, impactSpeed, propSpeeds)
                    }
                    let hit = run(prop: true)
                    let clear = run(prop: false)
                    guard let frame = hit.impactFrame else { ok = false; results.append("missed"); continue }
                    // The step change across the impact, less whatever the same
                    // car did over the same frames without the prop — which takes
                    // the gearbox's own timing out of the comparison.
                    let before = frame - 1, after = frame + 2
                    let change = (hit.speeds[after] - hit.speeds[before]) - (clear.speeds[after] - clear.speeds[before])
                    let loss = -change / max(hit.impactSpeed, 1e-3)
                    let propSpeed = hit.propSpeeds[frame + 1]
                    let key = "\(label)-\(distance)"
                    if kind == .cone { coneLosses[key] = loss }
                    let costsMore = kind == .cone || loss > (coneLosses[key] ?? 0)
                    ok = ok && loss > 0.01 && loss < ceiling && propSpeed > hit.impactSpeed * 0.9 && costsMore
                    results.append(String(format: "%.2f m/s → −%.0f%%, off at %.2f", hit.impactSpeed, loss * 100, propSpeed))
                }
                check("\(kind.rawValue) (\(label)): costs some speed, never a wall", ok, results.joined(separator: "; "))
            }
        }

        // 8. A glancing touch sends the cone sideways and barely moves the car.
        do {
            var d = car(.sports)
            var c = contacts()
            var tc = TestProp(position: SIMD2(c.carHalfExtents.x + 0.012, 2.5))
            input.releaseAll(); input.throttle = 1
            var headingBefore: Float = 0, touched = false
            for frame in 0..<(120 * 4) {
                if frame == 0 { headingBefore = d.state.heading }
                c.looseProps = [tc.body()]
                d.advance(deltaTime: 1 / 120, input: input, contacts: &c)
                tc.advance(after: c.looseProps[0], dt: 1 / 120)
                if c.takeImpacts().cone > 0 { touched = true }
            }
            let turned = abs(d.state.heading - headingBefore) * 180 / .pi
            check("cone clipped: pushed aside, car holds its line", touched && tc.position.x > c.carHalfExtents.x + 0.03 && turned < 4,
                  String(format: "cone moved %.2f m sideways, car turned %.1f°", tc.position.x - c.carHalfExtents.x - 0.012, turned))
        }

        // 9. Parked next to a cone: nothing moves.
        do {
            var d = car(.sedan)
            var c = contacts()
            var tc = TestProp(position: SIMD2(0, c.carHalfExtents.y + CourseSpec.Cone.contactRadius + 0.005))
            input.releaseAll()
            for _ in 0..<(60 * 5) {
                c.looseProps = [tc.body()]
                d.advance(deltaTime: 1 / 60, input: input, contacts: &c)
                tc.advance(after: c.looseProps[0], dt: 1 / 60)
            }
            check("parked beside a cone: both stay put", d.state.position == .zero && simd_length(tc.velocity) == 0,
                  "car \(d.state.position), cone speed \(simd_length(tc.velocity))")
        }

        // 10. A cone left under the car is eased out, not launched.
        do {
            var d = car(.sedan)
            var c = contacts()
            var tc = TestProp(position: SIMD2(0.02, 0.1))
            input.releaseAll()
            var fastest: Float = 0
            for _ in 0..<(60 * 2) {
                c.looseProps = [tc.body()]
                d.advance(deltaTime: 1 / 60, input: input, contacts: &c)
                tc.advance(after: c.looseProps[0], dt: 1 / 60)
                fastest = max(fastest, simd_length(tc.velocity))
            }
            let outside = !c.carBox(for: d.state).overlaps(circle: tc.position, radius: CourseSpec.Cone.contactRadius)
            check("cone under the car: eased out gently", outside && fastest < 0.8 && simd_length(d.state.position) < 0.01,
                  String(format: "out: %@, fastest %.2f m/s, car moved %.1f mm", outside ? "yes" : "no", fastest,
                         simd_length(d.state.position) * 1000))
        }

        // 11. Contact geometry: flat faces give two points, corners one.
        do {
            let wall = OrientedBox2D(centre: SIMD2(0, 1), halfExtents: SIMD2(0.5, 0.05), angle: 0)
            let flat = OrientedBox2D(centre: SIMD2(0, 1 - 0.05 - 0.2 + 0.003), halfExtents: SIMD2(0.08, 0.2), angle: 0)
            let corner = OrientedBox2D(centre: SIMD2(0, 1 - 0.05 - 0.2), halfExtents: SIMD2(0.08, 0.2), angle: 0.4)
            let a = ContactGeometry.contact(car: flat, obstacle: wall, carCameFrom: flat.centre)
            let b = ContactGeometry.contact(car: corner, obstacle: wall, carCameFrom: corner.centre)
            check("manifold: flat contact has two points pushing back", a?.points.count == 2 && (a?.normal.y ?? 0) < -0.99
                  && abs((a?.depth ?? 0) - 0.003) < 1e-4,
                  "points \(a?.points.count ?? 0), normal \(a?.normal ?? .zero), depth \(a?.depth ?? 0)")
            check("manifold: corner contact has one point", b?.points.count == 1, "points \(b?.points.count ?? 0)")
        }

        // 12. Slalom planner.
        do {
            let half = SIMD2<Float>(0.087, 0.204)
            let open = SlalomPlanner.plan(carPosition: .zero, carHeading: 0, carHalfExtents: half, carLength: 0.42,
                                          capacity: 24, canStand: { _ in true })
            if case .success(let p) = open {
                check("slalom: full row straight ahead on open floor",
                      p.positions.count == SlalomPlanner.preferredCount && p.heading == 0 && p.positions.allSatisfy { $0.y > 0.4 },
                      String(format: "%d cones, %.2f m apart, first %.2f m ahead", p.positions.count, p.spacing, p.positions[0].y))
            } else { check("slalom: full row on open floor", false, "\(open)") }

            let room: (SIMD2<Float>) -> Bool = { simd_length($0) < 2.2 }
            if case .success(let p) = SlalomPlanner.plan(carPosition: .zero, carHeading: 0, carHalfExtents: half,
                                                         carLength: 0.42, capacity: 24, canStand: room) {
                check("slalom: fewer cones on a small floor", p.positions.count >= 3 && p.positions.count < 6
                      && p.positions.allSatisfy(room),
                      String(format: "%d cones, %.2f m apart", p.positions.count, p.spacing))
            } else { check("slalom: fewer cones on a small floor", false, "none") }

            let tiny = SlalomPlanner.plan(carPosition: .zero, carHeading: 0, carHalfExtents: half, carLength: 0.42,
                                          capacity: 24, canStand: { simd_length($0) < 0.6 })
            check("slalom: explains when it cannot fit", tiny == .failure(.noRoom), "\(tiny)")

            let full = SlalomPlanner.plan(carPosition: .zero, carHeading: 0, carHalfExtents: half, carLength: 0.42,
                                          capacity: 2, canStand: { _ in true })
            check("slalom: respects the prop limit", full == .failure(.courseFull), "\(full)")

            // Something in the way straight ahead: it turns rather than giving up.
            let blocked: (SIMD2<Float>) -> Bool = { !(abs($0.x) < 0.3 && $0.y > 0) }
            if case .success(let p) = SlalomPlanner.plan(carPosition: .zero, carHeading: 0, carHalfExtents: half,
                                                         carLength: 0.42, capacity: 24, canStand: blocked) {
                check("slalom: routes round an obstruction", p.heading != 0 && p.positions.allSatisfy(blocked),
                      String(format: "turned %.0f°, %d cones", p.heading * 180 / .pi, p.positions.count))
            } else { check("slalom: routes round an obstruction", false, "none") }
        }

        print(failures == 0 ? "\nAll course checks passed." : "\n\(failures) course check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
