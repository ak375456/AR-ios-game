//
//  Drivetrain.swift
//  vr
//
//  Engine, gearbox and the rules that pick a gear.
//

import Foundation

/// Who chooses the forward gears.
enum TransmissionMode: String, CaseIterable, Codable, Identifiable {
    case automatic
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .manual:    return "Manual"
        }
    }
}

/// What is engaged.
///
/// Stored as one number so the ordering — R, N, 1, 2, … — is the same thing as
/// the order the shift buttons walk through.
struct Gear: Hashable {
    /// -1 reverse, 0 neutral, 1 and up the forward gears.
    var index: Int

    static let reverse = Gear(index: -1)
    static let neutral = Gear(index: 0)
    static func forward(_ number: Int) -> Gear { Gear(index: number) }

    var isReverse: Bool { index < 0 }
    var isNeutral: Bool { index == 0 }
    var isForward: Bool { index > 0 }

    /// What the instrument cluster prints.
    var label: String {
        if index < 0 { return "R" }
        if index == 0 { return "N" }
        return String(index)
    }
}

/// Why a requested shift did not happen, so the interface can say so.
enum ShiftRefusal: Hashable {
    /// Already in top gear, or already in reverse.
    case endOfTravel
    /// Reverse was asked for while the car is still moving forward.
    case tooFastForReverse
    /// The gear below would take the engine past the rev limiter.
    case wouldOverRev
}

/// Every number the drivetrain reads, in one place.
///
/// The ratios are ordinary gearbox ratios and are the numbers to edit when a
/// car should pull differently. Everything that depends on the scale the cars
/// are rendered at — the final drive, and the force one unit of engine torque
/// is worth — is *derived* in `VehicleTuning.make` from the car's own top
/// speed and wheel radius, so editing a ratio never breaks the car's top speed.
struct TransmissionTuning: Hashable {

    // MARK: Ratios

    /// First gear first. A close-ratio set: these cars cover a narrow speed
    /// range, so a road car's 4.4:1 spread between first and top would leave
    /// first useful for about a metre.
    var forwardRatios: [Float]
    /// Reverse, chosen in `make` so the rev limiter caps reverse at roughly the
    /// same speed the old flat reverse force used to.
    var reverseRatio: Float
    /// Derived: takes up whatever is left between the ratios above and the
    /// car's actual wheel radius and top speed.
    var finalDrive: Float

    // MARK: Engine

    var idleRPM: Float
    var redlineRPM: Float
    /// Where peak torque sits, as a fraction of the redline.
    var peakTorqueFraction: Float
    /// Normalised torque at the redline. Below 1 because the curve falls away
    /// past its peak, which is what makes holding a gear too long pointless.
    var torqueAtRedline: Float
    /// Floor under the normalised curve, so a lugging engine still pulls.
    var minimumTorqueFraction: Float
    /// Derived: newtons at the driven wheels in top gear at peak torque.
    /// Scaled so that top gear at the car's top speed produces exactly the
    /// force the car used to have at all speeds — which is how top speed comes
    /// out unchanged.
    var peakDriveForce: Float
    /// Reverse is deliberately weaker; this scales engine torque in reverse.
    var reverseTorqueScale: Float
    /// Engine braking at the redline with the throttle shut, as a fraction of
    /// peak engine torque.
    var engineBrakingFraction: Float
    /// RPM band over which the limiter fades torque out below the redline.
    var limiterRange: Float

    // MARK: Clutch

    /// There is no clutch pedal. Below the speed at which the engine would be
    /// at idle in the engaged gear, the gearbox slips for the driver and passes
    /// this fraction of the torque it otherwise would. Nothing can stall.
    var clutchSlipFloor: Float

    // MARK: Shifting

