import Foundation
import AppKit
import RemoteCore

/// Exécute les commandes d'une session authentifiée.
///
/// Le routeur est la seule porte d'entrée vers les actions réelles. Chaque
/// commande passe par la validation de séquence, la limitation de débit, puis
/// une méthode dédiée : il n'existe pas de chemin générique qui exécuterait
/// une chaîne venue du réseau.
@MainActor
final class SessionRouter {

    private let targets = TargetTracker()
    private let insertion = TextInsertionCoordinator()
    private let windows = WindowCatalog()

    private var validator = SequenceValidator()
    private var gestureLimiter = RateLimiter(capacity: 240, refillPerSecond: 180)
    private var commandLimiter = RateLimiter(capacity: 40, refillPerSecond: 20)
    private var acknowledgements: [UUID: AcknowledgementPayload] = [:]

    let peerID: String
    let sessionID: String

    init(peerID: String, sessionID: String) {
        self.peerID = peerID
        self.sessionID = sessionID
    }

    enum Outcome {
        case acknowledge(AcknowledgementPayload)
        /// Accusé léger, propre à la session : il confirme au téléphone que le
        /// geste a réellement été injecté, sans remplir les caches de commandes.
        case gestureAcknowledged
        case snapshot(WindowsSnapshotPayload)
        case screenRequest(ScreenStreamRequestPayload)
        case controlConfigurationRequest
        case controlConfigurationUpdate(ControlConfiguration)
        case workWalkingSessionsRequest(Date)
        case healthActivitySnapshotUpdate(HealthActivitySnapshotPayload)
        case hostShortcutPress(String)
        case voiceControl(VoiceControlPayload)
        case failure(RemoteErrorPayload)
        case ignore
    }

    func handle(_ envelope: RemoteEnvelope) -> Outcome {
        guard envelope.version == ProtocolVersion.current else {
            return .failure(RemoteErrorPayload(code: .versionMismatch))
        }

        switch validator.validate(envelope) {
        case .versionMismatch:
            return .failure(RemoteErrorPayload(code: .versionMismatch))
        case .replay:
            return .failure(RemoteErrorPayload(code: .replayDetected))
        case .duplicate(let id):
            // Une commande renvoyée après une perte d'accusé ne doit jamais
            // être exécutée deux fois : on rejoue seulement la réponse.
            if let previous = acknowledgements[id] { return .acknowledge(previous) }
            return .ignore
        case .accepted:
            break
        }

        // Les flèches générées par le trackpad de la barre Espace arrivent à
        // la cadence d'affichage. Elles doivent emprunter le budget des gestes
        // continus, sinon le limiteur des commandes (20/s) les saccade après
        // quelques instants. Les touches restent des valeurs fermées et leur
        // répétition est bornée avant injection.
        let isGesture = [
            .pointerMove, .pointerAbsolute, .pointerDrag, .scroll, .keyPress
        ].contains(envelope.type)
        let allowed = isGesture ? gestureLimiter.allow() : commandLimiter.allow()
        guard allowed else {
            return .failure(RemoteErrorPayload(code: .rateLimited))
        }

        do {
            return try execute(envelope)
        } catch let error as RemoteErrorPayload {
            return .failure(error)
        } catch {
            // System error strings can embed focused-app or window context.
            // The client only needs a stable, non-sensitive failure category.
            return .failure(RemoteErrorPayload(code: .internalFailure, detail: "internal_failure"))
        }
    }

