import SwiftUI
import StoreKit

enum StoreLinks {
    static let terms = URL(string: "https://ak375456.github.io/ar-ios-game-privacy-policy/terms-of-service.html")!
    static let privacy = URL(string: "https://ak375456.github.io/ar-ios-game-privacy-policy/privacy-policy.html")!
}

/// The garage's shop: the three one-time unlocks and Restore Purchases.
struct ShopSheet: View {
    let store: PurchaseStore
    let progression: ProgressionModel
    let settings: ControlSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            GameSheetHeader(title: "Shop", close: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PAY ONCE, KEEP FOREVER").font(.caption2.weight(.heavy)).tracking(1).foregroundStyle(GaragePalette.neon)
                        Text("One-time purchases. No ads and no subscriptions.").font(.subheadline).foregroundStyle(GaragePalette.muted)
                    }
                    ForEach(PaidUnlock.allCases) { unlock in
                        PaidUnlockCard(unlock: unlock, store: store, progression: progression, haptics: settings.usesHaptics)
                    }
                    if store.status == .unavailable { unavailable }
                    Button { Task { await store.restore() } } label: {
                        HStack(spacing: 8) {
                            if store.isRestoring { ProgressView().tint(GaragePalette.paper) } else { Image(systemName: "arrow.clockwise") }
                            Text("Restore Purchases")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GameButtonStyle(compact: true))
                    .disabled(store.isRestoring || store.pending != nil)
                    .padding(.top, 6)
                    Text("Purchases are charged to your Apple Account. Restore brings them back on any iPhone signed in to the same account.")
                        .font(.caption).foregroundStyle(GaragePalette.muted)
                    HStack(spacing: 18) {
                        Link("Terms of Service", destination: StoreLinks.terms)
                        Link("Privacy Policy", destination: StoreLinks.privacy)
                    }.font(.caption.weight(.bold)).foregroundStyle(GaragePalette.neon)
                }.padding(20)
            }
        }
        .foregroundStyle(GaragePalette.paper).background(GaragePalette.midnight)
        .storeNotice(store)
        .task { if store.status == .unavailable { await store.loadProducts() } }
    }

    private var unavailable: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(GaragePalette.amberTop)
            VStack(alignment: .leading, spacing: 8) {
                Text("Prices couldn’t load. Check your internet connection.").font(.subheadline.weight(.semibold))
                Button("Try again") { Task { await store.loadProducts() } }
                    .font(.subheadline.weight(.heavy)).foregroundStyle(GaragePalette.neon)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(GaragePalette.deepIndigo, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One unlock: what it does, then its price or "Owned". Used in the shop and, where
/// it helps, in the Workshop and the locked-car sheet.
struct PaidUnlockCard: View {
    let unlock: PaidUnlock
    let store: PurchaseStore
    let progression: ProgressionModel
    var haptics = true
    @Environment(\.purchase) private var purchase
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Owning all 28 cars through play makes All Cars pointless, so it is never sold then.
    private var isOwned: Bool { store.owned.contains(unlock) || (unlock == .allCars && progression.ownsEveryCar) }

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(alignment: .top, spacing: 14) {
                badge
                VStack(alignment: .leading, spacing: 3) {
                    Text(unlock.title).font(GameType.display(22))
                    Text(unlock.detail).font(.subheadline).foregroundStyle(GaragePalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(14)
        .background(GaragePalette.indigo, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .compositingGroup().shadow(color: .black.opacity(0.4), radius: 0, y: 4)
    }

    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(isOwned ? GaragePalette.success : GaragePalette.amberTop)
            switch unlock {
            case .doubleCoins: Text("×2").font(GameType.display(25))
            case .allCars: Image(systemName: "car.2.fill").font(.system(size: 20, weight: .heavy))
            case .maxUpgrades: Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 21, weight: .heavy))
            }
        }
        .foregroundStyle(GaragePalette.midnight).frame(width: 52, height: 52).accessibilityHidden(true)
    }

    @ViewBuilder private var action: some View {
        if isOwned {
            Label("Owned", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.heavy)).foregroundStyle(GaragePalette.success)
                .frame(minHeight: 44)
        } else {
            Button {
                Task {
                    await store.purchase(unlock, with: purchase)
                    if haptics && store.owned.contains(unlock) { Haptics.success() }
                }
            } label: {
                ZStack {
                    // The price keeps the button's width while the spinner shows.
                    Text(store.prices[unlock] ?? "$0.00").monospacedDigit()
                        .opacity(store.prices[unlock] == nil || store.pending == unlock ? 0 : 1)
                    if store.pending == unlock || (store.prices[unlock] == nil && store.status == .loading) {
                        ProgressView().tint(GaragePalette.midnight)
                    } else if store.prices[unlock] == nil {
                        Text("—")
                    }
                }
            }
            .buttonStyle(GameButtonStyle(color: GaragePalette.amberTop, ink: GaragePalette.midnight, compact: true))
            .disabled(store.prices[unlock] == nil || store.pending != nil || store.isRestoring)
            .accessibilityLabel("Buy \(unlock.title)")
            .accessibilityValue(store.prices[unlock] ?? "Price unavailable")
        }
    }
}

extension View {
    /// Shows the store's waiting, failure and restore messages from the sheet in front.
    func storeNotice(_ store: PurchaseStore) -> some View {
        alert("Shop", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK") { store.notice = nil }
        } message: {
            Text(store.notice ?? "")
        }
    }
}
