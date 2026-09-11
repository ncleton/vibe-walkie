import Foundation
import StoreKit

@MainActor
final class PurchaseManager: ObservableObject {
    static let monthlyProductID = "app.vibewalkie.premium.monthly"
    static let yearlyProductID = "app.vibewalkie.premium.yearly"
    static let lifetimeProductID = "app.vibewalkie.premium.lifetime"
    static let productIDs = [monthlyProductID, yearlyProductID, lifetimeProductID]

    @Published private(set) var products: [Product] = []
    @Published private(set) var hasPremiumAccess = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var transactionListener: Task<Void, Never>?

    init() {
#if OTA_UPDATES
        // Les builds OTA privés ne passent pas par le reçu App Store. Ils sont
        // déjà limités aux appareils enregistrés dans le profil Ad Hoc et ne
        // doivent donc jamais se retrouver bloqués par un paywall StoreKit
        // incapable de charger des produits.
        hasPremiumAccess = true
#else
        transactionListener = observeTransactions()
        Task { await refresh() }
#endif
    }

    deinit {
        transactionListener?.cancel()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            products = try await Product.products(for: Self.productIDs)
                .sorted(by: Self.productSort)
            await refreshEntitlements()
        } catch {
            errorMessage = String(localized: "premium.error.load")
        }
    }

    func purchase(_ product: Product) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.verified(verification)
                await transaction.finish()
                await refreshEntitlements()
            case .pending:
                errorMessage = String(localized: "premium.purchase.pending")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = String(localized: "premium.error.purchase")
        }
    }

    /// Appelée uniquement depuis le bouton explicite « Restaurer les achats ».
    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !hasPremiumAccess {
                errorMessage = String(localized: "premium.restore.none")
            }
        } catch {
            errorMessage = String(localized: "premium.error.restore")
        }
    }

    private func observeTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if let transaction = try? Self.verified(update) {
                    await transaction.finish()
                }
                await self.refreshEntitlements()
            }
        }
    }

    private func refreshEntitlements() async {
        var entitled = false
        for await entitlement in Transaction.currentEntitlements {
            guard let transaction = try? Self.verified(entitlement),
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            entitled = true
            break
        }
        hasPremiumAccess = entitled
    }

    private static func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified: throw PurchaseVerificationError.failed
        }
    }

    private static func productSort(_ lhs: Product, _ rhs: Product) -> Bool {
        let order = [yearlyProductID, monthlyProductID, lifetimeProductID]
        return (order.firstIndex(of: lhs.id) ?? .max) < (order.firstIndex(of: rhs.id) ?? .max)
    }
}

private enum PurchaseVerificationError: Error {
    case failed
}