    private func execute(_ envelope: RemoteEnvelope) throws -> Outcome {
        switch envelope.type {
        case .hello:
            // Battement de cœur authentifié. Il permet à l’iPhone de détecter
            // une socket silencieusement morte après veille ou mise à jour.
            _ = try? envelope.decodePayload(HelloPayload.self)
            return record(envelope, AcknowledgementPayload(ok: true))

        case .recordingStarted:
            let target = try targets.capture()
            let token = TargetToken(
                token: target.token,
                applicationName: target.applicationName,
                bundleIdentifier: target.bundleIdentifier,
                windowTitle: target.windowTitle,
                expiresAt: target.expiresAt
            )
            return record(envelope, AcknowledgementPayload(ok: true, targetToken: token))

        case .insertText:
            let payload = try envelope.decodePayload(InsertTextPayload.self)
            let target = try targets.resolve(token: payload.targetToken)
            // Mirror the Windows companion: once a valid token has been
            // resolved, no retry may reuse it after an insertion failure.
            defer { targets.consume() }
            let result = try insertion.insert(payload.text, into: target)
            return record(envelope, AcknowledgementPayload(ok: true, insertion: result))

        case .cancel:
            targets.consume()
            return record(envelope, AcknowledgementPayload(ok: true))

        case .keyboardText:
            let payload = try envelope.decodePayload(KeyboardTextPayload.self)
            guard payload.text.count <= 512 else {
                throw RemoteErrorPayload(code: .payloadTooLarge)
            }
            let result = try insertion.typeManually(payload.text, userInitiated: payload.userInitiated)
            return record(envelope, AcknowledgementPayload(ok: true, insertion: result))

        case .keyPress:
            let payload = try envelope.decodePayload(KeyPressPayload.self)
            CGEventFactory.press(
                payload.key,
                repeatCount: ControlInputPolicy.keyRepeatCount(payload.repeatCount)
            )
            return record(envelope, AcknowledgementPayload(ok: true))

        case .voiceControl:
            let payload = try envelope.decodePayload(VoiceControlPayload.self)
            guard AccessibilityClient.isTrusted else {
                if payload.phase == .began {
                    AccessibilityClient.requestTrust()
                    AccessibilityClient.openAccessibilitySettings()
                }
                NSLog("[VibeWalkie] voice_control_permission_denied")
                throw RemoteErrorPayload(code: .permissionAccessibilityDenied)
            }
            return .voiceControl(payload)

        case .hostShortcutPress:
            let payload = try envelope.decodePayload(HostShortcutPressPayload.self)
            guard !payload.shortcutID.isEmpty else {
                throw RemoteErrorPayload(code: .unsupportedCapability, detail: "Raccourci clavier invalide")
            }
            return .hostShortcutPress(payload.shortcutID)

        case .controlConfigurationRequest:
            return .controlConfigurationRequest

        case .controlConfigurationUpdate:
            let payload = try envelope.decodePayload(ControlConfigurationPayload.self)
            return .controlConfigurationUpdate(payload.configuration)

        case .pointerMove:
            let payload = try envelope.decodePayload(PointerMovePayload.self)
            CGEventFactory.move(
                deltaX: try ControlInputPolicy.gestureDelta(payload.deltaX),
                deltaY: try ControlInputPolicy.gestureDelta(payload.deltaY)
            )
            return .gestureAcknowledged

        case .pointerAbsolute:
            let payload = try envelope.decodePayload(PointerAbsolutePayload.self)
            CGEventFactory.moveAbsolute(
                normalizedX: try ControlInputPolicy.normalizedCoordinate(payload.normalizedX),
                normalizedY: try ControlInputPolicy.normalizedCoordinate(payload.normalizedY)
            )
            return .ignore

        case .pointerClick:
            let payload = try envelope.decodePayload(PointerClickPayload.self)
            CGEventFactory.click(button: payload.button, clickCount: payload.clickCount)
            return record(envelope, AcknowledgementPayload(ok: true))

        case .pointerDrag:
            let payload = try envelope.decodePayload(PointerDragPayload.self)
            CGEventFactory.drag(
                phase: payload.phase,
                deltaX: try ControlInputPolicy.gestureDelta(payload.deltaX),
                deltaY: try ControlInputPolicy.gestureDelta(payload.deltaY)
            )
            return .ignore

        case .scroll:
            let payload = try envelope.decodePayload(ScrollPayload.self)
            let deltaX = try ControlInputPolicy.gestureDelta(payload.deltaX)
            let deltaY = try ControlInputPolicy.gestureDelta(payload.deltaY)
            if payload.zoom == true {
                CGEventFactory.zoom(deltaY: deltaY)
            } else {
                CGEventFactory.scroll(deltaX: deltaX, deltaY: deltaY)
            }
            return .ignore

        case .listWindows:
            let payload = (try? envelope.decodePayload(ListWindowsPayload.self)) ?? ListWindowsPayload()
            return .snapshot(windows.snapshot(includeIcons: payload.includeIcons))

        case .activateWindow:
            let payload = try envelope.decodePayload(ActivateWindowPayload.self)
            try windows.activate(applicationID: payload.applicationID, windowID: payload.windowID)
            return record(envelope, AcknowledgementPayload(ok: true))

        case .screenStreamRequest:
            return .screenRequest(try envelope.decodePayload(ScreenStreamRequestPayload.self))

        case .workWalkingSessionsRequest:
            let payload = try envelope.decodePayload(WorkWalkingSessionsRequestPayload.self)
            return .workWalkingSessionsRequest(payload.since)

        case .healthActivitySnapshotUpdate:
            let payload = try envelope.decodePayload(HealthActivitySnapshotPayload.self)
            let briskMinutesAreValid = payload.briskWalkingMinutesLast7Days.map {
                $0.isFinite && (0...10_080).contains($0)
            } ?? true
            let capturedAtIsPlausible = payload.capturedAt >= Date().addingTimeInterval(-7 * 86_400)
                && payload.capturedAt <= Date().addingTimeInterval(3_600)
            guard briskMinutesAreValid,
                  payload.walkingDistanceMetersLast7Days.isFinite,
                  (0...1_000_000).contains(payload.walkingDistanceMetersLast7Days),
                  payload.detectedWalkingDurationLast7Days.isFinite,
                  (0...604_800).contains(payload.detectedWalkingDurationLast7Days),
                  capturedAtIsPlausible else {
                throw RemoteErrorPayload(code: .protocolMismatch)
            }
            return .healthActivitySnapshotUpdate(payload)

        case .pairingChallenge, .pairingResponse, .pairingPending, .acknowledgement,
             .connectionStatus, .error, .windowsSnapshot, .screenStreamStatus,
             .screenFrame, .controlConfigurationSnapshot, .workWalkingSessionsSnapshot:
            return .ignore
        }
    }

    private func record(_ envelope: RemoteEnvelope, _ payload: AcknowledgementPayload) -> Outcome {
        acknowledgements[envelope.messageID] = payload
        if acknowledgements.count > 128 {
            acknowledgements.removeAll(keepingCapacity: true)
        }
        return .acknowledge(payload)
    }

}
