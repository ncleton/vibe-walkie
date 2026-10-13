using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using VibeWalkie.Companion.Health;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Posture;

public sealed record PosturePresentation(string Phase, double Progress, string Activity, int Severity,
    string? Issue, string Viewpoint, bool Sound, bool HasNeck, bool HasUpperBody, bool HasFullBody, bool EnoughLight);

public sealed class PostureCoachService(WorkWalkingSessionStore walking) : IAsyncDisposable
{
    private CancellationTokenSource? _lifetime;
    private Task? _monitor;
    private string? _command;
    public string Sensitivity { get; set; } = "balanced";
    public bool IsRunning => _monitor is { IsCompleted: false };
    public event Action<PosturePresentation, byte[]>? Changed;
    public event Action<string>? Failed;
    private static string VisionPath => Path.Combine(AppContext.BaseDirectory, "Vision", "VibeWalkieVision.exe");

    public static async Task<IReadOnlyList<string>> CamerasAsync()
    {
        using var process = Launch(VisionPath, "--models", Path.Combine(AppContext.BaseDirectory, "Vision", "models"), "--list");
        var output = await process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20));
        if (process.ExitCode != 0) throw new InvalidOperationException("Inventaire caméra impossible. Réinstallez les composants du coach Windows.");
        return JsonSerializer.Deserialize<string[]>(output) ?? throw new InvalidOperationException("Inventaire caméra invalide.");
    }
    public void Start(int cameraIndex)
    {
        if (IsRunning) return;
        _lifetime = new CancellationTokenSource();
        _monitor = MonitorAsync(cameraIndex, _lifetime.Token);
    }
    public void Calibrate(bool leaned) => Interlocked.Exchange(ref _command, leaned ? "lean" : "calibrate");
    private async Task MonitorAsync(int cameraIndex, CancellationToken cancellation)
    {
        Process? vision = null, core = null;
        try
        {
            core = Launch(Path.Combine(AppContext.BaseDirectory, "PostureCore", "PostureCore.exe"));
            vision = Launch(VisionPath, "--models", Path.Combine(AppContext.BaseDirectory, "Vision", "models"), "--camera", cameraIndex.ToString());
            while (!cancellation.IsCancellationRequested)
            {
                var line = await vision.StandardOutput.ReadLineAsync(cancellation).AsTask().WaitAsync(TimeSpan.FromSeconds(15), cancellation);
                if (line is null) throw new InvalidOperationException("Le moteur caméra s’est arrêté. Vérifiez les autorisations caméra Windows puis redémarrez le coach.");
                var frame = JsonNode.Parse(line) ?? throw new InvalidDataException();
                if (frame["error"] is { } error) throw new InvalidOperationException(error.GetValue<string>());
                var preview = Convert.FromBase64String(frame["preview"]!.GetValue<string>());
                frame.AsObject().Remove("preview");
                frame["command"] = Interlocked.Exchange(ref _command, null);
                frame["sensitivity"] = Sensitivity;
                await core.StandardInput.WriteLineAsync(frame.ToJsonString().AsMemory(), cancellation);
                await core.StandardInput.FlushAsync(cancellation);
                var result = await core.StandardOutput.ReadLineAsync(cancellation).AsTask().WaitAsync(TimeSpan.FromSeconds(5), cancellation);
                if (result is null) throw new InvalidOperationException("Le moteur de posture s’est arrêté. Réinstallez le compagnon Windows.");
                using var document = JsonDocument.Parse(result);
                if (document.RootElement.TryGetProperty("error", out var coreError)) throw new InvalidOperationException(coreError.GetString());
                var presentation = CanonicalJson.Deserialize<PosturePresentation>(result);
                walking.Observe(presentation.Activity == "walking", DateTimeOffset.UtcNow);
                Changed?.Invoke(presentation, preview);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception error)
        {
            LocalDiagnostics.Record("posture_failed", error);
            Failed?.Invoke(error is InvalidOperationException ? error.Message : "Le coach caméra a échoué. Fermez les autres applications caméra et redémarrez le coach.");
        }
        finally
        {
            foreach (var process in new[] { vision, core })
                if (process is not null) { if (!process.HasExited) process.Kill(entireProcessTree: true); process.Dispose(); }
            walking.FinishActive(DateTimeOffset.UtcNow);
        }
    }
    private static Process Launch(string executable, params string[] arguments)
    {
        if (!File.Exists(executable)) throw new InvalidOperationException("Le composant " + Path.GetFileName(executable) + " est absent. Réinstallez le compagnon Windows complet.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardInput = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        return Process.Start(start) ?? throw new InvalidOperationException("Le composant caméra ne peut pas démarrer.");
    }
    public async ValueTask DisposeAsync()
    {
        if (_lifetime is null) return;
        await _lifetime.CancelAsync();
        if (_monitor is not null) await _monitor;
        _lifetime.Dispose(); _lifetime = null; _monitor = null;
    }
}
