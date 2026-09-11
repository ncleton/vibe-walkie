import Foundation
import Network
import AppKit
import CoreGraphics
import RemoteCore

/// Serveur local : publication Bonjour, TLS, authentification, routage des
/// commandes et diffusion bornée de l'écran.
@MainActor
final class MacConnectionServer: ObservableObject {

    @Published private(set) var isListening = false
    @Published private(set) var connectedPeerName: String?
    @Published private(set) var lastError: String?
    @Published private(set) var serviceName: String = ""
    @Published private(set) var nomadEndpoint: NomadEndpoint?
    @Published private(set) var hasCompletedFirstCommand: Bool
    @Published private(set) var controlConfiguration: ControlConfiguration
    @Published private(set) var healthActivitySnapshot: HealthActivitySnapshotPayload?

    private var listener: NWListener?
    private var identity: SecIdentity?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private let screenCapture = ScreenCaptureService()
    private var screenCaptureRunning = false
    private var screenCaptureStarting = false
    private var connectionLimiter = RateLimiter(capacity: 20, refillPerSecond: 1.0 / 3.0)
    private var crossSessionResponses = PeerResponseCache()

    private let peers: ApprovedPeersStore
    private let authority: PairingAuthority
    private let shortcutStore: HostShortcutStore
    private let walkingSessions: WorkWalkingSessionStore

    /// Une connexion en cours de vie, avec son état d'authentification.
    ///
    /// Isolée sur le main actor comme le serveur : tout le traitement réseau
    /// est séquentiel ici, ce qui évite d'avoir à raisonner sur des accès
    /// concurrents à l'état d'authentification.
    @MainActor
    private final class Session {
        let connection: NWConnection
        var framer = MessageFramer()
        var nonce: Data
        var router: SessionRouter?
        var sequence: UInt64 = 0
        var wantsScreen = false
        var screenRequest: ScreenStreamRequestPayload?
        var screenFrameInFlight = false
        var pendingApprovalID: UUID?
        var pendingApprovalReplyTo: UUID?
        var approvalExpiryTask: Task<Void, Never>?
        var authenticationExpiryTask: Task<Void, Never>?
        let sessionID = UUID().uuidString

        init(connection: NWConnection) {
            self.connection = connection
            self.nonce = SecureRandom.bytes(32)
        }

        var isAuthenticated: Bool { router != nil }
    }

    init(
        peers: ApprovedPeersStore,
        authority: PairingAuthority,
        walkingSessions: WorkWalkingSessionStore,
        nomadEndpoint: NomadEndpoint? = nil
    ) {
        self.peers = peers
        self.authority = authority
        self.walkingSessions = walkingSessions
        let shortcutStore = HostShortcutStore()
        self.shortcutStore = shortcutStore
        self.nomadEndpoint = nomadEndpoint?.isValid == true ? nomadEndpoint : nil
        self.hasCompletedFirstCommand = UserDefaults.standard.bool(forKey: "hasCompletedFirstCommand")
        self.controlConfiguration = shortcutStore.migrate(Self.loadControlConfiguration())
        self.healthActivitySnapshot = nil
    }

    var certificateFingerprint: String? {
        guard let identity else { return nil }
        return try? TLSIdentityStore.fingerprint(of: identity)
    }

#if DEBUG
    /// Résumé déterministe réservé aux captures marketing du dashboard Santé.
    func configureMarketingHealthPreview(now: Date = Date()) {
        healthActivitySnapshot = HealthActivitySnapshotPayload(
            briskWalkingMinutesLast7Days: 472,
            walkingDistanceMetersLast7Days: 24_680,
            detectedWalkingDurationLast7Days: 9 * 3_600 + 18 * 60,
            capturedAt: now
        )
    }
#endif

    // MARK: - Cycle de vie

