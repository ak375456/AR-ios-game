//
//  VehicleDynamics.swift
//  vr
//
//  The single authoritative vehicle state, and the model that advances it.
//

import Foundation
import simd

/// Everything that describes where the car is and what it is doing.
///
/// This is the only place position, heading, velocity and yaw rate live. The
/// renderer reads an interpolated copy; nothing else writes to it.
struct VehicleState {
    /// Metres, on the placement anchor's ground plane.
    var position: SIMD2<Float> = .zero
    /// Metres per second, in world space — deliberately *not* tied to the
    /// heading, which is what makes sliding possible.
    var velocity: SIMD2<Float> = .zero
    /// Radians. 0 faces +Z; positive turns towards +X, the car's left.
    var heading: Float = 0
    /// Radians per second, positive to the left.
    var yawRate: Float = 0
    /// Front-wheel angle, radians, positive steers left.
    var steerAngle: Float = 0
    /// Accumulated wheel rotation, radians.
    var frontWheelSpin: Float = 0
    var rearWheelSpin: Float = 0

    /// Unit vector the car points along.
    var forward: SIMD2<Float> { SIMD2(sin(heading), cos(heading)) }
    /// The car's left-hand side. Right is -X at heading 0, so left is +X.
    var left: SIMD2<Float> { SIMD2(cos(heading), -sin(heading)) }

    var forwardSpeed: Float { simd_dot(velocity, forward) }
    var lateralSpeed: Float { simd_dot(velocity, left) }
    var speed: Float { simd_length(velocity) }

    var isFinite: Bool {
        position.x.isFinite && position.y.isFinite
            && velocity.x.isFinite && velocity.y.isFinite
            && heading.isFinite && yawRate.isFinite && steerAngle.isFinite
    }
}

/// What the tyres are doing, for effects and for the interface.
struct VehicleTelemetry {
    /// Slip angles in radians.
    var frontSlipAngle: Float = 0
    var rearSlipAngle: Float = 0
    /// How fast the rear contact patches are sliding sideways, m/s. This is
    /// what drives the smoke.
    var rearLateralSlipSpeed: Float = 0
    /// Longitudinal slip at the rear from wheelspin or lock-up, m/s.
    var rearLongitudinalSlipSpeed: Float = 0
    /// True while the car is sideways enough, or braked hard enough, that the
    /// gearbox should leave the gear alone.
    var isSliding: Bool = false
    /// Combined rear slip speed, m/s.
    var rearSlipSpeed: Float { (rearLateralSlipSpeed * rearLateralSlipSpeed
                                + rearLongitudinalSlipSpeed * rearLongitudinalSlipSpeed).squareRoot() }
    /// Fraction of available rear grip currently used, 0...1+.
    var rearGripUsage: Float = 0
    /// True while the car is meaningfully sideways and moving.
    var isDrifting: Bool = false
    /// Gear index after this step: -1 reverse, 0 neutral, 1 and up forward.
    var gear: Int = 0
}

/// Solid things the car can run into, resolved inside every fixed step.
///
/// The car is moved by this model's own integration, never by a physics
/// engine, so a collision shape on its own would let it drive straight through
/// anything. A solver is handed the state immediately after each step and may
/// move the car out of whatever it has entered and change its velocity and
/// yaw rate. It runs at the same 180 Hz as the tyres, so impacts are as
/// frame-rate independent as the driving, and it edits the one authoritative
/// state — the drivetrain, wheels, smoke and speedometer all read the speed
/// the impact left behind on the very next step.
protocol VehicleContactSolver {
    mutating func resolveContacts(state: inout VehicleState, previous: VehicleState,
                                  tuning: VehicleTuning, dt: Float)
}

/// An empty room.
struct NoContacts: VehicleContactSolver {
    func resolveContacts(state: inout VehicleState, previous: VehicleState,
                         tuning: VehicleTuning, dt: Float) {}
}