    /// How long drive is held back for while a gear goes home.
    var shiftDuration: Float
    /// How much drive survives the *start* of a shift, ramping back to all of
    /// it by the end. Not zero: these cars cover their whole speed range in
    /// about two seconds, so drag is nearly a match for the engine near the
    /// top, and cutting drive outright there drops the speedometer by ten
    /// km/h every time the gearbox changes its mind. A dip reads as a shift;
    /// a cliff reads as a fault.
    var shiftTorqueFloor: Float
    /// Shortest time between one shift finishing and the next starting.
    var minimumShiftInterval: Float
    /// Upshift RPM as a fraction of the redline, pinned at both ends of the
    /// throttle. Everything between is interpolated.
    var upshiftFractionOffThrottle: Float
    var upshiftFractionAtFullThrottle: Float
    /// How far into the rev limiter a slide has to push the engine before the
    /// gearbox will change gear anyway. Holding a gear through a drift is only
    /// right until the engine runs out of revs; past that, refusing to shift
    /// traps the car against the limiter and it simply stops accelerating.
    var limiterUpshiftFraction: Float
    /// Where a downshift is allowed to leave the engine, as a fraction of the
    /// upshift point for the gear being dropped into. Below 1, so the gearbox
    /// cannot land somewhere it would immediately want to shift back out of —
    /// this single number is the hysteresis.
    var downshiftLanding: Float
    /// How quickly the throttle the shift map reads catches up with the pedal.
    /// It rises fast, so flooring it downshifts, and falls slowly, so lifting
    /// off mid-corner does not upshift.
    var throttleRiseRate: Float
    var throttleFallRate: Float

    // MARK: Engagement rules

    /// Forward speed under which the automatic will swap between forward and
    /// reverse. Matches the threshold the pedals already used.
    var creepSpeed: Float
    /// Speed under which Manual will accept reverse. Roughly 5 km/h of
    /// full-size speed: fast enough to be reachable with a tap, slow enough
    /// that it is never a surprise.
    var reverseEngageSpeed: Float

    // MARK: Traction

    /// The most of the rear axle's dry grip that may ever reach the road, as a
    /// fraction of it.
    ///
    /// Not all of it, and not by accident: `availableLateral` shares one
    /// friction circle between driving and cornering, so an axle putting every
    /// newton it has into driving has nothing left to keep the back of the car
    /// in line. Pushed to 100% the drift class spends its whole life sideways
    /// at full lock, which is a different car from the one this app shipped.
    var tractionCeiling: Float
    /// How much of the ceiling is soft knee. Demand under the knee passes
    /// through untouched and demand above it is compressed into the rest, so a
    /// low gear asking for three times the grip available spins the wheels
    /// instead of firing the car across the room.
    var tractionSoftening: Float

    /// Sensible starting point for every car. `VehicleTuning.make` derives
    /// `finalDrive` and `peakDriveForce` per car and may override the rest.
    static let baseline = TransmissionTuning(
        forwardRatios: [2.90, 2.32, 1.86, 1.49, 1.19],
        reverseRatio: 2.25,
        finalDrive: 1,
        idleRPM: 850,
        redlineRPM: 6800,
        peakTorqueFraction: 0.70,
        torqueAtRedline: 0.86,
        minimumTorqueFraction: 0.15,
        peakDriveForce: 1,
        reverseTorqueScale: 0.55,
        engineBrakingFraction: 0.10,
        limiterRange: 350,
        clutchSlipFloor: 0.62,
        shiftDuration: 0.09,
        shiftTorqueFloor: 0.35,
        minimumShiftInterval: 0.22,
        upshiftFractionOffThrottle: 0.52,
        upshiftFractionAtFullThrottle: 0.92,
        limiterUpshiftFraction: 0.985,
        downshiftLanding: 0.82,
        throttleRiseRate: 9,
        throttleFallRate: 2.6,
        creepSpeed: 0.06,
        reverseEngageSpeed: 0.15,
        tractionCeiling: 0.94,
        tractionSoftening: 0.10
    )

    /// Top gear's own ratio. Every gear below it is a step up from here, and
    /// the final drive takes up the difference, so this number only sets where
    /// the printed ratios sit — not how the car pulls.
    static let topGearRatio: Float = 1.19

    /// Where in the rev range top gear sits when the car is at its top speed.
    /// Below 1 so the car is limited by drag rather than by the rev limiter at
    /// the top end, which stops the limiter chattering at full speed.
    static let topGearRedlineFraction: Float = 0.80
    /// Where the limiter stops reverse, as a fraction of the car's top speed.
    static let reverseRedlineFraction: Float = 0.66

    var topGear: Int { forwardRatios.count }

    /// Gearbox ratio for a gear. Neutral has none.
    func ratio(for gear: Gear) -> Float? {
        if gear.isNeutral { return nil }
        if gear.isReverse { return reverseRatio }
        let index = min(max(gear.index, 1), forwardRatios.count)
        return forwardRatios[index - 1]
    }

