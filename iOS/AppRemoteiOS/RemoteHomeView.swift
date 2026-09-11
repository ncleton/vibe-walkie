import SwiftUI
import RemoteCore
import UniformTypeIdentifiers

/// Cadence commune aux touches qui doivent se répéter tant que le doigt reste
/// posé. Un seul message réseau est émis par intervalle ; son lot grossit avec
/// la durée de l'appui, ce qui accélère franchement sans saturer la connexion.
struct AcceleratingKeyRepeatPolicy {
    static let initialDelay: Duration = .milliseconds(380)
    static let interval: Duration = .milliseconds(85)

    static func batchSize(forTick tick: Int) -> Int {
        let stage = min(max(tick, 0) / 14, 5)
        return 1 << stage
    }
}

/// Bouton tactile à répétition accélérée. Le premier appui part immédiatement,
/// puis les lots passent progressivement de 1 à 32 frappes. Un glissement
/// volontaire hors du bouton annule la rafale, comme sur un clavier natif.
struct AcceleratingKeyRepeatButton<Label: View>: View {
    let action: (Int) -> Void
    @ViewBuilder let label: () -> Label

    @State private var isPressed = false
    @State private var didCancelGesture = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        label()
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.96 : 1)
            .opacity(isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if abs(value.translation.width) > 48 || abs(value.translation.height) > 48 {
                            didCancelGesture = true
                            stopRepeating()
                        } else if !didCancelGesture, !isPressed {
                            startRepeating()
                        }
                    }
                    .onEnded { _ in
                        didCancelGesture = false
                        stopRepeating()
                    }
            )
            .onDisappear(perform: stopRepeating)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                HapticFeedback.shared.tick()
                action(1)
            }
    }

    private func startRepeating() {
        isPressed = true
        HapticFeedback.shared.tick()
        action(1)
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            do {
                try await Task.sleep(for: AcceleratingKeyRepeatPolicy.initialDelay)
                var tick = 0
                while !Task.isCancelled {
                    action(AcceleratingKeyRepeatPolicy.batchSize(forTick: tick))
                    tick += 1
                    try await Task.sleep(for: AcceleratingKeyRepeatPolicy.interval)
                }
            } catch {
                // L'annulation au relâchement est le chemin normal.
            }
        }
    }

    private func stopRepeating() {
        isPressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}

/// Écran principal.
///
/// Une pilule de cible reste en haut, une grande surface tactile occupe le
/// centre et les commandes essentielles restent accessibles au pouce.
/// Le bouton de dictée est centré et dimensionné pour être maintenu au pouce
/// sans regarder l'écran.
struct RemoteHomeView: View {
    @EnvironmentObject private var client: HostConnectionClient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var dictation: DictationController

    @State private var showSwitcher = false
    @State private var showHostSwitcher = false
    @State private var showKeyboard = false
    @State private var showSettings = false
    @State private var showScreen = false
    @State private var showControlConfigurator = false
    @State private var showGlobalPalette = false
    @AppStorage(DictationLanguage.storageKey) private var dictationLanguageIdentifier = DictationLanguage.automaticIdentifier

    init(client: HostConnectionClient) {
        _dictation = StateObject(wrappedValue: DictationController(client: client))
#if DEBUG
        _showGlobalPalette = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("--marketing-global")
        )
#endif
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topRow

                VStack(spacing: 12) {
                    TrackpadView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            statusStrip
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                                .allowsHitTesting(false)
                        }

                    if !showKeyboard {
                        dictationBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)

                if showKeyboard {
                    RemoteKeyboardView(presentation: .inline) { keyboardAnimation in
                        withAnimation(reduceMotion ? nil : keyboardAnimation) {
                            showKeyboard = false
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: dictationLanguageIdentifier) {
            client.connectIfPossible()
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--marketing-home") {
                dictation.configureMarketingRecording()
                return
            }
            if arguments.contains("--marketing-home-delivered") {
                dictation.configureMarketingDelivered()
                return
            }
            if arguments.contains("--marketing-home-idle") { return }
            if arguments.contains("--marketing-global") { return }
#endif
            // Le test écran ne dépend ni du micro ni de la transcription.
            // Le lancer en premier évite qu'une initialisation Speech lente
            // suspende la validation réseau sur un appareil physique.
            if ProcessInfo.processInfo.arguments.contains("--smoke-test-screen") {
                await runScreenSmokeTestIfRequested()
                return
            }
            let resolvedLocale: String
            if #available(iOS 26.0, *) {
                resolvedLocale = await AppleSpeechLocaleCatalog.resolvedIdentifier(
                    storedIdentifier: dictationLanguageIdentifier
                )
            } else {
                resolvedLocale = DictationLanguage.deviceLocaleIdentifier
            }
            await dictation.prepareEngine(localeIdentifier: resolvedLocale)
            await runPTTSmokeTestIfRequested()
        }
        .task(id: client.state.isReady) {
            await monitorActiveApplication()
        }
        .sheet(isPresented: $showSwitcher) {
            AppSwitcherView().environmentObject(client)
        }
        .sheet(isPresented: $showHostSwitcher) {
            HostSwitcherView().environmentObject(client)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(client)
        }
        .sheet(isPresented: $showControlConfigurator) {
            NavigationStack {
                ControlConfiguratorView()
                    .environmentObject(client)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("ios.close.711e5f2") { showControlConfigurator = false }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showScreen) {
            RemoteScreenView(dictation: dictation)
                .environmentObject(client)
        }
    }

