import Foundation

struct RewardRecord: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var coins: Int
    var date: Date
    var presented = false
}
struct MissionProgress: Codable, Equatable {
    var value: Double = 0
    var completed = false
    var perfectDonuts = 0
}
struct DailyState: Codable, Equatable {
    var day = ""
    var zone = ""
    var highWater = ""
    var lastWall: Date = .distantPast
    var lastGrant: Date = .distantPast
    var slots: [String] = []
    var rerolled = false
    var chapter = 1
}
struct ProgressionSave: Codable, Equatable {
    var version = 1
    var coins = 0
    var owned: Set<String> = [ProgressionCatalog.starter]
    var parts: [String: CarParts] = [:]
    var paints: [String: Set<String>] = [:]
    var selectedCar = ProgressionCatalog.starter
    var selectedPaints: [String: String] = [:]
    var missions: [String: MissionProgress] = [:]
    var active: Set<String> = ["career.01.01"]
    var pinned: [String] = ["career.01.01"]
    var ledger: [RewardRecord] = []
    var transactions: Set<String> = []
    var daily = DailyState()
    var contractSerial = 0
    var introduced = false
    var freeMasteryPaints: Set<String> = []
    var paintShopUnlocked = false

    /// Earned coins waiting on the garage's Collect all. They are saved in `coins`
    /// the moment they are earned, so nothing is lost, but cannot be spent yet.
    var uncollected: Int { ledger.reduce(0) { $1.presented ? $0 : $0 + $1.coins } }
    /// The spendable, displayed balance.
    var wallet: Int { max(0, coins - uncollected) }
    var stars: Int { MissionCatalog.career.reduce(0) { $0 + (missions[$1.id]?.completed == true ? 1 : 0) } }
    var chapter: Int {
        var result = 1
        for chapter in MissionCatalog.careerChapters.prefix(9) {
            guard chapter.filter({ missions[$0.id]?.completed == true }).count >= 8 else { break }
            result += 1
        }
        return result
    }
    @discardableResult
    mutating func migrateDrivingGoals() -> Bool {
        var changed = false
        // Daily progress keys carry a local-day prefix. Do not translate drift
        // points into metres, or wipe any completed mission/earned entitlement.
        for (key, ids) in [("mission-rules.no-drift.v1", MissionCatalog.revisedMissionIDs),
                           ("mission-rules.everyday.v2", MissionCatalog.everydayRevisedIDs),
                           ("mission-rules.variety.v3", MissionCatalog.varietyRevisedIDs)] {
            guard !transactions.contains(key) else { continue }
            for (id, progress) in missions where !progress.completed {
                if ids.contains(where: { id == $0 || id.hasSuffix("." + $0) }) {
                    missions[id] = MissionProgress()
                }
            }
            transactions.insert(key)
            changed = true
        }
        // "Drive different cars" counts earlier drives too. Any mastery progress
        // means that car has been driven, since mastery only tracks the session car.
        if !transactions.contains("cars-driven.v1") {
            for car in owned where missions.contains(where: { key, progress in
                key.hasPrefix("mastery.\(car).") && (progress.value > 0 || progress.completed)
            }) { transactions.insert("driven.\(car)") }
            transactions.insert("cars-driven.v1")
            changed = true
        }
        return changed
    }

    mutating func sanitize() {
        coins = max(0, min(coins, 100_000_000))
        contractSerial = min(max(contractSerial,0),1_000_000_000)
        daily.chapter = min(max(daily.chapter,1),10)
        for i in ledger.indices { ledger[i].coins = min(max(ledger[i].coins,0),100_000) }
        // Preserve unknown entitlements for future catalog changes; never turn them into new grants.
        owned.insert(ProgressionCatalog.starter)
        if !owned.contains(selectedCar) || !ProgressionCatalog.ids.contains(selectedCar) { selectedCar = ProgressionCatalog.starter }
        for (key,var part) in parts { for category in UpgradePart.allCases { part[category] = part[category] }; parts[key] = part }
        for (key,var progress) in missions {
            if !progress.value.isFinite || progress.value < 0 { progress.value = 0 }
            progress.value = min(progress.value,1_000_000_000)
            progress.perfectDonuts = min(max(progress.perfectDonuts,0),1_000_000_000)
            missions[key] = progress
        }
        pinned = Array(Array(NSOrderedSet(array:pinned)) .compactMap { $0 as? String }.prefix(3))
        for (id,color) in selectedPaints where color != "factory" && (!(paints[id]?.contains(color) ?? false) || !CarPaint.all.contains(where:{$0.id == color})) { selectedPaints[id] = "factory" }
        if (1...6).allSatisfy({ missions[String(format:"career.01.%02d",$0)]?.completed == true }) { paintShopUnlocked = true }
    }
}