    func start() {
        guard listener == nil else { return }
        do {
            let identity = try TLSIdentityStore.loadOrCreate()
            self.identity = identity

            let parameters = try makeParameters(identity: identity)
            guard let port = NWEndpoint.Port(rawValue: VibeWalkieInfo.controlPort) else {
                throw RemoteErrorPayload(code: .internalFailure, detail: "port invalide")
            }
            let listener = try NWListener(using: parameters, on: port)

            // Le nom historique basé uniquement sur le Mac pouvait rester
            // réservé par une ancienne installation Bonjour et faire échouer
            // la nouvelle publication avec EADDRINUSE. Le certificat est
            // propre à cette installation : son préfixe donne un nom stable,
            // unique et dépourvu de donnée personnelle supplémentaire.
            let fingerprint = try TLSIdentityStore.fingerprint(of: identity)
            let suffix = String(fingerprint.filter { $0.isLetter || $0.isNumber }.prefix(8))
            let host = String((Host.current().localizedName ?? "Mac").prefix(30))
            // Le nom Bonjour est également un identifiant technique durable.
            // Conserver le préfixe historique évite de casser les iPhone déjà
            // appairés lors d'une simple mise à jour ou d'un renommage produit.
            let name = "VibeRemote-\(host)-\(suffix)"
            listener.service = NWListener.Service(name: name, type: VibeWalkieInfo.bonjourServiceType)
            self.serviceName = name

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = "Impossible de démarrer le service : \(error.localizedDescription)"
        }
    }

