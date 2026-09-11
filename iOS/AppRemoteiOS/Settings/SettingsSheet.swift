import SwiftUI
import RemoteCore

private func hostSymbol(for platform: HostPlatform) -> String {
    switch platform {
    case .macOS: "desktopcomputer"
    case .windows: "pc"
    case .linux: "server.rack"
    }
}

/// Sélecteur court accessible depuis le bouton en haut à gauche de la
/// télécommande. Il ferme la feuille dès qu'une nouvelle cible est choisie.
struct HostSwitcherView: View {
    @EnvironmentObject private var client: HostConnectionClient
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(client.pairedHosts) { host in
                        Button {
                            guard host.id != client.selectedHostID else {
                                dismiss()
                                return
                            }
                            HapticFeedback.shared.tick()
                            client.selectHost(host.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: hostSymbol(for: host.platform))
                                    .font(.title3)
                                    .foregroundStyle(
                                        host.id == client.selectedHostID ? Color.remoteBlue : .secondary
                                    )
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(host.name)
                                        .foregroundStyle(.primary)
                                    Text(host.id == client.selectedHostID ? selectedStatusText : AppL10n.text("ios.paired.6f91b17"))
                                        .font(.caption)
                                        .foregroundStyle(
                                            host.id == client.selectedHostID && client.state.isReady ? .green : .secondary
                                        )
                                }

                                Spacer()
                                if host.id == client.selectedHostID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.remoteBlue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("ios.choose.a.mac.c0cacb9")
                } footer: {
                    Text("ios.the.remote.controls.one.mac.at.a.time.0f42474")
                }

                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("ios.add.8d39b2a", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("ios.my.macs.52ba7f6")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("ios.close.711e5f2") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                PairingScannerView().environmentObject(client)
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private var selectedStatusText: String {
        switch client.state {
        case .ready: return AppL10n.text("ios.connected.e92b0f9")
        case .connecting: return AppL10n.text("ios.connecting.280398a")
        case .pairing: return AppL10n.text("ios.pairing.46d2c0d")
        case .awaitingApproval: return AppL10n.text("ios.approval.required.b4ebf21")
        case .searching: return AppL10n.text("ios.searching.d074331")
        case .failed: return AppL10n.text("ios.unavailable.3f0806b")
        case .idle: return AppL10n.text("ios.disconnected.137ba3f")
        }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject private var client: HostConnectionClient
    @Environment(\.dismiss) private var dismiss

    @State private var showScanner = false
    @AppStorage("trackpadSensitivity") private var trackpadSensitivity: Double = TrackpadSettings.defaultPointerSpeed
    @AppStorage("scrollSensitivity") private var scrollSensitivity: Double = TrackpadSettings.defaultScrollSpeed
    @AppStorage("screenQuality") private var screenQuality: Double = 0.45
    @AppStorage("screenFrameRate") private var screenFrameRate: Double = 10
    @AppStorage(KeyboardInputMode.storageKey) private var keyboardInputMode: KeyboardInputMode = .direct
    @AppStorage(RemoteScreenPTTSide.storageKey) private var remoteScreenPTTSide: RemoteScreenPTTSide = .right
    @AppStorage(AppLanguage.storageKey) private var appLanguageIdentifier = AppLanguage.systemIdentifier
    @AppStorage(DictationLanguage.storageKey) private var dictationLanguageIdentifier = DictationLanguage.automaticIdentifier
    @State private var dictationLocales: [SpeechLocaleOption] = []
    @State private var isLoadingDictationLocales = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(client.pairedHosts) { host in
                        Button {
                            client.selectHost(host.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: hostSymbol(for: host.platform))
                                    .foregroundStyle(host.id == client.selectedHostID ? Color.remoteBlue : .secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name)
                                        .foregroundStyle(.primary)
                                    if host.id == client.selectedHostID {
                                        Text(macStatusText)
                                            .font(.caption)
                                            .foregroundStyle(client.state.isReady ? .green : .secondary)
                                    }
                                }
                                Spacer()
                                if host.id == client.selectedHostID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.remoteBlue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("ios.forget.a7ff2f5", role: .destructive) {
                                client.forgetHost(host.id)
                            }
                        }
                    }

                    Button {
                        showScanner = true
                    } label: {
                        Label("ios.add.8d39b2a", systemImage: "plus")
                    }
                } header: {
                    Text("ios.my.macs.52ba7f6")
                } footer: {
                    Text("ios.tap.a.mac.to.switch.the.remote.each.companion.must.51a9305")
                }

