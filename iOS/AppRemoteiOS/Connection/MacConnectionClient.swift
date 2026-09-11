import Foundation
import Network
import CryptoKit
import RemoteCore

/// Client réseau de l'iPhone : découverte, TLS épinglé, authentification.
@MainActor
final class HostConnectionClient: ObservableObject {

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var snapshot: WindowsSnapshotPayload?
    @Published private(set) var inputControlReady = true
    @Published private(set) var screenCaptureReady = true
    @Published private(set) var connectedHostPlatform: HostPlatform = .macOS
    @Published private(set) var hostCapabilities: Set<HostCapability> = Set(HostCapability.fullControl)
    @Published private(set) var latestScreenFrame: ScreenFramePayload?
    @Published private(set) var lastScreenFrameAt: Date?
    @Published private(set) var screenStreamStatus = ScreenStreamStatusPayload(
        isStreaming: false,
        permissionGranted: true
    )
    @Published private(set) var controlConfiguration: ControlConfiguration
    @Published private(set) var connectionRoute: ConnectionRoute = .local
    @Published private(set) var connectionIsExpensive = false
    @Published private(set) var connectionIsConstrained = false
    @Published private(set) var nomadEndpoint: NomadEndpoint?
    @Published private(set) var pairedHosts: [PairedHost]
    @Published private(set) var selectedHostID: PairedHost.ID?

    private enum AttemptKind: Hashable {
        case local
        case nomadDNS
        case nomadIPv4
    }

    private final class ConnectionAttempt {
        let connection: NWConnection
        let kind: AttemptKind
        let generation: UUID

        init(connection: NWConnection, kind: AttemptKind, generation: UUID) {
            self.connection = connection
            self.kind = kind
            self.generation = generation
        }
    }

    private var screenStreamOwner: UUID?
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var framer = MessageFramer()
    private var sequence: UInt64 = 0
    private var sessionID = UUID().uuidString
    private var retry = RetryPolicy()
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var foregroundReconnectTask: Task<Void, Never>?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var nomadFallbackTask: Task<Void, Never>?
    private var activeServiceName: String?
    private var connectionGeneration = UUID()
    private var connectionAttempts: [ObjectIdentifier: ConnectionAttempt] = [:]
    private var startedAttemptKinds: Set<AttemptKind> = []
    private var lastLocalPreferenceAttemptAt: Date?

    var selectedHost: PairedHost? {
        guard let selectedHostID else { return pairedHosts.first }
        return pairedHosts.first { $0.id == selectedHostID } ?? pairedHosts.first
    }

    func supports(_ capability: HostCapability) -> Bool {
        hostCapabilities.contains(capability)
    }

    private var pairedHost: PairedHost? { selectedHost }
    /// Renseigné le temps d'un appairage, puis effacé.
    private var pendingPairing: PairingQRPayload?

    private var pendingReplies: [UUID: CheckedContinuation<RemoteEnvelope, Error>] = [:]
    private var pendingControlConfiguration: ControlConfiguration?
    private var configurationStorageFailed = false
    private let configurationStore = HostControlConfigurationStore(defaults: .standard)

    init() {
        let storedHosts = PairedHostStore.load()
        pairedHosts = storedHosts.macs
        selectedHostID = storedHosts.selectedHostID
        nomadEndpoint = NomadFeatureFlag.isEnabled ? storedHosts.selectedHost?.nomadEndpoint : nil
        controlConfiguration = .standard
        do {
            try configurationStore.migrateLegacy(selectedHostID: storedHosts.selectedHostID)
            try loadHostConfiguration()
        } catch {
            configurationStorageFailed = true
            state = .failed(.invalidControlConfiguration)
        }
    }

#if DEBUG
    /// Données déterministes réservées aux captures marketing du simulateur.
    /// Elles ne sont jamais compilées dans une archive Release.
    func configureMarketingPreview() {
        state = .ready(hostName: "MacBook Pro")
        inputControlReady = true
        snapshot = WindowsSnapshotPayload(
            applications: [
                RemoteApplication(
                    id: "notes",
                    name: "Notes",
                    bundleIdentifier: "com.apple.Notes",
                    isActive: true,
                    iconPNG: nil,
                    windows: [RemoteWindow(id: "notes-main", title: "Vibe Walkie", isMain: true, isMinimized: false)]
                ),
                RemoteApplication(
                    id: "safari",
                    name: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    isActive: false,
                    iconPNG: nil,
                    windows: [RemoteWindow(id: "safari-main", title: "Vibe Walkie", isMain: true, isMinimized: false)]
                ),
                RemoteApplication(
                    id: "mail",
                    name: "Mail",
                    bundleIdentifier: "com.apple.mail",
                    isActive: false,
                    iconPNG: nil,
                    windows: [RemoteWindow(id: "mail-main", title: "Vibe Walkie", isMain: true, isMinimized: false)]
                ),
                RemoteApplication(
                    id: "codex",
                    name: "Codex",
                    bundleIdentifier: "com.openai.codex",
                    isActive: false,
                    iconPNG: nil,
                    windows: [RemoteWindow(id: "codex-main", title: "ios.vibe.walkie.111e6dd", isMain: true, isMinimized: false)]
                ),
                RemoteApplication(
                    id: "xcode",
                    name: "Xcode",
                    bundleIdentifier: "com.apple.dt.Xcode",
                    isActive: false,
                    iconPNG: nil,
                    windows: [RemoteWindow(id: "xcode-main", title: "ios.vibe.walkie.111e6dd", isMain: true, isMinimized: false)]
                ),
                RemoteApplication(
                    id: "terminal",
                    name: "Terminal",
                    bundleIdentifier: "com.apple.Terminal",
                    isActive: false,
                    iconPNG: nil,
                    windows: [RemoteWindow(id: "terminal-main", title: "zsh", isMain: true, isMinimized: false)]
                )
            ],
            activeApplicationID: "notes"
        )
    }
#endif

