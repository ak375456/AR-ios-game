import Foundation

/// Deterministic expected-time model; durations/retry rates are assumptions, not
/// phone measurements. Reads the shipping catalogs and uses the real transactions.
@main struct EconomySimulation {
    struct Profile {
        let name: String, speed: Double, moving: Double, success: [Double]
    }
    static let profiles = [
        Profile(name:"Newcomer",speed:0.48,moving:0.55,success:[0.85,0.60,0.40,0.45]),
        Profile(name:"Average",speed:0.65,moving:0.72,success:[0.95,0.80,0.65,0.72]),
        Profile(name:"Skilled",speed:0.85,moving:0.85,success:[0.99,0.94,0.88,0.90])]
    static func duration(_ m: MissionDefinition, _ p: Profile) -> Double {
        let target = m.target
        let raw: Double
        switch m.metric {
        case .brakeStops: raw = target * 6
        case .reverseDistance: raw = target / (p.speed * p.moving * 0.3)
        case .distance: raw = target/(p.speed*p.moving)
        case .movingTime: raw = target/p.moving
        case .cleanTime: raw = target/p.moving
        case .accelerationStops: raw = target*14
        case .driftHold: raw = 12+target*3
        case .driftPoints: raw = target/(22*p.moving*0.45)
        case .donuts: raw = target*22
        case .slalom: raw = target*7
        case .gates: raw = target*5
        case .parking: raw = 14+target
        case .driftCount: raw = target*15
        case .parkingCount: raw = target*18
        case .slalomRuns: raw = target*28
        case .gateLaps: raw = target*20
        case .driftLinks: raw = target*25
        case .sequence: raw = max(25,Double(m.steps.count)*16)
        case .capstone: raw = 45+Double(m.chapter)*3
        // Road coins: one pickup per ~6 moving seconds, worth 2.35 on average;
        // a 10 turns up about once in 15 coins.
        case .coinPickups, .coinStreak: raw = target*6/p.moving
        case .coinValue: raw = target/2.35*6/p.moving
        case .tenCoins: raw = target*15*6/p.moving
        case .topSpeed: raw = 20
        case .fullTurns: raw = target*8
        case .uTurns: raw = target*6
        case .handbrakeTurns: raw = target*6
        case .nonStop: raw = target/p.speed
        case .smooth: raw = target/(p.speed*0.9)
        case .upshifts: raw = target*4
        case .reachGear: raw = 15
        case .photos: raw = target*15
        case .carsDriven: raw = 60
        }
        let cumulative = [.distance,.movingTime].contains(m.metric)
        return (raw+(m.requiresCourse ? 3 : 0))/(cumulative ? 1 : p.success[min(3,m.difficulty)])
    }
    struct Route {
        let profile: Profile
        let upgrades: Bool, dailies: Bool
        var save = ProgressionSave()
        var seconds: Double = 0, firstUpgrade: Double = 0, secondCar: Double = 0
        var purchasedAt: [Double] = [0]
        var income: [String:Int] = [:]
        var spending: [String:Int] = [:]
        var automaticValue: [String:Double] = [:]
        var activeDailies: [MissionDefinition] = []
        var contractValue: Double = 0
        var contractDefinition = MissionCatalog.contract(chapter:1,serial:0)
        var completedDays: Set<Int> = []
        var visitedMastery: Set<String> = []
        var maxPurchaseGap: Double = 0
        var nextDailySet = 0
        mutating func grant(_ id: String, _ amount: Int, _ category: String) {
            if save.transactions.contains(id) { return }
            try! Economy.grant(id:id,title:id,coins:amount,now:Date(timeIntervalSince1970:seconds),save:&save)
            income[category,default:0] += amount
        }
        /// "Drive N different cars" needs N owned cars; nothing else is gated.
        func feasible(_ m: MissionDefinition) -> Bool { m.metric != .carsDriven || Double(save.owned.count) >= m.target }
        mutating func finish(_ m: MissionDefinition) {
            guard save.missions[m.id]?.completed != true, feasible(m) else { return }
            save.missions[m.id] = MissionProgress(value:m.target,completed:true)
            grant("reward."+m.id,m.reward,m.mode.rawValue)
            if m.mode == .career && MissionCatalog.career.filter({$0.chapter == m.chapter}).allSatisfy({save.missions[$0.id]?.completed == true}) {
                grant("chapter.\(m.chapter)",100*m.chapter,"chapter")
            }
            save.sanitize()
        }
        mutating func shop() {
            // Both routes buy one starter engine upgrade. Mixed additionally buys
            // engine/tires/drift level 2 on every car, and one paint every fourth car.
            let id = save.selectedCar
            let desired: [UpgradePart] = upgrades ? [.engine,.tires,.drift] : (id == ProgressionCatalog.starter ? [.engine] : [])
            for part in desired where (save.parts[id] ?? CarParts())[part] == 1 {
                let cost = ProgressionCatalog.upgradeCost(carID:id,part:part,level:1)
                if save.coins >= cost {
                    try! Economy.upgrade(id,part:part,expectedLevel:1,save:&save)
                    spending["parts",default:0] += cost
                    if firstUpgrade == 0 { firstUpgrade = seconds }
                }
            }
            if upgrades, save.paintShopUnlocked, let slot = ProgressionCatalog.slot(id), slot.isMultiple(of:4),
               CarCatalog.car(id:id).isRepaintable, save.paints[id]?.contains(CarPaint.all[0].id) != true, save.coins >= 30 {
                try! Economy.paint(id,color:CarPaint.all[0].id,save:&save); spending["paint",default:0] += 30
            }
            if let slot = ProgressionCatalog.ids.firstIndex(where:{!save.owned.contains($0)}), Economy.carBlock(ProgressionCatalog.ids[slot],save:save) == nil {
                try! Economy.purchaseCar(ProgressionCatalog.ids[slot],save:&save)
                spending["cars",default:0] += ProgressionCatalog.prices[slot]
                maxPurchaseGap = max(maxPurchaseGap,seconds-(purchasedAt.last ?? 0)); purchasedAt.append(seconds)
                if slot == 1 { secondCar = seconds }
            }
        }
        mutating func advance(_ duration: Double, carID fixedCar: String? = nil) {
            var remaining = duration
            while remaining > 0 {
                let dt = min(0.5,remaining), id = fixedCar ?? save.selectedCar
                remaining -= dt; seconds += dt
                let moving = dt*profile.moving
                let chapter = save.chapter
                let automatic = MissionCatalog.career + MissionCatalog.mastery + activeDailies
                for m in automatic where !m.requiresCourse && m.chapter <= chapter
                    && (m.carID == nil || m.carID == id) && save.missions[m.id]?.completed != true && feasible(m) {
                    // Expected rates model overlap; they are not synthetic telemetry
                    // fed into the shipping evaluator or guaranteed human performance.
                    automaticValue[m.id, default: 0] += dt / EconomySimulation.duration(m, profile) * m.target
                    if automaticValue[m.id, default: 0] >= m.target { finish(m) }
                }
                contractValue += contractDefinition.metric == .distance ? moving*profile.speed : moving
                if contractValue >= contractDefinition.target {
                    finish(contractDefinition); save.contractSerial += 1; contractValue = 0
                    contractDefinition = MissionCatalog.contract(chapter:save.chapter,serial:save.contractSerial)
                }
                shop()
            }
        }
        mutating func attempt(_ m: MissionDefinition, carID: String? = nil) {
            guard save.missions[m.id]?.completed != true, feasible(m) else { return }
            if m.requiresCourse {
                for definition in MissionCatalog.career + MissionCatalog.mastery + activeDailies where definition.scope != .cumulative {
                    automaticValue[definition.id] = 0
                }
                advance(EconomySimulation.duration(m, profile), carID: carID)
                finish(m)
            } else {
                let fraction = min(1, automaticValue[m.id, default: 0] / m.target)
                advance(EconomySimulation.duration(m, profile) * (1-fraction) + 0.01, carID: carID)
                finish(m)
            }
            shop()
        }
        mutating func dailyIfDue() {
            guard dailies else { return }
            // One return per active hour; assumes those sessions occur on distinct
            // calendar days. Time spent on daily objectives is included, not free income.
            let day = Int(seconds/3600)
            guard day >= nextDailySet else { return }
            nextDailySet = day+1
            completedDays.insert(day); grant("login-model.\(day)",10,"login")
            let multiplier = 1+0.2*Double(save.chapter-1)
            activeDailies = []
            for tier in 0...2 {
                let pool = MissionCatalog.dailyBank.filter{$0.difficulty == tier}
                var m = pool[(day*7+tier)%pool.count]; m.id = "day.\(day)."+m.id
                m.reward = ProgressionCatalog.roundCoins(Double(m.reward)*multiplier)
                activeDailies.append(m)
            }
            for m in activeDailies { attempt(m) }
            grant("set-model.\(day)",ProgressionCatalog.roundCoins(20*multiplier),"daily")
        }
        mutating func run() {
            if dailies { completedDays.insert(0); grant("login-model.0",10,"login") }
            // Seek first clears in catalog order, skipping goals already completed
            // automatically during earlier driving. Course setup resets attempts.
            for m in MissionCatalog.career {
                let car = save.selectedCar
                attempt(m, carID: car)
                // The first session starts driving without selecting a mission.
                dailyIfDue()
            }
            while save.owned.count < 28 {
                dailyIfDue()
                // Car-collection goals wait until enough cars are owned.
                for m in MissionCatalog.career where save.missions[m.id]?.completed != true && feasible(m) { attempt(m) }
                if let id = ProgressionCatalog.ids.first(where:{save.owned.contains($0) && !visitedMastery.contains($0)}) {
                    visitedMastery.insert(id)
                    for m in MissionCatalog.mastery where m.carID == id && save.missions[m.id]?.completed != true {
                        attempt(m, carID: id)
                    }
                } else { advance(30) }
                precondition(seconds < 200*3600,"Unreachable collection")
            }
        }
    }
    static func main() {
        print("# Reproducible economy model\n")
        print("Generated by `Tools/EconomySimulation.swift` using shipping catalogs and economy transactions. These are modeled active attempt times, **not device playtests**. Scanning, menus and loading are excluded. Purchases happen immediately when affordable.\n")
        print("Profiles: newcomer / average / skilled use rendered speed 0.48 / 0.65 / 0.85 m/s and moving fractions 0.55 / 0.72 / 0.85. Easy/medium/skill/capstone attempt success assumptions are 85/60/40/45%, 95/80/65/72%, and 99/94/88/90%. Expected attempt time = nominal time / success rate.\n")
        print("Career first clears are sought in chapter and family order, skipping auto-completed goals. All eligible passive career, daily and current-car mastery goals plus one contract progress concurrently. Expected passive rates use the nominal durations below, using the October 1 everyday-driving mission pool. Stop and reverse rates are assumptions; all these goals work during ordinary free driving. Other mastery is attempted before farming. No extra maneuver payouts. Daily routes receive +10 on opening, then play one set per active hour on separate calendar days and include its attempt time. No-daily routes exclude even the initial login. Both routes buy the first starter engine level; mixed routes buy engine, tires and drift level 2 per car and one 30-coin paint on every fourth repaintable car. No max-build purchases are assumed.\n")
        print("| Profile | Spending | Daily | First upgrade min | Car 2 min | Collection hours | Largest car gap min | Parts / paint | First-clear / contracts / daily coins |\n|---|---|---|---:|---:|---:|---:|---:|---:|")
        for p in profiles { for upgrades in [false,true] { for daily in [false,true] {
            var route = Route(profile:p,upgrades:upgrades,dailies:daily); route.run()
            let first = ["career","mastery","chapter"].reduce(0){$0+route.income[$1,default:0]}
            let dailyCoins = route.income["daily",default:0]+route.income["login",default:0]
            print(String(format:"| %@ | %@ | %@ | %.2f | %.2f | %.2f | %.1f | %d / %d | %d / %d / %d |",p.name,upgrades ? "Mixed" : "Save",daily ? "Yes" : "No",route.firstUpgrade/60,route.secondCar/60,route.seconds/3600,route.maxPurchaseGap/60,route.spending["parts",default:0],route.spending["paint",default:0],first,route.income["contract",default:0],dailyCoins))
        } } }
        print("\nAll sequential cars cost \(ProgressionCatalog.prices.reduce(0,+)) coins. The solver uses exact source prices and grants each first clear once. Spending never affects availability of the distance/time contract. The model is intentionally transparent about cumulative-task overlap; adding arbitrary setup delays would hide early-pacing mismatches.\n")
        print("Nominal attempts: brake stop 6s/cycle; reverse distance uses 30% of forward modeled speed; clean driving uses moving time divided by success rate. Road coins: one pickup per 6 moving seconds averaging 2.35, a 10 every 15 coins. Turns 8s per circle, 6s per U-turn or handbrake turn; top speed and gear runs 15-20s; photos 15s; a new car's drive 60s once owned. Pure distance/time tasks have no retry multiplier. No course setup or race finish is required.\n")
    }
}
