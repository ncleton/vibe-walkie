import Foundation
import CryptoKit
import Testing
@testable import RemoteCore

@Suite("Cadrage des messages")
struct MessageFramerTests {

    @Test("Un message encadré est restitué intact")
    func roundTrip() throws {
        var framer = MessageFramer()
        let payload = Data("bonjour".utf8)
        let framed = try MessageFramer.frame(payload)
        let messages = try framer.append(framed)
        #expect(messages == [payload])
    }

    @Test("Un message arrivé en plusieurs morceaux est reconstitué")
    func splitDelivery() throws {
        var framer = MessageFramer()
        let payload = Data(repeating: 0x41, count: 500)
        let framed = try MessageFramer.frame(payload)

        let firstChunk = framed.prefix(10)
        let secondChunk = framed.dropFirst(10)

        let partial = try framer.append(Data(firstChunk))
        let completed = try framer.append(Data(secondChunk))
        #expect(partial.isEmpty)
        #expect(completed == [payload])
    }

    @Test("Plusieurs messages dans un même paquet sont séparés")
    func multipleMessages() throws {
        var framer = MessageFramer()
        var stream = Data()
        stream.append(try MessageFramer.frame(Data("un".utf8)))
        stream.append(try MessageFramer.frame(Data("deux".utf8)))

        let messages = try framer.append(stream)
        #expect(messages.count == 2)
        #expect(String(data: messages[1], encoding: .utf8) == "deux")
    }

    @Test("Une longueur au-delà de la limite est rejetée sans allouer")
    func oversizedFrameRejected() throws {
        var framer = MessageFramer()
        var header = Data()
        var length = UInt32(ProtocolLimits.maxFrameBytes + 1).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }

        #expect(throws: MessageFramer.FramingError.self) {
            _ = try framer.append(header)
        }
    }

    @Test("Encoder une charge utile trop grande échoue")
    func oversizedPayloadRejected() {
        let payload = Data(repeating: 0, count: ProtocolLimits.maxFrameBytes + 1)
        #expect(throws: MessageFramer.FramingError.self) {
            _ = try MessageFramer.frame(payload)
        }
    }
}

@Suite("Enveloppe")
struct EnvelopeTests {

    @Test("Le réseau local est toujours préféré au Mode Nomade")
    func localRoutePriority() {
        #expect(ConnectionRoute.local.isPreferred(over: .nomad))
        #expect(!ConnectionRoute.nomad.isPreferred(over: .local))
        #expect(!ConnectionRoute.local.isPreferred(over: .local))
    }

    @Test("La charge utile typée survit à l'aller-retour")
    func payloadRoundTrip() throws {
        let payload = InsertTextPayload(targetToken: "abc", text: "Bonjour, ça va ?", dictationID: UUID())
        let envelope = try RemoteEnvelope.make(
            type: .insertText,
            sessionID: "s1",
            sequence: 1,
            payload: payload
        )

        let data = try RemoteCoding.encoder.encode(envelope)
        let decoded = try RemoteCoding.decoder.decode(RemoteEnvelope.self, from: data)
        let decodedPayload = try decoded.decodePayload(InsertTextPayload.self)

        #expect(decoded.type == .insertText)
        #expect(decodedPayload.text == "Bonjour, ça va ?")
    }

