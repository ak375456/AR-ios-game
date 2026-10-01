import SwiftUI

struct UpgradeGarageSheet: View {
    let car: CarDefinition
    let progression: ProgressionModel
    let settings: ControlSettings
    let onMissions: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UpgradePart = .engine
    @State private var receipt: String?
    @State private var reviewedLevel = 1
    @State private var cooling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            GameSheetHeader(title: "Workshop", close: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(car.displayName).font(GameType.display(24))
                            Text("MAKE IT YOURS").font(.caption2.weight(.heavy)).tracking(1).foregroundStyle(GaragePalette.neon)
                        }
                        Spacer()
                        WalletView(progression: progression)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(UpgradePart.allCases) { part in
                                Button { selected = part; receipt = nil; reviewedLevel = progression.parts(car.id)[part] } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: part.icon).font(.title2).frame(height: 28)
                                        Text(part.title).font(.caption2.weight(.bold))
                                        HStack(spacing: 3) {
                                            ForEach(1...5, id: \.self) { i in
                                                RoundedRectangle(cornerRadius: 1).fill(i <= progression.parts(car.id)[part] ? GaragePalette.amberTop : GaragePalette.midnight).frame(width: 9, height: 5)
                                            }
                                        }
                                    }.padding(12).background(selected == part ? GaragePalette.indigo : GaragePalette.deepIndigo, in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected == part ? GaragePalette.neon : .clear, lineWidth: 2))
                                }.buttonStyle(.plain).accessibilityLabel("\(part.title), level \(progression.parts(car.id)[part]) of 5").accessibilityAddTraits(selected == part ? .isSelected : [])
                            }
                        }.padding(.vertical, 3)
                    }
                    detail
                    DisclosureGroup("About ratings") {
                        Text("Ratings share a 0–100 scale across all cars. Top speed is estimated from reference wheel geometry. Handling uses the loaded model while driving.").font(.caption).padding(.top, 8)
                    }.font(.subheadline).foregroundStyle(GaragePalette.muted)
                }.padding(20)
            }
        }.foregroundStyle(GaragePalette.paper).background(GaragePalette.midnight)
            .onAppear { reviewedLevel = progression.parts(car.id)[selected] }
    }
    private var detail: some View {
        let parts = progression.parts(car.id), level = parts[selected]
        var next = parts; next[selected] = min(5, level+1)
        var top = parts; top[selected] = 5
        let current = EffectiveTuning.estimate(car: car, parts: parts), after = EffectiveTuning.estimate(car: car, parts: next)
        let maxed = EffectiveTuning.estimate(car: car, parts: top)
        let cost = ProgressionCatalog.upgradeCost(carID: car.id, part: selected, level: level)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(selected.title).font(GameType.display(30))
                Spacer()
                Text("LV \(level) / 5").font(.caption.weight(.heavy)).foregroundStyle(GaragePalette.neon)
            }
            Text(selected.benefit).font(.subheadline).foregroundStyle(GaragePalette.muted)
            UpgradeMeter(title: metricName, unit: unitLabel,
                current: number(current), next: number(after), maximum: number(maxed),
                scale: selected == .transmission ? number(maxed) * 1.15 : 100,
                isMaxed: level == 5, format: { String(format: "%.0f", $0) })
            if let receipt {
                Label(receipt, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.bold)).foregroundStyle(GaragePalette.success)
                    .transition(.opacity)
            }
            if level == 5 {
                Label("Fully upgraded", systemImage: "checkmark.seal.fill").font(GameType.display(24)).foregroundStyle(GaragePalette.success)
            } else if progression.save.wallet < cost {
                HStack { CoinLabel(amount: cost); Spacer(); Text("\(cost-progression.save.wallet) more needed").font(.caption.weight(.bold)) }
                Button(action: onMissions) { Text("Earn coins").frame(maxWidth: .infinity) }.buttonStyle(AmberActionStyle())
            } else {
                HStack { Text("Balance after").font(.caption); Spacer(); CoinLabel(amount: progression.save.wallet-cost) }
                Button {
                    guard !cooling, progression.upgrade(car.id, part: selected, level: reviewedLevel) else { return }
                    let fitted = reviewedLevel + 1
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.8, bounce: 0.15)) { reviewedLevel = fitted }
                    receipt = "Level \(fitted) fitted"
                    if settings.usesHaptics { Haptics.success() }
                    cooling = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.9)); cooling = false
                        try? await Task.sleep(for: .seconds(1.2)); if receipt == "Level \(fitted) fitted" { receipt = nil }
                    }
                } label: { HStack { Text("Upgrade"); Spacer(); CoinLabel(amount: cost, iconColor: GaragePalette.midnight) }.frame(maxWidth: .infinity) }.buttonStyle(AmberActionStyle())
            }
        }
    }
    private var unitLabel: String { selected == .transmission ? settings.speedUnit.abbreviation : "/100" }
    private var metricName: String { selected == .transmission ? "Estimated top speed" : "\(selected == .engine ? "Acceleration" : selected == .tires ? "Grip" : selected == .steering ? "Agility" : "Drift control") rating" }
    private func number(_ tuning: VehicleTuning) -> Double {
        if selected == .transmission { return Double(SimulationScale.displaySpeed(renderedMetresPerSecond:tuning.topSpeed,unit:settings.speedUnit)) }
        return EffectiveTuning.ratings(tuning)[selected == .engine ? 1 : selected == .tires ? 2 : selected == .steering ? 3 : 4].1
    }
}