    /// Engine revolutions per minute of road speed, for a gear.
    func totalRatio(for gear: Gear) -> Float? {
        ratio(for: gear).map { $0 * finalDrive }
    }

    /// Normalised torque, 0...1, at an engine speed.
    ///
    /// A parabola through peak torque: flat enough in the middle that the car
    /// pulls everywhere, down at the redline so there is a reason to shift,
    /// and well down at idle so a standing start is a gentle roll rather than
    /// a launch.
    func normalisedTorque(atRPM rpm: Float) -> Float {
        let x = rpm / max(redlineRPM, 1)
        let span = max(1 - peakTorqueFraction, 0.05)
        let falloff = (1 - torqueAtRedline) / (span * span)
        let offset = x - peakTorqueFraction
        return max(1 - falloff * offset * offset, minimumTorqueFraction)
    }

    /// How much torque survives the rev limiter at an engine speed.
    func limiterFactor(atRPM rpm: Float) -> Float {
        guard limiterRange > 0 else { return rpm >= redlineRPM ? 0 : 1 }
        return min(max((redlineRPM - rpm) / limiterRange, 0), 1)
    }

    /// Engine RPM the gearing implies at a rendered forward speed.
    ///
    /// Rendered units are the right ones: `speed / wheelRadius` is an angular
    /// velocity, and the scale in `SimulationScale` cancels out of it, so this
    /// is the full-size engine's RPM without any conversion.
    func gearedRPM(renderedSpeed speed: Float, wheelRadius: Float, gear: Gear) -> Float {
        guard let total = totalRatio(for: gear), wheelRadius > 1e-5 else { return 0 }
        let wheelRPM = abs(speed) / wheelRadius * 60 / (2 * .pi)
        return wheelRPM * total
    }

    /// Rendered forward speed at which a gear reaches a given engine speed.
    func renderedSpeed(atRPM rpm: Float, wheelRadius: Float, gear: Gear) -> Float {
        guard let total = totalRatio(for: gear), total > 1e-5 else { return 0 }
        return rpm / total * (2 * .pi) / 60 * wheelRadius
    }
}

/// What one drivetrain update produced.
struct DrivetrainOutput {
    /// Signed force at the driven wheels, newtons; positive drives the car
    /// forwards. Not yet limited by grip — `VehicleDynamics` does that,
    /// because how much of it reaches the road is a tyre matter.
    var driveDemand: Float = 0
    /// Unsigned retarding force, newtons, from a shut throttle in gear.
    var engineBraking: Float = 0
    /// How much friction brake the pedals are asking for, 0...1, which is the
    /// share `VehicleDynamics` multiplies by `brakeForce`. It covers both the
    /// ordinary brake pedal and a pedal being held against the way the car is
    /// actually travelling.
    var brakeDemand: Float = 0
}

/// What the instrument cluster shows.
struct DrivetrainReadout: Equatable {
    var gear: Gear = .neutral
    var engineRPM: Float = 0
    var redlineRPM: Float = 1
    /// This car's tickover, so a stationary car's tachometer can show where the
    /// engine actually sits rather than dropping to zero.
    var idleRPM: Float = 0
    var isShifting: Bool = false
    /// Bumped every time a requested shift was turned down, so the interface
    /// can flash without having to subscribe to an event.
    var refusals: Int = 0
    var lastRefusal: ShiftRefusal?

    var revFraction: Float { min(max(engineRPM / max(redlineRPM, 1), 0), 1) }
}

/// The engine and gearbox.
///
/// It owns the gear, the engine speed and the shift timing, and turns a pedal
/// position into a force at the driven wheels. It deliberately knows nothing
/// about tyres: what it returns is *demand*, and `VehicleDynamics` decides how
/// much of that the rear axle can actually put down.
struct Drivetrain {

    var tuning: TransmissionTuning

    private(set) var gear: Gear = .neutral
    private(set) var engineRPM: Float
    private(set) var isShifting = false
    private(set) var refusals = 0
    private(set) var lastRefusal: ShiftRefusal?

    /// Counts down the torque interruption of a shift.
    private var shiftTimer: Float = 0
    /// Time since the last shift finished, for the minimum interval.
    private var sinceShift: Float = .greatestFiniteMagnitude
    /// The throttle the shift map reads, rather than the pedal itself.
    private var mappedThrottle: Float = 0