    @Test("Le zoom reste une extension rétrocompatible du défilement")
    func zoomScrollPayloadCompatibility() throws {
        let legacy = try RemoteCoding.decoder.decode(
            ScrollPayload.self,
            from: Data(#"{"deltaX":0,"deltaY":12}"#.utf8)
        )
        #expect(legacy.zoom == nil)

        let zoom = ScrollPayload(deltaX: 0, deltaY: 18, zoom: true)
        let data = try RemoteCoding.encoder.encode(zoom)
        let decoded = try RemoteCoding.decoder.decode(ScrollPayload.self, from: data)
        #expect(decoded.deltaY == 18)
        #expect(decoded.zoom == true)
    }

    @Test("Une image d’écran survit à l’aller-retour")
    func screenFrameRoundTrip() throws {
        let payload = ScreenFramePayload(
            jpegData: Data(repeating: 0x42, count: 1_024),
            width: 1_280,
            height: 800
        )
        let envelope = try RemoteEnvelope.make(
            type: .screenFrame,
            sessionID: "screen",
            sequence: 2,
            payload: payload
        )

        let data = try RemoteCoding.encoder.encode(envelope)
        let decoded = try RemoteCoding.decoder.decode(RemoteEnvelope.self, from: data)
        let frame = try decoded.decodePayload(ScreenFramePayload.self)
        #expect(frame.jpegData == payload.jpegData)
        #expect(frame.width == 1_280)
        #expect(frame.height == 800)
    }

    @Test("Une demande d'approbation d'appairage survit à l'aller-retour")
    func pairingPendingRoundTrip() throws {
        let payload = PairingPendingPayload(
            requestID: UUID(),
            deviceName: "iPhone de test",
            confirmationCode: "123456",
            expiresAt: Date().addingTimeInterval(60)
        )
        let data = try RemoteCoding.encoder.encode(payload)
        let decoded = try RemoteCoding.decoder.decode(PairingPendingPayload.self, from: data)

        #expect(decoded.requestID == payload.requestID)
        #expect(decoded.deviceName == payload.deviceName)
        #expect(decoded.confirmationCode == payload.confirmationCode)
        #expect(abs(decoded.expiresAt.timeIntervalSince(payload.expiresAt)) < 1)
    }

    @Test("Les créneaux de marche conservent leurs horaires")
    func workWalkingSessionsRoundTrip() throws {
        let session = WorkWalkingSession(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_600)
        )
        let payload = WorkWalkingSessionsSnapshotPayload(sessions: [session])
        let data = try RemoteCoding.encoder.encode(payload)
        let decoded = try RemoteCoding.decoder.decode(
            WorkWalkingSessionsSnapshotPayload.self,
            from: data
        )

        #expect(decoded.sessions == [session])
        #expect(decoded.sessions[0].duration == 600)
    }

    @Test("Le résumé Santé ne transporte que les agrégats utiles")
    func healthActivitySnapshotRoundTrip() throws {
        let payload = HealthActivitySnapshotPayload(
            briskWalkingMinutesLast7Days: 182,
            walkingDistanceMetersLast7Days: 9_450,
            detectedWalkingDurationLast7Days: 14_400
        )
        let data = try RemoteCoding.encoder.encode(payload)
        let decoded = try RemoteCoding.decoder.decode(
            HealthActivitySnapshotPayload.self,
            from: data
        )

        #expect(decoded.briskWalkingMinutesLast7Days == 182)
        #expect(decoded.walkingDistanceMetersLast7Days == 9_450)
        #expect(decoded.detectedWalkingDurationLast7Days == 14_400)
    }

    @Test("Tous les types de message ont une valeur brute stable")
    func messageTypesStable() {
        #expect(RemoteMessageType.insertText.rawValue == "insert_text")
        #expect(RemoteMessageType.activateWindow.rawValue == "activate_window")
        #expect(RemoteMessageType.pairingPending.rawValue == "pairing_pending")
        #expect(RemoteMessageType.voiceControl.rawValue == "voice_control")
        #expect(RemoteMessageType.hostShortcutPress.rawValue == "host_shortcut_press")
        #expect(RemoteMessageType.workWalkingSessionsRequest.rawValue == "work_walking_sessions_request")
        #expect(RemoteMessageType.workWalkingSessionsSnapshot.rawValue == "work_walking_sessions_snapshot")
        #expect(RemoteMessageType.healthActivitySnapshotUpdate.rawValue == "health_activity_snapshot_update")
        #expect(RemoteMessageType.allCases.count == 31)
        #expect(ProtocolVersion.current == 4)
    }

    @Test("Le contrôle vocal reste limité aux fournisseurs et phases connus")
    func voiceControlRoundTrip() throws {
        let payload = VoiceControlPayload(provider: .chatGPT, phase: .began)
        let decoded = try RemoteCoding.decoder.decode(
            VoiceControlPayload.self,
            from: RemoteCoding.encoder.encode(payload)
        )

        #expect(decoded == payload)
    }