    /// Maintient la pilule du haut alignée sur l'app réellement au premier
    /// plan sur le Mac. La requête légère n'embarque pas les icônes ; la grille
    /// complète continue de les demander uniquement lorsqu'elle est ouverte.
    private func monitorActiveApplication() async {
        guard client.state.isReady else { return }
        while !Task.isCancelled && client.state.isReady {
            if !showSwitcher {
                _ = try? await client.send(
                    type: .listWindows,
                    payload: ListWindowsPayload(includeIcons: false)
                )
            }
            try? await Task.sleep(for: .milliseconds(750))
        }
    }

    /// Utilisé uniquement par l'installation de validation sur un iPhone
    /// physique. Le lancement normal ne contient jamais cet argument.
    private func runPTTSmokeTestIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--smoke-test-ptt") else { return }

        // Attend la reconnexion puis vérifie le trajet complet de la grille
        // d'apps (requête, sérialisation des icônes et réponse).
        for _ in 0..<50 where !client.state.isReady {
            try? await Task.sleep(for: .milliseconds(100))
        }

        var applicationCount: Int?
        var applicationError: String?
        do {
            let response = try await client.send(
                type: .listWindows,
                payload: ListWindowsPayload(includeIcons: true)
            )
            let snapshot = try response.decodePayload(WindowsSnapshotPayload.self)
            applicationCount = snapshot.applications.count
        } catch {
            // A smoke-test artifact is intentionally safe to export. Do not
            // persist a host-provided error because it may contain app/window
            // context; the stable category is enough for the test runner.
            applicationError = "request_failed"
        }

        try? await Task.sleep(for: .milliseconds(500))
        dictation.pressBegan()
        try? await Task.sleep(for: .seconds(2))
        dictation.pressEnded()
        try? await Task.sleep(for: .seconds(3))