    init(tuning: TransmissionTuning) {
        self.tuning = tuning
        self.engineRPM = tuning.idleRPM
    }

    var readout: DrivetrainReadout {
        DrivetrainReadout(gear: gear, engineRPM: engineRPM, redlineRPM: tuning.redlineRPM,
                          idleRPM: tuning.idleRPM, isShifting: isShifting,
                          refusals: refusals, lastRefusal: lastRefusal)
    }

    /// Puts the gearbox where a car that has just been placed would be:
    /// out of gear, engine idling, nothing pending.
    mutating func settle() {
        gear = .neutral
        engineRPM = tuning.idleRPM
        isShifting = false
        shiftTimer = 0
        sinceShift = .greatestFiniteMagnitude
        mappedThrottle = 0
        refusals = 0
        lastRefusal = nil
    }

    // MARK: - One step

    /// Advances the drivetrain one fixed step and returns the forces it wants.
    ///
    /// - Parameters:
    ///   - forwardSpeed: the car's own forward speed, rendered m/s.
    ///   - wheelRadius: rendered rolling radius.
    ///   - isSliding: true while the car is sideways or the handbrake is on.
    ///     The gearbox holds whatever gear it is in for the duration, which is
    ///     what stops it hunting through a drift.
    mutating func update(dt: Float,
                         mode: TransmissionMode,
                         throttle: Float,
                         brake: Float,
                         forwardSpeed: Float,
                         wheelRadius: Float,
                         isSliding: Bool,
                         shiftUp: Int,
                         shiftDown: Int) -> DrivetrainOutput {

        switch mode {
        case .manual:
            applyManual(up: shiftUp, down: shiftDown, throttle: throttle,
                        forwardSpeed: forwardSpeed, wheelRadius: wheelRadius)
        case .automatic:
            updateAutomatic(throttle: throttle, brake: brake,
                            forwardSpeed: forwardSpeed, wheelRadius: wheelRadius,
                            isSliding: isSliding)
        }

        // Which pedal is asking the engine for torque.
        //
        // Forwards, that is the accelerator. In reverse it depends on how
        // reverse was reached: the automatic engages it *from* the brake pedal
        // and keeps driving from the brake pedal, which is the scheme the app
        // has always had. Manual puts the car in R deliberately, and then the
        // accelerator drives — the gear already says which way.
        let reverseOnBrake = gear.isReverse && mode == .automatic
        let drivePedal = reverseOnBrake ? brake : throttle
        let restingPedal = reverseOnBrake ? throttle : brake

        advanceTimers(dt: dt, drivePedal: drivePedal)

        let direction: Float = gear.isReverse ? -1 : (gear.isForward ? 1 : 0)
        // Holding a pedal while the car is still travelling the other way has
        // always stopped the car first and only then pulled it back, so that
        // holding one never has the engine fighting itself.
        let pushingUphill = direction != 0 && forwardSpeed * direction < -tuning.creepSpeed
        let rolling = abs(forwardSpeed) > tuning.creepSpeed

        var output = DrivetrainOutput()
        if pushingUphill { output.brakeDemand += drivePedal }
        if rolling { output.brakeDemand += restingPedal }

        let geared = tuning.gearedRPM(renderedSpeed: forwardSpeed, wheelRadius: wheelRadius, gear: gear)
        updateEngineSpeed(dt: dt, gearedRPM: geared, pedal: drivePedal)

        // Neutral, or being asked to drive against the car's own motion: the
        // engine is not connected to anything that can move the car.
        guard !gear.isNeutral, !pushingUphill else { return output }

        let topRatio = max(tuning.forwardRatios.last ?? 1, 1e-5)
        let ratioShare = (tuning.ratio(for: gear) ?? topRatio) / topRatio
        let reverseScale = gear.isReverse ? tuning.reverseTorqueScale : 1

        // Below the speed at which the engine would be at idle in this gear the
        // clutch is slipping, and passes less than all of the torque. This is
        // the whole of the assisted manual: no pedal, and nothing can stall.
        let lockup = min(max(geared / max(tuning.idleRPM, 1), 0), 1)
        let clutch = tuning.clutchSlipFloor + (1 - tuning.clutchSlipFloor) * lockup

        let torque = tuning.normalisedTorque(atRPM: engineRPM)
        let limiter = tuning.limiterFactor(atRPM: engineRPM)

        output.driveDemand = direction * drivePedal * clutch * reverseScale * limiter
            * torque * ratioShare * tuning.peakDriveForce * shiftFactor

        // A shut throttle in gear drags on the car through the same gearing, so
        // it bites hardest in the lowest gear — and, because it reaches the road
        // through the rear tyres, it eats into the same friction circle
        // everything else does.
        let coasting = max(1 - drivePedal * 2.2, 0)
        let revSpan = max(tuning.redlineRPM - tuning.idleRPM, 1)
        let revShare = min(max((engineRPM - tuning.idleRPM) / revSpan, 0), 1)
        output.engineBraking = coasting * revShare * lockup
            * tuning.engineBrakingFraction * ratioShare * tuning.peakDriveForce * shiftFactor

        return output
    }

