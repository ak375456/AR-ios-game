import Foundation

enum MissionMode: String, Codable, CaseIterable { case career, daily, mastery, contract }
enum MissionMetric: String, Codable, CaseIterable {
    case brakeStops, reverseDistance
    case distance, movingTime, cleanTime, accelerationStops, driftHold, driftPoints, donuts
    case slalom, gates, parking, sequence, capstone, driftCount, slalomRuns, parkingCount, driftLinks, gateLaps
    // Everyday techniques: ordinary driving, road coins and the camera register
    // these without a course, markers or a slide.
    case coinPickups, coinValue, tenCoins, coinStreak, topSpeed, fullTurns, uTurns, handbrakeTurns
    case nonStop, smooth, upshifts, reachGear, photos, carsDriven
    var unit: String { switch self {
        case .distance, .reverseDistance, .nonStop, .smooth: return "m"; case .movingTime, .cleanTime, .driftHold, .parking: return "s"
        case .driftPoints: return "pts"; default: return ""
    } }
    var passive: Bool { [.distance, .movingTime, .cleanTime, .brakeStops, .reverseDistance, .driftHold, .driftPoints, .driftCount, .driftLinks].contains(self) || Self.everyday.contains(self) }
    static let everyday: [MissionMetric] = [.coinPickups, .coinValue, .tenCoins, .coinStreak, .topSpeed, .fullTurns, .uTurns,
                                            .handbrakeTurns, .nonStop, .smooth, .upshifts, .reachGear, .photos, .carsDriven]
    /// Runs that restart when broken; everything else banks across drives.
    var defaultScope: MissionScope { [.cleanTime, .coinStreak, .nonStop, .smooth].contains(self) ? .attempt : .cumulative }
    /// A bump into a prop restarts the older attempt goals. A coin streak or a
    /// rolling run is only broken by its own rule.
    var restartsOnContact: Bool { ![.coinStreak, .nonStop, .smooth].contains(self) }
    /// Counts only with the manual gearbox, so pause cards skip it in automatic.
    var needsManualGearbox: Bool { self == .upshifts || self == .reachGear }
}
enum MissionScope: String, Codable { case cumulative, attempt, sequence }
enum Technique: String, Codable { case gates, slalom, park, stop, accelerateStop, drift, donut, leftTurn, rightTurn, reverse, recover, driftLeft, driftRight, figureEight, reverseGate, driftLink }
struct MissionStep: Codable, Equatable {
    var technique: Technique
    var target: Double
    init(_ technique: Technique, _ target: Double = 1) { self.technique = technique; self.target = target }
}
struct MissionDefinition: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var objective: String
    var mode: MissionMode
    var metric: MissionMetric
    var target: Double
    var scope: MissionScope
    var chapter: Int = 1
    var carID: String? = nil
    var reward: Int
    var difficulty: Int = 0
    var steps: [MissionStep] = []
    var seed: Int = 0
    var assisted = false
    var perfectRequired = false
    var requiresCourse: Bool { !metric.passive || !steps.isEmpty }
    var prerequisite: String { mode == .career && chapter > 1 ? "Complete 8 missions in chapter \(chapter-1)" : (carID == nil ? "An owned car" : "Own this car") }
    var spatialRequirement: String { requiresCourse ? "Detected floor for a compact car-sized course" : "Clear floor for your car" }
    var shortObjective: String {
        let n = String(format: target == target.rounded() ? "%.0f" : "%.1f", target)
        switch metric {
        case .distance: return "Drive \(n) m"
        case .movingTime: return "Drive for \(n) seconds"
        case .cleanTime: return "Drive \(n) s without crashing"
        case .brakeStops: return target == 1 ? "Brake to a stop" : "Brake to a stop \(n) times"
        case .reverseDistance: return "Reverse \(n) m"
        case .coinPickups: return target == 1 ? "Pick up a coin" : "Pick up \(n) coins"
        case .coinValue: return "Collect coins worth \(n)"
        case .tenCoins: return target == 1 ? "Grab a 10 coin" : "Grab \(n) coins worth 10"
        case .coinStreak: return "Collect \(n) coins in a row"
        case .topSpeed: return "Reach \(MissionDefinition.speedText(target, rounding: .toNearestOrAwayFromZero))"
        case .fullTurns: return target == 1 ? "Turn a full circle" : "Turn \(n) full circles"
        case .uTurns: return target == 1 ? "Make a U-turn" : "Make \(n) U-turns"
        case .handbrakeTurns: return target == 1 ? "Do a handbrake turn" : "Do \(n) handbrake turns"
        case .nonStop: return "Drive \(n) m without stopping"
        case .smooth: return "Drive \(n) m without braking"
        case .upshifts: return target == 1 ? "Shift up once" : "Shift up \(n) times"
        case .reachGear: return "Reach gear \(n)"
        case .photos: return target == 1 ? "Take a photo of your car" : "Take \(n) photos of your car"
        case .carsDriven: return "Drive \(n) different cars"
        default: return title
        }
    }
    var quickInstruction: String {
        switch metric {
        case .distance: return "Drive anywhere. Forward and reverse both count."
        case .movingTime: return "Keep moving. Time adds up across drives."
        case .cleanTime: return "Keep moving without hitting virtual props."
        case .brakeStops: return "Release GO, then use Brake or Hand. Drive 0.4 m between stops."
        case .reverseDistance: return "Auto: hold Brake. Manual: select R, then GO."
        case .coinPickups: return "Drive over the spinning coins on the floor."
        case .coinValue: return "Each coin shows its value: 1, 2, 5 or 10."
        case .tenCoins: return "Cyan coins are worth 10. They land close and stay longer."
        case .coinStreak: return "Collect coins before they vanish. A missed coin restarts the streak."
        case .topSpeed: return "Hold GO on your longest straight. Transmission upgrades add top speed."
        case .fullTurns: return "Keep steering one way until the car faces the same way again."
        case .uTurns: return "Steer one way until you face back the way you came."
        case .handbrakeTurns: return "While moving, steer and tap Hand. The car must swing 30°."
        case .nonStop: return "Keep rolling. Circles count; stopping restarts the run."
        case .smooth: return "Ease off GO to slow down. Brake or Hand restarts the run."
        case .upshifts: return "Manual gearbox (garage Settings): tap + while moving."
        case .reachGear: return "Manual gearbox (garage Settings): shift up while moving and hold the gear."
        case .photos: return "Pause, open Tools and tap Photo with your car placed."
        case .carsDriven: return "Buy another car in the garage and drive it a few metres."
        default: return objective
        }
    }
    var failureRule: String {
        if !requiresCourse {
            switch metric {
            case .cleanTime:
                return "Only moving time counts. Hitting a virtual obstacle or resetting the car restarts this goal. Menus and standing still add no time."
            case .coinStreak:
                return "Only a coin that vanishes breaks the streak. Bumps don't. Resetting the car or ending the drive restarts it."
            case .nonStop:
                return "Coming to a stop, resetting the car or ending the drive restarts the run. Changing direction needs a stop."
            case .smooth:
                return "Pressing Brake or Hand, resetting the car or ending the drive restarts the run. Coasting to a stop is fine."
            case .topSpeed:
                return "Your best speed is kept between drives. Speed is read from the speedometer."
            case .reachGear:
                return "Counts in the manual gearbox while moving, after the gear is held for half a second."
            case .upshifts:
                return "Counts in the manual gearbox while moving. Shifts while stopped don't count."
            case .photos:
                return "Counts when the photo is taken with your car placed. Saving to Photos is optional."
            case .carsDriven:
                return "Every owned car you have driven at least a metre counts, including earlier drives. The free test drive doesn't."
            default:
                return "Progress adds up automatically across drives. No course or mission selection is needed. Resetting the car never earns progress."
            }
        }
        let reset = scope == .cumulative ? "Banked progress stays. Reset clears only the current maneuver." : "Reset or a relevant collision restarts this attempt. No coins lost."
        let contact = metric == .slalom || metric == .slalomRuns || steps.contains(where:{$0.technique == .slalom})
            ? " Any target-cone touch restarts the weave."
            : " Tiny solver contacts are tolerated; significant course contacts break clean runs."
        let drift = [.driftHold,.driftPoints,.driftCount,.driftLinks,.donuts].contains(metric)
            ? " Minor contacts reduce unbanked slide points; a major crash loses only that chain."
            : ""
        return reset+contact+drift
    }
    func formatted(_ progress: Double) -> String {
        if metric == .topSpeed {
            let unit = SpeedUnit.preferred
            let shown = min(max(progress.isFinite ? progress : 0, 0), target)
            let best = Int(SimulationScale.displaySpeed(renderedMetresPerSecond: Float(shown), unit: unit).rounded(.down))
            return "\(best) / \(MissionDefinition.speedText(target, rounding: .toNearestOrAwayFromZero))"
        }
        let value = min(max(progress.isFinite ? progress : 0, 0), target)
        let decimals = metric.unit == "s" || metric.unit == "m" ? 1 : 0
        return String(format: "%.*f / %.*f %@", decimals, value, decimals, target, metric.unit)
    }
    /// A rendered speed as the speedometer would print it, in the player's unit.
    static func speedText(_ rendered: Double, rounding: FloatingPointRoundingRule) -> String {
        let unit = SpeedUnit.preferred
        let value = SimulationScale.displaySpeed(renderedMetresPerSecond: Float(rendered), unit: unit)
        return "\(Int(value.rounded(rounding))) \(unit.abbreviation)"
    }
}

