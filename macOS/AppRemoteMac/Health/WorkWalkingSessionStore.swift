import Foundation
import RemoteCore

/// Journal local des périodes de marche reconnues par la caméra du Mac.
///
/// Seules les bornes temporelles quittent le Mac. Aucune image, aucun squelette
/// Vision et aucune métrique corporelle ne sont conservés ni transmis.
@MainActor
final class WorkWalkingSessionStore: ObservableObject {
    @Published private(set) var sessions: [WorkWalkingSession] = []
    @Published private(set) var isWalking = false

    private struct ActiveSession: Codable {
        var id: UUID
        var startedAt: Date
        var lastObservedAt: Date
    }

    private struct DiskState: Codable {
        var sessions: [WorkWalkingSession]
        var active: ActiveSession?
    }

    private static let retention: TimeInterval = 366 * 24 * 60 * 60
    private static let maximumSessionDuration: TimeInterval = 12 * 60 * 60
    private static let minimumSessionDuration: TimeInterval = 3
    private let fileURL: URL
    private var active: ActiveSession?
    private var lastPersistedHeartbeat: Date?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    func observe(_ activity: ActivityState, at date: Date = Date()) {
        switch activity {
        case .walking:
            if active == nil {
                // Le détecteur confirme une cadence après trois secondes. Les
                // réintégrer évite de jeter les premiers pas du créneau.
                active = ActiveSession(
                    id: UUID(),
                    startedAt: date.addingTimeInterval(-3),
                    lastObservedAt: date
                )
                isWalking = true
                persist()
            } else {
                active?.lastObservedAt = date
                if lastPersistedHeartbeat.map({ date.timeIntervalSince($0) >= 10 }) ?? true {
                    persist()
                }
            }

        case .stationary:
            guard let current = active else {
                isWalking = false
                return
            }
            // L'arrêt est confirmé après cinq secondes sans cadence.
            finish(current, at: date.addingTimeInterval(-5))
        }
    }

    func finishActive(at date: Date = Date()) {
        guard let current = active else { return }
        finish(current, at: min(date, current.lastObservedAt))
    }

    func snapshot(since: Date, now: Date = Date()) -> WorkWalkingSessionsSnapshotPayload {
        var visible = sessions.filter { $0.endedAt >= since }
        if let active {
            visible.append(WorkWalkingSession(
                id: active.id,
                startedAt: active.startedAt,
                endedAt: min(now, active.lastObservedAt.addingTimeInterval(2)),
                isOngoing: true
            ))
        }
        visible.sort { $0.startedAt < $1.startedAt }
        return WorkWalkingSessionsSnapshotPayload(sessions: visible, capturedAt: now)
    }

    func walkingDuration(on day: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }
        return snapshot(since: start, now: day).sessions.reduce(0) { total, session in
            let overlapStart = max(start, session.startedAt)
            let overlapEnd = min(end, session.endedAt)
            return total + max(0, overlapEnd.timeIntervalSince(overlapStart))
        }
    }

#if DEBUG
    /// Données déterministes réservées aux captures exactes du dashboard.
    func configureMarketingPreview(now: Date = Date()) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        sessions = (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let startedAt = calendar.date(byAdding: .hour, value: 9 + (offset % 3), to: day) else {
                return nil
            }
            return WorkWalkingSession(
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(TimeInterval(46 + offset * 7) * 60)
            )
        }
        active = nil
        isWalking = false
    }
#endif

    private func finish(_ current: ActiveSession, at proposedEnd: Date) {
        let end = min(
            max(proposedEnd, current.startedAt),
            current.startedAt.addingTimeInterval(Self.maximumSessionDuration)
        )
        if end.timeIntervalSince(current.startedAt) >= Self.minimumSessionDuration {
            sessions.append(WorkWalkingSession(
                id: current.id,
                startedAt: current.startedAt,
                endedAt: end
            ))
            sessions.sort { $0.startedAt < $1.startedAt }
        }
        active = nil
        isWalking = false
        prune(referenceDate: end)
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? RemoteCoding.decoder.decode(DiskState.self, from: data) else {
            return
        }
        sessions = state.sessions.filter(Self.isPlausible)
        if let interrupted = state.active,
           interrupted.lastObservedAt.timeIntervalSince(interrupted.startedAt) >= Self.minimumSessionDuration {
            sessions.append(WorkWalkingSession(
                id: interrupted.id,
                startedAt: interrupted.startedAt,
                endedAt: min(
                    interrupted.lastObservedAt,
                    interrupted.startedAt.addingTimeInterval(Self.maximumSessionDuration)
                )
            ))
        }
        sessions.sort { $0.startedAt < $1.startedAt }
        active = nil
        isWalking = false
        prune(referenceDate: Date())
        persist()
    }

    private func prune(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-Self.retention)
        sessions = sessions.filter { $0.endedAt >= cutoff && Self.isPlausible($0) }
    }

    private func persist() {
        lastPersistedHeartbeat = Date()
        let state = DiskState(sessions: sessions, active: active)
        guard let data = try? RemoteCoding.encoder.encode(state) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Une erreur disque ne doit jamais interrompre le coach caméra.
        }
    }

    private static func isPlausible(_ session: WorkWalkingSession) -> Bool {
        session.endedAt >= session.startedAt
            && session.duration <= maximumSessionDuration
    }

    private static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vibe Walkie", isDirectory: true)
            .appendingPathComponent("work-walking-sessions.json")
    }
}