    @Test("La commande du switcher d'app conserve sa valeur réseau")
    func applicationSwitcherKeyIsStable() throws {
        #expect(RemoteKey.applicationSwitcher.rawValue == "application_switcher")
        let payload = try RemoteCoding.decoder.decode(
            KeyPressPayload.self,
            from: Data(#"{"key":"application_switcher"}"#.utf8)
        )
        #expect(payload.key == .applicationSwitcher)
    }

    @Test("La commande de conversation suivante conserve sa valeur réseau")
    func nextConversationKeyIsStable() throws {
        #expect(RemoteKey.nextConversation.rawValue == "next_conversation")
        let payload = try RemoteCoding.decoder.decode(
            KeyPressPayload.self,
            from: Data(#"{"key":"next_conversation"}"#.utf8)
        )
        #expect(payload.key == .nextConversation)
    }

    @Test("Les appuis répétés restent compatibles avec les anciens messages")
    func keyPressRepeatCountRoundTrip() throws {
        let legacyPayload = try RemoteCoding.decoder.decode(
            KeyPressPayload.self,
            from: Data(#"{"key":"arrow_left"}"#.utf8)
        )
        #expect(legacyPayload.key == .arrowLeft)
        #expect(legacyPayload.repeatCount == 1)

        let payload = KeyPressPayload(key: .arrowRight, repeatCount: 12)
        let decoded = try RemoteCoding.decoder.decode(
            KeyPressPayload.self,
            from: RemoteCoding.encoder.encode(payload)
        )
        #expect(decoded.key == .arrowRight)
        #expect(decoded.repeatCount == 12)
    }

    @Test("La configuration ne transporte qu'une référence de raccourci hôte")
    func controlConfigurationRoundTrip() throws {
        let shortcut = MacKeyboardShortcut(
            keyCode: 40,
            modifiers: [.command, .shift],
            displayName: "⌘⇧K"
        )
        var configuration = ControlConfiguration.standard
        configuration.setButton(ControlButtonConfiguration(
            zone: .upperLeft,
            title: "Mon raccourci",
            icon: .system("command"),
            action: .macShortcut(shortcut)
        ))
        let available = configuration.availableGlobalButtons
        let rightArrow = try #require(available.first(where: { $0.id == "standard.right" }))
        configuration.setAvailableGlobalButtonOrder([rightArrow] + available.filter { $0.id != rightArrow.id })

        let data = try RemoteCoding.encoder.encode(ControlConfigurationPayload(configuration: configuration))
        let decoded = try RemoteCoding.decoder.decode(ControlConfigurationPayload.self, from: data)

        #expect(decoded.configuration.button(in: .upperLeft).title == "Mon raccourci")
        #expect(decoded.configuration.button(in: .upperLeft).action == .hostShortcut(shortcut.migratedDefinition.reference))
        #expect(!String(decoding: data, as: UTF8.self).contains("keyCode"))
        #expect(decoded.configuration.availableGlobalButtons.first?.id == "standard.right")
        #expect(decoded.configuration.availableGlobalButtons.allSatisfy { candidate in
            !decoded.configuration.buttons.contains { $0.action == candidate.action }
        })
        #expect(ControlZone.allCases.count == 7)
    }

    @Test("Le statut V4 annonce la plateforme et les capacités")
    func connectionStatusV4RoundTrip() throws {
        let status = ConnectionStatusPayload(
            inputControlReady: true,
            screenCaptureReady: false,
            hostName: "PC Bureau",
            hostPlatform: .windows,
            capabilities: [.keyboard, .pointer],
            companionVersion: "1.0"
        )
        let decoded = try RemoteCoding.decoder.decode(
            ConnectionStatusPayload.self,
            from: RemoteCoding.encoder.encode(status)
        )
        #expect(decoded == status)
        #expect(decoded.hostPlatform == .windows)
        #expect(decoded.acknowledgesPointerMoves == nil)

        let macStatus = ConnectionStatusPayload(
            inputControlReady: true,
            screenCaptureReady: true,
            hostName: "Mac",
            hostPlatform: .macOS,
            capabilities: [.pointer],
            companionVersion: "1.0.54",
            acknowledgesPointerMoves: true
        )
        let decodedMacStatus = try RemoteCoding.decoder.decode(
            ConnectionStatusPayload.self,
            from: RemoteCoding.encoder.encode(macStatus)
        )
        #expect(decodedMacStatus.acknowledgesPointerMoves == true)
    }

    @Test("Une ancienne configuration reçoit automatiquement l’ordre Global par défaut")
    func legacyControlConfigurationGetsGlobalOrder() throws {
        let encoded = try RemoteCoding.encoder.encode(ControlConfiguration.standard)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "globalButtons")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try RemoteCoding.decoder.decode(ControlConfiguration.self, from: legacyData)

        #expect(decoded.globalButtons == ControlConfiguration.standardGlobalButtons)
        #expect(decoded.availableGlobalButtons.count == 9)
    }
}

