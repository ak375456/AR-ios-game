//
//  SlalomPlanner.swift
//  vr
//
//  Lays out a row of cones for the car to weave through.
//

import Foundation
import simd

/// Works out where a slalom can go.
///
/// A slalom is a straight row of cones the car weaves through, so the numbers
/// that matter are the gap between cones — wide enough to swing round each
/// one — and the run-up before the first. Both are measured in car lengths:
/// the cars are all 1:10 but a Mini Hatch is shorter and tighter-turning than
/// a big 4x4, and spacing that suits one is a wall or a drag race for the other.
///
/// The planner never decides for itself what counts as floor. It is handed a
/// test for "a cone could stand here" — which checks the detected surface, the
/// car and every other prop — and only ever returns positions that passed it.
/// When there is less room than a full slalom needs it tries fewer, closer
/// cones, then other directions, and gives up below three: two cones are not a
/// slalom.
enum SlalomPlanner {

    static let preferredCount = 6
    static let minimumCount = 3

    /// Centre-to-centre gap, in car lengths. Two lengths leaves room to weave
    /// at speed; one and a half is still drivable with the handbrake.
    static let widestSpacing: Float = 2.1
    static let tightestSpacing: Float = 1.5
    /// Clear floor between the car and the first cone, in car lengths.
    static let runUp: Float = 1.0
    /// Never closer to the car than this, however short the car.
    static let minimumRunUp: Float = 0.3

    /// Straight ahead first, then gradually further round. The first direction
    /// that fits the most cones wins.
    static let directions: [Float] = [0, 0.35, -0.35, 0.8, -0.8, .pi / 2, -.pi / 2, .pi]

    struct Plan: Equatable {
        var positions: [SIMD2<Float>]
        /// Which way the row runs, so every cone's base can square up to it.
        var heading: Float
        var spacing: Float
    }

    enum Failure: Error, Equatable {
        /// Fewer than `minimumCount` free places left under the prop limit.
        case courseFull
        /// Not enough detected, empty floor anywhere near the car.
        case noRoom
    }

    static func plan(carPosition: SIMD2<Float>, carHeading: Float,
                     carHalfExtents: SIMD2<Float>, carLength: Float,
                     capacity: Int, canStand: (SIMD2<Float>) -> Bool) -> Result<Plan, Failure> {
        let most = min(preferredCount, capacity)
        guard most >= minimumCount else { return .failure(.courseFull) }

        let spacings = stride(from: widestSpacing, through: tightestSpacing - 1e-4, by: -0.15)
            .map { $0 * carLength }

        for count in stride(from: most, through: minimumCount, by: -1) {
            for turn in directions {
                let heading = carHeading + turn
                let direction = Plane2D.axisZ(heading)
                // Measured from the side of the car the row leaves from, so a
                // sideways row does not start inside the car's length.
                let edge = carHalfExtents.x * abs(simd_dot(Plane2D.axisX(carHeading), direction))
                    + carHalfExtents.y * abs(simd_dot(Plane2D.axisZ(carHeading), direction))
                let first = edge + max(runUp * carLength, minimumRunUp)

                for spacing in spacings {
                    let positions = (0..<count).map { index in
                        carPosition + direction * (first + Float(index) * spacing)
                    }
                    if positions.allSatisfy(canStand) {
                        return .success(Plan(positions: positions, heading: heading, spacing: spacing))
                    }
                }
            }
        }
        return .failure(.noRoom)
    }
}
