using System.Diagnostics;
using System.Text.Json;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion;

public static class TailscaleDetector
{
    public static async Task<NomadEndpoint?> DetectAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo("tailscale", "status --json")
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                }
            };
            process.Start();
            var json = await process.StandardOutput.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            if (process.ExitCode != 0) return null;
            using var document = JsonDocument.Parse(json);
            var self = document.RootElement.GetProperty("Self");
            var dns = self.GetProperty("DNSName").GetString()?.TrimEnd('.');
            var ip = self.GetProperty("TailscaleIPs").EnumerateArray()
                .Select(static value => value.GetString())
                .FirstOrDefault(static value => value?.StartsWith("100.", StringComparison.Ordinal) == true);
            if (string.IsNullOrWhiteSpace(dns)) return null;
            var endpoint = new NomadEndpoint(dns, ip);
            return endpoint.IsValid ? endpoint : null;
        }
        catch (Exception error)
        {
            LocalDiagnostics.Record("tailscale_unavailable", error);
            return null;
        }
    }
}