/// A planar vehicle model for a small car driving on the AR ground plane.
///
/// **What it is.** A dynamic bicycle model. The two front wheels are lumped
/// into one at the front axle and the two rears into one at the rear axle.
/// Each axle gets a slip angle from the car's own velocity and yaw rate; that
/// slip produces a lateral force which rises with slip and then *saturates* at
/// the grip available on that axle. Those forces drive both sideways
/// acceleration and yaw acceleration, so the car rotates because its tyres
/// push it round — not because anything rotates the model directly.
///
/// **Why a drift happens.** When the rear axle is asked for more lateral force
/// than it has (too much slip, too much throttle eating into the friction
/// circle, or the handbrake cutting rear grip), the rear force saturates while
/// the front keeps gripping. The car yaws faster than its velocity vector
/// turns, the rear slip angle grows, and the car is sliding. Countersteering
/// works because unwinding the front wheels reduces front lateral force and
/// the yaw moment that goes with it.
///
/// **Deliberate simplifications.** No suspension, no load transfer between
/// axles, no per-wheel rotational dynamics, no differential, no tyre
/// temperature, and the ground is a flat plane. Longitudinal slip is estimated
/// from excess drive or brake force rather than simulated with wheel inertia.
/// This is an arcade model tuned to feel right, not a motorsport simulator.
///
/// **Simulation scale.** The cars are about 1:10 scale but gravity is not
/// scaled, so full-size friction coefficients would make them physically
/// unable to slide at the speeds they travel. Grip coefficients are therefore
/// tuned for this scale; everything else is in honest SI units.
struct VehicleDynamics {

    // MARK: - Configuration

    var tuning: VehicleTuning

    /// The physics runs at a fixed rate and the renderer interpolates, so
    /// behaviour never depends on the display refresh rate.
    static let fixedTimeStep: Float = 1.0 / 180.0
    /// Never simulate more than this much wall time in one frame; a long stall
    /// is dropped rather than fast-forwarded through.
    static let maxCatchUp: Float = 0.1

    /// Below this speed the model blends towards plain kinematic steering so
    /// the car is predictable to shuffle around and cannot spin on the spot.
    private static let lowSpeedBlend: Float = 0.45
    /// Denominator floor when forming slip angles.
    private static let slipSpeedFloor: Float = 0.30
    /// Speed over which tyre lateral force fades in from nothing.
    private static let tyreActivitySpeed: Float = 0.12
    private static let maxYawRate: Float = 4.5
    /// Turns the drive force the rear tyres refused into an equivalent
    /// wheelspin speed, m/s per newton per kilogram. Kept low on purpose: a
    /// low-gear launch should chirp and smoke, not lay a black line every time
    /// the car pulls away.
    private static let wheelspinSlipScale: Float = 0.055

    // MARK: - State

    private(set) var state = VehicleState()
    private(set) var previousState = VehicleState()
    private(set) var telemetry = VehicleTelemetry()

    /// Engine and gearbox. It produces the longitudinal *demand*; the tyre
    /// model below still decides how much of it reaches the ground.
    private(set) var drivetrain: Drivetrain

    /// Shift taps waiting for the next fixed step. Held here rather than read
    /// straight out of the input so that a frame which happens to run three
    /// physics steps cannot shift three times, and a frame which runs none
    /// cannot lose a tap.
    private var pendingShifts: (up: Int, down: Int) = (0, 0)

    private var accumulator: Float = 0
    private var placedPosition: SIMD2<Float> = .zero
    private var placedHeading: Float = 0
    /// Grip recovers progressively after the handbrake is let go.
    private var handbrakeGrip: Float = 1

    init(tuning: VehicleTuning) {
        self.tuning = tuning
        self.drivetrain = Drivetrain(tuning: tuning.transmission)
    }

    /// What the instrument cluster reads.
    var drivetrainReadout: DrivetrainReadout { drivetrain.readout }

    // MARK: - Lifecycle

    mutating func place(heading: Float) {
        place(at: .zero, heading: heading)
    }

    /// Puts the car down at `position` on the anchor's ground plane. Reset
    /// brings it back here, which is what lets a car be moved within a course
    /// without the course moving with it.
    mutating func place(at position: SIMD2<Float>, heading: Float) {
        placedPosition = position
        placedHeading = heading
        reset()
    }

    /// Where the car was put down, and which way it faced.
    var placement: (position: SIMD2<Float>, heading: Float) { (placedPosition, placedHeading) }

    mutating func reset() {
        state = VehicleState()
        state.position = placedPosition
        state.heading = placedHeading
        previousState = state
        telemetry = VehicleTelemetry()
        drivetrain.settle()
        pendingShifts = (0, 0)
        accumulator = 0
        handbrakeGrip = 1
    }

    /// Brings the car to a halt where it stands, without moving it.
    mutating func halt() {
        state.velocity = .zero
        state.yawRate = 0
        state.steerAngle = 0
        previousState = state
        telemetry = VehicleTelemetry()
        drivetrain.settle()
        pendingShifts = (0, 0)
        accumulator = 0
        handbrakeGrip = 1
    }

