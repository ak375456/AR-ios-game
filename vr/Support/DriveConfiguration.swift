//
//  DriveConfiguration.swift
//  vr
//
//  Settings that apply to every car. Per-car handling lives in CarCatalog.
//

import Foundation

enum DriveConfiguration {

    // MARK: - Simulation

    /// Below this speed the car counts as stopped and the brake becomes reverse.
    static let stoppedSpeedThreshold: Float = 0.02

    /// Frame deltas are clamped so a hitch or a resumed session cannot teleport
    /// the car across the room.
    static let maxTimeStep: Float = 1.0 / 20.0

    /// Sideways speed, as a fraction of forward speed, above which the car is
    /// treated as drifting for the on-screen indicator.
    static let driftThreshold: Float = 0.33

    // MARK: - Visual polish

    /// Peak body roll when cornering, in radians. Deliberately small.
    static let maxBodyRoll: Float = 3.0 * .pi / 180
    /// Peak body pitch under acceleration and braking, in radians.
    static let maxBodyPitch: Float = 1.8 * .pi / 180
    static let bodyLeanSmoothing: Float = 6.0

    // MARK: - Environment

    /// ARKit ambient intensity (lux) below which the user is warned about light.
    static let darkSceneThreshold: CGFloat = 120
    /// Hysteresis so the warning does not flicker.
    static let brightSceneThreshold: CGFloat = 220
}
