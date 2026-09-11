@preconcurrency import HealthKit
import Foundation
import RemoteCore

struct WorkWalkingDaySummary: Identifiable, Equatable {
    let day: Date
    let workSteps: Int
    let totalSteps: Int
    let workSessionDuration: TimeInterval
    let briskWalkingMinutes: Double?
    let walkingDistanceMeters: Double

    var id: Date { day }
    var lifePoints: Double { Double(workSteps) / 100 }
}

enum HealthHistoryPeriod: String, CaseIterable, Identifiable {
    case week
    case month
    case year

    var id: Self { self }

    var title: String {
        switch self {
        case .week: AppL10n.text("ios.health.period.week")
        case .month: AppL10n.text("ios.health.period.month")
        case .year: AppL10n.text("ios.health.period.year")
        }
    }

    var rangeTitle: String {
        switch self {
        case .week: AppL10n.text("ios.health.range.7.days")
        case .month: AppL10n.text("ios.health.range.30.days")
        case .year: AppL10n.text("ios.health.range.12.months")
        }
    }
}

struct WorkWalkingChartPoint: Identifiable, Equatable {
    let date: Date
    let workSteps: Int
    let representedDayCount: Int

    var id: Date { date }
}

enum HealthHistoryAggregator {
    static func points(
        from days: [WorkWalkingDaySummary],
        period: HealthHistoryPeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [WorkWalkingChartPoint] {
        let today = calendar.startOfDay(for: now)

        switch period {
        case .week, .month:
            let dayCount = period == .week ? 7 : 30
            guard let firstDay = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) else {
                return []
            }
            let summariesByDay = Dictionary(uniqueKeysWithValues: days.map {
                (calendar.startOfDay(for: $0.day), $0)
            })
            return (0..<dayCount).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else {
                    return nil
                }
                return WorkWalkingChartPoint(
                    date: date,
                    workSteps: summariesByDay[date]?.workSteps ?? 0,
                    representedDayCount: 1
                )
            }

        case .year:
            guard let currentMonth = calendar.date(
                from: calendar.dateComponents([.year, .month], from: today)
            ), let firstMonth = calendar.date(byAdding: .month, value: -11, to: currentMonth) else {
                return []
            }
            return (0..<12).compactMap { offset in
                guard let month = calendar.date(byAdding: .month, value: offset, to: firstMonth),
                      let nextMonth = calendar.date(byAdding: .month, value: 1, to: month) else {
                    return nil
                }
                let availableDays = days.filter {
                    let date = calendar.startOfDay(for: $0.day)
                    return date >= month && date < nextMonth && date <= today
                }
                let total = availableDays.reduce(0) { $0 + $1.workSteps }
                let average = availableDays.isEmpty
                    ? 0
                    : Int((Double(total) / Double(availableDays.count)).rounded())
                return WorkWalkingChartPoint(
                    date: month,
                    workSteps: average,
                    representedDayCount: availableDays.count
                )
            }
        }
    }
}

enum AppleHealthConnectionState: Equatable {
    case unavailable
    case notRequested
    case accessRequested
    case failed(String)
}

/// Croise les périodes où l'app est active et connectée au Mac avec les pas
/// déjà consolidés par HealthKit. L'app reste strictement en lecture seule et
/// ne fabrique aucun échantillon de santé.
@MainActor
final class HealthActivityStore: ObservableObject {
    @Published private(set) var connectionState: AppleHealthConnectionState
    @Published private(set) var days: [WorkWalkingDaySummary] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var syncMessage: String?

    // v2 ajoute la distance et les minutes d'exercice. La clé v1 doit rester
    // reconnue : invalider cette ancienne autorisation empêchait aussi la
    // lecture des pas, pourtant déjà accordée par l'utilisateur.
    private static let authorizationKey = "vibe.walkie.health.authorization-requested.v2"
    private static let legacyStepAuthorizationKey = "vibe.walkie.health.authorization-requested.v1"
    // Le journal local conserve 366 jours afin d'afficher une tendance
    // annuelle sans modifier les données Santé.
    private static let historyDays = 366
    private let healthStore: HKHealthStore
    private let defaults: UserDefaults
    private let workSessions: ConnectedWorkSessionStore
    private var refreshQueued = false
#if DEBUG
    private var isMarketingPreview = false
#endif