                Section("ios.connection.61d6950") {
                    LabeledContent("ios.status.de4dd03", value: statusText)
                    LabeledContent("ios.route.33db21d") {
                        Label(routeText, systemImage: routeSymbol)
                            .foregroundStyle(routeColor)
                    }
                    if !client.inputControlReady {
                        Label("ios.accessibility.is.disabled.on.the.mac.6de7b8e", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                    if client.isPaired {
                        if client.isNomadModeEnabled {
                            NavigationLink {
                                NomadSettingsView()
                                    .environmentObject(client)
                            } label: {
                                Label("ios.remote.mode.6c2b26c", systemImage: "network")
                            }
                        }
                        Button("ios.forget.selected.mac.13716e5", role: .destructive) { client.forgetHost() }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("ios.pointer.speed.28fb9b9") {
                            Text("\(trackpadSensitivity, specifier: "%.2g")×")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $trackpadSensitivity, in: TrackpadSettings.pointerRange, step: 0.1) {
                            Text("ios.pointer.speed.28fb9b9")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise")
                        } maximumValueLabel: {
                            Image(systemName: "hare")
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("ios.scroll.speed.addea81") {
                            Text("\(scrollSensitivity, specifier: "%.2g")×")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $scrollSensitivity, in: TrackpadSettings.scrollRange, step: 0.1) {
                            Text("ios.scroll.speed.addea81")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise")
                        } maximumValueLabel: {
                            Image(systemName: "hare")
                        }
                    }
                } header: {
                    Text("ios.trackpad.c8dc586")
                } footer: {
                    Text("ios.pointer.and.scroll.speeds.can.be.adjusted.independently.up.to.23da271")
                }

                Section {
                    NavigationLink {
                        ControlConfiguratorView()
                            .environmentObject(client)
                    } label: {
                        Label("ios.configure.button.panel.a006d38", systemImage: "rectangle.3.group")
                    }
                } header: {
                    Text("ios.controls.0e3118a")
                } footer: {
                    Text("ios.seven.customizable.positions.surround.the.central.push.to.talk.button.041c814")
                }

                Section {
                    Picker("ios.input.mode.dd95c13", selection: $keyboardInputMode) {
                        ForEach(KeyboardInputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                } header: {
                    Text("ios.keyboard.cd896f5")
                } footer: {
                    Text("ios.in.editor.mode.the.draft.stays.on.the.iphone.until.5b5d191")
                }

                Section {
                    LabeledContent("ios.current.connection.8cf8ef6") {
                        Label(
                            routeText,
                            systemImage: routeSymbol
                        )
                        .foregroundStyle(client.state.isReady ? .green : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("ios.screen.quality.d18a3e1") {
                            Text("\(Int(screenQuality * 100)) %")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $screenQuality, in: 0.25...0.7, step: 0.05)
                    }

                    Picker("ios.frame.rate.d190183", selection: $screenFrameRate) {
                        Text("ios.economy.6.fps.db96528").tag(6.0)
                        Text("ios.balanced.10.fps.27a7782").tag(10.0)
                        Text("ios.smooth.15.fps.d425e33").tag(15.0)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("ios.ptt.button.position.9006a04")
                            .font(.subheadline)
                        Picker("ios.ptt.button.position.9006a04", selection: $remoteScreenPTTSide) {
                            ForEach(RemoteScreenPTTSide.allCases) { side in
                                Text(side.title).tag(side)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                } header: {
                    Text("ios.screen.view.b5645a8")
                } footer: {
                    Text("ios.screen.view.stays.encrypted.between.iphone.and.mac.and.adapts.5eedf76")
                }

                Section {
                    Picker("ios.interface.language.3e91b63", selection: $appLanguageIdentifier) {
                        Text("ios.device.language.d5f4dba").tag(AppLanguage.systemIdentifier)
                        ForEach(AppLanguage.interfaceLocaleIdentifiers, id: \.self) { identifier in
                            Text(AppLanguage.displayName(
                                for: identifier,
                                in: AppLanguage.locale(for: appLanguageIdentifier)
                            )).tag(identifier)
                        }
                    }

                    Picker("ios.dictation.language.6514df0", selection: $dictationLanguageIdentifier) {
                        Text("ios.device.language.d5f4dba").tag(DictationLanguage.automaticIdentifier)
                        ForEach(dictationLocales) { option in
                            Text(option.displayName(in: AppLanguage.locale(for: appLanguageIdentifier)))
                                .tag(option.id)
                        }
                    }

                    if isLoadingDictationLocales {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("ios.checking.on.device.dictation.9ddcbab")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if let selectedDictationLocale, !selectedDictationLocale.isInstalled {
                        Label("ios.the.on.device.dictation.model.must.be.downloaded.edc4230", systemImage: "icloud.and.arrow.down")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("ios.languages.2d259f0")
                } footer: {
                    Text("ios.your.voice.is.processed.on.this.iphone.using.apple.models.620b855")
                }

            }
            .navigationTitle("ios.vibe.walkie.111e6dd")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("ios.ok.565339b") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                PairingScannerView().environmentObject(client)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: appLanguageIdentifier) {
            isLoadingDictationLocales = true
            guard #available(iOS 26.0, *) else {
                dictationLocales = []
                isLoadingDictationLocales = false
                return
            }
            dictationLocales = await AppleSpeechLocaleCatalog.options(
                displayLocale: AppLanguage.locale(for: appLanguageIdentifier)
            )
            isLoadingDictationLocales = false
        }
    }

    private var selectedDictationLocale: SpeechLocaleOption? {
        guard dictationLanguageIdentifier != DictationLanguage.automaticIdentifier else { return nil }
        return dictationLocales.first { $0.id == dictationLanguageIdentifier }
    }

    private var statusText: String {
        switch client.state {
        case .ready(let name): return AppL10n.format("ios.connected.to.value.421b271", name)
        case .connecting(let name): return AppL10n.format("ios.connecting.to.value.f5c4e11", name)
        case .pairing(let name, let code): return AppL10n.format("ios.pairing.with.value.value.2bc2405", name, code)
        case .awaitingApproval(let name, let code): return AppL10n.format("ios.allow.value.on.the.mac.value.6a374f8", name, code)
        case .searching: return AppL10n.text("ios.searching.d074331")
        case .failed(let code): return AppL10n.remoteError(code)
        case .idle: return AppL10n.text("ios.no.paired.mac.d113f3e")
        }
    }

    private var macStatusText: String {
        switch client.state {
        case .ready: return AppL10n.text("ios.connected.e92b0f9")
        case .connecting: return AppL10n.text("ios.connecting.280398a")
        case .pairing: return AppL10n.text("ios.pairing.46d2c0d")
        case .awaitingApproval: return AppL10n.text("ios.approval.required.b4ebf21")
        case .searching: return AppL10n.text("ios.searching.d074331")
        case .failed: return AppL10n.text("ios.unavailable.3f0806b")
        case .idle: return AppL10n.text("ios.disconnected.137ba3f")
        }
    }

    private var routeText: String {
        if client.state.isReady {
            return client.connectionRoute == .local ? AppL10n.text("ios.local.8c31e6e") : AppL10n.text("ios.remote.tailscale.8abdd7e")
        }
        return client.nomadEndpoint == nil ? AppL10n.text("ios.tailscale.disabled.55bdec3") : AppL10n.text("ios.mac.unreachable.4860c38")
    }

    private var routeSymbol: String {
        if client.state.isReady {
            return client.connectionRoute == .local ? "wifi" : "network"
        }
        return client.nomadEndpoint == nil ? "network.slash" : "exclamationmark.icloud"
    }

    private var routeColor: Color {
        client.state.isReady ? .green : .secondary
    }

    private func keyboardModeDescription(_ mode: KeyboardInputMode, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: mode.systemImage)
                .foregroundStyle(keyboardInputMode == mode ? Color.remoteBlue : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(mode.title)
                        .font(.subheadline.weight(.semibold))
                    if keyboardInputMode == mode {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.remoteBlue)
                    }
                }
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

}

private struct NomadSettingsView: View {
    @EnvironmentObject private var client: HostConnectionClient

    var body: some View {
        List {
            Section {
                LabeledContent("ios.status.de4dd03") {
                    Label(statusText, systemImage: statusSymbol)
                        .foregroundStyle(statusColor)
                }
                if let endpoint = client.nomadEndpoint {
                    LabeledContent("Mac", value: endpoint.magicDNSName)
                        .font(.footnote)
                }
            } header: {
                Text("ios.connection.61d6950")
            } footer: {
                Text("ios.vibe.walkie.always.tries.the.local.network.first.then.tailscale.09b2bf5")
            }

            Section("ios.set.up.on.iphone.b33974c") {
                Link(destination: URL(string: "https://tailscale.com/download/ios")!) {
                    Label("ios.download.tailscale.ae8b630", systemImage: "arrow.up.right.square")
                }

                Link(destination: URL(string: "https://tailscale.com/docs/features/client/ios-vpn-on-demand")!) {
                    Label("ios.view.official.guide.b2bd04d", systemImage: "arrow.up.right.square")
                }
            }

            Section {
                Button {
                    client.reconnectNow()
                } label: {
                    Label("ios.test.connection.73f42a6", systemImage: "bolt.horizontal.circle")
                }
                .disabled(!client.isPaired)
            } footer: {
                Text("ios.the.connection.remains.direct.to.the.mac.no.account.tailscale.246dd09")
            }
        }
        .navigationTitle("ios.remote.mode.6c2b26c")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusText: String {
        if client.state.isReady {
            return client.connectionRoute == .local ? AppL10n.text("ios.local.8c31e6e") : AppL10n.text("ios.remote.tailscale.8abdd7e")
        }
        return client.nomadEndpoint == nil ? AppL10n.text("ios.tailscale.disabled.55bdec3") : AppL10n.text("ios.mac.unreachable.4860c38")
    }

    private var statusSymbol: String {
        if client.state.isReady {
            return client.connectionRoute == .local ? "wifi" : "network"
        }
        return client.nomadEndpoint == nil ? "network.slash" : "exclamationmark.icloud"
    }

    private var statusColor: Color {
        client.state.isReady ? .green : .orange
    }
}

private struct NomadStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.remoteBlue, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