@Suite("Anti-rejeu")
struct SequenceValidatorTests {

    private func envelope(sequence: UInt64, id: UUID = UUID()) -> RemoteEnvelope {
        RemoteEnvelope(type: .keyPress, messageID: id, sessionID: "s", sequence: sequence)
    }

    @Test("Une séquence croissante est acceptée")
    func increasingAccepted() {
        var validator = SequenceValidator()
        let first = validator.validate(envelope(sequence: 1))
        let second = validator.validate(envelope(sequence: 2))
        #expect(first == .accepted)
        #expect(second == .accepted)
    }

    @Test("Une séquence ancienne est un rejeu")
    func staleSequenceIsReplay() {
        var validator = SequenceValidator()
        _ = validator.validate(envelope(sequence: 5))
        let verdict = validator.validate(envelope(sequence: 3))
        #expect(verdict == .replay)
    }

    @Test("Une enveloppe V3 est refusée avant tout suivi de séquence")
    func v3EnvelopeIsVersionMismatch() {
        var validator = SequenceValidator()
        let legacy = RemoteEnvelope(
            version: 3,
            type: .keyPress,
            sessionID: "v3",
            sequence: 1
        )

        #expect(validator.validate(legacy) == .versionMismatch)
        #expect(validator.validate(envelope(sequence: 1)) == .accepted)
    }

    @Test("Un identifiant déjà vu est un doublon, pas une seconde exécution")
    func duplicateDetected() {
        var validator = SequenceValidator()
        let id = UUID()
        let first = validator.validate(envelope(sequence: 1, id: id))
        let second = validator.validate(envelope(sequence: 2, id: id))
        #expect(first == .accepted)
        #expect(second == .duplicate(id))
    }
}

@Suite("Idempotence entre sessions")
struct PeerResponseCacheTests {

    @Test("Une réponse est isolée par pair et survit à une reconnexion")
    func responseIsScopedToPeer() {
        var cache = PeerResponseCache()
        let messageID = UUID()
        let response = CachedPeerResponse(type: .acknowledgement, payload: Data("ok".utf8))

        cache.store(response, for: "iphone-a", messageID: messageID)

        #expect(cache.response(for: "iphone-a", messageID: messageID) == response)
        #expect(cache.response(for: "iphone-b", messageID: messageID) == nil)
    }

    @Test("Le cache évince la plus ancienne réponse d’un pair")
    func oldestResponseIsEvicted() {
        var cache = PeerResponseCache(maximumPeers: 2, entriesPerPeer: 2)
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let response = CachedPeerResponse(type: .acknowledgement, payload: Data())

        cache.store(response, for: "iphone", messageID: first)
        cache.store(response, for: "iphone", messageID: second)
        cache.store(response, for: "iphone", messageID: third)

        #expect(cache.response(for: "iphone", messageID: first) == nil)
        #expect(cache.response(for: "iphone", messageID: second) == response)
        #expect(cache.response(for: "iphone", messageID: third) == response)
    }

    @Test("La révocation efface les réponses d’un pair")
    func revokedPeerIsForgotten() {
        var cache = PeerResponseCache()
        let messageID = UUID()
        let response = CachedPeerResponse(type: .acknowledgement, payload: Data())
        cache.store(response, for: "iphone", messageID: messageID)

        cache.removeAll(for: "iphone")

        #expect(cache.response(for: "iphone", messageID: messageID) == nil)
    }
}

@Suite("Limitation de débit")
struct RateLimiterTests {