enum MissionCatalog {
    static let chapters = ["First Keys","Finding Grip","Road School","Precision Driver","Smooth Operator","Daily Driver","Road Rhythm","Technical Driver","Garage Veteran","Room Champion"]
    static let targets: [[Double]] = [
        [5,20,8,1,0.6,60,1,3,3,1.5,1,1], [12,40,12,2,0.8,120,1,3,4,2,1,1],
        [20,60,16,2,1,180,2,4,5,2,1,1], [30,80,20,3,1.2,260,2,4,6,2.5,1,1],
        [40,100,25,3,1.5,360,3,5,6,2.5,1,1], [55,120,30,4,1.8,480,3,5,7,3,1,1],
        [70,150,35,4,2,620,4,6,8,3,1,1], [90,180,40,5,2.3,780,4,6,9,3.5,1,1],
        [110,210,45,5,2.6,950,5,7,10,3.5,1,1], [140,240,50,6,3,1150,5,7,12,4,1,1]]
    static let families: [MissionMetric] = [.distance,.movingTime,.cleanTime,.accelerationStops,.driftHold,.driftPoints,.donuts,.slalom,.gates,.parking,.sequence,.capstone]
    static let titles: [[String]] = [
        ["First Roll","Engine Warm","A Clean Start","Easy Does It","A Little Sideways","First Smoke","Round the Ring","Weave Hello","Open Doors","Home Sweet Home","Slow and Steady","First Finish"],
        ["Further Afield","Settle In","Untouched","Twice as Smooth","Find the Edge","Building Rhythm","Full Circle","Thread the Line","Four Corners","Stay a Moment","Left Meets Right","Cone Graduate"],
        ["Longer Lines","Minute Driver","Clean Canvas","Measured Pedal","Slide a Second","Bank the Slide","Double Orbit","Broad Weave","Five Alive","Hold Your Spot","Catch the Tail","Slide to Finish"],
        ["Quiet Miles","Patient Pace","Room to Breathe","Three Good Stops","Edge Control","Collected Slides","Round Again","Tighter Thread","Door to Door","Precise Arrival","Back It In","Park the Weave"],
        ["Rolling Along","In the Groove","No Scrapes","Soft Landings","Sustain It","Smoke Savings","Triple Circle","Wide Awake","Find Your Route","Right at Home","Both Sides","Eight Is Great"],
        ["Regular Route","Two Minutes","Clean Routine","Four of a Kind","Stay Sideways","Point Collector","Ring Regular","Cone Conversation","Seven Stops","Steady Hands","Finish on a Mark","Course Combination"],
        ["Keep Exploring","Driving Rhythm","Clean Sweep","Pedal Discipline","Two Seconds","Drift Ledger","Four Orbits","Flowing Weave","Eight Doors","Perfectly Still","Link the Slides","Circle and Slide"],
        ["Technical Tour","Three Minutes","Calm Control","Five Gentle Stops","Long Arc","Angle Artist","Circle Craft","Technical Thread","Nine in Line","Tight Arrival","Back Through","Reverse Routine"],
        ["Veteran Route","Time Well Driven","Clean Record","Stop Specialist","Deep Slide","Score Curator","Five Circles","Wide Expertise","Ten Doors","Park with Pride","Figure and Finish","Weave and Link"],
        ["Champion Journey","Four Minutes","Flawless Flow","Six Smooth Stops","Three Seconds","Slide Champion","One Perfect Orbit","Final Weave","Twelve Doors","Champion Parking","Technique Trio","Room Champion"]]
    static let sequences: [[MissionStep]] = [
        [.init(.stop),.init(.leftTurn)], [.init(.leftTurn),.init(.rightTurn)], [.init(.drift,1),.init(.recover)],
        [.init(.reverse),.init(.park,2.5)], [.init(.driftLeft,0.6),.init(.recover),.init(.driftRight,0.6)],
        [.init(.gates,3),.init(.stop)], [.init(.driftLink)],
        [.init(.reverseGate),.init(.park,3.5)], [.init(.figureEight),.init(.park,3.5)],
        [.init(.gates,3),.init(.drift,1),.init(.park,4)]]
    static let capstones: [[MissionStep]] = [
        [.init(.gates,3),.init(.park,1.5)], [.init(.slalom,3),.init(.stop)],
        [.init(.drift,0.6),.init(.gates,3),.init(.stop)], [.init(.slalom,4),.init(.park,2.5)],
        [.init(.figureEight),.init(.stop)], [.init(.slalom,5),.init(.gates,4)],
        [.init(.donut),.init(.drift,0.8),.init(.recover)], [.init(.reverse),.init(.park,3.5),.init(.gates,5)],
        [.init(.slalom,6),.init(.driftLeft,0.6),.init(.driftRight,0.6)],
        [.init(.gates,4),.init(.slalom,4),.init(.drift,1),.init(.park,4)]]
    static func reward(chapter: Int, difficulty: Int) -> Int {
        switch difficulty { case 0: return 15+10*(chapter-1); case 1: return 25+15*(chapter-1); case 2: return 40+20*(chapter-1); default: return 60+30*(chapter-1) }
    }
    static func wording(_ metric: MissionMetric, _ target: Double) -> String {
        let n = String(format: target == target.rounded() ? "%.0f" : "%.1f", target)
        switch metric {
        case .brakeStops: return "Drive at least 0.4 m, release GO, then use Brake or Hand to stop. Repeat \(n) times, anywhere on the floor."
        case .reverseDistance: return "Hold Brake after stopping to reverse. Back up \(n) m in total, anywhere on the floor."
        case .distance: return "Drive \(n) m anywhere. Forward and reverse both count."
        case .movingTime: return "Drive actively for \(n) seconds."
        case .cleanTime: return "Keep moving for \(n) seconds without a significant contact."
        case .accelerationStops: return "Reach the marked pace, then stop in the zone \(n) times."
        case .driftHold: return "Hold one controlled forward drift for \(n) seconds, then recover."
        case .driftPoints: return "Bank \(n) drift points with clean exits."
        case .donuts: return "Complete \(n) sliding orbits around the marked ring."
        case .slalom: return "Weave alternately around \(n) cones in order, without touching them."
        case .gates: return "Cross \(n) numbered gates in order and in the arrow direction."
        case .parking: return "Fit the whole car in the bay, align and hold still for \(n) seconds."
        case .driftCount: return "Bank \(n) separate controlled drifts."
        case .slalomRuns: return "Finish \(n) separate clean slalom attempts."
        case .parkingCount: return "Complete \(n) separate precise parking attempts."
        case .driftLinks: return "Link a stable left and right slide \(n) times."
        case .gateLaps: return "Complete \(n) compact ordered gate laps."
        case .sequence, .capstone: return "Complete each marked technique in order."
        case .coinPickups, .coinValue, .tenCoins, .coinStreak, .topSpeed, .fullTurns, .uTurns, .handbrakeTurns,
             .nonStop, .smooth, .upshifts, .reachGear, .photos, .carsDriven:
            return MissionDefinition(id: "", title: "", objective: "", mode: .daily, metric: metric, target: target,
                                     scope: metric.defaultScope, reward: 0).quickInstruction
        }
    }
    static func stepText(_ steps: [MissionStep]) -> String {
        steps.map { step in
            switch step.technique {
            case .gates: return "\(Int(step.target)) gates"; case .slalom: return "\(Int(step.target)) cones"
            case .park: return "park \(step.target)s"; case .stop: return "controlled stop"
            case .accelerateStop: return "accelerate and stop"; case .drift: return "drift \(step.target)s"
            case .donut: return "donut"; case .leftTurn: return "clean left turn"; case .rightTurn: return "clean right turn"
            case .reverse: return "reverse 0.4 course m"; case .recover: return "recover straight"
            case .driftLeft: return "left drift"; case .driftRight: return "right drift"
            case .driftLink: return "two linked slides within 5 seconds"
            case .figureEight: return "follow all eight figure-eight gates"; case .reverseGate: return "reverse through gate"
            }
        }.joined(separator: " → ")
    }
    private static let originalCareer: [MissionDefinition] = (0..<10).flatMap { c in
        (0..<12).map { f in
            let metric = families[f], target = targets[c][f]
            let difficulty = [0,0,0,0,1,1,2,1,1,1,2,3][f]
            let steps = f == 10 ? sequences[c] : (f == 11 ? capstones[c] : [])
            return MissionDefinition(id: String(format:"career.%02d.%02d",c+1,f+1), title: titles[c][f],
                objective: steps.isEmpty ? wording(metric,target) + (c == 9 && f == 6 ? " Include one perfect donut." : "") : stepText(steps),
                mode: .career, metric: metric, target: target,
                scope: [.distance,.movingTime,.driftPoints,.donuts,.accelerationStops].contains(metric) ? .cumulative : (steps.isEmpty ? .attempt : .sequence),
                chapter: c+1, reward: reward(chapter:c+1,difficulty:difficulty), difficulty:difficulty, steps:steps,
                seed:c*12+f, assisted:c == 0 && f == 6, perfectRequired:c == 9 && f == 6)
        }
    }
    static let careerChapters: [[MissionDefinition]] = (1...10).map { chapter in career.filter { $0.chapter == chapter } }
    private static let originalDaily: [MissionDefinition] = {
        let metrics: [MissionMetric] = [.distance,.movingTime,.cleanTime,.driftCount,.driftPoints,.driftHold,.donuts,.gates,.slalomRuns,.parkingCount,.accelerationStops,.driftLinks]
        let values: [[Double]] = [[10,20,35,50,75],[30,60,90,120,180],[8,12,18,25,35],[2,3,5,7,10],[80,150,250,400,650],[0.6,0.8,1.2,1.6,2],[1,2,3,4,5],[4,6,8,12,16],[1,2,3,4,5],[1,2,3,4,5],[1,2,3,4,5],[1,2,3,4,5]]
        let names = ["Daily journey","Daily drive","Clean roads","Slide collection","Point run","Hold the line","Circle session","Gate tour","Cone practice","Park practice","Smooth stops","Slide links"]
        return metrics.enumerated().flatMap { index, metric in (0..<5).map { v in
            let difficulty = [.donuts,.driftLinks,.driftHold].contains(metric) ? 2 : (index < 3 && v < 3 ? 0 : 1)
            return MissionDefinition(id:"daily.\(metric.rawValue).\(v+1)",title:"\(names[index]) \(v+1)", objective:wording(metric,values[index][v]),mode:.daily,metric:metric,target:values[index][v],scope:[.cleanTime,.gates].contains(metric) ? .attempt : .cumulative,reward:[20,35,50][difficulty],difficulty:difficulty,seed:100+index*5+v)
        } }
    }()
    private static let originalMastery: [MissionDefinition] = { ProgressionCatalog.cars.enumerated().flatMap { slot, car in
        let signature: MissionMetric
        switch car.carClass { case .drift: signature = .driftCount; case .offroad,.novelty: signature = .gateLaps
        case .sports,.supercar,.openWheel: signature = .accelerationStops; default: signature = .parkingCount }
        let signatureStep: MissionStep = signature == .driftCount ? .init(.drift,1) : signature == .gateLaps ? .init(.gates,4) : signature == .parkingCount ? .init(.park,2) : .init(.accelerateStop)
        let metrics: [MissionMetric] = [.movingTime,.distance,.cleanTime,.slalom,signature,.capstone]
        let goals: [Double] = [30,30,15,4,signature == .accelerationStops ? 3 : 2,1]
        return (0..<6).map { i in MissionDefinition(id:"mastery.\(car.id).\(i+1)",title:["First Drive","Familiar Wheels","Clean Control","Precision","Class Signature","Car Showcase"][i],objective:i == 5 ? "Four gates, your class skill, then park." : wording(metrics[i],goals[i]),mode:.mastery,metric:metrics[i],target:goals[i],scope:i < 2 || i == 4 ? .cumulative : .attempt,carID:car.id,reward:ProgressionCatalog.roundCoins(Double([15,25,30,40,50,75][i]) * (1+0.15*Double(slot))),steps:i == 5 ? [.init(.gates,4),signatureStep,.init(.park,2)] : [],seed:200+slot*6+i) }
    } }()
    // Stable IDs preserve completed missions, stars and reward receipts. Only the
    // unfinished counters whose meaning changed are reset by the save migration.
    private static let everydayCareer: [MissionDefinition] = {
        var seen: Set<String> = []
        return originalCareer.map { original in
            var goal = everydayDrivingGoal(accessibleDrivingGoal(original))
            func signature() -> String { "\(goal.chapter).\(goal.metric.rawValue).\(goal.target)" }
            // Replacing a bay stop must not create a second identical stop goal.
            // Keep each chapter distinct after collapsing legacy skill families.
            while seen.contains(signature()) {
                goal.target += goal.metric == .distance ? 3 : goal.metric == .movingTime ? 10 : 1
            }
            seen.insert(signature())
            goal.title = goal.shortObjective; goal.objective = goal.quickInstruction
            return goal
        }
    }()
    private static let everydayDaily = originalDaily.map { everydayDrivingGoal(accessibleDrivingGoal($0)) }
    private static let everydayMastery = originalMastery.map { everydayDrivingGoal(accessibleDrivingGoal($0)) }
    static let career = everydayCareer.map(varietyCareerGoal)
    static let dailyBank = everydayDaily.map(varietyDailyGoal) + extraDaily
    static let mastery = everydayMastery.map(varietyMasteryGoal)
    static let revisedMissionIDs = Set((originalCareer + originalDaily + originalMastery)
        .filter { accessibleDrivingGoal($0) != $0 }.map(\.id))
    // Compare scoring meaning, not renamed copy, with the previous shipping catalog.
    static let everydayRevisedIDs = Set((originalCareer + originalDaily + originalMastery)
        .map { accessibleDrivingGoal($0) }.filter { $0.requiresCourse }.map(\.id))
    /// Slots whose action or target changed when the everyday techniques arrived.
    /// Paired list by list: the daily bank also gains new families at its end.
    static let varietyRevisedIDs = Set([zip(everydayCareer, career), zip(everydayDaily, dailyBank), zip(everydayMastery, mastery)]
        .flatMap { pairs in pairs.filter { $0.metric != $1.metric || $0.target != $1.target }.map(\.0.id) })

