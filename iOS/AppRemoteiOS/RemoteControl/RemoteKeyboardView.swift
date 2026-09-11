import SwiftUI
import UIKit
import RemoteCore

enum KeyboardInputMode: String, CaseIterable, Identifiable {
    static let storageKey = "keyboardInputMode"

    case direct
    case corrected

    var id: Self { self }

    var title: String {
        switch self {
        case .direct: AppL10n.text("ios.direct.002c7c6")
        case .corrected: AppL10n.text("ios.editor.b2ded81")
        }
    }

    var systemImage: String {
        switch self {
        case .direct: "bolt.fill"
        case .corrected: "text.badge.checkmark"
        }
    }
}

/// Clavier distant proposant une frappe immédiate ou un brouillon corrigé.
struct RemoteKeyboardView: View {
    enum Presentation: Equatable {
        case sheet
        case inline
    }

    @EnvironmentObject private var client: HostConnectionClient

    var presentation: Presentation = .sheet
    var onDismiss: ((Animation) -> Void)?

    @AppStorage(KeyboardInputMode.storageKey) private var inputMode: KeyboardInputMode = .direct

    @State private var draft = ""
    @State private var isSendingDraft = false
    @State private var deliveryMessage: String?
    @State private var errorMessage: String?
    @State private var directFocusRequest = 0
    @State private var isDismissalPending = false
    @State private var isSoftwareKeyboardVisible = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        Group {
            switch presentation {
            case .sheet:
                sheetContent
            case .inline:
                inlineContent
            }
        }
        .onAppear {
            requestKeyboardFocus()
        }
        .onChange(of: inputMode) { _, _ in
            errorMessage = nil
            deliveryMessage = nil
            requestKeyboardFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isSoftwareKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            isSoftwareKeyboardVisible = false
            guard presentation == .inline, isDismissalPending else { return }
            finishInlineKeyboardDismissal(
                animation: Self.keyboardAnimation(from: notification)
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            isSoftwareKeyboardVisible = false
        }
    }

    private var sheetContent: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Label(
                AppL10n.text(inputMode == .direct
                    ? "ios.direct.002c7c6"
                    : "ios.editor.b2ded81"),
                systemImage: inputMode.systemImage
            )
                .font(.headline)
                .foregroundStyle(.white)

            statusMessage

