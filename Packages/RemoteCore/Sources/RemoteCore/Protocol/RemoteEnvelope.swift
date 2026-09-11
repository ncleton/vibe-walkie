import Foundation

/// Version du protocole. Le Mac refuse une enveloppe dont la version majeure
/// diffère : mieux vaut une erreur explicite qu'une commande mal interprétée
/// par un compagnon plus ancien que l'iPhone.
public enum ProtocolVersion {
    public static let current = 4
}

/// Limites dures du protocole.
///
/// Elles ne sont pas décoratives : le compagnon Mac exécute des événements
/// clavier et souris réels. Une trame arbitrairement grande venant du réseau
/// local est une surface d'attaque, pas un cas limite théorique.
public enum ProtocolLimits {
    /// Taille maximale d'une trame, en-tête de longueur exclu.
    public static let maxFrameBytes = 512 * 1024
    /// Longueur maximale d'un texte inséré en une commande.
    public static let maxTextLength = 32_000
    /// Au-delà, un accusé n'est plus attendu et la commande est réputée perdue.
    public static let acknowledgementTimeout: TimeInterval = 8
}

/// Les types de messages échangés. Liste fermée et exhaustive : le serveur
/// n'accepte jamais un type inconnu, ce qui interdit d'ajouter une commande
/// par le réseau sans mise à jour signée des deux côtés.
public enum RemoteMessageType: String, Codable, Sendable, CaseIterable {
    case hello
    case pairingChallenge = "pairing_challenge"
    case pairingResponse = "pairing_response"
    case pairingPending = "pairing_pending"
    case recordingStarted = "recording_started"
    case insertText = "insert_text"
    case cancel
    case listWindows = "list_windows"
    case windowsSnapshot = "windows_snapshot"
    case activateWindow = "activate_window"
    case keyboardText = "keyboard_text"
    case keyPress = "key_press"
    case voiceControl = "voice_control"
    case hostShortcutPress = "host_shortcut_press"
    case controlConfigurationRequest = "control_configuration_request"
    case controlConfigurationSnapshot = "control_configuration_snapshot"
    case controlConfigurationUpdate = "control_configuration_update"
    case pointerMove = "pointer_move"
    case pointerAbsolute = "pointer_absolute"
    case pointerClick = "pointer_click"
    case pointerDrag = "pointer_drag"
    case scroll
    case screenStreamRequest = "screen_stream_request"
    case screenStreamStatus = "screen_stream_status"
    case screenFrame = "screen_frame"
    case workWalkingSessionsRequest = "work_walking_sessions_request"
    case workWalkingSessionsSnapshot = "work_walking_sessions_snapshot"
    case healthActivitySnapshotUpdate = "health_activity_snapshot_update"
    case acknowledgement
    case connectionStatus = "connection_status"
    case error
}

/// Enveloppe commune à tous les messages.
///
/// `sequence` est strictement croissante par session et `messageID` unique :
/// ensemble ils permettent au Mac de rejeter un rejeu et de dédupliquer une
/// commande renvoyée après une perte d'accusé, sans jamais insérer deux fois
/// la même phrase.
public struct RemoteEnvelope: Codable, Sendable {
    public let version: Int
    public let type: RemoteMessageType
    public let messageID: UUID
    public let replyTo: UUID?
    public let sessionID: String
    public let sequence: UInt64
    public let sentAt: Date
    public let payload: Data

    public init(
        version: Int = ProtocolVersion.current,
        type: RemoteMessageType,
        messageID: UUID = UUID(),
        replyTo: UUID? = nil,
        sessionID: String,
        sequence: UInt64,
        sentAt: Date = Date(),
        payload: Data = Data()
    ) {
        self.version = version
        self.type = type
        self.messageID = messageID
        self.replyTo = replyTo
        self.sessionID = sessionID
        self.sequence = sequence
        self.sentAt = sentAt
        self.payload = payload
    }
}

public extension RemoteEnvelope {
    /// Construit une enveloppe en encodant la charge utile typée.
    static func make<T: Encodable>(
        type: RemoteMessageType,
        sessionID: String,
        sequence: UInt64,
        replyTo: UUID? = nil,
        payload: T
    ) throws -> RemoteEnvelope {
        let data = try RemoteCoding.encoder.encode(payload)
        return RemoteEnvelope(
            type: type,
            replyTo: replyTo,
            sessionID: sessionID,
            sequence: sequence,
            payload: data
        )
    }

    /// Décode la charge utile typée.
    func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        try RemoteCoding.decoder.decode(T.self, from: payload)
    }
}

/// Encodeurs partagés. Les dates sont en ISO 8601 pour rester lisibles dans
/// un diagnostic. Les types inconnus sont refusés par l'énumération fermée.
public enum RemoteCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Un même objet doit toujours produire exactement les mêmes octets.
        // C'est notamment indispensable au QR d'appairage : SwiftUI peut
        // recalculer la vue sans que la matrice du code ne change à l'écran.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