    var isPaired: Bool { !pairedHosts.isEmpty }
    var isNomadModeEnabled: Bool { NomadFeatureFlag.isEnabled }
    // MARK: - Appairage

    /// Prend en compte un QR scanné et lance la connexion.
    func pair(with payload: PairingQRPayload) throws {
        try payload.validate()
        pendingPairing = payload
        nomadEndpoint = NomadFeatureFlag.isEnabled ? payload.nomadEndpoint : nil
        state = .pairing(hostName: payload.hostName, confirmationCode: payload.confirmationCode)
        startPairingTimeout()
        connect(
            to: payload.serviceName,
            fingerprint: payload.certificateFingerprint,
            hostName: payload.hostName
        )
    }

    func selectHost(_ id: PairedHost.ID) {
        guard id != selectedHostID,
              pairedHosts.contains(where: { $0.id == id }) else { return }

        disconnect()
        apply(PairedHostStore.select(id))
        resetTargetState()
        state = .searching
        connectIfPossible()
    }

    func forgetHost(_ id: PairedHost.ID? = nil) {
        guard let id = id ?? selectedHostID else { return }
        let wasSelected = id == selectedHostID
        if wasSelected { disconnect() }
        apply(PairedHostStore.remove(id))

        guard wasSelected else { return }
        resetTargetState()
        if pairedHost == nil {
            state = .idle
        } else {
            state = .searching
            connectIfPossible()
        }
    }

