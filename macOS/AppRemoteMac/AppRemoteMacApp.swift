import SwiftUI
import AppKit
import Darwin
import RemoteCore

final class ExclusiveProcessLock {
    private var descriptor: Int32 = -1

    @discardableResult
    func acquire(at path: String) -> Bool {
        guard descriptor < 0 else { return true }
        let candidate = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard candidate >= 0 else { return false }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(candidate)
            return false
        }
        descriptor = candidate
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

@MainActor
private final class VibeWalkieAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        RuntimeInstanceCoordinator.reconcileRunningCopies {
            VibeWalkieDependencies.shared.startServicesIfAppropriate()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidLaunchApplication(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        VibeWalkieDependencies.shared.stopServices()
        // Le verrou est volontairement conservé jusqu'à la mort effective du
        // processus. Lors d'une mise à jour Sparkle, la nouvelle copie ne peut
        // ainsi reprendre le port réseau pendant que l'ancienne le ferme encore.
    }

    @objc private func workspaceDidLaunchApplication(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
        RuntimeInstanceCoordinator.handleNewApplication(application)
    }
}

@MainActor
private enum RuntimeInstanceCoordinator {
    private static let knownBundleIdentifiers: Set<String> = [
        "com.nicolascleton.viberemote.mac",
        "com.nicolascleton.viberemote.mac.debug",
        "app.vibewalkie"
    ]
    private static let runtimeLock = ExclusiveProcessLock()
    private static let runtimeLockPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("com.nicolascleton.vibe-walkie.instance.lock")
        .path

