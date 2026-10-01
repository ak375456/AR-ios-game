//
//  SimulationScale.swift
//  vr
//
//  The one conversion between the car on the floor and the car it stands for.
//

import Foundation

/// How rendered AR metres relate to the metres of the road the car is
/// pretending to drive on.
///
/// **Why a conversion exists at all.** Everything in the simulation —
/// positions, velocities, forces, wheel radii, grip — is in *rendered* metres,
/// the metres ARKit lays on the room's floor. A placed car is 0.36–0.52 m long
/// (`CarDefinition.length`), because a car you drive round a rug has to fit on
/// one. The vehicles those models depict are 3.6–5.2 m long. The models are
/// therefore placed at **1:10**, and the number below is the whole of that
/// convention:
///
///     1 rendered metre  ==  10 full-size metres
///
/// **What uses it.** Only the read-outs: the speedometer and anything else
/// that quotes a number to the player. The simulation itself never multiplies
/// by it. Driving, drifting, wheel rotation and the skid and smoke effects all
/// stay in rendered metres, which is the only way their thresholds can keep
/// meaning what they meant before there was a speedometer.
///
/// **Engine speed is exempt, and that is not an oversight.** Angular velocity
/// is scale-free: the wheel turns at `v / r`, and both the speed and the radius
/// are scaled by the same ten, so the rendered wheel and the full-size wheel
/// turn at exactly the same rate. Engine RPM is that rate multiplied by the
/// gearing, so the RPM the drivetrain computes from rendered units is already
/// the full-size engine's RPM. Nothing needs converting.
///
/// **What the speedometer is claiming.** It reads the speed of the full-size
/// car being simulated, not the speed of the model across the carpet. The
/// model really is crossing the room at a tenth of that — around 2 m/s at the
/// top end — and there is no GPS or device motion involved anywhere: every
/// figure comes from `VehicleState.velocity`.
enum SimulationScale {

    /// The scale the cars are placed at. See the note above.
    static let fullSizeMetresPerRenderedMetre: Float = 10

    /// Converts a rendered speed into the speed the driver is meant to read.
    static func displaySpeed(renderedMetresPerSecond speed: Float, unit: SpeedUnit) -> Float {
        speed * fullSizeMetresPerRenderedMetre * unit.perMetrePerSecond
    }
}

/// How the player wants the speed written down.
enum SpeedUnit: String, CaseIterable, Codable, Identifiable {
    case kilometresPerHour
    case milesPerHour

    var id: String { rawValue }

    /// What goes next to the number.
    var abbreviation: String {
        switch self {
        case .kilometresPerHour: return "km/h"
        case .milesPerHour:      return "mph"
        }
    }

    /// Multiplier from full-size metres per second.
    var perMetrePerSecond: Float {
        switch self {
        case .kilometresPerHour: return 3.6
        case .milesPerHour:      return 2.236936
        }
    }
}

extension SpeedUnit {
    /// The player's saved choice, for text built away from the settings
    /// screen, such as a mission's target speed. Same key as
    /// `ControlSettings.speedUnit`.
    static var preferred: SpeedUnit {
        SpeedUnit(rawValue: UserDefaults.standard.string(forKey: "drive.speedUnit") ?? "") ?? .kilometresPerHour
    }

    /// The rendered speed that reads `kmh` on the speedometer.
    static func renderedSpeed(kmh: Double) -> Double {
        kmh / Double(SimulationScale.displaySpeed(renderedMetresPerSecond: 1, unit: .kilometresPerHour))
    }
}