    @Test("La rafale est bornée par la capacité")
    func burstIsCapped() {
        var limiter = RateLimiter(capacity: 3, refillPerSecond: 1)
        let results = (0..<4).map { _ in limiter.allow() }
        #expect(results == [true, true, true, false])
    }

    @Test("Les jetons se rechargent avec le temps")
    func refills() {
        let start = Date()
        var limiter = RateLimiter(capacity: 2, refillPerSecond: 10, now: start)
        let first = limiter.allow(now: start)
        let second = limiter.allow(now: start)
        let exhausted = limiter.allow(now: start)
        let afterRefill = limiter.allow(now: start.addingTimeInterval(0.5))
        #expect([first, second, exhausted, afterRefill] == [true, true, false, true])
    }
}

@Suite("Appairage")
struct PairingTests {

    private func makePayload(
        expires: Date = Date().addingTimeInterval(120),
        nomadEndpoint: NomadEndpoint? = nil
    ) -> PairingQRPayload {
        PairingQRPayload(
            macName: "Mac de Nicolas",
            serviceName: "appremote-1234",
            certificateFingerprint: SecureRandom.bytes(32).base64EncodedString(),
            pairingSecret: SecureRandom.bytes(16).base64EncodedString(),
            expiresAt: expires,
            nomadEndpoint: nomadEndpoint
        )
    }

    @Test("Le QR Nomade conserve le point d'accès Tailscale")
    func nomadQRRoundTrip() throws {
        let endpoint = NomadEndpoint(
            magicDNSName: "MacBook-Pro.tail1234.ts.net.",
            ipv4Address: "100.105.79.12"
        )
        let payload = makePayload(nomadEndpoint: endpoint)
        let decoded = try PairingQRPayload.decode(try payload.encoded())
        #expect(decoded.nomadEndpoint == endpoint)
        #expect(decoded.nomadEndpoint?.isValid == true)
    }

    @Test("Le QR survit à l'encodage base64")
    func qrRoundTrip() throws {
        let payload = makePayload()
        let decoded = try PairingQRPayload.decode(try payload.encoded())
        // L'égalité stricte n'est pas testée sur la date : l'encodage ISO 8601
        // arrondit à la seconde. Sans effet ici (la fenêtre d'appairage dure
        // deux minutes), mais il ne faut pas prétendre à une identité binaire.
        #expect(decoded.macName == payload.macName)
        #expect(decoded.serviceName == payload.serviceName)
        #expect(decoded.certificateFingerprint == payload.certificateFingerprint)
        #expect(decoded.pairingSecret == payload.pairingSecret)
        #expect(decoded.confirmationCode == payload.confirmationCode)
        #expect(abs(decoded.expiresAt.timeIntervalSince(payload.expiresAt)) < 1)
    }

    @Test("Le QR reste strictement identique entre deux rendus")
    func qrEncodingIsStable() throws {
        let payload = makePayload()
        let encodings = try (0..<20).map { _ in try payload.encoded() }
        #expect(Set(encodings).count == 1)
    }

    @Test("L'ancien format QR reste lisible")
    func legacyQRStillDecodes() throws {
        let payload = makePayload()
        let legacy = try RemoteCoding.encoder.encode(payload).base64EncodedString()
        let decoded = try PairingQRPayload.decode(legacy)
        #expect(decoded.macName == payload.macName)
        #expect(decoded.confirmationCode == payload.confirmationCode)
    }

    @Test("Le QR compact est plus court que l'ancien format")
    func compactQRIsShorter() throws {
        let payload = makePayload()
        let legacy = try RemoteCoding.encoder.encode(payload).base64EncodedString()
        #expect(try payload.encoded().count < legacy.count)
    }

    @Test("Le code de confirmation fait six chiffres et est déterministe")
    func confirmationCode() {
        let payload = makePayload()
        #expect(payload.confirmationCode.count == 6)
        #expect(payload.confirmationCode == payload.confirmationCode)
    }

    @Test("Deux QR différents donnent des codes différents")
    func confirmationCodesDiffer() {
        #expect(makePayload().confirmationCode != makePayload().confirmationCode)
    }

