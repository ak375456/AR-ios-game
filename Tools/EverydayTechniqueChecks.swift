import Foundation
import simd

/// Everyday techniques: catalog shape, detection on real vehicle physics, and
/// the coin, camera and garage events that arrive from outside the evaluator.
extension ProgressionChecks {
    struct Run {
        var events = DrivingEvents()
        var distance: Float = 0
        var bestSpeed: Double = 0
        var halted = false, braked = false
        mutating func add(_ e: DrivingEvents) {
            events.fullTurns += e.fullTurns; events.uTurns += e.uTurns; events.handbrakeTurns += e.handbrakeTurns
            events.upshifts += e.upshifts; events.gearReached = max(events.gearReached, e.gearReached)
            bestSpeed = max(bestSpeed, e.speed); halted = halted || e.halted; braked = braked || e.braked
        }
    }

    /// Fixed 180 Hz physics fed straight into the shipping evaluator.
    static func drive(_ vehicle: inout VehicleDynamics, _ input: DrivingInput, _ detector: inout DrivingEvaluator,
                      seconds: Float, run: inout Run, until stop: ((Run) -> Bool)? = nil) {
        var evaluator = detector, totals = run
        defer { detector = evaluator; run = totals }
        for _ in 0..<Int(seconds * 180) {
            let start = vehicle.state.position
            vehicle.advance(deltaTime: 1/180, input: input, contacts: &NoContactBox.shared) { state, _, telemetry, dt in
                totals.add(evaluator.consume(DriveSample(position: state.position, heading: state.heading, velocity: state.velocity,
                    yawRate: state.yawRate, dt: dt, active: true, braking: input.brake > 0 || input.handbrake > 0,
                    handbrake: input.handbrake > 0, gear: telemetry.gear, manual: input.transmissionMode == .manual)))
            }
            totals.distance += simd_distance(start, vehicle.state.position)
            if stop?(totals) == true { return }
        }
    }

    static func everydayTechniqueChecks() throws {
        catalogChecks()
        try physicsChecks()
        try modelEventChecks()
    }

    static func catalogChecks() {
        let all = MissionCatalog.career + MissionCatalog.dailyBank + MissionCatalog.mastery
        for metric in MissionMetric.everyday {
            check("\(metric.rawValue) is offered", all.contains { $0.metric == metric })
            check("\(metric.rawValue) tracks without a course", metric.passive)
        }
        for chapter in MissionCatalog.careerChapters {
            let base = chapter.filter { [0, 1, 2, 3, 7].contains($0.seed % 12) }.map(\.metric)
            check("chapter \(chapter[0].chapter) keeps its five driving basics", base == [.distance, .movingTime, .cleanTime, .brakeStops, .reverseDistance])
            check("chapter \(chapter[0].chapter) has twelve distinct actions", Set(chapter.map(\.metric)).count == 12)
            check("chapter \(chapter[0].chapter) rewards stay with their slots", chapter.allSatisfy { $0.reward == MissionCatalog.reward(chapter: $0.chapter, difficulty: $0.difficulty) })
        }
        let gears = all.filter { $0.metric.needsManualGearbox }
        check("gear goals only from chapter 4, never above gear 4", gears.allSatisfy { $0.mode == .career && $0.chapter >= 4 && ($0.metric != .reachGear || $0.target <= 4) })
        check("daily never needs the manual gearbox, another car or the camera", MissionCatalog.dailyBank.allSatisfy { ![.upshifts, .reachGear, .carsDriven, .photos].contains($0.metric) })
        for tier in 0...2 {
            check("daily tier \(tier) has three distinct actions to choose from", Set(MissionCatalog.dailyBank.filter { $0.difficulty == tier }.map(\.metric)).count >= 3)
        }
        let collectors = MissionCatalog.career.filter { $0.metric == .carsDriven }
        check("car collection never outruns ownership stars", collectors.allSatisfy { m in
            ProgressionCatalog.stars[Int(m.target) - 1] <= (m.chapter - 1) * 8
        })
        check("runs restart on their own rule, not on bumps", [MissionMetric.coinStreak, .nonStop, .smooth].allSatisfy { $0.defaultScope == .attempt && !$0.restartsOnContact })
        check("older attempt goals still restart on contact", MissionMetric.cleanTime.restartsOnContact)
        let changed = MissionCatalog.varietyRevisedIDs
        check("only retargeted slots migrate", MissionCatalog.career.allSatisfy { changed.contains($0.id) == ![0, 1, 2, 3, 7].contains($0.seed % 12) }
              && !changed.contains("mastery.mini-hatch.1") && changed.contains("mastery.mini-hatch.6") && !changed.contains("daily.smooth.1"))
    }

