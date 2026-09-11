import SwiftUI
import RemoteCore

enum PTTMode: String, CaseIterable, Identifiable {
    static let storageKey = "pttMode"

    case apple
    case chatGPT
    case claude

    var id: Self { self }

    var title: String {
        switch self {
        case .apple: "Apple"
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        }
    }

    var provider: VoiceAssistantProvider? {
        switch self {
        case .apple: nil
        case .chatGPT: .chatGPT
        case .claude: .claude
        }
    }

    var accentColor: Color {
        switch self {
        case .apple:
            .remoteBlue
        case .chatGPT:
            Color(red: 0.06, green: 0.64, blue: 0.49)
        case .claude:
            Color(red: 0.85, green: 0.39, blue: 0.25)
        }
    }

    var buttonGradient: LinearGradient {
        let colors: [Color]
        switch self {
        case .apple:
            colors = [.remoteBlue, Color(red: 0.03, green: 0.38, blue: 0.92)]
        case .chatGPT:
            colors = [Color(red: 0.08, green: 0.70, blue: 0.54), Color(red: 0.04, green: 0.38, blue: 0.32)]
        case .claude:
            colors = [Color(red: 0.93, green: 0.50, blue: 0.34), Color(red: 0.70, green: 0.27, blue: 0.18)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Le bouton Push-to-Talk.
///
/// Bouton principal aux couleurs du mode actif, anneaux animés pendant
/// l'écoute, icône qui bascule entre `sparkles` et `waveform`, ombre teintée.
/// Le sélecteur reste dans une rangée tactile indépendante au-dessus.
///
/// Le geste vit dans un overlay de la frame extérieure, jamais parmi les vues
/// qui s'animent : c'est ce qui empêche UIKit de recréer la vue du
/// reconnaisseur et d'annuler le geste alors que le doigt est encore posé.
struct PTTButton: View {
    @ObservedObject var dictation: DictationController
    let showsModeSwitcher: Bool

    @EnvironmentObject private var client: HostConnectionClient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PTTMode.storageKey) private var mode: PTTMode = .apple
    @State private var isRemoteVoicePressed = false
    @State private var isRemoteVoiceArmedForCancel = false

    init(dictation: DictationController, showsModeSwitcher: Bool = true) {
        self.dictation = dictation
        self.showsModeSwitcher = showsModeSwitcher
    }

    /// L'automatisation ChatGPT/Claude est fournie par le compagnon macOS.
    /// Sur Windows, le bouton conserve donc le comportement de dictée native.
    private var activeMode: PTTMode {
        client.connectedHostPlatform == .macOS ? mode : .apple
    }

    private var isRecording: Bool {
        activeMode == .apple ? dictation.isRecording : isRemoteVoicePressed
    }

    private var isArmedForCancel: Bool {
        activeMode == .apple ? dictation.phase == .armedForCancel : isRemoteVoiceArmedForCancel
    }

    var body: some View {
        Group {
            if showsModeSwitcher, client.connectedHostPlatform == .macOS {
                VStack(spacing: 12) {
                    modeSwitcher
                    pushToTalkControl
                }
            } else {
                pushToTalkControl
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.78), value: mode)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: client.connectedHostPlatform)
        .onChange(of: mode) { oldMode, _ in
            guard isRemoteVoicePressed, let provider = oldMode.provider else { return }
            sendVoiceControl(provider: provider, phase: .cancelled)
            isRemoteVoicePressed = false
            isRemoteVoiceArmedForCancel = false
        }
        .onChange(of: client.connectedHostPlatform) { _, platform in
            guard platform != .macOS, isRemoteVoicePressed else { return }
            isRemoteVoicePressed = false
            isRemoteVoiceArmedForCancel = false
        }
    }

    private var pushToTalkControl: some View {
        ZStack {
            if isRecording {
                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .stroke(ringColor.opacity(0.3), lineWidth: 2)
                        .frame(
                            width: 94 + CGFloat(index) * 18 + level * 12,
                            height: 94 + CGFloat(index) * 18 + level * 12
                        )
                }
            }

            Circle()
                .fill(fillStyle)
                .frame(width: 88, height: 88)
                .shadow(color: glowColor.opacity(0.42), radius: isRecording ? 12 : 8, y: 4)
                .overlay(
                    buttonIcon
                        .foregroundStyle(.white)
                )
                .scaleEffect(isRecording ? 1.12 : 1.0)
                .animation(reduceMotion ? nil : .spring(response: 0.2), value: isRecording)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isArmedForCancel)
        }
        .frame(width: 116, height: 116)
        .allowsHitTesting(false)
        .overlay(
            PressAndHoldGesture(
                onPressStart: pressBegan,
                onPressMoved: pressMoved,
                onPressEnd: pressEnded,
                onPressCancel: pressCancelled
            )
        )
        .accessibilityElement()
        .accessibilityLabel(activeMode == .apple ? AppL10n.text("ios.dictate.c1b029f") : activeMode.title)
        .accessibilityValue(isRecording ? AppL10n.text("ios.transcribing.6511a3a") : "")
        .accessibilityHint(activeMode == .apple
            ? AppL10n.text("ios.hold.to.dictate.release.to.insert.on.the.mac.14cabfc")
            : "Maintenez pour parler, relâchez pour couper le microphone du Mac.")
        .accessibilityAddTraits(.startsMediaSession)
        .accessibilityAction {
            if isRecording {
                pressEnded()
            } else {
                pressBegan()
            }
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 8) {
            ForEach(PTTMode.allCases.filter { $0 != activeMode }) { candidate in
                Button {
                    HapticFeedback.shared.tick()
                    mode = candidate
                } label: {
                    PTTModeLogo(mode: candidate)
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .frame(width: 34, height: 34)
                        .background(candidate.accentColor.gradient, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.72), lineWidth: 1.5)
                        }
                        .shadow(color: .black.opacity(0.32), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(isRecording)
                .accessibilityLabel("Activer \(candidate.title)")
            }
        }
    }

