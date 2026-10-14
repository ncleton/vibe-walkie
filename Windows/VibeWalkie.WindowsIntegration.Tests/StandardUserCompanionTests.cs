using System.Text;
using System.Text.Json;
using Xunit;

namespace VibeWalkie.WindowsIntegration.Tests;

public sealed class StandardUserCompanionTests
{
    [Fact]
    [Trait("Category", "BundledRuntime")]
    public async Task FullNativeCompanionWorksUnderTheRealUnelevatedInteractiveUser()
    {
        Assert.Equal("true", Environment.GetEnvironmentVariable("GITHUB_ACTIONS"));
        var desktopUser = System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value;
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !File.Exists(Path.Combine(root.FullName, "Windows", "scripts", "test-native-window.ps1"))) root = root.Parent;
        Assert.NotNull(root);
        var bundle = Path.Combine(root.FullName, "build", "windows-native-validation");
        Assert.True(File.Exists(Path.Combine(bundle, "VibeWalkie.Companion.exe")), "Build the native bundle before running the BundledRuntime category.");
        var directory = Path.Combine(Path.GetTempPath(), "VibeWalkieStandard-" + Guid.NewGuid().ToString("N"));
        var evidence = Path.Combine(directory, "evidence");
        Directory.CreateDirectory(evidence);
        var script = Path.Combine(directory, "verify.ps1");
        static string Ps(string path) => "'" + path.Replace("'", "''") + "'";
        var verifier = Path.Combine(root.FullName, "Windows", "scripts", "test-native-window.ps1");
        File.WriteAllText(script, $$"""
            $ErrorActionPreference = 'Stop'
            $Evidence = {{Ps(evidence)}}
            try {
                $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                if ($Identity.User.Value -ne '{{desktopUser}}') { throw 'The actual GUI test must use the logged-on desktop account.' }
                $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
                if ($Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'The actual companion test must run without administrator privileges.' }
                & {{Ps(verifier)}} -EvidenceDirectory $Evidence
                @{ tokenIsUnelevated = $true; interactiveAccount = $true; completeNativeUiTest = $true } | ConvertTo-Json |
                    Set-Content -LiteralPath (Join-Path $Evidence 'standard-user.json') -Encoding utf8
            } catch {
                $Failure = $_.Exception.Message
                $Stages = Join-Path $Evidence 'ui-startup.log'
                if (Test-Path -LiteralPath $Stages) { $Failure += "`n" + (Get-Content -Raw -LiteralPath $Stages) }
                $Failure | Set-Content -LiteralPath (Join-Path $Evidence 'failure.txt') -Encoding utf8
                exit 1
            }
            """, new UTF8Encoding(true));
        using var process = DesktopEditorProcess.StartUnelevatedInteractiveUser(script);
        try
        {
            await process.WaitForExitAsync(TestContext.Current.CancellationToken).WaitAsync(TimeSpan.FromMinutes(3), TestContext.Current.CancellationToken);
            var failure = Path.Combine(evidence, "failure.txt");
            Assert.True(process.ExitCode == 0, File.Exists(failure) ? File.ReadAllText(failure) : "The actual standard-user verifier failed without producing a diagnostic.");
            var standard = Path.Combine(evidence, "standard-user.json");
            var native = Path.Combine(evidence, "native-window-evidence.json");
            using var status = JsonDocument.Parse(File.ReadAllText(standard));
            Assert.True(status.RootElement.GetProperty("tokenIsUnelevated").GetBoolean());
            Assert.True(status.RootElement.GetProperty("interactiveAccount").GetBoolean());
            using var ui = JsonDocument.Parse(File.ReadAllText(native));
            foreach (var property in new[] { "runtimeStarted", "configurationPersisted", "unpackagedUpdateError", "cameraSelectionError", "gracefulExit" })
                Assert.True(ui.RootElement.GetProperty(property).GetBoolean(), property);
            // Export only boolean test evidence. Never copy the user's CNG key,
            // pairing QR, confirmation secret, registry or DPAPI profile files.
            File.Copy(native, Path.Combine(bundle, "standard-user-native-evidence.json"), true);
            File.Copy(standard, Path.Combine(bundle, "standard-user-account-evidence.json"), true);
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                if (!process.WaitForExit(5000)) throw new TimeoutException("The standard-user test did not terminate.");
            }
            DesktopEditorProcess.RestoreDesktopAccess(process.Id);
            Directory.Delete(directory, true);
        }
    }
}
