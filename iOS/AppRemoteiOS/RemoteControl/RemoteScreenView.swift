import SwiftUI
import UIKit
import RemoteCore

enum RemoteScreenPTTSide: String, CaseIterable, Identifiable {
    static let storageKey = "remoteScreenPTTSide"

    case right
    case left

    var id: Self { self }

    var title: String {
        switch self {
        case .right: AppL10n.text("ios.right.37f370d")
        case .left: AppL10n.text("ios.left.b107a0a")
        }
    }
}

/// Mode écran distant : l’image sert de retour visuel et le pavé reste la
/// surface de contrôle principale. On évite ainsi de masquer le pointeur sous
/// le doigt et on conserve exactement les gestes du pavé habituel.
struct RemoteScreenView: View {
    @EnvironmentObject private var client: HostConnectionClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var dictation: DictationController

    @AppStorage("screenQuality") private var screenQuality = 0.45
    @AppStorage("screenFrameRate") private var screenFrameRate = 10.0
    @AppStorage(RemoteScreenPTTSide.storageKey) private var pttSide: RemoteScreenPTTSide = .right
    @State private var streamOwner = UUID()
    @State private var showKeyboard = false
    @State private var showGlobalPalette = false
    @State private var showControlConfigurator = false

    private struct ScreenProfile: Equatable {
        let maxWidth: Int
        let framesPerSecond: Int
        let jpegQuality: Double
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.height >= proxy.size.width {
                    portraitLayout(in: proxy)
                } else {
                    landscapeLayout(in: proxy)
                }
            }
            // Le canevas occupe bien tout l'écran, mais respecte la zone du
            // clavier logiciel afin que l'image du Mac reste visible au-dessus.
            .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task(id: client.state.isReady) {
            guard client.state.isReady else { return }
            await maintainScreenStream()
        }
        .onAppear {
            AppOrientationPolicy.setRemoteScreenActive(true)
            // Une télécommande posée près du Mac ne doit pas verrouiller son
            // écran en plein contrôle : iOS suspendrait alors le réseau et le
            // flux semblerait « couper » au bout du délai de veille.
            RemoteScreenIdlePolicy.setActive(true, owner: streamOwner)
        }
        .onDisappear {
            AppOrientationPolicy.setRemoteScreenActive(false)
            RemoteScreenIdlePolicy.setActive(false, owner: streamOwner)
            client.stopScreenStream(owner: streamOwner)
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
    }

    /// En portrait, l'écran du Mac occupe tout le canevas. Le pavé devient une
    /// couche tactile transparente et les commandes flottent au-dessus.
    private func portraitLayout(in proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                screenPreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                TrackpadView(appearance: .screenOverlay)
                    .environmentObject(client)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, proxy.safeAreaInsets.top + 54)
                    .padding(.bottom, showKeyboard ? 8 : proxy.safeAreaInsets.bottom + 78)

                screenHeader(topInset: proxy.safeAreaInsets.top, compact: false)
                    .frame(maxHeight: .infinity, alignment: .top)

                if !showKeyboard {
                    globalPalette(compact: false, bottomInset: proxy.safeAreaInsets.bottom)

                    floatingCommandDock(compact: false)
                        .padding(.horizontal, 10)
                        .padding(.bottom, max(8, proxy.safeAreaInsets.bottom))
                } else {
                    keyboardDismissButton(compact: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            inlineKeyboard
        }
    }

    /// Le paysage suit la même logique plein écran, avec un dock plus compact.
    private func landscapeLayout(in proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                screenPreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                TrackpadView(appearance: .screenOverlay)
                    .environmentObject(client)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, proxy.safeAreaInsets.leading)
                    .padding(.trailing, proxy.safeAreaInsets.trailing)
                    .padding(.top, proxy.safeAreaInsets.top + 46)
                    .padding(.bottom, showKeyboard ? 6 : proxy.safeAreaInsets.bottom + 64)

                screenHeader(topInset: max(4, proxy.safeAreaInsets.top), compact: true)
                    .frame(maxHeight: .infinity, alignment: .top)

