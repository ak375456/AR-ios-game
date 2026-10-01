//
//  CourseGeometry.swift
//  vr
//
//  Ground-plane shapes for the course: overlap tests and contact manifolds.
//

import Foundation
import simd

// Everything here lives on the stage's ground plane, in rendered metres, with
// `x` along the stage's X and `y` along its Z — the plane and the convention
// `VehicleState` already uses. Angles follow the car's heading: turning by
// `angle` about +Y takes an entity's local +X to `axisX(angle)` and its local
// +Z to `axisZ(angle)`.

enum Plane2D {

    /// Where an entity's local +X points once turned by `angle` about +Y.
    static func axisX(_ angle: Float) -> SIMD2<Float> { SIMD2(cos(angle), -sin(angle)) }

    /// Where an entity's local +Z points once turned by `angle` about +Y.
    static func axisZ(_ angle: Float) -> SIMD2<Float> { SIMD2(sin(angle), cos(angle)) }

    /// The velocity a unit yaw rate gives a point at `offset` from the centre
    /// of rotation. Positive yaw turns +Z towards +X, so this is the offset
    /// turned a quarter towards the car's left.
    static func perp(_ offset: SIMD2<Float>) -> SIMD2<Float> { SIMD2(offset.y, -offset.x) }
}

/// A rectangle on the floor.
struct OrientedBox2D: Equatable {
    var centre: SIMD2<Float>
    /// Half the size along the box's own X and Z.
    var halfExtents: SIMD2<Float>
    var angle: Float

    var axisX: SIMD2<Float> { Plane2D.axisX(angle) }
    var axisZ: SIMD2<Float> { Plane2D.axisZ(angle) }

    var corners: [SIMD2<Float>] {
        let x = axisX * halfExtents.x
        let z = axisZ * halfExtents.y
        return [centre + x + z, centre - x + z, centre - x - z, centre + x - z]
    }

    /// Smallest circle round the box, for cheap early-outs.
    var boundingRadius: Float { simd_length(halfExtents) }

    /// Half the box's shadow on a line through its centre.
    func radius(along axis: SIMD2<Float>) -> Float {
        halfExtents.x * abs(simd_dot(axisX, axis)) + halfExtents.y * abs(simd_dot(axisZ, axis))
    }

    func toLocal(_ point: SIMD2<Float>) -> SIMD2<Float> {
        let offset = point - centre
        return SIMD2(simd_dot(offset, axisX), simd_dot(offset, axisZ))
    }

    func toWorld(_ local: SIMD2<Float>) -> SIMD2<Float> {
        centre + axisX * local.x + axisZ * local.y
    }

    func contains(_ point: SIMD2<Float>, margin: Float = 0) -> Bool {
        let local = toLocal(point)
        return abs(local.x) <= halfExtents.x + margin && abs(local.y) <= halfExtents.y + margin
    }

    func expanded(by margin: Float) -> OrientedBox2D {
        OrientedBox2D(centre: centre, halfExtents: halfExtents + margin, angle: angle)
    }

    /// Separating-axis test.
    func overlaps(_ other: OrientedBox2D) -> Bool {
        let offset = other.centre - centre
        for axis in [axisX, axisZ, other.axisX, other.axisZ] {
            if abs(simd_dot(offset, axis)) >= radius(along: axis) + other.radius(along: axis) { return false }
        }
        return true
    }

    func overlaps(circle centre: SIMD2<Float>, radius: Float) -> Bool {
        let local = toLocal(centre)
        let clamped = simd_clamp(local, -halfExtents, halfExtents)
        return simd_length_squared(local - clamped) < radius * radius
    }
}

/// What a prop, or the car, covers on the floor.
enum Footprint2D: Equatable {
    case circle(centre: SIMD2<Float>, radius: Float)
    case box(OrientedBox2D)