            if inputMode == .direct {
                directInputField
                    .foregroundStyle(.white)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.controlSurface))

                HStack(spacing: 12) {
                    keyButton("ios.esc.7bd72d1", key: .escape)
                    keyButton("ios.tab.90ddf19", key: .tab)
                    keyButton("ios.backspace.ff7e715", key: .backspace)
                    keyButton("ios.return.d9c7efe", key: .enter)
                }
            } else {
                composer
                draftActions
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private var inlineContent: some View {
        VStack(spacing: 0) {
            inlineDismissBar

            if inputMode == .direct {
                directInputField
                    // Le texte factice est volontairement très long. Une
                    // largeur flexible laisserait son intrinsicContentSize
                    // élargir tout le VStack et pousserait le bouton de
                    // fermeture hors de l'écran.
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
            } else {
                VStack(spacing: 8) {
                HStack {
                    Label("ios.editable.draft.038347c", systemImage: inputMode.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    Spacer()
                }

                composer
                draftActions
                statusMessage
                }
                .padding(12)
                .background(Color.controlSurface)
            }
        }
        .background(Color.appBackground)
    }

    private var inlineDismissBar: some View {
        HStack {
            Spacer()

            Button {
                HapticFeedback.shared.tick()
                dismissInlineKeyboard()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.controlSurface))
                    .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("ios.close.keyboard.a7fb38b")
            .accessibilityHint("ios.restores.dictation.controls.13392f1")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Divider().overlay(.white.opacity(0.08))
        }
    }

    private var directInputField: some View {
        RemoteDirectTextField(
            focusRequest: directFocusRequest,
            onText: sendText,
            onBackspace: sendBackspace,
            onSubmit: { sendKey(.enter) },
            onCursorMove: sendCursorMovement,
            supportsSmoothCursorNavigation: client.supports(.smoothCursorNavigation)
        )
    }

    private var composer: some View {
        TextField("ios.type.your.text.e0e35fa", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($isComposerFocused)
            .autocorrectionDisabled(false)
            .textInputAutocapitalization(.sentences)
            .lineLimit(3...7)
            .foregroundStyle(.white)
            .padding(12)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .disabled(isSendingDraft)
            .accessibilityLabel("ios.draft.to.send.to.the.mac.529af97")
            .onChange(of: draft) { _, newValue in
                guard newValue.count > 512 else { return }
                draft = String(newValue.prefix(512))
            }
    }

    private var draftActions: some View {
        HStack(spacing: 12) {
            Button("ios.clear.e4750da", role: .destructive) {
                draft = ""
                deliveryMessage = nil
                errorMessage = nil
            }
            .disabled(draft.isEmpty || isSendingDraft)

            Spacer()
            characterCount

            Button {
                sendDraft()
            } label: {
                if isSendingDraft {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("ios.send.7907520", systemImage: "arrow.up.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.remoteBlue)
            .disabled(draft.isEmpty || isSendingDraft)
        }
    }

    private var characterCount: some View {
        Text("\(draft.count)/512")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.48))
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        } else if let deliveryMessage {
            Label(deliveryMessage, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
        }
    }

    private func requestKeyboardFocus() {
        Task { @MainActor in
            // Le champ inline arrive après l'animation qui remplace la barre
            // de dictée. Un premier rendement laisse SwiftUI l'insérer dans la
            // hiérarchie avant de demander le clavier.
            isComposerFocused = false
            await Task.yield()
            if inputMode == .direct {
                directFocusRequest &+= 1
            } else {
                isComposerFocused = true
            }
        }
    }

    /// Commence par rendre le first responder au système, puis laisse passer
    /// une frame avant de retirer la vue SwiftUI. Le clavier et le contenu ne
    /// se disputent ainsi plus le même recalcul de layout, ce qui supprimait la
    /// petite saccade visible au moment de la réduction.
    private func dismissInlineKeyboard() {
        guard !isDismissalPending else { return }
        isDismissalPending = true
        isComposerFocused = false
        let expectsSystemAnimation = isSoftwareKeyboardVisible
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )

        if !expectsSystemAnimation {
            Task { @MainActor in
                // Avec un clavier physique, UIKit n'émet aucun
                // keyboardWillHide : seul le chrome inline est à fermer.
                await Task.yield()
                guard isDismissalPending else { return }
                finishInlineKeyboardDismissal(animation: .smooth(duration: 0.24))
            }
        }
    }

    private func finishInlineKeyboardDismissal(animation: Animation) {
        guard isDismissalPending else { return }
        isDismissalPending = false
        onDismiss?(animation)
    }

    /// Reproduit la courbe fournie par UIKit au lieu d'estimer le mouvement du
    /// clavier. Le panneau inline et la safe area avancent ainsi sur la même
    /// horloge, y compris lorsque la durée système varie.
    private static func keyboardAnimation(from notification: Notification) -> Animation {
        let userInfo = notification.userInfo
        let duration = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
            .doubleValue ?? 0.25
        let rawCurve = (userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?
            .intValue ?? UIView.AnimationCurve.easeInOut.rawValue

        switch UIView.AnimationCurve(rawValue: rawCurve) {
        case .easeIn:
            return .timingCurve(0.42, 0, 1, 1, duration: duration)
        case .easeOut:
            return .timingCurve(0, 0, 0.58, 1, duration: duration)
        case .linear:
            return .linear(duration: duration)
        case .easeInOut, .none:
            return .timingCurve(0.42, 0, 0.58, 1, duration: duration)
        @unknown default:
            return .timingCurve(0.42, 0, 0.58, 1, duration: duration)
        }
    }

    private func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        Task {
            do {
                _ = try await client.send(
                    type: .keyboardText,
                    payload: KeyboardTextPayload(text: text, userInitiated: true)
                )
                errorMessage = nil
            } catch let error as RemoteErrorPayload {
                errorMessage = AppL10n.remoteError(error.code)
            } catch {
                errorMessage = AppL10n.text("ios.the.text.was.not.sent.to.the.mac.8f573c5")
            }
        }
    }

    private func sendBackspace() {
        client.sendFireAndForget(type: .keyPress, payload: KeyPressPayload(key: .backspace))
    }

    private func sendCursorMovement(_ delta: Int) {
        guard delta != 0 else { return }
        let key: RemoteKey = delta < 0 ? .arrowLeft : .arrowRight
        client.sendFireAndForget(
            type: .keyPress,
            payload: KeyPressPayload(key: key, repeatCount: min(abs(delta), 32))
        )
    }

    private func keyButton(_ label: String, key: RemoteKey) -> some View {
        Button {
            sendKey(key)
        } label: {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(Color.controlSurface))
        }
        .buttonStyle(.plain)
    }

    private func sendKey(_ key: RemoteKey) {
        HapticFeedback.shared.tick()
        client.sendFireAndForget(type: .keyPress, payload: KeyPressPayload(key: key))
    }

    private func sendDraft() {
        guard !draft.isEmpty, !isSendingDraft else { return }
        let text = draft
        isSendingDraft = true
        errorMessage = nil
        deliveryMessage = nil
        HapticFeedback.shared.tick()

        Task {
            do {
                _ = try await client.send(
                    type: .keyboardText,
                    payload: KeyboardTextPayload(text: text, userInitiated: true)
                )
                draft = ""
                deliveryMessage = AppL10n.text("ios.text.sent.to.the.mac.0ed5c3d")
            } catch let error as RemoteErrorPayload {
                errorMessage = AppL10n.remoteError(error.code)
            } catch {
                errorMessage = AppL10n.text("ios.the.text.was.not.sent.to.the.mac.8f573c5")
            }
            isSendingDraft = false
        }
    }
}

