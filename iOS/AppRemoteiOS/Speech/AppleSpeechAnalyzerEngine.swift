import Foundation
@preconcurrency import AVFoundation
import Speech
import RemoteCore

/// Dictée locale multilingue avec l'API moderne d'iOS 26.
///
/// Les hypothèses volatiles sont uniquement affichées sur l'iPhone. Seuls
/// les résultats finalisés, qui ne peuvent plus être révisés par Apple, sont
/// publiés dans `finalizedText` et peuvent donc être envoyés au Mac.
@available(iOS 26.0, *)
@MainActor
final class AppleSpeechAnalyzerEngine: SpeechEngine {

    private let requestedLocale: Locale
    private let audioEngine = AVAudioEngine()

    private var preparedLocale: Locale?
    private var preparedTranscriberKind: AppleSpeechTranscriberKind?
    private var analyzer: SpeechAnalyzer?
    private var audioConverter: AnalyzerAudioConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var recognitionState: AnalyzerRecognitionState?
    private var tapInstalled = false
    /// Invalide un démarrage suspendu dans la demande d'autorisation micro.
    private var captureGeneration: UInt64 = 0

    private(set) var isAvailable = false
    @Published private(set) var level: CGFloat = 0

    init(localeIdentifier: String) {
        requestedLocale = Locale(identifier: localeIdentifier)
    }

    /// Vérification légère utilisée par les réglages. La préparation complète
    /// refait ce contrôle puis inspecte/installe l'asset Apple local.
    static func supportsLocale(identifier: String) async -> Bool {
        let requestedLocale = Locale(identifier: identifier)
        for kind in AppleSpeechTranscriberKind.candidates(
            speechTranscriberIsAvailable: SpeechTranscriber.isAvailable
        ) {
            if await kind.supportedLocale(equivalentTo: requestedLocale) != nil {
                return true
            }
        }
        return false
    }

