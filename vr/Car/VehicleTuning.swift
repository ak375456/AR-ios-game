//
//  VehicleTuning.swift
//  vr
//
//  Every number the vehicle model reads, in one documented place.
//

import Foundation

/// The broad kind of vehicle a model represents. Picking a class sets the
/// starting point for mass, power and grip; the exact numbers are then scaled
/// by the geometry actually measured from that car's mesh, so two cars with
/// visibly different proportions never end up driving identically.
enum CarClass: String, Hashable, Codable {
    case compact
    case sedan
    case sports
    case supercar
    case drift
    case offroad
    case van
    case truck
    case openWheel
    case classic
    case novelty

    /// Human-readable label for the garage.
    var label: String {
        switch self {
        case .compact:   return "Compact"
        case .sedan:     return "Sedan"
        case .sports:    return "Sports"
        case .supercar:  return "Supercar"
        case .drift:     return "Drift"
        case .offroad:   return "Off-road"
        case .van:       return "Van"
        case .truck:     return "Truck"
        case .openWheel: return "Open wheel"
        case .classic:   return "Classic"
        case .novelty:   return "Novelty"
        }
    }

    /// Reference figures for a car 0.42 m long. Everything else is derived.
    ///
    /// `grip` values are friction coefficients. They sit below real tyre
    /// figures on purpose: these cars are roughly 1:10 scale but gravity is
    /// not, so a full-size coefficient would make them physically unable to
    /// slide at the speeds they actually travel. See the note in
    /// `VehicleDynamics` about simulation scale.
    var reference: Reference {
        switch self {
        case .compact:
            return Reference(mass: 1.30, topSpeed: 1.55, acceleration: 2.1,
                             frontGrip: 0.78, rearGrip: 0.74, steer: 30, handbrake: 0.30)
        case .sedan:
            return Reference(mass: 1.60, topSpeed: 1.65, acceleration: 2.0,
                             frontGrip: 0.84, rearGrip: 0.82, steer: 27, handbrake: 0.30)
        case .sports:
            return Reference(mass: 1.45, topSpeed: 2.05, acceleration: 2.9,
                             frontGrip: 0.98, rearGrip: 0.92, steer: 25, handbrake: 0.26)
        case .supercar:
            return Reference(mass: 1.55, topSpeed: 2.30, acceleration: 3.4,
                             frontGrip: 1.05, rearGrip: 0.98, steer: 23, handbrake: 0.24)
        case .drift:
            return Reference(mass: 1.35, topSpeed: 1.80, acceleration: 2.6,
                             frontGrip: 0.90, rearGrip: 0.58, steer: 34, handbrake: 0.28)
        case .offroad:
            return Reference(mass: 2.05, topSpeed: 1.50, acceleration: 1.9,
                             frontGrip: 0.74, rearGrip: 0.72, steer: 30, handbrake: 0.32)
        case .van:
            return Reference(mass: 1.95, topSpeed: 1.45, acceleration: 1.7,
                             frontGrip: 0.70, rearGrip: 0.68, steer: 28, handbrake: 0.32)
        case .truck:
            return Reference(mass: 2.30, topSpeed: 1.50, acceleration: 1.8,
                             frontGrip: 0.70, rearGrip: 0.66, steer: 26, handbrake: 0.30)
        case .openWheel:
            return Reference(mass: 1.05, topSpeed: 2.45, acceleration: 3.6,
                             frontGrip: 1.22, rearGrip: 1.18, steer: 20, handbrake: 0.40)
        case .classic:
            return Reference(mass: 1.85, topSpeed: 1.35, acceleration: 1.6,
                             frontGrip: 0.66, rearGrip: 0.60, steer: 28, handbrake: 0.26)
        case .novelty:
            return Reference(mass: 1.15, topSpeed: 1.60, acceleration: 2.3,
                             frontGrip: 0.72, rearGrip: 0.60, steer: 32, handbrake: 0.22)
        }
    }