    // MARK: - Advancing

    /// Advances the simulation by real elapsed time, in fixed steps.
    ///
    /// Leftover time is carried in an accumulator so the physics rate stays
    /// constant whatever the frame rate; `interpolatedState` blends the last
    /// two steps for rendering.
    mutating func advance(deltaTime: Float, input: DrivingInput) {
        var nothing = NoContacts()
        advance(deltaTime: deltaTime, input: input, contacts: &nothing)
    }

    /// As above, with `contacts` resolved after every fixed step.
    mutating func advance<Contacts: VehicleContactSolver>(deltaTime: Float, input: DrivingInput,
                                                          contacts: inout Contacts,
                                                          onStep: ((VehicleState, VehicleState, VehicleTelemetry, Float) -> Void)? = nil) {
        guard deltaTime.isFinite, deltaTime > 0 else { return }
        accumulator = min(accumulator + deltaTime, Self.maxCatchUp)

        let taps = input.takeShiftRequests()
        if input.isEnabled {
            pendingShifts.up += taps.up
            pendingShifts.down += taps.down
        }

        let dt = Self.fixedTimeStep
        while accumulator >= dt {
            previousState = state
            step(dt: dt, input: input, shifts: pendingShifts)
            contacts.resolveContacts(state: &state, previous: previousState, tuning: tuning, dt: dt)
            onStep?(state, previousState, telemetry, dt)
            pendingShifts = (0, 0)
            accumulator -= dt
        }

        if !state.isFinite {
            // Something went badly wrong; put the car back rather than let a
            // NaN propagate into the scene graph.
            reset()
        }
    }

    /// Blend factor between `previousState` and `state` for this frame.
    var interpolationAlpha: Float {
        min(max(accumulator / Self.fixedTimeStep, 0), 1)
    }

    /// The pose to render this frame.
    func interpolatedState() -> VehicleState {
        let alpha = interpolationAlpha
        var result = state
        result.position = previousState.position + (state.position - previousState.position) * alpha
        result.heading = previousState.heading + shortestAngle(from: previousState.heading, to: state.heading) * alpha
        result.steerAngle = previousState.steerAngle + (state.steerAngle - previousState.steerAngle) * alpha
        result.frontWheelSpin = previousState.frontWheelSpin
            + shortestAngle(from: previousState.frontWheelSpin, to: state.frontWheelSpin) * alpha
        result.rearWheelSpin = previousState.rearWheelSpin
            + shortestAngle(from: previousState.rearWheelSpin, to: state.rearWheelSpin) * alpha
        return result
    }

    // MARK: - One fixed step