    // MARK: - Everyday techniques

    /// Career families that had collapsed into repeats of distance, time and
    /// stops once drift, cones and parking were retired (0-based family index).
    /// Each now holds a different everyday technique; rewards and difficulty
    /// stay with the slot, so the economy is unchanged.
    private static let varietySlots = [4, 5, 6, 8, 9, 10, 11]
    private static func kmh(_ value: Double) -> Double { SpeedUnit.renderedSpeed(kmh: value) }
    /// Per chapter, in `varietySlots` order. Introduced a few at a time; the
    /// manual gearbox arrives in chapter 4. Speeds: the stock starter reaches
    /// 32 km/h in under a metre; 40 needs a better car or transmission
    /// upgrade and 50 a fully upgraded one (Tools measurement).
    private static let varietyCareer: [[(MissionMetric, Double)]] = [
        [(.coinPickups, 3), (.fullTurns, 1), (.photos, 1), (.uTurns, 1), (.nonStop, 3), (.topSpeed, kmh(25)), (.coinValue, 10)],
        [(.smooth, 4), (.coinPickups, 6), (.handbrakeTurns, 1), (.fullTurns, 2), (.uTurns, 2), (.tenCoins, 1), (.coinStreak, 3)],
        [(.coinValue, 20), (.nonStop, 5), (.handbrakeTurns, 2), (.topSpeed, kmh(28)), (.smooth, 6), (.uTurns, 3), (.carsDriven, 2)],
        [(.upshifts, 3), (.coinPickups, 12), (.fullTurns, 3), (.nonStop, 8), (.handbrakeTurns, 3), (.coinStreak, 4), (.coinValue, 35)],
        [(.smooth, 10), (.uTurns, 4), (.tenCoins, 2), (.reachGear, 3), (.coinPickups, 18), (.handbrakeTurns, 4), (.nonStop, 12)],
        [(.coinValue, 50), (.fullTurns, 4), (.coinStreak, 5), (.topSpeed, kmh(32)), (.upshifts, 6), (.smooth, 14), (.carsDriven, 3)],
        [(.coinPickups, 25), (.handbrakeTurns, 5), (.uTurns, 6), (.nonStop, 16), (.fullTurns, 5), (.tenCoins, 3), (.coinValue, 75)],
        [(.reachGear, 4), (.smooth, 18), (.fullTurns, 6), (.coinStreak, 6), (.coinPickups, 32), (.handbrakeTurns, 7), (.topSpeed, kmh(40))],
        [(.upshifts, 10), (.uTurns, 8), (.tenCoins, 4), (.nonStop, 20), (.coinValue, 100), (.coinStreak, 7), (.carsDriven, 5)],
        [(.coinPickups, 40), (.smooth, 22), (.fullTurns, 8), (.handbrakeTurns, 9), (.nonStop, 25), (.coinStreak, 8), (.topSpeed, kmh(50))]]

