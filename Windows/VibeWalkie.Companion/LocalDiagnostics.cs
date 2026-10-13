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

    public static string ExportRedacted()
    {
        lock (Lock) return string.Join(Environment.NewLine, Entries);
    }
}
