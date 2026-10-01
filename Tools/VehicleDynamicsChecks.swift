import Foundation
import simd

@main
struct DynTest {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
        if !ok { failures += 1 }
    }

    static func car(_ c: CarClass, length: Float = 0.42) -> VehicleDynamics {
        let t = VehicleTuning.make(carClass: c, length: length,
                                   wheelBase: length * 0.55, trackWidth: length * 0.44,
                                   wheelRadius: length * 0.115)
        var d = VehicleDynamics(tuning: t)
        d.place(heading: 0)
        return d
    }

    static func run(_ d: inout VehicleDynamics, _ seconds: Double, hz: Double, _ i: DrivingInput) {
        let dt = Float(1.0 / hz)
        for _ in 0..<Int(seconds * hz) { d.advance(deltaTime: dt, input: i) }
    }

    static func main() {
        let input = DrivingInput(); input.isEnabled = true

        // 1. Inputs do nothing until driving is enabled.
        do {
            var d = car(.sedan)
            let off = DrivingInput(); off.throttle = 1; off.steering = 1; off.handbrake = 1
            run(&d, 2, hz: 60, off)
            check("locked out before placement", d.state.position == .zero && d.state.speed == 0,
                  "pos=\(d.state.position)")
        }

        // 2. Every class reaches its own top speed and stops short of it.
        for c in [CarClass.compact, .sedan, .sports, .supercar, .drift, .offroad, .van, .truck, .openWheel, .classic, .novelty] {
            var d = car(c)
            input.releaseAll(); input.throttle = 1
            run(&d, 14, hz: 120, input)
            let reached = d.state.forwardSpeed
            let target = d.tuning.topSpeed
            check("\(c.rawValue): top speed", abs(reached - target) < target * 0.06,
                  String(format: "%.2f of %.2f m/s", reached, target))
        }

        // 3. Frame-rate independence, straight / cornering / handbrake drift.
        for (label, steer, hand, tol) in [("straight", Float(0), Float(0), Float(0.01)),
                                          ("cornering", Float(0.85), Float(0), Float(0.03)),
                                          ("handbrake drift", Float(1), Float(1), Float(0.06))] {
            var paths: [Float] = []
            for hz in [30.0, 60.0, 120.0] {
                var d = car(.sports)
                let dt = Float(1.0 / hz)
                // Get up to speed first, then apply the manoeuvre.
                input.releaseAll(); input.throttle = 1
                for _ in 0..<Int(4 * hz) { d.advance(deltaTime: dt, input: input) }
                input.steering = steer; input.handbrake = hand
                var path: Float = 0, prev = d.state.position
                for _ in 0..<Int(4 * hz) {
                    d.advance(deltaTime: dt, input: input)
                    path += simd_length(d.state.position - prev); prev = d.state.position
                }
                paths.append(path)
            }
            let spread = (paths.max()! - paths.min()!) / paths[1]
            check("frame-rate independent — \(label)", spread < tol,
                  paths.enumerated().map { String(format: "%.3fm", $0.element) }.joined(separator: " ")
                  + String(format: " (spread %.2f%%)", spread * 100))
        }

        // 4. Brake to a stop, then reverse, then recover on the throttle.
        do {
            var d = car(.sedan)
            input.releaseAll(); input.throttle = 1
            run(&d, 8, hz: 120, input)
            let cruise = d.state.forwardSpeed
            input.releaseAll(); input.brake = 1
            var t: Float = 0
            while d.state.forwardSpeed > 0.01 && t < 6 { d.advance(deltaTime: 1.0/120, input: input); t += 1.0/120 }
            check("brake stops the car", d.state.forwardSpeed <= 0.01 && t < 2.5,
                  String(format: "%.2f m/s to rest in %.2f s", cruise, t))
            run(&d, 4, hz: 120, input)
            check("brake becomes reverse", d.state.forwardSpeed < -0.2,
                  String(format: "%.2f m/s", d.state.forwardSpeed))
            input.releaseAll(); input.throttle = 1
            t = 0
            while d.state.forwardSpeed < 0 && t < 3 { d.advance(deltaTime: 1.0/120, input: input); t += 1.0/120 }
            check("throttle recovers from reverse", t < 1.5, String(format: "%.2f s", t))
        }

        // 5. No pivot on the spot, and low speed is stable.
        do {
            var d = car(.drift)
            input.releaseAll(); input.steering = 1
            run(&d, 3, hz: 120, input)
            check("no pivoting on the spot", d.state.heading == 0 && d.state.position == .zero,
                  "heading=\(d.state.heading)")

            input.releaseAll(); input.throttle = 0.22; input.steering = 1
            var maxYaw: Float = 0
            for _ in 0..<600 { d.advance(deltaTime: 1.0/120, input: input); maxYaw = max(maxYaw, abs(d.state.yawRate)) }
            check("stable at crawling speed", maxYaw < 4.0 && d.state.speed < 0.9,
                  String(format: "peak yaw %.2f rad/s at %.2f m/s", maxYaw, d.state.speed))
        }

        // 6. Grip ordering: the drift car slides, the open wheeler does not.
        func peakSlip(_ c: CarClass, hand: Float, steer: Float = 1) -> (Float, Float) {
            var d = car(c)
            input.releaseAll(); input.throttle = 1
            run(&d, 6, hz: 120, input)
            input.steering = steer; input.handbrake = hand
            var slipAngle: Float = 0, slipSpeed: Float = 0
            for _ in 0..<360 {
                d.advance(deltaTime: 1.0/120, input: input)
                slipAngle = max(slipAngle, abs(d.telemetry.rearSlipAngle))
                slipSpeed = max(slipSpeed, d.telemetry.rearSlipSpeed)
            }
            return (slipAngle * 180 / .pi, slipSpeed)
        }
        let racer = peakSlip(.openWheel, hand: 0)
        let drift = peakSlip(.drift, hand: 0)
        let sedanDry = peakSlip(.sedan, hand: 0)
        let sedanHand = peakSlip(.sedan, hand: 1)
        check("grippy car holds its line", racer.0 < 9, String(format: "%.1f° rear slip", racer.0))
        check("drift car breaks away", drift.0 > 14, String(format: "%.1f° rear slip", drift.0))
        check("drift car slides more than the racer", drift.0 > racer.0 * 1.6,
              String(format: "%.1f° vs %.1f°", drift.0, racer.0))
        check("handbrake breaks traction", sedanHand.0 > sedanDry.0 * 1.8,
              String(format: "%.1f° -> %.1f° rear slip", sedanDry.0, sedanHand.0))
        check("handbrake produces slide speed", sedanHand.1 > 0.25,
              String(format: "%.2f m/s rear slip speed", sedanHand.1))

        // 7. Countersteering catches the car: same slide, two responses.
        do {
            var peakYaw: Float = 0
            var peakSlipAngle: Float = 0
            func slide() -> VehicleDynamics {
                var d = car(.drift)
                input.releaseAll(); input.throttle = 1
                run(&d, 6, hz: 120, input)
                input.steering = 1; input.handbrake = 1
                for _ in 0..<Int(0.45 * 120) {
                    d.advance(deltaTime: 1.0 / 120, input: input)
                    peakYaw = max(peakYaw, abs(d.state.yawRate))
                    peakSlipAngle = max(peakSlipAngle, abs(d.telemetry.rearSlipAngle))
                }
                return d
            }
            var holding = slide()
            var catching = holding
            let entryYaw = peakYaw
            let entrySlip = peakSlipAngle

            input.releaseAll(); input.throttle = 1; input.steering = 1
            run(&holding, 0.6, hz: 120, input)
            input.releaseAll(); input.throttle = 1; input.steering = -1
            run(&catching, 0.6, hz: 120, input)

            check("slide actually starts", entryYaw > 1.5 && entrySlip > 0.1,
                  String(format: "%.2f rad/s, %.0f° rear slip", entryYaw, entrySlip * 180 / .pi))
            check("countersteering reduces rotation",
                  abs(catching.state.yawRate) < abs(holding.state.yawRate),
                  String(format: "counter %.2f vs hold %.2f rad/s",
                         abs(catching.state.yawRate), abs(holding.state.yawRate)))
            check("countersteering reduces rear slip",
                  abs(catching.telemetry.rearSlipAngle) < abs(holding.telemetry.rearSlipAngle),
                  String(format: "counter %.0f° vs hold %.0f°",
                         abs(catching.telemetry.rearSlipAngle) * 180 / .pi,
                         abs(holding.telemetry.rearSlipAngle) * 180 / .pi))
        }

        // 8. Slip settles again once inputs are neutral.
        do {
            var d = car(.drift)
            input.releaseAll(); input.throttle = 1
            run(&d, 5, hz: 120, input)
            input.steering = 1; input.handbrake = 1
            run(&d, 1.0, hz: 120, input)
            input.releaseAll(); input.throttle = 0.6
            run(&d, 3, hz: 120, input)
            check("recovers to a clean line", abs(d.telemetry.rearSlipAngle) < 0.09,
                  String(format: "%.1f° rear slip after recovery", d.telemetry.rearSlipAngle * 180 / .pi))
        }

        // 9. Extreme frame delay cannot teleport the car.
        do {
            var d = car(.supercar)
            input.releaseAll(); input.throttle = 1
            d.advance(deltaTime: 6.0, input: input)
            check("long stall clamped", simd_length(d.state.position) < 0.25,
                  String(format: "moved %.3f m on a 6 s frame", simd_length(d.state.position)))
        }

        // 10. Wheels roll the distance actually travelled.
        do {
            var d = car(.sedan)
            input.releaseAll(); input.throttle = 1
            var turns: Float = 0, last = d.state.frontWheelSpin, travelled: Float = 0
            for _ in 0..<900 {
                d.advance(deltaTime: 1.0/120, input: input)
                var delta = d.state.frontWheelSpin - last
                if delta < -Float.pi { delta += 2 * .pi }
                turns += delta; last = d.state.frontWheelSpin
                travelled += d.state.forwardSpeed / 120
            }
            check("wheels roll the distance driven", abs(turns * d.tuning.wheelRadius - travelled) < 0.01,
                  String(format: "%.3f m vs %.3f m", turns * d.tuning.wheelRadius, travelled))
        }

        // 11. Halt leaves the car where it stands.
        do {
            var d = car(.sports)
            input.releaseAll(); input.throttle = 1; input.steering = 0.5
            run(&d, 3, hz: 120, input)
            let at = d.state.position
            d.halt()
            let idle = DrivingInput()
            run(&d, 1, hz: 120, idle)
            check("halt keeps the car still", simd_length(d.state.position - at) < 0.001,
                  String(format: "drifted %.5f m", simd_length(d.state.position - at)))
        }

        // 12. Interpolation never runs ahead of the simulation.
        do {
            var d = car(.sports)
            input.releaseAll(); input.throttle = 1
            run(&d, 2, hz: 60, input)
            let r = d.interpolatedState()
            let lo = min(d.previousState.position.y, d.state.position.y)
            let hi = max(d.previousState.position.y, d.state.position.y)
            check("render pose sits between physics steps", r.position.y >= lo - 1e-5 && r.position.y <= hi + 1e-5,
                  String(format: "%.5f in [%.5f, %.5f]", r.position.y, lo, hi))
        }

        // 13. Holding full lock must not stall the car.
        //
        // The slip angle is formed by dividing by a floored speed, so below that
        // floor the steering term has to be scaled the same way or the front
        // tyre reports almost the whole steering angle as slip, saturates, and
        // the longitudinal component of that force out-pulls the engine. The car
        // then creeps at a fraction of its straight-line speed with the wheels
        // turned — in both directions, and worst on the low-powered classes.
        for c in [CarClass.compact, .sedan, .sports, .supercar, .drift, .offroad, .van, .truck, .openWheel, .classic, .novelty] {
            func settle(steering: Float, reverse: Bool) -> Float {
                var d = car(c)
                input.releaseAll()
                input.steering = steering
                if reverse { input.brake = 1 } else { input.throttle = 1 }
                run(&d, 14, hz: 120, input)
                return abs(d.state.forwardSpeed)
            }
            // The drift classes legitimately lose speed at full lock because the
            // rear lets go, so this is a floor on stalling, not on cornering.
            let minimum: Float = c == .drift ? 0.45 : 0.80
            let straight = settle(steering: 0, reverse: false)
            let locked = settle(steering: 1, reverse: false)
            check("\(c.rawValue): full lock does not stall", locked > straight * minimum,
                  String(format: "%.2f of %.2f m/s (%.0f%%)", locked, straight, locked / straight * 100))

            let back = settle(steering: 0, reverse: true)
            let backLocked = settle(steering: 1, reverse: true)
            check("\(c.rawValue): full lock does not stall in reverse", backLocked > back * 0.60,
                  String(format: "%.2f of %.2f m/s (%.0f%%)", backLocked, back, backLocked / back * 100))
        }

        // ---------------------------------------------------------------
        // Drivetrain
        // ---------------------------------------------------------------

        // 14. A gear is not a label: the same car, same pedal, accelerates
        //     very differently depending on which one is selected.
        do {
            // Timed to a speed every gear can reach, so the comparison is of
            // acceleration rather than of where each gear runs out of revs.
            func timeTo(_ target: Float, gear: Int) -> Float {
                var d = car(.sports)
                let m = DrivingInput(); m.isEnabled = true; m.transmissionMode = .manual
                m.throttle = 1
                // Take the gear before moving; from rest the box is in first.
                for _ in 1..<gear { m.requestShiftUp(); d.advance(deltaTime: 1.0/120, input: m) }
                for step in 0..<Int(10 * 120) {
                    d.advance(deltaTime: 1.0/120, input: m)
                    if d.state.forwardSpeed >= target { return Float(step) / 120 }
                }
                return .infinity
            }
            let first = timeTo(0.30, gear: 1)
            let third = timeTo(0.30, gear: 3)
            let sixth = timeTo(0.30, gear: 6)
            check("gear changes acceleration", third > first * 1.3 && sixth > third * 1.3,
                  String(format: "0 to 0.30 m/s: 1st %.2f s, 3rd %.2f s, 6th %.2f s", first, third, sixth))
        }

        // 15. And each gear runs out of road speed of its own, at the limiter,
        //     rather than every gear quietly reaching the same place.
        do {
            var settled: [Float] = []
            for gear in [1, 3, 6] {
                var d = car(.sports)
                let m = DrivingInput(); m.isEnabled = true; m.transmissionMode = .manual
                m.throttle = 1
                for _ in 1..<gear { m.requestShiftUp(); d.advance(deltaTime: 1.0/120, input: m) }
                run(&d, 14, hz: 120, m)
                settled.append(d.state.forwardSpeed)
                let rpm = d.drivetrainReadout.engineRPM
                check("gear \(gear): rev limiter holds the engine",
                      rpm <= d.tuning.transmission.redlineRPM + 1,
                      String(format: "%.0f of %.0f rpm", rpm, d.tuning.transmission.redlineRPM))
            }
            check("each gear has its own top speed", settled[0] < settled[1] && settled[1] < settled[2],
                  settled.map { String(format: "%.2f", $0) }.joined(separator: " < "))
        }

        // 16. Manual does not shift for you, however long the engine is held
        //     against the limiter.
        do {
            var d = car(.sports)
            let m = DrivingInput(); m.isEnabled = true; m.transmissionMode = .manual
            m.throttle = 1
            run(&d, 10, hz: 120, m)
            check("manual never upshifts on its own", d.drivetrainReadout.gear.index == 1,
                  "still in \(d.drivetrainReadout.gear.label) after 10 s at full throttle")
        }

        // 17. Automatic works its way up the box, and comes back down.
        do {
            var d = car(.sports)
            input.releaseAll(); input.throttle = 1
            run(&d, 6, hz: 120, input)
            let climbed = d.drivetrainReadout.gear.index
            input.releaseAll(); input.brake = 1
            run(&d, 1.2, hz: 120, input)
            let dropped = d.drivetrainReadout.gear.index
            check("automatic climbs the box", climbed >= d.tuning.transmission.topGear - 1,
                  "reached \(climbed) of \(d.tuning.transmission.topGear)")
            check("automatic drops gears under braking", dropped < climbed,
                  "\(climbed) down to \(dropped)")
        }

        // 18. The shift map has to be quiet through a slide. A gearbox that
        //     hunts takes the drive away exactly when it is being used to hold
        //     an angle.
        do {
            var d = car(.drift)
            input.releaseAll(); input.throttle = 1
            run(&d, 3, hz: 120, input)
            input.steering = 1; input.handbrake = 1
            var shifts = 0
            var last = d.drivetrainReadout.gear
            for _ in 0..<Int(3 * 120) {
                d.advance(deltaTime: 1.0/120, input: input)
                if d.drivetrainReadout.gear != last { shifts += 1; last = d.drivetrainReadout.gear }
            }
            check("no gear hunting through a drift", shifts <= 1, "\(shifts) shift(s) in 3 s of slide")
        }

        // 19. Manual cannot select what is not there.
        do {
            var d = car(.sports)
            let m = DrivingInput(); m.isEnabled = true; m.transmissionMode = .manual
            for _ in 0..<12 { m.requestShiftUp(); d.advance(deltaTime: 1.0/120, input: m) }
            let top = d.drivetrainReadout.gear.index
            for _ in 0..<20 { m.requestShiftDown(); d.advance(deltaTime: 1.0/120, input: m) }
            let bottom = d.drivetrainReadout.gear
            check("manual stops at top gear", top == d.tuning.transmission.topGear,
                  "reached \(top) of \(d.tuning.transmission.topGear)")
            check("manual stops at reverse", bottom.isReverse, "ended in \(bottom.label)")
        }

        // 20. Reverse while rolling forwards is refused, and works the moment
        //     the car has stopped.
        do {
            var d = car(.sports)
            let m = DrivingInput(); m.isEnabled = true; m.transmissionMode = .manual
            m.throttle = 1
            run(&d, 3, hz: 120, m)
            let before = d.drivetrainReadout.refusals
            // Down to neutral, then ask for reverse at speed.
            for _ in 0..<10 { m.requestShiftDown(); d.advance(deltaTime: 1.0/120, input: m) }
            let moving = d.drivetrainReadout
            check("reverse refused while moving forward",
                  !moving.gear.isReverse && moving.refusals > before && moving.lastRefusal == .tooFastForReverse,
                  "gear \(moving.gear.label), \(moving.refusals - before) refusal(s)")

            m.throttle = 0; m.brake = 1
            run(&d, 4, hz: 120, m)
            m.brake = 0
            m.requestShiftDown(); d.advance(deltaTime: 1.0/120, input: m)
            let stopped = d.drivetrainReadout
            check("reverse engages once stopped", stopped.gear.isReverse,
                  String(format: "gear %@ at %.3f m/s", stopped.gear.label, d.state.forwardSpeed))

            m.throttle = 1
            run(&d, 3, hz: 120, m)
            check("manual reverse drives on the accelerator", d.state.forwardSpeed < -0.2,
                  String(format: "%.2f m/s", d.state.forwardSpeed))
        }

        // 21. And a downshift that would bounce the engine off the limiter is
        //     refused rather than obeyed.
        do {
            var d = car(.sports)
            input.releaseAll(); input.throttle = 1
            run(&d, 6, hz: 120, input)
            let m = DrivingInput(); m.isEnabled = true; m.transmissionMode = .manual; m.throttle = 1
            d.advance(deltaTime: 1.0/120, input: m)
            let high = d.drivetrainReadout.gear.index
            let before = d.drivetrainReadout.refusals
            for _ in 0..<6 { m.requestShiftDown(); d.advance(deltaTime: 1.0/120, input: m) }
            let after = d.drivetrainReadout
            check("money shift refused", after.gear.index > 1 && after.refusals > before,
                  "\(high) down to \(after.gear.label), \(after.refusals - before) refusal(s)")
            check("engine still under the limiter", after.engineRPM <= d.tuning.transmission.redlineRPM + 1,
                  String(format: "%.0f rpm", after.engineRPM))
        }

        // 22. Changing mode mid-corner changes who is shifting and nothing
        //     else. The car must not so much as twitch.
        do {
            var d = car(.sports)
            input.releaseAll(); input.throttle = 1; input.steering = 0.5
            run(&d, 3, hz: 120, input)
            let before = d.state
            let gearBefore = d.drivetrainReadout.gear
            let m = DrivingInput(); m.isEnabled = true; m.transmissionMode = .manual
            m.throttle = 1; m.steering = 0.5
            d.advance(deltaTime: 1.0/120, input: m)
            let after = d.state
            let jump = simd_length(after.velocity - before.velocity)
            check("mode change keeps the car's velocity", jump < 0.02,
                  String(format: "%.4f m/s step, gear %@ to %@", jump,
                         gearBefore.label, d.drivetrainReadout.gear.label))
            check("mode change keeps the gear", d.drivetrainReadout.gear == gearBefore,
                  "\(gearBefore.label) to \(d.drivetrainReadout.gear.label)")
        }

        // 23. A shift is a dip in drive, not a step in speed.
        do {
            var d = car(.sports)
            input.releaseAll(); input.throttle = 1
            var lastGear = d.drivetrainReadout.gear
            var speedAtShift: Float = 0
            var lowestSinceShift: Float = 0
            var worstDip: Float = 0
            var wasShifting = false
            for _ in 0..<Int(6 * 120) {
                d.advance(deltaTime: 1.0/120, input: input)
                let now = d.state.forwardSpeed
                let readout = d.drivetrainReadout
                if readout.gear != lastGear {
                    lastGear = readout.gear
                    speedAtShift = now
                    lowestSinceShift = now
                    wasShifting = true
                }
                if wasShifting {
                    lowestSinceShift = min(lowestSinceShift, now)
                    if !readout.isShifting {
                        worstDip = max(worstDip, speedAtShift - lowestSinceShift)
                        wasShifting = false
                    }
                }
            }
            // A shift is a dip in drive, not a step in speed. Anything the
            // driver would read as the speedometer jumping is a fault; a
            // sub-km/h sag while the clutch comes back is a gearbox.
            check("shifts do not step the speed", worstDip < 0.06,
                  String(format: "deepest sag across a shift %.4f m/s (%.2f km/h)",
                         worstDip, worstDip * 36))
        }

        // 24. Every reading the cluster shows comes from the simulation, and
        //     the two unit scales are exactly the published ones.
        do {
            var d = car(.sports)
            input.releaseAll()
            run(&d, 0.5, hz: 120, input)
            check("speed reads zero at rest",
                  SimulationScale.displaySpeed(renderedMetresPerSecond: d.state.speed,
                                               unit: .kilometresPerHour) == 0,
                  String(format: "%.4f m/s", d.state.speed))

            input.throttle = 1
            run(&d, 4, hz: 120, input)
            let rendered = d.state.speed
            let kmh = SimulationScale.displaySpeed(renderedMetresPerSecond: rendered, unit: .kilometresPerHour)
            let mph = SimulationScale.displaySpeed(renderedMetresPerSecond: rendered, unit: .milesPerHour)
            let scale = SimulationScale.fullSizeMetresPerRenderedMetre
            check("km/h is the simulated speed times 3.6",
                  abs(kmh - rendered * scale * 3.6) < 1e-3,
                  String(format: "%.3f rendered m/s -> %.1f km/h", rendered, kmh))
            check("mph is the simulated speed times 2.236936",
                  abs(mph - rendered * scale * 2.236936) < 1e-3,
                  String(format: "%.3f rendered m/s -> %.1f mph", rendered, mph))
            check("the two units describe one speed", abs(kmh / mph - 1.609344) < 1e-4,
                  String(format: "%.1f km/h / %.1f mph = %.5f", kmh, mph, kmh / mph))
        }

        // 25. The gearbox is as frame-rate independent as the rest of the model.
        do {
            var speeds: [Float] = []
            var gears: [Int] = []
            for hz in [30.0, 60.0, 120.0] {
                var d = car(.sports)
                input.releaseAll(); input.throttle = 1
                run(&d, 4, hz: hz, input)
                speeds.append(d.state.forwardSpeed)
                gears.append(d.drivetrainReadout.gear.index)
            }
            let spread = (speeds.max()! - speeds.min()!) / speeds.max()!
            check("gearbox is frame-rate independent", spread < 0.02 && Set(gears).count == 1,
                  String(format: "%.3f %.3f %.3f m/s, gears \(gears) (spread %.2f%%)",
                         speeds[0], speeds[1], speeds[2], spread * 100))
        }

        // 26. Engine braking exists, and only when the throttle is shut.
        do {
            func coast(gear: Int) -> Float {
                var d = car(.sports)
                let m = DrivingInput(); m.isEnabled = true; m.transmissionMode = .manual
                m.throttle = 1
                for _ in 1..<gear { m.requestShiftUp(); d.advance(deltaTime: 1.0/120, input: m) }
                run(&d, 6, hz: 120, m)
                // Match the starting speed before lifting off, so the only
                // difference between the two runs is the gear. 0.95 m/s sits
                // inside every gear's own range, second included.
                var guardCount = 0
                while d.state.forwardSpeed > 0.95, guardCount < 4000 {
                    m.throttle = 0; d.advance(deltaTime: 1.0/120, input: m); guardCount += 1
                }
                while d.state.forwardSpeed < 0.95, guardCount < 8000 {
                    m.throttle = 1; d.advance(deltaTime: 1.0/120, input: m); guardCount += 1
                }
                m.throttle = 0
                let start = d.state.forwardSpeed
                // Short enough that neither gear reaches a standstill, or the
                // measurement saturates and both answers come out the same.
                run(&d, 0.4, hz: 120, m)
                return start - d.state.forwardSpeed
            }
            let low = coast(gear: 2)
            let high = coast(gear: 6)
            check("engine braking bites hardest in a low gear", low > high * 1.15,
                  String(format: "2nd sheds %.3f m/s, 6th sheds %.3f m/s", low, high))
        }

        print(failures == 0 ? "\nAll vehicle-dynamics checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
