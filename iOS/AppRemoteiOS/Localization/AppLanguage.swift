import Foundation
import RemoteCore
import Speech

/// Langues d'interface embarquées. Les variantes régionales de la dictée
/// restent séparées : un utilisateur peut garder l'interface en anglais tout
/// en choisissant précisément l'anglais australien pour SpeechAnalyzer.
enum AppLanguage {
    static let storageKey = "appLanguage"
    static let systemIdentifier = "system"

    /// Le manifeste gelé de la release est embarqué comme ressource. La liste
    /// de secours ne sert qu'aux tests unitaires sans bundle d'application.
    static var interfaceLocaleIdentifiers: [String] {
        ReleaseLocaleManifest.current?.uiLocales ?? ["en", "fr"]
    }

    static func migrate(defaults: UserDefaults = .standard) {
        switch defaults.string(forKey: storageKey) {
        case "french": defaults.set("fr", forKey: storageKey)
        case "english": defaults.set("en", forKey: storageKey)
        default: break
        }
    }

    static func locale(for identifier: String) -> Locale {
        identifier == systemIdentifier
            ? .autoupdatingCurrent
            : Locale(identifier: identifier)
    }

    static func displayName(for identifier: String, in displayLocale: Locale) -> String {
        displayLocale.localizedString(forIdentifier: identifier)
            ?? Locale(identifier: identifier).localizedString(forIdentifier: identifier)
            ?? identifier
    }
}

private struct ReleaseLocaleManifest: Decodable {
    let uiLocales: [String]

    static let current: ReleaseLocaleManifest? = {
        guard let url = Bundle.main.url(forResource: "locale-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ReleaseLocaleManifest.self, from: data)
    }()
}

struct SpeechLocaleOption: Identifiable, Hashable, Sendable {
    let id: String
    let isInstalled: Bool

    func displayName(in locale: Locale) -> String {
        locale.localizedString(forIdentifier: id) ?? id
    }
}

/// Locale utilisée par SpeechAnalyzer. Apple reste l'unique source de vérité.
enum DictationLanguage {
    static let storageKey = "dictationLanguage"
    static let automaticIdentifier = "automatic"

    static func migrate(defaults: UserDefaults = .standard) {
        switch defaults.string(forKey: storageKey) {
        case "french": defaults.set("fr-FR", forKey: storageKey)
        case "english": defaults.set("en-US", forKey: storageKey)
        default: break
        }
    }

    static var deviceLocaleIdentifier: String {
        Locale.preferredLanguages.first ?? "en-US"
    }
}

@available(iOS 26.0, *)
enum AppleSpeechLocaleCatalog {
    static func options(displayLocale: Locale = .autoupdatingCurrent) async -> [SpeechLocaleOption] {
        let speechSupported = SpeechTranscriber.isAvailable
            ? await SpeechTranscriber.supportedLocales
            : []
        let dictationSupported = await DictationTranscriber.supportedLocales
        let speechInstalled = SpeechTranscriber.isAvailable
            ? await SpeechTranscriber.installedLocales
            : []
        let dictationInstalled = await DictationTranscriber.installedLocales

        let installed = Set((speechInstalled + dictationInstalled).map(canonicalIdentifier))
        let supported = Set((speechSupported + dictationSupported).map(canonicalIdentifier))

        return supported
            .map { SpeechLocaleOption(id: $0, isInstalled: installed.contains($0)) }
            .sorted {
                $0.displayName(in: displayLocale).localizedStandardCompare(
                    $1.displayName(in: displayLocale)
                ) == .orderedAscending
            }
    }

