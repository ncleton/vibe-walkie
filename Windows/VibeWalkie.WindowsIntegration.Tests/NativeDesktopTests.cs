using System.Diagnostics;
using System.Runtime.InteropServices;
using Interop.UIAutomationClient;
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
            var automation = new CUIAutomation8();
            var editorCondition = automation.CreateAndCondition(
                automation.CreatePropertyCondition(UIA_PropertyIds.UIA_ProcessIdPropertyId, editor.Id),
                automation.CreatePropertyCondition(UIA_PropertyIds.UIA_ControlTypePropertyId, UIA_ControlTypeIds.UIA_EditControlTypeId));
            string? lastCaptureError = null;
            for (var attempt = 0; attempt < 100; attempt++)
            {
                try
                {
                    // Establish the real user precondition by clicking our own
                    // editor, rather than assuming Windows grants auto-focus.
                    var field = automation.GetRootElement().FindFirst(TreeScope.TreeScope_Subtree, editorCondition);
                    if (field is not null)
                    {
                        var bounds = field.CurrentBoundingRectangle;
                        Assert.True(SetCursorPos((bounds.left + bounds.right) / 2, (bounds.top + bounds.bottom) / 2));
                        input.Click(PointerButton.Left, 1);
                        await Task.Delay(100, TestContext.Current.CancellationToken);
                    }
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
        finally
        {
            if (!editor.HasExited)
            {
                editor.Kill(entireProcessTree: true);
                if (!editor.WaitForExit(5000)) throw new TimeoutException("The integration editor did not terminate during cleanup.");
            }
            DesktopEditorProcess.RestoreDesktopAccess(editor.Id);
            Directory.Delete(directory, true);
        }
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
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
}