enum ProgressionError: LocalizedError {
    case rejected(String), unsupportedSave, unreadableSave
    var errorDescription: String? { switch self {
        case .rejected(let text): return text
        case .unsupportedSave: return "This career was saved by a newer version. Update the app to continue."
        case .unreadableSave: return "The career could not be read. Your save files have been kept. Try reopening the app."
    } }
}

/// The file is the commit boundary. Memory publishes only after atomic replacement.
/// The backup contains the last committed generation; a failed write never spends.
final class ProgressionStore {
    let url: URL
    let backupURL: URL
    var simulateInterruptionBeforeCommit = false
    var simulateInterruptionAfterCommit = false
    var simulateWriteFailure = false // Dependency seam used by standalone durability checks.
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        url = directory.appendingPathComponent("career-v1.json")
        backupURL = directory.appendingPathComponent("career-v1.backup.json")
    }
    func load() throws -> ProgressionSave {
        let decoder = JSONDecoder()
        var found = false
        for path in [url,backupURL] where FileManager.default.fileExists(atPath:path.path) {
            found = true
            if let data = try? Data(contentsOf:path), var save = try? decoder.decode(ProgressionSave.self,from:data) {
                guard save.version == 1 else { throw ProgressionError.unsupportedSave }
                save.sanitize()
                if save.migrateDrivingGoals() { try write(save) }
                return save
            }
        }
        if found { throw ProgressionError.unreadableSave }
        var fresh = ProgressionSave()
        fresh.migrateDrivingGoals()
        return fresh
    }
    func write(_ save: ProgressionSave) throws {
        if simulateWriteFailure { throw CocoaError(.fileWriteOutOfSpace) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(save)
        // Preserve the prior valid primary before replacing it. Never back up corrupt bytes.
        if let current = try? Data(contentsOf:url), (try? JSONDecoder().decode(ProgressionSave.self,from:current)) != nil {
            try current.write(to:backupURL,options:.atomic)
        }
        if simulateInterruptionBeforeCommit { throw CocoaError(.fileWriteUnknown) }
        try data.write(to:url,options:.atomic)
        if simulateInterruptionAfterCommit { return }
        // Best effort refresh: primary has already committed, so failure here must
        // not report a rejected purchase and cause a retry to spend again.
        try? data.write(to:backupURL,options:.atomic)
    }
}

/// Stateless rules used both by UI and transaction validation.
enum Economy {
    static func carBlock(_ id: String, save: ProgressionSave) -> String? {
        guard let slot = ProgressionCatalog.slot(id) else { return "Car unavailable" }
        if save.owned.contains(id) { return nil }
        if slot > 0 && !save.owned.contains(ProgressionCatalog.ids[slot-1]) {
            return "Own \(CarCatalog.car(id:ProgressionCatalog.ids[slot-1]).displayName) first"
        }
        if save.stars < ProgressionCatalog.stars[slot] { return "\(ProgressionCatalog.stars[slot]-save.stars) more career stars needed" }
        if save.wallet < ProgressionCatalog.prices[slot] { return "Need \(ProgressionCatalog.prices[slot]-save.wallet) more coins" }
        return nil
    }
    static func purchaseCar(_ id: String, save: inout ProgressionSave) throws {
        guard !save.owned.contains(id), let slot = ProgressionCatalog.slot(id) else { throw ProgressionError.rejected("Already owned") }
        if let reason = carBlock(id,save:save) { throw ProgressionError.rejected(reason) }
        save.coins -= ProgressionCatalog.prices[slot]
        save.owned.insert(id); save.parts[id] = CarParts(); save.selectedPaints[id] = "factory"
        save.transactions.insert("car.\(id)"); save.selectedCar = id
    }
    static func upgrade(_ id: String, part: UpgradePart, expectedLevel: Int, save: inout ProgressionSave) throws {
        guard save.owned.contains(id), ProgressionCatalog.slot(id) != nil else { throw ProgressionError.rejected("Own this car first") }
        var parts = save.parts[id] ?? CarParts()
        guard parts[part] == expectedLevel, expectedLevel < 5 else { throw ProgressionError.rejected("This upgrade is already applied") }
        let cost = ProgressionCatalog.upgradeCost(carID:id,part:part,level:expectedLevel)
        guard save.wallet >= cost else { throw ProgressionError.rejected("Need \(cost-save.wallet) more coins") }
        save.coins -= cost; parts[part] += 1; save.parts[id] = parts
        save.transactions.insert("part.\(id).\(part.rawValue).\(expectedLevel+1)")
    }
    static func paint(_ id: String, color: String, free: Bool = false, save: inout ProgressionSave) throws {
        guard save.owned.contains(id), let car = CarCatalog.all.first(where:{$0.id == id}) else { throw ProgressionError.rejected("Own this car first") }
        if color == "factory" { save.selectedPaints[id] = color; return }
        guard car.isRepaintable, CarPaint.all.contains(where:{$0.id == color}) else { throw ProgressionError.rejected("Original finish only") }
        if save.paints[id]?.contains(color) != true {
            guard save.paintShopUnlocked else { throw ProgressionError.rejected("Complete the first six career missions to open Paint") }
            let gift = free && save.freeMasteryPaints.contains(id)
            guard gift || save.wallet >= 30 else { throw ProgressionError.rejected("Need \(30-save.wallet) more coins") }
            if gift { save.freeMasteryPaints.remove(id) } else { save.coins -= 30 }
            save.paints[id,default:[]].insert(color)
        }
        save.selectedPaints[id] = color
    }
    static func grant(id: String, title: String, coins: Int, now: Date, save: inout ProgressionSave) throws {
        guard !save.transactions.contains(id) else { return }
        guard coins >= 0, coins <= 100_000, save.coins <= 100_000_000-coins else { throw ProgressionError.rejected("Coin balance limit reached") }
        save.coins += coins; save.transactions.insert(id)
        save.ledger.append(RewardRecord(id:id,title:title,coins:coins,date:now))
    }
    /// Road coins credit at once but share one uncollected ledger row per drive, so
    /// the summary shows a single total rather than a line per pickup. A row that
    /// was already collected is never reopened, or its coins would count twice.
    static func roadCoins(drive: String, coins: Int, now: Date, save: inout ProgressionSave) throws {
        guard coins > 0, coins <= 100, save.coins <= 100_000_000-coins else { throw ProgressionError.rejected("Coin balance limit reached") }
        save.coins += coins
        let id = "road.\(drive)"
        let rows = save.ledger.indices.filter { save.ledger[$0].id == id || save.ledger[$0].id.hasPrefix(id+".") }
        if let i = rows.first(where: { !save.ledger[$0].presented }) {
            save.ledger[i].coins += coins; save.ledger[i].date = now
        } else {
            save.ledger.append(RewardRecord(id:rows.isEmpty ? id : "\(id).\(rows.count)",title:"Road coins",coins:coins,date:now))
        }
    }
}

