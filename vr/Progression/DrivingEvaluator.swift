import Foundation
import simd

struct DriveSample {
    var position: SIMD2<Float>
    var heading: Float
    var velocity: SIMD2<Float>
    var yawRate: Float
    var dt: Float
    var active: Bool
    var contact: Float = 0
    var coneContact = false
    var braking = false
    var handbrake = false
    /// Gear index, -1 reverse, 0 neutral; and who is choosing it.
    var gear = 0
    var manual = false
    var speed: Float { simd_length(velocity) }
    var forwardSpeed: Float { simd_dot(velocity,SIMD2(sin(heading),cos(heading))) }
    var slip: Float { atan2(simd_dot(velocity,SIMD2(cos(heading),-sin(heading))),forwardSpeed) }
}
struct DrivingEvents {
    var distance: Double = 0
    var movingTime: Double = 0
    var cleanTime: Double = 0
    var driftHold: Double = 0
    var driftPoints: Double = 0
    var drifts = 0
    var driftLinks = 0
    var donuts = 0
    var perfectDonuts = 0
    var orbitFraction: Double = 0
    var driftSide = 0
    var gates = 0
    var slalom = 0
    var parking: Double = 0
    var parks = 0
    var accelerationStops = 0
    var leftTurns = 0
    var rightTurns = 0
    var reverseDistance: Double = 0
    var recovered = false
    var stopped = false
    var brakeStops = 0
    var collided = false
    var coneContact = false
    // Everyday techniques.
    /// Travel this step while rolling, for runs that a stop or brake restarts.
    var rollDistance: Double = 0
    var halted = false
    var braked = false
    /// Forward speed, rendered metres per second.
    var speed: Double = 0
    var fullTurns = 0
    var uTurns = 0
    var handbrakeTurns = 0
    var upshifts = 0
    var gearReached = 0
    // Delivered from outside the evaluator: road coins, the camera, the garage.
    var coinPickups = 0
    var coinValue = 0
    var tenCoins = 0
    var coinMissed = false
    var photos = 0
    var carsDriven = 0
}

struct ChallengeGate: Equatable {
    var center: SIMD2<Float>
    var normal: SIMD2<Float>
    var halfWidth: Float
    var reverse = false
    func crossed(from a: SIMD2<Float>, to b: SIMD2<Float>, carHalfWidth: Float) -> Bool {
        let old = simd_dot(a-center,normal), new = simd_dot(b-center,normal)
        guard old < 0, new >= 0, new-old > 0.00001 else { return false }
        let point = a + (b-a) * (-old/(new-old))
        return abs(simd_dot(point-center,SIMD2(normal.y,-normal.x))) + carHalfWidth <= halfWidth
    }
}
struct ParkingZone: Equatable {
    var center: SIMD2<Float>
    var heading: Float
    var halfSize: SIMD2<Float>
    var tolerance: Float
    func contains(position: SIMD2<Float>, heading carHeading: Float, halfSize car: SIMD2<Float>) -> Bool {
        let delta = angleDifference(carHeading,heading)
        guard abs(delta) <= tolerance else { return false }
        let offset = position-center
        let x = SIMD2(cos(heading),-sin(heading)), z = SIMD2(sin(heading),cos(heading))
        let extentX = abs(cos(delta))*car.x + abs(sin(delta))*car.y
        let extentZ = abs(sin(delta))*car.x + abs(cos(delta))*car.y
        return abs(simd_dot(offset,x))+extentX <= halfSize.x && abs(simd_dot(offset,z))+extentZ <= halfSize.y
    }
}
func angleDifference(_ a: Float, _ b: Float) -> Float { atan2(sin(a-b),cos(a-b)) }

struct ChallengeLayout {
    var gates: [ChallengeGate]
    var cones: [SIMD2<Float>]
    var slalomGates: [ChallengeGate]
    var parking: ParkingZone
    var orbitCenter: SIMD2<Float>
    var orbitRadius: Float
    var boundsMin: SIMD2<Float>
    var boundsMax: SIMD2<Float>
    var origin: SIMD2<Float>
    var heading: Float
    var carHalfSize: SIMD2<Float>
    var accelerationSpeed: Float
    var compact: Bool

