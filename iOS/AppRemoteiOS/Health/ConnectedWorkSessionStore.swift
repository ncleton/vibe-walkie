import Foundation

/// Journal local des périodes pendant lesquelles Vibe Walkie est réellement
/// utilisable comme télécommande : l'app iPhone est active et le Mac est prêt.
///
/// Les pas restent lus a posteriori dans HealthKit. Ce journal ne contient que
/// des bornes temporelles et n'enregistre aucune donnée de santé.
@MainActor
final class ConnectedWorkSessionStore {
    private struct StoredSession: Codable {
        let startedAt: Date
        let endedAt: Date

        var isPlausible: Bool {
            endedAt > startedAt && endedAt.timeIntervalSince(startedAt) <= 24 * 60 * 60
        }
    }

    private static let retention: TimeInterval = 366 * 24 * 60 * 60

    private let fileURL: URL
    private var completedSessions: [StoredSession] = []
    private var activeSessionStartedAt: Date?

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    var isTracking: Bool {
        activeSessionStartedAt != nil
    }

    func update(
        isAppActive: Bool,
        isConnectedToMac: Bool,
        at date: Date = Date()
    ) {
        if isAppActive && isConnectedToMac {
            if activeSessionStartedAt == nil {
                activeSessionStartedAt = date
            }
        } else {
            finishActive(at: date)
        }
    }

    func intervals(since: Date, now: Date = Date()) -> [DateInterval] {
        var intervals = completedSessions.compactMap { session -> DateInterval? in
            guard session.endedAt >= since else { return nil }
            return DateInterval(start: session.startedAt, end: session.endedAt)
        }
        if let startedAt = activeSessionStartedAt, now > startedAt {
            intervals.append(DateInterval(start: startedAt, end: now))
        }
        return intervals.sorted { $0.start < $1.start }
    }

    private func finishActive(at date: Date) {
        guard let startedAt = activeSessionStartedAt else { return }
        activeSessionStartedAt = nil
        if date > startedAt {
            completedSessions.append(StoredSession(startedAt: startedAt, endedAt: date))
        }
        prune(referenceDate: date)
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([StoredSession].self, from: data) else {
            return
        }
        completedSessions = decoded.filter(\.isPlausible)
        prune(referenceDate: Date())
    }

    private func prune(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-Self.retention)
        completedSessions = completedSessions.filter {
            $0.endedAt >= cutoff && $0.isPlausible
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(completedSessions) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Une erreur disque ne doit jamais interrompre l'usage de la télécommande.
        }
    }
}