struct PaintGarageSheet: View {
    let car: CarDefinition
    let progression: ProgressionModel
    let settings: ControlSettings
    @Environment(\.dismiss) private var dismiss
    @State private var preview = CarPaint.factory
    @State private var message = ""
    var body: some View {
        VStack(spacing: 0) {
            GameSheetHeader(title: "Paint shop", close: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ZStack { GarageStudio(); CarPreviewView(car: car, paint: preview) { _ in }.padding(.vertical, 12) }.frame(height: 240)
                    if !car.isRepaintable {
                        Text("Original finish").font(GameType.display(27))
                        Text("This car keeps its signature colors.").font(.subheadline).foregroundStyle(GaragePalette.muted)
                    } else {
                        HStack {
                            Text(preview.name).font(GameType.display(28))
                            Spacer()
                            if isOwned(preview) { Label("Owned", systemImage: "checkmark.circle.fill").font(.caption.weight(.bold)).foregroundStyle(GaragePalette.success) }
                            else { CoinLabel(amount: 30) }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 14) {
                            ForEach([CarPaint.factory] + CarPaint.all) { paint in
                                Button { preview = paint; message = "" } label: {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(paint.id == "factory" ? GaragePalette.paper : Color(hue: Double(paint.hue)/360, saturation: Double(paint.saturation), brightness: Double(paint.brightness)))
                                        .frame(height: 48)
                                        .overlay { if preview == paint { Image(systemName: "checkmark").font(.title3.bold()).foregroundStyle(.white).shadow(color: .black, radius: 1) } else if paint.id == "factory" { Image(systemName: "car.side.fill").foregroundStyle(GaragePalette.midnight) } }
                                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(preview == paint ? .white : .white.opacity(0.25), lineWidth: preview == paint ? 3 : 1))
                                        .compositingGroup().shadow(color: .black.opacity(0.5), radius: 0, y: 3)
                                }.buttonStyle(.plain).accessibilityLabel("\(paint.name), \(isOwned(paint) ? "owned" : "30 coins")").accessibilityAddTraits(preview == paint ? .isSelected : [])
                            }
                        }
                        let gift = progression.save.freeMasteryPaints.contains(car.id) && !isOwned(preview)
                        if !progression.paintUnlocked { Label("Finish the first 6 career goals to unlock paint", systemImage: "lock.fill").font(.subheadline) }
                        Button {
                            if progression.applyPaint(car.id, color: preview.id, free: gift) {
                                message = "Paint applied"
                                if settings.usesHaptics { Haptics.success() }
                            }
                        } label: { Text(progression.paint(car.id) == preview ? "Applied ✓" : gift ? "Use paint gift" : isOwned(preview) ? "Apply paint" : "Unlock · 30").frame(maxWidth: .infinity) }
                            .buttonStyle(AmberActionStyle()).disabled(progression.paint(car.id) == preview || (!isOwned(preview) && (!progression.paintUnlocked || (!gift && progression.save.wallet < 30))))
                        if !isOwned(preview) && progression.paintUnlocked && progression.save.wallet < 30 && !gift { Text("\(30-progression.save.wallet) more coins needed").font(.caption) }
                        if !message.isEmpty { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(GaragePalette.success) }
                    }
                }.padding(20)
            }
        }.foregroundStyle(GaragePalette.paper).background(GaragePalette.midnight).onAppear { preview = progression.paint(car.id) }
    }
    private func isOwned(_ paint: CarPaint) -> Bool { paint.id == "factory" || progression.save.paints[car.id]?.contains(paint.id) == true }
}

