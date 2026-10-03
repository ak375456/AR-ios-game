import Foundation
import Observation

struct MissionAttempt {
    var gates = 0, cones = 0, runs = 0, step = 0
    var stepValue: Double = 0
    var hold: Double = 0
    var figureSide = 0
    var driftSegments = 0
    mutating func advance(_ m: MissionDefinition, event e: DrivingEvents, progress: inout MissionProgress) {
        if e.collided || (e.coneContact && (m.metric == .slalom || m.metric == .slalomRuns || m.steps.contains { $0.technique == .slalom })) {
            gates = 0; cones = 0; step = 0; stepValue = 0; hold = 0
            if m.scope != .cumulative && m.metric.restartsOnContact { progress.value = 0 }
        }
        if !m.steps.isEmpty {
            guard step < m.steps.count else { return }
            let s = m.steps[step]
            switch s.technique {
            case .gates, .reverseGate: stepValue += Double(e.gates)
            case .slalom: stepValue += Double(e.slalom)
            case .park: stepValue = e.parking
            case .stop: if e.stopped { stepValue = 1 }
            case .accelerateStop: stepValue += Double(e.accelerationStops)
            case .drift: stepValue = max(stepValue,e.driftHold)
            case .donut: stepValue += Double(e.donuts)
            case .leftTurn: stepValue += Double(e.leftTurns)
            case .rightTurn: stepValue += Double(e.rightTurns)
            case .reverse: stepValue += e.reverseDistance/0.4
            case .recover: hold = e.recovered ? hold+e.movingTime : 0; stepValue = hold/0.5
            case .driftLeft: if e.driftSide > 0 { stepValue = max(stepValue,e.driftHold) }
            case .driftRight: if e.driftSide < 0 { stepValue = max(stepValue,e.driftHold) }
            case .driftLink: stepValue += Double(e.driftLinks)
            case .figureEight:
                stepValue += Double(e.gates)/8
            }
            if stepValue >= s.target { step += 1; stepValue = 0; hold = 0 }
            progress.value = step == m.steps.count ? m.target : 0
            return
        }
        switch m.metric {
        case .brakeStops: progress.value += Double(e.brakeStops)
        case .reverseDistance: progress.value += e.reverseDistance
        case .distance: progress.value += e.distance
        case .movingTime: progress.value += e.movingTime
        case .cleanTime: progress.value = e.cleanTime > 0 ? progress.value + e.movingTime : 0
        case .accelerationStops: progress.value += Double(e.accelerationStops)
        case .driftHold: progress.value = max(progress.value,e.driftHold)
        case .driftPoints: progress.value += e.driftPoints
        case .donuts:
            progress.value += Double(e.donuts); progress.perfectDonuts += e.perfectDonuts
            if m.perfectRequired && progress.perfectDonuts == 0 { progress.value = min(progress.value,m.target-0.01) }
        case .slalom: cones += e.slalom; progress.value = Double(cones)
        case .gates: gates += e.gates; progress.value = Double(gates)
        case .parking: progress.value = e.parking
        case .driftCount:
            // Class signature calls for two banked one-second drifts.
            if m.mode != .mastery || e.driftHold >= 1 { progress.value += Double(e.drifts) }
        case .parkingCount: progress.value += Double(e.parks)
        case .slalomRuns:
            cones += e.slalom
            if cones >= 4 { progress.value += 1; cones = 0 }
        case .gateLaps:
            gates += e.gates
            if gates >= 4 { progress.value += 1; gates = 0 }
        case .driftLinks: progress.value += Double(e.driftLinks)
        case .sequence,.capstone: break
        case .coinPickups: progress.value += Double(e.coinPickups)
        case .coinValue: progress.value += Double(e.coinValue)
        case .tenCoins: progress.value += Double(e.tenCoins)
        case .coinStreak: progress.value = e.coinMissed ? 0 : progress.value + Double(e.coinPickups)
        case .topSpeed: progress.value = max(progress.value, e.speed)
        case .fullTurns: progress.value += Double(e.fullTurns)
        case .uTurns: progress.value += Double(e.uTurns)
        case .handbrakeTurns: progress.value += Double(e.handbrakeTurns)
        case .nonStop: progress.value = e.halted ? 0 : progress.value + e.rollDistance
        case .smooth: progress.value = e.braked ? 0 : progress.value + e.rollDistance
        case .upshifts: progress.value += Double(e.upshifts)
        case .reachGear: progress.value = max(progress.value, Double(e.gearReached))
        case .photos: progress.value += Double(e.photos)
        case .carsDriven: progress.value = max(progress.value, Double(e.carsDriven))
        }
        progress.value = min(m.target,max(0,progress.value))
    }
}