    /// The engine and gearbox this class of car is built around.
    ///
    /// Ratios themselves are not listed here: `VehicleTuning.make` builds the
    /// set from `gearCount` and `spread` and then derives the final drive from
    /// the car's own top speed and wheel radius, so a class can be given an
    /// extra gear without anybody having to recompute anything.
    var transmission: TransmissionReference {
        switch self {
        case .compact:
            return TransmissionReference(gearCount: 5, spread: 1.25, redlineRPM: 6400,
                                         idleRPM: 820, peakTorqueFraction: 0.64,
                                         torqueAtRedline: 0.82, shiftDuration: 0.10)
        case .sedan:
            return TransmissionReference(gearCount: 5, spread: 1.25, redlineRPM: 6200,
                                         idleRPM: 780, peakTorqueFraction: 0.60,
                                         torqueAtRedline: 0.80, shiftDuration: 0.10)
        case .sports:
            return TransmissionReference(gearCount: 6, spread: 1.21, redlineRPM: 7400,
                                         idleRPM: 900, peakTorqueFraction: 0.72,
                                         torqueAtRedline: 0.88, shiftDuration: 0.07)
        case .supercar:
            return TransmissionReference(gearCount: 6, spread: 1.21, redlineRPM: 8200,
                                         idleRPM: 950, peakTorqueFraction: 0.76,
                                         torqueAtRedline: 0.91, shiftDuration: 0.05)
        case .drift:
            return TransmissionReference(gearCount: 5, spread: 1.23, redlineRPM: 7000,
                                         idleRPM: 900, peakTorqueFraction: 0.70,
                                         torqueAtRedline: 0.86, shiftDuration: 0.08)
        case .offroad:
            return TransmissionReference(gearCount: 5, spread: 1.26, redlineRPM: 4800,
                                         idleRPM: 700, peakTorqueFraction: 0.50,
                                         torqueAtRedline: 0.68, shiftDuration: 0.11)
        case .van:
            return TransmissionReference(gearCount: 5, spread: 1.26, redlineRPM: 4600,
                                         idleRPM: 700, peakTorqueFraction: 0.48,
                                         torqueAtRedline: 0.66, shiftDuration: 0.12)
        case .truck:
            return TransmissionReference(gearCount: 5, spread: 1.27, redlineRPM: 4200,
                                         idleRPM: 650, peakTorqueFraction: 0.45,
                                         torqueAtRedline: 0.64, shiftDuration: 0.12)
        case .openWheel:
            return TransmissionReference(gearCount: 6, spread: 1.19, redlineRPM: 9800,
                                         idleRPM: 1400, peakTorqueFraction: 0.80,
                                         torqueAtRedline: 0.94, shiftDuration: 0.04)
        case .classic:
            return TransmissionReference(gearCount: 4, spread: 1.32, redlineRPM: 5200,
                                         idleRPM: 700, peakTorqueFraction: 0.56,
                                         torqueAtRedline: 0.74, shiftDuration: 0.13)
        case .novelty:
            return TransmissionReference(gearCount: 4, spread: 1.30, redlineRPM: 6000,
                                         idleRPM: 850, peakTorqueFraction: 0.66,
                                         torqueAtRedline: 0.84, shiftDuration: 0.09)
        }
    }

    /// The handful of gearbox figures that differ between classes.
    struct TransmissionReference {
        let gearCount: Int
        /// Step between one gear and the next. The whole set is this stepped
        /// down from first, so the spread also sets how much more force the
        /// lowest gear has than the highest.
        let spread: Float
        let redlineRPM: Float
        let idleRPM: Float
        let peakTorqueFraction: Float
        let torqueAtRedline: Float
        let shiftDuration: Float
    }

    struct Reference {
        /// Kilograms, for a 0.42 m car.
        let mass: Float
        /// Metres per second.
        let topSpeed: Float
        /// Metres per second squared at a standstill.
        let acceleration: Float
        /// Friction coefficients.
        let frontGrip: Float
        let rearGrip: Float
        /// Maximum front-wheel angle in degrees.
        let steer: Float
        /// Fraction of rear grip left when the handbrake is fully applied.
        let handbrake: Float
    }
}

/// The full parameter set for one car.
///
/// Built by `VehicleTuning.make` from the car's class plus the geometry
/// measured from its mesh, so wheelbase, track and wheel size always match the
/// model the player is looking at.
struct VehicleTuning: Hashable {

    // MARK: Geometry (metres)

    /// Axle to axle.
    var wheelBase: Float
    /// Centre of mass to the front axle.
    var frontAxleToCG: Float
    /// Centre of mass to the rear axle.
    var rearAxleToCG: Float
    /// Left wheel to right wheel.
    var trackWidth: Float
    /// Rolling radius of one wheel.
    var wheelRadius: Float