    /// True if the two come closer than `margin`.
    func overlaps(_ other: Footprint2D, margin: Float) -> Bool {
        switch (self, other) {
        case let (.circle(a, ra), .circle(b, rb)):
            return simd_distance(a, b) < ra + rb + margin
        case let (.circle(c, r), .box(box)), let (.box(box), .circle(c, r)):
            return box.overlaps(circle: c, radius: r + margin)
        case let (.box(a), .box(b)):
            return a.expanded(by: margin).overlaps(b)
        }
    }

    /// Points that must all stand on detected floor for the prop to be safe
    /// to place: the centre and its outline.
    var supportPoints: [SIMD2<Float>] {
        switch self {
        case let .circle(centre, radius):
            return [centre] + (0..<6).map { index in
                let angle = Float(index) / 6 * 2 * .pi
                return centre + SIMD2(cos(angle), sin(angle)) * radius
            }
        case let .box(box):
            // Corners plus the middle of each long side, so a long barrier
            // cannot bridge a gap in the detected floor.
            let x = box.axisX * box.halfExtents.x
            let z = box.axisZ * box.halfExtents.y
            return [box.centre] + box.corners + [box.centre + z, box.centre - z, box.centre + x, box.centre - x]
        }
    }

    var centre: SIMD2<Float> {
        switch self {
        case let .circle(centre, _): return centre
        case let .box(box):          return box.centre
        }
    }
}

// MARK: - Contacts

/// Where two shapes touch, and how deeply.
struct ContactPoint {
    /// A point of the car's or the obstacle's outline inside the other one.
    var position: SIMD2<Float>
    var depth: Float
}

struct BoxContact {
    /// Unit normal pointing from the obstacle towards the car.
    var normal: SIMD2<Float>
    var points: [ContactPoint]
    var depth: Float { points.map(\.depth).max() ?? 0 }
}

enum ContactGeometry {

    /// Contact between the car and a fixed box, or `nil` if they are apart.
    ///
    /// Separating axes find the direction of least overlap; the edge of one box
    /// facing the other is then clipped against the face it has pushed into,
    /// which gives one point for a corner hit and two for a flat one. Two
    /// points are what let a car lie flat along a wall instead of rocking on
    /// one corner and then the other.
    ///
    /// `carCameFrom` is where the car was one step earlier. Along the
    /// obstacle's own axes the push-out goes back to *that* side, so however
    /// deep a fast corner gets in a single step it can never be pushed out
    /// through the far side of a thin barrier.
    static func contact(car: OrientedBox2D, obstacle: OrientedBox2D,
                        carCameFrom previous: SIMD2<Float>) -> BoxContact? {
        let offset = car.centre - obstacle.centre
        let cameFrom = previous - obstacle.centre

        struct Candidate {
            var axis: SIMD2<Float>
            var overlap: Float
            var onObstacle: Bool
        }
        var best: Candidate?
        let candidates: [(SIMD2<Float>, Bool)] = [(obstacle.axisX, true), (obstacle.axisZ, true),
                                                  (car.axisX, false), (car.axisZ, false)]
        for (axis, onObstacle) in candidates {
            let overlap = car.radius(along: axis) + obstacle.radius(along: axis) - abs(simd_dot(offset, axis))
            if overlap <= 0 { return nil }
            // The obstacle's faces are preferred when it is close: their normals
            // stay put while the car rotates, which keeps a slide along a wall
            // smooth instead of flicking between two nearly equal answers.
            let score = onObstacle ? overlap : overlap * 1.04 + 0.0005
            let bestScore = best.map { $0.onObstacle ? $0.overlap : $0.overlap * 1.04 + 0.0005 }
            if bestScore == nil || score < bestScore! {
                best = Candidate(axis: axis, overlap: overlap, onObstacle: onObstacle)
            }
        }
        guard let best else { return nil }

        var normal = best.axis
        if best.onObstacle {
            let side = simd_dot(cameFrom, best.axis)
            let now = simd_dot(offset, best.axis)
            if (abs(side) > 1e-4 ? side : now) < 0 { normal = -normal }
        } else if simd_dot(offset, best.axis) < 0 {
            normal = -normal
        }

        // The reference face belongs to whichever box owns the axis, and faces
        // the other box.
        let reference = best.onObstacle ? obstacle : car
        let incident = best.onObstacle ? car : obstacle
        let referenceNormal = best.onObstacle ? normal : -normal

        let faceDepth = reference.radius(along: referenceNormal)
        let faceCentre = reference.centre + referenceNormal * faceDepth
        let tangent = Plane2D.perp(referenceNormal)
        let faceHalfLength = reference.radius(along: tangent)

        // The incident box's face that looks most directly back at it.
        let faces: [(SIMD2<Float>, Float, Float)] = [
            (incident.axisX, incident.halfExtents.x, incident.halfExtents.y),
            (-incident.axisX, incident.halfExtents.x, incident.halfExtents.y),
            (incident.axisZ, incident.halfExtents.y, incident.halfExtents.x),
            (-incident.axisZ, incident.halfExtents.y, incident.halfExtents.x),
        ]
        let face = faces.min { simd_dot($0.0, referenceNormal) < simd_dot($1.0, referenceNormal) }!
        let edgeCentre = incident.centre + face.0 * face.1
        let edgeDirection = Plane2D.perp(face.0)
        var segment = [edgeCentre + edgeDirection * face.2, edgeCentre - edgeDirection * face.2]

        let along = simd_dot(faceCentre, tangent)
        segment = clip(segment, normal: tangent, offset: along + faceHalfLength)
        segment = clip(segment, normal: -tangent, offset: -along + faceHalfLength)

        var points: [ContactPoint] = []
        for point in segment {
            let separation = simd_dot(point - faceCentre, referenceNormal)
            if separation < 0 { points.append(ContactPoint(position: point, depth: -separation)) }
        }
        if points.isEmpty {
            // Numerically on the edge of touching: one point, midway.
            points = [ContactPoint(position: (car.centre + obstacle.centre) / 2, depth: best.overlap)]
        }
        return BoxContact(normal: normal, points: points)
    }

