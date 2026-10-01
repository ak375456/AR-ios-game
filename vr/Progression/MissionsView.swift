import SwiftUI

extension MissionDefinition {
    var symbol: String {
        switch metric {
        case .reverseDistance: "arrow.uturn.backward"
        case .brakeStops: "hand.raised.fill"
        case .distance: "point.topleft.down.to.point.bottomright.curvepath"
        case .movingTime: "stopwatch.fill"
        case .cleanTime: "shield.lefthalf.filled"
        case .accelerationStops: "speedometer"
        case .slalom, .slalomRuns: "cone.fill"
        case .gates, .gateLaps: "flag.checkered"
        case .parking, .parkingCount: "parkingsign.circle.fill"
        case .coinPickups: "circle.inset.filled"
        case .coinValue: "square.stack.3d.up.fill"
        case .tenCoins: "10.circle.fill"
        case .coinStreak: "flame.fill"
        case .topSpeed: "gauge.with.dots.needle.67percent"
        case .fullTurns: "arrow.clockwise.circle.fill"
        case .uTurns: "arrow.uturn.left.circle.fill"
        case .handbrakeTurns: "arrow.triangle.turn.up.right.circle.fill"
        case .nonStop: "infinity"
        case .smooth: "leaf.fill"
        case .upshifts: "arrow.up.circle.fill"
        case .reachGear: "gearshape.2.fill"
        case .photos: "camera.fill"
        case .carsDriven: "car.2.fill"
        default: "trophy.fill"
        }
    }

}

/// Three readable cards in pause; completed cards stay visible until Resume.
struct PauseMissionCard: View {
    let mission: MissionDefinition
    let progress: MissionProgress
    private var accent: Color { progress.completed ? GaragePalette.success : GaragePalette.neon }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: progress.completed ? "checkmark" : mission.symbol)
                    .font(.system(size: 21, weight: .heavy)).frame(width: 36, height: 40)
                    .background(accent, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
                Text(mission.shortObjective).font(GameType.display(22))
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(mission.quickInstruction).font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            GameProgress(value: progress.completed ? 1 : progress.value / mission.target, color: accent)
            HStack(spacing: 8) {
                if progress.completed {
                    Label("Completed", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.heavy))
                } else {
                    Text(mission.formatted(progress.value)).font(.subheadline.weight(.heavy)).monospacedDigit()
                }
                Spacer(minLength: 0)
                CoinLabel(amount: mission.reward, iconColor: GaragePalette.amberBottom)
            }
        }.padding(14).foregroundStyle(GaragePalette.midnight)
            .background(GaragePalette.paper, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent, lineWidth: 2))
            .compositingGroup().shadow(color: .black.opacity(0.4), radius: 0, y: 4)
            .accessibilityElement(children: .combine)
            .accessibilityValue(progress.completed ? "Reward received" : "Tracks automatically")
    }
}