@MainActor @Observable
final class ProgressionModel {
    private(set) var save = ProgressionSave()
    private(set) var error: String?
    private(set) var clockNotice: String?
    private(set) var selectedChallenge: String?
    private(set) var attemptText = ""
    private(set) var finishedChallenge: String?
    @ObservationIgnored private var rewardRetryAfter: TimeInterval = 0
    @ObservationIgnored private var replayProgress: [String: MissionProgress] = [:]
    private(set) var sessionCarID = ProgressionCatalog.starter
    private(set) var sessionRewards: [RewardRecord] = []
    private(set) var driveMissions: [MissionDefinition] = []
    private(set) var isAvailable = true
    /// The one-time free test drive: a car the player does not own, driven fully upgraded.
    private(set) var trialCarID: String?
    /// App Store unlocks, set only from StoreKit's verified receipts. They are not saved
    /// here, so a refund takes them away again. All Cars is different: see `grantAllCars`.
    private(set) var doubleCoins = false
    private(set) var maxUpgrades = false
    var coinMultiplier: Int { doubleCoins ? 2 : 1 }
    /// Every car in the garage, whether bought with coins or with All Cars.
    var ownsEveryCar: Bool { ProgressionCatalog.ids.allSatisfy(save.owned.contains) }
    @ObservationIgnored private var store: ProgressionStore?
    @ObservationIgnored private var draft = ProgressionSave()
    @ObservationIgnored private var attempts: [String: MissionAttempt] = [:]
    @ObservationIgnored private var publishTime: Double = 0
    @ObservationIgnored private var persistTime: Double = 0
    @ObservationIgnored private var sessionLedgerStart: Set<String> = []
    @ObservationIgnored private var roadDrive = UUID().uuidString
    /// Gear goals only make pause cards while the manual gearbox is selected.
    @ObservationIgnored var manualGearbox = false
    /// Distinct owned cars driven at least a metre; mirrors the "driven." receipts.
    @ObservationIgnored private var drivenCars = 0
    @ObservationIgnored private var sessionDistance: Double = 0
    @ObservationIgnored private var sessionCarCounted = true
    @ObservationIgnored private var wallStart = Date()
    @ObservationIgnored private var uptimeStart = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var masteryDefinitions = MissionCatalog.mastery