                if !showKeyboard {
                    globalPalette(compact: true, bottomInset: proxy.safeAreaInsets.bottom)

                    floatingCommandDock(compact: true)
                        .padding(.horizontal, max(10, max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing)))
                        .padding(.bottom, max(6, proxy.safeAreaInsets.bottom))
                } else {
                    keyboardDismissButton(compact: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            inlineKeyboard
        }
    }

    @ViewBuilder
    private var inlineKeyboard: some View {
        if showKeyboard {
            RemoteKeyboardView(presentation: .inline)
            .environmentObject(client)
            .frame(maxWidth: .infinity)
        }
    }

    private func keyboardDismissButton(compact: Bool) -> some View {
        Button {
            closeKeyboard()
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: compact ? 15 : 17, weight: .semibold))
                .frame(width: compact ? 40 : 44, height: compact ? 40 : 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.trailing, compact ? 10 : 12)
        .padding(.bottom, compact ? 8 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityLabel("ios.close.keyboard.a7fb38b")
        .zIndex(20)
    }

    private func openKeyboard() {
        showGlobalPalette = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            showKeyboard = true
        }
    }

    private func closeKeyboard() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            showKeyboard = false
        }
    }

    /// Redemande le flux si ScreenCaptureKit s'est arrêté sans faire tomber
    /// la session TLS. Sans cette surveillance, l'interface pouvait afficher
    /// une image puis rester figée après un verrouillage ou un changement
    /// d'écran côté Mac.
    private func maintainScreenStream() async {
        var lastRequestAt = Date.distantPast
        var lastAdaptationAt = Date.distantPast
        var stableSince: Date?
        var isDegraded = false
        var nominalProfile = preferredScreenProfile()

        func requestStream(_ profile: ScreenProfile) {
            lastRequestAt = Date()
            client.startScreenStream(
                maxWidth: profile.maxWidth,
                framesPerSecond: profile.framesPerSecond,
                jpegQuality: profile.jpegQuality,
                owner: streamOwner
            )
        }

        requestStream(nominalProfile)
        while !Task.isCancelled && client.state.isReady {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, client.state.isReady else { return }

            let now = Date()
            let updatedNominalProfile = preferredScreenProfile()
            if updatedNominalProfile != nominalProfile {
                nominalProfile = updatedNominalProfile
                if !isDegraded { requestStream(nominalProfile) }
            }

            let frameAge = now.timeIntervalSince(client.lastScreenFrameAt ?? lastRequestAt)
            if !isDegraded,
               frameAge > 3,
               client.screenStreamStatus.permissionGranted,
               now.timeIntervalSince(lastAdaptationAt) >= 20 {
                isDegraded = true
                stableSince = nil
                lastAdaptationAt = now
                requestStream(ScreenProfile(maxWidth: 720, framesPerSecond: 4, jpegQuality: 0.25))
                continue
            }

            if isDegraded {
                if frameAge <= 2 {
                    stableSince = stableSince ?? now
                } else {
                    stableSince = nil
                }
                if let stableSince,
                   now.timeIntervalSince(stableSince) >= 30,
                   now.timeIntervalSince(lastAdaptationAt) >= 20 {
                    isDegraded = false
                    lastAdaptationAt = now
                    requestStream(nominalProfile)
                }
            } else if frameAge > 5,
                      client.screenStreamStatus.permissionGranted,
                      now.timeIntervalSince(lastRequestAt) > 5 {
                requestStream(nominalProfile)
            }
        }
    }

    private func preferredScreenProfile() -> ScreenProfile {
        guard client.connectionRoute == .nomad else {
            return ScreenProfile(
                maxWidth: 1_280,
                framesPerSecond: Int(screenFrameRate),
                jpegQuality: screenQuality
            )
        }
        if client.connectionIsExpensive || client.connectionIsConstrained {
            return ScreenProfile(maxWidth: 960, framesPerSecond: 5, jpegQuality: 0.32)
        }
        return ScreenProfile(maxWidth: 1_280, framesPerSecond: 8, jpegQuality: 0.40)
    }

    @ViewBuilder
    private var screenPreview: some View {
        ZStack {
            Color.black
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--marketing-screen") {
                MarketingDesktopPreview()
            } else {
                liveScreenPreview
            }
#else
            liveScreenPreview
#endif
        }
        .clipped()
    }

    @ViewBuilder
    private var liveScreenPreview: some View {
        if let frame = client.latestScreenFrame,
           let image = UIImage(data: frame.jpegData) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fit)
        } else if !client.screenStreamStatus.permissionGranted {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text("ios.allow.screen.access.on.the.mac.e835fe8")
                    .font(.footnote.weight(.semibold))
                Text(client.screenStreamStatus.detail ?? AppL10n.text("ios.allow.screen.access.on.the.mac.e835fe8"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 46)
            }
        } else {
            ProgressView("ios.connecting.to.the.mac.screen.e023739")
                .font(.caption)
                .tint(.white)
        }
    }

