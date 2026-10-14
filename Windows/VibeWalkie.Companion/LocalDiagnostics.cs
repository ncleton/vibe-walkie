namespace VibeWalkie.Companion;

public static class LocalDiagnostics
{
    private static readonly object Lock = new();
    private static readonly Queue<string> Entries = new();

    public static void Record(string category, Exception? error = null)
    {
        var safe = $"{DateTimeOffset.UtcNow:O} {category} {error?.GetType().Name}".TrimEnd();
        lock (Lock)
        {
            Entries.Enqueue(safe);
            while (Entries.Count > 200) Entries.Dequeue();
        }
    }

    public static void StartupStage(string stage)
    {
        // Opt-in CI startup diagnostics: only fixed stage names, PID and
        // session metadata, never text, keys, QR secrets or camera pixels.
        var path = Environment.GetEnvironmentVariable("VIBEWALKIE_UI_DIAGNOSTIC_PATH");
        if (path is null) return;
        File.AppendAllText(path, $"{DateTimeOffset.UtcNow:O} {Environment.ProcessId} {stage}\n");
    }

    public static string ExportRedacted()
    {
        lock (Lock) return string.Join(Environment.NewLine, Entries);
    }
}