    init(directory: URL? = nil) {
        do {
            let directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("DriveAR",isDirectory:true)
            let store = try ProgressionStore(directory:directory)
            self.store = store; draft = try store.load(); save = draft
            drivenCars = draft.transactions.filter { $0.hasPrefix("driven.") }.count
        } catch { self.error = error.localizedDescription; isAvailable = false }
    }
    var allMissions: [MissionDefinition] { MissionCatalog.career + dailyMissions + masteryDefinitions + [contract] }
    var contract: MissionDefinition { MissionCatalog.contract(chapter:draft.chapter,serial:draft.contractSerial) }
    var dailyMissions: [MissionDefinition] { draft.daily.slots.compactMap { id in
        guard var m = MissionCatalog.dailyBank.first(where:{$0.id == id}) else { return nil }
        m.reward = ProgressionCatalog.roundCoins(Double(m.reward)*(1+0.2*Double(draft.daily.chapter-1)))
        return m
    } }
    var pendingNotification: RewardRecord? { save.ledger.first { !$0.presented } }
    /// Everything earned since the last Collect, oldest first.
    var pendingRewards: [RewardRecord] { save.ledger.filter { !$0.presented } }
    var paintUnlocked: Bool { save.paintShopUnlocked }
    func definition(_ id: String) -> MissionDefinition? { allMissions.first { $0.id == id } }
    func key(_ m: MissionDefinition) -> String { m.mode == .daily ? "\(draft.daily.day).\(m.id)" : m.id }
    func progress(_ m: MissionDefinition) -> MissionProgress { save.missions[key(m)] ?? MissionProgress() }
    func eligible(_ m: MissionDefinition) -> Bool {
        isAvailable && m.chapter <= draft.chapter && (m.carID == nil || draft.owned.contains(m.carID!))
    }
    /// Background goals are always live. Pins from older saves never gate scoring
    /// or leave completed rows stranded on the driving HUD.
    func automaticGoals(carID: String, limit: Int = 3) -> [MissionDefinition] {
        // Driving another car is a garage goal, and gear goals wait for Manual.
        Array(allMissions.filter {
            !$0.requiresCourse && eligible($0) && ($0.carID == nil || $0.carID == carID)
                && !progress($0).completed && $0.metric != .carsDriven
                && (manualGearbox || !$0.metric.needsManualGearbox)
        }.prefix(limit))
    }
    /// Keep this drive's three cards stable, including their completed state.
    /// Refill completed slots on Resume, never shuffle them while pause is open.
    func refreshDriveMissions() {
        guard trialCarID == nil else { return }
        let unfinished = driveMissions.filter { eligible($0) && !progress($0).completed }
        var next = unfinished
        let candidates = automaticGoals(carID: sessionCarID, limit: Int.max)
        // Show different actions first rather than three distance counters.
        for varied in [true, false] {
            for mission in candidates where !next.contains(where: { $0.id == mission.id }) {
                guard next.count < 3 else { break }
                if varied && next.contains(where: { $0.metric == mission.metric }) { continue }
                next.append(mission)
            }
        }
        driveMissions = next
    }
    func nextCourse(carID: String) -> MissionDefinition? {
        allMissions.first {
            $0.requiresCourse && eligible($0) && ($0.carID == nil || $0.carID == carID)
                && !progress($0).completed
        }
    }
    /// The levels every view and drive uses. Max Upgrades covers each car, including
    /// ones unlocked later, without touching the levels bought with coins.
    func parts(_ id: String) -> CarParts { maxUpgrades ? .maximum : save.parts[id] ?? CarParts() }
    /// What a mission pays, as shown and as credited.
    func reward(_ m: MissionDefinition) -> Int { m.reward * coinMultiplier }
    func setPaidUnlocks(doubleCoins: Bool, maxUpgrades: Bool) {
        if self.doubleCoins != doubleCoins { self.doubleCoins = doubleCoins }
        if self.maxUpgrades != maxUpgrades { self.maxUpgrades = maxUpgrades }
    }
    /// All Cars is written into ownership, so every ownership rule (driving, mastery,
    /// paint, the collection count) works unchanged. Each granted car keeps a receipt,
    /// so a refund removes exactly those cars and never one bought with coins.
    func grantAllCars() {
        guard isAvailable, ProgressionCatalog.ids.contains(where: { !draft.owned.contains($0) }) else { return }
        _ = transaction { s in
            for id in ProgressionCatalog.ids where !s.owned.contains(id) {
                s.owned.insert(id)
                s.parts[id] = s.parts[id] ?? CarParts()
                s.selectedPaints[id] = s.selectedPaints[id] ?? "factory"
                s.transactions.insert("iap.car.\(id)")
            }
        }
    }
    func revokeAllCars() {
        guard isAvailable, draft.transactions.contains(where: { $0.hasPrefix("iap.car.") }) else { return }
        _ = transaction { s in
            for id in ProgressionCatalog.ids where s.transactions.contains("iap.car.\(id)") {
                s.transactions.remove("iap.car.\(id)")
                if !s.transactions.contains("car.\(id)") && id != ProgressionCatalog.starter { s.owned.remove(id) }
            }
        }
    }

