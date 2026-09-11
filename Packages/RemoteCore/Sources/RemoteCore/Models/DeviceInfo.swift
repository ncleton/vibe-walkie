import Foundation

public struct VibeWalkieInfo: Sendable {
    // Identifiant réseau historique et invisible. Il doit rester stable entre
    // les mises à jour et les changements de marque : un iPhone récent doit
    // continuer à trouver un ancien compagnon Mac (et inversement).
    public static let bonjourServiceType = "_viberemote._tcp"
    // Identifiants historiques invisibles : la fiche App Store, la signature
    // macOS et le trousseau existant y sont déjà liés. Une marque n'a pas
    // besoin de correspondre au Bundle ID.
    public static let iosBundleIdentifier = "com.nicolascleton.viberemote"
    public static let macBundleIdentifier = "com.nicolascleton.viberemote.mac"
    public static let androidApplicationIdentifier = "com.nicolascleton.vibewalkie"
    public static let windowsPackageIdentity = "VibeWalkie.Companion"
    public static let keychainService = "com.nicolascleton.viberemote"
    public static let dictationLocale = "fr-FR"
    /// Port fixe du compagnon, publié sur le LAN par Bonjour et joignable sur
    /// l'interface privée Tailscale lorsque le Mode Nomade est activé.
    public static let controlPort: UInt16 = 54_389

    /// Durée de vie d'un jeton de cible. Assez long pour une phrase, assez
    /// court pour qu'un jeton oublié ne serve jamais à insérer ailleurs.
    public static let targetTokenLifetime: TimeInterval = 120
    /// Fenêtre du mode appairage sur le Mac.
    public static let pairingWindow: TimeInterval = 120
    /// Durée du QR partagé pour un appairage Nomade avec confirmation Mac.
    public static let nomadPairingWindow: TimeInterval = 600
    /// Une approbation explicite ne doit jamais rester ouverte indéfiniment.
    public static let pairingApprovalWindow: TimeInterval = 60
}

public enum HostPlatform: String, Codable, Sendable, CaseIterable {
    case macOS = "macos"
    case windows
    case linux
}

public enum ClientPlatform: String, Codable, Sendable, CaseIterable {
    case iOS = "ios"
    case android
}

public enum HostCapability: String, Codable, Sendable, CaseIterable {
    case dictationTargeting = "dictation_targeting"
    case keyboard
    case pointer
    case appWindows = "app_windows"
    case screenStreaming = "screen_streaming"
    case customShortcuts = "custom_shortcuts"
    case configurationSync = "configuration_sync"
    case tailscale
    /// Le compagnon accepte les déplacements du caret à cadence écran dans
    /// le budget réseau réservé aux gestes continus.
    case smoothCursorNavigation = "smooth_cursor_navigation"

    /// Socle V4 historiquement annoncé par macOS et Windows. Les capacités
    /// ajoutées après V4 restent opt-in afin qu'un client récent adapte son
    /// débit lorsqu'il parle à un ancien compagnon.
    public static let fullControl: [HostCapability] = [
        .dictationTargeting,
        .keyboard,
        .pointer,
        .appWindows,
        .screenStreaming,
        .customShortcuts,
        .configurationSync,
        .tailscale
    ]
}

/// Point d'accès privé d'un Mac dans un tailnet Tailscale.
///
/// Ce modèle ne contient aucun jeton ni compte Tailscale. Il indique seulement
/// où joindre le même serveur TLS déjà épinglé par l'appairage Vibe Walkie.
public struct NomadEndpoint: Codable, Sendable, Equatable {
    public let magicDNSName: String
    public let ipv4Address: String?
    public let port: UInt16

    public init(
        magicDNSName: String,
        ipv4Address: String? = nil,
        port: UInt16 = VibeWalkieInfo.controlPort
    ) {
        self.magicDNSName = Self.normalizeDNSName(magicDNSName)
        self.ipv4Address = ipv4Address?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
    }

    /// Seuls les noms MagicDNS et les IPv4 CGNAT attribuées par Tailscale sont
    /// acceptés. Le port reste celui du protocole afin qu'un QR ne puisse pas
    /// transformer l'iPhone en client TCP générique.
    public var isValid: Bool {
        guard port == VibeWalkieInfo.controlPort,
              Self.isValidMagicDNSName(magicDNSName) else { return false }
        guard let ipv4Address else { return true }
        return Self.isValidTailscaleIPv4(ipv4Address)
    }

    public static func normalizeDNSName(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix(".") { normalized.removeLast() }
        return normalized
    }

    public static func isValidMagicDNSName(_ value: String) -> Bool {
        let normalized = normalizeDNSName(value)
        guard normalized.hasSuffix(".ts.net"), normalized.count <= 253 else { return false }
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
        }
    }

    public static func isValidTailscaleIPv4(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { UInt8($0) }
        guard components.count == 4, octets.count == 4 else { return false }
        // 100.64.0.0/10, la plage CGNAT utilisée pour les adresses Tailscale.
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}
