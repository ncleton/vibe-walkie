import SwiftUI
import CoreImage.CIFilterBuiltins
import RemoteCore

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var server: MacConnectionServer
    @EnvironmentObject private var permissions: PermissionCoordinator
    @EnvironmentObject private var authority: PairingAuthority
    @EnvironmentObject private var peers: ApprovedPeersStore
    @EnvironmentObject private var tailscale: TailscaleCoordinator
    @EnvironmentObject private var updates: UpdateController
    @EnvironmentObject private var postureCoach: PostureCoachController
    @State private var showResetConfirmation = false
    @State private var showControlConfigurator = false
    @State private var showNomadSetup = false
    @State private var showOnboarding = false
    @AppStorage("vibe.walkie.mac.onboarding.v2.completed") private var didCompleteOnboarding = false
    @AppStorage(PermissionCoordinator.screenCaptureResumeKey)
    private var resumeAfterScreenCapture = false
    @AppStorage("vibe.walkie.mac.nomad.discovery.v1.dismissed") private var didDismissNomadDiscovery = false

    var body: some View {
        ScrollView {
            content
        }
        .frame(width: 340)
        .frame(maxHeight: 600)
        .background(Color.remoteBackground)
        .preferredColorScheme(.dark)
        .onChange(of: permissions.accessibilityGranted) { _, _ in beginFirstPairingIfReady() }
        .onChange(of: permissions.screenCaptureReady) { _, _ in
            server.screenCapturePermissionDidChange(permissions.screenCaptureReady)
        }
        .onChange(of: permissions.screenCaptureRequiresRelaunch) { _, requiresRelaunch in
            if requiresRelaunch, !showOnboarding {
                permissions.relaunchToApplyScreenCapturePermission()
            }
        }
        .onChange(of: server.isListening) { _, _ in beginFirstPairingIfReady() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
            if !showOnboarding, permissions.screenCaptureRequiresRelaunch {
                permissions.relaunchToApplyScreenCapturePermission()
            }
        }
        .task {
            if InstallationLocation.isSuitable,
               (resumeAfterScreenCapture
                || !didCompleteOnboarding
                || !permissions.accessibilityGranted) {
                showOnboarding = true
            }
            beginFirstPairingIfReady()
            if NomadFeatureFlag.isEnabled {
                await tailscale.refresh()
                server.setNomadEndpoint(tailscale.activeEndpoint)
            }
        }
        .onChange(of: tailscale.activeEndpoint) { _, endpoint in
            server.setNomadEndpoint(endpoint)
        }
        .confirmationDialog(
            "mac.reset.vibe.walkie.c3ae48c",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("mac.reset.pairings.and.identity.da50dbb", role: .destructive) {
                server.resetEverything()
            }
            Button("mac.cancel.46ad391", role: .cancel) {}
        } message: {
            Text("mac.all.iphones.will.need.to.be.paired.again.ed49b37")
        }
        .sheet(isPresented: $showControlConfigurator) {
            MacControlConfiguratorView()
                .environmentObject(server)
        }
        .sheet(isPresented: $showNomadSetup) {
            NomadSetupView()
                .environmentObject(tailscale)
                .environmentObject(server)
                .environmentObject(authority)
        }
        .sheet(isPresented: $showOnboarding) {
            CompanionOnboardingView {
                didCompleteOnboarding = true
                showOnboarding = false
                beginFirstPairingIfReady()
            }
            .environmentObject(permissions)
            .environmentObject(server)
            .environmentObject(authority)
            .environmentObject(tailscale)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if updates.presentationState.isVisible {
                updateSection
            }
            if !InstallationLocation.isSuitable {
                installationSection
            } else {
                if shouldShowNomadDiscovery { nomadDiscoveryBanner }
                if peers.peers.allSatisfy(\.isRevoked) { welcomeSection }
                permissionSection
                postureCoachSection

                if let pending = authority.pendingApproval {
                    approvalSection(pending)
                } else if let session = authority.activeSession, !session.payload.isExpired {
                    pairingSection(session)
                }

                peersSection
                if NomadFeatureFlag.isEnabled { nomadSection }
                controlsSection
            }
            footer
        }
        .padding(14)
    }

    private var welcomeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("mac.welcome.6121f20").font(.headline)
            Text(
                NomadFeatureFlag.isEnabled
                    ? "Aucun compte Vibe Walkie n’est nécessaire. Les commandes restent entre cet iPhone et ce Mac, en local ou via votre réseau Tailscale facultatif."
                    : "Aucun compte n’est nécessaire. Les commandes restent entre cet iPhone et ce Mac sur votre réseau local."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .remoteCard()
    }

    private var installationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("mac.move.vibe.walkie.to.applications.dc3ada8", systemImage: "arrow.down.app.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("mac.the.app.was.opened.from.the.installation.disk.drag.it.015b0ae")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("mac.open.applications.25aa8d9") { InstallationLocation.openApplicationsFolder() }
                .buttonStyle(.borderedProminent)
                .tint(Color.remoteBlue)
        }
        .remoteCard()
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.remoteBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("mac.update.available.0d130ab")
                        .font(.headline)
                    if let version = updates.presentationState.version {
                        Text(MacL10n.format("mac.version.value.is.ready.to.install.03ed2d8", version))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                updates.installAvailableUpdate()
            } label: {
                HStack(spacing: 8) {
                    if updates.presentationState.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("mac.update.now.c2511f5")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.remoteBlue)
            .disabled(updates.presentationState.isBusy)

            if updates.presentationState.isBusy {
                Text("mac.vibe.walkie.will.relaunch.automatically.after.the.update.9b9d835")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .remoteCard()
    }

    private func approvalSection(_ pending: PairingAuthority.PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("mac.allow.this.iphone.f90f9ed", systemImage: "iphone.badge.checkmark")
                .font(.headline)
            Text(pending.peer.name)
                .font(.title3.weight(.semibold))
            Text(MacL10n.format("mac.code.value.74a3b10", pending.confirmationCode))
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .foregroundStyle(Color.remoteBlue)
            Text("mac.pointer.keyboard.and.screen.control.will.be.granted.only.after.fd007ac")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("mac.allow.5fa07ae") { server.approvePairing(pending.id) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.remoteBlue)
                Button("mac.deny.283348d", role: .destructive) { server.denyPairing(pending.id) }
                    .buttonStyle(.bordered)
            }
        }
        .remoteCard()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("mac.vibe.walkie.111e6dd").font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.56))
            }
            Spacer()
        }
    }

    private var statusColor: Color {
        if !permissions.accessibilityGranted { return .orange }
        if server.connectedPeerName != nil { return .green }
        return server.isListening ? .blue : .red
    }

    private var statusText: String {
        if let error = server.lastError { return error }
        if !permissions.accessibilityGranted { return MacL10n.text("mac.accessibility.required.8ac4820") }
        if let peer = server.connectedPeerName { return MacL10n.format("mac.connected.to.value.421b271", peer) }
        return server.isListening ? MacL10n.text("mac.waiting.for.an.iphone.3454e98") : MacL10n.text("mac.service.stopped.6a46108")
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(
                    "mac.mac.control.e859c34",
                    systemImage: permissions.accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(permissions.accessibilityGranted ? .green : .orange)
                Spacer()
                Text(permissions.accessibilityGranted ? "Prêt" : "Requis")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !permissions.accessibilityGranted {
                Text("mac.vibe.walkie.needs.accessibility.access.to.read.the.active.field.f7cd725")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("mac.request.913c40f") { permissions.guideAccessibilityAccess() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.remoteBlue)
                    Button("mac.open.settings.239783c") { permissions.openAccessibilitySettings() }
                        .buttonStyle(.bordered)
                }
            }

            if peers.peers.contains(where: { !$0.isRevoked }) {
                HStack {
                    Label(
                        "mac.screen.view.b5645a8",
                        systemImage: screenCapturePermissionIcon
                    )
                    .foregroundStyle(permissions.screenCaptureReady ? .green : .secondary)
                    Spacer()
                    if !permissions.screenCaptureGranted {
                        Button("mac.request.913c40f") {
                            permissions.requestScreenCapture()
                        }
                        .buttonStyle(.borderless)
                    }
                    if permissions.screenCaptureRequiresRelaunch {
                        Button("mac.continue.0f4bb2d") {
                            permissions.relaunchToApplyScreenCapturePermission()
                        }
                        .buttonStyle(.borderless)
                    } else if permissions.screenCaptureReadiness == .verifying {
                        ProgressView()
                            .controlSize(.small)
                    } else if permissions.screenCaptureReadiness == .failed {
                        Button("mac.check.again.72912f6") {
                            permissions.verifyScreenCaptureReadiness(force: true)
                        }
                        .buttonStyle(.borderless)
                    } else if permissions.hasRequestedScreenCapture,
                              !permissions.screenCaptureGranted {
                        Button {
                            permissions.openScreenCaptureSettings()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .buttonStyle(.borderless)
                        .help("mac.screen.view.settings.e789af6")
                    }
                }
            }
        }
        .remoteCard()
    }

    private var screenCapturePermissionIcon: String {
        if permissions.screenCaptureReady { return "checkmark.rectangle.fill" }
        if permissions.screenCaptureRequiresRelaunch { return "arrow.clockwise.circle.fill" }
        if permissions.screenCaptureReadiness == .verifying { return "hourglass" }
        return "rectangle.dashed.badge.record"
    }

    private func pairingSection(_ session: PairingAuthority.PairingSession) -> some View {
        let payload = session.payload
        let isNomad = payload.nomadEndpoint != nil
        return VStack(alignment: .leading, spacing: 8) {
            Text(isNomad ? "Appairage Nomade" : "Appairage en cours").font(.subheadline.bold())
            if let image = PairingQRCodeRenderer.image(for: session.encodedPayload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("mac.pairing.qr.code.77b59f3")
            }
            Text(MacL10n.format("mac.code.value.18fbe57", payload.confirmationCode))
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(Color.remoteBlue)
                .frame(maxWidth: .infinity)
            Text(
                isNomad
                    ? "Partagez le QR ou le code avec l’iPhone. Une personne devra confirmer ici dans les 60 secondes suivant sa connexion."
                    : "Scannez ce code avec Vibe Walkie sur l'iPhone. Il reste identique pendant 2 minutes."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if isNomad {
                    Button("mac.copy.code.58d4532") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.encodedPayload, forType: .string)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.remoteBlue)
                }
                Button("mac.cancel.46ad391") { authority.endPairing() }
                    .buttonStyle(.bordered)
            }
        }
        .remoteCard()
    }

    private var peersSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("mac.allowed.iphones.75962c2").font(.subheadline.bold())
                Spacer()
                Button {
                    beginPairing()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(server.certificateFingerprint == nil)
                .help("mac.pair.an.iphone.44c3c84")
            }

            if activePeers.isEmpty {
                Text("mac.no.paired.iphone.644c9ef").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(activePeers) { peer in
                    ApprovedPeerRow(peer: peer)
                }
            }

            if peers.peers.contains(where: { !$0.isRevoked }) {
                HStack {
                    Label(
                        tailscale.isEnabled ? "Connexion locale ou Nomade chiffrée" : "Connexion locale chiffrée",
                        systemImage: "lock.fill"
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("mac.revoke.all.776dd82", role: .destructive) {
                            for peer in peers.peers where !peer.isRevoked { server.disconnectPeer(peer.id) }
                            peers.revokeAll()
                        }
                        Button("mac.reset.everything.9877873", role: .destructive) { showResetConfirmation = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

        }
        .remoteCard()
    }

    private var controlsSection: some View {
        Button {
            showControlConfigurator = true
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("mac.iphone.controls.5c65e13", systemImage: "rectangle.3.group.fill")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("mac.edit.42e3760")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.remoteBlue)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(Color.remoteBlue)
                }
                MacControlMiniPreview(configuration: server.controlConfiguration)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .remoteCard()
    }

    private var postureCoachSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(postureMenuTint.opacity(0.16))
                        .frame(width: 34, height: 34)
                    Image(systemName: postureMenuIcon)
                        .foregroundStyle(postureMenuTint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Module Santé")
                            .font(.subheadline.bold())
                        Text("BÊTA")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.remoteBlue)
                    }
                    Text(postureMenuSubtitle)
                        .font(.caption2)
                        .foregroundStyle(postureCoach.evaluation.severity >= .warning
                            ? postureMenuTint
                            : .secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                healthEntryButton(
                    title: "Suivi en direct",
                    systemImage: "video.fill"
                ) {
                    openHealthWindow {
                        postureCoach.showExpandedLiveTracking()
                    }
                }
                healthEntryButton(
                    title: "Dashboard",
                    systemImage: "chart.bar.xaxis"
                ) {
                    openHealthWindow {
                        postureCoach.showHealthDashboard()
                    }
                }
            }
        }
        .remoteCard()
    }

    private func healthEntryButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openHealthWindow(select destination: () -> Void) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        destination()
        openWindow(id: "posture-coach")
        NotificationCenter.default.post(name: .postureCoachShowPreview, object: nil)
    }

    private var postureMenuTint: Color {
        switch postureCoach.evaluation.severity {
        case .correction: .red
        case .warning: .orange
        case .good: .green
        case .unavailable: .gray
        }
    }

    private var postureMenuIcon: String {
        switch postureCoach.evaluation.severity {
        case .correction: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .good, .unavailable: "figure.stand"
        }
    }

    private var postureMenuSubtitle: String {
        if postureCoach.evaluation.severity >= .warning {
            return postureCoach.evaluation.primaryIssue?.message ?? "Mauvaise posture détectée"
        }
        if postureCoach.phase == .monitoring, postureCoach.isPreviewHidden {
            return postureCoach.soundEnabled
                ? "Analyse active · bulle masquée · son activé"
                : "Analyse active · bulle masquée · son coupé"
        }
        if postureCoach.walkingSessions.isWalking {
            return "Marche détectée · prêt à croiser avec Apple Santé"
        }
        return "Module optionnel · posture et marche analysées sur ce Mac"
    }

    private var nomadSection: some View {
        Button {
            showNomadSetup = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tailscale.isEnabled ? "globe.badge.chevron.backward" : "globe")
                    .foregroundStyle(tailscale.isEnabled ? .green : Color.remoteBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("mac.remote.mode.6c2b26c").font(.subheadline.bold())
                    Text(tailscale.isEnabled ? "Compatible avec Tailscale · Activé" : "Contrôlez ce Mac hors du Wi‑Fi local")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(Color.remoteBlue)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .remoteCard()
    }

    private var shouldShowNomadDiscovery: Bool {
        NomadFeatureFlag.isEnabled && !didDismissNomadDiscovery && !tailscale.isEnabled
    }

    private var nomadDiscoveryBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.remoteBlue.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Image(systemName: "globe.badge.chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.remoteBlue)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("mac.remote.mode.6c2b26c")
                        .font(.headline)
                    Text("mac.nomad.discovery.body.f6e2a71")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Link(destination: TailscaleCoordinator.whatIsTailscaleURL) {
                Label("tailscale.com/docs", systemImage: "arrow.up.right.square")
                    .font(.caption2.weight(.semibold))
            }

            HStack {
                Button("mac.configure.later.17b69c4") {
                    didDismissNomadDiscovery = true
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("mac.start.95e0ef0") {
                    didDismissNomadDiscovery = true
                    showNomadSetup = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.remoteBlue)
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [Color.remoteBlue.opacity(0.15), Color.remoteCard],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.remoteBlue.opacity(0.32), lineWidth: 1)
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if server.hasCompletedFirstCommand {
                Toggle("mac.launch.at.login.13962bf", isOn: Binding(
                    get: { permissions.launchesAtLogin },
                    set: { permissions.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                Text("mac.optional.keep.the.companion.ready.after.you.sign.in.d4a38bf")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(Bundle.main.appVersion).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showOnboarding = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("mac.welcome.6121f20")
                Button("mac.check.for.updates.a581402") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
                Button("mac.quit.4974161") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private var activePeers: [ApprovedPeer] {
        peers.peers.filter { !$0.isRevoked }
    }

    private struct ApprovedPeerRow: View {
        let peer: ApprovedPeer
        @EnvironmentObject private var peers: ApprovedPeersStore
        @EnvironmentObject private var server: MacConnectionServer
        @State private var name: String

        init(peer: ApprovedPeer) {
            self.peer = peer
            _name = State(initialValue: peer.name)
        }

        var body: some View {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    TextField("mac.iphone.name.c868e4b", text: $name)
                        .textFieldStyle(.plain)
                        .onSubmit { peers.rename(peer.id, to: name) }
                    Text(peer.isRevoked ? "Révoqué" : "Autorisé")
                        .font(.caption2)
                        .foregroundStyle(peer.isRevoked ? .red : .secondary)
                }
                Spacer()
                if !peer.isRevoked {
                    Button("mac.revoke.81954c8") {
                        peers.revoke(peer.id)
                        server.disconnectPeer(peer.id)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func beginPairing() {
        guard let fingerprint = server.certificateFingerprint else { return }
        let endpoint = tailscale.isEnabled ? tailscale.activeEndpoint : nil
        _ = authority.beginPairing(
            macName: Host.current().localizedName ?? "Mac",
            serviceName: server.serviceName,
            fingerprint: fingerprint,
            nomadEndpoint: endpoint,
            validity: endpoint == nil ? VibeWalkieInfo.pairingWindow : VibeWalkieInfo.nomadPairingWindow
        )
    }

    /// Le premier QR apparaît dès que l'identité TLS, le service local et
    /// l'autorisation Accessibilité sont prêts. Les lancements suivants ne
    /// rouvrent jamais l'appairage sans action de l'utilisateur.
    private func beginFirstPairingIfReady() {
        guard permissions.accessibilityGranted,
              server.isListening,
              peers.peers.isEmpty,
              !authority.isPairing,
              authority.pendingApproval == nil else { return }
        beginPairing()
    }

}

/// Rend exactement le même QR dans l'onboarding et dans la fenêtre principale.
/// Garder un seul encodeur évite qu'un écran affiche un pictogramme décoratif
/// pendant que l'autre contient la vraie charge d'appairage.
@MainActor
enum PairingQRCodeRenderer {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for encoded: String) -> NSImage? {
        guard !encoded.isEmpty else { return nil }
        let cacheKey = encoded as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(encoded.utf8)
        // Le niveau L suffit pour un écran propre et réduit la densité du QR.
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }

        // Quatre modules blancs constituent la « quiet zone » recommandée.
        // Trois points par module donnent des arêtes nettes sur écran Retina.
        let quietZone: CGFloat = 4
        let extent = output.extent.integral
        let paddedExtent = extent.insetBy(dx: -quietZone, dy: -quietZone)
        let background = CIImage(color: CIColor.white).cropped(to: paddedExtent)
        let padded = output.composited(over: background)
        let moduleScale: CGFloat = 3
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: moduleScale, y: moduleScale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: scaled.extent.width, height: scaled.extent.height)
        )
        cache.setObject(image, forKey: cacheKey)
        return image
    }
}

private struct MacControlMiniPreview: View {
    let configuration: ControlConfiguration

    var body: some View {
        HStack(spacing: 5) {
            ForEach(ControlZone.allCases) { zone in
                let button = configuration.button(in: zone)
                MenuBarControlIcon(icon: button.icon)
                    .frame(width: 15, height: 15)
                    .frame(maxWidth: .infinity, minHeight: 31)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                    .help(button.title)
            }
            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.remoteBlue)
                .frame(maxWidth: .infinity, minHeight: 31)
                .background(Color.remoteBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .help("mac.global.a258b30")
        }
    }
}

private struct MenuBarControlIcon: View {
    let icon: ControlButtonIcon

    var body: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
        case .customImage(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "photo")
                    .resizable()
                    .scaledToFit()
            }
        }
    }
}

extension View {
    func remoteCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.remoteCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.07), lineWidth: 1)
                    )
            )
    }
}

extension Color {
    static let remoteBackground = Color(red: 0.035, green: 0.038, blue: 0.042)
    static let remoteCard = Color(red: 0.12, green: 0.125, blue: 0.13)
    static let remoteBlue = Color(red: 0.02, green: 0.56, blue: 0.98)
}
