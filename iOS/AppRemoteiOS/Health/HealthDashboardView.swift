import Charts
import RemoteCore
import SwiftUI

struct HealthDashboardView: View {
    @EnvironmentObject private var client: HostConnectionClient
    @EnvironmentObject private var health: HealthActivityStore
    @State private var historyPeriod: HealthHistoryPeriod = .week

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                appleHealthCard
                todayCard
                longevityProjectionCard
                historyCard
                methodCard
            }
            .padding(16)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(AppL10n.text("ios.health.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if health.hasRequestedAuthorization {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await health.refresh(using: client) }
                    } label: {
                        if health.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(health.isRefreshing)
                    .accessibilityLabel(AppL10n.text("ios.health.refresh"))
                }
            }
        }
        .task {
            if health.hasRequestedAuthorization {
                await health.refresh(using: client)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppL10n.text("ios.health.hero.eyebrow"), systemImage: "figure.walk.motion")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.remoteBlue)
            Text(AppL10n.text("ios.health.hero.title"))
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text(AppL10n.text("ios.health.hero.description"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .healthCard()
    }

    @ViewBuilder
    private var appleHealthCard: some View {
        switch health.connectionState {
        case .notRequested:
            VStack(alignment: .leading, spacing: 12) {
                Label("Connecter Apple Santé", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(.pink)
                Text("Lecture seule des pas, de la distance et des minutes d’exercice. Vibe Walkie n’écrit aucune donnée dans Santé.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await health.requestAuthorizationAndRefresh(using: client) }
                } label: {
                    HStack {
                        Spacer()
                        if health.isRefreshing { ProgressView().tint(.white) }
                        Text("Autoriser Santé")
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.remoteBlue)
                .disabled(health.isRefreshing)
            }
            .healthCard()

        case .unavailable:
            Label("Apple Santé n’est pas disponible sur cet appareil.", systemImage: "heart.slash")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .healthCard()

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Réessayer") {
                    Task { await health.requestAuthorizationAndRefresh(using: client) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .healthCard()

        case .accessRequested:
            HStack(spacing: 12) {
                Image(systemName: "heart.fill")
                    .font(.title2)
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppL10n.text("ios.health.connected.title"))
                        .font(.headline)
                    Text(AppL10n.text("ios.health.connected.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .healthCard()
        }
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppL10n.text("ios.health.today"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("\(health.today.workSteps.formatted())")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(AppL10n.text("ios.health.steps.working"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(health.today.lifePoints.formatted(.number.precision(.fractionLength(2))))
                        .font(.title.bold())
                        .monospacedDigit()
                        .foregroundStyle(Color.remoteBlue)
                    Text(AppL10n.text("ios.health.life.points"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider().overlay(.white.opacity(0.08))

            HStack {
                metric("iphone.and.arrow.forward", workSessionTimeText)
                Spacer()
                metric("shoeprints.fill", AppL10n.format("ios.health.total.steps", health.today.totalSteps.formatted()))
            }

            HStack {
                metric("heart.text.square.fill", briskWalkingText)
                Spacer()
                metric("location.fill", walkingDistanceText)
            }

            ShareLink(item: shareText) {
                Label(AppL10n.text("ios.health.share"), systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Color.remoteBlue)

            if let message = health.syncMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let lastUpdatedAt = health.lastUpdatedAt {
                Text(AppL10n.format("ios.health.synced.at", lastUpdatedAt.formatted(date: .omitted, time: .shortened)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .healthCard()
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppL10n.text("ios.health.history.title"))
                    .font(.headline)
                Spacer()
                Text(historyPeriod.rangeTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Picker("Période", selection: $historyPeriod) {
                ForEach(HealthHistoryPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 18) {
                historyMetric(
                    value: historyTotal.formatted(),
                    label: AppL10n.text("ios.health.history.period.total")
                )
                historyMetric(
                    value: historyDailyAverage.formatted(),
                    label: AppL10n.text("ios.health.history.daily.average")
                )
            }

            Chart(historyPoints) { point in
                if historyPeriod == .year {
                    AreaMark(
                        x: .value("Mois", point.date, unit: .month),
                        y: .value("Moyenne de pas", point.workSteps)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [Color.remoteBlue.opacity(0.35), Color.remoteBlue.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Mois", point.date, unit: .month),
                        y: .value("Moyenne de pas", point.workSteps)
                    )
                    .foregroundStyle(Color.remoteBlue)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                    PointMark(
                        x: .value("Mois", point.date, unit: .month),
                        y: .value("Moyenne de pas", point.workSteps)
                    )
                    .foregroundStyle(Color.remoteBlue)
                } else {
                    BarMark(
                        x: .value("Jour", point.date, unit: .day),
                        y: .value("Pas", point.workSteps)
                    )
                    .foregroundStyle(Color.remoteBlue.gradient)
                    .cornerRadius(4)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartXAxis {
                if historyPeriod == .week {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                } else if historyPeriod == .month {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.day())
                    }
                } else {
                    AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
            }
            .chartYScale(domain: 0...historyChartUpperBound)
            .frame(height: 170)

            if historyPeriod == .year {
                Text("La courbe affiche la moyenne quotidienne de chaque mois pour comparer les périodes équitablement.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .healthCard()
    }

    private var longevityProjectionCard: some View {
        let dailyMinutes = health.today.briskWalkingMinutes
        let weeklyMinutes = dailyMinutes.map { max(0, $0) * 5 }
        let estimate = EvidenceBasedLongevityEstimate(
            weeklyBriskWalkingMinutes: weeklyMinutes
        )

        return VStack(alignment: .leading, spacing: 12) {
            Label(
                AppL10n.text("ios.health.longevity.projection.eyebrow"),
                systemImage: "heart.fill"
            )
            .font(.caption.weight(.bold))
            .foregroundStyle(.pink)

            if let result = estimate.result, let dailyMinutes, let weeklyMinutes {
                Text(
                    AppL10n.format(
                        "ios.health.longevity.projection.value",
                        formattedLongevityYears(result.associatedYears)
                    )
                )
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

                Text(AppL10n.text("ios.health.longevity.projection.after40"))
                    .font(.headline)

                Text(
                    AppL10n.format(
                        "ios.health.longevity.projection.summary",
                        Int(dailyMinutes.rounded()),
                        Int(weeklyMinutes.rounded())
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(AppL10n.text("ios.health.longevity.projection.unavailable"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider().overlay(.white.opacity(0.08))

            Text(AppL10n.text("ios.health.longevity.projection.disclaimer"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(destination: EvidenceBasedLongevityEstimate.sourceURL) {
                Label(
                    AppL10n.text("ios.health.longevity.projection.source"),
                    systemImage: "arrow.up.right.square"
                )
                .font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .healthCard()
    }

    private var historyPoints: [WorkWalkingChartPoint] {
        HealthHistoryAggregator.points(from: health.days, period: historyPeriod)
    }

    private var historyTotal: Int {
        selectedHistoryDays.reduce(0) { $0 + $1.workSteps }
    }

    private var selectedHistoryDays: [WorkWalkingDaySummary] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start: Date?
        switch historyPeriod {
        case .week:
            start = calendar.date(byAdding: .day, value: -6, to: today)
        case .month:
            start = calendar.date(byAdding: .day, value: -29, to: today)
        case .year:
            let currentMonth = calendar.date(
                from: calendar.dateComponents([.year, .month], from: today)
            )
            start = currentMonth.flatMap { calendar.date(byAdding: .month, value: -11, to: $0) }
        }
        guard let start else { return [] }
        return health.days.filter {
            let date = calendar.startOfDay(for: $0.day)
            return date >= start && date <= today
        }
    }

    private var historyDailyAverage: Int {
        let representedDays = historyPoints.reduce(0) { $0 + $1.representedDayCount }
        guard representedDays > 0 else { return 0 }
        return Int((Double(historyTotal) / Double(representedDays)).rounded())
    }

    private var historyChartUpperBound: Int {
        max(100, Int(Double(historyPoints.map(\.workSteps).max() ?? 0) * 1.12))
    }

    private func historyMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var methodCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Comment le score est calculé", systemImage: "checkmark.shield")
                .font(.headline)
            Text("1 point de vie = 100 pas Apple Santé effectués pendant que Vibe Walkie est active et connectée à votre Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("L’estimation de longévité utilise uniquement les minutes d’exercice Apple Santé, c’est-à-dire les minutes atteignant au moins l’intensité d’une marche soutenue. Elle est plafonnée au palier maximal publié.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .healthCard()
    }

    private func metric(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var workSessionTimeText: String {
        let minutes = max(0, Int((health.today.workSessionDuration / 60).rounded()))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes < 60 ? [.minute] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }

    private var briskWalkingText: String {
        guard let minutes = health.today.briskWalkingMinutes else {
            return AppL10n.text("ios.health.intensity.unavailable")
        }
        return AppL10n.format("ios.health.active.minutes", Int(minutes.rounded()))
    }

    private var walkingDistanceText: String {
        let kilometers = health.today.walkingDistanceMeters / 1_000
        return "\(kilometers.formatted(.number.precision(.fractionLength(2)))) km"
    }

    private func formattedLongevityYears(_ years: Double) -> String {
        let identifier = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
            ?? AppLanguage.systemIdentifier
        return max(0, years).formatted(
            .number
                .locale(AppLanguage.locale(for: identifier))
                .precision(.fractionLength(1))
        )
    }

    private var shareText: String {
        "Aujourd’hui, j’ai gagné \(health.today.lifePoints.formatted(.number.precision(.fractionLength(2)))) points de vie et fait \(health.today.workSteps.formatted()) pas en travaillant debout avec Vibe Walkie."
    }
}

private extension View {
    func healthCard() -> some View {
        padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.controlSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}