    private static func varietyCareerGoal(_ goal: MissionDefinition) -> MissionDefinition {
        guard let slot = varietySlots.firstIndex(of: goal.seed % 12) else { return goal }
        let (metric, target) = varietyCareer[goal.chapter - 1][slot]
        return retarget(goal, metric: metric, target: target)
    }

    /// Daily families that had become repeats, by original family index:
    /// targets per variant and the tier each variant sits in.
    private static let varietyDaily: [Int: (MissionMetric, [Double], [Int])] = [
        3: (.coinPickups, [3, 5, 8, 12, 16], [0, 0, 1, 1, 1]),
        4: (.coinValue, [8, 12, 20, 30, 45], [1, 1, 1, 1, 1]),
        5: (.nonStop, [3, 5, 8, 12, 16], [1, 1, 1, 2, 2]),
        6: (.fullTurns, [1, 2, 3, 4, 5], [0, 0, 1, 1, 2]),
        7: (.uTurns, [1, 2, 3, 4, 6], [0, 0, 1, 1, 2]),
        // The stock starter reaches all five; 33 km/h is 92% of its top speed.
        10: (.topSpeed, [20, 24, 27, 30, 33].map(kmh), [1, 1, 1, 2, 2]),
        11: (.handbrakeTurns, [1, 2, 3, 4, 5], [1, 1, 2, 2, 2])]