    static func resolvedIdentifier(
        storedIdentifier: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async -> String {
        let identifiers = await options().map(\.id)

        if storedIdentifier != DictationLanguage.automaticIdentifier,
           let exact = identifiers.first(where: {
               canonicalIdentifier(Locale(identifier: $0))
                   == canonicalIdentifier(Locale(identifier: storedIdentifier))
           }) {
            return exact
        }

        for preferred in preferredLanguages {
            let preferredLocale = Locale(identifier: preferred)
            if let exact = identifiers.first(where: {
                canonicalIdentifier(Locale(identifier: $0))
                    == canonicalIdentifier(preferredLocale)
            }) {
                return exact
            }

            let preferredLanguage = preferredLocale.language.languageCode?.identifier
            if let equivalent = identifiers.first(where: {
                Locale(identifier: $0).language.languageCode?.identifier == preferredLanguage
            }) {
                return equivalent
            }
        }

        return identifiers.first(where: { $0 == "en-US" }) ?? identifiers.first ?? "en-US"
    }

    static func canonicalIdentifier(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-")
    }
}

enum AppL10n {
    static func text(_ key: String.LocalizationValue) -> String {
        let identifier = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
            ?? AppLanguage.systemIdentifier
        return String(localized: key, locale: AppLanguage.locale(for: identifier))
    }

    static func format(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
        let identifier = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
            ?? AppLanguage.systemIdentifier
        let locale = AppLanguage.locale(for: identifier)
        return String(format: String(localized: key, locale: locale), locale: locale, arguments: arguments)
    }

    static func remoteError(_ code: RemoteErrorCode) -> String {
        switch code {
        case .invalidControlConfiguration:
            text("ios.workspace.configuration.invalid")
        case .versionMismatch:
            text("ios.the.vibe.walkie.versions.do.not.match.update.the.iphone.c095c26")
        case .unsupportedCapability, .inputUnavailable, .screenUnavailable, .activationDenied:
            code.localizedMessage
        case .secureTarget:
            text("ios.vibe.walkie.never.inserts.dictation.into.a.secure.field.bac6c18")
        case .targetLost:
            text("ios.the.window.changed.during.dictation.the.text.was.not.inserted.21b34b7")
        case .permissionAccessibilityDenied:
            text("ios.allow.accessibility.access.for.vibe.walkie.on.the.mac.e0456ac")
        case .localNetworkDenied:
            text("ios.local.network.access.is.denied.c5bf432")
        case .macUnavailable:
            text("ios.mac.not.found.check.wi.fi.tailscale.and.that.the.1f73825")
        case .speechAssetMissing:
            text("ios.the.on.device.dictation.model.must.be.downloaded.edc4230")
        case .speechUnavailable:
            text("ios.on.device.transcription.is.unavailable.on.this.device.8f2dc9f")
        case .noFocusedTarget:
            text("ios.click.a.text.field.on.the.mac.first.0235759")
        case .targetChanged:
            text("ios.the.window.changed.during.dictation.the.text.was.not.inserted.21b34b7")
        case .targetExpired:
            text("ios.the.target.expired.start.dictation.again.918dd23")
        case .secureField:
            text("ios.vibe.walkie.never.inserts.dictation.into.a.secure.field.bac6c18")
        case .axNotSettable:
            text("ios.this.field.does.not.accept.direct.input.7cf817d")
        case .pasteNotConsumed:
            text("ios.the.app.did.not.apply.the.pasted.text.d62a116")
        case .pasteboardChanged:
            text("ios.the.clipboard.changed.in.the.meantime.so.it.was.not.939ce66")
        case .windowUnavailableOnSpace:
            text("ios.this.window.is.on.another.desktop.open.it.once.on.53b6079")
        case .applicationNotFound:
            text("ios.this.app.is.no.longer.open.cda8a04")
        case .peerRevoked:
            text("ios.this.iphone.was.revoked.pair.it.again.673c52d")
        case .notPaired:
            text("ios.device.not.paired.cbafc67")
        case .pairingDenied:
            text("ios.pairing.was.denied.on.the.mac.98b69bb")
        case .pairingApprovalExpired:
            text("ios.the.approval.request.expired.scan.the.qr.code.again.b612a2a")
        case .protocolMismatch:
            text("ios.the.vibe.walkie.versions.do.not.match.update.the.iphone.c095c26")
        case .replayDetected:
            text("ios.message.rejected.replay.detected.1dd9ad1")
        case .payloadTooLarge:
            text("ios.message.is.too.large.e784f9e")
        case .rateLimited:
            text("ios.too.many.commands.were.sent.slow.down.6850b10")
        case .internalFailure:
            text("ios.internal.mac.companion.error.e6df66d")
        }
    }
}
