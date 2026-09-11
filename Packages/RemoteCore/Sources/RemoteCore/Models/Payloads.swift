import Foundation

// MARK: - Poignée de main

public struct HelloPayload: Codable, Sendable {
    public let deviceName: String
    public let deviceIdentifier: String
    public let appVersion: String
    public let protocolVersion: Int
    public let clientPlatform: ClientPlatform

    public init(
        deviceName: String,
        deviceIdentifier: String,
        appVersion: String,
        protocolVersion: Int = ProtocolVersion.current,
        clientPlatform: ClientPlatform = .iOS
    ) {
        self.deviceName = deviceName
        self.deviceIdentifier = deviceIdentifier
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.clientPlatform = clientPlatform
    }
}

/// Défi envoyé par le Mac à chaque connexion.
///
/// Le nonce est régénéré à chaque fois : une signature capturée sur le réseau
/// ne vaut rien à la connexion suivante.
public struct PairingChallengePayload: Codable, Sendable {
    public let nonce: Data
    public let requiresPairingSecret: Bool

    public init(nonce: Data, requiresPairingSecret: Bool) {
        self.nonce = nonce
        self.requiresPairingSecret = requiresPairingSecret
    }
}

public struct PairingResponsePayload: Codable, Sendable {
    public let deviceIdentifier: String
    public let deviceName: String
    public let publicKey: Data
    public let signature: Data
    /// Présent uniquement lors du tout premier appairage, il prouve que
    /// l'utilisateur a physiquement scanné le QR affiché sur le Mac.
    public let pairingSecret: Data?
    public let clientPlatform: ClientPlatform

    public init(
        deviceIdentifier: String,
        deviceName: String,
        publicKey: Data,
        signature: Data,
        pairingSecret: Data?,
        clientPlatform: ClientPlatform = .iOS
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.signature = signature
        self.pairingSecret = pairingSecret
        self.clientPlatform = clientPlatform
    }
}

/// État envoyé immédiatement après la vérification cryptographique d'un nouvel
/// iPhone. Aucune commande n'est acceptée avant le clic humain sur le Mac.
public struct PairingPendingPayload: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let deviceName: String
    public let confirmationCode: String
    public let expiresAt: Date

    public init(requestID: UUID, deviceName: String, confirmationCode: String, expiresAt: Date) {
        self.requestID = requestID
        self.deviceName = deviceName
        self.confirmationCode = confirmationCode
        self.expiresAt = expiresAt
    }
}

// MARK: - Dictée

public struct RecordingStartedPayload: Codable, Sendable {
    public let locale: String
    public let dictationID: UUID

    public init(locale: String, dictationID: UUID) {
        self.locale = locale
        self.dictationID = dictationID
    }
}

/// Cible figée au moment du contact sur le bouton.
///
/// Sans ce jeton, une phrase dictée pendant un changement de fenêtre pourrait
/// atterrir dans une autre application. Le jeton est à usage unique et expire.
public struct TargetToken: Codable, Sendable, Equatable {
    public let token: String
    public let applicationName: String
    public let applicationIdentifier: String?
    public let windowTitle: String?
    public let expiresAt: Date

    public init(
        token: String,
        applicationName: String,
        applicationIdentifier: String?,
        windowTitle: String?,
        expiresAt: Date
    ) {
        self.token = token
        self.applicationName = applicationName
        self.applicationIdentifier = applicationIdentifier
        self.windowTitle = windowTitle
        self.expiresAt = expiresAt
    }

    public init(token: String, applicationName: String, bundleIdentifier: String?, windowTitle: String?, expiresAt: Date) {
        self.init(
            token: token,
            applicationName: applicationName,
            applicationIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            expiresAt: expiresAt
        )
    }

    public var bundleIdentifier: String? { applicationIdentifier }
}

public struct InsertTextPayload: Codable, Sendable {
    public let targetToken: String
    public let text: String
    public let dictationID: UUID

    public init(targetToken: String, text: String, dictationID: UUID) {
        self.targetToken = targetToken
        self.text = text
        self.dictationID = dictationID
    }
}

/// Méthode réellement employée pour écrire le texte.
///
/// Elle remonte jusqu'à l'iPhone parce qu'un collage et une écriture AX n'ont
/// pas les mêmes garanties : le premier peut être avalé par une application
/// qui lit le presse-papiers en retard.
public enum InsertionMethod: String, Codable, Sendable {
    case axSelectedText = "ax_selected_text"
    case axRange = "ax_range"
    case paste
    case keyboardEvents = "keyboard_events"
    case uiAutomation = "ui_automation"
    case unicodeEvents = "unicode_events"
}