    private mutating func step(dt: Float, input: DrivingInput, shifts: (up: Int, down: Int)) {
        let live = input.isEnabled
        let throttle = live ? clamp(input.throttle, 0, 1) : 0
        let brake = live ? clamp(input.brake, 0, 1) : 0
        let handbrake = live ? clamp(input.handbrake, 0, 1) : 0
        let steerInput = live ? clamp(input.steering, -1, 1) : 0
        let shiftUp = live ? shifts.up : 0
        let shiftDown = live ? shifts.down : 0

        var vx = state.forwardSpeed
        var vy = state.lateralSpeed
        var yaw = state.yawRate

        updateSteering(dt: dt, steerInput: steerInput, forwardSpeed: vx)

        // Handbrake grip falls immediately and returns progressively, so
        // catching the car after letting go is a skill rather than a switch.
        let target = 1 - (1 - tuning.handbrakeGripScale) * handbrake
        if target < handbrakeGrip {
            handbrakeGrip = target
        } else {
            handbrakeGrip = min(target, handbrakeGrip + tuning.handbrakeReleaseRate * dt)
        }

        // --- Drivetrain ----------------------------------------------------
        // The engine and gearbox produce a *demand*; what follows decides how
        // much of it the rear tyres can actually pass.
        let demand = drivetrain.update(
            dt: dt, mode: input.transmissionMode, throttle: throttle, brake: brake,
            forwardSpeed: vx, wheelRadius: tuning.wheelRadius,
            isSliding: telemetry.isSliding || handbrake > 0.05,
            shiftUp: shiftUp, shiftDown: shiftDown)
        telemetry.gear = drivetrain.gear.index

        // --- Longitudinal forces -----------------------------------------
        // The knee is measured against the rear axle's *dry* grip rather than
        // what is left after the handbrake, so a handbrake turn still puts the
        // power down the way it always has.
        let dryRearPeak = tuning.rearGrip * tuning.rearAxleLoad
        let driveForce = tractionLimited(demand.driveDemand, grip: dryRearPeak)
        // What the tyres could not pass is wheelspin, which is what the smoke
        // is made of.
        let driveOverflow = max(abs(demand.driveDemand) - tractionCeiling, 0)

        let engineBraking = min(demand.engineBraking, tractionCeiling)
        let wheelBraking = tuning.brakeForce * demand.brakeDemand
            + tuning.handbrakeForce * handbrake

        // Braking is capped so a single step can never push the car through
        // zero and out the other side. Engine braking is scaled with it so the
        // two cannot between them overshoot either.
        let brakingForce = wheelBraking + engineBraking
        let stoppingForce = abs(vx) / max(dt, 1e-5) * tuning.mass
        let brakeScale = brakingForce > stoppingForce ? stoppingForce / max(brakingForce, 1e-5) : 1
        let appliedWheelBraking = wheelBraking * brakeScale
        let appliedEngineBraking = engineBraking * brakeScale
        let appliedBraking = appliedWheelBraking + appliedEngineBraking
        let brakeSign: Float = vx > 0 ? -1 : (vx < 0 ? 1 : 0)

        var longitudinal = driveForce + brakeSign * appliedBraking
        if abs(vx) > 0.01 {
            longitudinal -= (vx > 0 ? 1 : -1) * tuning.rollingResistance
        }
        longitudinal -= tuning.dragCoefficient * vx * abs(vx)

        // Magnitudes of the longitudinal force each axle is passing, for the
        // friction circle: drive goes to the rear, wheel braking is split by
        // bias, and engine braking is all rear because that is where the
        // driveshaft is.
        let frontLongitudinal = appliedWheelBraking * tuning.frontBrakeBias
        let rearLongitudinal = abs(driveForce)
            + appliedWheelBraking * (1 - tuning.frontBrakeBias)
            + appliedEngineBraking

        // --- Tyre slip ----------------------------------------------------
        let denominator = max(abs(vx), Self.slipSpeedFloor)
        let direction: Float = vx >= 0 ? 1 : -1
        // Below the floor the velocity term is divided by more than the car's
        // real speed, so the steering term has to be scaled by the same factor
        // or the two halves stop describing the same tyre. Left unscaled it
        // reports very nearly the whole steering angle as slip on a car that is
        // barely moving, saturates the front tyre at full grip, and the
        // longitudinal component of that phantom force (`frontLateral * sinSteer`
        // in `ax` below) out-pulls the engine — the car sticks at a crawl
        // whenever the wheels are turned. Scaled together, slip falls away with
        // speed, which is what a rolling tyre actually does.
        let floorScale = abs(vx) / denominator
        let frontSlip = atan((vy + tuning.frontAxleToCG * yaw) / denominator)
            - state.steerAngle * direction * floorScale
        let rearSlip = atan((vy - tuning.rearAxleToCG * yaw) / denominator)

        let frontPeak = tuning.frontGrip * tuning.frontAxleLoad
        let rearPeak = tuning.rearGrip * tuning.rearAxleLoad * handbrakeGrip

        let frontAvailable = availableLateral(peak: frontPeak, longitudinal: frontLongitudinal)
        let rearAvailable = availableLateral(peak: rearPeak, longitudinal: rearLongitudinal)

        // Slip angles are formed from a velocity that is about to be divided
        // by, so they stop meaning anything as the car comes to rest. Fade the
        // tyre forces out over a narrow window: a stationary car then generates
        // no lateral force at all, instead of slowly creeping and rotating
        // under a phantom force from its own steering angle.
        let tyreActivity = clamp(simd_length(SIMD2(vx, vy)) / Self.tyreActivitySpeed, 0, 1)

        let frontLateral = lateralForce(slip: frontSlip,
                                        stiffness: tuning.frontCorneringStiffness,
                                        available: frontAvailable) * tyreActivity
        let rearLateral = lateralForce(slip: rearSlip,
                                       stiffness: tuning.rearCorneringStiffness * handbrakeGrip,
                                       available: rearAvailable) * tyreActivity

        // --- Accelerations -------------------------------------------------
        let cosSteer = cos(state.steerAngle)
        let sinSteer = sin(state.steerAngle)

        let ax = (longitudinal - frontLateral * sinSteer) / tuning.mass + vy * yaw
        let ay = (frontLateral * cosSteer + rearLateral) / tuning.mass - vx * yaw
        let yawAcceleration = (tuning.frontAxleToCG * frontLateral * cosSteer
                               - tuning.rearAxleToCG * rearLateral
                               - tuning.yawDamping * yaw) / tuning.yawInertia

        vx += ax * dt
        vy += ay * dt
        yaw += yawAcceleration * dt

        // --- Low-speed behaviour -------------------------------------------
        // Slip angles are meaningless as speed approaches zero, so fade to the
        // kinematic answer: the car simply goes where the wheels point.
        let speedFraction = clamp(abs(vx) / Self.lowSpeedBlend, 0, 1)
        if speedFraction < 1 {
            let kinematicYaw = vx * tan(state.steerAngle) / tuning.wheelBase
            // A car turning slowly still has lateral velocity: the rear axle
            // rolls without slipping, so the centre of mass tracks sideways at
            // `rearAxleToCG * yawRate`. Fading vy to zero instead claimed the
            // car was travelling straight while it was visibly turning, which
            // left the front tyre a residual slip angle it had not earned —
            // and the drag that comes with it. Both still reach zero at rest.
            let kinematicLateral = tuning.rearAxleToCG * kinematicYaw
            yaw = kinematicYaw + (yaw - kinematicYaw) * speedFraction
            vy = kinematicLateral + (vy - kinematicLateral) * speedFraction
        }

        yaw = clamp(yaw, -Self.maxYawRate, Self.maxYawRate)
        vx = clamp(vx, -tuning.topSpeed * tuning.reverseForceScale - 0.2, tuning.topSpeed + 0.2)
        if abs(vx) < 0.012 && throttle == 0 && brake == 0 { vx = 0 }

        // --- Integrate ------------------------------------------------------
        state.yawRate = yaw
        state.heading = normalizeAngle(state.heading + yaw * dt)
        state.velocity = state.forward * vx + state.left * vy
        state.position += state.velocity * dt

        updateWheels(dt: dt, forwardSpeed: vx, handbrake: handbrake)
        updateTelemetry(frontSlip: frontSlip, rearSlip: rearSlip, vy: vy, yaw: yaw,
                        rearLongitudinal: rearLongitudinal, rearPeak: rearPeak,
                        rearAvailable: rearAvailable, forwardSpeed: vx,
                        driveOverflow: driveOverflow, handbrake: handbrake)
    }