    var today: WorkWalkingDaySummary {
        days.first(where: { Calendar.current.isDateInToday($0.day) })
            ?? WorkWalkingDaySummary(
                day: Calendar.current.startOfDay(for: Date()),
                workSteps: 0,
                totalSteps: 0,
                workSessionDuration: 0,
                briskWalkingMinutes: nil,
                walkingDistanceMeters: 0
            )
    }

    var hasRequestedAuthorization: Bool {
        connectionState == .accessRequested
    }

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        defaults: UserDefaults = .standard,
        cacheURL: URL? = nil
    ) {
        self.healthStore = healthStore
        self.defaults = defaults
        self.workSessions = ConnectedWorkSessionStore(
            fileURL: cacheURL ?? Self.defaultCacheURL()
        )
        if !HKHealthStore.isHealthDataAvailable() {
            connectionState = .unavailable
        } else if Self.authorizationWasRequested(in: defaults) {
            connectionState = .accessRequested
        } else {
            connectionState = .notRequested
        }
    }

    /// Ouvre un créneau uniquement lorsque les deux signaux sont vrais, puis
    /// le ferme dès que l'app quitte le premier plan ou que la liaison tombe.
    func updateWorkSessionTracking(
        isAppActive: Bool,
        isConnectedToMac: Bool,
        at date: Date = Date()
    ) {
        workSessions.update(
            isAppActive: isAppActive,
            isConnectedToMac: isConnectedToMac,
            at: date
        )
    }

    func requestAuthorizationAndRefresh(using client: HostConnectionClient) async {
        guard HKHealthStore.isHealthDataAvailable(), !Self.readTypes.isEmpty else {
            connectionState = .unavailable
            return
        }

        isRefreshing = true
        syncMessage = nil
        do {
            try await requestReadAuthorization(for: Self.readTypes)
            defaults.set(true, forKey: Self.authorizationKey)
            connectionState = .accessRequested
            isRefreshing = false
            await refresh(using: client)
        } catch {
            isRefreshing = false
            connectionState = .failed("Apple Santé n’a pas pu être ouvert.")
        }
    }

    func refresh(using client: HostConnectionClient) async {
#if DEBUG
        if isMarketingPreview { return }
#endif
        guard !isRefreshing else {
            // Une lecture Santé peut être en cours quand le Mac termine sa
            // reconnexion. Conserver cette seconde demande évite de rester
            // avec les anciens créneaux jusqu'à une actualisation manuelle.
            refreshQueued = true
            return
        }

        repeat {
            refreshQueued = false
            isRefreshing = true
            await performRefresh(using: client)
            isRefreshing = false
        } while refreshQueued
    }

    private func performRefresh(using client: HostConnectionClient) async {
        syncMessage = nil

        if client.state.isReady, client.connectedHostPlatform != .macOS {
            syncMessage = "Le suivi des sessions de travail nécessite le compagnon Mac."
        } else if !client.state.isReady {
            syncMessage = "Connectez le Mac pour démarrer une session de travail."
        }

        guard connectionState == .accessRequested else { return }
        do {
            days = try await buildDaySummaries()
            lastUpdatedAt = Date()
            await sendHealthActivitySnapshot(using: client)
        } catch {
            let healthError = error as NSError
            connectionState = .failed(
                "Les pas ne sont pas lisibles dans Apple Santé (\(healthError.domain) \(healthError.code))."
            )
        }
    }

    private func buildDaySummaries(now: Date = Date()) async throws -> [WorkWalkingDaySummary] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var summaries: [WorkWalkingDaySummary] = []
        let historyStart = calendar.date(
            byAdding: .day,
            value: -Self.historyDays,
            to: today
        ) ?? now.addingTimeInterval(-Double(Self.historyDays) * 86_400)
        let workIntervals = workSessions.intervals(since: historyStart, now: now)
        let exerciseTimeIsAvailable = (try? await cumulativeQuantity(
            type: Self.exerciseTimeType,
            unit: .minute(),
            from: historyStart,
            to: now
        )) != nil

        for offset in 0..<Self.historyDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let dayEnd = min(nextDay, now)
            let intervals = Self.mergedIntervals(
                from: workIntervals,
                boundedBy: DateInterval(start: day, end: dayEnd)
            )
            var workSteps = 0
            var walkingDistanceMeters = 0.0
            var briskWalkingMinutes: Double? = exerciseTimeIsAvailable ? 0 : nil
            for interval in intervals {
                workSteps += try await stepCount(from: interval.start, to: interval.end)
                walkingDistanceMeters += (try? await walkingDistance(
                    from: interval.start,
                    to: interval.end
                )) ?? 0
                if exerciseTimeIsAvailable {
                    briskWalkingMinutes = (briskWalkingMinutes ?? 0) + ((try? await exerciseMinutes(
                        from: interval.start,
                        to: interval.end
                    )) ?? 0)
                }
            }
            // Le total quotidien n'est affiché que pour aujourd'hui. Éviter les
            // 27 requêtes historiques rend l'ouverture du tableau immédiate.
            let totalSteps = offset == 0 ? try await stepCount(from: day, to: dayEnd) : 0
            let duration = intervals.reduce(0) { $0 + $1.duration }
            summaries.append(WorkWalkingDaySummary(
                day: day,
                workSteps: workSteps,
                totalSteps: totalSteps,
                workSessionDuration: duration,
                briskWalkingMinutes: briskWalkingMinutes,
                walkingDistanceMeters: walkingDistanceMeters
            ))
        }
        return summaries
    }

    private func requestReadAuthorization(for readTypes: Set<HKObjectType>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthActivityError.authorizationFailed)
                }
            }
        }
    }

    private func stepCount(from start: Date, to end: Date) async throws -> Int {
        let value = try await cumulativeQuantity(
            type: Self.stepType,
            unit: .count(),
            from: start,
            to: end
        ) ?? 0
        return max(0, Int(value.rounded()))
    }

    private func walkingDistance(from start: Date, to end: Date) async throws -> Double {
        try await cumulativeQuantity(
            type: Self.walkingDistanceType,
            unit: .meter(),
            from: start,
            to: end
        ) ?? 0
    }

    private func exerciseMinutes(from start: Date, to end: Date) async throws -> Double? {
        try await cumulativeQuantity(
            type: Self.exerciseTimeType,
            unit: .minute(),
            from: start,
            to: end
        )
    }

    private func cumulativeQuantity(
        type: HKQuantityType?,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async throws -> Double? {
        guard end > start, let type else { return nil }
        // HealthKit condense souvent les pas en échantillons qui chevauchent
        // légèrement les bornes d'une session. Les options strictes exigeaient
        // auparavant que les deux dates soient à l'intérieur et pouvaient donc
        // écarter tous les pas d'une courte session. Le mode overlap est celui
        // prévu par HealthKit pour récupérer ces échantillons consolidés.
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: Self.sampleQueryOptions
        )
        do {
            return try await statisticsQuantity(type: type, unit: unit, predicate: predicate)
        } catch {
            // Certaines versions d'iOS peuvent refuser ponctuellement une
            // requête statistique alors que les échantillons restent lisibles.
            // Une lecture directe évite de perdre tous les pas dans ce cas.
            return try await sampleQuantity(type: type, unit: unit, predicate: predicate)
        }
    }

    private func statisticsQuantity(
        type: HKQuantityType,
        unit: HKUnit,
        predicate: NSPredicate
    ) async throws -> Double? {
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let value = statistics?.sumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: value.map { max(0, $0) })
            }
            healthStore.execute(query)
        }
    }

    private func sampleQuantity(
        type: HKQuantityType,
        unit: HKUnit,
        predicate: NSPredicate
    ) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let quantities = (samples ?? []).compactMap { $0 as? HKQuantitySample }
                guard !quantities.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let total = quantities.reduce(0.0) { partial, sample in
                    partial + sample.quantity.doubleValue(for: unit)
                }
                continuation.resume(returning: max(0, total))
            }
            healthStore.execute(query)
        }
    }

    private func sendHealthActivitySnapshot(using client: HostConnectionClient) async {
        guard client.state.isReady, client.connectedHostPlatform == .macOS else { return }
        let recentDays = Array(days.prefix(7))
        let briskValues = recentDays.compactMap(\.briskWalkingMinutes)
        let briskMinutes = briskValues.count == recentDays.count
            ? briskValues.reduce(0, +)
            : nil
        let payload = HealthActivitySnapshotPayload(
            briskWalkingMinutesLast7Days: briskMinutes,
            walkingDistanceMetersLast7Days: recentDays.reduce(0) { $0 + $1.walkingDistanceMeters },
            detectedWalkingDurationLast7Days: recentDays.reduce(0) { $0 + $1.workSessionDuration }
        )
        // Une ancienne version du compagnon ignore ce nouveau type additif.
        // L'envoi sans attente évite qu'un Mac pas encore mis à jour force une
        // reconnexion de l'iPhone pendant le déploiement progressif.
        client.sendFireAndForget(type: .healthActivitySnapshotUpdate, payload: payload)
    }

    static func mergedIntervals(
        from sessions: [DateInterval],
        boundedBy bounds: DateInterval
    ) -> [DateInterval] {
        let clipped = sessions.compactMap { session -> DateInterval? in
            let start = max(bounds.start, session.start)
            let end = min(bounds.end, session.end)
            guard end > start else { return nil }
            return DateInterval(start: start, end: end)
        }.sorted { $0.start < $1.start }

        var merged: [DateInterval] = []
        for interval in clipped {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }
            if interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static var stepType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .stepCount)
    }

    private static var walkingDistanceType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)
    }

    private static var exerciseTimeType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .appleExerciseTime)
    }

    private static var readTypes: Set<HKObjectType> {
        Set([stepType, walkingDistanceType, exerciseTimeType].compactMap { $0 })
    }

    static func authorizationWasRequested(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: authorizationKey)
            || defaults.bool(forKey: legacyStepAuthorizationKey)
    }

    /// Un échantillon HealthKit est retenu dès qu'il chevauche la période.
    /// Cette valeur est interne afin de verrouiller le comportement par test.
    static let sampleQueryOptions: HKQueryOptions = []

    private static func defaultCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vibe Walkie", isDirectory: true)
            .appendingPathComponent("health-connected-work-sessions-v2.json")
    }

#if DEBUG
    /// Données déterministes réservées à la vérification visuelle du simulateur.
    func configureMarketingPreview(now: Date = Date()) {
        isMarketingPreview = true
        connectionState = .accessRequested
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let recentWorkSteps = [1842, 1260, 2110, 980, 1640, 2235, 1510]
        days = (0..<Self.historyDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let steps = offset < recentWorkSteps.count
                ? recentWorkSteps[offset]
                : 1_050 + ((offset * 193) % 1_250)
            return WorkWalkingDaySummary(
                day: day,
                workSteps: steps,
                totalSteps: offset == 0 ? 6934 : 0,
                workSessionDuration: TimeInterval(steps) * 0.55,
                briskWalkingMinutes: Double(steps) / 112,
                walkingDistanceMeters: Double(steps) * 0.74
            )
        }
        lastUpdatedAt = now
        syncMessage = nil
    }
#endif
}

private enum HealthActivityError: Error {
    case authorizationFailed
}