struct MissionsView: View {
    let progression: ProgressionModel
    let carID: String
    let onStart: (MissionDefinition) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var mode = MissionMode.career
    @State private var chapter = 1
    @State private var review: MissionDefinition?
    @State private var showCompleted = false
    private var definitions: [MissionDefinition] {
        switch mode {
        case .career: MissionCatalog.careerChapters[chapter-1]
        case .daily: progression.dailyMissions
        case .mastery: MissionCatalog.mastery.filter { $0.carID == carID }
        case .contract: [progression.contract]
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 6) {
                    ForEach([MissionMode.career, .daily, .mastery], id: \.self) { item in
                        Button { mode = item; showCompleted = false } label: {
                            Text(item.rawValue.capitalized).font(GameType.display(18)).lineLimit(1).minimumScaleFactor(0.7).dynamicTypeSize(...DynamicTypeSize.xxxLarge).frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(mode == item ? GaragePalette.midnight : GaragePalette.paper)
                                .background(mode == item ? GaragePalette.neon : GaragePalette.indigo, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityAddTraits(mode == item ? .isSelected : [])
                    }
                }
                if mode == .career { chapterHeader }
                else if mode == .daily {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Today's three").font(GameType.display(27))
                            Text("Finish all 3 for a bonus").font(.caption).foregroundStyle(GaragePalette.muted)
                        }
                        Spacer()
                        Image(systemName: "sun.max.fill").font(.title).foregroundStyle(GaragePalette.amberTop)
                    }
                    if let notice = progression.clockNotice { Text(notice).font(.caption) }
                } else {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(GaragePalette.amberTop)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(CarCatalog.car(id: carID).displayName).font(GameType.display(25))
                            Text("6 goals • Mastery badge + paint gift").font(.caption).foregroundStyle(GaragePalette.muted)
                        }
                    }
                }
                let unfinished = definitions.filter { !progression.progress($0).completed }
                ForEach(unfinished) { mission in
                    missionRow(mission)
                }
                let completed = definitions.filter { progression.progress($0).completed }
                if !completed.isEmpty {
                    DisclosureGroup(isExpanded: $showCompleted) {
                        VStack(spacing: 10) { ForEach(completed) { missionRow($0) } }.padding(.top, 12)
                    } label: {
                        Label("\(completed.count) completed", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.bold)).foregroundStyle(GaragePalette.success).frame(minHeight: 44)
                    }.tint(GaragePalette.success)
                }
                if mode == .career {
                    Divider().overlay(GaragePalette.indigo)
                    Text("KEEP ROLLING").font(.caption.weight(.heavy)).tracking(1).foregroundStyle(GaragePalette.muted)
                    missionRow(progression.contract)
                }
            }.padding(18).padding(.bottom, 12)
        }.onAppear {
            chapter = progression.save.chapter
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--daily") { mode = .daily }
            #endif
        }
        .sheet(item: $review) { mission in
            VStack(spacing: 0) {
                GameSheetHeader(title: "Mission", close: { review = nil })
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Image(systemName: mission.symbol).font(.system(size: 42, weight: .bold)).foregroundStyle(GaragePalette.neon)
                        Text(mission.shortObjective).font(GameType.display(30))
                        Text(mission.objective).font(.body)
                        if !mission.steps.isEmpty { Text("Follow the lit markers in order.").font(.subheadline).foregroundStyle(GaragePalette.muted) }
                        HStack { CoinLabel(amount: mission.reward); if mission.mode == .career { Label("1", systemImage: "star.fill").foregroundStyle(GaragePalette.neon) } }
                        if progression.progress(mission).completed {
                            Label("Reward received", systemImage: "checkmark.circle.fill").foregroundStyle(GaragePalette.success)
                        }
                        DisclosureGroup("How progress works") {
                            Text(mission.failureRule + (mission.requiresCourse ? " Your own course is kept while the challenge is running." : " Progress tracks automatically while you drive."))
                                .font(.subheadline).padding(.top, 8)
                        }
                        if mission.requiresCourse {
                            Button {
                                review = nil; onStart(mission)
                            } label: { Text(progression.progress(mission).completed ? "Practice run" : "Drive course").frame(maxWidth: .infinity) }
                                .buttonStyle(AmberActionStyle()).disabled(!progression.eligible(mission))
                        } else {
                            Label("Tracks while you drive", systemImage: "bolt.fill").font(.subheadline.weight(.bold)).foregroundStyle(GaragePalette.neon)
                        }
                    }.padding(22)
                }
            }.foregroundStyle(GaragePalette.paper).background(GaragePalette.midnight)
            .presentationDragIndicator(.visible)
        }
    }
    private var chapterHeader: some View {
        let done = definitions.filter { progression.progress($0).completed }.count
        return VStack(spacing: 12) {
            HStack {
                Button { chapter -= 1; showCompleted = false } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(chapter == 1)
                VStack(spacing: 3) {
                    Text("CHAPTER \(chapter)").font(.caption2.weight(.black)).tracking(1).foregroundStyle(GaragePalette.neon)
                    Text(MissionCatalog.chapters[chapter-1]).font(GameType.display(27)).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
                Button { chapter += 1; showCompleted = false } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(chapter == 10)
            }.buttonStyle(.plain)
            GameProgress(value: Double(done) / 12, color: GaragePalette.amberTop)
            HStack {
                Text("\(done) / 12").monospacedDigit().font(.caption.weight(.heavy))
                Spacer()
                Text(chapter > progression.save.chapter ? "Locked • finish 8 in chapter \(chapter-1)" : chapter == 10 ? "Final chapter" : done >= 8 ? "Next chapter open" : "\(8-done) more → Chapter \(chapter+1)")
                    .font(.caption).foregroundStyle(GaragePalette.muted)
            }
        }.padding(.bottom, 4)
    }
    private func missionRow(_ mission: MissionDefinition) -> some View {
        let progress = progression.progress(mission)
        let eligible = progression.eligible(mission)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: progress.completed ? "checkmark" : mission.symbol).font(.system(size: 22, weight: .bold))
                    .foregroundStyle(GaragePalette.midnight).frame(width: 36, height: 40)
                    .background(progress.completed ? GaragePalette.success : GaragePalette.neon, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(mission.shortObjective).font(GameType.display(21)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { review = mission } label: { Image(systemName: "info.circle").font(.body.weight(.bold)).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Details for \(mission.shortObjective)")
            }
            if !progress.completed {
                Text(mission.quickInstruction).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                GameProgress(value: progress.value / mission.target, color: GaragePalette.neon)
                let rowLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 8))
                rowLayout {
                    Text(mission.formatted(progress.value)).font(.caption.weight(.bold)).monospacedDigit()
                    Spacer(minLength: 4)
                    CoinLabel(amount: mission.reward).font(.caption)
                    if mission.mode == .career { Label("1", systemImage: "star.fill").font(.caption.weight(.bold)).foregroundStyle(Color(red: 0.08, green: 0.4, blue: 0.5)) }
                    if !eligible { Image(systemName: "lock.fill").accessibilityLabel("Locked") }
                    else if mission.requiresCourse {
                        Button { review = mission } label: { Text("Course").font(GameType.display(17)).padding(.horizontal, 12).frame(minHeight: 44).background(GaragePalette.amberTop, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                    } else { Label("Auto", systemImage: "bolt.fill").font(.caption.weight(.heavy)) }
                    if mode == .daily && !progression.save.daily.rerolled,
                       let index = progression.dailyMissions.firstIndex(where: { $0.id == mission.id }) {
                        Button { progression.reroll(index) } label: { Image(systemName: "arrow.triangle.2.circlepath").frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Use free reroll for \(mission.shortObjective)")
                    }
                }
            }
        }.padding(14).foregroundStyle(GaragePalette.midnight)
            .background(GaragePalette.paper, in: RoundedRectangle(cornerRadius: 12))
            .compositingGroup().shadow(color: .black.opacity(0.5), radius: 0, y: 4).opacity(eligible ? 1 : 0.6)
    }
}
/// Garage card: every mission finished since the last visit, bundled in one list
/// with a single Collect all. Coins are already in the wallet; this acknowledges them.
struct RewardsReadyCard: View {
    let progression: ProgressionModel
    let haptics: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let visibleRows = 4

    var body: some View {
        let rewards = progression.pendingRewards
        if !rewards.isEmpty {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.title3).foregroundStyle(GaragePalette.amberTop)
                    Text(rewards.count == 1 ? "Mission complete" : "\(rewards.count) missions complete")
                        .font(GameType.display(20)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    CoinLabel(amount: rewards.reduce(0) { $0 + $1.coins })
                }
                VStack(spacing: 0) {
                    ForEach(Array(rewards.prefix(visibleRows))) { reward in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(GaragePalette.success)
                            Text(reward.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("+\(reward.coins)").font(.subheadline.weight(.heavy)).monospacedDigit()
                                .foregroundStyle(GaragePalette.amberTop)
                        }.frame(minHeight: 36)
                    }
                    if rewards.count > visibleRows {
                        Text("and \(rewards.count - visibleRows) more")
                            .font(.caption.weight(.semibold)).foregroundStyle(GaragePalette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                }
                Button(action: collect) {
                    Text("Collect all").frame(maxWidth: .infinity)
                }.buttonStyle(AmberActionStyle())
            }
            .padding(14)
            .background(GaragePalette.indigo, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(GaragePalette.amberTop.opacity(0.7), lineWidth: 1.5))
            .accessibilityElement(children: .contain)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }
    private func collect() {
        if haptics { Haptics.success() }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { progression.acknowledgeAll() }
    }
}

struct SessionSummaryView: View {
    let progression: ProgressionModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            GameSheetHeader(title: "Nice drive!", close: { dismiss() })
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "flag.checkered").font(.system(size: 48)).foregroundStyle(GaragePalette.neon)
                    Text("+\(progression.sessionRewards.reduce(0) { $0 + $1.coins })").font(GameType.display(54)).monospacedDigit().foregroundStyle(GaragePalette.amberTop)
                    Text("COINS EARNED").font(.caption.weight(.heavy)).tracking(1)
                    let mastery = MissionCatalog.mastery.filter { $0.carID == progression.sessionCarID }
                    let mastered = mastery.filter { progression.progress($0).completed }.count
                    HStack {
                        Label("\(mastered) / 6 mastery", systemImage: "checkmark.seal.fill")
                        Spacer()
                        Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(GaragePalette.success)
                    }.font(.subheadline.weight(.bold))
                    DisclosureGroup("Rewards · \(progression.sessionRewards.count)") {
                        VStack(spacing: 14) {
                            ForEach(progression.sessionRewards) { reward in
                                LabeledContent(reward.title, value: "+\(reward.coins)").font(.subheadline)
                            }
                        }.padding(.top, 14)
                    }
                    Button { dismiss() } label: { Text("Back to garage").frame(maxWidth: .infinity) }.buttonStyle(AmberActionStyle())
                }.padding(24)
            }
        }.foregroundStyle(GaragePalette.paper).background(GaragePalette.midnight)
    }
}