    static func make(mission: MissionDefinition, length: Float, width: Float, speed: Float,
                     origin: SIMD2<Float>, heading: Float, compact: Bool) -> ChallengeLayout {
        let radius = length * (compact ? 2.0 : 2.5)
        let center = SIMD2<Float>(0,radius+length)
        let gateWidth = max(width*1.65,length*0.75)
        let count = max(3,min(7, mission.metric == .slalom ? Int(mission.target) : Int(mission.steps.first(where:{$0.technique == .slalom})?.target ?? 4)))
        let offset = Float(mission.seed % 3) * 0.12 + Float(max(0,mission.chapter-1) % 5) * 0.05
        let wide = mission.mode == .career && mission.chapter.isMultiple(of:2) == false
        var gates: [ChallengeGate] = []
        // Follow a compact clockwise circuit; ordered gates can span multiple laps.
        for i in 0..<4 {
            let a = Float(i) * .pi/2 + offset
            let point = center + SIMD2(sin(a),-cos(a))*radius
            gates.append(ChallengeGate(center:point,normal:SIMD2(cos(a),sin(a)),halfWidth:gateWidth))
        }
        if mission.steps.contains(where: { $0.technique == .figureEight }) {
            gates = (0..<8).map { i in
                let a = Float(i) * .pi/4
                let point = center + SIMD2(radius * sin(a), radius * sin(a) * cos(a))
                let tangent = simd_normalize(SIMD2(radius * cos(a), radius * cos(2*a)))
                return ChallengeGate(center: point, normal: tangent, halfWidth: gateWidth)
            }
        }
        var cones: [SIMD2<Float>] = [], slalom: [ChallengeGate] = []
        for i in 0..<count {
            let a = Float(i)/Float(max(count-1,1)) * .pi * 1.5 - .pi/2 + offset
            let radial = SIMD2<Float>(sin(a),cos(a))
            let point = center + radial*radius
            let side: Float = i.isMultiple(of:2) ? 1 : -1
            let clearance = width*(wide ? 0.85 : 0.75)+0.07
            cones.append(point)
            slalom.append(ChallengeGate(center:point+radial*side*clearance,normal:SIMD2(cos(a),-sin(a)),halfWidth:width*(wide ? 0.95 : 0.75)))
        }
        func transform(_ p: SIMD2<Float>) -> SIMD2<Float> { origin + SIMD2(cos(heading),-sin(heading))*p.x + SIMD2(sin(heading),cos(heading))*p.y }
        func direction(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(cos(heading),-sin(heading))*p.x + SIMD2(sin(heading),cos(heading))*p.y }
        gates = gates.map { ChallengeGate(center:transform($0.center),normal:direction($0.normal),halfWidth:$0.halfWidth) }
        slalom = slalom.map { ChallengeGate(center:transform($0.center),normal:direction($0.normal),halfWidth:$0.halfWidth) }
        let park = ParkingZone(center:transform(SIMD2(0,length*0.4)),heading:heading,
            halfSize:SIMD2(width*0.85,length*0.8),tolerance:(mission.chapter < 4 ? 20 : 16) * .pi/180)
        let padding = length*1.03
        let corners = [SIMD2(-radius-padding,-length),SIMD2(radius+padding,-length),SIMD2(-radius-padding,center.y+radius+padding),SIMD2(radius+padding,center.y+radius+padding)].map(transform)
        return ChallengeLayout(gates:gates,cones:cones.map(transform),slalomGates:slalom,parking:park,orbitCenter:transform(center),orbitRadius:radius,
            boundsMin:corners.reduce(SIMD2(repeating:Float.infinity),simd_min),boundsMax:corners.reduce(SIMD2(repeating:-Float.infinity),simd_max),origin:origin,heading:heading,
            carHalfSize:SIMD2(width/2,length/2),accelerationSpeed:min(speed*0.5,0.65),compact:compact)
    }
    /// A grid over the complete floor footprint, not only prop centers.
    func fits(_ contains: (SIMD2<Float>) -> Bool) -> Bool {
        let columns = max(1,Int(ceil((boundsMax.x-boundsMin.x)/0.10)))
        let rows = max(1,Int(ceil((boundsMax.y-boundsMin.y)/0.10)))
        for x in 0...columns { for y in 0...rows {
            let point = boundsMin + (boundsMax-boundsMin) * SIMD2(Float(x)/Float(columns),Float(y)/Float(rows))
            if !contains(point) { return false }
        } }
        return true
    }
}

