#if DEBUG
import SwiftUI

/// Point d'entrée non distribué pour produire des captures exactes des écrans
/// de l'app dans le simulateur. Aucun de ces états n'existe dans l'archive
/// Release : ils servent uniquement aux assets de la landing page.
struct MarketingRootView: View {
    let mode: String
    @ObservedObject var client: HostConnectionClient
    @EnvironmentObject private var health: HealthActivityStore

    var body: some View {
        Group {
            switch mode {
            case "--marketing-home":
                RemoteHomeView(client: client)
            case "--marketing-home-idle", "--marketing-home-delivered":
                RemoteHomeView(client: client)
            case "--marketing-global":
                RemoteHomeView(client: client)
            case "--marketing-apps":
                AppSwitcherView()
                    .environmentObject(client)
            case "--marketing-screen":
                MarketingScreenRoot(client: client)
            case "--marketing-settings":
                MarketingSettingsPreview(client: client)
            case "--marketing-health":
                NavigationStack {
                    HealthDashboardView()
                }
            case "--marketing-controls":
                NavigationStack {
                    ControlConfiguratorView()
                        .environmentObject(client)
                }
            case "--marketing-welcome":
                WelcomeView()
            case "--marketing-macs":
                HostSwitcherView()
                    .environmentObject(client)
            case "--marketing-paywall":
                MarketingPaywallPreview()
            default:
                RemoteHomeView(client: client)
            }
        }
        .task {
            client.configureMarketingPreview()
            if mode == "--marketing-health" {
                health.configureMarketingPreview()
            }
        }
    }
}

/// Capture fidèle du paywall pour App Review. Les produits StoreKit ne sont
/// pas disponibles dans un build simulateur non signé ; seuls leurs trois
/// libellés et prix sont figés ici. Cette vue est exclue des archives Release.
private struct MarketingPaywallPreview: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
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

                    VStack(alignment: .leading, spacing: 12) {
                        feature("mic.fill", "premium.feature.dictation")
                        feature("hand.tap.fill", "premium.feature.controls")
                        feature("rectangle.inset.filled.and.person.filled", "premium.feature.screen")
                        feature("figure.walk", "premium.feature.health")
                    }
                    .padding(18)
                    .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    VStack(spacing: 12) {
                        plan("Premium Yearly", detail: "premium.plan.yearly.detail", price: "€9.99", featured: true)
                        plan("Premium Monthly", detail: "premium.plan.monthly.detail", price: "€2.99")
                        plan("Premium Lifetime", detail: "premium.plan.lifetime.detail", price: "€29.99")
                    }

                    VStack(spacing: 10) {
                        Text("premium.restore")
                        Text("premium.offer.code")
                        Text("premium.manage")
                    }
                    .foregroundStyle(Color.remoteBlue)
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 10) {
                        Text("premium.renewal.notice")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.58))
                            .multilineTextAlignment(.center)
                        HStack {
                            Text("premium.privacy")
                            Text("•").foregroundStyle(.secondary)
                            Text("premium.terms")
                        }
                        .font(.caption)
                        .foregroundStyle(Color.remoteBlue)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(22)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(String(localized: "premium.title"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(.white)
            .font(.subheadline.weight(.semibold))
    }

    private func plan(
        _ name: String,
        detail: LocalizedStringKey,
        price: String,
        featured: Bool = false
    ) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.64))
            }
            Spacer()
            Text(verbatim: price).font(.title3.bold()).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(17)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(featured ? Color.remoteBlue : Color.controlSurface)
        )
    }
}

private struct MarketingScreenRoot: View {
    @StateObject private var dictation: DictationController
    @ObservedObject var client: HostConnectionClient

    init(client: HostConnectionClient) {
        self.client = client
        _dictation = StateObject(wrappedValue: DictationController(client: client))
    }

    var body: some View {
        RemoteScreenView(dictation: dictation)
            .environmentObject(client)
    }
}

private struct MarketingSettingsPreview: View {
    @ObservedObject var client: HostConnectionClient

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("ios.vibe.walkie.111e6dd")
                        .font(.headline)
                    Spacer()
                    Text("ios.ok.565339b")
                        .font(.headline)
                        .frame(width: 48, height: 44)
                        .background(Color.controlSurface, in: Capsule())
                }
                .padding(.leading, 48)
                .padding(.horizontal, 16)
                .padding(.bottom, 18)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        sectionTitle("ios.connection.61d6950")
                        card {
                            row("ios.status.de4dd03", value: "ios.connected.e92b0f9")
                            divider
                            row("ios.current.connection.8cf8ef6", value: "ios.local.8c31e6e", symbol: "wifi", tint: .green)
                        }

                        sectionTitle("ios.trackpad.c8dc586")
                        card {
                            sliderRow("ios.pointer.speed.28fb9b9", value: "1.6×", progress: 0.48, left: "tortoise", right: "hare")
                            divider
                            sliderRow("ios.scroll.speed.addea81", value: "0.8×", progress: 0.36, left: "tortoise", right: "hare")
                        }

                        sectionTitle("ios.controls.0e3118a")
                        card {
                            row("ios.configure.button.panel.a006d38", value: "7 · Global", symbol: "rectangle.3.group", tint: .white)
                        }

                        sectionTitle("ios.screen.view.b5645a8")
                        card {
                            sliderRow("ios.screen.quality.d18a3e1", value: "45 %", progress: 0.45, left: "rectangle", right: "rectangle.inset.filled")
                            divider
                            row("ios.frame.rate.d190183", value: "ios.balanced.10.fps.27a7782")
                        }

                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(.green)
                            Text("ios.screen.view.stays.encrypted.between.iphone.and.mac.and.adapts.5eedf76")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
            }
            .padding(.top, 6)
        }
        .preferredColorScheme(.dark)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(.title3.bold())
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 16)
            .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            )
    }

    private func row(_ title: String, value: String, symbol: String? = nil, tint: Color = .secondary) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
            Spacer()
            if let symbol { Image(systemName: symbol) }
            Text(LocalizedStringKey(value))
        }
        .font(.body)
        .foregroundStyle(tint)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }

    private func sliderRow(_ title: String, value: String, progress: CGFloat, left: String, right: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 12) {
                Image(systemName: left)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12)).frame(height: 5)
                        Capsule().fill(Color.remoteBlue).frame(width: proxy.size.width * progress, height: 5)
                        Circle().fill(.white).frame(width: 22, height: 22)
                            .offset(x: max(0, proxy.size.width * progress - 11))
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 22)
                Image(systemName: right)
            }
        }
        .padding(.vertical, 15)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
    }
}
#endif