    static func physicsChecks() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let starterGeometry = try MeasuredCarGeometry(car: CarCatalog.car(id: "mini-hatch"), resources: resources)
        func straightTop(_ parts: CarParts, metres: Float) -> Double {
            var vehicle = VehicleDynamics(tuning: EffectiveTuning.resolve(base: starterGeometry.base, carID: "mini-hatch", parts: parts))
            vehicle.place(heading: 0)
            let input = DrivingInput(); input.isEnabled = true; input.throttle = 1
            var detector = DrivingEvaluator(), run = Run()
            drive(&vehicle, input, &detector, seconds: 8, run: &run) { $0.distance >= metres }
            return run.bestSpeed
        }
        let stockStarter = straightTop(CarParts(), metres: 1.5)
        let earlySpeeds = (MissionCatalog.dailyBank + MissionCatalog.career.filter { $0.chapter <= 6 }).filter { $0.metric == .topSpeed }
        check("stock starter reaches every daily and early career speed in 1.5 m", earlySpeeds.allSatisfy { stockStarter >= $0.target })
        let chapter8 = MissionCatalog.career.first { $0.chapter == 8 && $0.metric == .topSpeed }!
        let chapter10 = MissionCatalog.career.first { $0.chapter == 10 && $0.metric == .topSpeed }!
        check("chapter 8 speed needs more than the stock starter", stockStarter < chapter8.target)
        check("transmission level 3 reaches the chapter 8 speed", straightTop(CarParts(levels: ["transmission": 3]), metres: 2) >= chapter8.target)
        check("a fully upgraded starter reaches the final speed in 2 m", straightTop(.maximum, metres: 2) >= chapter10.target)

        for car in ProgressionCatalog.cars {
            let geometry = try MeasuredCarGeometry(car: car, resources: resources)
            let tuning = EffectiveTuning.resolve(base: geometry.base, carID: car.id, parts: CarParts())
            let mastery = MissionCatalog.mastery.first { $0.carID == car.id && $0.metric == .topSpeed }!
            // Straight, full throttle: the showcase speed and no false turns.
            var vehicle = VehicleDynamics(tuning: tuning); vehicle.place(heading: 0)
            let input = DrivingInput(); input.isEnabled = true; input.throttle = 1
            var detector = DrivingEvaluator(), straight = Run()
            drive(&vehicle, input, &detector, seconds: 6, run: &straight) { $0.distance >= 2 }
            check("stock \(car.id) reaches its showcase speed in 2 m", straight.bestSpeed >= mastery.target)
            check("straight line earns no turns \(car.id)", straight.events.fullTurns == 0 && straight.events.uTurns == 0 && straight.events.handbrakeTurns == 0)
            var rolling = Run()
            drive(&vehicle, input, &detector, seconds: 0.5, run: &rolling)
            check("rolling never halts or brakes \(car.id)", !rolling.halted && !rolling.braked && !straight.braked)
            // Full lock: a U-turn first, then whole circles.
            input.steering = 1
            var circle = Run()
            drive(&vehicle, input, &detector, seconds: 4, run: &circle)
            check("full lock makes a U-turn within 4 s \(car.id)", circle.events.uTurns >= 1)
            drive(&vehicle, input, &detector, seconds: 8, run: &circle)
            check("full lock turns a full circle within 12 s \(car.id)", circle.events.fullTurns >= 1)
            // Handbrake turn from a straight: one per press, however long it is held.
            var hand = VehicleDynamics(tuning: tuning); hand.place(heading: 0)
            let handInput = DrivingInput(); handInput.isEnabled = true; handInput.throttle = 1
            var handDetector = DrivingEvaluator(), handRun = Run()
            drive(&hand, handInput, &handDetector, seconds: 1, run: &handRun)
            handInput.steering = 1; handInput.handbrake = 1
            drive(&hand, handInput, &handDetector, seconds: 2, run: &handRun)
            check("steer plus Hand is one handbrake turn \(car.id)", handRun.events.handbrakeTurns == 1 && handRun.braked)
            // Brake to a stop: the non-stop run breaks.
            handInput.releaseAll(); handInput.brake = 1
            var stop = Run()
            drive(&hand, handInput, &handDetector, seconds: 3, run: &stop) { $0.halted }
            check("braking to a stop breaks a non-stop run \(car.id)", stop.halted)
        }