/// Suit uniquement un caret simple. Une sélection de texte à deux doigts est
/// volontairement ignorée : le compagnon ne connaît pas le contenu distant et
/// ne peut donc pas reproduire une plage sélectionnée de façon fiable.
struct RemoteCursorSelectionTracker {
    static let maximumPlausibleMovement = 32

    private(set) var previousOffset: Int?

    mutating func reset(to offset: Int) {
        previousOffset = offset
    }

    mutating func movement(selectionStart: Int, selectionEnd: Int) -> Int? {
        guard selectionStart == selectionEnd else { return nil }
        defer { previousOffset = selectionStart }
        guard let previousOffset else { return nil }
        let delta = selectionStart - previousOffset
        guard delta != 0,
              abs(delta) <= Self.maximumPlausibleMovement else { return nil }
        return delta
    }
}

/// Champ UIKit invisible conservant assez de positions de texte pour que le
/// geste natif « maintenir Espace puis glisser » puisse déplacer son caret.
/// Les frappes ne modifient jamais ce texte factice : elles restent envoyées
/// directement au Mac.
private struct RemoteDirectTextField: UIViewRepresentable {
    let focusRequest: Int
    let onText: (String) -> Void
    let onBackspace: () -> Void
    let onSubmit: () -> Void
    let onCursorMove: (Int) -> Void
    let supportsSmoothCursorNavigation: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.backgroundColor = .clear
        textField.borderStyle = .none
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.smartInsertDeleteType = .no
        textField.isAccessibilityElement = false
        context.coordinator.installShadowText(in: textField)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.requestFocus(in: textField, request: focusRequest)
    }

    static func dismantleUIView(_ textField: UITextField, coordinator: Coordinator) {
        coordinator.flushPendingMovement()
        textField.resignFirstResponder()
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        private static let shadowLength = 513
        private static let centerOffset = shadowLength / 2
        // Une cadence écran (environ 60 Hz) évite les bonds perceptibles du
        // caret. Les petits lots absorbent les callbacks UIKit rapprochés sans
        // rejouer d'un coup toute la distance accumulée.
        private var maximumBatchSize: Int {
            parent.supportsSmoothCursorNavigation ? 3 : 32
        }

        private var flushInterval: Duration {
            .milliseconds(parent.supportsSmoothCursorNavigation ? 16 : 50)
        }

        var parent: RemoteDirectTextField
        private var selectionTracker = RemoteCursorSelectionTracker()
        private var lastFocusRequest: Int?
        private var isApplyingSelection = false
        private var pendingMovement = 0
        private var flushTask: Task<Void, Never>?
        private var recenterTask: Task<Void, Never>?

        init(parent: RemoteDirectTextField) {
            self.parent = parent
        }

        deinit {
            flushTask?.cancel()
            recenterTask?.cancel()
        }

        func installShadowText(in textField: UITextField) {
            // L'espace cadratin numérique possède une largeur réelle tout en
            // restant neutre pour les suggestions, contrairement à une longue
            // suite de lettres factices.
            textField.text = String(repeating: "\u{2007}", count: Self.shadowLength)
            setSelection(Self.centerOffset, in: textField)
        }

        func requestFocus(in textField: UITextField, request: Int) {
            guard lastFocusRequest != request else { return }
            lastFocusRequest = request
            Task { @MainActor [weak self, weak textField] in
                guard let self, let textField else { return }
                // `becomeFirstResponder` peut placer momentanément le caret à
                // la fin des 513 caractères factices. Ce saut UIKit n'est pas
                // un geste utilisateur et ne doit jamais devenir une rafale
                // de flèches envoyée au Mac.
                self.isApplyingSelection = true
                textField.becomeFirstResponder()
                self.applySelection(Self.centerOffset, in: textField)
                self.pendingMovement = 0
                self.flushTask?.cancel()
                self.flushTask = nil
                self.isApplyingSelection = false
            }
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if string.isEmpty {
                if range.length > 0 {
                    parent.onBackspace()
                }
            } else {
                parent.onText(string)
            }
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            guard !isApplyingSelection,
                  let range = textField.selectedTextRange else { return }
            let start = textField.offset(from: textField.beginningOfDocument, to: range.start)
            let end = textField.offset(from: textField.beginningOfDocument, to: range.end)
            scheduleRecentering(in: textField)
            guard let movement = selectionTracker.movement(
                selectionStart: start,
                selectionEnd: end
            ) else { return }
            queueMovement(movement)
        }

        private func setSelection(_ offset: Int, in textField: UITextField) {
            isApplyingSelection = true
            applySelection(offset, in: textField)
            isApplyingSelection = false
        }

        private func applySelection(_ offset: Int, in textField: UITextField) {
            guard let position = textField.position(
                from: textField.beginningOfDocument,
                offset: offset
            ), let range = textField.textRange(from: position, to: position) else { return }
            textField.selectedTextRange = range
            selectionTracker.reset(to: offset)
        }

        private func queueMovement(_ movement: Int) {
            pendingMovement = min(max(pendingMovement + movement, -256), 256)
            guard flushTask == nil else { return }
            flushTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: self?.flushInterval ?? .milliseconds(50))
                } catch {
                    return
                }
                self?.flushPendingMovement()
            }
        }

        private func scheduleRecentering(in textField: UITextField) {
            recenterTask?.cancel()
            recenterTask = Task { @MainActor [weak self, weak textField] in
                do {
                    try await Task.sleep(for: .milliseconds(350))
                } catch {
                    return
                }
                guard let self, let textField else { return }
                self.setSelection(Self.centerOffset, in: textField)
                self.recenterTask = nil
            }
        }

        func flushPendingMovement() {
            flushTask?.cancel()
            flushTask = nil
            guard pendingMovement != 0 else { return }

            let batch = min(max(pendingMovement, -maximumBatchSize), maximumBatchSize)
            pendingMovement -= batch
            parent.onCursorMove(batch)

            if pendingMovement != 0 {
                queueMovement(0)
            }
        }
    }
}