    private static func varietyDailyGoal(_ goal: MissionDefinition) -> MissionDefinition {
        let family = (goal.seed - 100) / 5, variant = (goal.seed - 100) % 5
        guard let (metric, targets, tiers) = varietyDaily[family] else { return goal }
        var m = retarget(goal, metric: metric, target: targets[variant])
        m.difficulty = tiers[variant]; m.reward = [20, 35, 50][m.difficulty]
        return m
    }

    /// Daily families that never existed before; new IDs, nothing to migrate.
    private static let extraDaily: [MissionDefinition] = {
        let families: [(MissionMetric, [Double], [Int])] = [
            (.smooth, [3, 5, 8, 11, 15], [1, 1, 1, 2, 2]),
            (.coinStreak, [2, 3, 4, 5, 6], [1, 1, 2, 2, 2]),
            (.tenCoins, [1, 2, 3, 4, 5], [1, 1, 2, 2, 2])]
        return families.enumerated().flatMap { index, family in
            let (metric, targets, tiers) = family
            return targets.indices.map { v in
                retarget(MissionDefinition(id: "daily.\(metric.rawValue).\(v + 1)", title: "", objective: "", mode: .daily,
                                           metric: metric, target: targets[v], scope: metric.defaultScope,
                                           reward: [20, 35, 50][tiers[v]], difficulty: tiers[v], seed: 160 + index * 5 + v),
                         metric: metric, target: targets[v])
            }
        }
    }()