    // MARK: - Pieces

    private mutating func updateSteering(dt: Float, steerInput: Float, forwardSpeed: Float) {
        // Less lock at speed: keeps fast passes stable and slow work tight.
        let fraction = clamp(abs(forwardSpeed) / max(tuning.topSpeed, 0.01), 0, 1)
        let available = tuning.maxSteerAngle * (1 - tuning.steerSpeedReduction * fraction)

        // The control reports +1 for "right", and right is -X, so the wheel
        // angle takes the opposite sign.
        let target = -steerInput * available
        let step = tuning.steerRate * dt
        state.steerAngle += clamp(target - state.steerAngle, -step, step)
    }

    /// How much of a longitudinal demand the rear tyres can actually pass.
    ///
    /// The ceiling is most of the rear axle's dry grip — *or* the flat engine
    /// force this model used to have, whichever is larger. That floor is not
    /// decoration: the drift class ran at 95% of its rear grip before there was
    /// a gearbox, and the friction circle turns out to be knife-edged there.
    /// Two percent either side of it is the difference between a drift car that
    /// grips at full lock and one that spends its entire life sideways. Every
    /// other class is well under the grip ceiling, so for them the ceiling is
    /// what bites, and no car ends up with less drive than it used to have.
    ///
    /// Below the knee everything passes through untouched. Above it, demand is
    /// compressed into what is left and no further, so a low gear can ask for
    /// three times the grip available and simply spin the wheels — which is the
    /// only reason first gear does not fire the car across the room.
    ///
    /// The part that never arrives comes back as wheelspin, in the telemetry.
    private func tractionLimited(_ demand: Float, grip: Float) -> Float {
        let transmission = tuning.transmission
        let ceiling = max(grip * transmission.tractionCeiling, tuning.engineForce)
        guard ceiling > 1e-5 else { return 0 }

        let headroom = max(ceiling * transmission.tractionSoftening, 1e-5)
        let knee = ceiling - headroom

        let magnitude = abs(demand)
        guard magnitude > knee else { return demand }
        let limited = knee + headroom * tanh((magnitude - knee) / headroom)
        return demand < 0 ? -limited : limited
    }