/// Fixed-step skill detection. No camera transform, display unit or wall clock enters here.
struct DrivingEvaluator {
    private var previous: DriveSample?
    private var clean: Double = 0
    private var entry: Double = 0, chainTime: Double = 0, chainPoints: Double = 0, grace: Double = 0
    private var entered = false, chainSide = 0, lastBankSide = 0
    private var lastBankAge: Double = 100
    private var contactCooldown: Double = 0
    private var orbitAngle: Float = 0, orbitDirection: Float = 0
    private var orbitArc: Float = 0, orbitTime: Float = 0, orbitDrift: Float = 0
    private var radii: [Float] = [], speeds: [Float] = []
    private var orbitClean = true
    private var orbitSampleClock: Float = 0
    private var gateIndex = 0, slalomIndex = 0
    private var gateArmed = true, slalomArmed = true
    private var parkHold: Double = 0, parkArmed = false, parkAwarded = false
    private var accelerationDwell: Double = 0, accelerationArmed = false
    private var stopHold: Double = 0, traveledSinceStop: Float = 0
    private var brakedSinceStop = false
    private var freeStopDistance: Float = 0
    private var freeStopArmed = false
    private var turnTravel: Float = 0, turnSign: Float = 0
    private var circleSweep: Float = 0
    private var uTurnSweep: Float = 0, straightTime: Double = 0
    private var handTurnSweep: Float = 0, handTurnWindow: Double = 0, handTurnLive = false
    private var sinceUpshift: Double = 100
    private var heldGear = 0, gearHold: Double = 0
    var layout: ChallengeLayout?
    var assisted = false
    var requiredParkHold: Double = 2
    var reverseGate = false
    var guidance = "Keep moving to build progress."

