@preconcurrency import AVFoundation
import AppKit
import RemoteCore
import SwiftUI

struct PostureCoachView: View {
    @EnvironmentObject private var controller: PostureCoachController
    @EnvironmentObject private var walkingSessions: WorkWalkingSessionStore
    @EnvironmentObject private var server: MacConnectionServer
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var showsTechnicalDetails = false
    @State private var isHoveringBubble = false
    @State private var dashboardCelebrationTrigger = 0
    @State private var dashboardRevealProgress = 0.0
    @State private var dashboardHaloPhase = false
    @State private var showsLongevityEvidence = false

    private var usesCompactPresentation: Bool {
        controller.destination == .liveTracking
            && controller.phase.usesCompactBubble
            && !controller.keepsLiveTrackingExpanded
    }

    var body: some View {
        Group {
            if controller.destination == .dashboard {
                healthDashboard
            } else if usesCompactPresentation {
                compactCoach
            } else {
                fullCoach
            }
        }
        .preferredColorScheme(.dark)
        .background(
            PostureWindowLifecycleObserver(
                controller: controller,
                isCompact: usesCompactPresentation
            )
        )
    }

    private var fullCoach: some View {
        VStack(spacing: 0) {
            toolbar
            healthSummary
            ZStack {
                Color.black
                CameraPreviewView(session: controller.session)
                    .opacity(controller.phase == .idle ? 0 : 1)
                PostureOverlayView(
                    pose: controller.currentPose,
                    ghostPose: controller.ghostPose,
                    face: controller.facePose,
                    viewpoint: controller.viewpoint,
                    evaluation: controller.evaluation,
                    trackingIsReliable: controller.isTrackingReliable
                )
                phaseCard
                statusBanner
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .padding([.horizontal, .top], 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            technicalDetails
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color.remoteBackground)
    }

    private var compactCoach: some View {
        VStack(spacing: 8) {
            Group {
                if isHoveringBubble {
                    HStack(spacing: 4) {
                        compactMenuButton("Agrandir", systemImage: "arrow.up.left.and.arrow.down.right") {
                            controller.showExpandedLiveTracking()
                        }
                        compactMenuButton("Réduire", systemImage: "eye.slash.fill") {
                            NotificationCenter.default.post(name: .postureCoachHidePreview, object: nil)
                        }
                        compactMenuButton("Quitter", systemImage: "xmark") {
                            NotificationCenter.default.post(name: .postureCoachClose, object: nil)
                        }
                    }
                    .padding(5)
                    .background(.ultraThickMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Color.clear
                }
            }
            .frame(width: 220, height: 38)

            ZStack {
                Circle().fill(Color.black)
                CameraPreviewView(session: controller.session)
                PostureOverlayView(
                    pose: controller.currentPose,
                    ghostPose: controller.ghostPose,
                    face: controller.facePose,
                    viewpoint: controller.viewpoint,
                    evaluation: controller.evaluation,
                    trackingIsReliable: controller.isTrackingReliable
                )
                Circle()
                    .fill(statusColor.opacity(controller.evaluation.severity >= .warning ? 0.18 : 0))

                if controller.evaluation.severity >= .warning {
                    VStack(spacing: 4) {
                        Spacer()
                        Image(systemName: statusIcon)
                            .font(.title2.bold())
                        Text(controller.evaluation.primaryIssue?.message ?? "Mauvaise posture")
                            .font(.caption.bold())
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 22)
                    .shadow(color: .black, radius: 5)
                } else {
                    Image(systemName: controller.isTrackingReliable
                        ? "checkmark.circle.fill"
                        : "viewfinder.circle")
                        .font(.title3.bold())
                        .foregroundStyle(statusColor)
                        .padding(13)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                Circle()
                    .stroke(statusColor, lineWidth: compactRingWidth)
                    .shadow(
                        color: statusColor.opacity(controller.evaluation.severity >= .warning ? 0.9 : 0.35),
                        radius: controller.evaluation.severity == .correction ? 16 : 6
                    )

                Button {
                    controller.showExpandedLiveTracking()
                } label: {
                    Circle().fill(Color.clear)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Agrandir le suivi de posture")
            }
            .clipShape(Circle())
            .contentShape(Circle())
            .frame(width: 220, height: 220)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHoveringBubble = hovering }
        }
        .frame(width: 220, height: 266, alignment: .bottom)
        .background(Color.clear)
        .ignoresSafeArea()
    }

    private func compactMenuButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.caption.bold())
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title == "Réduire" ? "Masquer entièrement l’image" : title)
    }

    private var compactRingWidth: CGFloat {
        switch controller.evaluation.severity {
        case .correction: 12
        case .warning: 8
        case .good, .unavailable: 4
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            backToCompanionButton
            Divider()
                .frame(height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Santé")
                        .font(.headline)
                    Text("BÊTA")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.remoteBlue.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.remoteBlue)
                }
                Text("Posture et marche · analyse locale par caméra")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if !controller.cameras.isEmpty {
                Picker("Caméra", selection: Binding(
                    get: { controller.selectedCameraID },
                    set: { if let value = $0 { controller.selectCamera(value) } }
                )) {
                    ForEach(controller.cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
            }

            Picker("Sensibilité", selection: Binding(
                get: { controller.sensitivity },
                set: { controller.setSensitivity($0) }
            )) {
                ForEach(PostureSensitivity.allCases) { sensitivity in
                    Text(sensitivity.title).tag(sensitivity)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            if isActive {
                Button("Dashboard", systemImage: "chart.bar.xaxis") {
                    controller.showHealthDashboard()
                }

                if controller.phase == .monitoring,
                   controller.keepsLiveTrackingExpanded {
                    Button("Bulle", systemImage: "circle.inset.filled") {
                        controller.showCompactCoach()
                    }
                }

                Menu {
                    Toggle(
                        "Signal sonore",
                        isOn: Binding(
                            get: { controller.soundEnabled },
                            set: { controller.setSoundEnabled($0) }
                        )
                    )
                    Button("Tester le signal") { controller.testAlertSound() }
                        .disabled(!controller.soundEnabled)
                } label: {
                    Label(
                        controller.soundEnabled ? "Son" : "Muet",
                        systemImage: controller.soundEnabled
                            ? "speaker.wave.2.fill"
                            : "speaker.slash.fill"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if controller.phase == .monitoring {
                    Button("Recalibrer ma posture", systemImage: "scope") {
                        controller.recalibrate()
                    }
                }
                Button("Arrêter", systemImage: "stop.fill", role: .destructive) { controller.stop() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.remoteCard)
    }

    private var healthDashboard: some View {
        VStack(spacing: 0) {
            dashboardToolbar

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dashboardHero
                    dashboardMetrics
                    dashboardWeekCard
                    dashboardSessionsCard
                    dashboardPhoneCard
                }
                .padding(18)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color.remoteBackground)
        .task(id: dashboardCelebrationTrigger) {
            await playDashboardCelebration()
        }
    }

    private var dashboardToolbar: some View {
        HStack(spacing: 12) {
            backToCompanionButton
            Divider()
                .frame(height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Dashboard santé")
                        .font(.headline)
                    Text("BÊTA")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.remoteBlue.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.remoteBlue)
                }
                Text("Votre activité de marche détectée par ce Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Suivi en direct", systemImage: "video.fill") {
                controller.showExpandedLiveTracking()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.remoteBlue)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.remoteCard)
    }

    private var backToCompanionButton: some View {
        Button {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "control-panel")
            dismissWindow(id: "posture-coach")
        } label: {
            Label("Retour", systemImage: "chevron.left")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .help("Fermer le module Santé et revenir au compagnon Vibe Walkie")
    }

    private var dashboardHero: some View {
        let snapshot = recentHealthActivitySnapshot
        let estimate = EvidenceBasedLongevityEstimate(
            weeklyBriskWalkingMinutes: snapshot?.briskWalkingMinutesLast7Days
        )
        let result = estimate.result

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(Color.healthCoral)
                        Text("LONGÉVITÉ · DONNÉES PUBLIÉES")
                            .font(.caption.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(Color.healthCoral)
                    }

                    if let result {
                        AnimatedLongevityValue(
                            years: result.associatedYears * dashboardRevealProgress
                        )
                    } else {
                        Text("—")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }

                    Text("Années de vie associées après 40 ans")
                        .font(.headline)

                    Text(healthMeasurementDescription(snapshot: snapshot))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if dashboardActiveDayCount > 1 {
                        Label(
                            "Série de \(dashboardActiveDayCount) jours actifs",
                            systemImage: "flame.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.11), in: Capsule())
                    }
                }

                Spacer(minLength: 18)

                VStack(alignment: .trailing, spacing: 10) {
                    Text("ÉTUDE · 654 827 ADULTES")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.07), in: Capsule())
                        .foregroundStyle(.secondary)

                    LongevityCelebrationEmblem(
                        progress: dashboardRevealProgress * Double(dashboardActiveDayCount) / 7,
                        activeDayCount: dashboardActiveDayCount,
                        haloPhase: dashboardHaloPhase
                    )
                }
            }

            Divider().overlay(.white.opacity(0.08))

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    if let result, let briskMinutes = snapshot?.briskWalkingMinutesLast7Days {
                        Label(
                            "Apple Santé : \(Int(briskMinutes.rounded())) min soutenues · \(publishedWalkingRangeLabel(for: result))",
                            systemImage: "heart.text.square.fill"
                        )
                        .font(.caption.weight(.semibold))

                        if let interval = result.confidenceInterval {
                            Text("Association publiée : \(formattedLongevityYears(result.associatedYears)) ans · IC 95 % : \(formattedLongevityYears(interval.lowerBound))–\(formattedLongevityYears(interval.upperBound)) ans")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Aucune année supplémentaire associée à ce palier par rapport au groupe de référence.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label(
                            "Intensité Santé indisponible · aucune estimation affichée",
                            systemImage: "iphone.and.arrow.forward"
                        )
                        .font(.caption.weight(.semibold))
                    }
                }

                Spacer()

                if walkingSessions.isWalking {
                    Label("Marche en cours", systemImage: "figure.walk.motion")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 10) {
                Label("Association statistique · non individuelle", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Source", systemImage: "book.closed.fill") {
                    showsLongevityEvidence = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(22)
        .background {
            ZStack {
                Color.remoteCard
                RadialGradient(
                    colors: [Color.healthCoral.opacity(0.12), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 320
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        .sheet(isPresented: $showsLongevityEvidence) {
            LongevityEvidenceSheet(
                snapshot: snapshot,
                result: result
            )
        }
    }

    private var recentHealthActivitySnapshot: HealthActivitySnapshotPayload? {
        guard let snapshot = server.healthActivitySnapshot,
              Date().timeIntervalSince(snapshot.capturedAt) < 36 * 3_600 else {
            return nil
        }
        return snapshot
    }

    private func healthMeasurementDescription(
        snapshot: HealthActivitySnapshotPayload?
    ) -> String {
        guard let snapshot else {
            return "Ouvrez Vibe Walkie sur l’iPhone pour synchroniser les minutes d’exercice Apple Santé."
        }
        guard let briskMinutes = snapshot.briskWalkingMinutesLast7Days else {
            return "Apple Santé ne fournit pas encore de mesure d’intensité exploitable pour ces créneaux."
        }
        return "Apple Santé a qualifié \(Int(briskMinutes.rounded())) min au niveau d’une marche soutenue sur les 7 derniers jours."
    }

    private func formattedLongevityYears(_ years: Double) -> String {
        years.formatted(
            .number.locale(Locale(identifier: "fr_FR")).precision(.fractionLength(1))
        )
    }

    private func publishedWalkingRangeLabel(
        for result: EvidenceBasedLongevityEstimate.Result
    ) -> String {
        guard let range = result.briskWalkingMinutesRange else {
            return "palier de référence"
        }
        if range.upperBound == Double.greatestFiniteMagnitude {
            return "\(Int(range.lowerBound)) min ou plus"
        }
        if range.lowerBound == 0 {
            return "moins de \(Int(range.upperBound)) min"
        }
        return "\(Int(range.lowerBound))–\(Int(range.upperBound - 1)) min"
    }

    private var dashboardMetrics: some View {
        HStack(spacing: 12) {
            dashboardMetric(
                icon: "calendar",
                value: formattedDashboardDuration(weekDashboardDuration),
                label: "de marche observée · 7 jours",
                tint: .green
            )
            dashboardMetric(
                icon: "clock.fill",
                value: formattedDashboardDuration(todayDashboardDuration),
                label: "de marche aujourd’hui",
                tint: Color.remoteBlue
            )
            dashboardMetric(
                icon: "rectangle.stack.fill",
                value: "\(todayDashboardSessions.count)",
                label: todayDashboardSessions.count == 1 ? "créneau aujourd’hui" : "créneaux aujourd’hui",
                tint: .purple
            )
        }
    }

    private func dashboardMetric(
        icon: String,
        value: String,
        label: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .dashboardCard()
    }

    private var dashboardWeekCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Marche détectée · 7 jours")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 12) {
                ForEach(dashboardDays) { day in
                    VStack(spacing: 7) {
                        Text(day.duration > 0 ? formattedDashboardDuration(day.duration) : "—")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(day.duration > 0 ? Color.remoteBlue : Color.white.opacity(0.06))
                            .frame(height: dashboardBarHeight(for: day.duration))
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Color.remoteBlue : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 154, alignment: .bottom)
        }
        .padding(18)
        .dashboardCard()
    }

    @ViewBuilder
    private var dashboardSessionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Créneaux d’aujourd’hui")
                .font(.headline)

            if todayDashboardSessions.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "figure.walk")
                        .foregroundStyle(.secondary)
                    Text("Aucune marche détectée aujourd’hui.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(Array(todayDashboardSessions.prefix(5).enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider().overlay(.white.opacity(0.08)) }
                    HStack {
                        Label(
                            session.isOngoing ? "En cours" : session.startedAt.formatted(date: .omitted, time: .shortened),
                            systemImage: session.isOngoing ? "waveform.path.ecg" : "clock"
                        )
                        .foregroundStyle(session.isOngoing ? .green : .primary)
                        Spacer()
                        Text(formattedDashboardDuration(session.duration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .dashboardCard()
    }

    private var dashboardPhoneCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(Color.remoteBlue)
            VStack(alignment: .leading, spacing: 3) {
                Text("Pas et points de vie sur l’iPhone")
                    .font(.headline)
                Text("L’iPhone rapproche ces créneaux des pas Apple Santé. Le Mac ne conserve ni image ni mesure corporelle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .dashboardCard()
    }

    private var dashboardDays: [PostureDashboardDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
            let duration = dashboardSessions.reduce(0) { total, session in
                total + max(0, min(end, session.endedAt).timeIntervalSince(max(date, session.startedAt)))
            }
            return PostureDashboardDay(date: date, duration: duration)
        }
    }

    private var dashboardSessions: [WorkWalkingSession] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        return walkingSessions.snapshot(since: start).sessions
    }

    private var todayDashboardSessions: [WorkWalkingSession] {
        let start = Calendar.current.startOfDay(for: Date())
        return dashboardSessions
            .filter { $0.endedAt >= start }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var todayDashboardDuration: TimeInterval {
        walkingSessions.walkingDuration()
    }

    private var weekDashboardDuration: TimeInterval {
        dashboardDays.reduce(0) { $0 + $1.duration }
    }

    private var dashboardActiveDayCount: Int {
        dashboardDays.count { $0.duration > 0 }
    }

    @MainActor
    private func playDashboardCelebration() async {
        withAnimation(.none) {
            dashboardRevealProgress = reducesMotion ? 1 : 0
            dashboardHaloPhase = false
        }

        guard !reducesMotion else { return }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }

        withAnimation(.spring(duration: 1.15, bounce: 0.24)) {
            dashboardRevealProgress = 1
        }
        withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
            dashboardHaloPhase = true
        }
    }

    private func dashboardBarHeight(for duration: TimeInterval) -> CGFloat {
        let maximum = max(dashboardDays.map(\.duration).max() ?? 0, 60)
        guard duration > 0 else { return 4 }
        return max(8, CGFloat(duration / maximum) * 102)
    }

    private func formattedDashboardDuration(_ duration: TimeInterval) -> String {
        let minutes = Int((duration / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60)"
    }

    private var healthSummary: some View {
        HStack(spacing: 12) {
            summaryMetric(
                icon: healthStatus.icon,
                value: healthStatus.value,
                label: healthStatus.label,
                tint: healthStatus.tint
            )

            Divider().frame(height: 38)

            summaryMetric(
                icon: "clock.fill",
                value: todayWalkingTime,
                label: "de marche au travail aujourd’hui",
                tint: Color.remoteBlue
            )

            Spacer()

            Label("Pas et points de vie sur l’iPhone", systemImage: "iphone")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.remoteBackground)
    }

    private func summaryMetric(
        icon: String,
        value: String,
        label: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.bold())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var todayWalkingTime: String {
        let minutes = Int((walkingSessions.walkingDuration() / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60)"
    }

    private var healthStatus: (icon: String, value: String, label: String, tint: Color) {
        if walkingSessions.isWalking {
            return ("figure.walk.motion", "Marche détectée", "créneau en cours", .green)
        }
        if controller.phase == .idle {
            return ("figure.stand", "Prêt", "démarrez le suivi caméra", .secondary)
        }
        return ("figure.stand", "Suivi actif", "posture et cadence", Color.remoteBlue)
    }

    @ViewBuilder
    private var phaseCard: some View {
        switch controller.phase {
        case .idle:
            centeredCard(
                icon: "figure.stand",
                title: "Préparez votre posture de référence",
                message: "La caméra va d’abord vous aider à vous cadrer. Elle n’enregistrera votre référence qu’après que vous vous serez volontairement redressé et aurez confirmé cette posture."
            ) {
                Button("Ouvrir la caméra et me positionner") { controller.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.remoteBlue)
                    .controlSize(.large)
            }
        case .requestingPermission:
            centeredCard(
                icon: "camera.fill",
                title: "Autorisation de la caméra",
                message: "Validez la demande de macOS pour lancer l’analyse locale."
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        case .positioning:
            centeredCard(
                icon: controller.viewpoint == .threeQuarter
                    ? "arrow.triangle.2.circlepath.camera"
                    : "viewfinder",
                title: "Préparation du cadrage",
                message: controller.guidance
            ) {
                VStack(spacing: 14) {
                    qualityIndicators
                    if controller.isReadyToFreezePosture {
                        VStack(spacing: 8) {
                            Label(
                                "Tête droite · buste redressé · épaules relâchées",
                                systemImage: "figure.mind.and.body"
                            )
                            .font(.callout.weight(.semibold))
                            Button("Je suis bien droit · enregistrer cette posture") {
                                controller.confirmCalibrationPosture()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .controlSize(.large)
                        }
                    }
                }
            }
        case .calibratingStatic(let progress):
            calibrationCard(
                title: "Nous calibrons votre posture avec cet emplacement de caméra",
                message: "Maintenez votre meilleure posture jusqu’à la fin : tête droite, buste redressé et épaules relâchées. Cette position deviendra la référence du coach.",
                progress: progress
            )
        case .awaitingLeanSample:
            centeredCard(
                icon: "figure.stand.line.dotted.figure.stand",
                title: "Montrez la posture à corriger",
                message: "Prenez votre posture habituelle quand vous vous rapprochez un peu trop de l’écran. Une légère inclinaison naturelle suffit : inutile de vous baisser fortement."
            ) {
                Button("Je suis légèrement penché · enregistrer cet exemple") {
                    controller.confirmLeanPosture()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
            }
        case .calibratingLean(let progress):
            calibrationCard(
                title: "Nous apprenons la posture à corriger",
                message: "Gardez simplement votre légère inclinaison habituelle. Elle sera comparée à votre posture droite pour cette caméra précise.",
                progress: progress
            )
        case .calibratingWalking(let progress):
            calibrationCard(
                title: "Nous calibrons votre posture de marche",
                message: "Marchez avec la posture que vous souhaitez conserver. Cet emplacement et cet angle de caméra deviennent votre référence.",
                progress: progress
            )
        case .permissionDenied:
            centeredCard(
                icon: "camera.fill",
                title: "Accès caméra désactivé",
                message: "Autorisez Vibe Walkie dans Réglages Système › Confidentialité et sécurité › Caméra."
            ) {
                Button("Ouvrir les réglages") { controller.openCameraPrivacySettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.remoteBlue)
            }
        case .unavailable(let message):
            centeredCard(
                icon: "exclamationmark.triangle.fill",
                title: "Caméra indisponible",
                message: message
            ) {
                Button("Réessayer") { controller.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.remoteBlue)
            }
        case .monitoring:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if controller.phase == .monitoring {
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: statusIcon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.guidance)
                            .font(.headline)
                        Text(statusSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(
                        controller.activity == .walking ? "Marche" : "Statique",
                        systemImage: controller.activity == .walking ? "figure.walk" : "figure.stand"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .padding(13)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(16)
            }
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: $showsTechnicalDetails) {
            HStack(spacing: 18) {
                detail("Vue", viewpointTitle)
                detail("Analyse", controller.metrics?.uses3D == true ? "Vision 3D" : "Vision 2D")
                detail("Cou–thorax", formatted(controller.metrics?.headThoraxAngle))
                detail("CVA estimé", formatted(controller.metrics?.profileCVA))
                detail("Inclinaison tête", formatted(controller.metrics?.headPitch))
                detail("Inclinaison buste", formatted(controller.metrics?.trunkInclination))
                Spacer()
                Label("Traitement local · rien n’est conservé", systemImage: "lock.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } label: {
            Text("Détails techniques")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var qualityIndicators: some View {
        HStack(spacing: 12) {
            qualityIndicator("Cou", ready: controller.trackingQuality.hasNeck)
            qualityIndicator("Buste", ready: controller.trackingQuality.hasUpperBody)
            qualityIndicator("Lumière", ready: controller.trackingQuality.enoughLight)
            qualityIndicator("Marche", ready: controller.trackingQuality.hasFullBody)
        }
    }

    private func qualityIndicator(_ title: String, ready: Bool) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption)
            .foregroundStyle(ready ? .green : .secondary)
    }

    private func calibrationCard(title: String, message: String, progress: Double) -> some View {
        centeredCard(icon: "scope", title: title, message: message) {
            VStack(spacing: 7) {
                ProgressView(value: progress)
                    .frame(width: 220)
                    .tint(Color.remoteBlue)
                Text("\(Int(progress * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func centeredCard<Actions: View>(
        icon: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.remoteBlue)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text(message)
                .font(.callout)
                .foregroundStyle(Color.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 410)
            actions()
        }
        .padding(26)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.remoteCard.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
        .padding(24)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    private var isActive: Bool {
        switch controller.phase {
        case .idle, .permissionDenied, .unavailable: false
        default: true
        }
    }

    private var statusColor: Color {
        guard controller.isTrackingReliable else { return .gray }
        switch controller.evaluation.severity {
        case .unavailable: return .gray
        case .good: return .green
        case .warning: return .orange
        case .correction: return .red
        }
    }

    private var statusIcon: String {
        switch controller.evaluation.severity {
        case .unavailable: "viewfinder.circle"
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .correction: "exclamationmark.triangle.fill"
        }
    }

    private var statusSubtitle: String {
        guard controller.isTrackingReliable else { return "Mesure momentanément indisponible" }
        return controller.evaluation.primaryIssue == nil
            ? "Cou, regard et buste proches de votre référence calibrée"
            : "Écart postural prolongé détecté"
    }

    private var viewpointTitle: String {
        switch controller.viewpoint {
        case .front: "Face"
        case .profile: "Profil"
        case .threeQuarter: "Trois-quarts"
        case .back: "Dos"
        case .unknown: "Indéterminée"
        }
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f°", value)
    }
}

private struct PostureDashboardDay: Identifiable {
    let date: Date
    let duration: TimeInterval

    var id: Date { date }
}

private extension View {
    func dashboardCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.remoteCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.setSession(session)
    }
}

private final class CameraPreviewNSView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    func setSession(_ session: AVCaptureSession) {
        if previewLayer.session !== session { previewLayer.session = session }
    }
}

private struct PostureOverlayView: View {
    let pose: TrackedPose2D?
    let ghostPose: TrackedPose2D?
    let face: FacePose?
    let viewpoint: CameraViewpoint
    let evaluation: PostureEvaluation
    let trackingIsReliable: Bool

    var body: some View {
        Canvas { context, size in
            if let ghostPose {
                drawSkeleton(
                    ghostPose,
                    in: &context,
                    size: size,
                    ghost: true
                )
            }
            if let pose {
                drawSkeleton(
                    pose,
                    in: &context,
                    size: size,
                    ghost: false
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func drawSkeleton(
        _ pose: TrackedPose2D,
        in context: inout GraphicsContext,
        size: CGSize,
        ghost: Bool
    ) {
        let neutral = ghost ? Color.white.opacity(0.24) : Color.white.opacity(0.78)
        let style = StrokeStyle(
            lineWidth: ghost ? 3 : 5,
            lineCap: .round,
            lineJoin: .round,
            dash: ghost ? [7, 6] : []
        )

        let neutralSegments: [(PoseJoint, PoseJoint)] = [
            (.leftShoulder, .rightShoulder),
            (.leftShoulder, .leftElbow),
            (.leftElbow, .leftWrist),
            (.rightShoulder, .rightElbow),
            (.rightElbow, .rightWrist),
            (.leftHip, .rightHip),
            (.leftHip, .leftKnee),
            (.leftKnee, .leftAnkle),
            (.rightHip, .rightKnee),
            (.rightKnee, .rightAnkle)
        ]
        for segment in neutralSegments {
            drawLine(segment.0, segment.1, pose: pose, color: neutral, style: style, in: &context, size: size)
        }

        if let segment = PostureMetricCalculator.trunkSegment(in: pose) {
            drawLine(
                from: segment.lower,
                to: segment.shoulder,
                pose: pose,
                color: ghost ? neutral : color(for: evaluation.severity(for: .trunkInclined)),
                style: style,
                in: &context,
                size: size
            )
        }

        if viewpoint == .profile,
           let neck = pose.shoulderCenter,
           let ear = bestEar(in: pose) {
            let neckColor = ghost ? neutral : color(for: evaluation.severity(for: .neckForward))
            drawLine(from: neck, to: ear, pose: pose, color: neckColor, style: style, in: &context, size: size)
            if !ghost {
                let direction: CGFloat = ear.x >= neck.x ? 1 : -1
                drawLine(
                    from: neck,
                    to: CGPoint(x: neck.x + 0.13 * direction, y: neck.y),
                    pose: pose,
                    color: .white.opacity(0.32),
                    style: StrokeStyle(lineWidth: 2, dash: [5, 5]),
                    in: &context,
                    size: size
                )
            }
        } else if let shoulder = pose.shoulderCenter, let head = pose.headCenter {
            drawLine(
                from: shoulder,
                to: head,
                pose: pose,
                color: ghost ? neutral : color(for: evaluation.severity(for: .neckForward)),
                style: style,
                in: &context,
                size: size
            )
        }

        guard !ghost else { return }
        drawHeadDirection(pose: pose, in: &context, size: size)
        for point in pose.points.values where point.confidence >= 0.4 {
            let location = displayPoint(point.location, pose: pose, size: size)
            let rect = CGRect(x: location.x - 3, y: location.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.82)))
        }
    }

    private func drawHeadDirection(
        pose: TrackedPose2D,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let nose = pose.reliablePoint(.nose) ?? pose.headCenter else { return }
        let pitch = (face?.pitchDegrees ?? 0) * .pi / 180
        let yaw = (face?.yawDegrees ?? 0) * .pi / 180
        let end: CGPoint
        if viewpoint == .profile, let ear = bestEar(in: pose) {
            let horizontalDirection: CGFloat = nose.x >= ear.x ? 1 : -1
            end = CGPoint(
                x: nose.x + horizontalDirection * 0.11 * cos(pitch),
                y: nose.y + 0.11 * sin(pitch)
            )
        } else {
            end = CGPoint(
                x: nose.x + 0.12 * sin(yaw),
                y: nose.y + 0.12 * sin(pitch)
            )
        }
        let headSeverity = max(
            evaluation.severity(for: .headDown),
            evaluation.severity(for: .headTurned)
        )
        // White is neutral here: green made this direction vector look like a
        // validation of the whole posture even when it was merely available.
        let lineColor = headSeverity == .good
            ? Color.white.opacity(0.72)
            : color(for: headSeverity)
        if hypot(end.x - nose.x, end.y - nose.y) < 0.008 {
            let location = displayPoint(nose, pose: pose, size: size)
            context.stroke(
                Path(ellipseIn: CGRect(x: location.x - 7, y: location.y - 7, width: 14, height: 14)),
                with: .color(lineColor),
                lineWidth: 3
            )
        } else {
            drawLine(
                from: nose,
                to: end,
                pose: pose,
                color: lineColor,
                style: StrokeStyle(lineWidth: 4, lineCap: .round),
                in: &context,
                size: size
            )
        }
    }

    private func drawLine(
        _ first: PoseJoint,
        _ second: PoseJoint,
        pose: TrackedPose2D,
        color: Color,
        style: StrokeStyle,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let start = pose.reliablePoint(first), let end = pose.reliablePoint(second) else { return }
        drawLine(from: start, to: end, pose: pose, color: color, style: style, in: &context, size: size)
    }

    private func drawLine(
        from start: CGPoint,
        to end: CGPoint,
        pose: TrackedPose2D,
        color: Color,
        style: StrokeStyle,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        var path = Path()
        path.move(to: displayPoint(start, pose: pose, size: size))
        path.addLine(to: displayPoint(end, pose: pose, size: size))
        context.stroke(path, with: .color(color), style: style)
    }

    /// Applies the same aspect-fill crop as AVCaptureVideoPreviewLayer, keeping
    /// Vision's macOS capture coordinates in the preview's horizontal direction.
    private func displayPoint(_ point: CGPoint, pose: TrackedPose2D, size: CGSize) -> CGPoint {
        PostureOverlayGeometry.displayPoint(
            point,
            frameSize: pose.frameSize,
            viewSize: size
        )
    }

    private func bestEar(in pose: TrackedPose2D) -> CGPoint? {
        [PoseJoint.leftEar, .rightEar]
            .compactMap { pose[$0] }
            .filter { $0.confidence >= 0.4 }
            .max { $0.confidence < $1.confidence }?
            .location
    }

    private func color(for severity: PostureSeverity) -> Color {
        guard trackingIsReliable else { return .gray.opacity(0.75) }
        switch severity {
        case .unavailable: return .gray.opacity(0.75)
        case .good: return .green.opacity(0.9)
        case .warning: return .orange
        case .correction: return .red
        }
    }
}

extension Notification.Name {
    static let postureCoachHidePreview = Notification.Name("vibe.walkie.posture.hide-preview")
    static let postureCoachShowPreview = Notification.Name("vibe.walkie.posture.show-preview")
    static let postureCoachClose = Notification.Name("vibe.walkie.posture.close")
}

private struct PostureWindowLifecycleObserver: NSViewRepresentable {
    let controller: PostureCoachController
    let isCompact: Bool

    func makeNSView(context: Context) -> PostureWindowObserverNSView {
        PostureWindowObserverNSView(controller: controller, isCompact: isCompact)
    }

    func updateNSView(_ nsView: PostureWindowObserverNSView, context: Context) {
        nsView.setCompact(isCompact)
    }
}

enum PostureWindowPlacement {
    static let defaultFullSize = NSSize(width: 960, height: 720)
    static let minimumFullSize = NSSize(width: 720, height: 560)

    static func centeredFullFrame(
        preferredSize: NSSize = defaultFullSize,
        visibleFrame: NSRect
    ) -> NSRect {
        let horizontalMargin: CGFloat = 24
        let verticalMargin: CGFloat = 24
        let availableWidth = max(minimumFullSize.width, visibleFrame.width - horizontalMargin * 2)
        let availableHeight = max(minimumFullSize.height, visibleFrame.height - verticalMargin * 2)
        let size = NSSize(
            width: min(max(preferredSize.width, minimumFullSize.width), availableWidth),
            height: min(max(preferredSize.height, minimumFullSize.height), availableHeight)
        )
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
private final class PostureWindowObserverNSView: NSView {
    private static let bubbleOriginKey = "vibe.walkie.mac.posture.bubble.origin.v1"
    private static let bubbleWindowSize = NSSize(width: 220, height: 266)
    private let controller: PostureCoachController
    private weak var observedWindow: NSWindow?
    private var wantsCompact: Bool
    private var isCompact = false
    private var fullFrame: NSRect?
    private var fullStyleMask: NSWindow.StyleMask?
    private var fullHasShadow = true

    init(controller: PostureCoachController, isCompact: Bool) {
        self.controller = controller
        self.wantsCompact = isCompact
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        observedWindow = window
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didMiniaturize),
            name: NSWindow.didMiniaturizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didMove),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hidePreview),
            name: .postureCoachHidePreview,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showPreview),
            name: .postureCoachShowPreview,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closeCoach),
            name: .postureCoachClose,
            object: nil
        )
        updatePresentation()
        if !wantsCompact {
            // SwiftUI restaure parfois le dernier cadre de la bulle flottante
            // pour cette même scène. Recentrer après le premier cycle laisse
            // les contraintes de contenu fixer la taille avant de la placer.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.observedWindow === window,
                      !self.wantsCompact else { return }
                self.placeFullWindow(window, preferredSize: Self.fullSize(from: window.frame))
            }
        }
    }

    func setCompact(_ compact: Bool) {
        guard wantsCompact != compact || isCompact != compact else { return }
        wantsCompact = compact
        updatePresentation()
    }

    private func updatePresentation() {
        guard let window = observedWindow else { return }
        if wantsCompact, !isCompact {
            fullFrame = window.frame
            fullStyleMask = window.styleMask
            fullHasShadow = window.hasShadow
            isCompact = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // A titled SwiftUI window leaves its rectangular title bar and
            // shadow visible above a circular view. The compact coach is a
            // genuinely borderless transparent window; SwiftUI draws the
            // circle and its colored ring itself.
            window.styleMask = [.borderless]
            window.hasShadow = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isMovableByWindowBackground = true
            window.minSize = Self.bubbleWindowSize
            window.maxSize = Self.bubbleWindowSize
            window.contentAspectRatio = .zero
            setTrafficLights(hidden: true, in: window)
            placeBubble(window)
            controller.setPreviewHidden(false)
        } else if !wantsCompact, isCompact {
            isCompact = false
            if let fullStyleMask { window.styleMask = fullStyleMask }
            window.hasShadow = fullHasShadow
            window.level = .normal
            window.collectionBehavior = [.managed]
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
            window.isMovableByWindowBackground = false
            window.minSize = PostureWindowPlacement.minimumFullSize
            window.maxSize = NSSize(width: 4_000, height: 4_000)
            window.contentAspectRatio = .zero
            setTrafficLights(hidden: false, in: window)
            placeFullWindow(
                window,
                preferredSize: fullFrame?.size ?? PostureWindowPlacement.defaultFullSize,
                animate: true
            )
            controller.setPreviewHidden(false)
        }
    }

    private static func fullSize(from currentFrame: NSRect) -> NSSize {
        guard currentFrame.width >= PostureWindowPlacement.minimumFullSize.width,
              currentFrame.height >= PostureWindowPlacement.minimumFullSize.height else {
            return PostureWindowPlacement.defaultFullSize
        }
        return currentFrame.size
    }

    private func placeFullWindow(
        _ window: NSWindow,
        preferredSize: NSSize,
        animate: Bool = false
    ) {
        let screen = NSScreen.main ?? window.screen ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            window.setContentSize(preferredSize)
            window.center()
            return
        }
        window.setFrame(
            PostureWindowPlacement.centeredFullFrame(
                preferredSize: preferredSize,
                visibleFrame: visibleFrame
            ),
            display: true,
            animate: animate
        )
        fullFrame = window.frame
    }

    private func placeBubble(_ window: NSWindow) {
        let size = Self.bubbleWindowSize
        let visibleFrame = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        var origin = NSPoint(x: visibleFrame.maxX - size.width - 24, y: visibleFrame.minY + 24)
        if let stored = UserDefaults.standard.string(forKey: Self.bubbleOriginKey) {
            let candidate = NSPointFromString(stored)
            if visibleFrame.insetBy(dx: -60, dy: -60).contains(candidate) {
                origin = candidate
            }
        }
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }

    private func setTrafficLights(hidden: Bool, in window: NSWindow) {
        [.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = hidden
        }
    }

    @objc private func didMiniaturize() {
        controller.setPreviewHidden(true)
    }

    @objc private func didMove() {
        guard isCompact, let window = observedWindow else { return }
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: Self.bubbleOriginKey)
    }

    @objc private func hidePreview() {
        guard isCompact, let window = observedWindow else { return }
        window.orderOut(nil)
        controller.setPreviewHidden(true)
    }

    @objc private func showPreview() {
        guard let window = observedWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        controller.setPreviewHidden(false)
    }

    @objc private func closeCoach() {
        observedWindow?.close()
    }

    @objc private func willClose() {
        controller.stop()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
