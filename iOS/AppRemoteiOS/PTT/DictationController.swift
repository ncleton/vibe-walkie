import SwiftUI
import RemoteCore

@MainActor
protocol DictationTransport: AnyObject {
    func send<T: Encodable>(type: RemoteMessageType, payload: T) async throws -> RemoteEnvelope
}

extension HostConnectionClient: DictationTransport {}

/// Orchestration d'une dictée transactionnelle : la cible et le micro sont
/// préparés en parallèle, puis le texte n'est annoncé livré qu'après l'accusé
/// du Mac. Le parallélisme est indispensable pour ne pas perdre les premiers
/// mots pendant l'aller-retour réseau qui capture le champ cible.
@MainActor
final class DictationController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording
        case armedForCancel
        case finalizing
        case sending
        case delivered(String)
        case sentUnverified(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var partialText = ""
    @Published private(set) var level: CGFloat = 0

    private let client: any DictationTransport
    private var engine: (any SpeechEngine)?
    private var dictationLocaleIdentifier: String
    private var engineLocaleIdentifier: String?
    private var enginePreparation: EnginePreparation?
    private var dictationID = UUID()
    private var targetToken: TargetToken?
    private var captureTask: Task<Void, Never>?
    private var partialsTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var releaseRequested = false

    private struct EnginePreparation {
        let id: UUID
        let localeIdentifier: String
        let task: Task<Void, Error>
    }

    private static let cancelThreshold: CGFloat = -70

    init(
        client: any DictationTransport,
        engine: (any SpeechEngine)? = nil,
        localeIdentifier: String = DictationLanguage.deviceLocaleIdentifier
    ) {
        self.client = client
        self.engine = engine
        dictationLocaleIdentifier = localeIdentifier
        engineLocaleIdentifier = engine == nil ? nil : localeIdentifier
    }

    var isRecording: Bool {
        phase == .recording || phase == .armedForCancel
    }

#if DEBUG
    func configureMarketingRecording() {
        partialText = AppL10n.text("ios.control.the.pointer.keyboard.and.dictation.from.this.iphone.no.2d4c813")
        level = 0.72
        phase = .recording
    }

    func configureMarketingDelivered() {
        partialText = ""
        level = 0
        phase = .delivered(AppL10n.format("ios.written.in.value.5e6ee32", "Notes"))
    }
#endif

    func prepareEngine(localeIdentifier: String) async {
        guard #available(iOS 26.0, *) else {
            phase = .failed(AppL10n.text("ios.on.device.transcription.is.unavailable.on.this.device.8f2dc9f"))
            return
        }
        if isRecording || phase == .finalizing || phase == .sending { return }
        dictationLocaleIdentifier = localeIdentifier
        do {
            _ = try await ensureEnginePrepared(localeIdentifier: localeIdentifier)
        } catch is CancellationError {
            // Une nouvelle langue ou la fermeture de la vue a remplacé cette
            // préparation. Le prochain démarrage attendra la tâche courante.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func pressBegan() {
        guard !isRecording, phase != .finalizing, phase != .sending else { return }
        resetTask?.cancel()
        captureTask?.cancel()
        HapticFeedback.shared.prepare()
        partialText = ""
        dictationID = UUID()
        targetToken = nil
        releaseRequested = false
        phase = .recording

        let currentID = dictationID
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let requestedToken = requestTarget(for: currentID)
                try await startCapture()
                let token = try await requestedToken
                guard !Task.isCancelled, isRecording, dictationID == currentID else {
                    await engine?.cancel()
                    await cancelRemoteTarget(for: currentID)
                    return
                }
                targetToken = token
            } catch is CancellationError {
                await engine?.cancel()
                await cancelRemoteTarget(for: currentID)
            } catch let error as RemoteErrorPayload {
                await engine?.cancel()
                await fail(AppL10n.remoteError(error.code))
            } catch {
                await engine?.cancel()
                await fail(error.localizedDescription)
            }
        }
    }

    func pressMoved(_ translation: CGPoint) {
        guard isRecording, !releaseRequested else { return }
        let armed = translation.x < Self.cancelThreshold
        if armed && phase != .armedForCancel {
            phase = .armedForCancel
            HapticFeedback.shared.armedForCancel()
        } else if !armed && phase == .armedForCancel {
            phase = .recording
            HapticFeedback.shared.tick()
        }
    }

    func pressEnded() {
        guard isRecording, !releaseRequested else { return }
        if phase == .armedForCancel {
            cancelDictation(reason: AppL10n.text("ios.close.711e5f2"))
            return
        }
        HapticFeedback.shared.recordingReleased()
        releaseRequested = true
        let currentID = dictationID
        let startupTask = captureTask
        Task { [weak self] in
            await startupTask?.value
            guard let self,
                  self.dictationID == currentID,
                  self.releaseRequested,
                  self.isRecording else { return }
            self.captureTask = nil
            self.finishAndSend()
        }
    }

    func pressCancelled() {
        guard isRecording else { return }
        cancelDictation(reason: AppL10n.text("ios.close.711e5f2"))
    }

    /// Affiche une erreur provenant d'un contrôle distant qui ne passe pas
    /// par le moteur de dictée Apple (ChatGPT ou Claude).
    func reportRemoteControlFailure(_ message: String) {
        resetTask?.cancel()
        HapticFeedback.shared.failed()
        phase = .failed(message)
        scheduleReset()
    }

    private func requestTarget(for id: UUID) async throws -> TargetToken {
        let response = try await client.send(
            type: .recordingStarted,
            payload: RecordingStartedPayload(locale: dictationLocaleIdentifier, dictationID: id)
        )
        let ack = try response.decodePayload(AcknowledgementPayload.self)
        guard let token = ack.targetToken else {
            throw RemoteErrorPayload(code: .noFocusedTarget)
        }
        return token
    }

    private func startCapture() async throws {
        let engine = try await ensureEnginePrepared(localeIdentifier: dictationLocaleIdentifier)
        let stream = try await engine.start()
        guard !Task.isCancelled, isRecording else {
            await engine.cancel()
            throw CancellationError()
        }
        HapticFeedback.shared.recordingStarted()
        partialsTask = Task { [weak self] in
            for await update in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.partialText = update.text }
            }
        }
    }

    private func finishAndSend() {
        releaseRequested = false
        phase = .finalizing
        let currentID = dictationID
        let token = targetToken
        Task { [weak self] in
            guard let self else { return }
            guard let engine else {
                await fail(SpeechEngineError.notPrepared.localizedDescription)
                return
            }
            let update: SpeechUpdate
            do {
                update = try await engine.finish()
            } catch {
                partialsTask?.cancel()
                partialsTask = nil
                await cancelRemoteTarget(for: currentID)
                await fail(error.localizedDescription)
                return
            }
            partialsTask?.cancel()
            partialsTask = nil

            let finalText = update.finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            partialText = finalText
            guard !finalText.isEmpty else {
                await cancelRemoteTarget(for: currentID)
                await fail(AppL10n.text("ios.no.speech.detected.61bb54a"))
                return
            }
            guard let token else {
                await fail(AppL10n.text("ios.no.active.text.field.on.the.mac.880e867"))
                return
            }

            phase = .sending
            do {
                let response = try await client.send(
                    type: .insertText,
                    payload: InsertTextPayload(targetToken: token.token, text: finalText, dictationID: currentID)
                )
                let ack = try response.decodePayload(AcknowledgementPayload.self)
                guard ack.ok, let insertion = ack.insertion else {
                    throw RemoteErrorPayload(code: .internalFailure, detail: "accusé incomplet")
                }
                if insertion.verified {
                    HapticFeedback.shared.delivered()
                    phase = .delivered(AppL10n.format("ios.written.in.value.5e6ee32", insertion.applicationName))
                } else {
                    phase = .sentUnverified(AppL10n.format("ios.sent.to.value.check.the.field.8ae889d", insertion.applicationName))
                }
                scheduleReset()
            } catch let error as RemoteErrorPayload {
                await fail(AppL10n.remoteError(error.code))
            } catch {
                await fail(AppL10n.text("ios.delivery.not.confirmed.check.the.active.field.e0e5a15"))
            }
        }
    }

    private func cancelDictation(reason: String) {
        releaseRequested = false
        captureTask?.cancel()
        captureTask = nil
        partialsTask?.cancel()
        partialsTask = nil
        partialText = ""
        let currentID = dictationID

        Task { [weak self] in
            guard let self else { return }
            await engine?.cancel()
            await cancelRemoteTarget(for: currentID)
            phase = .failed(reason)
            scheduleReset()
        }
    }

    private func cancelRemoteTarget(for id: UUID) async {
        guard targetToken != nil || dictationID == id else { return }
        _ = try? await client.send(type: .cancel, payload: CancelPayload(dictationID: id))
        targetToken = nil
    }

    private func fail(_ message: String) async {
        releaseRequested = false
        HapticFeedback.shared.failed()
        phase = .failed(message)
        scheduleReset()
    }

    private func scheduleReset() {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.phase = .idle
                self?.partialText = ""
                self?.targetToken = nil
            }
        }
    }

    /// Retourne un moteur réellement préparé. La préchauffe lancée par la vue
    /// et un appui utilisateur partagent la même tâche : un appui immédiat
    /// après l'ouverture attend donc le modèle Apple au lieu d'échouer avec
    /// `notPrepared`.
    private func ensureEnginePrepared(localeIdentifier: String) async throws -> any SpeechEngine {
        if let engine,
           engineLocaleIdentifier == localeIdentifier,
           engine.isAvailable {
            return engine
        }

        if let preparation = enginePreparation,
           preparation.localeIdentifier == localeIdentifier {
            return try await resolve(preparation)
        }

        enginePreparation?.task.cancel()

        let candidate: any SpeechEngine
        if let engine, engineLocaleIdentifier == localeIdentifier {
            candidate = engine
        } else {
            guard #available(iOS 26.0, *) else {
                throw SpeechEngineError.unsupportedDevice
            }
            await engine?.cancel()
            candidate = AppleSpeechAnalyzerEngine(localeIdentifier: localeIdentifier)
        }

        engine = candidate
        engineLocaleIdentifier = localeIdentifier
        let preparation = EnginePreparation(
            id: UUID(),
            localeIdentifier: localeIdentifier,
            task: Task { @MainActor in
                try await candidate.prepare()
            }
        )
        enginePreparation = preparation
        return try await resolve(preparation)
    }

    private func resolve(_ preparation: EnginePreparation) async throws -> any SpeechEngine {
        do {
            try await preparation.task.value
            if enginePreparation?.id == preparation.id {
                enginePreparation = nil
            }
            if let engine,
               engineLocaleIdentifier == preparation.localeIdentifier,
               engine.isAvailable {
                return engine
            }
            throw CancellationError()
        } catch {
            if enginePreparation?.id == preparation.id {
                enginePreparation = nil
            }
            throw error
        }
    }

}
