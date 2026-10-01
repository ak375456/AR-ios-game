//
//  CourseContacts.swift
//  vr
//
//  The car's side of every collision with the course.
//

import Foundation
import simd

/// Resolves the car against the course inside every fixed physics step.
///
/// **Why the car's collisions are solved here and not by RealityKit.** The car
/// is moved by `VehicleDynamics`, which integrates its own position at 180 Hz
/// so that it can slide. RealityKit never moves it, so a collision shape on
/// the car would at best push props aside while the car drove through them
/// untouched, and a barrier would stop nothing. The contact has to change the
/// same velocity and yaw rate the tyres work on, in the same step, or the
/// drivetrain, speedometer, wheels and smoke would disagree about what just
/// happened.
///
/// **Barriers** are fixed boxes. On contact the car is moved back out by the
/// full depth — never more, so it cannot jump — and an impulse removes the
/// closing speed at each contact point, with a little restitution on a hard
/// hit and none on a gentle one, so pushing against a barrier is quiet and
/// hitting it at speed gives a small, believable rebound. Friction along the
/// barrier is limited by that normal impulse: a shallow hit has little normal
/// speed, so it loses little along the wall and the car scrapes along instead
/// of sticking. The impulse acts at the contact point, so a hit on one corner
/// turns the car.
///
/// **Cones and tyres** are loose bodies. The car and the prop exchange
/// momentum as two masses would — a cone costs the car a few per cent of its
/// speed, a tyre, being heavier, rather more — and the prop takes the rest;
/// the impulse is then handed to RealityKit, which does what only a 3D solver
/// can: tips a cone over, spins a tyre away, and lets either settle. Between
/// frames a prop is carried on at the speed it has been given, so one that has
/// just been hit is already moving away on the next step and the same contact
/// is never counted twice.
///
/// Everything is in the stage's ground plane, like `VehicleState`.
final class CourseContacts: VehicleContactSolver {

    /// A cone or a tyre as the car meets it: a few circles projected onto the
    /// floor. A standing cone's stack into one; a cone lying down traces its
    /// length; a tyre is one circle lying flat and a short row on its edge.
    struct LooseProp {
        let id: UUID
        let kind: PropKind
        /// `x`, `y` on the floor and `z` the radius.
        var circles: [SIMD3<Float>]
        var velocity: SIMD2<Float>
        /// Lowest point above the floor, so a prop flying over the roof is
        /// left alone.
        var lowestPoint: Float
        let mass: Float
        /// How lively the car–prop knock is, and how much it drags sideways.
        let restitution: Float
        let friction: Float

        /// What the car did to it during the frame.
        var impulse: SIMD2<Float> = .zero
        var impulseMoment: SIMD2<Float> = .zero
        var impulseWeight: Float = 0

        init(id: UUID, kind: PropKind, circles: [SIMD3<Float>], velocity: SIMD2<Float>, lowestPoint: Float) {
            self.id = id
            self.kind = kind
            self.circles = circles
            self.velocity = velocity
            self.lowestPoint = lowestPoint
            switch kind {
            case .tyre:
                mass = CourseSpec.Tyre.mass
                restitution = CourseSpec.Tyre.impactRestitution
                friction = CourseSpec.Tyre.impactFriction
            case .cone, .barrier:
                mass = CourseSpec.Cone.mass
                restitution = CourseSpec.Cone.impactRestitution
                friction = CourseSpec.Cone.impactFriction
            }
        }

        /// Where on the floor the impulse acted, on average.
        var impulsePoint: SIMD2<Float>? {
            impulseWeight > 1e-6 ? impulseMoment / impulseWeight : nil
        }
    }

    /// Half the car's collision footprint: `x` across, `y` along.
    var carHalfExtents = SIMD2<Float>(0.085, 0.205)
    var carHeight: Float = 0.14
    var barriers: [OrientedBox2D] = []
    var looseProps: [LooseProp] = []

    /// The hardest closing speeds since they were last taken, for haptics.
    private(set) var stepImpact: Float = 0
    private(set) var stepConeContact = false
    private(set) var barrierImpact: Float = 0
    private(set) var coneImpact: Float = 0
    private(set) var tyreImpact: Float = 0

    /// Penetration left in place so resting contact stays in contact rather
    /// than chattering in and out every step.
    static let slop: Float = 0.0005
    /// How quickly a prop found inside the car is eased out, as a fraction
    /// of the overlap per step.
    static let separationRate: Float = 0.2
    /// Nothing the course does should spin the car faster than the tyres can.
    static let maxYawRate: Float = 6

    var isEmpty: Bool { barriers.isEmpty && looseProps.isEmpty }

    func takeImpacts() -> (barrier: Float, cone: Float, tyre: Float) {
        defer { barrierImpact = 0; coneImpact = 0; tyreImpact = 0 }
        return (barrierImpact, coneImpact, tyreImpact)
    }

    func carBox(for state: VehicleState) -> OrientedBox2D {
        OrientedBox2D(centre: state.position, halfExtents: carHalfExtents, angle: state.heading)
    }

    // MARK: - VehicleContactSolver

    func resolveContacts(state: inout VehicleState, previous: VehicleState,
                         tuning: VehicleTuning, dt: Float) {
        stepImpact = 0; stepConeContact = false
        guard !isEmpty else { return }
        resolveBarriers(state: &state, previous: previous, tuning: tuning)
        resolveLooseProps(state: &state, tuning: tuning, dt: dt)
        state.yawRate = min(max(state.yawRate, -Self.maxYawRate), Self.maxYawRate)
    }

    // MARK: - Barriers