    func paint(_ id: String) -> CarPaint {
        let selected = save.selectedPaints[id] ?? "factory"
        return selected == "factory" ? .factory : CarPaint.paint(id:selected)
    }
    /// Fresh installs only: no mission finished, nothing bought or upgraded, offer not yet used.
    /// The daily login bonus lands in the ledger on first launch, so the ledger is not a signal.
    var shouldOfferTestDrive: Bool {
        isAvailable && !draft.introduced && draft.owned == [ProgressionCatalog.starter]
            && draft.parts.values.allSatisfy { $0 == CarParts() } && !draft.missions.values.contains { $0.completed }
    }
    /// May the AR drive open for this car? Owned cars, or the active test drive.
    func canLaunch(_ id: String) -> Bool { canDrive(id) || (isAvailable && trialCarID == id) }
    /// Starts the test drive. The offer is spent here, so it never returns. The trial
    /// earns nothing: scoring still requires owning the car.
    func beginTrial(carID: String) {
        guard isAvailable else { return }
        introduce()
        trialCarID = carID
        driveMissions = []
    }
    func endTrial() { trialCarID = nil }
    func canDrive(_ id: String) -> Bool { isAvailable && draft.owned.contains(id) && ProgressionCatalog.ids.contains(id) }
    @discardableResult private func transaction(_ action: (inout ProgressionSave) throws -> Void) -> Bool {
        guard isAvailable, let store else { return false }
        var next = draft
        do { try action(&next); next.sanitize(); try store.write(next); draft = next; save = next; error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func clearError() { error = nil }
    func refreshDay(now: Date = Date(), zone: TimeZone = .current) {
        // Reject a wall-clock jump backwards during this process independently of day strings.
        let expected = wallStart.addingTimeInterval(ProcessInfo.processInfo.systemUptime-uptimeStart)
        if now < expected.addingTimeInterval(-300) { clockNotice = "Daily goals return when the clock catches up. Career remains available."; return }
        var notice: String?
        let oldDay = draft.daily.day
        let bonus = 10 * coinMultiplier
        _ = transaction { notice = try DailySelector.refresh(now:now,zone:zone,save:&$0,bonus:bonus) }
        if oldDay != draft.daily.day {
            attempts = attempts.filter { !$0.key.hasPrefix("daily.") }
            let hadCards = !driveMissions.isEmpty
            driveMissions.removeAll { $0.mode == .daily }
            if hadCards { refreshDriveMissions() }
            if selectedChallenge?.hasPrefix("daily.") == true { selectedChallenge = nil; finishedChallenge = nil }
        }
        clockNotice = notice
    }
    func acknowledge(_ id: String) { _ = transaction { s in if let i = s.ledger.firstIndex(where:{$0.id == id}) { s.ledger[i].presented = true } } }
    func acknowledgeAll() { _ = transaction { s in for i in s.ledger.indices { s.ledger[i].presented = true } } }
    func introduce() { _ = transaction { $0.introduced = true } }
    @discardableResult func buyCar(_ id: String) -> Bool { transaction { try Economy.purchaseCar(id,save:&$0) } }
    @discardableResult func upgrade(_ id: String, part: UpgradePart, level: Int) -> Bool { transaction { try Economy.upgrade(id,part:part,expectedLevel:level,save:&$0) } }
    @discardableResult func applyPaint(_ id: String, color: String, free: Bool = false) -> Bool { transaction { try Economy.paint(id,color:color,free:free,save:&$0) } }
    func select(_ id: String) { guard canDrive(id) else { return }; _ = transaction { $0.selectedCar = id } }
    func activate(_ m: MissionDefinition, replay: Bool = false) {
        guard eligible(m) else { return }
        if m.requiresCourse { selectedChallenge = m.id; attempts[m.id] = MissionAttempt() }
        _ = transaction { s in
            s.active.insert(m.id)
            if !s.pinned.contains(m.id) { s.pinned = Array(([m.id]+s.pinned).prefix(3)) }
        }
    }
    func pin(_ id: String) {
        _ = transaction { s in
            if s.pinned.contains(id) { s.pinned.removeAll{$0 == id} }
            else if s.pinned.count < 3 { s.pinned.append(id) }
        }
    }
    func reroll(_ slot: Int) {
        guard draft.daily.slots.indices.contains(slot), !draft.daily.rerolled else { return }
        let oldID = draft.daily.slots[slot]
        guard let old = definition(oldID), progress(old).completed == false else { return }
        let families = Set(dailyMissions.filter { $0.id != oldID }.map(\.metric))
        let candidates = MissionCatalog.dailyBank.filter { $0.id != oldID && ($0.metric != old.metric || $0.target != old.target) && $0.difficulty == old.difficulty && !families.contains($0.metric) }
        let different = candidates.filter { $0.metric != old.metric }
        let pool = different.isEmpty ? candidates : different
        guard !pool.isEmpty else { return }
        let pick = pool[Int(DailySelector.hash(draft.daily.day+"reroll") % UInt64(pool.count))]
        _ = transaction { s in
            s.daily.slots[slot] = pick.id; s.daily.rerolled = true
            s.missions.removeValue(forKey:"\(s.daily.day).\(oldID)"); s.active.remove(oldID)
            s.pinned.removeAll{$0 == oldID}
        }
        if selectedChallenge == oldID { selectedChallenge = nil }
        if driveMissions.contains(where: { $0.id == oldID }) {
            driveMissions.removeAll { $0.id == oldID }; refreshDriveMissions()
        }
    }
    func beginSession(carID: String) {
        guard canDrive(carID) else { return }
        sessionCarID = carID
        sessionLedgerStart = Set(draft.ledger.map(\.id)); sessionRewards = []; attempts.removeAll()
        roadDrive = UUID().uuidString
        sessionDistance = 0; sessionCarCounted = draft.transactions.contains("driven.\(carID)")
        // Mastery starts when the car is actually selected for a session, never on preview.
        for m in masteryDefinitions where m.carID == carID && m.metric.passive { draft.active.insert(m.id) }
        draft.active.insert(contract.id)
        save = draft
        driveMissions = []
        refreshDriveMissions()
    }
    func endSession() {
        selectedChallenge = nil
        resetAttempt(message:"")
        flush()
        sessionRewards = draft.ledger.filter { !sessionLedgerStart.contains($0.id) }
    }
    func resetAttempt(message: String) {
        attempts.removeAll(); replayProgress.removeAll(); finishedChallenge = nil; attemptText = message
        for m in allMissions where m.scope != .cumulative && draft.missions[key(m)]?.completed != true {
            draft.missions[key(m)] = MissionProgress()
        }
        save = draft; flush()
    }
    /// Coins picked up off the floor. Owned cars only; the trial earns nothing.
    /// Double Coins doubles the credit; coin goals still count the coin's face value.
    @discardableResult func collectRoadCoins(_ coins: Int, carID: String) -> Bool {
        let credit = coins * coinMultiplier
        guard canDrive(carID), carID == sessionCarID,
              transaction({ try Economy.roadCoins(drive:roadDrive,coins:credit,now:Date(),save:&$0) }) else { return false }
        record(DrivingEvents(coinPickups:1,coinValue:coins,tenCoins:coins >= 10 ? 1 : 0), carID:carID)
        return true
    }
    /// A road coin vanished before it was collected; breaks coin streaks.
    func missedRoadCoin(carID: String) { record(DrivingEvents(coinMissed:true), carID:carID) }
    /// A photo was taken with the car placed.
    func recordPhoto(carID: String) { record(DrivingEvents(photos:1), carID:carID) }
    /// Events from outside the physics step. Published at once, since they can
    /// arrive while driving is paused.
    private func record(_ event: DrivingEvents, carID: String) {
        guard carID == sessionCarID else { return }
        consume(event, carID:carID, dt:0, scoredChallenge:nil)
        if save != draft { save = draft }
    }
    func stopChallenge() { selectedChallenge = nil; resetAttempt(message:"Free drive. Your banked progress is safe.") }
    func currentStep(for m: MissionDefinition) -> Int { attempts[m.id]?.step ?? 0 }
    func consume(_ event: DrivingEvents, carID: String, dt: Double, scoredChallenge: String?) {
        guard canDrive(carID) else { return }
        // A car joins the collection count once it has actually been driven.
        if !sessionCarCounted && carID == sessionCarID {
            sessionDistance += event.distance
            if sessionDistance >= 1 {
                sessionCarCounted = true
                if draft.transactions.insert("driven.\(carID)").inserted { drivenCars += 1 }
            }
        }
        var event = event
        event.carsDriven = drivenCars
        let chapter = draft.chapter
        // Filter eligibility once per sample, not once per mission's nested save scan.
        let missions = allMissions
        for m in missions where m.chapter <= chapter && (m.carID == nil || m.carID == carID) {
            // Ordinary goals need no Track tap. A spatial goal still needs its
            // own validated layout; it cannot score against somebody else's course.
            guard !m.requiresCourse || (draft.active.contains(m.id) && scoredChallenge == m.id) else { continue }
            let k = key(m)
            let replay = draft.missions[k]?.completed == true
            guard !replay || scoredChallenge == m.id else { continue }
            guard finishedChallenge != m.id else { continue }
            var progress = replay ? (replayProgress[m.id] ?? MissionProgress()) : (draft.missions[k] ?? MissionProgress())
            var attempt = attempts[m.id] ?? MissionAttempt()
            attempt.advance(m,event:event,progress:&progress)
            attempts[m.id] = attempt
            if replay { replayProgress[m.id] = progress } else { draft.missions[k] = progress }
            if scoredChallenge == m.id && !m.steps.isEmpty {
                let i = min(attempt.step,m.steps.count-1)
                let text = "\(min(attempt.step+1,m.steps.count))/\(m.steps.count) · \(MissionCatalog.stepText([m.steps[i]]))"
                if text != attemptText { attemptText = text }
            }
            if progress.value >= m.target {
                if !replay {
                    guard ProcessInfo.processInfo.systemUptime >= rewardRetryAfter else { continue }
                    guard complete(m) else { rewardRetryAfter = ProcessInfo.processInfo.systemUptime+2; continue }
                }
                if scoredChallenge == m.id { finishedChallenge = m.id }
            }
        }
        publishTime += dt; persistTime += dt
        if publishTime >= 0.125 { publishTime = 0; if save != draft { save = draft } }
        if persistTime >= 2 { persistTime = 0; flush() }
    }
    @discardableResult private func complete(_ m: MissionDefinition) -> Bool {
        let k = key(m), now = Date(), multiplier = coinMultiplier
        return transaction { s in
            guard s.missions[k]?.completed != true else { return }
            s.missions[k,default:MissionProgress()].completed = true
            s.pinned.removeAll { $0 == m.id }
            try Economy.grant(id:"reward.\(k)",title:m.title,coins:m.reward*multiplier,now:now,save:&s)
            if m.mode == .career {
                let chapter = MissionCatalog.career.filter{$0.chapter == m.chapter}
                if chapter.allSatisfy({s.missions[$0.id]?.completed == true}) {
                    try Economy.grant(id:"chapter.\(m.chapter)",title:"\(MissionCatalog.chapters[m.chapter-1]) complete",coins:100*m.chapter*multiplier,now:now,save:&s)
                }
            }
            if m.mode == .daily && s.daily.slots.allSatisfy({s.missions["\(s.daily.day).\($0)"]?.completed == true}) {
                try Economy.grant(id:"daily-set.\(s.daily.day)",title:"Daily set complete",coins:ProgressionCatalog.roundCoins(20*(1+0.2*Double(s.daily.chapter-1)))*multiplier,now:now,save:&s)
            }
            if m.mode == .mastery, let id = m.carID,
               masteryDefinitions.filter({$0.carID == id}).allSatisfy({s.missions[$0.id]?.completed == true}),
               !s.transactions.contains("mastered.\(id)") {
                s.transactions.insert("mastered.\(id)")
                if CarCatalog.car(id:id).isRepaintable { s.freeMasteryPaints.insert(id) }
            }
            if m.mode == .contract {
                s.active.remove(m.id); s.contractSerial += 1
                s.active.insert(MissionCatalog.contract(chapter:s.chapter,serial:s.contractSerial).id)
            }
        }
    }
    func flush() {
        guard isAvailable, let store else { return }
        do { try store.write(draft); if save != draft { save = draft } }
        catch { self.error = error.localizedDescription }
    }
}
