import Foundation
import Observation
import StoreKit
import SwiftUI

/// The game's three one-time App Store purchases (non-consumable). The raw values are
/// the App Store Connect product IDs: they must match exactly and can never change.
enum PaidUnlock: String, CaseIterable, Identifiable {
    case doubleCoins = "drivear.doublecoins"
    case allCars = "drivear.allcars"
    case maxUpgrades = "drivear.maxupgrades"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .doubleCoins: "Double Coins"
        case .allCars: "All Cars"
        case .maxUpgrades: "Max Upgrades"
        }
    }
    var detail: String {
        switch self {
        case .doubleCoins: "Every coin you earn counts twice, forever."
        case .allCars: "All 28 cars unlocked straight away."
        case .maxUpgrades: "Every part on every car at max level, including cars unlocked later."
        }
    }
}

/// Loads prices, buys, restores, and listens for App Store changes made outside the
/// shop: Ask to Buy approvals, refunds and purchases on another iPhone. Unlocks come
/// only from StoreKit's verified receipts, which iOS keeps on the device, so they
/// work offline and nothing is sent to a server of ours.
@MainActor @Observable
final class PurchaseStore {
    enum Status { case loading, ready, unavailable }

    private(set) var status = Status.loading
    private(set) var prices: [PaidUnlock: String] = [:]
    private(set) var owned: Set<PaidUnlock> = []
    /// The purchase waiting on the App Store sheet, if any.
    private(set) var pending: PaidUnlock?
    private(set) var isRestoring = false
    /// A message for the player: waiting for approval, a failure, or a restore result.
    var notice: String?

    @ObservationIgnored private let progression: ProgressionModel
    @ObservationIgnored private var products: [PaidUnlock: Product] = [:]
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var isFixture = false
    private static let offline = "The App Store isn’t reachable right now. Check your internet connection and try again."

    init(progression: ProgressionModel) { self.progression = progression }

    /// Call once at launch. Returns once owned unlocks are applied, which is local and
    /// quick, so the daily bonus is credited at the right rate. Prices load afterwards.
    func start() async {
        guard listener == nil, !isFixture else { return }
        listener = Task { [weak self] in
            for await update in StoreKit.Transaction.updates { await self?.process(update) }
        }
        await refreshEntitlements()
        Task { await loadProducts() }
    }

    func loadProducts() async {
        guard !isFixture else { return }
        if products.isEmpty { status = .loading }
        if let found = try? await Product.products(for: PaidUnlock.allCases.map(\.rawValue)) {
            for product in found {
                guard let unlock = PaidUnlock(rawValue: product.id) else { continue }
                products[unlock] = product
                prices[unlock] = product.displayPrice
            }
        }
        status = products.isEmpty ? .unavailable : .ready
    }

    /// `action` is SwiftUI's `\.purchase`, which shows Apple's sheet in the right scene.
    func purchase(_ unlock: PaidUnlock, with action: PurchaseAction) async {
        guard pending == nil, !isRestoring, !owned.contains(unlock) else { return }
        pending = unlock
        defer { pending = nil }
        if isFixture {
            try? await Task.sleep(for: .seconds(0.6))
            apply(owned.union([unlock]))
            return
        }
        if products[unlock] == nil { await loadProducts() }
        guard let product = products[unlock] else { notice = Self.offline; return }
        do {
            switch try await action(product) {
            case .success(let result):
                if !(await process(result)) {
                    notice = "The App Store couldn’t confirm this purchase. If you were charged, tap Restore Purchases."
                }
            case .pending:
                notice = "Waiting for approval. \(unlock.title) unlocks as soon as the purchase is approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            notice = "The purchase didn’t go through. Please try again."
        }
    }

    func restore() async {
        guard !isRestoring, pending == nil else { return }
        isRestoring = true
        defer { isRestoring = false }
        if !isFixture {
            do {
                try await AppStore.sync()
            } catch {
                // Cancelling the Apple Account sign-in also lands here.
                if case StoreKitError.userCancelled = error { return }
                notice = Self.offline
                return
            }
        }
        await refreshEntitlements()
        notice = owned.isEmpty ? "No purchases were found for this Apple Account." : "Your purchases have been restored."
    }

    /// Applies one transaction, then finishes it. Returns false if it failed verification.
    @discardableResult private func process(_ result: VerificationResult<StoreKit.Transaction>) async -> Bool {
        guard case .verified(let transaction) = result else { return false }
        if let unlock = PaidUnlock(rawValue: transaction.productID) {
            if transaction.revocationDate == nil {
                apply(owned.union([unlock]))
            } else {
                apply(owned.subtracting([unlock]))
                if unlock == .allCars { progression.revokeAllCars() }
            }
        }
        await transaction.finish()
        return true
    }

    /// Adds every unlock this Apple Account owns. A missing receipt is not a refund:
    /// it can mean another Apple Account or a slow sync. Only an explicitly revoked
    /// All Cars receipt takes the granted cars back.
    private func refreshEntitlements() async {
        var found = Set<PaidUnlock>()
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil,
                  let unlock = PaidUnlock(rawValue: transaction.productID) else { continue }
            found.insert(unlock)
        }
        apply(owned.union(found))
        if !found.contains(.allCars),
           case .verified(let latest)? = await StoreKit.Transaction.latest(for: PaidUnlock.allCars.rawValue),
           latest.revocationDate != nil {
            progression.revokeAllCars()
        }
    }

    private func apply(_ unlocks: Set<PaidUnlock>) {
        if owned != unlocks { owned = unlocks }
        progression.setPaidUnlocks(doubleCoins: unlocks.contains(.doubleCoins),
                                   maxUpgrades: unlocks.contains(.maxUpgrades))
        if unlocks.contains(.allCars) { progression.grantAllCars() }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// UI fixtures only: US prices, no App Store, and purchases that succeed at once.
    static func fixture(progression: ProgressionModel, owned: Set<PaidUnlock> = []) -> PurchaseStore {
        let store = PurchaseStore(progression: progression)
        store.isFixture = true
        store.prices = [.doubleCoins: "$1.99", .allCars: "$4.99", .maxUpgrades: "$4.99"]
        store.status = .ready
        store.apply(owned)
        return store
    }
    #endif
}