    private var level: CGFloat {
        activeMode == .apple ? dictation.level : (isRemoteVoicePressed ? 0.55 : 0)
    }

    private var fillStyle: AnyShapeStyle {
        if isArmedForCancel {
            return AnyShapeStyle(Color(red: 0.75, green: 0.28, blue: 0.28))
        }
        return AnyShapeStyle(activeMode.buttonGradient)
    }

    private var glowColor: Color {
        isArmedForCancel ? Color(red: 0.75, green: 0.28, blue: 0.28) : activeMode.accentColor
    }

    private var ringColor: Color { glowColor }

    @ViewBuilder
    private var buttonIcon: some View {
        if isArmedForCancel {
            Image(systemName: "xmark")
                .font(.system(size: 32, weight: .semibold))
        } else {
            switch activeMode {
            case .apple:
                Image(systemName: isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 32, weight: .semibold))
            case .chatGPT, .claude:
                PTTModeLogo(mode: activeMode)
                    .frame(width: 40, height: 40)
            }
        }
    }

    private func pressBegan() {
        guard let provider = activeMode.provider else {
            dictation.pressBegan()
            return
        }
        guard !isRemoteVoicePressed else { return }
        isRemoteVoicePressed = true
        isRemoteVoiceArmedForCancel = false
        HapticFeedback.shared.prepare()
        sendVoiceControl(provider: provider, phase: .began)
    }

    private func pressMoved(_ translation: CGPoint) {
        guard activeMode != .apple else {
            dictation.pressMoved(translation)
            return
        }
        guard isRemoteVoicePressed else { return }
        let armed = translation.x < -70
        if armed != isRemoteVoiceArmedForCancel {
            isRemoteVoiceArmedForCancel = armed
            armed ? HapticFeedback.shared.armedForCancel() : HapticFeedback.shared.tick()
        }
    }

    private func pressEnded() {
        guard let provider = activeMode.provider else {
            dictation.pressEnded()
            return
        }
        guard isRemoteVoicePressed else { return }
        let phase: VoiceControlPhase = isRemoteVoiceArmedForCancel ? .cancelled : .ended
        sendVoiceControl(provider: provider, phase: phase)
        isRemoteVoicePressed = false
        isRemoteVoiceArmedForCancel = false
        HapticFeedback.shared.recordingReleased()
    }

    private func pressCancelled() {
        guard let provider = activeMode.provider else {
            dictation.pressCancelled()
            return
        }
        guard isRemoteVoicePressed else { return }
        sendVoiceControl(provider: provider, phase: .cancelled)
        isRemoteVoicePressed = false
        isRemoteVoiceArmedForCancel = false
    }

    private func sendVoiceControl(provider: VoiceAssistantProvider, phase: VoiceControlPhase) {
        guard client.connectedHostPlatform == .macOS else { return }
        let payload = VoiceControlPayload(provider: provider, phase: phase)

        // Le démarrage doit recevoir une réponse : sans cela, une permission
        // Accessibilité refusée ressemblait exactement à un bouton inerte.
        guard phase == .began else {
            client.sendFireAndForget(type: .voiceControl, payload: payload)
            return
        }

        Task { @MainActor in
            do {
                let response = try await client.send(type: .voiceControl, payload: payload)
                let acknowledgement = try response.decodePayload(AcknowledgementPayload.self)
                guard acknowledgement.ok else {
                    throw RemoteErrorPayload(code: .internalFailure)
                }
            } catch let error as RemoteErrorPayload {
                isRemoteVoicePressed = false
                isRemoteVoiceArmedForCancel = false
                dictation.reportRemoteControlFailure(AppL10n.remoteError(error.code))
            } catch {
                isRemoteVoicePressed = false
                isRemoteVoiceArmedForCancel = false
                dictation.reportRemoteControlFailure(
                    AppL10n.text("ios.the.text.was.not.sent.to.the.mac.8f573c5")
                )
            }
        }
    }
}

private struct PTTModeLogo: View {
    let mode: PTTMode

    var body: some View {
        Group {
            switch mode {
            case .apple:
                Image(systemName: "apple.logo")
                    .font(.system(size: 17, weight: .semibold))
            case .chatGPT:
                Image("ChatGPTLogo")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .scaledToFit()
            case .claude:
                Image("ClaudeLogo")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }
}