    /// Abandonne proprement un QR qui n'a pas abouti afin que le scanner
    /// puisse immédiatement en accepter un nouveau.
    func cancelPairing() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pendingPairing = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelConnectionCycle()
        nomadEndpoint = NomadFeatureFlag.isEnabled ? pairedHost?.nomadEndpoint : nil
        state = pairedHost == nil ? .idle : .searching
        if pairedHost != nil { connectIfPossible() }
    }

    // MARK: - Connexion

    func connectIfPossible() {
        guard !configurationStorageFailed else {
            state = .failed(.invalidControlConfiguration)
            return
        }
        guard let mac = pairedHost, connection == nil else { return }
        state = .searching
        browseForPairedHost(mac)
        connect(
            to: mac.serviceName,
            fingerprint: mac.certificateFingerprint,
            hostName: mac.name
        )
    }

    /// Relance immédiatement une connexion bloquée en résolution ou en TLS.
    /// Le bouton de reconnexion doit remplacer l'objet `NWConnection` : appeler
    /// simplement `connectIfPossible` ne faisait rien tant qu'une connexion en
    /// état `.waiting` restait conservée.
    func reconnectNow() {
        guard let mac = pairedHost else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelConnectionCycle()
        state = .searching
        browseForPairedHost(mac)
        connect(
            to: mac.serviceName,
            fingerprint: mac.certificateFingerprint,
            hostName: mac.name
        )
    }

    /// iOS met brièvement le réseau local en pause lors d'un changement
    /// d'application. Attendre quelques centaines de millisecondes évite une
    /// fausse tentative pendant que le Wi‑Fi et Bonjour se réactivent.
    func resumeAfterForeground() {
        foregroundReconnectTask?.cancel()
        guard pairedHost != nil || pendingPairing != nil else { return }
        foregroundReconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            if let pairing = self.pendingPairing {
                guard !pairing.isExpired else {
                    self.failPairing(.pairingApprovalExpired)
                    return
                }
                self.startPairingTimeout()
                self.connect(
                    to: pairing.serviceName,
                    fingerprint: pairing.certificateFingerprint,
                    hostName: pairing.hostName
                )
            } else {
                self.reconnectNow()
            }
        }
    }

    func disconnect() {
        foregroundReconnectTask?.cancel()
        foregroundReconnectTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        cancelConnectionCycle()
        browser?.cancel()
        browser = nil
        activeServiceName = nil
        framer.reset()
        latestScreenFrame = nil
        lastScreenFrameAt = nil
        screenStreamStatus = ScreenStreamStatusPayload(isStreaming: false, permissionGranted: true)
        failPendingReplies(RemoteErrorPayload(code: .internalFailure, detail: "déconnecté"))
    }

    private func connect(
        to serviceName: String,
        fingerprint: String,
        hostName: String
    ) {
        // Une découverte Bonjour peut trouver le bon nom pendant qu'une
        // ancienne relance différée est encore planifiée. Cette dernière ne
        // doit pas venir écraser la nouvelle connexion quelques secondes plus
        // tard.
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelConnectionCycle()
        framer.reset()
        sequence = 0
        sessionID = UUID().uuidString
        state = .connecting(hostName: hostName)
        activeServiceName = serviceName

        let generation = UUID()
        connectionGeneration = generation
        let localEndpoint = NWEndpoint.service(
            name: serviceName,
            type: VibeWalkieInfo.bonjourServiceType,
            domain: "local.",
            interface: nil
        )
        startAttempt(
            to: localEndpoint,
            kind: .local,
            generation: generation,
            hostName: hostName,
            serviceName: serviceName,
            fingerprint: fingerprint
        )

        let endpoint = NomadFeatureFlag.isEnabled
            ? (pendingPairing?.nomadEndpoint ?? pairedHost?.nomadEndpoint)
            : nil
        guard endpoint?.isValid == true else { return }
        nomadFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self,
                  self.connectionGeneration == generation,
                  self.connection == nil else { return }
            self.nomadFallbackTask = nil
            self.startNomadAttempts(
                endpoint: endpoint,
                generation: generation,
                hostName: hostName,
                serviceName: serviceName,
                fingerprint: fingerprint
            )
        }
    }

    private func startNomadAttempts(
        endpoint: NomadEndpoint?,
        generation: UUID,
        hostName: String,
        serviceName: String,
        fingerprint: String
    ) {
        guard let endpoint, endpoint.isValid,
              connectionGeneration == generation,
              connection == nil else {
            finishAttemptCycleIfNeeded(
                generation: generation,
                hostName: hostName,
                serviceName: serviceName,
                fingerprint: fingerprint
            )
            return
        }
        let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port))!
        startAttempt(
            to: .hostPort(host: NWEndpoint.Host(endpoint.magicDNSName), port: port),
            kind: .nomadDNS,
            generation: generation,
            hostName: hostName,
            serviceName: serviceName,
            fingerprint: fingerprint
        )

        // MagicDNS peut rester longtemps en `.preparing` sur iOS lorsque le
        // tunnel Tailscale vient de se réveiller. Dans ce cas, attendre son
        // échec avant de tenter l'adresse 100.x fait expirer l'appairage alors
        // que le Mac est joignable. Les deux routes sont sûres (le certificat
        // reste épinglé) : on les met donc en concurrence et la première
        // connexion TLS valide gagne.
        startIPv4FallbackIfNeeded(
            after: .nomadDNS,
            generation: generation,
            hostName: hostName,
            serviceName: serviceName,
            fingerprint: fingerprint
        )
    }

    private func startAttempt(
        to endpoint: NWEndpoint,
        kind: AttemptKind,
        generation: UUID,
        hostName: String,
        serviceName: String,
        fingerprint: String
    ) {
        guard connectionGeneration == generation,
              connection == nil,
              !startedAttemptKinds.contains(kind) else { return }

        startedAttemptKinds.insert(kind)
        let candidate = NWConnection(to: endpoint, using: makeParameters(expecting: fingerprint))
        let attempt = ConnectionAttempt(connection: candidate, kind: kind, generation: generation)
        connectionAttempts[ObjectIdentifier(candidate)] = attempt

        candidate.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                if self.connection === candidate {
                    switch newState {
                    case .waiting, .failed, .cancelled:
                        candidate.cancel()
                        self.handleDisconnection(
                            hostName: hostName,
                            serviceName: serviceName,
                            fingerprint: fingerprint
                        )
                    default:
                        break
                    }
                    return
                }

                let identifier = ObjectIdentifier(candidate)
                guard let current = self.connectionAttempts[identifier],
                      current.generation == generation,
                      self.connectionGeneration == generation else { return }
                switch newState {
                case .ready:
                    self.selectWinningConnection(
                        candidate,
                        kind: kind,
                        generation: generation,
                        hostName: hostName,
                        serviceName: serviceName,
                        fingerprint: fingerprint
                    )
                case .waiting, .failed, .cancelled:
                    candidate.cancel()
                    self.connectionAttempts.removeValue(forKey: identifier)
                    self.startIPv4FallbackIfNeeded(
                        after: kind,
                        generation: generation,
                        hostName: hostName,
                        serviceName: serviceName,
                        fingerprint: fingerprint
                    )
                    self.finishAttemptCycleIfNeeded(
                        generation: generation,
                        hostName: hostName,
                        serviceName: serviceName,
                        fingerprint: fingerprint
                    )
                default:
                    break
                }
            }
        }
        candidate.start(queue: .main)
    }

    private func startIPv4FallbackIfNeeded(
        after kind: AttemptKind,
        generation: UUID,
        hostName: String,
        serviceName: String,
        fingerprint: String
    ) {
        guard kind == .nomadDNS,
              let endpoint = pendingPairing?.nomadEndpoint ?? pairedHost?.nomadEndpoint,
              let address = endpoint.ipv4Address,
              NomadEndpoint.isValidTailscaleIPv4(address),
              let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { return }
        startAttempt(
            to: .hostPort(host: NWEndpoint.Host(address), port: port),
            kind: .nomadIPv4,
            generation: generation,
            hostName: hostName,
            serviceName: serviceName,
            fingerprint: fingerprint
        )
    }

    private func selectWinningConnection(
        _ winner: NWConnection,
        kind: AttemptKind,
        generation: UUID,
        hostName: String,
        serviceName: String,
        fingerprint: String
    ) {
        guard connectionGeneration == generation, connection == nil else {
            winner.cancel()
            return
        }
        connection = winner
        connectionAttempts.removeValue(forKey: ObjectIdentifier(winner))
        let losingAttempts = connectionAttempts.values
        connectionAttempts.removeAll()
        losingAttempts.forEach { $0.connection.cancel() }
        nomadFallbackTask?.cancel()
        nomadFallbackTask = nil
        retry.reset()
        connectionRoute = kind == .local ? .local : .nomad
        updatePath(from: winner.currentPath, for: winner)
        winner.pathUpdateHandler = { [weak self, weak winner] path in
            guard let winner else { return }
            Task { @MainActor in
                self?.updatePath(from: path, for: winner)
            }
        }
        receive(
            on: winner,
            hostName: hostName,
            serviceName: serviceName,
            fingerprint: fingerprint
        )
    }

    private func updatePath(from path: NWPath?, for candidate: NWConnection) {
        guard connection === candidate else { return }
        connectionIsExpensive = path?.isExpensive ?? false
        connectionIsConstrained = path?.isConstrained ?? false
    }

    private func finishAttemptCycleIfNeeded(
        generation: UUID,
        hostName: String,
        serviceName: String,
        fingerprint: String
    ) {
        guard connectionGeneration == generation,
              connection == nil,
              connectionAttempts.isEmpty,
              nomadFallbackTask == nil else { return }
        scheduleReconnect(
            hostName: hostName,
            serviceName: serviceName,
            fingerprint: fingerprint
        )
    }

    private func cancelConnectionCycle() {
        connectionGeneration = UUID()
        nomadFallbackTask?.cancel()
        nomadFallbackTask = nil
        let attempts = connectionAttempts.values
        connectionAttempts.removeAll()
        attempts.forEach { $0.connection.cancel() }
        startedAttemptKinds.removeAll()
        let current = connection
        connection = nil
        current?.cancel()
        connectionIsExpensive = false
        connectionIsConstrained = false
    }

    /// Redécouvre le service par son empreinte si macOS ou Bonjour a modifié
    /// son nom. Le TLS épinglé reste l'autorité de sécurité : un autre Mac ne
    /// peut pas être accepté même s'il imite le nom publié.
    private func browseForPairedHost(_ mac: PairedHost) {
        browser?.cancel()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: VibeWalkieInfo.bonjourServiceType, domain: "local."),
            using: parameters
        )
        let fingerprintSuffix = String(
            mac.certificateFingerprint.filter { $0.isLetter || $0.isNumber }.prefix(8)
        )

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.browser === browser, self.pendingPairing == nil else { return }
                let names = results.compactMap { result -> String? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return name
                }
                guard let discovered = names.first(where: { $0 == mac.serviceName })
                        ?? names.first(where: { $0.contains(fingerprintSuffix) }),
                      !discovered.isEmpty else { return }

                // Une session Tailscale ne masque jamais le réseau local. Si
                // Bonjour réapparaît (retour à la maison, Wi-Fi réactivé), on
                // relance une course avec 750 ms d'avance pour le LAN. La
                // reconnexion reste protégée par le même certificat épinglé.
                if ConnectionRoute.local.isPreferred(over: self.connectionRoute),
                   self.connection != nil,
                   self.state.isReady {
                    let now = Date()
                    guard self.lastLocalPreferenceAttemptAt.map({ now.timeIntervalSince($0) >= 10 }) ?? true else {
                        return
                    }
                    self.lastLocalPreferenceAttemptAt = now
                    self.connect(
                        to: discovered,
                        fingerprint: mac.certificateFingerprint,
                        hostName: mac.name
                    )
                    return
                }

                guard discovered != self.activeServiceName else { return }
                self.connect(
                    to: discovered,
                    fingerprint: mac.certificateFingerprint,
                    hostName: mac.name
                )
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            Task { @MainActor in
                guard self?.browser === browser else { return }
                self?.browser = nil
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func startPairingTimeout() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.pendingPairing != nil else { return }
            if case .awaitingApproval = self.state { return }
            self.failPairing(.macUnavailable)
        }
    }

    /// Une approbation distante ne doit jamais laisser le scanner tourner
    /// indéfiniment. Le compagnon transmet son échéance exacte ; passée cette
    /// date, l'iPhone rend la main et demande un nouveau QR.
    private func startApprovalTimeout(expiresAt: Date) {
        pairingTimeoutTask?.cancel()
        let delay = max(0, expiresAt.timeIntervalSinceNow + 1)
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.pendingPairing != nil,
                  case .awaitingApproval = self.state else { return }
            self.failPairing(.pairingApprovalExpired)
        }
    }

    private func failPairing(_ error: RemoteErrorCode) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pendingPairing = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelConnectionCycle()
        nomadEndpoint = NomadFeatureFlag.isEnabled ? pairedHost?.nomadEndpoint : nil
        state = .failed(error)
    }

    /// Paramètres TLS avec épinglage strict.
    ///
    /// Le certificat du Mac est auto-signé : la validation par défaut le
    /// rejetterait. On ne désactive pas la vérification pour autant — on la
    /// remplace par une comparaison d'empreinte exacte, celle transmise par le
    /// QR. Accepter n'importe quel certificat ouvrirait la porte à un
    /// intercepteur sur le même Wi-Fi.
    private func makeParameters(expecting fingerprint: String) -> NWParameters {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)

        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                      let leaf = chain.first else {
                    complete(false)
                    return
                }
                let data = SecCertificateCopyData(leaf) as Data
                let digest = Data(SHA256.hash(data: data)).base64EncodedString()
                complete(digest == fingerprint)
            },
            .main
        )

        let parameters = NWParameters(tls: options)
        parameters.includePeerToPeer = true
        return parameters
    }

    private func handleDisconnection(
        hostName: String,
        serviceName: String,
        fingerprint: String
    ) {
        watchdogTask?.cancel()
        watchdogTask = nil
        connection = nil
        latestScreenFrame = nil
        lastScreenFrameAt = nil
        screenStreamStatus = ScreenStreamStatusPayload(isStreaming: false, permissionGranted: true)
        failPendingReplies(RemoteErrorPayload(code: .internalFailure, detail: "connexion perdue"))
        guard isPaired || pendingPairing != nil else {
            state = .idle
            return
        }
        state = .searching

        scheduleReconnect(
            hostName: hostName,
            serviceName: serviceName,
            fingerprint: fingerprint
        )
    }

    private func scheduleReconnect(
        hostName: String,
        serviceName: String,
        fingerprint: String
    ) {
        reconnectTask?.cancel()
        let delay = retry.nextDelay()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.connect(
                    to: serviceName,
                    fingerprint: fingerprint,
                    hostName: hostName
                )
            }
        }
    }

    // MARK: - Réception

    private func receive(
        on connection: NWConnection,
        hostName: String,
        serviceName: String,
        fingerprint: String
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                // Une fin de lecture appartenant à une ancienne connexion ne
                // doit jamais annuler celle qui vient de la remplacer.
                guard self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.ingest(data)
                }
                if isComplete || error != nil {
                    // On programme nous-mêmes la reconnexion. Attendre le
                    // callback `.cancelled` de Network.framework laissait
                    // parfois l’iPhone bloqué sur l’ancienne session après une
                    // mise à jour ou un redémarrage du compagnon Mac.
                    connection.cancel()
                    self.handleDisconnection(
                        hostName: hostName,
                        serviceName: serviceName,
                        fingerprint: fingerprint
                    )
                    return
                }
                self.receive(
                    on: connection,
                    hostName: hostName,
                    serviceName: serviceName,
                    fingerprint: fingerprint
                )
            }
        }
    }

    private func ingest(_ data: Data) {
        guard let messages = try? framer.append(data) else {
            connection?.cancel()
            return
        }
        for message in messages {
            guard let envelope = try? RemoteCoding.decoder.decode(RemoteEnvelope.self, from: message) else { continue }
            handle(envelope)
        }
    }

    private func handle(_ envelope: RemoteEnvelope) {
        guard envelope.version == ProtocolVersion.current else {
            pendingPairing = nil
            connection?.cancel()
            connection = nil
            state = .failed(.versionMismatch)
            return
        }
        if let replyTo = envelope.replyTo, let continuation = pendingReplies.removeValue(forKey: replyTo) {
            if envelope.type == .error, let payload = try? envelope.decodePayload(RemoteErrorPayload.self) {
                continuation.resume(throwing: payload)
            } else {
                // Les réponses typées doivent aussi alimenter l'état publié.
                // Avant, `windowsSnapshot` reprenait la continuation puis
                // quittait la méthode : la grille d'apps restait donc vide.
                if envelope.type == .windowsSnapshot {
                    snapshot = try? envelope.decodePayload(WindowsSnapshotPayload.self)
                }
                continuation.resume(returning: envelope)
            }
            return
        }

        switch envelope.type {
        case .pairingChallenge:
            guard let payload = try? envelope.decodePayload(PairingChallengePayload.self) else { return }
            respondToChallenge(payload, replyTo: envelope.messageID)

        case .pairingPending:
            guard let payload = try? envelope.decodePayload(PairingPendingPayload.self),
                  let pending = pendingPairing else { return }
            state = .awaitingApproval(
                hostName: pending.hostName,
                confirmationCode: payload.confirmationCode
            )
            startApprovalTimeout(expiresAt: payload.expiresAt)

        case .connectionStatus:
            guard let payload = try? envelope.decodePayload(ConnectionStatusPayload.self) else { return }
            inputControlReady = payload.inputControlReady
            screenCaptureReady = payload.screenCaptureReady
            connectedHostPlatform = payload.hostPlatform
            hostCapabilities = Set(payload.capabilities)
            state = .ready(hostName: payload.hostName)
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            startWatchdog()


            let advertisedNomadEndpoint = NomadFeatureFlag.isEnabled && payload.nomadEndpoint?.isValid == true
                ? payload.nomadEndpoint
                : nil

            if let pending = pendingPairing {
                let mac = PairedHost(
                    name: payload.hostName,
                    platform: payload.hostPlatform,
                    serviceName: pending.serviceName,
                    certificateFingerprint: pending.certificateFingerprint,
                    nomadEndpoint: advertisedNomadEndpoint ?? pending.nomadEndpoint
                )
                apply(PairedHostStore.upsert(mac, select: true))
                pendingPairing = nil
            } else if let current = pairedHost,
                      let activeServiceName {
                let refreshed = PairedHost(
                    name: payload.hostName,
                    platform: payload.hostPlatform,
                    serviceName: activeServiceName,
                    certificateFingerprint: current.certificateFingerprint,
                    nomadEndpoint: advertisedNomadEndpoint
                )
                if refreshed != current {
                    apply(PairedHostStore.upsert(refreshed, select: false))
                }
                nomadEndpoint = refreshed.nomadEndpoint
            }

            guard !configurationStorageFailed else { return }
            if let pendingControlConfiguration {
                sendFireAndForget(
                    type: .controlConfigurationUpdate,
                    payload: ControlConfigurationPayload(configuration: pendingControlConfiguration)
                )
            } else {
                sendFireAndForget(type: .controlConfigurationRequest, payload: EmptyPayload())
            }

            // L'écoute Bonjour reste active pendant une session Nomade. Elle
            // permet de revenir automatiquement au LAN dès que l'iPhone et le
            // Mac partagent de nouveau le même réseau.
            if browser == nil, let pairedHost {
                browseForPairedHost(pairedHost)
            }

        case .windowsSnapshot:
            snapshot = try? envelope.decodePayload(WindowsSnapshotPayload.self)

        case .screenFrame:
            if let frame = try? envelope.decodePayload(ScreenFramePayload.self) {
                latestScreenFrame = frame
                lastScreenFrameAt = Date()
            }

        case .screenStreamStatus:
            if let payload = try? envelope.decodePayload(ScreenStreamStatusPayload.self) {
                screenStreamStatus = payload
                if !payload.isStreaming { latestScreenFrame = nil }
            }

        case .controlConfigurationSnapshot:
            guard let payload = try? envelope.decodePayload(ControlConfigurationPayload.self) else { return }
            if let pendingControlConfiguration,
               (
                   pendingControlConfiguration.buttons != payload.configuration.buttons ||
                   pendingControlConfiguration.globalButtons != payload.configuration.globalButtons
               ),
               payload.configuration.revision <= pendingControlConfiguration.revision {
                // Le premier instantané peut avoir été mis en file avant la
                // mise à jour locale envoyée juste après la reconnexion.
                sendFireAndForget(
                    type: .controlConfigurationUpdate,
                    payload: ControlConfigurationPayload(configuration: pendingControlConfiguration)
                )
                return
            }
            controlConfiguration = payload.configuration
            pendingControlConfiguration = nil
            persistControlConfiguration(payload.configuration, pending: false)

        case .error:
            if let payload = try? envelope.decodePayload(RemoteErrorPayload.self) {
                if pendingPairing != nil,
                   [.pairingDenied, .pairingApprovalExpired, .notPaired, .versionMismatch, .protocolMismatch].contains(payload.code) {
                    failPairing(payload.code)
                    return
                }
                state = .failed(payload.code)
            }

        default:
            break
        }
    }

    private func apply(_ storedHosts: PairedHostStore.State) {
        let previousHostID = selectedHostID
        pairedHosts = storedHosts.macs
        selectedHostID = storedHosts.selectedHostID
        nomadEndpoint = NomadFeatureFlag.isEnabled ? storedHosts.selectedHost?.nomadEndpoint : nil
        if previousHostID != selectedHostID {
            controlConfiguration = .standard
            pendingControlConfiguration = nil
            do { try loadHostConfiguration() } catch {
                configurationStorageFailed = true
                state = .failed(.invalidControlConfiguration)
            }
        }
    }

    private func loadHostConfiguration() throws {
        let stored = try configurationStore.load(hostID: selectedHostID)
        controlConfiguration = stored.configuration
        pendingControlConfiguration = stored.pending
        configurationStorageFailed = false
    }

    private func resetTargetState() {
        snapshot = nil
        inputControlReady = true
        screenCaptureReady = true
        connectedHostPlatform = selectedHost?.platform ?? .macOS
        hostCapabilities = Set(HostCapability.fullControl)
        latestScreenFrame = nil
        lastScreenFrameAt = nil
        screenStreamStatus = ScreenStreamStatusPayload(isStreaming: false, permissionGranted: true)
        connectionRoute = .local
    }

    func startScreenStream(maxWidth: Int = 1_280, framesPerSecond: Int = 10, jpegQuality: Double = 0.45, owner: UUID? = nil) {
        screenStreamOwner = owner
        latestScreenFrame = nil
        lastScreenFrameAt = nil
        screenStreamStatus = ScreenStreamStatusPayload(isStreaming: false, permissionGranted: true)
        sendFireAndForget(
            type: .screenStreamRequest,
            payload: ScreenStreamRequestPayload(
                enabled: true,
                maxWidth: maxWidth,
                framesPerSecond: framesPerSecond,
                jpegQuality: jpegQuality
            )
        )
    }

    func stopScreenStream(owner: UUID? = nil) {
        guard owner == nil || owner == screenStreamOwner else { return }
        screenStreamOwner = nil
        sendFireAndForget(type: .screenStreamRequest, payload: ScreenStreamRequestPayload(enabled: false))
        latestScreenFrame = nil
        lastScreenFrameAt = nil
        screenStreamStatus = ScreenStreamStatusPayload(isStreaming: false, permissionGranted: true)
    }

    func reportStaleScreenStream(owner: UUID) {
        guard screenStreamOwner == owner else { return }
        stopScreenStream(owner: owner)
        screenStreamStatus = ScreenStreamStatusPayload(
            isStreaming: false,
            permissionGranted: true,
            detail: AppL10n.text("ios.workspace.screen.stale")
        )
    }

    // MARK: - Bloc de commandes

    func updateControlConfiguration(_ configuration: ControlConfiguration) {
        var local = configuration
        local.updatedAt = Date()
        controlConfiguration = local
        pendingControlConfiguration = local
        persistControlConfiguration(local, pending: true)

        guard state.isReady else { return }
        sendFireAndForget(
            type: .controlConfigurationUpdate,
            payload: ControlConfigurationPayload(configuration: local)
        )
    }

    func resetControlConfiguration() {
        let wasStorageFailed = configurationStorageFailed
        updateControlConfiguration(.standard)
        if wasStorageFailed && !configurationStorageFailed { reconnectNow() }
    }

    private func persistControlConfiguration(_ configuration: ControlConfiguration, pending: Bool) {
        guard let selectedHostID else { return }
        do {
            try configurationStore.save(configuration, hostID: selectedHostID, pending: pending)
            configurationStorageFailed = false
        } catch {
            configurationStorageFailed = true
            state = .failed(.invalidControlConfiguration)
        }
    }

    /// Battement de cœur indépendant des vues présentées. Le plein écran peut
    /// suspendre les tâches de la vue principale ; la connexion, elle, doit
    /// continuer à être surveillée et se reconstruire sans intervention.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, self.state.isReady else { return }
                do {
                    _ = try await self.send(
                        type: .hello,
                        payload: HelloPayload(
                            deviceName: DeviceKeyStore.deviceName,
                            deviceIdentifier: DeviceKeyStore.deviceIdentifier,
                            appVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
                        )
                    )
                } catch {
                    // `send` remplace déjà la connexion sur timeout. Ce garde
                    // couvre les autres erreurs de transport immédiates.
                    if self.state.isReady { self.reconnectNow() }
                    return
                }
            }
        }
    }

    private func respondToChallenge(_ challenge: PairingChallengePayload, replyTo: UUID) {
        do {
            let key = try DeviceKeyStore.loadOrCreatePrivateKey()
            let secret = pendingPairing.flatMap { Data(base64Encoded: $0.pairingSecret) }
            let signature = try ChallengeSigner.sign(
                nonce: challenge.nonce,
                deviceIdentifier: DeviceKeyStore.deviceIdentifier,
                pairingSecret: secret,
                privateKey: key
            )
            let payload = PairingResponsePayload(
                deviceIdentifier: DeviceKeyStore.deviceIdentifier,
                deviceName: DeviceKeyStore.deviceName,
                publicKey: key.publicKey.rawRepresentation,
                signature: signature,
                pairingSecret: secret,
                clientPlatform: .iOS
            )
            sendFireAndForget(type: .pairingResponse, payload: payload, replyTo: replyTo)
        } catch {
            state = .failed(.notPaired)
        }
    }

    // MARK: - Envoi

    @discardableResult
    func send<T: Encodable>(type: RemoteMessageType, payload: T) async throws -> RemoteEnvelope {
        guard let connection, state.isReady || type == .pairingResponse else {
            throw RemoteErrorPayload(code: .internalFailure, detail: "non connecté")
        }
        sequence += 1
        let envelope = try RemoteEnvelope.make(
            type: type,
            sessionID: sessionID,
            sequence: sequence,
            payload: payload
        )
        let data = try RemoteCoding.encoder.encode(envelope)
        let framed = try MessageFramer.frame(data)

        return try await withCheckedThrowingContinuation { continuation in
            pendingReplies[envelope.messageID] = continuation
            connection.send(content: framed, completion: .idempotent)

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(ProtocolLimits.acknowledgementTimeout))
                await MainActor.run {
                    guard let pending = self?.pendingReplies.removeValue(forKey: envelope.messageID) else { return }
                    // Sans réponse, on ne conclut pas à un échec : la commande
                    // a pu aboutir. L'appelant décidera quoi montrer.
                    pending.resume(throwing: RemoteErrorPayload(code: .internalFailure, detail: "timeout"))
                    // La requête périodique des apps sert aussi de battement de
                    // cœur. Si le Mac a redémarré sans que Network.framework
                    // nous signale la socket morte, on la remplace ici.
                    self?.reconnectNow()
                }
            }
        }
    }

    /// Envoi sans attente de réponse, pour les gestes continus.
    func sendFireAndForget<T: Encodable>(type: RemoteMessageType, payload: T, replyTo: UUID? = nil) {
        guard let connection else { return }
        sequence += 1
        guard let envelope = try? RemoteEnvelope.make(
            type: type,
            sessionID: sessionID,
            sequence: sequence,
            replyTo: replyTo,
            payload: payload
        ),
        let data = try? RemoteCoding.encoder.encode(envelope),
        let framed = try? MessageFramer.frame(data) else { return }
        connection.send(content: framed, completion: .idempotent)
    }

    private func failPendingReplies(_ error: Error) {
        let pending = pendingReplies
        pendingReplies.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
    }

}