        // Manual gearbox: shifts count only while moving, automatic shifts never do.
        var manual = VehicleDynamics(tuning: starterGeometry.base); manual.place(heading: 0)
        let stick = DrivingInput(); stick.isEnabled = true; stick.transmissionMode = .manual
        var stickDetector = DrivingEvaluator(), parked = Run()
        stick.requestShiftUp()
        drive(&manual, stick, &stickDetector, seconds: 0.5, run: &parked)
        stick.requestShiftUp()
        drive(&manual, stick, &stickDetector, seconds: 0.5, run: &parked)
        check("shifting while stopped counts nothing", parked.events.upshifts == 0 && parked.events.gearReached == 0)
        manual = VehicleDynamics(tuning: starterGeometry.base); manual.place(heading: 0)
        stickDetector = DrivingEvaluator()
        var shifting = Run()
        stick.throttle = 1
        for _ in 0..<3 {
            drive(&manual, stick, &stickDetector, seconds: 0.6, run: &shifting)
            stick.requestShiftUp()
        }
        drive(&manual, stick, &stickDetector, seconds: 1, run: &shifting)
        check("manual upshifts while moving count once each", shifting.events.upshifts == 3)
        check("holding gear 4 while moving reaches it", shifting.events.gearReached == 4)
        var auto = VehicleDynamics(tuning: starterGeometry.base); auto.place(heading: 0)
        let pedal = DrivingInput(); pedal.isEnabled = true; pedal.throttle = 1
        var autoDetector = DrivingEvaluator(), autoRun = Run()
        drive(&auto, pedal, &autoDetector, seconds: 5, run: &autoRun)
        check("automatic shifts never count for gear goals", autoRun.events.upshifts == 0 && autoRun.events.gearReached == 0 && auto.drivetrainReadout.gear.index > 1)