public struct InsertionResult: Codable, Sendable {
    public let method: InsertionMethod
    public let verified: Bool
    public let pasteboardRestored: Bool?
    public let applicationName: String

    public init(method: InsertionMethod, verified: Bool, pasteboardRestored: Bool?, applicationName: String) {
        self.method = method
        self.verified = verified
        self.pasteboardRestored = pasteboardRestored
        self.applicationName = applicationName
    }
}

public struct CancelPayload: Codable, Sendable {
    public let dictationID: UUID

    public init(dictationID: UUID) {
        self.dictationID = dictationID
    }
}

// MARK: - Applications et fenêtres

public struct RemoteWindow: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let isMain: Bool
    public let isMinimized: Bool

    public init(id: String, title: String, isMain: Bool, isMinimized: Bool) {
        self.id = id
        self.title = title
        self.isMain = isMain
        self.isMinimized = isMinimized
    }
}

public struct RemoteApplication: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let applicationIdentifier: String?
    public let isActive: Bool
    /// PNG redimensionné côté Mac. Plafonné pour ne jamais saturer le canal
    /// de commande avec une icône de plusieurs mégaoctets.
    public let iconPNG: Data?
    public let windows: [RemoteWindow]

    public init(
        id: String,
        name: String,
        applicationIdentifier: String?,
        isActive: Bool,
        iconPNG: Data?,
        windows: [RemoteWindow]
    ) {
        self.id = id
        self.name = name
        self.applicationIdentifier = applicationIdentifier
        self.isActive = isActive
        self.iconPNG = iconPNG
        self.windows = windows
    }

    public init(id: String, name: String, bundleIdentifier: String?, isActive: Bool, iconPNG: Data?, windows: [RemoteWindow]) {
        self.init(
            id: id,
            name: name,
            applicationIdentifier: bundleIdentifier,
            isActive: isActive,
            iconPNG: iconPNG,
            windows: windows
        )
    }

    public var bundleIdentifier: String? { applicationIdentifier }
}

public struct WindowsSnapshotPayload: Codable, Sendable {
    public let applications: [RemoteApplication]
    public let activeApplicationID: String?
    public let capturedAt: Date

    public init(applications: [RemoteApplication], activeApplicationID: String?, capturedAt: Date = Date()) {
        self.applications = applications
        self.activeApplicationID = activeApplicationID
        self.capturedAt = capturedAt
    }
}

public struct ListWindowsPayload: Codable, Sendable {
    public let includeIcons: Bool

    public init(includeIcons: Bool = true) {
        self.includeIcons = includeIcons
    }
}

public struct ActivateWindowPayload: Codable, Sendable {
    public let applicationID: String
    public let windowID: String?

    public init(applicationID: String, windowID: String?) {
        self.applicationID = applicationID
        self.windowID = windowID
    }
}

// MARK: - Clavier

/// Touches standard configurables depuis l'iPhone. Les combinaisons de
/// keycodes bruts suivent un message distinct et ne peuvent être enregistrées
/// que dans l'interface du compagnon Mac authentifié.
public enum RemoteKey: String, Codable, Sendable, CaseIterable {
    case enter
    case escape
    case tab
    /// Bascule immédiatement vers l'application utilisée précédemment,
    /// comme un appui bref sur Cmd+Tab affecté à un bouton de souris.
    case applicationSwitcher = "application_switcher"
    /// Passe au chat suivant dans ChatGPT, ou à l'onglet suivant dans les
    /// autres applications compatibles comme Claude et Chrome.
    case nextConversation = "next_conversation"
    case backspace
    case delete
    case arrowUp = "arrow_up"
    case arrowDown = "arrow_down"
    case arrowLeft = "arrow_left"
    case arrowRight = "arrow_right"
    case space
    case copy
    case paste
    case cut
}

public struct KeyPressPayload: Codable, Sendable {
    public let key: RemoteKey
    /// Nombre d'appuis identiques à rejouer. Les anciens compagnons ignorent
    /// ce champ et conservent donc un comportement compatible à un appui.
    public let repeatCount: Int

    public init(key: RemoteKey, repeatCount: Int = 1) {
        self.key = key
        self.repeatCount = repeatCount
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case repeatCount = "repeat_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(RemoteKey.self, forKey: .key)
        repeatCount = try container.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        if repeatCount != 1 {
            try container.encode(repeatCount, forKey: .repeatCount)
        }
    }
}