    mutating func discontinuity() {
        previous = nil
        freeStopDistance = 0; freeStopArmed = false
        entry = 0; entered = false; chainTime = 0; chainPoints = 0; grace = 0
        turnTravel = 0; clearOrbit()
        uTurnSweep = 0; straightTime = 0; handTurnLive = false; gearHold = 0; heldGear = 0
    }
    mutating func resetCourseProgress() { gateIndex = 0; slalomIndex = 0; gateArmed = true; slalomArmed = true; parkHold = 0 }
    mutating func reset() {
        let l = layout, a = assisted, p = requiredParkHold, r = reverseGate
        self = DrivingEvaluator(); layout = l; assisted = a; requiredParkHold = p; reverseGate = r
    }
    private mutating func clearOrbit() {
        orbitAngle = 0; orbitArc = 0; orbitTime = 0; orbitDrift = 0; radii.removeAll(keepingCapacity:true); speeds.removeAll(keepingCapacity:true); orbitClean = true; orbitDirection = 0; orbitSampleClock = 0
    }
    mutating func consume(_ sample: DriveSample) -> DrivingEvents {
        var result = DrivingEvents()
        guard sample.active, sample.dt.isFinite, sample.dt > 0, sample.dt <= 0.11,
              sample.position.x.isFinite, sample.position.y.isFinite, sample.heading.isFinite, sample.speed.isFinite, sample.yawRate.isFinite, sample.contact.isFinite else {
            discontinuity(); return result
        }
        guard let old = previous else { previous = sample; return result }
        previous = sample
        let dt = Double(sample.dt), travel = simd_distance(sample.position,old.position)
        guard travel <= max(0.04, (sample.speed+old.speed)*sample.dt*0.7+0.015) else {
            reset(); previous = sample; guidance = "Position changed. Start the technique again."; return result
        }
        let moving = sample.speed > 0.12 && travel > 0.000001
        result.distance = moving ? Double(travel) : 0; result.movingTime = moving ? dt : 0
        lastBankAge += dt; contactCooldown = max(0,contactCooldown-dt)
        let collision = sample.contact > 0.08
        result.coneContact = sample.coneContact
        if sample.coneContact { orbitClean = false }
        if collision { orbitClean = false; clean = 0 }
        if collision && contactCooldown == 0 { result.collided = true; contactCooldown = 0.4 }
        if moving { if !collision { clean += dt }; traveledSinceStop += travel }
        // An ordinary pedal stop needs no painted bay, target speed, or dwell.
        // BRAKE transitions to reverse, so a half-second hold would miss it.
        if collision { freeStopDistance = 0; freeStopArmed = false }
        else {
            if moving { freeStopDistance += travel }
            if freeStopDistance >= 0.4 && sample.braking && max(old.speed, sample.speed) > 0.08 {
                freeStopArmed = true
            }
            if freeStopArmed && sample.speed < 0.08 {
                result.brakeStops = 1; freeStopDistance = 0; freeStopArmed = false
            }
        }
        result.cleanTime = clean
        if moving && sample.forwardSpeed < -0.08 { result.reverseDistance = Double(travel) }
        everydayTechniques(sample, old: old, travel: travel, moving: moving, collision: collision, dt: dt, into: &result)
        let angle = abs(sample.slip)*180 / .pi
        let qualifies = sample.speed >= (assisted ? 0.40 : 0.48) && sample.forwardSpeed > 0.12
            && angle >= 12 && angle <= 55 && abs(sample.yawRate) > 0.12 && moving
        let invalid = sample.contact > 0.35 || angle > 72 || sample.forwardSpeed < -0.1
        if invalid {
            clearOrbit()
            entry = 0; chainTime = 0; chainPoints = 0; entered = false; grace = 0
            guidance = sample.contact > 0.35 ? "Contact ended this slide. Banked points are safe." : "Ease off and straighten the car."
        } else if qualifies {
            let side = sample.slip >= 0 ? 1 : -1
            if entered && side != chainSide {
                // A direction change starts a new stable segment; zero-slip jitter
                // cannot turn the end of an old chain into a new linked drift.
                if chainTime >= 0.25 {
                    result.driftHold = chainTime; result.driftPoints = floor(chainPoints); result.drifts = 1
                    result.driftSide = chainSide
                    if chainSide != lastBankSide && lastBankSide != 0 && lastBankAge < 5 { result.driftLinks = 1 }
                    lastBankSide = chainSide; lastBankAge = 0
                }
                entered = false; entry = 0; chainTime = 0; chainPoints = 0
            }
            if !entered && side != chainSide { entry = 0; chainSide = side }
            grace = 0; entry += dt
            if entry >= 0.25 { entered = true }
            if entered {
                chainTime += dt; chainSide = sample.slip >= 0 ? 1 : -1
                let angleQuality = min(1.5,max(1,Double(angle)/30))
                let speedQuality = min(1.5,max(1,Double(sample.speed)/0.8))
                let combo = min(2,1+chainTime/6)
                chainPoints += dt*20*angleQuality*speedQuality*combo
                if result.drifts == 0 { result.driftSide = chainSide }
                guidance = "Hold the curve; unwind gently to bank it."
            }
        } else {
            if !entered { entry = 0 }
            grace += dt
            if grace > 0.32 {
                if entered && chainTime >= 0.25 {
                    result.driftHold = chainTime; result.driftPoints = floor(chainPoints * (collision ? 0.75 : 1)); result.drifts = 1
                    result.driftSide = chainSide
                    if chainSide != lastBankSide && lastBankSide != 0 && lastBankAge < 5 { result.driftLinks = 1 }
                    lastBankSide = chainSide; lastBankAge = 0
                    guidance = "Slide banked."
                }
                entered = false; chainTime = 0; chainPoints = 0; entry = 0
            }
        }
        if sample.contact > 0.08 && sample.contact <= 0.35 { chainPoints *= max(0,1-0.25*dt/0.4) }
        // Clean turn is actual curved translation, with stable direction, not a heading jump.
        let turn = angleDifference(sample.heading,old.heading)
        if moving && sample.forwardSpeed > 0.1 && angle < 35 && !collision {
            let sign: Float = turn >= 0 ? 1 : -1
            if sign != turnSign { turnTravel = 0; turnSign = sign }
            turnTravel += abs(turn)
            if turnTravel >= .pi/3 { if sign > 0 { result.leftTurns = 1 } else { result.rightTurns = 1 }; turnTravel = 0 }
        }
        if collision { turnTravel = 0; brakedSinceStop = false }
        if moving && sample.braking { brakedSinceStop = true }
        result.recovered = moving && angle < 8 && abs(sample.yawRate) < 0.3
        if sample.speed < 0.08 { stopHold += dt } else { stopHold = 0 }
        if stopHold >= 0.5 && traveledSinceStop > 0.4 && brakedSinceStop { result.stopped = true; traveledSinceStop = 0; brakedSinceStop = false }
        guard let layout else { return result }
        // Re-arm only after leaving the bay by a meaningful distance. One hold is one attempt.
        let inBay = layout.parking.contains(position:sample.position,heading:sample.heading,halfSize:layout.carHalfSize)
        if simd_distance(sample.position,layout.parking.center) > layout.parking.halfSize.y+layout.carHalfSize.y+0.15 {
            parkArmed = true; parkAwarded = false
        }
        if inBay && sample.speed < 0.08 && !collision { parkHold += dt } else { parkHold = 0 }
        result.parking = parkArmed ? parkHold : 0
        if parkArmed && !parkAwarded && parkHold >= requiredParkHold {
            result.parks = 1; parkAwarded = true; parkArmed = false
            if accelerationArmed { result.accelerationStops = 1; accelerationArmed = false; accelerationDwell = 0 }
        }
        if sample.forwardSpeed >= layout.accelerationSpeed && !collision { accelerationDwell += dt }
        else if !accelerationArmed { accelerationDwell = 0 }
        if accelerationDwell >= 0.3 { accelerationArmed = true }
        if collision {
            accelerationArmed = false; accelerationDwell = 0; parkHold = 0
            gateIndex = 0; gateArmed = true
        }
        if collision || sample.coneContact { slalomIndex = 0; slalomArmed = true }
        if !layout.gates.isEmpty {
            var gate = layout.gates[gateIndex % layout.gates.count]
            if reverseGate { gate.normal = -gate.normal }
            let directionOK = reverseGate ? sample.forwardSpeed < -0.08 : sample.forwardSpeed > 0.08
            if simd_dot(sample.position-gate.center,gate.normal) < -0.03 { gateArmed = true }
            if !collision && gateArmed && directionOK && gate.crossed(from:old.position,to:sample.position,carHalfWidth:layout.carHalfSize.x) {
                result.gates = 1; gateIndex += 1; gateArmed = false
            }
        }
        if !layout.slalomGates.isEmpty && !sample.coneContact && !collision {
            let gate = layout.slalomGates[slalomIndex % layout.slalomGates.count]
            if simd_dot(sample.position-gate.center,gate.normal) < -0.03 { slalomArmed = true }
            if slalomArmed && sample.forwardSpeed > 0.08 && gate.crossed(from:old.position,to:sample.position,carHalfWidth:layout.carHalfSize.x) {
                result.slalom = 1; slalomIndex += 1; slalomArmed = false
            }
        }
        // Orbit is position around the marked center. Heading-only spins earn nothing.
        let a = old.position-layout.orbitCenter, b = sample.position-layout.orbitCenter
        let radius = simd_length(b), expected = layout.orbitRadius
        let angular = angleDifference(atan2(b.x,b.y),atan2(a.x,a.y))
        let sign: Float = angular >= 0 ? 1 : -1
        let tolerance: Float = assisted ? 0.55 : 0.38
        if moving && sample.forwardSpeed > 0.1 && abs(radius-expected) <= expected*tolerance && abs(angular) < 0.15 {
            if orbitDirection != 0 && sign != orbitDirection && abs(angular) > 0.001 { clearOrbit() }
            if abs(angular) > 0.00001 { orbitDirection = sign }
            orbitAngle += abs(angular); orbitArc += travel; orbitTime += sample.dt
            if qualifies { orbitDrift += sample.dt }
            // At most 360 samples; sample spacing is independent of display FPS.
            orbitSampleClock += sample.dt
            if orbitSampleClock >= 1/30 {
                orbitSampleClock.formTruncatingRemainder(dividingBy:1/30)
                radii.append(radius); speeds.append(sample.speed)
                if radii.count > 360 { radii.removeFirst(); speeds.removeFirst() }
            }
            result.orbitFraction = Double(min(1,orbitAngle/(2 * .pi)))
            if orbitAngle >= 2 * .pi {
                let coverage = orbitDrift/max(orbitTime,0.001)
                func cv(_ values: [Float]) -> Float {
                    guard !values.isEmpty else { return 1 }
                    let mean = values.reduce(0,+)/Float(values.count)
                    guard mean > 0.001 else { return 1 }
                    return sqrt(values.reduce(0) { $0+pow($1-mean,2) }/Float(values.count))/mean
                }
                if orbitArc >= 2 * .pi * expected * 0.65 && coverage >= (assisted ? 0.25 : 0.5) {
                    result.donuts = 1
                    if orbitClean && coverage >= 0.8 && cv(radii) < 0.20 && cv(speeds) < 0.25 { result.perfectDonuts = 1 }
                }
                let residual = orbitAngle-2 * .pi; clearOrbit(); orbitAngle = residual
            }
        } else { clearOrbit() }
        return result
    }
    /// Turns, stops, speed and gears from ordinary driving. Heading only counts
    /// while the car is travelling, so pushing against a wall earns nothing.
    private mutating func everydayTechniques(_ sample: DriveSample, old: DriveSample, travel: Float, moving: Bool,
                                             collision: Bool, dt: Double, into result: inout DrivingEvents) {
        result.rollDistance = moving ? Double(travel) : 0
        // Automatic Brake turns into reverse the moment the car stops, so a
        // stop can be a single pass through walking pace.
        result.halted = sample.speed < 0.05
        result.braked = moving && sample.braking
        if moving && sample.forwardSpeed > 0 { result.speed = Double(sample.forwardSpeed) }

        let turning = travel > 0.0005 && !collision
        let delta = turning ? angleDifference(sample.heading, old.heading) : 0
        // A full circle is net heading change in one direction, built up in as
        // many arcs as the room needs.
        circleSweep += delta
        if abs(circleSweep) >= 2 * .pi {
            result.fullTurns = 1
            circleSweep -= circleSweep > 0 ? 2 * .pi : -2 * .pi
        }
        // A U-turn is one continuous turn through 160°: straightening up for
        // more than a moment or turning back the other way starts again.
        if abs(delta) / max(sample.dt, 0.0001) < 0.15 {
            straightTime += dt
            if straightTime > 1.5 { uTurnSweep = 0 }
        } else {
            straightTime = 0
            if uTurnSweep != 0 && (delta > 0) != (uTurnSweep > 0) { uTurnSweep = 0 }
            uTurnSweep += delta
            if abs(uTurnSweep) >= 160 * .pi / 180 { result.uTurns = 1; uTurnSweep = 0 }
        }
        // One handbrake turn per press: the car must swing 30° while Hand is
        // held or just after it is let go.
        if sample.handbrake && !old.handbrake && sample.forwardSpeed >= 0.2 {
            handTurnLive = true; handTurnSweep = 0
        }
        if handTurnLive {
            handTurnWindow = sample.handbrake ? 0.6 : handTurnWindow - dt
            handTurnSweep += abs(delta)
            if handTurnSweep >= 30 * .pi / 180 { result.handbrakeTurns = 1; handTurnLive = false }
            else if handTurnWindow <= 0 { handTurnLive = false }
        }
        // Gears count in manual only, and only while the car is going somewhere.
        sinceUpshift += dt
        if sample.manual && old.manual && old.gear >= 1 && sample.gear > old.gear
            && sample.forwardSpeed >= 0.2 && sinceUpshift >= 0.35 {
            result.upshifts = 1; sinceUpshift = 0
        }
        if sample.manual && sample.gear >= 1 && moving && sample.forwardSpeed >= 0.2 {
            if sample.gear == heldGear { gearHold += dt } else { heldGear = sample.gear; gearHold = 0 }
            if gearHold >= 0.5 { result.gearReached = heldGear }
        } else { heldGear = 0; gearHold = 0 }
    }
    var liveDriftTime: Double { chainTime }
    var nextGate: Int { gateIndex }
    var nextCone: Int { slalomIndex }
}