    // MARK: Mass

    /// Kilograms.
    var mass: Float
    /// Yaw moment of inertia, kg·m².
    var yawInertia: Float
    /// Resistance to rotation, N·m per rad/s. Stands in for the yaw damping a
    /// lumped two-axle model under-represents, and is what lets a driver catch
    /// a slide instead of watching it become a spin.
    var yawDamping: Float

    // MARK: Longitudinal

    /// Newtons at full throttle.
    var engineForce: Float
    /// Newtons at full brake, shared front and rear.
    var brakeForce: Float
    /// Reverse is deliberately weaker than forward drive.
    var reverseForceScale: Float = 0.55
    /// Constant retarding force while rolling, newtons.
    var rollingResistance: Float
    /// Quadratic drag, newtons per (m/s)².
    var dragCoefficient: Float
    /// The speed the above numbers are balanced to produce, m/s.
    var topSpeed: Float
    /// Fraction of braking applied to the front axle.
    var frontBrakeBias: Float = 0.6

    // MARK: Tyres

    /// Peak friction coefficient at each axle.
    var frontGrip: Float
    var rearGrip: Float
    /// Newtons of lateral force per radian of slip, before saturation.
    var frontCorneringStiffness: Float
    var rearCorneringStiffness: Float
    /// Fraction of rear grip remaining with the handbrake fully applied.
    var handbrakeGripScale: Float
    /// Extra rear braking force from the handbrake, newtons.
    var handbrakeForce: Float
    /// How quickly grip returns after the handbrake is released, per second.
    var handbrakeReleaseRate: Float = 3.5

    // MARK: Drivetrain

    /// Engine, gearbox and the rules that pick a gear. Everything to do with
    /// how the car pulls in a given gear is in here, and nowhere else.
    var transmission: TransmissionTuning

    // MARK: Steering

    /// Maximum front-wheel angle at a standstill, radians.
    var maxSteerAngle: Float
    /// How fast the wheels swing towards the requested angle, radians/second.
    var steerRate: Float = 4.2
    /// Fraction of the steering lock given up at top speed.
    var steerSpeedReduction: Float = 0.45

    // MARK: Derived

    /// Static vertical load on each axle, newtons.
    var frontAxleLoad: Float { mass * 9.81 * rearAxleToCG / max(wheelBase, 0.001) }
    var rearAxleLoad: Float { mass * 9.81 * frontAxleToCG / max(wheelBase, 0.001) }

    /// Builds a consistent parameter set for one car.
    ///
    /// - Parameters:
    ///   - carClass: what kind of vehicle this is.
    ///   - length: the car's real length once placed, in metres.
    ///   - wheelBase: measured axle-to-axle distance, metres.
    ///   - trackWidth: measured left-to-right wheel distance, metres.
    ///   - wheelRadius: measured rolling radius, metres.
    ///   - rearBias: 0.5 puts the centre of mass midway between the axles;
    ///     higher values move it rearwards, which makes the car more willing
    ///     to rotate.
    ///   - yawInertiaScale: compensation for running a 1:10 car under 1:1
    ///     gravity. Lower values make the car snappier and easier to spin.
    static func make(
        carClass: CarClass,
        length: Float,
        wheelBase: Float,
        trackWidth: Float,
        wheelRadius: Float,
        rearBias: Float = 0.48,
        yawInertiaScale: Float = 5.0
    ) -> VehicleTuning {
        let reference = carClass.reference

        // Mass scales with volume, so a longer car of the same class is heavier.
        let lengthRatio = max(length, 0.05) / 0.42
        let mass = reference.mass * pow(lengthRatio, 3)

        let base = max(wheelBase, 0.05)
        let track = max(trackWidth, 0.04)
        // 1.25 accounts for mass sitting outside a uniform box.
        let geometricInertia = mass * (base * base + track * track) / 12 * 1.25
        // ...then scaled up. Angular acceleration goes as 1/length, so a 1:10
        // car under full-size gravity rotates roughly an order of magnitude
        // faster than the real thing and simply spins on the spot. Raising the
        // yaw inertia is the cheapest way to put the rotational response back
        // in a range a person can drive. See VehicleDynamics for the note on
        // simulation scale.
        let yawInertia = geometricInertia * yawInertiaScale

        let engineForce = mass * reference.acceleration
        let rollingResistance = mass * 0.45
        let topSpeed = reference.topSpeed
        // Balance drag so full throttle settles exactly at the quoted top speed.
        let drag = max(engineForce - rollingResistance, 0.05) / (topSpeed * topSpeed)

        let transmission = makeTransmission(carClass: carClass,
                                            wheelRadius: max(wheelRadius, 0.005),
                                            topSpeed: topSpeed,
                                            engineForce: engineForce)

        let frontLoad = mass * 9.81 * (1 - rearBias)
        let rearLoad = mass * 9.81 * rearBias
        // Peak slip lands near 6-7 degrees, which is where real tyres peak too.
        let stiffnessRatio: Float = 9

        return VehicleTuning(
            wheelBase: base,
            frontAxleToCG: base * rearBias,
            rearAxleToCG: base * (1 - rearBias),
            trackWidth: track,
            wheelRadius: max(wheelRadius, 0.005),
            mass: mass,
            yawInertia: yawInertia,
            yawDamping: yawInertia * 1.25,
            engineForce: engineForce,
            brakeForce: engineForce * 1.55,
            rollingResistance: rollingResistance,
            dragCoefficient: drag,
            topSpeed: topSpeed,
            frontGrip: reference.frontGrip,
            rearGrip: reference.rearGrip,
            frontCorneringStiffness: reference.frontGrip * frontLoad * stiffnessRatio,
            rearCorneringStiffness: reference.rearGrip * rearLoad * stiffnessRatio,
            handbrakeGripScale: reference.handbrake,
            handbrakeForce: engineForce * 0.55,
            transmission: transmission,
            maxSteerAngle: reference.steer * .pi / 180
        )
    }

