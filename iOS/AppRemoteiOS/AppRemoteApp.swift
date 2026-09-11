import SwiftUI
import RemoteCore
import UIKit
import WidgetKit

/// Supprime les transcriptions créées par les prototypes qui proposaient un
/// historique local. La suppression est répétée sans danger à chaque lancement
/// afin qu'aucune ancienne phrase ne subsiste après la mise à jour.
enum LegacyTranscriptCleanup {
    private static let enabledKey = "com.nicolascleton.viberemote.historyEnabled"

    static func run(defaults: UserDefaults = .standard, fileURL: URL? = nil) {
        defaults.removeObject(forKey: enabledKey)
        let transcriptURL = fileURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("transcripts.json")
        try? FileManager.default.removeItem(at: transcriptURL)
    }
}

/// Every remote surface supports resizing and rotation. The Duo inner display
/// supplies its own geometry; layout must not depend on the physical orientation.
@MainActor
enum AppOrientationPolicy {
    static var supported: UIInterfaceOrientationMask = .allButUpsideDown

    static func setRemoteScreenActive(_ isActive: Bool) {
        supported = .allButUpsideDown

        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: supported))
        }
    }
}

final class VibeWalkieAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationPolicy.supported
    }
}

/// Canal privé de développement. Le symbole `OTA_UPDATES` n'est défini que
/// pour les archives Ad Hoc publiées sur le VPS ; ce code est donc absent des
/// builds TestFlight et App Store.
#if !DEBUG && OTA_UPDATES
@MainActor
private final class OTAUpdateCoordinator: ObservableObject {
    @Published var isUpdateAvailable = false
    private var manifestURL: URL?
    private var isChecking = false

    private struct UpdateResponse: Decodable {
        let hasUpdate: Bool
        let manifestUrl: URL?
    }

    func checkForUpdate() async {
        guard !isChecking, !isUpdateAvailable else { return }
        isChecking = true
        defer { isChecking = false }

        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        guard var components = URLComponents(
            string: "https://app-remote.92.222.247.135.sslip.io/api/releases/ios/check"
        ) else { return }
        components.queryItems = [URLQueryItem(name: "build", value: build)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let update = try? JSONDecoder().decode(UpdateResponse.self, from: data),
              update.hasUpdate,
              let manifestURL = update.manifestUrl else { return }

        self.manifestURL = manifestURL
        isUpdateAvailable = true
    }

    func install() {
        // iOS peut refuser silencieusement `itms-services` lorsqu'il est
        // ouvert directement depuis une app. Safari, lui, est le contexte
        // système prévu pour confirmer une installation OTA. La page stable
        // régénère en plus un manifeste signé frais à chaque affichage.
        guard manifestURL != nil,
              let installPageURL = URL(
                string: "https://app-remote.92.222.247.135.sslip.io/install/ios"
              ) else { return }
        isUpdateAvailable = false
        UIApplication.shared.open(installPageURL)
    }
}
#endif

@main
struct VibeWalkieApp: App {
    @UIApplicationDelegateAdaptor(VibeWalkieAppDelegate.self) private var appDelegate
    @StateObject private var client = HostConnectionClient()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.storageKey) private var appLanguageIdentifier = AppLanguage.systemIdentifier
#if !DEBUG && OTA_UPDATES
    @StateObject private var updater = OTAUpdateCoordinator()
#endif

    init() {
        LegacyTranscriptCleanup.run()
        TrackpadSettings.migrateExpandedSpeedRange()
        AppLanguage.migrate()
        DictationLanguage.migrate()
    }

    var body: some Scene {
        WindowGroup {
            rootContent
                .environmentObject(client)
                .environment(\.locale, AppLanguage.locale(for: appLanguageIdentifier))
                .task {
                    ControlCenter.shared.reloadAllControls()
#if !DEBUG && OTA_UPDATES
                    await updater.checkForUpdate()
#endif
                }
#if !DEBUG && OTA_UPDATES
                .alert("ios.update.available", isPresented: $updater.isUpdateAvailable) {
                    Button("ios.install") { updater.install() }
                    Button("ios.later", role: .cancel) {}
                } message: {
                    Text("ios.the.vibe.walkie.versions.do.not.match.update.the.iphone.c095c26")
                }
#endif
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspend l'application en arrière-plan : la connexion est
            // rétablie au retour au premier plan plutôt que maintenue en vain.
            switch phase {
            case .active:
                // Une mise à jour ou un redémarrage du compagnon peut laisser
                // iOS avec une socket apparemment vivante mais inutilisable.
                // Recréer la connexion au retour au premier plan est rapide et
                // garantit que le bouton Reconnecter n’est jamais nécessaire.
                client.resumeAfterForeground()
#if !DEBUG && OTA_UPDATES
                Task { await updater.checkForUpdate() }
#endif
            case .background: client.disconnect()
            default: break
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
#if DEBUG
        if let mode = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--marketing-") }) {
            MarketingRootView(mode: mode, client: client)
        } else {
            RootView()
        }
#else
        RootView()
#endif
    }
}

private struct RootView: View {
    @EnvironmentObject private var client: HostConnectionClient
    @State private var showDiscovery = false

    var body: some View {
        if client.isPaired {
            RemoteHomeView(client: client)
        } else {
            WelcomeView(showDiscovery: $showDiscovery)
                .fullScreenCover(isPresented: $showDiscovery) { DiscoveryView() }
        }
    }
}

/// Premier lancement : rien d'autre que ce qu'il faut pour se connecter.
private struct WelcomeView: View {
    @EnvironmentObject private var client: HostConnectionClient
    @Binding var showDiscovery: Bool
    @State private var showScanner = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    Text("ios.vibe.walkie.111e6dd")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)

                Spacer()

                VStack(alignment: .leading, spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.controlSurface)
                            .frame(width: 92, height: 92)
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(Color.remoteBlue)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("ios.add.your.mac.ce8ce66")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        Text("ios.control.the.pointer.keyboard.and.dictation.from.this.iphone.no.2d4c813")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.72))

                        Text(verbatim: "vibewalkie.app")
                            .font(.title2.monospaced().weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.remoteBlue.opacity(0.18))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(Color.remoteBlue.opacity(0.55), lineWidth: 1)
                                    )
                            )

                        Label("ios.download.mac.companion.c5e3804", systemImage: "arrow.down.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.remoteBlue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.trackpadSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(.white.opacity(0.07), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 20)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        showScanner = true
                    } label: {
                        Label("ios.add.8d39b2a", systemImage: "plus")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Capsule().fill(Color.remoteBlue))
                    }
                    .buttonStyle(.plain)

                    Button("ios.explore.without.a.mac.8ed8a17") { showDiscovery = true }
                        .font(.subheadline.weight(.semibold))

                    Text("ios.open.vibe.walkie.on.your.mac.then.choose.pair.an.f275c3d")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showScanner) {
            PairingScannerView().environmentObject(client)
        }
    }

}