        // Heading changes without travel, and teleports, earn no turns.
        var wall = DrivingEvaluator(), spins = 0
        for i in 0..<2000 {
            let e = wall.consume(DriveSample(position: .zero, heading: Float(i) * 0.02, velocity: SIMD2(0.5, 0.5), yawRate: 3, dt: 1/180, active: true, contact: 0.4))
            spins += e.fullTurns + e.uTurns + e.handbrakeTurns
        }
        check("spinning against a wall earns no turns", spins == 0)
        var jump = DrivingEvaluator(), jumped = 0
        for i in 0..<400 {
            let e = jump.consume(DriveSample(position: i == 200 ? SIMD2(9, 9) : SIMD2(0, Float(i) * 0.003), heading: i >= 200 ? .pi : 0, velocity: SIMD2(0, 0.6), yawRate: 0, dt: 1/180, active: true))
            jumped += e.fullTurns + e.uTurns
        }
        check("a teleport and flipped heading earn no turn", jumped == 0)
    }

    static func modelEventChecks() throws {
        // Attempt rules for the new runs.
        let streak = MissionCatalog.career.first { $0.metric == .coinStreak }!
        var attempt = MissionAttempt(), progress = MissionProgress()
        attempt.advance(streak, event: DrivingEvents(coinPickups: 2), progress: &progress)
        attempt.advance(streak, event: DrivingEvents(collided: true), progress: &progress)
        check("a bump keeps the coin streak", progress.value == 2)
        attempt.advance(streak, event: DrivingEvents(coinMissed: true), progress: &progress)
        check("a missed coin restarts the streak", progress.value == 0)
        let nonStop = MissionCatalog.career.first { $0.metric == .nonStop }!
        progress = MissionProgress()
        attempt.advance(nonStop, event: DrivingEvents(rollDistance: 2), progress: &progress)
        attempt.advance(nonStop, event: DrivingEvents(braked: true), progress: &progress)
        check("braking without stopping keeps a non-stop run", progress.value == 2)
        attempt.advance(nonStop, event: DrivingEvents(halted: true), progress: &progress)
        check("stopping restarts a non-stop run", progress.value == 0)
        let smooth = MissionCatalog.career.first { $0.metric == .smooth }!
        progress = MissionProgress()
        attempt.advance(smooth, event: DrivingEvents(rollDistance: 2), progress: &progress)
        attempt.advance(smooth, event: DrivingEvents(halted: true), progress: &progress)
        check("coasting to a stop keeps a smooth run", progress.value == 2)
        attempt.advance(smooth, event: DrivingEvents(braked: true), progress: &progress)
        check("braking restarts a smooth run", progress.value == 0)
        let speed = MissionCatalog.career.first { $0.metric == .topSpeed }!
        progress = MissionProgress()
        attempt.advance(speed, event: DrivingEvents(speed: speed.target * 0.8), progress: &progress)
        attempt.advance(speed, event: DrivingEvents(speed: speed.target * 0.3), progress: &progress)
        check("top speed keeps the best run", progress.value == speed.target * 0.8)

        // Coins, photos and the pause cards on a live model.
        let dir = directory("everyday"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = ProgressionModel(directory: dir)
        model.beginSession(carID: "mini-hatch")
        let pickups = MissionCatalog.career.first { $0.chapter == 1 && $0.metric == .coinPickups }!
        let worth = MissionCatalog.career.first { $0.chapter == 1 && $0.metric == .coinValue }!
        let wallet = model.save.coins
        for _ in 0..<Int(pickups.target) { model.collectRoadCoins(2, carID: "mini-hatch") }
        check("coin pickups complete their goal", model.progress(pickups).completed)
        check("coin value counts each coin's face value", model.progress(worth).value == pickups.target * 2)
        check("pickups still credit the wallet", model.save.coins >= wallet + Int(pickups.target) * 2)
        check("the free trial car collects nothing", !model.collectRoadCoins(5, carID: ProgressionCatalog.trialCar))
        let photo = MissionCatalog.career.first { $0.metric == .photos }!
        let carPhoto = MissionCatalog.mastery.first { $0.carID == "mini-hatch" && $0.metric == .photos }!
        let otherPhoto = MissionCatalog.mastery.first { $0.carID == "runabout" && $0.metric == .photos }!
        model.recordPhoto(carID: "mini-hatch")
        check("a photo completes the career and this car's mastery photo", model.progress(photo).completed && model.progress(carPhoto).completed)
        check("another car's photo goal never advances", model.progress(otherPhoto).value == 0)
        model.manualGearbox = false
        check("gear goals stay off pause cards in automatic", model.automaticGoals(carID: "mini-hatch", limit: .max).allSatisfy { !$0.metric.needsManualGearbox && $0.metric != .carsDriven })

        // Car collection counts each owned car once, after a real metre of driving.
        var save = ProgressionSave()
        for m in MissionCatalog.career where m.chapter <= 2 { save.missions[m.id] = MissionProgress(value: m.target, completed: true) }
        save.owned.insert("runabout"); save.migrateDrivingGoals()
        let garage = directory("collection"); defer { try? FileManager.default.removeItem(at: garage) }
        try ProgressionStore(directory: garage).write(save)
        let collector = ProgressionModel(directory: garage)
        let two = MissionCatalog.career.first { $0.metric == .carsDriven && $0.target == 2 }!
        collector.beginSession(carID: "mini-hatch")
        collector.consume(DrivingEvents(distance: 0.5), carID: "mini-hatch", dt: 0.1, scoredChallenge: nil)
        check("half a metre is not a drive", collector.progress(two).value == 0)
        collector.consume(DrivingEvents(distance: 0.6), carID: "mini-hatch", dt: 0.1, scoredChallenge: nil)
        collector.consume(DrivingEvents(distance: 5), carID: "mini-hatch", dt: 0.1, scoredChallenge: nil)
        check("the first car counts once", collector.progress(two).value == 1)
        collector.endSession(); collector.beginSession(carID: "runabout")
        collector.consume(DrivingEvents(distance: 1.2), carID: "runabout", dt: 0.1, scoredChallenge: nil)
        check("a second owned car completes Drive 2 different cars", collector.progress(two).completed)
        collector.endSession(); collector.beginSession(carID: "mini-hatch")
        collector.consume(DrivingEvents(distance: 3), carID: "mini-hatch", dt: 0.1, scoredChallenge: nil)
        check("driving a counted car again adds nothing", collector.save.transactions.filter { $0.hasPrefix("driven.") }.count == 2)

        // Existing players: cars with mastery progress were driven before the update.
        var veteran = ProgressionSave()
        // Already through the two earlier rule changes, so only this update applies.
        veteran.transactions.formUnion(["mission-rules.no-drift.v1", "mission-rules.everyday.v2"])
        veteran.owned.formUnion(["runabout", "rust-bucket"])
        veteran.missions["mastery.mini-hatch.1"] = MissionProgress(value: 4)
        veteran.missions["mastery.runabout.2"] = MissionProgress(value: 30, completed: true)
        veteran.missions["career.02.05"] = MissionProgress(value: 7)
        veteran.missions["career.01.01"] = MissionProgress(value: 3)
        veteran.migrateDrivingGoals()
        check("earlier drives count toward car collection", veteran.transactions.isSuperset(of: ["driven.mini-hatch", "driven.runabout"]) && !veteran.transactions.contains("driven.rust-bucket"))
        check("update restarts only retargeted counters", veteran.missions["career.02.05"]?.value == 0 && veteran.missions["career.01.01"]?.value == 3)
    }
}