    /// Mastery 4 is a photo of the car, 5 its class's technique and 6 a run
    /// to 90% of its stock top speed, so every car asks for something of its own.
    private static func varietyMasteryGoal(_ goal: MissionDefinition) -> MissionDefinition {
        let slot = (goal.seed - 200) / 6, index = (goal.seed - 200) % 6
        guard let id = goal.carID, ProgressionCatalog.ids.indices.contains(slot) else { return goal }
        switch index {
        case 3: return retarget(goal, metric: .photos, target: 1)
        case 4:
            switch CarCatalog.car(id: id).carClass {
            case .drift: return retarget(goal, metric: .handbrakeTurns, target: 3)
            case .offroad, .novelty: return retarget(goal, metric: .fullTurns, target: 2)
            case .sports, .supercar, .openWheel: return retarget(goal, metric: .nonStop, target: 10)
            default: return retarget(goal, metric: .uTurns, target: 3)
            }
        case 5:
            let stock = Double(SimulationScale.displaySpeed(renderedMetresPerSecond: ProgressionCatalog.stockSpeeds[slot], unit: .kilometresPerHour))
            return retarget(goal, metric: .topSpeed, target: kmh((stock * 0.9).rounded(.down)))
        default: return goal
        }
    }

    private static func retarget(_ previous: MissionDefinition, metric: MissionMetric, target: Double) -> MissionDefinition {
        var m = previous
        m.metric = metric; m.target = target; m.scope = metric.defaultScope; m.steps = []
        m.assisted = false; m.perfectRequired = false
        m.title = m.shortObjective
        m.objective = m.quickInstruction
        return m
    }