public struct KeyboardTextPayload: Codable, Sendable {
    public let text: String
    /// Vrai quand l'utilisateur a explicitement ouvert le clavier distant.
    /// C'est la seule condition qui autorise la frappe dans un champ sécurisé,
    /// et jamais pour la dictée.
    public let userInitiated: Bool

    public init(text: String, userInitiated: Bool) {
        self.text = text
        self.userInitiated = userInitiated
    }
}

// MARK: - Pointeur

public enum PointerButton: String, Codable, Sendable {
    case left
    case right
}

public struct PointerMovePayload: Codable, Sendable {
    public let deltaX: Double
    public let deltaY: Double

    public init(deltaX: Double, deltaY: Double) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

/// Position dans l'écran diffusé, normalisée entre 0 et 1. Le Mac transforme
/// ces valeurs en coordonnées de son écran principal après les avoir bornées.
public struct PointerAbsolutePayload: Codable, Sendable {
    public let normalizedX: Double
    public let normalizedY: Double

    public init(normalizedX: Double, normalizedY: Double) {
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
    }
}

public struct PointerClickPayload: Codable, Sendable {
    public let button: PointerButton
    public let clickCount: Int

    public init(button: PointerButton, clickCount: Int) {
        self.button = button
        self.clickCount = clickCount
    }
}

public enum DragPhase: String, Codable, Sendable {
    case began
    case moved
    case ended
}

public struct PointerDragPayload: Codable, Sendable {
    public let phase: DragPhase
    public let deltaX: Double
    public let deltaY: Double

    public init(phase: DragPhase, deltaX: Double, deltaY: Double) {
        self.phase = phase
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

public struct ScrollPayload: Codable, Sendable {
    public let deltaX: Double
    public let deltaY: Double
    /// Un pincement est transporté comme une variante rétrocompatible du
    /// défilement. Les anciens compagnons ignorent ce champ optionnel, tandis
    /// que les nouveaux l'injectent avec le modificateur de zoom de l'hôte.
    public let zoom: Bool?

    public init(deltaX: Double, deltaY: Double, zoom: Bool? = nil) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.zoom = zoom
    }
}

// MARK: - Écran distant

public struct ScreenStreamRequestPayload: Codable, Sendable {
    public let enabled: Bool
    public let maxWidth: Int
    public let framesPerSecond: Int
    public let jpegQuality: Double

    public init(enabled: Bool, maxWidth: Int = 1_280, framesPerSecond: Int = 10, jpegQuality: Double = 0.45) {
        self.enabled = enabled
        self.maxWidth = maxWidth
        self.framesPerSecond = framesPerSecond
        self.jpegQuality = jpegQuality
    }
}

public struct ScreenStreamStatusPayload: Codable, Sendable {
    public let isStreaming: Bool
    public let permissionGranted: Bool
    public let detail: String?

    public init(isStreaming: Bool, permissionGranted: Bool, detail: String? = nil) {
        self.isStreaming = isStreaming
        self.permissionGranted = permissionGranted
        self.detail = detail
    }
}

public struct ScreenFramePayload: Codable, Sendable {
    public let jpegData: Data
    public let width: Int
    public let height: Int
    public let capturedAt: Date

    public init(jpegData: Data, width: Int, height: Int, capturedAt: Date = Date()) {
        self.jpegData = jpegData
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
    }
}

// MARK: - Santé et marche pendant le travail

/// Créneau pendant lequel le compagnon Mac a détecté une marche devant la
/// caméra. Le Mac ne prétend pas compter les pas : l'iPhone rapproche ces
/// bornes temporelles des pas agrégés par Apple Santé.
public struct WorkWalkingSession: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let isOngoing: Bool

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        isOngoing: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = max(endedAt, startedAt)
        self.isOngoing = isOngoing
    }

    public var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

public struct WorkWalkingSessionsRequestPayload: Codable, Sendable, Equatable {
    public let since: Date

    public init(since: Date) {
        self.since = since
    }
}

public struct WorkWalkingSessionsSnapshotPayload: Codable, Sendable, Equatable {
    public let sessions: [WorkWalkingSession]
    public let capturedAt: Date

