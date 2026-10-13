using System.Diagnostics;
using VibeWalkie.Companion.Input;
using VibeWalkie.Companion.Screen;
using VibeWalkie.Protocol;
using Xunit;

namespace VibeWalkie.WindowsIntegration.Tests;

public sealed class NativeDesktopTests
{
    [Fact]
    public async Task RealWinFormsEditorVerifiesUnicodeSelectionAndChangedTarget()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory); var script = Path.Combine(directory, "editor.ps1");
        File.WriteAllText(script, """
            Add-Type -AssemblyName System.Windows.Forms
            $form = New-Object System.Windows.Forms.Form
            $form.Text = "Vibe Walkie native integration editor"
            $form.Width = 640; $form.Height = 480
            $text = New-Object System.Windows.Forms.TextBox
            $text.Multiline = $true; $text.Width = 600; $text.Height = 360
            $text.Text = "Initial "
            $form.Controls.Add($text)
            $form.Add_Shown({ $form.Activate(); $text.Focus(); $text.Select($text.TextLength, 0) })
            [System.Windows.Forms.Application]::Run($form)
            """);
        using var editor = DesktopEditorProcess.Start(script);
        try
        {
            var capture = new TargetCaptureService(); var input = new InputService(); TargetToken? token = null;
            string? lastCaptureError = null;
            for (var attempt = 0; attempt < 100; attempt++)
            {
                try
                {
                    token = capture.Capture();
                    if (token.ApplicationIdentifier == editor.Id.ToString()) break;
                    token = null;
                }
                catch (ProtocolException error) { lastCaptureError = $"{error.Code}: {error.Message}"; }
                await Task.Delay(100, TestContext.Current.CancellationToken);
            }
            Assert.True(token is not null, $"The real editor was not captured. Last error: {lastCaptureError}; exited: {editor.HasExited}");
            Assert.Contains("powershell", token.ApplicationName, StringComparison.OrdinalIgnoreCase);
            Assert.Equal(editor.Id.ToString(), token.ApplicationIdentifier);
            var target = capture.Resolve(token.Token);
            Assert.True(input.InsertText("Bonjour été 🌍\nEncore café", target).Verified);
            Assert.Contains("Bonjour été 🌍", TargetCaptureService.ReadText(target.Element).Text);
            var next = capture.Capture(); var changed = capture.Resolve(next.Token);
            input.TypeManually("changement", true);
            for (var attempt = 0; attempt < 40 && TargetCaptureService.ReadText(changed.Element).Text == changed.Snapshot.Text; attempt++)
                await Task.Delay(25, TestContext.Current.CancellationToken);
            Assert.NotEqual(changed.Snapshot.Text, TargetCaptureService.ReadText(changed.Element).Text);
            Assert.Equal(RemoteErrorCode.TargetChanged, Assert.Throws<ProtocolException>(() => input.InsertText("ne pas insérer", changed)).Code);
            capture.Consume(); input.ReleaseInputs();
        }
        finally { if (!editor.HasExited) editor.Kill(entireProcessTree: true); Directory.Delete(directory, true); }
    }
    [Fact]
    public async Task NativeDxgiCaptureProducesRealBoundedJpegAndReportsFailure()
    {
        await using var capture = new ScreenCaptureService();
        var first = new TaskCompletionSource<ScreenFramePayload>(TaskCreationOptions.RunContinuationsAsynchronously);
        capture.Failed += error => first.TrySetException(error);
        capture.Start(new ScreenStreamRequestPayload(true, 640, 4, .4), frame => { first.TrySetResult(frame); return ValueTask.CompletedTask; });
        var result = await first.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.InRange(result.Width, 1, 640); Assert.True(result.Height > 0);
        Assert.True(result.JpegData.Length > 1000); Assert.Equal(0xFF, result.JpegData[0]);
        capture.Stop();
    }
}
