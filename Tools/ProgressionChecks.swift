import Foundation
import simd

@main @MainActor struct ProgressionChecks {
    static var checks = 0
    static var failures = 0
    static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(name)") }
    }
    static func rejected(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
    static func directory(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("DriveAR-check-\(name)-\(UUID().uuidString)") }
    static func main() throws {
        let all = MissionCatalog.career + MissionCatalog.dailyBank + MissionCatalog.mastery
        check("28 unique source cars", Set(ProgressionCatalog.ids).count == 28 && Set(ProgressionCatalog.ids) == Set(CarCatalog.all.map(\.id)))
        check("120 career",MissionCatalog.career.count == 120)
        check("75 daily",MissionCatalog.dailyBank.count == 75)
        check("168 mastery",MissionCatalog.mastery.count == 168)
        check("unique mission ids",Set(all.map(\.id)).count == 363)
        check("plain objectives replace vague titles",all.allSatisfy { $0.title == $0.shortObjective })
        check("no duplicate action and target within a chapter",Set(MissionCatalog.career.map { "\($0.chapter).\($0.metric.rawValue).\($0.target)" }).count == 120)
        check("every mission works without a generated course",all.allSatisfy { !$0.requiresCourse && $0.steps.isEmpty })
        check("all missions explicit",all.allSatisfy{!$0.objective.isEmpty && $0.target > 0 && !$0.failureRule.isEmpty && !$0.spatialRequirement.isEmpty})
        check("no required drift metrics", all.allSatisfy { ![MissionMetric.driftHold,.driftPoints,.driftCount,.driftLinks,.donuts].contains($0.metric) })
        check("no drift steps", all.allSatisfy { $0.steps.allSatisfy { ![Technique.drift,.driftLeft,.driftRight,.driftLink,.donut].contains($0.technique) } })
        try drivingGoalMigrationChecks()
        var fresh = ProgressionSave()
        check("fresh owns one, zero wallet",fresh.owned == ["mini-hatch"] && fresh.coins == 0 && fresh.stars == 0)
        fresh.selectedCar = "racer"; fresh.selectedPaints["mini-hatch"] = "crimson"; fresh.sanitize()
        check("selection sanitized",fresh.selectedCar == "mini-hatch" && fresh.selectedPaints["mini-hatch"] == "factory")
        var rich = fresh; rich.coins = 1_000_000
        for mission in MissionCatalog.career { rich.missions[mission.id] = MissionProgress(value:mission.target,completed:true) }
        check("predecessor enforced",rejected{try Economy.purchaseCar("rust-bucket",save:&rich)})
        try Economy.purchaseCar("runabout",save:&rich)
        let afterCar = rich.coins
        check("duplicate car purchase",rejected{try Economy.purchaseCar("runabout",save:&rich)} && rich.coins == afterCar)
        try Economy.upgrade("mini-hatch",part:.engine,expectedLevel:1,save:&rich)
        let afterUpgrade = rich.coins
        check("double tap exactly one transition",rejected{try Economy.upgrade("mini-hatch",part:.engine,expectedLevel:1,save:&rich)} && rich.coins == afterUpgrade && rich.parts["mini-hatch"]?[.engine] == 2)
        check("locked car upgrade refused",rejected{try Economy.upgrade("racer",part:.engine,expectedLevel:1,save:&rich)})
        var noPaint = ProgressionSave(); noPaint.coins = 100
        check("paint gate",rejected{try Economy.paint("mini-hatch",color:"azure",save:&noPaint)})
        for m in MissionCatalog.career.prefix(6) { noPaint.missions[m.id] = MissionProgress(value:m.target,completed:true) }; noPaint.sanitize()
        try Economy.paint("mini-hatch",color:"azure",save:&noPaint); let painted = noPaint.coins
        try Economy.paint("mini-hatch",color:"azure",save:&noPaint)
        check("paint permanent once",painted == 70 && noPaint.coins == painted)
        var earned = ProgressionSave()
        for m in MissionCatalog.career.prefix(2) { earned.missions[m.id] = MissionProgress(value:m.target,completed:true) }
        try Economy.grant(id:"reward.check",title:"Check",coins:ProgressionCatalog.prices[1],now:Date(),save:&earned)
        check("uncollected coins saved but not spendable",earned.coins == ProgressionCatalog.prices[1] && earned.wallet == 0
              && rejected{try Economy.purchaseCar("runabout",save:&earned)})
        for i in earned.ledger.indices { earned.ledger[i].presented = true }
        try Economy.purchaseCar("runabout",save:&earned)
        check("collected coins spendable",earned.wallet == 0 && earned.owned.contains("runabout"))
        try Economy.roadCoins(drive:"check",coins:5,now:Date(),save:&earned)
        for i in earned.ledger.indices { earned.ledger[i].presented = true }
        try Economy.roadCoins(drive:"check",coins:3,now:Date(),save:&earned)
        check("collected road coins never reopen",earned.uncollected == 3 && earned.wallet == 5
              && Set(earned.ledger.map(\.id)).count == earned.ledger.count)
        var reward = fresh
        try Economy.grant(id:"same",title:"Test",coins:15,now:Date(),save:&reward)
        try Economy.grant(id:"same",title:"Test",coins:15,now:Date(),save:&reward)
        check("idempotent reward",reward.coins == 15 && reward.ledger.count == 1)
        // Every chapter needs only the preceding chapter; no car prerequisite.
        var reachable = ProgressionSave()
        for chapter in 1...10 {
            check("chapter \(chapter) reachable",reachable.chapter >= chapter)
            for m in MissionCatalog.career where m.chapter == chapter {
                check("career stock eligible \(m.id)",m.carID == nil)
                reachable.missions[m.id] = MissionProgress(value:m.target,completed:true)
            }
        }
        check("120 stars before final ownership",reachable.stars == 120 && reachable.owned.count == 1)
        for chapter in 1...10 { let c = MissionCatalog.contract(chapter:chapter,serial:chapter); check("no wallet softlock \(chapter)",c.carID == nil && !c.requiresCourse && c.reward > 0) }
        let dir = directory("save"); defer { try? FileManager.default.removeItem(at:dir) }
        let store = try ProgressionStore(directory:dir)
        reward.migrateDrivingGoals()
        try store.write(reward)
        store.simulateWriteFailure = true
        var uncommitted = reward; try Economy.grant(id:"uncommitted",title:"No",coins:20,now:Date(),save:&uncommitted)
        check("failed write leaves prior generation",rejected{try store.write(uncommitted)})
        store.simulateWriteFailure = false
        let reloaded = try store.load()
        check("relaunch exact wallet",reloaded.coins == 15)
        try Data("broken".utf8).write(to:store.url)
        let backup = try store.load()
        check("backup recovery",backup.coins == 15)
        try store.write(reward)
        store.simulateInterruptionBeforeCommit = true
        check("interruption before rename",rejected{try store.write(uncommitted)})
        check("precommit backup is prior generation",try! store.load().coins == 15)
        store.simulateInterruptionBeforeCommit = false; store.simulateInterruptionAfterCommit = true
        try store.write(uncommitted)
        var committed = try store.load()
        try Economy.grant(id:"uncommitted",title:"No duplicate",coins:20,now:Date(),save:&committed)
        check("interruption after rename preserves exactly one credit",committed.coins == 35 && committed.ledger.count == 2)
        store.simulateInterruptionAfterCommit = false
        var invalid = reward; invalid.coins = -5; invalid.parts["mini-hatch"] = CarParts(levels:["engine":99]); invalid.missions["bad"] = MissionProgress(value:.nan); invalid.sanitize()
        check("finite bounded sanitize",invalid.coins == 0 && invalid.parts["mini-hatch"]?[.engine] == 5 && invalid.missions["bad"]?.value == 0)
        try dailyChecks()
        try modelChecks()
        tuneChecks()
        detectorChecks()
        try everydayDrivingChecks()
        additionalChecks()
        try paidUnlockChecks()
        try everydayTechniqueChecks()
        print("\(checks-failures)/\(checks) progression checks passed")
        if failures > 0 { exit(1) }
    }
    static func dailyChecks() throws {
        let utc = TimeZone(secondsFromGMT:0)!, date = ISO8601DateFormatter().date(from:"2026-09-30T23:59:00Z")!
        var s = ProgressionSave()
        _ = try DailySelector.refresh(now:date,zone:utc,save:&s)
        check("login exactly ten",s.coins == 10 && s.daily.slots.count == 3)
        _ = try DailySelector.refresh(now:date,zone:utc,save:&s)
        check("same day no duplication",s.coins == 10)
        let defs = s.daily.slots.compactMap{id in MissionCatalog.dailyBank.first{$0.id == id}}
        check("daily distinct family and tiers",Set(defs.map(\.metric)).count == 3 && Set(defs.map(\.difficulty)) == [0,1,2])
        _ = try DailySelector.refresh(now:date.addingTimeInterval(120),zone:utc,save:&s)
        check("legitimate midnight",s.coins == 20)
        let rollback = try DailySelector.refresh(now:date.addingTimeInterval(-86400),zone:utc,save:&s)
        check("rollback does not pay",rollback != nil && s.coins == 20)
        _ = try DailySelector.refresh(now:date.addingTimeInterval(100*86400),zone:utc,save:&s)
        check("forward jump grants one day",s.coins == 30)
        var travel = ProgressionSave()
        _ = try DailySelector.refresh(now:date,zone:utc,save:&travel)
        _ = try DailySelector.refresh(now:date.addingTimeInterval(600),zone:TimeZone(secondsFromGMT:12*3600)!,save:&travel)
        check("travel does not duplicate early",travel.coins == 10)
        _ = try DailySelector.refresh(now:date.addingTimeInterval(21*3600),zone:TimeZone(secondsFromGMT:12*3600)!,save:&travel)
        check("travel eligible after 20h",travel.coins == 20)
        let ny = TimeZone(identifier:"America/New_York")!
        var dst = ProgressionSave(); let before = ISO8601DateFormatter().date(from:"2026-11-01T05:30:00Z")!
        _ = try DailySelector.refresh(now:before,zone:ny,save:&dst)
        _ = try DailySelector.refresh(now:before.addingTimeInterval(3600),zone:ny,save:&dst)
        check("DST repeated hour pays once",dst.coins == 10)
    }
    static func drivingGoalMigrationChecks() throws {
        let dir = directory("no-drift-migration"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProgressionStore(directory: dir)
        var old = ProgressionSave()
        old.coins = 512; old.owned.insert("runabout"); old.parts["mini-hatch"] = CarParts.maximum
        old.paintShopUnlocked = true; old.selectedCar = "runabout"
        old.missions["career.01.05"] = MissionProgress(value:0.2)
        old.missions["career.01.06"] = MissionProgress(value:60,completed:true)
        old.missions["career.01.01"] = MissionProgress(value:3)
        old.missions["2026-10-01.daily.driftPoints.1"] = MissionProgress(value:30)
        old.ledger = [RewardRecord(id:"old-earned",title:"Saved reward",coins:25,date:.distantPast)]
        try store.write(old)
        var migrated = try store.load()
        check("migration retains money and all earned rewards",migrated.coins == old.coins && migrated.ledger == old.ledger && migrated.stars == old.stars)
        check("migration retains owned cars tuning paint and selection",migrated.owned == old.owned && migrated.parts == old.parts && migrated.paintShopUnlocked && migrated.selectedCar == old.selectedCar)
        check("migration keeps completed drift achievements",migrated.missions["career.01.06"] == old.missions["career.01.06"])
        check("migration clears unfinished changed units only",migrated.missions["career.01.05"]?.value == 0 && migrated.missions["career.01.01"]?.value == 3 && migrated.missions["2026-10-01.daily.driftPoints.1"]?.value == 0)
        migrated.missions["career.01.05"] = MissionProgress(value:9)
        try store.write(migrated)
        let reloaded = try store.load()
        check("migration runs once and preserves new progress",reloaded == migrated)
        let freshDir = directory("new-rule-save"); defer { try? FileManager.default.removeItem(at: freshDir) }
        let newStore = try ProgressionStore(directory:freshDir)
        var fresh = try newStore.load(); fresh.missions["career.01.06"] = MissionProgress(value:4)
        try newStore.write(fresh)
        let newReload = try newStore.load()
        check("new players never have current progress migrated",newReload.missions["career.01.06"]?.value == 4)
    }
    static func automaticGoalChecks() throws {
        let dir = directory("automatic"); defer { try? FileManager.default.removeItem(at: dir) }
        var old = ProgressionSave()
        for mission in MissionCatalog.career.prefix(3) {
            old.missions[mission.id] = MissionProgress(value: mission.target, completed: true)
        }
        old.pinned = MissionCatalog.career.prefix(3).map(\.id)
        old.active = Set(old.pinned)
        try ProgressionStore(directory: dir).write(old)
        let model = ProgressionModel(directory: dir)
        model.beginSession(carID: "mini-hatch")
        let pauseIDs = model.driveMissions.map(\.id)
        check("pause prefers different actions", Set(model.driveMissions.map(\.metric)).count == 3)
        check("legacy completed pins never occupy automatic HUD", model.automaticGoals(carID: "mini-hatch").allSatisfy { !model.progress($0).completed })
        check("unfinished driving goal replaces completed goals", model.automaticGoals(carID: "mini-hatch").first?.id == "career.01.04")
        model.consume(DrivingEvents(distance: 20, movingTime: 16, cleanTime: 16, fullTurns: 1, coinPickups: 3), carID: "mini-hatch", dt: 0.2, scoredChallenge: nil)
        check("unselected career goals earn rewards automatically", model.progress(MissionCatalog.career[4]).completed && model.progress(MissionCatalog.career[5]).completed)
        check("next locked chapter earns no early progress", model.progress(MissionCatalog.career[16]).value == 0)
        let paid = model.save.coins
        model.consume(DrivingEvents(distance: 20, movingTime: 16, cleanTime: 16, fullTurns: 1, coinPickups: 3), carID: "mini-hatch", dt: 0.2, scoredChallenge: nil)
        check("auto completion cannot pay twice", model.save.coins >= paid && model.save.ledger.filter { ["reward.career.01.05", "reward.career.01.06"].contains($0.id) }.count == 2)
        check("completed pause cards remain until Resume", model.driveMissions.map(\.id) == pauseIDs && model.progress(model.driveMissions[1]).completed)
        model.consume(DrivingEvents(reverseDistance: 1, brakeStops: 1), carID: "mini-hatch", dt: 0.2, scoredChallenge: nil)
        check("normal stops and reversing complete without selection", model.progress(MissionCatalog.career[3]).completed && model.progress(MissionCatalog.career[7]).completed)
        check("no invisible course required", model.nextCourse(carID: "mini-hatch") == nil)
        let oldCards = model.driveMissions.map(\.id)
        model.refreshDriveMissions()
        check("Resume fills three unfinished cards", model.driveMissions.count == 3 && model.driveMissions.allSatisfy { !model.progress($0).completed } && model.driveMissions.map(\.id) != oldCards)
        model.endSession()
        check("returning to garage clears the old course selection", model.selectedChallenge == nil)
        model.refreshDay()
        model.beginSession(carID: "mini-hatch")
        if let daily = model.dailyMissions.first(where: { !$0.requiresCourse }) {
            let event: DrivingEvents
            switch daily.metric {
            case .brakeStops: event = DrivingEvents(brakeStops: Int(daily.target))
            case .reverseDistance: event = DrivingEvents(reverseDistance: daily.target)
            case .distance: event = DrivingEvents(distance: daily.target)
            case .movingTime: event = DrivingEvents(movingTime: daily.target)
            case .cleanTime: event = DrivingEvents(movingTime: daily.target, cleanTime: daily.target)
            case .driftPoints: event = DrivingEvents(driftPoints: daily.target)
            case .driftHold: event = DrivingEvents(driftHold: daily.target)
            case .driftCount: event = DrivingEvents(drifts: Int(daily.target))
            case .driftLinks: event = DrivingEvents(driftLinks: Int(daily.target))
            case .coinPickups, .coinStreak: event = DrivingEvents(coinPickups: Int(daily.target))
            case .coinValue: event = DrivingEvents(coinValue: Int(daily.target))
            case .tenCoins: event = DrivingEvents(tenCoins: Int(daily.target))
            case .topSpeed: event = DrivingEvents(speed: daily.target)
            case .fullTurns: event = DrivingEvents(fullTurns: Int(daily.target))
            case .uTurns: event = DrivingEvents(uTurns: Int(daily.target))
            case .handbrakeTurns: event = DrivingEvents(handbrakeTurns: Int(daily.target))
            case .nonStop, .smooth: event = DrivingEvents(rollDistance: daily.target)
            default: event = DrivingEvents()
            }
            model.consume(event, carID: "mini-hatch", dt: 0.2, scoredChallenge: nil)
            check("daily goals activate without selecting a mission", model.progress(daily).completed)
        }
        let mastery = MissionCatalog.mastery.first { $0.carID == "mini-hatch" && $0.metric == .distance }!
        model.consume(DrivingEvents(distance: mastery.target), carID: "mini-hatch", dt: 0.2, scoredChallenge: nil)
        check("owned session car mastery tracks automatically", model.progress(mastery).completed)
        check("other car mastery never advances", MissionCatalog.mastery.filter { $0.carID != "mini-hatch" }.allSatisfy { model.progress($0).value == 0 })
        let contract = model.contract
        model.consume(DrivingEvents(distance: 500, movingTime: 500), carID: "mini-hatch", dt: 0.2, scoredChallenge: nil)
        check("repeatable goal replaces itself automatically", model.contract.id != contract.id)
        check("automatic goals always have a contract fallback", !model.automaticGoals(carID: "mini-hatch").isEmpty)
    }
    static func modelChecks() throws {
        let dir = directory("model"); defer { try? FileManager.default.removeItem(at:dir) }
        let m = ProgressionModel(directory:dir)
        check("cannot launch locked by selection",!m.canDrive("racer") && m.canDrive("mini-hatch"))
        m.beginSession(carID:"mini-hatch")
        m.consume(DrivingEvents(distance:5),carID:"mini-hatch",dt:0.1,scoredChallenge:nil)
        check("automatic durable reward",m.save.coins == 15 && m.save.stars == 1)
        m.consume(DrivingEvents(distance:5),carID:"mini-hatch",dt:0.1,scoredChallenge:nil)
        check("completed career never repays",m.save.ledger.filter { $0.id == "reward.career.01.01" }.count == 1)
        let resumed = ProgressionModel(directory:dir)
        check("relaunch completion atomic",resumed.save.coins == m.save.coins && resumed.save.stars == m.save.stars && resumed.pendingNotification != nil)
        m.consume(DrivingEvents(movingTime:7),carID:"mini-hatch",dt:0.1,scoredChallenge:nil)
        m.resetAttempt(message:"Test reset")
        check("cumulative survives reset",m.progress(MissionCatalog.career[1]).value == 7)
        m.refreshDay(); let old = m.save.daily.slots
        m.reroll(0); let rerolled = m.save.daily.slots
        m.reroll(1)
        check("one reroll stable",rerolled != old && m.save.daily.slots == rerolled)
        let stop = MissionCatalog.career[3]
        m.consume(DrivingEvents(brakeStops: 1), carID: "mini-hatch", dt: 0.2, scoredChallenge: nil)
        let stopReceipts = m.save.ledger.filter { $0.id == "reward." + stop.id }
        m.resetAttempt(message:"Reset")
        m.consume(DrivingEvents(brakeStops: 1), carID: "mini-hatch", dt: 0.2, scoredChallenge: nil)
        check("completed stop never repays after reset", stopReceipts.count == 1 && m.save.ledger.filter { $0.id == "reward." + stop.id } == stopReceipts)
        try automaticGoalChecks()
        let cleanDaily = MissionCatalog.dailyBank.first{$0.metric == .cleanTime}!
        check("daily moving streak is attempt scoped",cleanDaily.scope == .attempt)
    }
    static func everydayDrivingChecks() throws {
        let dir = directory("everyday-migration"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProgressionStore(directory: dir)
        var old = ProgressionSave()
        old.transactions.insert("mission-rules.no-drift.v1")
        old.coins = 723
        old.missions["career.01.04"] = MissionProgress(value: 0.5)
        old.missions["career.01.08"] = MissionProgress(value: 2)
        old.missions["career.01.09"] = MissionProgress(value: 3, completed: true)
        old.missions["career.01.05"] = MissionProgress(value: 9)
        old.missions["career.01.02"] = MissionProgress(value: 9)
        old.missions["2026-10-01.daily.parkingCount.1"] = MissionProgress(value: 0.8)
        old.missions["mastery.mini-hatch.6"] = MissionProgress(value: 1, completed: true)
        try store.write(old)
        var new = try store.load()
        check("second migration preserves wallet stars completed mastery", new.coins == 723 && new.stars == old.stars && new.missions["mastery.mini-hatch.6"] == old.missions["mastery.mini-hatch.6"])
        check("course progress migrates but existing drive counters survive", new.missions["career.01.04"]?.value == 0 && new.missions["career.01.08"]?.value == 0 && new.missions["career.01.02"]?.value == 9 && new.missions["career.01.09"]?.completed == true && new.missions["2026-10-01.daily.parkingCount.1"]?.value == 0)
        check("slots given a new technique restart their unfinished counter", new.missions["career.01.05"]?.value == 0)
        new.missions["career.01.08"] = MissionProgress(value: 0.7)
        try store.write(new)
        check("second migration runs once", try! store.load() == new)
        var allDaysValid = true
        for day in 0..<366 {
            let choices = DailySelector.choices(day: "2026-day-\(day)").compactMap { id in MissionCatalog.dailyBank.first { $0.id == id } }
            allDaysValid = allDaysValid && choices.count == 3 && Set(choices.map(\.metric)).count == 3 && Set(choices.map(\.difficulty)).count == 3
        }
        check("a full year always selects three distinct daily types", allDaysValid)
        // Retire the campaign to exercise the repeatable-contract pause fallback.
        var done = ProgressionSave(); done.migrateDrivingGoals()
        for m in MissionCatalog.career + MissionCatalog.mastery { done.missions[m.id] = MissionProgress(value: m.target, completed: true) }
        try store.write(done)
        let model = ProgressionModel(directory: dir); model.refreshDay(); model.beginSession(carID: "mini-hatch")
        let yesterday = model.save.daily.day
        model.refreshDay(now: Date().addingTimeInterval(86400))
        check("midnight refills even a full daily pause set", model.save.daily.day != yesterday && model.driveMissions.count == 3 && model.driveMissions.allSatisfy { model.definition($0.id) != nil })
        let contract = model.contract
        model.consume(DrivingEvents(distance: 1000, movingTime: 1000, cleanTime: 1000, reverseDistance: 100, brakeStops: 100,
                                    rollDistance: 1000, speed: 3, fullTurns: 100, uTurns: 100, handbrakeTurns: 100,
                                    coinPickups: 1000, coinValue: 1000, tenCoins: 100), carID: "mini-hatch", dt: 0.2, scoredChallenge: nil)
        model.refreshDriveMissions()
        let card = model.driveMissions.first { $0.mode == .contract }!
        model.consume(DrivingEvents(distance: 1000, movingTime: 1000), carID: "mini-hatch", dt: 0.2, scoredChallenge: nil)
        check("completed contract card survives replacement definition", model.driveMissions.contains { $0.id == card.id } && model.progress(card).completed && model.contract.id != card.id && contract.id != card.id)

        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        for car in ProgressionCatalog.cars {
            let geometry = try MeasuredCarGeometry(car: car, resources: resources)
            let rates = car.id == "mini-hatch" ? [30, 60, 120] : [60]
            for hz in rates { for hand in [false, true] {
                var vehicle = VehicleDynamics(tuning: geometry.base); vehicle.place(heading: 0)
                let input = DrivingInput(); input.isEnabled = true
                var detector = DrivingEvaluator(), stops = 0, reversed: Double = 0
                func advance(_ seconds: Int) {
                    for _ in 0..<hz*seconds {
                        vehicle.advance(deltaTime: 1/Float(hz), input: input, contacts: &NoContactBox.shared) { state, _, _, dt in
                            let event = detector.consume(DriveSample(position: state.position, heading: state.heading, velocity: state.velocity, yawRate: state.yawRate, dt: dt, active: input.isEnabled, braking: input.brake > 0 || input.handbrake > 0))
                            stops += event.brakeStops; reversed += event.reverseDistance
                        }
                    }
                }
                input.throttle = 1; advance(4)
                input.throttle = 0
                if hand { input.handbrake = 1 } else { input.brake = 1 }
                advance(5)
                check("stock \(car.id) \(hz)Hz \(hand ? "Hand" : "Brake") counts one normal stop", stops == 1)
                if !hand { check("stock \(car.id) automatic reverse counts", reversed >= 1) }
                input.releaseAll(); input.handbrake = 1; advance(3)
                // Reverse -> handbrake may legitimately add a second stop.
                let atRest = stops; advance(4)
                check("held pedal cannot farm stops \(car.id)", stops == atRest)
            } }
        }
        let starterGeometry = try MeasuredCarGeometry(car: CarCatalog.car(id: "mini-hatch"), resources: resources)
        var manual = VehicleDynamics(tuning: starterGeometry.base); manual.place(heading: 0)
        let manualInput = DrivingInput(); manualInput.isEnabled = true; manualInput.transmissionMode = .manual
        manualInput.requestShiftDown(); manual.advance(deltaTime: 1/60, input: manualInput)
        manualInput.throttle = 1
        var reverseDetector = DrivingEvaluator(), reverseMetres: Double = 0
        for _ in 0..<300 {
            manual.advance(deltaTime: 1/60, input: manualInput, contacts: &NoContactBox.shared) { state, _, _, dt in
                reverseMetres += reverseDetector.consume(DriveSample(position: state.position, heading: state.heading, velocity: state.velocity, yawRate: state.yawRate, dt: dt, active: true)).reverseDistance
            }
        }
        check("manual R plus GO counts the same reverse mission", reverseMetres > 1 && manual.drivetrainReadout.gear.isReverse)
        // Coasting, impacts, teleporting and pausing must never fabricate a stop.
        for reason in ["coast", "collision", "teleport", "pause"] {
            var detector = DrivingEvaluator()
            for i in 0...90 {
                _ = detector.consume(DriveSample(position: SIMD2(0, Float(i)/60), heading: 0, velocity: SIMD2(0, 1), yawRate: 0, dt: 1/60, active: true, braking: reason == "pause" && i == 90))
            }
            if reason == "pause" { detector.discontinuity() }
            let event = detector.consume(DriveSample(position: SIMD2(0, reason == "teleport" ? 10 : 1.501), heading: 0, velocity: .zero, yawRate: 0, dt: 1/60, active: true, contact: reason == "collision" ? 1 : 0, braking: reason != "coast"))
            check("\(reason) never earns a brake stop", event.brakeStops == 0)
        }
    }

    static func tuneChecks() {
        var rows = ["car,stock_mps,max_mps,stock_0.8_seconds,max_0.8_seconds"]
        for car in ProgressionCatalog.cars {
            let base = (try? MeasuredCarGeometry(car:car,resources:URL(fileURLWithPath:CommandLine.arguments[1])))?.base ?? EffectiveTuning.reference(for:car)
            var valid = true
            for code in 0..<3125 {
                var n = code, parts = CarParts()
                for part in UpgradePart.allCases { parts[part] = n%5+1; n /= 5 }
                let t = EffectiveTuning.resolve(base:base,carID:car.id,parts:parts)
                let values = [t.engineForce,t.topSpeed,t.mass,t.yawInertia,t.frontGrip,t.rearGrip,t.steerRate,t.transmission.peakDriveForce,t.transmission.finalDrive,t.dragCoefficient]
                valid = valid && values.allSatisfy{$0.isFinite && $0 > 0} && t.topSpeed <= 2.5 && t.wheelBase == base.wheelBase && t.maxSteerAngle == base.maxSteerAngle && t.frontGrip <= 1.25 && t.rearGrip <= 1.35
            }
            check("3125 mixed builds bounded \(car.id)",valid)
            var metrics: [(Float,Float)] = []
            let builds = [CarParts(),CarParts.maximum,
                          CarParts(levels:["engine":5,"transmission":1,"tires":1,"steering":5,"drift":5]),
                          CarParts(levels:["engine":1,"transmission":5,"tires":5,"steering":1,"drift":1]),
                          CarParts(levels:["engine":5,"transmission":3,"tires":1,"steering":1,"drift":5])]
            for parts in builds {
                let t = EffectiveTuning.resolve(base:base,carID:car.id,parts:parts)
                var d = VehicleDynamics(tuning:t); d.place(heading:0)
                let input = DrivingInput(); input.isEnabled = true; input.throttle = 1
                var reached: Float = 0
                for i in 0..<3600 {
                    d.advance(deltaTime:1/180,input:input)
                    if reached == 0 && d.state.speed >= 0.8 { reached = Float(i)/180 }
                }
                check("straight-line finite \(car.id)",d.state.isFinite && d.state.speed > 0.85 && d.state.speed < 2.6)
                metrics.append((d.state.speed,reached))
                for i in 0..<1800 {
                    input.steering = i < 900 ? 1 : -1; input.handbrake = i%360 < 90 ? 1 : 0
                    d.advance(deltaTime:1/180,input:input)
                    if !d.state.isFinite { valid = false }
                }
                check("corner/handbrake bounded \(car.id)",valid && d.state.isFinite && abs(d.state.yawRate) < 7)
            }
            check("stock slower \(car.id)",metrics[0].0 < metrics[1].0)
            rows.append("\(car.id),\(metrics[0].0),\(metrics[1].0),\(metrics[0].1),\(metrics[1].1)")
        }
        try? rows.joined(separator:"\n").write(to:URL(fileURLWithPath:"/tmp/drive-ar-tuning.csv"),atomically:true,encoding:.utf8)
    }
    static func detectorChecks() {
        let mission = MissionDefinition(id:"test.orbit",title:"Orbit physics",objective:"Detector fixture",mode:.career,metric:.donuts,target:1,scope:.cumulative,reward:0,assisted:true)
        let layout = ChallengeLayout.make(mission:mission,length:0.36,width:0.16,speed:1,origin:.zero,heading:0,compact:true)
        func orbit(hz: Float, turns: Float, slip: Float, speed: Float = 0.7, reverse: Bool = false, perfect: Bool = true) -> (Int,Int,Double,Double) {
            var detector = DrivingEvaluator(); detector.layout = layout
            var donuts = 0, perfects = 0, distance: Double = 0, points: Double = 0
            let radius = layout.orbitRadius, omega = speed/radius
            let count = Int((turns*2 * .pi/omega)*hz)
            for i in 0...count {
                let a = Float(i)/hz*omega
                let pos = layout.orbitCenter + SIMD2(sin(a),cos(a))*radius
                let velocity = SIMD2(cos(a),-sin(a))*speed
                let direction = atan2(velocity.x,velocity.y)
                let e = detector.consume(DriveSample(position:pos,heading:direction-slip+(reverse ? .pi : 0),velocity:velocity,yawRate:omega,dt:1/hz,active:true,contact:perfect ? 0 : (i == count/2 ? 0.1 : 0)))
                donuts += e.donuts; perfects += e.perfectDonuts; distance += e.distance; points += e.driftPoints
            }
            // Straighten to bank the final chain.
            for i in 1...Int(hz) {
                let a = Float(count)/hz*omega, velocity = SIMD2(cos(a),-sin(a))*speed
                let pos = layout.orbitCenter+SIMD2(sin(a),cos(a))*radius+velocity*Float(i)/hz
                let e = detector.consume(DriveSample(position:pos,heading:atan2(velocity.x,velocity.y),velocity:velocity,yawRate:0,dt:1/hz,active:true))
                points += e.driftPoints
            }
            return (donuts,perfects,distance,points)
        }
        let good = orbit(hz:180,turns:2.2,slip:0.40)
        check("standard and perfect orbit",good.0 == 2 && good.1 == 2)
        check("clean exit banks points",good.3 > 0)
        check("reverse orbit rejected",orbit(hz:180,turns:1.2,slip:0.4,reverse:true).0 == 0)
        check("non-sliding circle rejected",orbit(hz:180,turns:1.2,slip:0).0 == 0)
        check("contact loses perfect",orbit(hz:180,turns:1.2,slip:0.4,perfect:false).1 == 0)
        var still = DrivingEvaluator(), stillScore: Double = 0
        for i in 0..<2000 { let e = still.consume(DriveSample(position:.zero,heading:Float(i)*0.01,velocity:.zero,yawRate:2,dt:1/180,active:true)); stillScore += e.distance+e.driftPoints+Double(e.donuts) }
        check("heading-only stationary spin rejected",stillScore == 0)
        let gate = ChallengeGate(center:.zero,normal:SIMD2(0,1),halfWidth:0.3)
        check("swept gate",gate.crossed(from:SIMD2(0,-0.2),to:SIMD2(0,0.4),carHalfWidth:0.08))
        check("reverse gate denied",!gate.crossed(from:SIMD2(0,0.2),to:SIMD2(0,-0.2),carHalfWidth:0.08))
        check("stationary gate denied",!gate.crossed(from:.zero,to:.zero,carHalfWidth:0.08))
        check("wide footprint fails gate",!gate.crossed(from:SIMD2(0.26,-0.2),to:SIMD2(0.26,0.2),carHalfWidth:0.08))
        let park = ParkingZone(center:.zero,heading:0,halfSize:SIMD2(0.2,0.3),tolerance:20 * .pi/180)
        check("park footprint fits",park.contains(position:.zero,heading:0,halfSize:SIMD2(0.08,0.18)))
        check("park heading fails",!park.contains(position:.zero,heading:.pi/2,halfSize:SIMD2(0.08,0.18)))
        check("park overhang fails",!park.contains(position:SIMD2(0,0.2),heading:0,halfSize:SIMD2(0.08,0.18)))
        // Rendering does not sample telemetry: each renderer feeds identical fixed steps.
        var distances: [Double] = []
        for hz in [30,60,120] {
            var d = VehicleDynamics(tuning:EffectiveTuning.estimate(car:CarCatalog.car(id:"mini-hatch"),parts:CarParts()))
            let input = DrivingInput(); input.isEnabled = true; input.throttle = 1
            var detector = DrivingEvaluator(), distance: Double = 0
            for _ in 0..<hz*10 {
                d.advance(deltaTime:1/Float(hz),input:input,contacts:&NoContactBox.shared) { s,_,_,dt in
                    distance += detector.consume(DriveSample(position:s.position,heading:s.heading,velocity:s.velocity,yawRate:s.yawRate,dt:dt,active:true)).distance
                }
            }
            distances.append(distance)
        }
        check("30/60/120 fixed-step distance agreement",(distances.max()!-distances.min()!) < 0.012)
    }
}
enum NoContactBox { static var shared = NoContacts() }