    public init(sessions: [WorkWalkingSession], capturedAt: Date = Date()) {
        self.sessions = sessions
        self.capturedAt = capturedAt
    }
}

/// Résumé Santé calculé sur l'iPhone puis envoyé au compagnon Mac.
///
/// Seuls des agrégats sont transportés : aucun échantillon HealthKit brut,
/// aucune fréquence cardiaque et aucun itinéraire ne quittent l'iPhone.
public struct HealthActivitySnapshotPayload: Codable, Sendable, Equatable {
    /// Minutes que HealthKit classe à une intensité au moins équivalente à une
    /// marche soutenue, limitées aux sessions où l'app est active et connectée.
    /// `nil` signifie que cette mesure n'est pas disponible dans Santé.
    public let briskWalkingMinutesLast7Days: Double?
    public let walkingDistanceMetersLast7Days: Double
    /// Durée des sessions de travail. Le nom historique est conservé sur le
    /// fil pour que les versions déjà distribuées restent compatibles.
    public let detectedWalkingDurationLast7Days: TimeInterval
    public let capturedAt: Date

    public init(
        briskWalkingMinutesLast7Days: Double?,
        walkingDistanceMetersLast7Days: Double,
        detectedWalkingDurationLast7Days: TimeInterval,
        capturedAt: Date = Date()
    ) {
        self.briskWalkingMinutesLast7Days = briskWalkingMinutesLast7Days.map { max(0, $0) }
        self.walkingDistanceMetersLast7Days = max(0, walkingDistanceMetersLast7Days)
        self.detectedWalkingDurationLast7Days = max(0, detectedWalkingDurationLast7Days)
        self.capturedAt = capturedAt
    }
}

// MARK: - Contrôle vocal des applications du Mac

/// Applications dont Vibe Walkie peut actionner les contrôles vocaux visibles.
/// La liste reste fermée : le téléphone ne peut pas fournir un bundle ID ou une
/// commande d'accessibilité arbitraire au compagnon.
public enum VoiceAssistantProvider: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case chatGPT = "chatgpt"
    case claude
}

public enum VoiceControlPhase: String, Codable, Sendable, Equatable {
    case began
    case ended
    case cancelled
}

public struct VoiceControlPayload: Codable, Sendable, Equatable {
    public let provider: VoiceAssistantProvider
    public let phase: VoiceControlPhase

    public init(provider: VoiceAssistantProvider, phase: VoiceControlPhase) {
        self.provider = provider
        self.phase = phase
    }
}

// MARK: - Accusés et erreurs

public struct AcknowledgementPayload: Codable, Sendable {
    public let ok: Bool
    public let targetToken: TargetToken?
    public let insertion: InsertionResult?

    public init(ok: Bool, targetToken: TargetToken? = nil, insertion: InsertionResult? = nil) {
        self.ok = ok
        self.targetToken = targetToken
        self.insertion = insertion
    }
}

public struct ConnectionStatusPayload: Codable, Sendable, Equatable {
    public let inputControlReady: Bool
    public let screenCaptureReady: Bool
    public let hostName: String
    public let hostPlatform: HostPlatform
    public let capabilities: [HostCapability]
    public let companionVersion: String
    public let nomadEndpoint: NomadEndpoint?
    /// `true` uniquement lorsque le compagnon répond après l'injection réelle
    /// d'un déplacement relatif. Optionnel pour rester décodable depuis les
    /// compagnons V4 déjà distribués.
    public let acknowledgesPointerMoves: Bool?

    public init(
        inputControlReady: Bool,
        screenCaptureReady: Bool,
        hostName: String,
        hostPlatform: HostPlatform,
        capabilities: [HostCapability],
        companionVersion: String,
        nomadEndpoint: NomadEndpoint? = nil,
        acknowledgesPointerMoves: Bool? = nil
    ) {
        self.inputControlReady = inputControlReady
        self.screenCaptureReady = screenCaptureReady
        self.hostName = hostName
        self.hostPlatform = hostPlatform
        self.capabilities = Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue }
        self.companionVersion = companionVersion
        self.nomadEndpoint = nomadEndpoint
        self.acknowledgesPointerMoves = acknowledgesPointerMoves
    }

    public init(
        accessibilityGranted: Bool,
        macName: String,
        companionVersion: String,
        nomadEndpoint: NomadEndpoint? = nil
    ) {
        self.init(
            inputControlReady: accessibilityGranted,
            screenCaptureReady: true,
            hostName: macName,
            hostPlatform: .macOS,
            capabilities: HostCapability.fullControl,
            companionVersion: companionVersion,
            nomadEndpoint: nomadEndpoint,
            acknowledgesPointerMoves: nil
        )
    }

    public var accessibilityGranted: Bool { inputControlReady }
    public var macName: String { hostName }
}
