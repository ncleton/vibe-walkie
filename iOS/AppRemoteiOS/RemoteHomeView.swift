import SwiftUI
import RemoteCore

/// Écran principal.
///
/// Une pilule de cible reste en haut, une grande surface tactile occupe le
/// centre et les commandes essentielles restent accessibles au pouce.
/// Le bouton de dictée est centré et dimensionné pour être maintenu au pouce
/// sans regarder l'écran.
struct RemoteHomeView: View {
    @EnvironmentObject private var client: HostConnectionClient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
                GeometryReader { proxy in
                    let geometry = WorkspaceGeometry(
                        size: proxy.size,
                        regularWidth: horizontalSizeClass == .regular,
                        division: RemoteWorkspaceRegions.division(in: proxy)
                    )
                    RemoteWorkspaceLayout(geometry: geometry) {
                        RemoteWorkspaceScreen(enabled: geometry.isExpanded && !showScreen) {
                            showScreen = true
                        }
                        .opacity(geometry.isExpanded ? 1 : 0)
                        .accessibilityHidden(!geometry.isExpanded)
                        .allowsHitTesting(geometry.isExpanded)
                        .clipped()

                        controlPanel
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

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

    private var controlPanel: some View {
        GeometryReader { proxy in
            VStack(spacing: 8) {
                topRow
                    TrackpadView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            statusStrip
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                                .allowsHitTesting(false)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if showKeyboard {
                                Button {
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                        showKeyboard = false
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Color.remoteBlue)
                                        .frame(width: 44, height: 44)
                                        .background(Circle().fill(Color.controlSurface))
                                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 12)
                                .padding(.bottom, 58)
                                .transition(.scale.combined(with: .opacity))
                                .accessibilityLabel("ios.close.keyboard.a7fb38b")
                                .accessibilityHint("ios.restores.dictation.controls.13392f1")
                            }
                        }

                if !showKeyboard {
                    if proxy.size.height < 440 {
                        compactDictationBar
                    } else {
                        dictationBar
                    }
                }
                if showKeyboard {
                    RemoteKeyboardView(presentation: .inline)
                }
            }
        }
    }

    /// The short outer display and a tabletop control pane keep every command
    /// reachable without shrinking the trackpad to nothing.
    private var compactDictationBar: some View {
        HStack(spacing: 8) {
            PTTButton(dictation: dictation)
                .scaleEffect(0.68)
                .frame(width: 94, height: 98)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(ControlZone.allCases, id: \.self) { zone in
                    configuredButton(zone, style: .bottom)
                }
                globalPaletteButton
            }
        }
        .padding(8)
        .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 20))
        .popover(isPresented: $showGlobalPalette) {
            GlobalShortcutBubble(
                buttons: client.controlConfiguration.availableGlobalButtons,
                perform: { action in showGlobalPalette = false; perform(action) },
                configure: { showGlobalPalette = false; showControlConfigurator = true },
                close: { showGlobalPalette = false }
            )
            .presentationCompactAdaptation(.popover)
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
        .padding(.vertical, 6)
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
                    buttons: client.controlConfiguration.availableGlobalButtons,
                    perform: { action in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            showGlobalPalette = false
                        }
                        perform(action)
                    },
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
            .frame(height: 44)
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

    private func configuredButton(_ zone: ControlZone, style: ConfiguredButtonStyle) -> some View {
        let configuration = client.controlConfiguration.button(in: zone)
        let displayedTitle = ControlTitleLocalization.title(configuration.title, action: configuration.action)
        return Button {
            perform(configuration.action)
        } label: {
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
            .frame(width: style == .side ? 68 : nil, height: style == .side ? 55 : 44)
            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: style == .side ? 16 : 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: style == .side ? 16 : 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
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
        client.sendFireAndForget(type: .keyPress, payload: KeyPressPayload(key: key))
    }

}

struct GlobalShortcutBubble: View {
    let buttons: [GlobalButtonConfiguration]
    let perform: (ControlButtonAction) -> Void
    let configure: () -> Void
    let close: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)

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
                ForEach(buttons) { button in
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
    }
}