enum DailySelector {
    static func day(at date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = zone
        let d = calendar.dateComponents([.year,.month,.day],from:date)
        return String(format:"%04d-%02d-%02d",d.year ?? 0,d.month ?? 0,d.day ?? 0)
    }
    static func hash(_ text: String) -> UInt64 { text.utf8.reduce(14695981039346656037) { ($0 ^ UInt64($1)) &* 1099511628211 } }
    static func choices(day: String, excluding: Set<MissionMetric> = []) -> [String] {
        // Choose a complete set, so an earlier pick cannot exhaust the final
        // tier after mission families have been migrated.
        func choose(_ tier: Int, used: Set<MissionMetric>) -> [String]? {
            if tier == 3 { return [] }
            let pool = MissionCatalog.dailyBank.filter { $0.difficulty == tier && !used.contains($0.metric) }
            guard !pool.isEmpty else { return nil }
            let offset = Int(hash(day+".\(tier)") % UInt64(pool.count))
            for index in pool.indices {
                let pick = pool[(offset + index) % pool.count]
                if let rest = choose(tier + 1, used: used.union([pick.metric])) { return [pick.id] + rest }
            }
            return nil
        }
        return choose(0, used: excluding) ?? []
    }

    static func refresh(now: Date, zone: TimeZone, save: inout ProgressionSave) throws -> String? {
        let today = day(at:now,zone:zone)
        guard now >= save.daily.lastWall.addingTimeInterval(-300), today >= save.daily.highWater else {
            return "Daily goals return when the clock catches up. Your career is available."
        }
        save.daily.lastWall = max(save.daily.lastWall,now)
        guard today > save.daily.highWater else { return nil }
        if !save.daily.zone.isEmpty && save.daily.zone != zone.identifier && now.timeIntervalSince(save.daily.lastGrant) < 20*3600 {
            return "Travel detected. The next daily bonus is available after 20 hours."
        }
        save.active = Set(save.active.filter { !$0.hasPrefix("daily.") })
        save.pinned.removeAll { $0.hasPrefix("daily.") }
        save.daily = DailyState(day:today,zone:zone.identifier,highWater:today,lastWall:now,lastGrant:now,
                                slots:choices(day:today),rerolled:false,chapter:save.chapter)
        try Economy.grant(id:"login.\(today)",title:"Daily bonus +10",coins:10,now:now,save:&save)
        return nil
    }
}