    /// The most drive force the rear tyres will ever pass, for the wheelspin
    /// estimate. Shares its definition with `tractionLimited` above.
    private var tractionCeiling: Float {
        max(tuning.rearGrip * tuning.rearAxleLoad * tuning.transmission.tractionCeiling,
            tuning.engineForce)
    }

    /// Friction circle: force already spent going forwards or stopping is not
    /// available for going sideways.
    private func availableLateral(peak: Float, longitudinal: Float) -> Float {
        guard peak > 1e-5 else { return 0 }
        let used = min(abs(longitudinal) / peak, 0.985)
        return peak * (1 - used * used).squareRoot()
    }

    /// Lateral force that rises with slip and then saturates at the grip
    /// available, rather than growing without limit.
    private func lateralForce(slip: Float, stiffness: Float, available: Float) -> Float {
        guard available > 1e-5 else { return 0 }
        return -available * tanh(stiffness * slip / available)
    }

    private mutating func updateWheels(dt: Float, forwardSpeed: Float, handbrake: Float) {
        guard tuning.wheelRadius > 0 else { return }
        let rolled = forwardSpeed * dt / tuning.wheelRadius
        state.frontWheelSpin = wrapAngle(state.frontWheelSpin + rolled)
        // Locked rear wheels stop turning, which is what makes a handbrake
        // slide read as a handbrake slide.
        state.rearWheelSpin = wrapAngle(state.rearWheelSpin + rolled * (1 - handbrake))
    }

    private mutating func updateTelemetry(frontSlip: Float, rearSlip: Float, vy: Float, yaw: Float,
                                          rearLongitudinal: Float, rearPeak: Float,
                                          rearAvailable: Float, forwardSpeed: Float,
                                          driveOverflow: Float, handbrake: Float) {
        telemetry.frontSlipAngle = frontSlip
        telemetry.rearSlipAngle = rearSlip
        telemetry.rearLateralSlipSpeed = abs(vy - tuning.rearAxleToCG * yaw)

        // Longitudinal slip is not simulated with wheel inertia; it is
        // estimated from how much drive or brake force the rear tyres are
        // being asked to pass that they do not have. `driveOverflow` is the
        // part of the gearbox's demand the traction limiter refused, which is
        // what makes a low gear chirp its tyres.
        let excess = max(abs(rearLongitudinal) - rearPeak, 0)
        telemetry.rearLongitudinalSlipSpeed = excess / max(tuning.mass, 0.01) * 0.35
            + driveOverflow / max(tuning.mass, 0.01) * Self.wheelspinSlipScale

        telemetry.rearGripUsage = rearAvailable > 1e-5
            ? min(abs(vy - tuning.rearAxleToCG * yaw) * tuning.rearCorneringStiffness / rearAvailable, 3)
            : 3
        telemetry.isDrifting = abs(rearSlip) > 0.16 && abs(forwardSpeed) > 0.25
        // What the gearbox watches, which is wider than what the badge shows:
        // a gear change is unwelcome through the whole of a slide, not only
        // once it is spectacular enough to announce.
        telemetry.isSliding = telemetry.isDrifting
            || handbrake > 0.05
            || (abs(rearSlip) > 0.09 && abs(forwardSpeed) > 0.2)
            || telemetry.rearGripUsage > 0.95
    }
}

// MARK: - Helpers

private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
    min(max(value, lower), upper)
}

private func wrapAngle(_ angle: Float) -> Float {
    angle.truncatingRemainder(dividingBy: 2 * .pi)
}

private func normalizeAngle(_ angle: Float) -> Float {
    var result = angle.truncatingRemainder(dividingBy: 2 * .pi)
    if result > .pi { result -= 2 * .pi }
    if result < -.pi { result += 2 * .pi }
    return result
}

/// Signed shortest path between two angles, so interpolation never spins the
/// long way round when a value wraps.
private func shortestAngle(from: Float, to: Float) -> Float {
    var delta = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
    if delta > .pi { delta -= 2 * .pi }
    if delta < -.pi { delta += 2 * .pi }
    return delta
}