struct CarPurchaseSheet: View {
    let car: CarDefinition
    let progression: ProgressionModel
    let settings: ControlSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            GameSheetHeader(title: "New keys", close: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ZStack { GarageStudio(); CarPreviewView(car: car, paint: .factory) { _ in }.padding(.vertical, 12) }.frame(height: 220)
                    Text(car.displayName).font(GameType.display(30))
                    StatsOverview(car: car, parts: CarParts(), unit: settings.speedUnit)
                    let slot = ProgressionCatalog.slot(car.id) ?? 0
                    requirement("\(ProgressionCatalog.prices[slot]) coins", met: progression.save.wallet >= ProgressionCatalog.prices[slot])
                    requirement("\(ProgressionCatalog.stars[slot]) career stars", met: progression.save.stars >= ProgressionCatalog.stars[slot])
                    if slot > 0 { requirement("Own \(CarCatalog.car(id: ProgressionCatalog.ids[slot-1]).displayName)", met: progression.save.owned.contains(ProgressionCatalog.ids[slot-1])) }
                    if let block = Economy.carBlock(car.id, save: progression.save) { Text(block).font(.caption.weight(.bold)).foregroundStyle(GaragePalette.amberTop) }
                    Button {
                        if progression.buyCar(car.id) { if settings.usesHaptics { Haptics.success() }; dismiss() }
                    } label: { HStack { Text("Unlock car"); Spacer(); CoinLabel(amount: ProgressionCatalog.prices[slot], iconColor: GaragePalette.midnight) } }
                        .buttonStyle(AmberActionStyle()).disabled(Economy.carBlock(car.id, save: progression.save) != nil || progression.save.owned.contains(car.id))
                    DisclosureGroup("Fully upgraded potential") {
                        StatsOverview(car: car, parts: .maximum, unit: settings.speedUnit).padding(.top, 12)
                        Text("New cars start at level 1. Upgrades sold separately.").font(.caption)
                    }.font(.subheadline)
                }.padding(20)
            }
        }.foregroundStyle(GaragePalette.paper).background(GaragePalette.midnight)
    }
    private func requirement(_ text: String, met: Bool) -> some View {
        Label(text, systemImage: met ? "checkmark.circle.fill" : "lock.fill").font(.subheadline.weight(.semibold))
            .foregroundStyle(met ? GaragePalette.success : GaragePalette.paper)
    }
}

/// Three overlapping layers on one track: what the car has now (cyan), what the
/// next level adds (gold), and the ceiling this part can reach (violet).
struct UpgradeMeter: View {
    let title: String
    let unit: String
    let current: Double
    let next: Double
    let maximum: Double
    let scale: Double
    let isMaxed: Bool
    let format: (Double) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let currentColor = GaragePalette.neon
    static let nextColor = GaragePalette.amberTop
    static let maxColor = Color(red: 0.62, green: 0.56, blue: 0.98)

    private func fraction(_ value: Double) -> CGFloat { CGFloat(min(max(value / max(scale, 1), 0), 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased()).font(.caption.weight(.heavy)).tracking(1).foregroundStyle(GaragePalette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(format(current)).font(GameType.display(44)).monospacedDigit().contentTransition(.numericText(value: current))
                Text(unit).font(.subheadline.weight(.bold)).foregroundStyle(GaragePalette.muted)
                Spacer(minLength: 8)
                if isMaxed {
                    Label("MAX", systemImage: "checkmark.seal.fill").font(.subheadline.weight(.heavy)).foregroundStyle(GaragePalette.success)
                } else {
                    Text("+\(format(next - current))").font(.subheadline.weight(.heavy)).monospacedDigit()
                        .foregroundStyle(Self.nextColor).contentTransition(.numericText(value: next - current))
                }
            }
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(GaragePalette.midnight)
                    Capsule().fill(Self.maxColor.opacity(0.6)).frame(width: max(w * fraction(maximum), 16))
                    Capsule().fill(Self.nextColor).frame(width: max(w * fraction(next), 16))
                    Capsule().fill(Self.currentColor).frame(width: max(w * fraction(current), 16))
                }
            }.frame(height: 18)
            HStack(spacing: 0) {
                legend("Now", format(current), Self.currentColor)
                Spacer(minLength: 8)
                if !isMaxed { legend("Next", format(next), Self.nextColor); Spacer(minLength: 8) }
                legend("Max", format(maximum), Self.maxColor)
            }
        }
        .padding(20).background(GaragePalette.indigo, in: RoundedRectangle(cornerRadius: 12))
        .animation(reduceMotion ? nil : .spring(duration: 0.8, bounce: 0.15), value: current)
        .animation(reduceMotion ? nil : .spring(duration: 0.8, bounce: 0.15), value: next)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). Now \(format(current)) \(unit)\(isMaxed ? ", fully upgraded" : ", next level \(format(next))"), maximum \(format(maximum))")
    }
    private func legend(_ name: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(name).font(.caption.weight(.heavy)).foregroundStyle(GaragePalette.muted)
            Text(value).font(.caption.weight(.heavy)).monospacedDigit()
        }
    }
}
