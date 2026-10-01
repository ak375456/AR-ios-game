import SwiftUI

struct HomeView: View {
    let progression: ProgressionModel
    @Bindable var settings: ControlSettings
    let onPlay: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedID = ProgressionCatalog.starter
    @State private var tab = GarageTab.garage
    @State private var previewStatus: CarPreviewStatus = .loading
    @State private var showingSettings = false
    @State private var sheet: GarageSheet?
    private var car: CarDefinition { CarCatalog.car(id: selectedID) }
    private var owned: Bool { progression.save.owned.contains(selectedID) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header.padding(.horizontal, 18).padding(.vertical, 10)
                switch tab {
                case .garage:
                    ScrollView {
                        VStack(spacing: 16) {
                            RewardsReadyCard(progression: progression, haptics: settings.usesHaptics)
                            selection
                            stage.frame(height: min(300, max(205, geometry.size.height * 0.39)))
                            if owned {
                                StatsOverview(car: car, parts: progression.parts(car.id), unit: settings.speedUnit)
                                HStack(spacing: 12) {
                                    Button { sheet = .upgrades } label: { Label("Upgrade", systemImage: "wrench.fill").frame(maxWidth: .infinity) }
                                    Button { sheet = .paint } label: { Label("Paint", systemImage: "paintbrush.pointed.fill").frame(maxWidth: .infinity) }
                                }.buttonStyle(GameButtonStyle(compact: true))
                            } else {
                                HStack(alignment: .top) {
                                    Image(systemName: "lock.fill").foregroundStyle(GaragePalette.amberTop)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(Economy.carBlock(car.id, save: progression.save) ?? "Ready to unlock").font(.subheadline.weight(.bold))
                                        HStack { CoinLabel(amount: ProgressionCatalog.prices[ProgressionCatalog.slot(car.id)!]); Label("\(ProgressionCatalog.stars[ProgressionCatalog.slot(car.id)!])", systemImage: "star.fill").foregroundStyle(GaragePalette.neon) }.font(.caption)
                                    }
                                    Spacer()
                                }.padding(14).background(GaragePalette.indigo, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }.padding(.horizontal, 18).padding(.bottom, 20)
                    }.scrollIndicators(.hidden)
                case .missions:
                    MissionsView(progression: progression, carID: progression.save.selectedCar) { mission in
                        progression.activate(mission); onPlay(mission.carID ?? progression.save.selectedCar)
                    }
                case .collection: collection
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .background(GarageBackdrop())
        }.foregroundStyle(GaragePalette.paper)
        .sheet(item: $sheet) { item in
            switch item {
            case .upgrades: UpgradeGarageSheet(car: car, progression: progression, settings: settings, onMissions: { sheet = nil; tab = .missions })
            case .paint: PaintGarageSheet(car: car, progression: progression, settings: settings)
            case .purchase: CarPurchaseSheet(car: car, progression: progression, settings: settings)
            }
        }
        .sheet(isPresented: $showingSettings) { ControlSettingsView(settings: settings) }
        .onAppear {
            selectedID = progression.save.selectedCar
            #if DEBUG && targetEnvironment(simulator)
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--collection") { tab = .collection }
            if args.contains("--missions") || args.contains("--daily") { tab = .missions }
            if args.contains("--locked") { selectedID = ProgressionCatalog.ids[1] }
            if let value = args.first(where: { $0.hasPrefix("--car=") })?.dropFirst(6), ProgressionCatalog.ids.contains(String(value)) { selectedID = String(value) }
            if args.contains("--purchase") { sheet = .purchase }
            if args.contains("--upgrades") { sheet = .upgrades }
            if args.contains("--paint") { sheet = .paint }
            #endif
        }
    }
    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(tab == .garage ? "DRIVE" : tab.rawValue).font(GameType.display(tab == .garage ? 32 : 26)).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize { WalletView(progression: progression) }
                Button { showingSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 20, weight: .bold)).frame(width: 44, height: 44)
                        .background(GaragePalette.indigo, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityLabel("Controls and settings")
            }
            if typeSize.isAccessibilitySize { WalletView(progression: progression).frame(maxWidth: .infinity, alignment: .trailing) }
        }
    }
    private var selection: some View {
        HStack(spacing: 8) {
            Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 44) }.accessibilityLabel("Previous car")
            VStack(spacing: 2) {
                Text(car.displayName).font(GameType.display(28)).multilineTextAlignment(.center)
                Text(car.carClass.label.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(GaragePalette.neon)
            }.frame(maxWidth: .infinity)
            Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 44) }.accessibilityLabel("Next car")
        }.buttonStyle(GameButtonStyle(compact: true))
    }
    private var stage: some View {
        ZStack(alignment: .bottom) {
            GarageStudio()
            CarPreviewView(car: car, paint: owned ? progression.paint(car.id) : .factory) { previewStatus = $0 }
                .padding(.vertical, 12)
            if previewStatus == .loading { ProgressView().padding(30) }
            if previewStatus == .failed { Label("Preview unavailable", systemImage: "exclamationmark.triangle").font(.caption).padding(12) }
            HStack {
                Text(String(format: "%02d / 28", (ProgressionCatalog.slot(car.id) ?? 0) + 1)).monospacedDigit()
                Spacer()
                Label(owned ? "IN YOUR GARAGE" : "LOCKED", systemImage: owned ? "checkmark.circle.fill" : "lock.fill")
            }.font(.system(size: 10, weight: .heavy)).padding(12)
        }.clipShape(RoundedRectangle(cornerRadius: 12))
        .gesture(DragGesture(minimumDistance: 35).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }; move(value.translation.width < 0 ? 1 : -1)
        })
        .accessibilityElement(children: .ignore).accessibilityLabel("\(car.displayName), \(owned ? "owned" : "locked preview")")
        .accessibilityAdjustableAction { direction in move(direction == .increment ? 1 : -1) }
    }
    private var collection: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("THE GARAGE").font(.caption.weight(.heavy)).tracking(1)
                        Spacer()
                        Text("\(progression.save.owned.intersection(Set(ProgressionCatalog.ids)).count) / 28").font(GameType.display(22)).monospacedDigit()
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 16) {
                        ForEach(ProgressionCatalog.cars) { item in collectionTile(item).id(item.id) }
                    }
                }.padding(18).padding(.bottom, 12)
            }.onAppear { reader.scrollTo(selectedID, anchor: .center) }
        }
    }
    private func collectionTile(_ item: CarDefinition) -> some View {
        let isOwned = progression.save.owned.contains(item.id)
        let slot = ProgressionCatalog.slot(item.id) ?? 0
        let next = !isOwned && (slot == 0 || progression.save.owned.contains(ProgressionCatalog.ids[slot-1]))
        return Button {
            selectedID = item.id; tab = .garage
            if isOwned { progression.select(item.id) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    (isOwned ? GaragePalette.neon : next ? GaragePalette.amberTop : GaragePalette.paper.opacity(0.78))
                    CarThumbnail(car: item).frame(height: 115).frame(maxWidth: .infinity).padding(.top, 6)
                    Text(String(format: "%02d", slot + 1)).font(.caption.weight(.black)).foregroundStyle(GaragePalette.midnight.opacity(0.65)).padding(8)
                }.frame(height: 125)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.displayName).font(GameType.display(20)).lineLimit(2).frame(minHeight: 44, alignment: .topLeading)
                    HStack(spacing: 5) {
                        Image(systemName: isOwned ? "checkmark.circle.fill" : "lock.fill")
                        Text(isOwned ? "Owned" : next ? "Up next" : "Locked")
                        Spacer(minLength: 0)
                    }.font(.caption.weight(.bold)).foregroundStyle(isOwned ? GaragePalette.success : next ? GaragePalette.amberTop : GaragePalette.muted)
                    CoinLabel(amount: ProgressionCatalog.prices[slot])
                        .font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
                        .opacity(isOwned ? 0 : 1).accessibilityHidden(isOwned)
                }.padding(12)
            }.background(GaragePalette.indigo).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(next ? GaragePalette.amberTop : .white.opacity(0.12), lineWidth: next ? 2 : 1))
                .compositingGroup().shadow(color: .black.opacity(0.4), radius: 0, y: 4)
        }.buttonStyle(.plain).accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.displayName), \(isOwned ? "owned" : next ? "next to unlock" : "locked"), \(isOwned ? "" : "\(ProgressionCatalog.prices[slot]) coins, ")view car")
    }
    private var footer: some View {
        VStack(spacing: 14) {
            if tab == .garage {
                Button {
                    guard progression.canDrive(car.id) else { sheet = .purchase; return }
                    progression.select(car.id)
                    if settings.usesHaptics { Haptics.placement() }; onPlay(car.id)
                } label: { Label(owned ? "DRIVE" : "VIEW UNLOCK", systemImage: owned ? "flag.checkered" : "lock.open.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(AmberActionStyle()).disabled(!progression.isAvailable).padding(.horizontal, 18)
            }
            HStack(spacing: 0) {
                ForEach(GarageTab.allCases) { item in
                    Button { tab = item } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.icon).font(.system(size: 23, weight: .bold))
                            Text(item.rawValue).font(GameType.display(15, relativeTo: .caption)).lineLimit(1).minimumScaleFactor(0.7).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        }.foregroundStyle(tab == item ? GaragePalette.midnight : GaragePalette.muted)
                            .frame(maxWidth: .infinity, minHeight: 63)
                            .background(tab == item ? GaragePalette.neon : GaragePalette.indigo)
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }.clipShape(RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 12)
        }.padding(.top, 12).padding(.bottom, 8).background(GaragePalette.midnight)
    }
    private func move(_ step: Int) {
        let index = ProgressionCatalog.slot(selectedID) ?? 0
        selectedID = ProgressionCatalog.ids[(index + step + 28) % 28]
        if progression.canDrive(selectedID) { progression.select(selectedID) }
        if settings.usesHaptics { Haptics.selection() }
    }
}
private enum GarageTab: String, CaseIterable, Identifiable {
    case garage = "Garage", missions = "Missions", collection = "Collection"
    var id: String { rawValue }
    var icon: String { switch self { case .garage: "car.side.fill"; case .missions: "flag.checkered"; case .collection: "square.grid.2x2.fill" } }
}
private enum GarageSheet: String, Identifiable { case upgrades, paint, purchase; var id: String { rawValue } }
struct WalletView: View {
    let progression: ProgressionModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            CoinLabel(amount: progression.save.coins).lineLimit(1).minimumScaleFactor(0.65)
            Label("\(progression.save.stars)", systemImage: "star.fill").font(.caption.weight(.heavy)).monospacedDigit().foregroundStyle(GaragePalette.neon)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(progression.save.coins) coins, \(progression.save.stars) career stars")
    }
}
struct StatsOverview: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let car: CarDefinition
    let parts: CarParts
    let unit: SpeedUnit
    var body: some View {
        let tuning = EffectiveTuning.estimate(car: car, parts: parts)
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
        layout {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.0f", SimulationScale.displaySpeed(renderedMetresPerSecond: tuning.topSpeed, unit: unit))).font(GameType.display(30)).monospacedDigit()
                    Text(unit.abbreviation).font(.caption2)
                }
                Text("EST. TOP SPEED").font(.system(size: 8, weight: .heavy)).foregroundStyle(GaragePalette.muted)
            }.frame(minWidth: 90)
            VStack(spacing: 8) {
                ForEach(Array(EffectiveTuning.ratings(tuning).dropFirst().prefix(3)), id: \.0) { name, value in
                    HStack(spacing: 8) {
                        Text(name == "Acceleration" ? "Accel." : name).font(.caption2.weight(.semibold)).frame(width: typeSize.isAccessibilitySize ? 110 : 68, alignment: .leading)
                        GameProgress(value: value / 100)
                    }.accessibilityElement(children: .ignore).accessibilityLabel("\(name), \(Int(value)) of 100")
                }
            }
        }.padding(.vertical, 6)
    }
}
