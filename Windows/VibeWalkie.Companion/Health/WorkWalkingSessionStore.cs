using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Health;

/// Only session times are persisted; camera frames and landmarks never are.
public sealed class WorkWalkingSessionStore
{
    private readonly object _lock = new();
    private readonly string _path;
    private List<WorkWalkingSession> _sessions = [];
    private WorkWalkingSession? _active;
    private DateTimeOffset _lastPersisted;
    public HealthActivitySnapshotPayload? HealthSnapshot { get; private set; }

    public WorkWalkingSessionStore(string path)
    {
        _path = path;
        if (!File.Exists(path)) return;
        var stored = CanonicalJson.Deserialize<DiskState>(File.ReadAllBytes(path));
        _sessions = stored.Sessions.ToList();
        if (stored.Active is { } interrupted) Finish(interrupted, interrupted.EndedAt);
        Prune(DateTimeOffset.UtcNow);
    }
    public void UpdateHealth(HealthActivitySnapshotPayload payload)
    {
        payload.Validate(DateTimeOffset.UtcNow);
        lock (_lock) HealthSnapshot = payload;
    }
    public void Observe(bool walking, DateTimeOffset now)
    {
        lock (_lock)
        {
            if (walking)
            {
                _active = _active is { } current
                    ? current with { EndedAt = now }
                    : new WorkWalkingSession(Guid.NewGuid(), now.AddSeconds(-3), now, true);
                if (now - _lastPersisted >= TimeSpan.FromSeconds(10)) Persist(now);
            }
            else if (_active is { } current) Finish(current, now.AddSeconds(-5));
        }
    }
    public void FinishActive(DateTimeOffset now)
    {
        lock (_lock) if (_active is { } active) Finish(active, now < active.EndedAt ? now : active.EndedAt);
    }
    public WorkWalkingSessionsSnapshotPayload Snapshot(DateTimeOffset since, DateTimeOffset now)
    {
        lock (_lock)
        {
            var sessions = _sessions.Where(session => session.EndedAt >= since).ToList();
            if (_active is { } active)
            {
                var end = active.EndedAt.AddSeconds(2);
                sessions.Add(active with { EndedAt = end < now ? end : now });
            }
            return new(sessions.OrderBy(session => session.StartedAt).ToArray(), now);
        }
    }
    private void Finish(WorkWalkingSession active, DateTimeOffset proposedEnd)
    {
        var end = proposedEnd < active.StartedAt ? active.StartedAt : proposedEnd;
        if (end > active.StartedAt.AddHours(12)) end = active.StartedAt.AddHours(12);
        if (end - active.StartedAt >= TimeSpan.FromSeconds(3))
            _sessions.Add(active with { EndedAt = end, IsOngoing = false });
        _active = null; Prune(end); Persist(end);
    }
    private void Prune(DateTimeOffset now) => _sessions.RemoveAll(session =>
        session.EndedAt < now.AddDays(-366) || session.EndedAt < session.StartedAt
        || session.EndedAt - session.StartedAt > TimeSpan.FromHours(12));
    private void Persist(DateTimeOffset now)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, CanonicalJson.SerializeToUtf8Bytes(new DiskState(_sessions, _active)));
            File.Move(temporary, _path, overwrite: true);
            _lastPersisted = now;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private sealed record DiskState(IReadOnlyList<WorkWalkingSession> Sessions, WorkWalkingSession? Active);
}
