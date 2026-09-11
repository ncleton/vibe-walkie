import StoreKit
import SwiftUI

struct PremiumPaywallView: View {
    @EnvironmentObject private var purchases: PurchaseManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showOfferCode = false

    let canDismiss: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    features

                    if purchases.products.isEmpty, purchases.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else if purchases.products.isEmpty {
                        unavailableProducts
                    } else {
                        VStack(spacing: 12) {
                            ForEach(purchases.products) { product in
                                productButton(product)
                            }
                        }
                    }

                    purchaseActions
                    legalLinks
                }
                .padding(22)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(String(localized: "premium.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canDismiss {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "premium.close")) { dismiss() }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .offerCodeRedemption(isPresented: $showOfferCode) { _ in
            Task { await purchases.refresh() }
        }
        .alert(
            String(localized: "premium.alert.title"),
            isPresented: Binding(
                get: { purchases.errorMessage != nil },
                set: { if !$0 { purchases.errorMessage = nil } }
            )
        ) {
            Button(String(localized: "premium.ok"), role: .cancel) {
                purchases.errorMessage = nil
            }
        } message: {
            Text(purchases.errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(Color.remoteBlue)
            Text("premium.headline")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text("premium.intro")
                .font(.body)
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 12) {
            feature("mic.fill", "premium.feature.dictation")
            feature("hand.tap.fill", "premium.feature.controls")
            feature("rectangle.inset.filled.and.person.filled", "premium.feature.screen")
            feature("figure.walk", "premium.feature.health")
        }
        .padding(18)
        .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(.white)
            .font(.subheadline.weight(.semibold))
    }

    private func productButton(_ product: Product) -> some View {
        Button {
            Task { await purchases.purchase(product) }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName)
                        .font(.headline)
                    Text(productDescription(product))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.64))
                }
                Spacer()
                Text(product.displayPrice)
                    .font(.title3.bold())
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(17)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(product.id == PurchaseManager.yearlyProductID
                          ? Color.remoteBlue
                          : Color.controlSurface)
            )
        }
        .buttonStyle(.plain)
        .disabled(purchases.isLoading)
    }

    private func productDescription(_ product: Product) -> String {
        switch product.id {
        case PurchaseManager.monthlyProductID:
            return String(localized: "premium.plan.monthly.detail")
        case PurchaseManager.yearlyProductID:
            return String(localized: "premium.plan.yearly.detail")
        default:
            return String(localized: "premium.plan.lifetime.detail")
        }
    }

    private var unavailableProducts: some View {
        VStack(spacing: 12) {
            Text("premium.products.unavailable")
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
            Button(String(localized: "premium.retry")) {
                Task { await purchases.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var purchaseActions: some View {
        VStack(spacing: 10) {
            Button(String(localized: "premium.restore")) {
                Task { await purchases.restorePurchases() }
            }
            Button(String(localized: "premium.offer.code")) {
                showOfferCode = true
            }
            Button(String(localized: "premium.manage")) {
                openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
        .disabled(purchases.isLoading)
    }

    private var legalLinks: some View {
        VStack(spacing: 10) {
            Text("premium.renewal.notice")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
            HStack {
                Link(String(localized: "premium.privacy"), destination: URL(string: "https://vibewalkie.app/privacy")!)
                Text("•").foregroundStyle(.secondary)
                Link(String(localized: "premium.terms"), destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PremiumLockedHomeView: View {
    @EnvironmentObject private var client: HostConnectionClient
    @EnvironmentObject private var purchases: PurchaseManager
    @State private var showSettings = false

    var body: some View {
        PremiumPaywallView(canDismiss: false)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
                    .environmentObject(client)
                    .environmentObject(purchases)
            }
    }
}