        let report: [String: Any] = [
            "applications": applicationCount.map { $0 as Any } ?? NSNull(),
            "applicationsError": applicationError.map { $0 as Any } ?? NSNull(),
            "processAliveAfterPTT": true,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: documents.appendingPathComponent("viberemote-smoke-test.json"), options: .atomic)
        }
    }

    /// Validation de bout en bout sur l’iPhone physique : demande réellement
    /// le flux au compagnon Mac et conserve les dimensions de la première
    /// image reçue dans le conteneur de l’app.
    private func runScreenSmokeTestIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--smoke-test-screen") else { return }

        for _ in 0..<100 where !client.state.isReady {
            try? await Task.sleep(for: .milliseconds(100))
        }

        client.startScreenStream(maxWidth: 1_280, framesPerSecond: 10, jpegQuality: 0.45)
        for _ in 0..<120 where client.latestScreenFrame == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }

        let frame = client.latestScreenFrame
        let report: [String: Any] = [
            "connected": client.state.isReady,
            "connection": client.connectionRoute.rawValue,
            "screenPermissionGranted": client.screenStreamStatus.permissionGranted,
            "screenStreaming": client.screenStreamStatus.isStreaming,
            "screenError": client.screenStreamStatus.detail ?? NSNull(),
            "frameBytes": frame?.jpegData.count ?? 0,
            "frameWidth": frame?.width ?? 0,
            "frameHeight": frame?.height ?? 0,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: documents.appendingPathComponent("viberemote-screen-smoke-test.json"), options: .atomic)
        }
        client.stopScreenStream()
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            CircularControlButton(
                systemImage: "desktopcomputer.and.macbook",
                size: 44,
                iconSize: 15,
                accessibilityText: "ios.switch.mac.1dd0a5a"
            ) {
                HapticFeedback.shared.tick()
                showHostSwitcher = true
            }

            TargetPill { showSwitcher = true }

            CircularControlButton(
                systemImage: "arrow.up.left.and.arrow.down.right",
                size: 44,
                iconSize: 15,
                accessibilityText: "ios.screen.view.b5645a8"
            ) {
                HapticFeedback.shared.tick()
                showScreen = true
            }
            .disabled(!client.state.isReady)

            CircularControlButton(
                systemImage: "list.bullet",
                size: 44,
                iconSize: 15,
                accessibilityText: "ios.connection.61d6950"
            ) {
                showSettings = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.appChrome)
    }

    /// Bandeau d'état : la transcription en direct et le résultat de l'envoi.
    /// Il garde une hauteur fixe pour que le trackpad ne bouge jamais sous le
    /// doigt quand un message apparaît.
    private var statusStrip: some View {
        Group {
            switch dictation.phase {
            case .recording, .armedForCancel:
                Text(dictation.partialText.isEmpty ? "Parlez…" : dictation.partialText)
                    .foregroundStyle(dictation.phase == .armedForCancel ? .red : .white)
            case .finalizing:
                Text("ios.transcribing.6511a3a").foregroundStyle(.white.opacity(0.6))
            case .sending:
                Text("ios.sending.1ccef8a").foregroundStyle(.white.opacity(0.6))
            case .delivered(let message):
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .sentUnverified(let message):
                Label(message, systemImage: "arrow.up.circle.fill").foregroundStyle(.orange)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .idle:
                Text(" ").foregroundStyle(.clear)
            }
        }
        .font(.footnote)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .center)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: dictation.phase)
    }

    private var dictationBar: some View {
        VStack(spacing: 6) {
            ZStack {
                HStack {
                    VStack(spacing: 7) {
                        configuredButton(.upperLeft, style: .side)
                        configuredButton(.lowerLeft, style: .side)
                    }
                    Spacer(minLength: 96)
                    VStack(spacing: 7) {
                        configuredButton(.upperRight, style: .side)
                        configuredButton(.lowerRight, style: .side)
                    }
                }

                PTTButton(dictation: dictation)
            }

            HStack(spacing: 7) {
                configuredButton(.bottomLeft, style: .bottom)
                configuredButton(.bottomCenter, style: .bottom)
                configuredButton(.bottomRight, style: .bottom)
                globalPaletteButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 218)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.controlSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.06), lineWidth: 1)
                )
        )
        .overlay(alignment: .bottom) {
            if showGlobalPalette {
                GlobalShortcutBubble(
                    slots: client.availableGlobalButtonSlots,
                    perform: perform,
                    reposition: client.updateGlobalButtonSlots,
                    configure: {
                        showGlobalPalette = false
                        showControlConfigurator = true
                    },
                    close: {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            showGlobalPalette = false
                        }
                    }
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 54)
                .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
                .zIndex(10)
            }
        }
    }

    private var globalPaletteButton: some View {
        Button {
            HapticFeedback.shared.tick()
            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.84)) {
                showGlobalPalette.toggle()
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: showGlobalPalette ? "xmark" : "circle.grid.2x2.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("ios.global.a258b30")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(showGlobalPalette ? Color.remoteBlue : .white.opacity(0.92))
            .frame(maxWidth: .infinity)
            .frame(height: 43)
            .background(
                (showGlobalPalette ? Color.remoteBlue.opacity(0.18) : Color.white.opacity(0.075)),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(showGlobalPalette ? Color.remoteBlue.opacity(0.7) : .white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showGlobalPalette ? "Fermer les commandes globales" : "Ouvrir les commandes globales")
    }

    private enum ConfiguredButtonStyle {
        case side
        case bottom
    }

    @ViewBuilder
    private func configuredButton(_ zone: ControlZone, style: ConfiguredButtonStyle) -> some View {
        let configuration = client.controlConfiguration.button(in: zone)
        let displayedTitle = ControlTitleLocalization.title(configuration.title, action: configuration.action)
        if let key = repeatingKey(for: configuration.action) {
            AcceleratingKeyRepeatButton {
                sendKeyBatch(key, repeatCount: $0)
            } label: {
                configuredButtonLabel(
                    configuration: configuration,
                    displayedTitle: displayedTitle,
                    style: style
                )
            }
            .accessibilityLabel(displayedTitle)
            .accessibilityHint("Maintenez pour accélérer progressivement.")
        } else {
            Button {
                perform(configuration.action)
            } label: {
                configuredButtonLabel(
                    configuration: configuration,
                    displayedTitle: displayedTitle,
                    style: style
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayedTitle)
            .accessibilityHint(actionIsEmpty(configuration.action) ? "Ouvre la configuration de cette zone." : "Maintenez pour modifier ce bouton.")
            .contextMenu {
                Button {
                    showControlConfigurator = true
                } label: {
                    Label("ios.edit.this.button.1993f87", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private func configuredButtonLabel(
        configuration: ControlButtonConfiguration,
        displayedTitle: String,
        style: ConfiguredButtonStyle
    ) -> some View {
        VStack(spacing: 3) {
            ControlIconImage(icon: configuration.icon)
                .frame(width: style == .side ? 17 : 15, height: style == .side ? 17 : 15)
            Text(displayedTitle)
                .font(.system(size: style == .side ? 8 : 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white.opacity(actionIsEmpty(configuration.action) ? 0.48 : 0.9))
        .frame(maxWidth: style == .bottom ? .infinity : nil)
        .frame(width: style == .side ? 68 : nil, height: style == .side ? 55 : 43)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: style == .side ? 16 : 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: style == .side ? 16 : 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func repeatingKey(for action: ControlButtonAction) -> RemoteKey? {
        guard case .standardKey(let key) = action else { return nil }
        switch key {
        case .backspace, .delete:
            return key
        default:
            return nil
        }
    }

    private func actionIsEmpty(_ action: ControlButtonAction) -> Bool {
        if case .none = action { return true }
        return false
    }

    private func perform(_ action: ControlButtonAction) {
        switch action {
        case .none:
            showControlConfigurator = true
        case .standardKey(let key):
            sendKey(key)
        case .hostShortcut(let shortcut):
            HapticFeedback.shared.tick()
            client.sendFireAndForget(
                type: .hostShortcutPress,
                payload: HostShortcutPressPayload(shortcutID: shortcut.id)
            )
        case .macShortcut(let shortcut):
            HapticFeedback.shared.tick()
            client.sendFireAndForget(
                type: .hostShortcutPress,
                payload: HostShortcutPressPayload(shortcutID: shortcut.migratedDefinition.id)
            )
        case .showKeyboard:
            HapticFeedback.shared.tick()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                showKeyboard = true
            }
        }
    }

    private func sendKey(_ key: RemoteKey) {
        HapticFeedback.shared.tick()
        sendKeyBatch(key, repeatCount: 1)
    }

    private func sendKeyBatch(_ key: RemoteKey, repeatCount: Int) {
        client.sendFireAndForget(
            type: .keyPress,
            payload: KeyPressPayload(key: key, repeatCount: repeatCount)
        )
    }

}

struct GlobalShortcutBubble: View {
    let slots: [GlobalButtonConfiguration?]
    let perform: (ControlButtonAction) -> Void
    let reposition: ([GlobalButtonConfiguration?]) -> Void
    let configure: () -> Void
    let close: () -> Void

    @State private var positionedButtons: [GlobalButtonConfiguration?]
    @State private var draggedButtonID: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)

    init(
        slots: [GlobalButtonConfiguration?],
        perform: @escaping (ControlButtonAction) -> Void,
        reposition: @escaping ([GlobalButtonConfiguration?]) -> Void,
        configure: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.slots = slots
        self.perform = perform
        self.reposition = reposition
        self.configure = configure
        self.close = close
        _positionedButtons = State(initialValue: slots)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Label("ios.global.a258b30", systemImage: "circle.grid.2x2.fill")
                    .font(.subheadline.bold())
                Text("ios.more.controls.7ec4e50")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: configure) {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("ios.reorder.global.controls.3846618")
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("ios.close.711e5f2")
            }

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(positionedButtons.indices, id: \.self) { index in
                    Group {
                        if let button = positionedButtons[index] {
                            let displayedTitle = ControlTitleLocalization.title(button.title, action: button.action)
                            Button {
                                perform(button.action)
                            } label: {
                                VStack(spacing: 4) {
                                    ControlIconImage(icon: button.icon)
                                        .frame(width: 18, height: 18)
                                    Text(displayedTitle)
                                        .font(.system(size: 9, weight: .semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                }
                                .foregroundStyle(.white.opacity(0.92))
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(displayedTitle)
                            .accessibilityHint("ios.hold.the.handle.then.drag.35697e0")
                            .onDrag {
                                draggedButtonID = button.id
                                HapticFeedback.shared.tick()
                                return NSItemProvider(object: button.id as NSString)
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.white.opacity(0.025))
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                }
                                .accessibilityHidden(true)
                        }
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: GlobalButtonDropDelegate(
                            destinationIndex: index,
                            positionedButtons: $positionedButtons,
                            draggedButtonID: $draggedButtonID,
                            reposition: reposition
                        )
                    )
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .onChange(of: slots) { _, newSlots in
            positionedButtons = newSlots
        }
    }
}

private struct GlobalButtonDropDelegate: DropDelegate {
    let destinationIndex: Int
    @Binding var positionedButtons: [GlobalButtonConfiguration?]
    @Binding var draggedButtonID: String?
    let reposition: ([GlobalButtonConfiguration?]) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedButtonID,
              positionedButtons.indices.contains(destinationIndex),
              let sourceIndex = positionedButtons.firstIndex(where: { $0?.id == draggedButtonID }),
              sourceIndex != destinationIndex else {
            return
        }

        withAnimation(.easeInOut(duration: 0.15)) {
            positionedButtons.swapAt(sourceIndex, destinationIndex)
        }
        reposition(positionedButtons)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedButtonID = nil
        return true
    }
}
