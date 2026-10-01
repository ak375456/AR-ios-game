//
//  CourseSpec.swift
//  vr
//
//  What a course can be built from, and how big and heavy each piece is.
//

import Foundation
import simd

/// What a course is built from.
enum PropKind: String, CaseIterable, Identifiable, Hashable {
    case cone
    case barrier
    case tyre

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cone:    return "Cone"
        case .barrier: return "Barrier"
        case .tyre:    return "Tyre"
        }
    }

    /// Knocked about by the car and left to RealityKit's physics, rather
    /// than fixed in place.
    var isLoose: Bool { self != .barrier }
}

/// One placed prop, as the player laid it out.
///
/// This is the *design*: where the prop was put, not where it is now. A cone
/// the car has knocked across the room still has its layout here, which is
/// what resetting and editing put it back to.
struct PropLayout: Identifiable, Hashable {
    let id: UUID
    var kind: PropKind
    /// Rendered metres on the stage's ground plane: `x` is the stage's X and
    /// `y` its Z, exactly as `VehicleState.position` is.
    var position: SIMD2<Float>
    /// Radians about the stage's up axis, the same convention as a car heading.
    var yaw: Float

    init(id: UUID = UUID(), kind: PropKind, position: SIMD2<Float>, yaw: Float) {
        self.id = id
        self.kind = kind
        self.position = position
        self.yaw = yaw
    }

    /// What the prop covers on the floor, for placement checks.
    var footprint: Footprint2D {
        switch kind {
        case .cone:
            return .circle(centre: position, radius: CourseSpec.Cone.footprintRadius)
        case .barrier:
            return .box(OrientedBox2D(centre: position,
                                      halfExtents: SIMD2(CourseSpec.Barrier.length, CourseSpec.Barrier.baseWidth) / 2,
                                      angle: yaw))
        case .tyre:
            return .circle(centre: position, radius: CourseSpec.Tyre.radius)
        }
    }
}

/// Sizes, masses and limits.
///
/// Everything is in *rendered* metres and kilograms, at the same 1:10 the cars
/// are placed at (see `SimulationScale`), so every car meets the same props:
/// the cars already differ in size the way the vehicles they depict do, and a
/// cone that grew with the car would make a van's course look like a hatch's.
enum CourseSpec {

    /// A course is a handful of props, not a level editor. The cap keeps the
    /// physics and the per-step contact work bounded on an iPhone 15 while it
    /// is also drawing smoke, skid marks and the instruments, and recording.
    static let maxProps = 24

    /// How far from the stage's floor, in metres, a surface can be and still
    /// count as the same floor.
    static let sameSurfaceTolerance: Float = 0.03

    /// Clear air left between a prop and the car, or another prop, when
    /// placing. Just enough that nothing starts the run already touching.
    static let carClearance: Float = 0.015
    static let propClearance: Float = 0.004

    enum Cone {
        /// A standard 70 cm road cone.
        static let height: Float = 0.070
        /// The heptagonal base plate, for placement.
        static let footprintRadius: Float = 0.030
        /// What a bumper actually meets: the shell just above the base plate.
        /// Smaller than the footprint on purpose — the plate is 5 mm tall and
        /// sits under a car's overhang, and a collision circle the size of the
        /// plate would register hits the player could see had missed.
        static let contactRadius: Float = 0.021
        /// Light next to any car (0.8–4.4 kg), so a hit costs the car a few
        /// per cent of its speed rather than stopping it.
        static let mass: Float = 0.10
        /// Real cones carry their weight in the base, which is why they rock
        /// when brushed and only go over when properly hit.
        static let centreOfMassHeight: Float = 0.016
        static let friction: Float = 0.55
        static let restitution: Float = 0.12
        /// Restitution of the car–cone impact itself, as the solver sees it.
        static let impactRestitution: Float = 0.15
        static let impactFriction: Float = 0.3
    }

    enum Tyre {
        /// A 70 cm tyre lying flat. That is a real size (a 255/55 R19), and it
        /// is the median wheel on the cars in the garage — measured from the
        /// models, 5.0 to 10.8 cm at game scale — so it reads as the same kind
        /// of tyre the cars run on rather than a toy beside them.
        static let diameter: Float = 0.070
        /// The model's own proportions: 19.3 cm tall for every 63 cm across.
        static let height: Float = 0.0214
        static var radius: Float { diameter / 2 }
        /// Just inside the tread, where its rounded shoulder meets a bumper.
        static let contactRadius: Float = 0.0335
        /// Several times a cone: a tyre shoves the car noticeably harder, but
        /// it is still loose, so it is never a wall.
        static let mass: Float = 0.20
        /// Rubber on the floor grips, so a hit tyre skids and spins to a stop
        /// quickly instead of skating off.
        static let friction: Float = 0.85
        static let restitution: Float = 0.3
        /// Rubber gives a livelier knock than a plastic cone.
        static let impactRestitution: Float = 0.3
        static let impactFriction: Float = 0.45
    }

    enum Barrier {
        /// A 2.4 m water-filled race barrier: long enough to make a wall of in
        /// a few pieces, short enough to fit round a room.
        static let length: Float = 0.24
        static let height: Float = 0.075
        static let baseWidth: Float = 0.056
        static let topWidth: Float = 0.019
        /// Width the car collides with. Between the toe (which the tyres meet)
        /// and the sloped face (which the bodywork meets), so contact happens
        /// within a few millimetres of where it visibly should.
        static let contactWidth: Float = 0.048
        /// Painted plastic against bodywork: low, so a car glancing off a
        /// barrier scrapes along it instead of being snatched to a stop.
        static let friction: Float = 0.22
        /// A little give on a hard hit, none on a gentle one.
        static let restitution: Float = 0.2
    }

    enum Ground {
        /// The invisible floor the cones land on. Much larger than any room,
        /// so a cone thrown clear of the detected area still lands on the
        /// real floor's plane instead of falling forever.
        static let halfSize: Float = 6
        static let friction: Float = 0.7
        static let restitution: Float = 0.08
    }

    /// A cone further than this from the stage, or this far below it, has
    /// left the room and is put away until the next reset.
    static let lostPropDistance: Float = 5
    static let lostPropDepth: Float = -0.25
}