    /// Builds the gearbox for one car.
    ///
    /// Two of the numbers are *derived* rather than typed, and they are the two
    /// that keep the gearbox honest about the scale the cars are rendered at:
    ///
    /// - **Final drive** is whatever makes top gear sit at
    ///   `topGearRedlineFraction` of the redline when the car is doing its
    ///   quoted top speed. Top gear therefore always covers the car's whole
    ///   speed range, whatever wheels the model turned out to have, and the
    ///   car runs out of speed because of drag rather than because of the rev
    ///   limiter.
    /// - **Peak drive force** is scaled so that top gear at the car's top speed
    ///   delivers exactly the force the old flat-force model produced at every
    ///   speed. That is the single condition that leaves every car's top speed
    ///   where it was; lower gears then multiply that force by their ratio, and
    ///   the rear tyres decide how much of it reaches the ground.
    private static func makeTransmission(carClass: CarClass,
                                         wheelRadius: Float,
                                         topSpeed: Float,
                                         engineForce: Float) -> TransmissionTuning {
        let reference = carClass.transmission
        var transmission = TransmissionTuning.baseline

        transmission.redlineRPM = reference.redlineRPM
        transmission.idleRPM = reference.idleRPM
        transmission.peakTorqueFraction = reference.peakTorqueFraction
        transmission.torqueAtRedline = reference.torqueAtRedline
        transmission.shiftDuration = reference.shiftDuration

        // Top gear is fixed; every gear below it is one more step up.
        let top = TransmissionTuning.topGearRatio
        let count = max(reference.gearCount, 1)
        transmission.forwardRatios = (0..<count).map { index in
            top * pow(reference.spread, Float(count - 1 - index))
        }

        // Reverse is geared so the rev limiter — not an arbitrary clamp — is
        // what stops it, at about the speed the old flat reverse force used to
        // settle at.
        transmission.reverseRatio = top
            / (TransmissionTuning.topGearRedlineFraction * TransmissionTuning.reverseRedlineFraction)

        let wheelRadiansAtRedline = topSpeed / TransmissionTuning.topGearRedlineFraction
            / max(wheelRadius, 1e-4)
        let engineRadiansAtRedline = transmission.redlineRPM * 2 * .pi / 60
        transmission.finalDrive = engineRadiansAtRedline / max(wheelRadiansAtRedline, 1e-4) / top

        let torqueAtTopSpeed = transmission.normalisedTorque(
            atRPM: transmission.redlineRPM * TransmissionTuning.topGearRedlineFraction)
        transmission.peakDriveForce = engineForce / max(torqueAtTopSpeed, 0.05)

        return transmission
    }
}
