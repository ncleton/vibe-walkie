import Foundation

/// Codes d'erreur stables du protocole.
///
/// Ils sont volontairement lisibles côté iPhone pour afficher une action
/// concrète. Une erreur ne doit jamais être silencieuse : l'utilisateur marche,
/// il ne regarde pas l'écran, et un texte perdu sans message est pire qu'un
/// texte refusé avec une explication.
public enum RemoteErrorCode: String, Codable, Sendable, CaseIterable {
    case versionMismatch = "version_mismatch"
    case unsupportedCapability = "unsupported_capability"
    case inputUnavailable = "input_unavailable"
    case screenUnavailable = "screen_unavailable"
    case secureTarget = "secure_target"
    case targetLost = "target_lost"
    case activationDenied = "activation_denied"
    case permissionAccessibilityDenied = "permission_accessibility_denied"
    case localNetworkDenied = "local_network_denied"
    case macUnavailable = "mac_unavailable"
    case speechAssetMissing = "speech_asset_missing"
    case speechUnavailable = "speech_unavailable"
    case noFocusedTarget = "no_focused_target"
    case targetChanged = "target_changed"
    case targetExpired = "target_expired"
    case secureField = "secure_field"
    case axNotSettable = "ax_not_settable"
    case pasteNotConsumed = "paste_not_consumed"
    case pasteboardChanged = "pasteboard_changed"
    case windowUnavailableOnSpace = "window_unavailable_on_space"
    case applicationNotFound = "application_not_found"
    case peerRevoked = "peer_revoked"
    case notPaired = "not_paired"
    case pairingDenied = "pairing_denied"
    case pairingApprovalExpired = "pairing_approval_expired"
    case protocolMismatch = "protocol_mismatch"
    case replayDetected = "replay_detected"
    case payloadTooLarge = "payload_too_large"
    case rateLimited = "rate_limited"
    case internalFailure = "internal_failure"
    case invalidControlConfiguration = "invalid_control_configuration"

    /// Message français prêt à afficher, orienté action.
    public var localizedMessage: String {
        switch self {
        case .invalidControlConfiguration:
            return "La configuration des commandes est illisible. Réinitialisez les commandes dans les réglages de Vibe Walkie."
        case .versionMismatch:
            return "Les versions de Vibe Walkie diffèrent. Mettez à jour les deux appareils."
        case .unsupportedCapability:
            return "Cette commande n’est pas prise en charge par cet ordinateur."
        case .inputUnavailable:
            return "Le contrôle du clavier et de la souris n’est pas disponible sur cet ordinateur."
        case .screenUnavailable:
            return "La capture d’écran n’est pas disponible sur cet ordinateur."
        case .secureTarget:
            return "Vibe Walkie n’insère jamais de dictée dans un champ sécurisé."
        case .targetLost:
            return "Le champ ciblé n’est plus disponible. Le texte n’a pas été inséré."
        case .activationDenied:
            return "Windows ou macOS a refusé d’activer cette fenêtre."
        case .permissionAccessibilityDenied:
            return "Autorisez le contrôle de l’ordinateur pour Vibe Walkie."
        case .localNetworkDenied:
            return "L'accès au réseau local est refusé."
        case .macUnavailable:
            return "Ordinateur introuvable sur le réseau local. Vérifiez le Wi‑Fi et que le compagnon est ouvert."
        case .speechAssetMissing:
            return "Le modèle français local doit être téléchargé."
        case .speechUnavailable:
            return "La transcription française locale est indisponible sur cet appareil."
        case .noFocusedTarget:
            return "Cliquez d'abord dans un champ de texte sur le Mac."
        case .targetChanged:
            return "La fenêtre a changé pendant la dictée. Le texte n'a pas été inséré."
        case .targetExpired:
            return "La cible a expiré. Recommencez la dictée."
        case .secureField:
            return "Vibe Walkie n'insère jamais de dictée dans un champ sécurisé."
        case .axNotSettable:
            return "Ce champ n'accepte pas l'écriture directe."
        case .pasteNotConsumed:
            return "L'application n'a pas pris en compte le collage."
        case .pasteboardChanged:
            return "Presse-papiers modifié entre-temps : restauration abandonnée."
        case .windowUnavailableOnSpace:
            return "Cette fenêtre est sur un autre bureau. Ouvrez-le une fois sur le Mac."
        case .applicationNotFound:
            return "Cette application n'est plus ouverte."
        case .peerRevoked:
            return "Cet iPhone a été révoqué. Refaites l'appairage."
        case .notPaired:
            return "Appareil non appairé."
        case .pairingDenied:
            return "L'appairage a été refusé sur le Mac."
        case .pairingApprovalExpired:
            return "La demande d'autorisation a expiré. Scannez de nouveau le QR."
        case .protocolMismatch:
            return "Les versions de Vibe Walkie diffèrent. Mettez à jour les deux appareils."
        case .replayDetected:
            return "Message rejeté (rejeu détecté)."
        case .payloadTooLarge:
            return "Message trop volumineux."
        case .rateLimited:
            return "Trop de commandes envoyées, ralentissez."
        case .internalFailure:
            return "Erreur interne du compagnon."
        }
    }
}

public struct RemoteErrorPayload: Codable, Sendable, Error {
    public let code: RemoteErrorCode
    public let detail: String?

    public init(code: RemoteErrorCode, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    public var message: String { code.localizedMessage }
}