#if DEBUG
    private struct MarketingDesktopPreview: View {
        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.12, green: 0.17, blue: 0.24), Color(red: 0.23, green: 0.14, blue: 0.24)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Spacer().frame(height: 34)
                        Text("Notes")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.9))
                        ForEach(["Vibe Walkie", "Codex", "Safari"], id: \.self) { item in
                            Text(item)
                                .font(.system(size: 9, weight: item == "Vibe Walkie" ? .semibold : .regular))
                                .foregroundStyle(item == "Vibe Walkie" ? .white : .white.opacity(0.55))
                        }
                        Spacer()
                    }
                    .padding(14)
                    .frame(width: 112)
                    .background(.black.opacity(0.28))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Vibe Walkie")
                            .font(.headline.bold())
                        Text(AppL10n.text("ios.control.the.pointer.keyboard.and.dictation.from.this.iphone.no.2d4c813"))
                            .font(.caption)
                            .lineSpacing(3)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.remoteBlue)
                            .frame(width: 2, height: 18)
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.12))
                }
                // La zone utile commence sous la Dynamic Island : aucun titre
                // ni texte de la fausse fenêtre Mac n'est masqué sur la capture.
                .padding(.top, 54)
            }
        }
    }
#endif

    private func screenHeader(topInset: CGFloat, compact: Bool) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: compact ? 14 : 16, weight: .semibold))
                    .frame(width: compact ? 38 : 44, height: compact ? 38 : 44)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            Label(
                client.connectionRoute == .local ? "ios.local.8c31e6e" : "ios.remote.tailscale.8abdd7e",
                systemImage: client.connectionRoute == .local ? "wifi" : "network"
            )
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 6 : 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.top, topInset + (compact ? 2 : 4))
    }

    private func floatingCommandDock(compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 5) {
            if pttSide == .left {
                pttButton(compact: compact)
            }

            commandButton(AppL10n.text("ios.keyboard.cd896f5"), systemImage: "keyboard", compact: compact) { openKeyboard() }
            commandButton(AppL10n.text("ios.clear.e4750da"), systemImage: "delete.left", compact: compact) { sendKey(.backspace) }
            commandButton(AppL10n.text("ios.space.91bdaf6"), systemImage: "space", compact: compact) { sendKey(.space) }
            commandButton(AppL10n.text("ios.return.d9c7efe"), systemImage: "return", compact: compact) { sendKey(.enter) }
            commandButton(
                AppL10n.text("ios.global.a258b30"),
                systemImage: showGlobalPalette ? "xmark" : "circle.grid.2x2.fill",
                compact: compact,
                isActive: showGlobalPalette
            ) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.84)) {
                    showGlobalPalette.toggle()
                }
            }

            if pttSide == .right {
                pttButton(compact: compact)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func pttButton(compact: Bool) -> some View {
        PTTButton(dictation: dictation)
            .scaleEffect(compact ? 0.56 : 0.60)
            .frame(width: compact ? 64 : 66, height: compact ? 56 : 62)
    }

    @ViewBuilder
    private func globalPalette(compact: Bool, bottomInset: CGFloat) -> some View {
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
            .frame(maxWidth: compact ? 440 : .infinity)
            .padding(.horizontal, 10)
            .padding(.bottom, bottomInset + (compact ? 64 : 72))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .transition(.scale(scale: 0.92, anchor: pttSide == .right ? .bottomTrailing : .bottomLeading).combined(with: .opacity))
            .zIndex(10)
        }
    }

    private func commandButton(
        _ title: String,
        systemImage: String,
        compact: Bool,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticFeedback.shared.tick()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 15 : 17, weight: .semibold))
                Text(title)
                    .font(.system(size: compact ? 7 : 8, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? Color.remoteBlue : .white.opacity(0.9))
            .frame(width: compact ? 46 : 48, height: compact ? 44 : 50)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous)
                    .stroke(isActive ? Color.remoteBlue.opacity(0.75) : .white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func sendKey(_ key: RemoteKey) {
        client.sendFireAndForget(type: .keyPress, payload: KeyPressPayload(key: key))
    }

    private func perform(_ action: ControlButtonAction) {
        switch action {
        case .none:
            showControlConfigurator = true
        case .standardKey(let key):
            HapticFeedback.shared.tick()
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
            openKeyboard()
        }
    }
}
