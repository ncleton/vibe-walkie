import Foundation
import Sparkle

enum UpdateRequest {
#if DEBUG
    static let scheme = "vibewalkie-mac-debug"
#else
    static let scheme = "vibewalkie-mac"
#endif
    static let checkForUpdatesHost = "check-for-updates"

    static func requestsImmediateCheck(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame
            && url.host?.caseInsensitiveCompare(checkForUpdatesHost) == .orderedSame
    }
}

enum UpdatePresentationState: Equatable {
    case idle
    case available(version: String)
    case preparing(version: String)
    case ready(version: String)
    case installing(version: String)

    var version: String? {
        switch self {
        case .idle:
            nil
        case let .available(version),
             let .preparing(version),
             let .ready(version),
             let .installing(version):
            version
        }
    }

    var isVisible: Bool { version != nil }

    var isBusy: Bool {
        switch self {
        case .preparing, .installing:
            true
        case .idle, .available, .ready:
            false
        }
    }

}

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var presentationState: UpdatePresentationState = .idle

    private let shouldStartUpdater: Bool
    private var immediateInstallHandler: (() -> Void)?
    private var installRequested = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: shouldStartUpdater,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    override init() {
        // Les tests unitaires hébergés lancent l'exécutable de l'app. Ne pas
        // contacter l'appcast public pendant une suite locale ou une CI. Une
        // copie située dans DerivedData ne doit pas non plus s'auto-mettre à
        // jour : Sparkle remplacerait alors cette copie au lieu de celle qui
        // est installée dans /Applications.
        shouldStartUpdater = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && InstallationLocation.isInstalledApplication
        super.init()

        guard shouldStartUpdater else { return }
        _ = controller
        Task { @MainActor [weak self] in
            // Sparkle autorise explicitement un contrôle silencieux juste
            // après son démarrage. Il alimente le bouton sans ouvrir d'alerte.
            await Task.yield()
            self?.checkForAvailableUpdate()
        }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Action unique du bouton visible dans l'app. Si Sparkle a déjà fini le
    /// téléchargement, l'installation démarre immédiatement. Sinon la demande
    /// reste armée et sera exécutée dès que l'archive est prête.
    func installAvailableUpdate() {
        guard let version = presentationState.version else {
            checkForUpdates()
            return
        }

        installRequested = true
        if immediateInstallHandler != nil {
            performImmediateInstall(version: version)
            return
        }

        presentationState = .preparing(version: version)
        if !controller.updater.sessionInProgress,
           controller.updater.canCheckForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        if immediateInstallHandler != nil {
            presentationState = .ready(version: version)
        } else if installRequested {
            presentationState = .preparing(version: version)
        } else {
            presentationState = .available(version: version)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        immediateInstallHandler = nil
        installRequested = false
        presentationState = .idle
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard let version = presentationState.version else { return }
        immediateInstallHandler = nil
        installRequested = false
        presentationState = .available(version: version)
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        self.immediateInstallHandler = immediateInstallHandler
        let version = item.displayVersionString
        presentationState = .ready(version: version)

        if installRequested {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.performImmediateInstall(version: version)
            }
        }
        return true
    }

    private func checkForAvailableUpdate() {
        guard controller.updater.automaticallyChecksForUpdates,
              !controller.updater.sessionInProgress,
              controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    private func performImmediateInstall(version: String) {
        guard let handler = immediateInstallHandler else { return }
        immediateInstallHandler = nil
        installRequested = false
        presentationState = .installing(version: version)
        handler()
    }
}