    @Test("Un QR périmé est détecté")
    func expiryDetected() {
        #expect(makePayload(expires: Date().addingTimeInterval(-1)).isExpired)
        #expect(makePayload().isExpired == false)
    }

    @Test("Un QR illisible échoue explicitement")
    func invalidQRThrows() {
        #expect(throws: RemoteErrorPayload.self) {
            _ = try PairingQRPayload.decode("pas du base64 !!!")
        }
    }

    @Test("Le QR rejette une empreinte ou un secret de mauvaise taille")
    func malformedPairingMaterialIsRejected() throws {
        let payload = PairingQRPayload(
            hostName: "PC Bureau",
            hostPlatform: .windows,
            serviceName: "VibeRemote-PC",
            certificateFingerprint: "cGFzLXVuLXNoYTI1Ng==",
            pairingSecret: SecureRandom.bytes(16).base64EncodedString(),
            expiresAt: Date().addingTimeInterval(120)
        )
        do {
            _ = try PairingQRPayload.decode(try payload.encoded())
            Issue.record("Le QR doit être refusé")
        } catch let error as RemoteErrorPayload {
            #expect(error.code == .protocolMismatch)
        }
    }
}

@Suite("Signature du défi")
struct ChallengeSignerTests {

    @Test("Une signature valide est acceptée")
    func validSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let nonce = SecureRandom.bytes(32)
        let signature = try ChallengeSigner.sign(
            nonce: nonce,
            deviceIdentifier: "iphone-1",
            pairingSecret: nil,
            privateKey: key
        )

        #expect(ChallengeSigner.verify(
            signature: signature,
            nonce: nonce,
            deviceIdentifier: "iphone-1",
            pairingSecret: nil,
            publicKeyRepresentation: key.publicKey.rawRepresentation
        ))
    }

    @Test("Une signature rejouée avec un autre nonce est refusée")
    func replayedNonceRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try ChallengeSigner.sign(
            nonce: SecureRandom.bytes(32),
            deviceIdentifier: "iphone-1",
            pairingSecret: nil,
            privateKey: key
        )

        #expect(ChallengeSigner.verify(
            signature: signature,
            nonce: SecureRandom.bytes(32),
            deviceIdentifier: "iphone-1",
            pairingSecret: nil,
            publicKeyRepresentation: key.publicKey.rawRepresentation
        ) == false)
    }

    @Test("La clé d'un autre appareil ne valide pas la signature")
    func otherKeyRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let attacker = Curve25519.Signing.PrivateKey()
        let nonce = SecureRandom.bytes(32)
        let signature = try ChallengeSigner.sign(
            nonce: nonce,
            deviceIdentifier: "iphone-1",
            pairingSecret: nil,
            privateKey: key
        )

        #expect(ChallengeSigner.verify(
            signature: signature,
            nonce: nonce,
            deviceIdentifier: "iphone-1",
            pairingSecret: nil,
            publicKeyRepresentation: attacker.publicKey.rawRepresentation
        ) == false)
    }

    @Test("Un identifiant d'appareil substitué invalide la signature")
    func identitySubstitutionRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let nonce = SecureRandom.bytes(32)
        let signature = try ChallengeSigner.sign(
            nonce: nonce,
            deviceIdentifier: "iphone-1",
            pairingSecret: nil,
            privateKey: key
        )

        #expect(ChallengeSigner.verify(
            signature: signature,
            nonce: nonce,
            deviceIdentifier: "iphone-2",
            pairingSecret: nil,
            publicKeyRepresentation: key.publicKey.rawRepresentation
        ) == false)
    }
}

@Suite("Politique de reconnexion")
struct RetryPolicyTests {

    @Test("Le délai croît puis plafonne")
    func backoffGrowsAndCaps() {
        var policy = RetryPolicy(base: 1, maximum: 10)
        let first = policy.nextDelay()
        var last = first
        for _ in 0..<10 { last = policy.nextDelay() }
        #expect(first < 3)
        #expect(last <= 10)
    }

    @Test("Une connexion réussie remet le compteur à zéro")
    func resetClearsAttempts() {
        var policy = RetryPolicy()
        _ = policy.nextDelay()
        _ = policy.nextDelay()
        policy.reset()
        #expect(policy.attemptCount == 0)
    }
}