    func prepare() async throws {
        isAvailable = false
        preparedLocale = nil
        preparedTranscriberKind = nil

        var foundSupportedLocale = false
        var lastPreparationError: Error?

        for kind in AppleSpeechTranscriberKind.candidates(
            speechTranscriberIsAvailable: SpeechTranscriber.isAvailable
        ) {
            guard let locale = await kind.supportedLocale(equivalentTo: requestedLocale) else {
                continue
            }
            foundSupportedLocale = true

            let transcriber = kind.makeTranscriber(locale: locale)
            do {
                guard await AssetInventory.status(forModules: [transcriber.module]) != .unsupported else {
                    continue
                }
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber.module]
                ) {
                    try await request.downloadAndInstall()
                }

                preparedLocale = locale
                preparedTranscriberKind = kind
                isAvailable = true
                return
            } catch {
                // Le nouveau modèle peut être annoncé disponible alors que son
                // asset ne peut pas être préparé sur ce matériel. La dictée
                // système reste alors un secours local et privé.
                lastPreparationError = error
            }
        }

        if let lastPreparationError { throw lastPreparationError }
        if foundSupportedLocale { throw SpeechEngineError.unsupportedDevice }
        throw SpeechEngineError.localeUnavailable(requestedLocale.identifier)
    }

    func start() async throws -> AsyncStream<SpeechUpdate> {
        guard isAvailable,
              let preparedLocale,
              let preparedTranscriberKind else {
            throw SpeechEngineError.notPrepared
        }
        captureGeneration &+= 1
        let generation = captureGeneration
        guard await Self.requestMicrophone() else { throw SpeechEngineError.microphoneDenied }
        guard generation == captureGeneration else { throw CancellationError() }

        await discardCurrentRecognition()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        let transcriber = preparedTranscriberKind.makeTranscriber(locale: preparedLocale)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber.module],
            considering: naturalFormat
        ), let converter = AnalyzerAudioConverter(
            inputFormat: naturalFormat,
            outputFormat: analyzerFormat
        ) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw SpeechEngineError.unsupportedDevice
        }
        guard generation == captureGeneration else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CancellationError()
        }

        let (updates, updateContinuation) = AsyncStream<SpeechUpdate>.makeStream()
        let state = AnalyzerRecognitionState(continuation: updateContinuation)
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber.module])

        recognitionState = state
        inputContinuation = continuation
        self.analyzer = analyzer
        audioConverter = converter
        resultsTask = transcriber.makeResultsTask(state: state)

        do {
            // Ouvrir le micro avant les derniers awaits de SpeechAnalyzer.
            // `inputs` bufferise les AnalyzerInput tant que l'analyseur n'a
            // pas encore commencé à les consommer : les premiers mots sont
            // ainsi conservés au lieu d'être prononcés pendant sa préparation.
            inputNode.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: naturalFormat,
                block: Self.makeAudioTap(converter: converter, continuation: continuation)
            )
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()

            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            guard generation == captureGeneration else { throw CancellationError() }
            try await analyzer.start(inputSequence: inputs)
            guard generation == captureGeneration else { throw CancellationError() }
        } catch {
            await discardCurrentRecognition()
            throw error
        }

        return updates
    }

    func finish() async throws -> SpeechUpdate {
        captureGeneration &+= 1
        stopAudioCapture()
        if let audioConverter, let inputContinuation {
            for buffer in audioConverter.flush() {
                inputContinuation.yield(AnalyzerInput(buffer: buffer))
            }
        }
        inputContinuation?.finish()
        inputContinuation = nil

        var finalizationError: Error?
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                finalizationError = error
                await analyzer.cancelAndFinishNow()
            }
        }
        await resultsTask?.value

        let final = recognitionState?.finalUpdate ?? .empty
        clearRecognitionReferences()
        if final.finalizedText.isEmpty, let finalizationError {
            throw finalizationError
        }
        return final
    }

    func cancel() async {
        captureGeneration &+= 1
        await discardCurrentRecognition()
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func discardCurrentRecognition() async {
        stopAudioCapture()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        resultsTask?.cancel()
        await resultsTask?.value
        recognitionState?.finish()
        clearRecognitionReferences()
    }

    private func clearRecognitionReferences() {
        resultsTask = nil
        analyzer = nil
        audioConverter = nil
        recognitionState = nil
        inputContinuation = nil
    }

    nonisolated private static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated private static func makeAudioTap(
        converter: AnalyzerAudioConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let converted = converter.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }
}

enum AppleSpeechTranscriberKind: Equatable {
    case speechTranscriber
    case dictationTranscriber

    static func candidates(speechTranscriberIsAvailable: Bool) -> [Self] {
        speechTranscriberIsAvailable
            ? [.speechTranscriber, .dictationTranscriber]
            : [.dictationTranscriber]
    }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        switch self {
        case .speechTranscriber:
            await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        case .dictationTranscriber:
            await DictationTranscriber.supportedLocale(equivalentTo: locale)
        }
    }

    func makeTranscriber(locale: Locale) -> AppleAnalyzerTranscriber {
        switch self {
        case .speechTranscriber:
            .speech(
                SpeechTranscriber(
                    locale: locale,
                    preset: .progressiveTranscription
                )
            )
        case .dictationTranscriber:
            .dictation(
                DictationTranscriber(
                    locale: locale,
                    preset: .progressiveShortDictation
                )
            )
        }
    }
}

enum AppleAnalyzerTranscriber {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var module: any SpeechModule {
        switch self {
        case .speech(let transcriber): transcriber
        case .dictation(let transcriber): transcriber
        }
    }

    func makeResultsTask(state: AnalyzerRecognitionState) -> Task<Void, Never> {
        switch self {
        case .speech(let transcriber):
            Task.detached(priority: .userInitiated) {
                await Self.consume(transcriber: transcriber, state: state)
            }
        case .dictation(let transcriber):
            Task.detached(priority: .userInitiated) {
                await Self.consume(transcriber: transcriber, state: state)
            }
        }
    }

    private static func consume(
        transcriber: SpeechTranscriber,
        state: AnalyzerRecognitionState
    ) async {
        do {
            for try await result in transcriber.results {
                state.receive(
                    text: String(result.text.characters),
                    isFinal: result.isFinal
                )
            }
        } catch {
            // La finalisation/cancellation ferme aussi le flux. L'état déjà
            // finalisé reste exploitable et ne doit pas être effacé.
        }
        state.finish()
    }