    // MARK: - Timers and engine speed

    private mutating func advanceTimers(dt: Float, drivePedal: Float) {
        if shiftTimer > 0 {
            shiftTimer -= dt
            if shiftTimer <= 0 {
                shiftTimer = 0
                isShifting = false
                sinceShift = 0
            }
        } else if sinceShift < .greatestFiniteMagnitude {
            sinceShift += dt
        }

        let rate = drivePedal > mappedThrottle ? tuning.throttleRiseRate : tuning.throttleFallRate
        mappedThrottle += (drivePedal - mappedThrottle) * min(rate * dt, 1)
    }

    /// In gear the tachometer is simply the road speed through the gearing —
    /// nothing else would keep RPM, gear and speed telling the same story.
    /// Out of gear, or between gears, it follows the pedal instead.
    private mutating func updateEngineSpeed(dt: Float, gearedRPM: Float, pedal: Float) {
        if gear.isNeutral {
            let free = tuning.idleRPM + (tuning.redlineRPM * 0.78 - tuning.idleRPM) * pedal
            engineRPM += (free - engineRPM) * min(9 * dt, 1)
            return
        }
        let geared = min(max(gearedRPM, tuning.idleRPM), tuning.redlineRPM)
        if isShifting, tuning.shiftDuration > 0 {
            // The clutch is slipping, so the needle sweeps across to the new
            // gear's engine speed rather than teleporting to it. It arrives
            // before the shift is over.
            engineRPM += (geared - engineRPM) * min(3 / tuning.shiftDuration * dt, 1)
        } else {
            engineRPM = geared
        }
    }

    // MARK: - Manual

    /// Walks the gear along by one per tap, refusing the moves that would break
    /// something. Taps are counted rather than sampled, so a quick double tap
    /// moves two gears and none of them are ever dropped.
    private mutating func applyManual(up: Int, down: Int, throttle: Float,
                                      forwardSpeed: Float, wheelRadius: Float) {
        // Assisted, so pulling away never needs a gear selection first: asking
        // for the accelerator from neutral at a standstill takes first, exactly
        // as letting a clutch up in first would. Everything above first is the
        // driver's.
        if gear.isNeutral, throttle > 0.02, abs(forwardSpeed) < tuning.creepSpeed {
            engage(.forward(1))
        }
        for _ in 0..<max(up, 0) {
            attempt(to: Gear(index: gear.index + 1), forwardSpeed: forwardSpeed, wheelRadius: wheelRadius)
        }
        for _ in 0..<max(down, 0) {
            attempt(to: Gear(index: gear.index - 1), forwardSpeed: forwardSpeed, wheelRadius: wheelRadius)
        }
    }

    private mutating func attempt(to target: Gear, forwardSpeed: Float, wheelRadius: Float) {
        guard target.index >= -1, target.index <= tuning.topGear else {
            refuse(.endOfTravel)
            return
        }
        // Reverse while the car is still rolling forwards is the one genuinely
        // damaging selection, so it is refused outright rather than fudged.
        if target.isReverse, forwardSpeed > tuning.reverseEngageSpeed {
            refuse(.tooFastForReverse)
            return
        }
        // Dropping into a gear that would bounce the engine off the limiter is
        // the other one.
        if target.isForward, gear.isForward, target.index < gear.index {
            let landing = tuning.gearedRPM(renderedSpeed: forwardSpeed,
                                           wheelRadius: wheelRadius, gear: target)
            if landing > tuning.redlineRPM {
                refuse(.wouldOverRev)
                return
            }
        }
        engage(target)
    }