    private func resolveBarriers(state: inout VehicleState, previous: VehicleState, tuning: VehicleTuning) {
        guard !barriers.isEmpty else { return }
        let reach = simd_length(carHalfExtents)

        // A second pass catches a car wedged between two barriers: pushing it
        // out of one can push it into the other.
        for _ in 0..<2 {
            var touched = false
            for barrier in barriers {
                guard simd_distance(barrier.centre, state.position) < reach + barrier.boundingRadius,
                      let contact = ContactGeometry.contact(car: carBox(for: state), obstacle: barrier,
                                                            carCameFrom: previous.position)
                else { continue }
                touched = true

                let centre = state.position
                let push = contact.depth - Self.slop
                if push > 0 { state.position += contact.normal * push }

                for point in contact.points {
                    applyWallImpulse(state: &state, offset: point.position - centre,
                                     normal: contact.normal, tuning: tuning)
                }
            }
            if !touched { break }
        }
    }

    private func applyWallImpulse(state: inout VehicleState, offset: SIMD2<Float>,
                                  normal: SIMD2<Float>, tuning: VehicleTuning) {
        let arm = Plane2D.perp(offset)
        let inverseMass = 1 / max(tuning.mass, 1e-3)
        let inverseInertia = 1 / max(tuning.yawInertia, 1e-6)

        let closing = simd_dot(state.velocity + state.yawRate * arm, normal)
        guard closing < 0 else { return }
        barrierImpact = max(barrierImpact, -closing)
        stepImpact = max(stepImpact, -closing)

        let armNormal = simd_dot(arm, normal)
        let bounce = CourseSpec.Barrier.restitution * smoothstep(0.15, 0.6, -closing)
        let normalImpulse = -(1 + bounce) * closing / (inverseMass + armNormal * armNormal * inverseInertia)
        state.velocity += normal * (normalImpulse * inverseMass)
        state.yawRate += normalImpulse * armNormal * inverseInertia

        let tangent = Plane2D.perp(normal)
        let armTangent = simd_dot(arm, tangent)
        let sliding = simd_dot(state.velocity + state.yawRate * arm, tangent)
        let limit = CourseSpec.Barrier.friction * normalImpulse
        let frictionImpulse = min(max(-sliding / (inverseMass + armTangent * armTangent * inverseInertia),
                                      -limit), limit)
        state.velocity += tangent * (frictionImpulse * inverseMass)
        state.yawRate += frictionImpulse * armTangent * inverseInertia
    }

    // MARK: - Cones and tyres

    private func resolveLooseProps(state: inout VehicleState, tuning: VehicleTuning, dt: Float) {
        guard !looseProps.isEmpty else { return }
        let inverseMass = 1 / max(tuning.mass, 1e-3)
        let inverseInertia = 1 / max(tuning.yawInertia, 1e-6)
        let reach = simd_length(carHalfExtents)
        let roof = carHeight * 0.9

        for index in looseProps.indices {
            var prop = looseProps[index]
            let drift = prop.velocity * dt
            for circle in prop.circles.indices {
                prop.circles[circle].x += drift.x
                prop.circles[circle].y += drift.y
            }
            defer { looseProps[index] = prop }
            guard prop.lowestPoint < roof else { continue }
            let inversePropMass = 1 / max(prop.mass, 1e-3)

            let car = carBox(for: state)
            for circle in prop.circles {
                let centre = SIMD2(circle.x, circle.y)
                guard simd_distance(centre, car.centre) < reach + circle.z,
                      let hit = ContactGeometry.contact(car: car, circle: centre, radius: circle.z)
                else { continue }

                if prop.kind == .cone { stepConeContact = true }
                let normal = hit.normal
                let arm = Plane2D.perp(hit.point - state.position)
                let closing = simd_dot(prop.velocity - (state.velocity + state.yawRate * arm), normal)

                // What the two should be doing apart afterwards: a rebound off
                // a real hit, and a gentle shove out for a prop that is merely
                // inside the car (a cone lying where it parked, say).
                let rebound = closing < 0 ? -prop.restitution * closing : 0
                let easeOut = min(Self.separationRate * max(hit.depth - Self.slop, 0) / dt, 0.5)
                let target = max(rebound, easeOut)
                guard closing < target else { continue }
                stepImpact = max(stepImpact, -closing)
                switch prop.kind {
                case .tyre:             tyreImpact = max(tyreImpact, -closing)
                case .cone, .barrier:   coneImpact = max(coneImpact, -closing)
                }

                let armNormal = simd_dot(arm, normal)
                let impulse = (target - closing)
                    / (inversePropMass + inverseMass + armNormal * armNormal * inverseInertia)
                prop.velocity += normal * (impulse * inversePropMass)
                state.velocity -= normal * (impulse * inverseMass)
                state.yawRate -= impulse * armNormal * inverseInertia

                // A glancing blow sends the prop off sideways.
                let tangent = Plane2D.perp(normal)
                let armTangent = simd_dot(arm, tangent)
                let sliding = simd_dot(prop.velocity - (state.velocity + state.yawRate * arm), tangent)
                let limit = prop.friction * impulse
                let frictionImpulse = min(max(-sliding / (inversePropMass + inverseMass
                                                          + armTangent * armTangent * inverseInertia),
                                              -limit), limit)
                prop.velocity += tangent * (frictionImpulse * inversePropMass)
                state.velocity -= tangent * (frictionImpulse * inverseMass)
                state.yawRate -= frictionImpulse * armTangent * inverseInertia

                prop.impulse += normal * impulse + tangent * frictionImpulse
                prop.impulseMoment += hit.point * impulse
                prop.impulseWeight += impulse
                // One contact per prop per step; the rest of its circles are
                // the same prop.
                break
            }
        }
    }
}

private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}