    static func reconcileRunningCopies(onReady: @escaping @MainActor () -> Void) {
        guard !isRunningUnitTests else { return }

        let currentIsInstalled = InstallationLocation.isInstalledApplication
        let peers = NSWorkspace.shared.runningApplications.filter(isVibeWalkiePeer)

        if currentIsInstalled {
            // La copie signée de /Applications fait autorité et ferme les
            // hôtes Debug oubliés par Xcode avant qu'ils ne gardent Vision actif.
            for peer in peers where !isInstalled(peer.bundleURL) {
                if !peer.terminate() { _ = peer.forceTerminate() }
            }
            acquireRuntimeLockAfterOtherCopyExits(onReady: onReady)
        } else if peers.contains(where: { isInstalled($0.bundleURL) }) {
            // Une exécution manuelle de DerivedData ne doit jamais doubler le
            // compagnon que Nicolas utilise réellement.
            NSApplication.shared.terminate(nil)
        } else if runtimeLock.acquire(at: runtimeLockPath) {
            onReady()
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    static func handleNewApplication(_ application: NSRunningApplication) {
        guard InstallationLocation.isInstalledApplication,
              isVibeWalkiePeer(application),
              !isInstalled(application.bundleURL) else { return }
        if !application.terminate() { _ = application.forceTerminate() }
    }

    private static func acquireRuntimeLockAfterOtherCopyExits(
        onReady: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor in
            // Un remplacement Sparkle lance la nouvelle app pendant que
            // l'ancienne termine encore ses dernières callbacks. Attendre le
            // verrou avant de démarrer Bonjour/TLS empêche un échec EADDRINUSE.
            for _ in 0..<150 {
                if runtimeLock.acquire(at: runtimeLockPath) {
                    onReady()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Une autre instance détient réellement le verrou : mieux vaut
            // fermer ce processus que laisser deux moteurs réseau/caméra vivre.
            NSApplication.shared.terminate(nil)
        }
    }

    private static func isVibeWalkiePeer(_ application: NSRunningApplication) -> Bool {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let identifier = application.bundleIdentifier,
              knownBundleIdentifiers.contains(identifier),
              let url = application.bundleURL else { return false }
        return url.lastPathComponent == "Vibe Walkie.app"
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static func isInstalled(_ url: URL?) -> Bool {
        guard let path = url?.standardizedFileURL.path else { return false }
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}

/// Dépendances uniques du compagnon.
///
/// SwiftUI peut reconstruire la valeur `App` lorsqu'une `WindowGroup` et un
/// `MenuBarExtra` coexistent. Les conserver ici garantit que les deux scènes
/// partagent le même serveur, la même autorité d'appairage et le même QR.
@MainActor
private final class VibeWalkieDependencies {
    static let shared = VibeWalkieDependencies()

    let peers: ApprovedPeersStore
    let permissions: PermissionCoordinator
    let authority: PairingAuthority
    let server: MacConnectionServer
    let tailscale: TailscaleCoordinator
    let updates: UpdateController
    let postureCoach: PostureCoachController
    let walkingSessions: WorkWalkingSessionStore
    private var servicesStarted = false

    private init() {
        let peers = ApprovedPeersStore()
        let authority = PairingAuthority(peers: peers)
        let tailscale = TailscaleCoordinator()
        let walkingSessions = WorkWalkingSessionStore()
        let server = MacConnectionServer(
            peers: peers,
            authority: authority,
            walkingSessions: walkingSessions,
            nomadEndpoint: NomadFeatureFlag.isEnabled ? tailscale.activeEndpoint : nil
        )

        let postureCoach = PostureCoachController(walkingSessions: walkingSessions)

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--marketing-health") {
            walkingSessions.configureMarketingPreview()
            server.configureMarketingHealthPreview()
            postureCoach.showHealthDashboard()
        }
#endif

        self.peers = peers
        self.permissions = PermissionCoordinator()
        self.authority = authority
        self.server = server
        self.tailscale = tailscale
        self.updates = UpdateController()
        self.walkingSessions = walkingSessions
        self.postureCoach = postureCoach
    }

    func startServicesIfAppropriate() {
        guard InstallationLocation.isSuitable, !servicesStarted else { return }
        servicesStarted = true
        server.start()
    }

    func stopServices() {
        guard servicesStarted else { return }
        postureCoach.stop()
        server.stop()
        servicesStarted = false
    }
}

@main
struct VibeWalkieMacApp: App {
    @NSApplicationDelegateAdaptor(VibeWalkieAppDelegate.self) private var appDelegate
    private let dependencies = VibeWalkieDependencies.shared

    var body: some Scene {
        WindowGroup("mac.vibe.walkie.111e6dd", id: "control-panel") {
            controlPanel
                .frame(minWidth: 340, idealWidth: 340, minHeight: 420, maxHeight: .infinity, alignment: .top)
        }
        .defaultSize(width: 340, height: 520)

        Window("Module Santé", id: "posture-coach") {
            PostureCoachView()
                .environmentObject(dependencies.postureCoach)
                .environmentObject(dependencies.walkingSessions)
                .environmentObject(dependencies.server)
        }
        .defaultSize(width: 960, height: 720)
        .windowResizability(.contentMinSize)

        // Let macOS own the status item's metrics and click target. Feeding the
        // 1024 px application icon to a custom label gives it an oversized
        // intrinsic size and bypasses the native template rendering used by
        // regular menu bar utilities.
        MenuBarExtra {
            controlPanel
        } label: {
            PostureMenuBarLabel(controller: dependencies.postureCoach)
        }
        .menuBarExtraStyle(.window)
    }

    private var controlPanel: some View {
        Group {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--marketing-health") {
                PostureCoachView()
                    .environmentObject(dependencies.server)
                    .environmentObject(dependencies.postureCoach)
                    .environmentObject(dependencies.walkingSessions)
            } else {
                menuBarView
            }
#else
            menuBarView
#endif
        }
    }

    private var menuBarView: some View {
        MenuBarView()
            .environmentObject(dependencies.server)
            .environmentObject(dependencies.permissions)
            .environmentObject(dependencies.authority)
            .environmentObject(dependencies.peers)
            .environmentObject(dependencies.tailscale)
            .environmentObject(dependencies.updates)
            .environmentObject(dependencies.postureCoach)
            .environmentObject(dependencies.walkingSessions)
            .onOpenURL { url in
                guard UpdateRequest.requestsImmediateCheck(url) else { return }
                NSApplication.shared.activate(ignoringOtherApps: true)
                dependencies.updates.checkForUpdates()
            }
    }
}

private struct PostureMenuBarLabel: View {
    @ObservedObject var controller: PostureCoachController

    var body: some View {
        Image(systemName: icon)
            .symbolRenderingMode(.palette)
            .foregroundStyle(tint, Color.primary)
            .accessibilityLabel(accessibilityLabel)
    }

    private var icon: String {
        switch controller.evaluation.severity {
        case .correction, .warning: "exclamationmark.triangle.fill"
        case .good, .unavailable: "iphone.radiowaves.left.and.right"
        }
    }

    private var tint: Color {
        switch controller.evaluation.severity {
        case .correction, .warning: .red
        case .good, .unavailable: .primary
        }
    }

    private var accessibilityLabel: String {
        controller.evaluation.severity >= .warning
            ? "Vibe Walkie · mauvaise posture détectée"
            : "Vibe Walkie"
    }
}