    /// Keeps the part of a segment on the inside of a line.
    private static func clip(_ segment: [SIMD2<Float>], normal: SIMD2<Float>, offset: Float) -> [SIMD2<Float>] {
        guard segment.count == 2 else { return segment }
        let a = segment[0], b = segment[1]
        let da = simd_dot(normal, a) - offset
        let db = simd_dot(normal, b) - offset
        var out: [SIMD2<Float>] = []
        if da <= 0 { out.append(a) }
        if db <= 0 { out.append(b) }
        if da * db < 0 {
            let t = da / (da - db)
            out.append(a + (b - a) * t)
        }
        return out
    }

    /// Contact between the car and a circle. The normal points from the car
    /// towards the circle; the point is on the car's outline.
    static func contact(car: OrientedBox2D, circle centre: SIMD2<Float>, radius: Float)
        -> (normal: SIMD2<Float>, point: SIMD2<Float>, depth: Float)? {
        let local = car.toLocal(centre)
        let half = car.halfExtents
        let clamped = simd_clamp(local, -half, half)
        let gap = local - clamped
        let distanceSquared = simd_length_squared(gap)

        if distanceSquared > 1e-10 {
            guard distanceSquared < radius * radius else { return nil }
            let distance = distanceSquared.squareRoot()
            let localNormal = gap / distance
            let normal = simd_normalize(car.axisX * localNormal.x + car.axisZ * localNormal.y)
            return (normal, car.toWorld(clamped), radius - distance)
        }

        // The centre is inside the car: out through the nearest side.
        let toSideX = half.x - abs(local.x)
        let toSideZ = half.y - abs(local.y)
        if toSideX < toSideZ {
            let sign: Float = local.x >= 0 ? 1 : -1
            return (car.axisX * sign, car.toWorld(SIMD2(half.x * sign, local.y)), toSideX + radius)
        } else {
            let sign: Float = local.y >= 0 ? 1 : -1
            return (car.axisZ * sign, car.toWorld(SIMD2(local.x, half.y * sign)), toSideZ + radius)
        }
    }
}