    private static func consume(
        transcriber: DictationTranscriber,
        state: AnalyzerRecognitionState
    ) async {
        do {
            for try await result in transcriber.results {
                state.receive(
                    text: String(result.text.characters),
                    isFinal: result.isFinal
                )
            }
        } catch {
            // La finalisation/cancellation ferme aussi le flux. L'état déjà
            // finalisé reste exploitable et ne doit pas être effacé.
        }
        state.finish()
    }
}

/// Convertisseur possédé exclusivement par le callback audio. Chaque sortie
/// est un nouveau buffer : SpeechAnalyzer ne reçoit jamais le buffer réutilisé
/// par `AVAudioEngine`.
private final class AnalyzerAudioConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()

    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(capacity, 1)
        ) else { return nil }

        let supply = ConverterInputSupply(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supply.wasConsumed else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supply.wasConsumed = true
            inputStatus.pointee = .haveData
            return supply.buffer
        }

        guard conversionError == nil, status != .error, output.frameLength > 0 else {
            return nil
        }
        return output
    }

    /// Rend les quelques échantillons que le changement de fréquence peut
    /// encore retenir lorsque l'utilisateur relâche le bouton.
    func flush() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }

        var outputs: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 4096
            ) else { break }

            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if output.frameLength > 0 { outputs.append(output) }
            if conversionError != nil || status != .haveData { break }
        }
        return outputs
    }
}

private final class ConverterInputSupply: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasConsumed = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// Agrège les phrases dans l'ordre garanti par les transcripteurs Apple.
/// Pendant l'écoute, `finalizedText` ne fait qu'augmenter. Une fois que
/// `SpeechAnalyzer` a fini de consommer l'entrée, sa dernière hypothèse est
/// définitive même si le flux n'a pas envoyé un dernier drapeau `isFinal`.
final class AnalyzerRecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var finalizedText = ""
    private var latestUpdate = SpeechUpdate.empty
    private var isFinished = false
    private var continuation: AsyncStream<SpeechUpdate>.Continuation?

    init(continuation: AsyncStream<SpeechUpdate>.Continuation) {
        self.continuation = continuation
    }

    var finalUpdate: SpeechUpdate {
        lock.lock()
        defer { lock.unlock() }
        let completedText = isFinished ? latestUpdate.text : finalizedText
        return SpeechUpdate(text: completedText, finalizedText: completedText)
    }

    func receive(text: String, isFinal: Bool) {
        guard !text.isEmpty else { return }

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        if isFinal {
            finalizedText = Self.join(finalizedText, text)
            latestUpdate = SpeechUpdate(text: finalizedText, finalizedText: finalizedText)
        } else {
            latestUpdate = SpeechUpdate(
                text: Self.join(finalizedText, text),
                finalizedText: finalizedText
            )
        }
        let update = latestUpdate
        let continuation = continuation
        lock.unlock()
        continuation?.yield(update)
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }

    private static func join(_ prefix: String, _ suffix: String) -> String {
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }

        // Les transcripteurs Apple peuvent publier deux fois le même segment
        // final ou remplacer un résultat final par sa version cumulative. Ces
        // cas ne sont pas deux paroles : conserver la version la plus complète
        // évite d'envoyer la phrase en double au Mac.
        if prefix == suffix || prefix.hasSuffix(suffix) { return prefix }
        if suffix.hasPrefix(prefix) { return suffix }

        guard prefix.last?.isWhitespace != true, suffix.first?.isWhitespace != true else {
            return prefix + suffix
        }

        let noSpaceBefore: Set<Character> = [".", ",", ";", ":", "!", "?", "…", ")", "]", "}"]
        let noSpaceAfter: Set<Character> = ["'", "’", "(", "[", "{"]
        if let first = suffix.first, noSpaceBefore.contains(first) { return prefix + suffix }
        if let last = prefix.last, noSpaceAfter.contains(last) { return prefix + suffix }
        return prefix + " " + suffix
    }
}