    private static func everydayDrivingGoal(_ previous: MissionDefinition) -> MissionDefinition {
        var m = previous
        switch m.metric {
        case .accelerationStops, .parkingCount: m.metric = .brakeStops
        case .parking: m.metric = .brakeStops; m.target = max(1, floor(m.target))
        case .gates: m.metric = .distance; m.target *= 3
        case .gateLaps: m.metric = .movingTime; m.target *= 30
        case .slalom: m.metric = .reverseDistance; m.target = max(1, (m.target / 3).rounded())
        case .slalomRuns: m.metric = .reverseDistance; m.target *= 2
        case .sequence: m.metric = .movingTime; m.target = Double(30 + m.chapter * 10)
        case .capstone: m.metric = .distance; m.target = m.mode == .mastery ? 60 : Double(20 + m.chapter * 10)
        default: break
        }
        m.steps = []
        m.scope = m.metric == .cleanTime ? .attempt : .cumulative
        m.assisted = false; m.perfectRequired = false
        m.title = m.shortObjective
        m.objective = m.quickInstruction
        return m
    }

    private static func accessibleDrivingGoal(_ original: MissionDefinition) -> MissionDefinition {
        var m = original
        switch m.metric {
        case .driftHold:
            m.metric = .cleanTime; m.target = (10 + original.target * 10).rounded(); m.scope = .attempt
        case .driftPoints:
            m.metric = .distance; m.target = (10 + original.target / 6).rounded(); m.scope = .cumulative
        case .driftCount:
            m.metric = .movingTime; m.target = original.target * 20; m.scope = .cumulative
        case .driftLinks:
            m.metric = .cleanTime; m.target = 10 + original.target * 5; m.scope = .attempt
        case .donuts:
            m.metric = .gates; m.target = 3 + original.target; m.scope = .attempt
        default: break
        }
        m.steps = m.steps.map { step in
            switch step.technique {
            case .drift, .donut: return MissionStep(.gates, 3)
            case .driftLeft: return MissionStep(.leftTurn)
            case .driftRight: return MissionStep(.rightTurn)
            case .driftLink: return MissionStep(.gates, 4)
            default: return step
            }
        }
        if m.metric != original.metric || m.steps != original.steps {
            let names: [MissionMetric: String] = [.cleanTime: "Smooth Cruise", .distance: "Explore More",
                .movingTime: "Time to Drive", .gates: "Gate Trail", .sequence: "Road Skills", .capstone: "Final Lap"]
            m.title = "\(names[m.metric] ?? "Road Skills") \(m.mode == .career ? m.chapter : m.seed)"
            m.objective = m.steps.isEmpty ? wording(m.metric, m.target) : stepText(m.steps)
            m.assisted = false; m.perfectRequired = false
        }
        return m
    }

    static func contract(chapter: Int, serial: Int) -> MissionDefinition {
        // Always reachable with any owned stock car, including after spending the wallet.
        let metric: MissionMetric = serial.isMultiple(of: 2) ? .movingTime : .distance
        let target = metric == .movingTime ? Double(30+chapter*6) : Double(10+chapter*3)
        return everydayDrivingGoal(MissionDefinition(id:"contract.\(serial)",title:"Keep driving",objective:wording(metric,target),mode:.contract,metric:metric,target:target,scope:.cumulative,chapter:chapter,reward:reward(chapter:chapter,difficulty:0),seed:serial))
    }
}