    /// Répare une identité TLS partielle ou corrompue. Une nouvelle empreinte
    /// invalide nécessairement tous les appareils précédemment appairés.
    func regenerateTLSIdentity() {
        stop()
        do {
            _ = try TLSIdentityStore.regenerate()
            peers.revokeAll()
            crossSessionResponses.removeAll()
            lastError = nil
            start()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resetEverything() {
        authority.cancelPendingApproval()
        peers.revokeAll()
        regenerateTLSIdentity()
        UserDefaults.standard.set(false, forKey: "hasCompletedFirstCommand")
        hasCompletedFirstCommand = false
    }

    func stop() {
        sessions.values.forEach {
            $0.approvalExpiryTask?.cancel()
            $0.authenticationExpiryTask?.cancel()
            $0.connection.cancel()
        }
        sessions.removeAll()
        listener?.cancel()
        listener = nil
        isListening = false
        connectedPeerName = nil
        screenCaptureRunning = false
        screenCaptureStarting = false
        Task { await screenCapture.stop() }
    }

    /// Ferme immédiatement les sessions d'un appareil révoqué.
    func disconnectPeer(_ peerID: String) {
        crossSessionResponses.removeAll(for: peerID)
        for (key, session) in sessions where session.router?.peerID == peerID {
            session.connection.cancel()
            sessions.removeValue(forKey: key)
        }
        if sessions.isEmpty { connectedPeerName = nil }
        stopScreenCaptureWhenUnused()
    }

    private func makeParameters(identity: SecIdentity) throws -> NWParameters {
        let options = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else {
            throw RemoteErrorPayload(code: .internalFailure, detail: "identité TLS invalide")
        }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: options, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            lastError = nil
        case .failed(let error):
            isListening = false
            lastError = error.localizedDescription
        case .cancelled:
            isListening = false
        default:
            break
        }
    }

    // MARK: - Connexions

    private func accept(_ connection: NWConnection) {
        let unauthenticatedCount = sessions.values.filter { !$0.isAuthenticated }.count
        guard unauthenticatedCount < 8, connectionLimiter.allow() else {
            connection.cancel()
            return
        }
        let session = Session(connection: connection)
        sessions[ObjectIdentifier(connection)] = session
        session.authenticationExpiryTask = Task { [weak connection] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            connection?.cancel()
        }

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendChallenge(session)
                case .failed, .cancelled:
                    session.approvalExpiryTask?.cancel()
                    session.authenticationExpiryTask?.cancel()
                    if let requestID = session.pendingApprovalID {
                        _ = self.authority.cancelPendingApproval(requestID)
                    }
                    self.sessions.removeValue(forKey: ObjectIdentifier(connection))
                    if self.sessions.isEmpty { self.connectedPeerName = nil }
                    self.stopScreenCaptureWhenUnused()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive(session)
    }

    private func receive(_ session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.ingest(data, into: session)
                }
                if isComplete || error != nil {
                    session.connection.cancel()
                    return
                }
                self.receive(session)
            }
        }
    }

    private func ingest(_ data: Data, into session: Session) {
        let messages: [Data]
        do {
            messages = try session.framer.append(data)
        } catch {
            // Trame invalide ou surdimensionnée : on coupe, sans négocier.
            session.connection.cancel()
            return
        }

        for message in messages {
            guard let envelope = try? RemoteCoding.decoder.decode(RemoteEnvelope.self, from: message) else {
                session.connection.cancel()
                return
            }
            process(envelope, in: session)
        }
    }

    private func process(_ envelope: RemoteEnvelope, in session: Session) {
        guard envelope.version == ProtocolVersion.current else {
            sendAndClose(
                error: RemoteErrorPayload(code: .versionMismatch),
                to: session,
                replyTo: envelope.messageID
            )
            return
        }
        guard session.isAuthenticated else {
            // Avant authentification, un seul type de message est recevable.
            guard envelope.type == .pairingResponse,
                  let payload = try? envelope.decodePayload(PairingResponsePayload.self) else {
                sendAndClose(
                    error: RemoteErrorPayload(code: .notPaired),
                    to: session,
                    replyTo: envelope.messageID
                )
                return
            }
            do {
                switch try authority.authenticate(response: payload, nonce: session.nonce) {
                case .approved(let peer):
                    establishAuthenticatedSession(session, peer: peer, replyTo: envelope.messageID)
                case .requiresApproval(let pending):
                    session.pendingApprovalID = pending.id
                    session.pendingApprovalReplyTo = envelope.messageID
                    send(
                        type: .pairingPending,
                        payload: PairingPendingPayload(
                            requestID: pending.id,
                            deviceName: pending.peer.name,
                            confirmationCode: pending.confirmationCode,
                            expiresAt: pending.expiresAt
                        ),
                        to: session,
                        replyTo: envelope.messageID
                    )
                    session.approvalExpiryTask = Task { [weak self, weak session] in
                        try? await Task.sleep(for: .seconds(VibeWalkieInfo.pairingApprovalWindow))
                        guard !Task.isCancelled, let self, let session else { return }
                        await MainActor.run { self.expirePairing(pending.id, in: session) }
                    }
                }
            } catch let error as RemoteErrorPayload {
                sendAndClose(error: error, to: session, replyTo: envelope.messageID)
            } catch {
                session.connection.cancel()
            }
            return
        }

        guard let router = session.router else { return }
        if isCrossSessionIdempotent(envelope.type),
           let previous = crossSessionResponses.response(
               for: router.peerID,
               messageID: envelope.messageID
           ) {
            sendEncoded(
                type: previous.type,
                payload: previous.payload,
                to: session,
                replyTo: envelope.messageID
            )
            return
        }
        switch router.handle(envelope) {
        case .acknowledge(let payload):
            if payload.ok && ![.hello, .recordingStarted, .cancel].contains(envelope.type) {
                markFirstCommandCompleted()
            }
            sendResponse(
                type: .acknowledgement,
                payload: payload,
                for: envelope,
                peerID: router.peerID,
                to: session
            )
        case .gestureAcknowledged:
            // Ce retour est le vrai mécanisme de pression réseau du pointeur :
            // l'iPhone n'envoie le prochain delta agrégé qu'après réception.
            // Il n'est pas conservé entre les sessions, contrairement aux
            // commandes qui peuvent être rejouées après une reconnexion.
            send(
                type: .acknowledgement,
                payload: AcknowledgementPayload(ok: true),
                to: session,
                replyTo: envelope.messageID
            )
        case .snapshot(let payload):
            send(type: .windowsSnapshot, payload: payload, to: session, replyTo: envelope.messageID)
        case .screenRequest(let payload):
            handleScreenRequest(payload, for: session, replyTo: envelope.messageID)
        case .controlConfigurationRequest:
            sendControlConfiguration(to: session, replyTo: envelope.messageID)
        case .controlConfigurationUpdate(let configuration):
            updateControlConfigurationFromPeer(configuration)
            sendResponse(
                type: .acknowledgement,
                payload: AcknowledgementPayload(ok: true),
                for: envelope,
                peerID: router.peerID,
                to: session
            )
        case .workWalkingSessionsRequest(let since):
            send(
                type: .workWalkingSessionsSnapshot,
                payload: walkingSessions.snapshot(since: since),
                to: session,
                replyTo: envelope.messageID
            )
        case .healthActivitySnapshotUpdate(let payload):
            healthActivitySnapshot = payload
            sendResponse(
                type: .acknowledgement,
                payload: AcknowledgementPayload(ok: true),
                for: envelope,
                peerID: router.peerID,
                to: session
            )
        case .hostShortcutPress(let shortcutID):
            let configuredActions = controlConfiguration.buttons.map(\.action) +
                controlConfiguration.globalButtons.map(\.action)
            let isConfigured = configuredActions.contains { action in
                guard case .hostShortcut(let configured) = action else { return false }
                return configured.id == shortcutID
            }
            guard isConfigured,
                  let shortcut = shortcutStore.definition(for: shortcutID),
                  shortcut.platform == .macOS,
                  shortcut.keyCode <= 127 else {
                sendResponse(
                    error: RemoteErrorPayload(code: .unsupportedCapability, detail: "Raccourci non configuré"),
                    for: envelope,
                    peerID: router.peerID,
                    to: session
                )
                break
            }
            CGEventFactory.press(MacKeyboardShortcut(
                keyCode: UInt16(shortcut.keyCode),
                modifiers: shortcut.modifiers,
                displayName: shortcut.displayName
            ))
            sendResponse(
                type: .acknowledgement,
                payload: AcknowledgementPayload(ok: true),
                for: envelope,
                peerID: router.peerID,
                to: session
            )
        case .voiceControl(let payload):
            NSLog(
                "[VibeWalkie] voice_control_received provider=%@ phase=%@",
                payload.provider.rawValue,
                payload.phase.rawValue
            )
            AIVoiceModeAutomation.handle(payload)
            sendResponse(
                type: .acknowledgement,
                payload: AcknowledgementPayload(ok: true),
                for: envelope,
                peerID: router.peerID,
                to: session
            )
        case .failure(let error):
            sendResponse(error: error, for: envelope, peerID: router.peerID, to: session)
        case .ignore:
            break
        }
    }

    private func markFirstCommandCompleted() {
        guard !hasCompletedFirstCommand else { return }
        hasCompletedFirstCommand = true
        UserDefaults.standard.set(true, forKey: "hasCompletedFirstCommand")
    }

    /// Les commandes qui fabriquent ou restituent un état propre à une socket
    /// repartent volontairement à zéro à la reconnexion. Toutes les autres
    /// réponses sont rejouées au lieu d'exécuter à nouveau une frappe, une
    /// insertion ou un raccourci dont l'accusé a été perdu.
    private func isCrossSessionIdempotent(_ type: RemoteMessageType) -> Bool {
        ![
            .hello,
            .recordingStarted,
            .listWindows,
            .screenStreamRequest,
            .controlConfigurationRequest,
            .workWalkingSessionsRequest
        ].contains(type)
    }

    func approvePairing(_ requestID: UUID) {
        guard let session = sessions.values.first(where: { $0.pendingApprovalID == requestID }),
              let peer = authority.approve(requestID) else {
            if let session = sessions.values.first(where: { $0.pendingApprovalID == requestID }) {
                expirePairing(requestID, in: session)
            }
            return
        }
        session.approvalExpiryTask?.cancel()
        let replyTo = session.pendingApprovalReplyTo
        session.pendingApprovalID = nil
        session.pendingApprovalReplyTo = nil
        establishAuthenticatedSession(session, peer: peer, replyTo: replyTo)
    }

    func denyPairing(_ requestID: UUID) {
        guard let session = sessions.values.first(where: { $0.pendingApprovalID == requestID }) else { return }
        session.approvalExpiryTask?.cancel()
        _ = authority.cancelPendingApproval(requestID)
        sendAndClose(
            error: RemoteErrorPayload(code: .pairingDenied),
            to: session,
            replyTo: session.pendingApprovalReplyTo
        )
    }

    private func expirePairing(_ requestID: UUID, in session: Session) {
        guard session.pendingApprovalID == requestID else { return }
        _ = authority.cancelPendingApproval(requestID)
        sendAndClose(
            error: RemoteErrorPayload(code: .pairingApprovalExpired),
            to: session,
            replyTo: session.pendingApprovalReplyTo
        )
    }

    private func establishAuthenticatedSession(_ session: Session, peer: ApprovedPeer, replyTo: UUID?) {
        session.authenticationExpiryTask?.cancel()
        session.authenticationExpiryTask = nil
        session.router = SessionRouter(peerID: peer.id, sessionID: session.sessionID)
        connectedPeerName = peer.name
        sendConnectionStatus(to: session, replyTo: replyTo)
        sendControlConfiguration(to: session, replyTo: nil)
    }

    func setNomadEndpoint(_ endpoint: NomadEndpoint?) {
        nomadEndpoint = endpoint?.isValid == true ? endpoint : nil
        for session in sessions.values where session.isAuthenticated {
            sendConnectionStatus(to: session, replyTo: nil)
        }
    }

    private func sendConnectionStatus(to session: Session, replyTo: UUID?) {
        send(
            type: .connectionStatus,
            payload: ConnectionStatusPayload(
                inputControlReady: AccessibilityClient.isTrusted,
                screenCaptureReady: CGPreflightScreenCaptureAccess(),
                hostName: Host.current().localizedName ?? "Mac",
                hostPlatform: .macOS,
                capabilities: HostCapability.fullControl + [.smoothCursorNavigation],
                companionVersion: Bundle.main.appVersion,
                nomadEndpoint: nomadEndpoint,
                acknowledgesPointerMoves: true
            ),
            to: session,
            replyTo: replyTo
        )
    }

    // MARK: - Bloc de commandes

    /// Le Mac conserve la copie de référence afin qu'un nouvel iPhone retrouve
    /// immédiatement la disposition et les raccourcis matériels enregistrés.
    func updateControlConfiguration(_ requested: ControlConfiguration) {
        var sanitized = Self.sanitizedControlConfiguration(shortcutStore.migrate(requested))
        sanitized.revision = controlConfiguration.revision &+ 1
        sanitized.updatedAt = Date()
        controlConfiguration = sanitized

        if let data = try? RemoteCoding.encoder.encode(sanitized) {
            UserDefaults.standard.set(data, forKey: Self.controlConfigurationDefaultsKey)
        }

        for session in sessions.values where session.isAuthenticated {
            sendControlConfiguration(to: session, replyTo: nil)
        }
    }

    func resetControlConfiguration() {
        updateControlConfiguration(.standard)
    }

    /// L'iPhone peut déplacer/remplacer les actions existantes, mais il ne
    /// peut pas fabriquer un keycode matériel. Une combinaison Mac déjà
    /// présente peut seulement être conservée à l'identique.
    private func updateControlConfigurationFromPeer(_ requested: ControlConfiguration) {
        var restricted = requested
        // This is a host-provided palette, never client-controlled state.
        restricted.availableShortcuts = nil
        // A mobile may assign any opaque reference advertised in the current
        // palette, not merely one that happened to be on the previous layout.
        let allowedShortcutIDs = Set(shortcutStore.references.map(\.id))
        for zone in ControlZone.allCases {
            var proposed = restricted.button(in: zone)
            if case .hostShortcut(let reference) = proposed.action,
               !allowedShortcutIDs.contains(reference.id) {
                proposed.action = .none
                restricted.setButton(proposed)
            } else if case .macShortcut = proposed.action {
                proposed.action = .none
                restricted.setButton(proposed)
            }
        }
        restricted.globalButtons = restricted.globalButtons.map { proposed in
            var safe = proposed
            if case .hostShortcut(let reference) = proposed.action,
               !allowedShortcutIDs.contains(reference.id) {
                safe.action = .none
            } else if case .macShortcut = proposed.action {
                safe.action = .none
            }
            return safe
        }
        updateControlConfiguration(restricted)
    }

    private func sendControlConfiguration(to session: Session, replyTo: UUID?) {
        var snapshot = controlConfiguration
        snapshot.availableShortcuts = shortcutStore.references
        send(
            type: .controlConfigurationSnapshot,
            payload: ControlConfigurationPayload(configuration: snapshot),
            to: session,
            replyTo: replyTo
        )
    }

    private static let controlConfigurationDefaultsKey = "controlConfiguration.v1"

    private static func loadControlConfiguration() -> ControlConfiguration {
        guard let data = UserDefaults.standard.data(forKey: controlConfigurationDefaultsKey),
              let decoded = try? RemoteCoding.decoder.decode(ControlConfiguration.self, from: data) else {
            return .standard
        }
        return sanitizedControlConfiguration(decoded)
    }

    /// Évite qu'une image importée ou une configuration incomplète ne dépasse
    /// la taille maximale d'une trame réseau.
    private static func sanitizedControlConfiguration(_ requested: ControlConfiguration) -> ControlConfiguration {
        var buttons: [ControlButtonConfiguration] = []
        var globalButtons: [GlobalButtonConfiguration] = []
        var customImageBytes = 0

        for zone in ControlZone.allCases {
            var button = requested.button(in: zone)
            button.title = String(button.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            if button.title.isEmpty { button.title = MacL10n.text("mac.untitled.2c847c1") }

            switch button.icon {
            case .system(let name):
                let cleaned = String(name.prefix(80))
                button.icon = .system(cleaned.isEmpty ? "circle" : cleaned)
            case .customImage(let data):
                guard data.count <= 40 * 1_024,
                      customImageBytes + data.count <= 280 * 1_024 else {
                    button.icon = .system("photo")
                    break
                }
                customImageBytes += data.count
            }

            if case .macShortcut(let shortcut) = button.action, !shortcut.isValid {
                button.action = .none
            }
            if case .hostShortcut(let shortcut) = button.action, !shortcut.isValid {
                button.action = .none
            }
            buttons.append(button)
        }

        for requestedButton in requested.globalButtons.prefix(32) {
            var button = requestedButton
            button.title = String(button.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            if button.title.isEmpty { button.title = MacL10n.text("mac.untitled.2c847c1") }

            switch button.icon {
            case .system(let name):
                let cleaned = String(name.prefix(80))
                button.icon = .system(cleaned.isEmpty ? "circle" : cleaned)
            case .customImage(let data):
                guard data.count <= 40 * 1_024,
                      customImageBytes + data.count <= 280 * 1_024 else {
                    button.icon = .system("photo")
                    break
                }
                customImageBytes += data.count
            }

            if case .macShortcut(let shortcut) = button.action, !shortcut.isValid {
                button.action = .none
            }
            if case .hostShortcut(let shortcut) = button.action, !shortcut.isValid {
                button.action = .none
            }
            globalButtons.append(button)
        }

        return ControlConfiguration(
            buttons: buttons,
            globalButtons: globalButtons,
            revision: requested.revision,
            updatedAt: requested.updatedAt
        )
    }

    // MARK: - Écran distant

    private func handleScreenRequest(
        _ request: ScreenStreamRequestPayload,
        for session: Session,
        replyTo: UUID?
    ) {
        session.wantsScreen = request.enabled
        session.screenRequest = request.enabled ? request : nil

        guard request.enabled else {
            send(
                type: .screenStreamStatus,
                payload: ScreenStreamStatusPayload(
                    isStreaming: false,
                    permissionGranted: CGPreflightScreenCaptureAccess()
                ),
                to: session,
                replyTo: replyTo
            )
            stopScreenCaptureWhenUnused()
            return
        }

        if screenCaptureRunning {
            send(
                type: .screenStreamStatus,
                payload: ScreenStreamStatusPayload(isStreaming: true, permissionGranted: true),
                to: session,
                replyTo: replyTo
            )
            return
        }
        guard !screenCaptureStarting else { return }
        screenCaptureStarting = true

        Task { [weak self] in
            guard let self else { return }
            do {
                try await screenCapture.start(
                    request: request,
                    frameHandler: { [weak self] frame in
                        Task { @MainActor in self?.broadcastScreenFrame(frame) }
                    },
                    stoppedHandler: { [weak self] error in
                        Task { @MainActor in self?.handleScreenCaptureStopped(error) }
                    }
                )
                screenCaptureStarting = false
                screenCaptureRunning = true

                if sessions.values.contains(where: \.wantsScreen) {
                    for viewer in sessions.values where viewer.wantsScreen {
                        send(
                            type: .screenStreamStatus,
                            payload: ScreenStreamStatusPayload(isStreaming: true, permissionGranted: true),
                            to: viewer,
                            replyTo: viewer === session ? replyTo : nil
                        )
                    }
                } else {
                    stopScreenCaptureWhenUnused()
                }
            } catch {
                screenCaptureStarting = false
                screenCaptureRunning = false
                send(
                    type: .screenStreamStatus,
                    payload: ScreenStreamStatusPayload(
                        isStreaming: false,
                        permissionGranted: CGPreflightScreenCaptureAccess(),
                        // A framework error can contain display or window
                        // context. The mobile only needs a stable state code.
                        detail: "screen_capture_unavailable"
                    ),
                    to: session,
                    replyTo: replyTo
                )
            }
        }
    }

    /// Publie immédiatement le nouvel état TCC vers l'iPhone. Une demande
    /// d'écran refusée conserve son intention ; dès que l'utilisateur coche
    /// Vibe Walkie dans Réglages, l'iPhone redemande alors le flux sans qu'il
    /// soit nécessaire de relancer le compagnon.
    func screenCapturePermissionDidChange(_ granted: Bool) {
        if granted,
           !screenCaptureRunning,
           !screenCaptureStarting,
           let viewer = sessions.values.first(where: { $0.wantsScreen && $0.isAuthenticated }),
           let request = viewer.screenRequest {
            handleScreenRequest(request, for: viewer, replyTo: nil)
            return
        }

        for viewer in sessions.values where viewer.wantsScreen && viewer.isAuthenticated {
            send(
                type: .screenStreamStatus,
                payload: ScreenStreamStatusPayload(
                    isStreaming: granted && screenCaptureRunning,
                    permissionGranted: granted
                ),
                to: viewer,
                replyTo: nil
            )
        }
    }

    private func broadcastScreenFrame(_ frame: ScreenFramePayload) {
        guard screenCaptureRunning else { return }
        for session in sessions.values where session.wantsScreen && session.isAuthenticated {
            sendScreenFrame(frame, to: session)
        }
    }

    /// ScreenCaptureKit peut interrompre un flux sans fermer la connexion
    /// réseau (verrouillage de session, changement d'écran, service relancé).
    /// On publie alors l'état réel afin que l'iPhone puisse redemander le flux
    /// au lieu de rester indéfiniment sur la dernière image reçue.
    private func handleScreenCaptureStopped(_: Error) {
        screenCaptureRunning = false
        screenCaptureStarting = false
        Task { await screenCapture.stop() }

        for viewer in sessions.values where viewer.wantsScreen && viewer.isAuthenticated {
            send(
                type: .screenStreamStatus,
                payload: ScreenStreamStatusPayload(
                    isStreaming: false,
                    permissionGranted: CGPreflightScreenCaptureAccess(),
                    detail: "screen_capture_unavailable"
                ),
                to: viewer,
                replyTo: nil
            )
        }
    }

    /// Une seule image peut attendre dans la pile TCP par iPhone. Si le réseau
    /// ralentit, on jette les images intermédiaires au lieu d'accumuler du
    /// retard : l'écran reste ainsi proche du temps réel.
    private func sendScreenFrame(_ payload: ScreenFramePayload, to session: Session) {
        guard !session.screenFrameInFlight else { return }
        session.sequence += 1
        guard let envelope = try? RemoteEnvelope.make(
            type: .screenFrame,
            sessionID: session.sessionID,
            sequence: session.sequence,
            payload: payload
        ), let data = try? RemoteCoding.encoder.encode(envelope),
           let framed = try? MessageFramer.frame(data) else { return }

        session.screenFrameInFlight = true
        session.connection.send(content: framed, completion: .contentProcessed { [weak session] _ in
            Task { @MainActor in session?.screenFrameInFlight = false }
        })
    }

    private func stopScreenCaptureWhenUnused() {
        guard !sessions.values.contains(where: \.wantsScreen),
              screenCaptureRunning || screenCaptureStarting else { return }
        screenCaptureRunning = false
        screenCaptureStarting = false
        Task { await screenCapture.stop() }
    }

    // MARK: - Envoi

    private func sendChallenge(_ session: Session) {
        session.nonce = SecureRandom.bytes(32)
        send(
            type: .pairingChallenge,
            payload: PairingChallengePayload(nonce: session.nonce, requiresPairingSecret: authority.isPairing),
            to: session,
            replyTo: nil
        )
    }

    private func send<T: Encodable>(type: RemoteMessageType, payload: T, to session: Session, replyTo: UUID?) {
        guard let payloadData = try? RemoteCoding.encoder.encode(payload) else { return }
        sendEncoded(type: type, payload: payloadData, to: session, replyTo: replyTo)
    }

    private func sendResponse<T: Encodable>(
        type: RemoteMessageType,
        payload: T,
        for request: RemoteEnvelope,
        peerID: String,
        to session: Session
    ) {
        guard let payloadData = try? RemoteCoding.encoder.encode(payload) else { return }
        cacheCrossSessionResponse(
            type: type,
            payload: payloadData,
            for: request,
            peerID: peerID
        )
        sendEncoded(type: type, payload: payloadData, to: session, replyTo: request.messageID)
    }

    private func sendResponse(
        error: RemoteErrorPayload,
        for request: RemoteEnvelope,
        peerID: String,
        to session: Session
    ) {
        sendResponse(
            type: .error,
            payload: error,
            for: request,
            peerID: peerID,
            to: session
        )
    }

    private func cacheCrossSessionResponse(
        type: RemoteMessageType,
        payload: Data,
        for request: RemoteEnvelope,
        peerID: String
    ) {
        guard isCrossSessionIdempotent(request.type) else { return }
        crossSessionResponses.store(
            CachedPeerResponse(type: type, payload: payload),
            for: peerID,
            messageID: request.messageID
        )
    }

    private func sendEncoded(
        type: RemoteMessageType,
        payload: Data,
        to session: Session,
        replyTo: UUID?
    ) {
        session.sequence += 1
        let envelope = RemoteEnvelope(
            type: type,
            replyTo: replyTo,
            sessionID: session.sessionID,
            sequence: session.sequence,
            payload: payload
        )
        guard let data = try? RemoteCoding.encoder.encode(envelope),
        let framed = try? MessageFramer.frame(data) else {
            return
        }
        session.connection.send(content: framed, completion: .idempotent)
    }

    private func send(error: RemoteErrorPayload, to session: Session, replyTo: UUID?) {
        send(type: .error, payload: error, to: session, replyTo: replyTo)
    }

    /// Network.framework ne garantit pas qu'un envoi `.idempotent` soit vidé
    /// avant un `cancel()` immédiat. Les erreurs d'appairage doivent parvenir à
    /// l'iPhone avant de fermer la session, sinon le scanner reste sur son
    /// loader sans savoir que le QR a expiré.
    private func sendAndClose(error: RemoteErrorPayload, to session: Session, replyTo: UUID?) {
        session.sequence += 1
        guard let envelope = try? RemoteEnvelope.make(
            type: .error,
            sessionID: session.sessionID,
            sequence: session.sequence,
            replyTo: replyTo,
            payload: error
        ),
        let data = try? RemoteCoding.encoder.encode(envelope),
        let framed = try? MessageFramer.frame(data) else {
            session.connection.cancel()
            return
        }
        let connection = session.connection
        connection.send(content: framed, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