    private mutating func refuse(_ reason: ShiftRefusal) {
        refusals &+= 1
        lastRefusal = reason
    }

    // MARK: - Automatic

    private mutating func updateAutomatic(throttle: Float, brake: Float,
                                          forwardSpeed: Float, wheelRadius: Float,
                                          isSliding: Bool) {
        let stopped = abs(forwardSpeed) < tuning.creepSpeed
        let wantsForward = throttle > 0.02
        let wantsBack = brake > 0.02

        // Direction first, and by the rule the pedals have always followed: the
        // brake becomes reverse once the car has actually stopped.
        if gear.isReverse {
            if stopped && wantsForward { engage(.forward(1)) }
            else if stopped && !wantsBack { engage(.neutral) }
            return
        }
        if gear.isNeutral {
            if stopped {
                if wantsForward { engage(.forward(1)) }
                else if wantsBack { engage(.reverse) }
            } else {
                // Rolling in neutral — which only happens after a switch out of
                // Manual — so pick the gear that suits the speed and drive on.
                engage(.forward(gearSuiting(speed: forwardSpeed, wheelRadius: wheelRadius)))
            }
            return
        }

        if stopped {
            if wantsBack && !wantsForward { engage(.reverse) }
            else if !wantsForward && !wantsBack { engage(.neutral) }
            else if wantsForward && gear.index > 1 { engage(.forward(1)) }
            return
        }

        guard canShift else { return }

        let upshiftRPM = tuning.redlineRPM
            * (tuning.upshiftFractionOffThrottle
               + (tuning.upshiftFractionAtFullThrottle - tuning.upshiftFractionOffThrottle) * mappedThrottle)

        // A gear change mid-slide would take the drive away exactly when the
        // driver is using it to hold an angle, so through a slide the gearbox
        // sits still — right up until the engine is on the limiter, where
        // holding the gear would stop the car accelerating altogether.
        let ceiling = isSliding ? tuning.redlineRPM * tuning.limiterUpshiftFraction : upshiftRPM

        if gear.index < tuning.topGear, engineRPM >= ceiling {
            engage(.forward(gear.index + 1))
            return
        }
        guard !isSliding else { return }

        if gear.index > 1 {
            let lower = Gear.forward(gear.index - 1)
            let landing = tuning.gearedRPM(renderedSpeed: forwardSpeed,
                                           wheelRadius: wheelRadius, gear: lower)
            // Only drop a gear if the engine would land clear of the point it
            // would want to shift straight back up at. That one comparison is
            // the whole hysteresis, and it stays correct whatever the ratios
            // and whatever the throttle is doing.
            if landing <= upshiftRPM * tuning.downshiftLanding {
                engage(lower)
            }
        }
    }

    /// The shortest gear that will not over-rev at this speed — so, the one
    /// with the most torque available. Used when picking a gear up again after
    /// coasting in neutral, which is what happens on a switch out of Manual.
    private func gearSuiting(speed: Float, wheelRadius: Float) -> Int {
        let ceiling = tuning.redlineRPM * tuning.upshiftFractionAtFullThrottle
        for index in 1...tuning.topGear {
            let rpm = tuning.gearedRPM(renderedSpeed: speed, wheelRadius: wheelRadius,
                                       gear: .forward(index))
            if rpm <= ceiling { return index }
        }
        return tuning.topGear
    }

    /// How much of the engine's torque is getting through right now. Falls to
    /// `shiftTorqueFloor` the instant a gear is selected and comes back over
    /// the length of the shift, which is the shape a clutch re-engaging has.
    private var shiftFactor: Float {
        guard isShifting, tuning.shiftDuration > 0 else { return 1 }
        let progress = 1 - min(max(shiftTimer / tuning.shiftDuration, 0), 1)
        return tuning.shiftTorqueFloor + (1 - tuning.shiftTorqueFloor) * progress
    }

    private var canShift: Bool {
        !isShifting && sinceShift >= tuning.minimumShiftInterval
    }

    /// Puts a gear in, with the short break in drive that going through a
    /// gearbox costs. Road speed is untouched, so a shift never moves the car.
    private mutating func engage(_ target: Gear) {
        guard target != gear else { return }
        gear = target
        shiftTimer = tuning.shiftDuration
        isShifting = tuning.shiftDuration > 0
        sinceShift = 0
    }
}
