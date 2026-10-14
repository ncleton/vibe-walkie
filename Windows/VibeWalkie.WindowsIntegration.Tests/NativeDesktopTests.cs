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
            var automation = new CUIAutomation8 { ConnectionTimeout = 1000, TransactionTimeout = 2000 };
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
            for (var attempt = 0; attempt < 40 && !TargetCaptureService.ReadText(changed.Element).Text.EndsWith("changement"); attempt++)
                await Task.Delay(25, TestContext.Current.CancellationToken);
            var beforeKeys = TargetCaptureService.ReadText(changed.Element).Text;
            Assert.EndsWith("changement", beforeKeys);
            input.Press(RemoteKey.Backspace, 4);
            var expectedKeys = beforeKeys[..^4];
            for (var attempt = 0; attempt < 40 && TargetCaptureService.ReadText(changed.Element).Text != expectedKeys; attempt++)
                await Task.Delay(25, TestContext.Current.CancellationToken);
            Assert.Equal(expectedKeys, TargetCaptureService.ReadText(changed.Element).Text);
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
    public async Task RealWpfEditorVerifiesReplacementAndRejectsPasswordFields()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var script = Path.Combine(directory, "editor.ps1");
        var ready = Path.Combine(directory, "ready.txt");
        void Stage(string value)
        {
            var path = Path.Combine(Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? directory, "native-wpf-progress.log");
            File.AppendAllText(path, value + Environment.NewLine);
        }
        Stage("creating_actual_wpf_editor");
        File.WriteAllText(script, """
            $ErrorActionPreference = 'Stop'
            $ReadyPath = Join-Path $PSScriptRoot 'ready.txt'
            $FailurePath = Join-Path $PSScriptRoot 'wpf-failure.txt'
            trap { ('wpf_startup_error_' + $_.Exception.GetType().Name + '_' + $_.Exception.HResult.ToString('X8')) | Set-Content -LiteralPath $FailurePath; exit 1 }
            Add-Type -AssemblyName PresentationFramework
            $window = New-Object System.Windows.Window
            $window.Title = 'Vibe Walkie WPF integration editor'
            $window.Width = 640; $window.Height = 480
            $panel = New-Object System.Windows.Controls.StackPanel
            $text = New-Object System.Windows.Controls.TextBox
            $text.Text = 'Initial WPF text'; $text.AcceptsReturn = $true; $text.Height = 300
            $password = New-Object System.Windows.Controls.PasswordBox
            $password.Height = 40
            $panel.Children.Add($text) | Out-Null
            $panel.Children.Add($password) | Out-Null
            $window.Content = $panel
            $window.Add_ContentRendered({
                $window.Activate(); $text.Focus() | Out-Null
                [IO.File]::WriteAllText($ReadyPath, 'rendered')
            })
            $window.ShowDialog() | Out-Null
            """);
        using var editor = DesktopEditorProcess.StartUnelevatedInteractiveUser(script);
        Stage("actual_wpf_process_created");
        var input = new InputService();
        try
        {
            for (var attempt = 0; attempt < 100 && !File.Exists(ready) && !editor.HasExited; attempt++)
                await Task.Delay(100, TestContext.Current.CancellationToken);
            var startupFailure = Path.Combine(directory, "wpf-failure.txt");
            Assert.True(File.Exists(ready), $"The real WPF editor did not render. Process exited: {editor.HasExited}. " +
                (File.Exists(startupFailure) ? File.ReadAllText(startupFailure) : "No startup error was reported."));
            Stage("actual_wpf_content_rendered");
            var automation = new CUIAutomation8 { ConnectionTimeout = 1000, TransactionTimeout = 2000 };
            Stage("uia_client_created");
            var capture = new TargetCaptureService();
            var owner = automation.CreatePropertyCondition(UIA_PropertyIds.UIA_ProcessIdPropertyId, editor.Id);
            var editable = automation.CreatePropertyCondition(UIA_PropertyIds.UIA_ControlTypePropertyId, UIA_ControlTypeIds.UIA_EditControlTypeId);
            var plain = automation.CreatePropertyCondition(UIA_PropertyIds.UIA_IsPasswordPropertyId, false);
            var fieldCondition = automation.CreateAndCondition(editable, plain);
            TargetToken? token = null;
            string? lastError = null;
            for (var attempt = 0; attempt < 100; attempt++)
            {
                try
                {
                    Stage("finding_actual_wpf_window");
                    var window = automation.GetRootElement().FindFirst(TreeScope.TreeScope_Children, owner);
                    Stage(window is null ? "actual_wpf_window_not_found" : "actual_wpf_window_found");
                    Stage("finding_actual_wpf_field");
                    var field = window?.FindFirst(TreeScope.TreeScope_Descendants, fieldCondition);
                    if (field is not null)
                    {
                        var bounds = field.CurrentBoundingRectangle;
                        Assert.True(SetCursorPos((bounds.left + bounds.right) / 2, (bounds.top + bounds.bottom) / 2));
                        input.Click(PointerButton.Left, 1);
                        await Task.Delay(100, TestContext.Current.CancellationToken);
                        input.Press(RemoteKey.SelectAll);
                        await Task.Delay(100, TestContext.Current.CancellationToken);
                        Stage("actual_wpf_selection_established");
                    }
                    if (field is null) { await Task.Delay(100, TestContext.Current.CancellationToken); continue; }
                    Stage("capturing_actual_wpf_target");
                    token = capture.Capture();
                    if (token.ApplicationIdentifier == editor.Id.ToString()) break;
                    token = null;
                }
                catch (ProtocolException error) { lastError = error.Code.ToString(); }
                await Task.Delay(100, TestContext.Current.CancellationToken);
            }
            Assert.True(token is not null, $"The real WPF editor was not captured: {lastError}.");
            Stage("actual_wpf_target_captured");
            var target = capture.Resolve(token.Token);
            Stage("actual_wpf_target_resolved");
            Assert.IsAssignableFrom<IUIAutomationTextPattern>(target.Element.GetCurrentPattern(UIA_PatternIds.UIA_TextPatternId));
            Assert.Equal(0, target.Snapshot.Start);
            Assert.Equal(target.Snapshot.Text.Length, target.Snapshot.End);
            const string replacement = "Dictée été 🌍\nDeuxième ligne";
            Assert.True(input.InsertText(replacement, target).Verified);
            Stage("actual_wpf_insertion_verified");
            Assert.Equal(replacement, TextSelectionSnapshot.Normalize(TargetCaptureService.ReadText(target.Element).Text));
            capture.Consume();
            Assert.Equal(RemoteErrorCode.TargetLost, Assert.Throws<ProtocolException>(() => capture.Resolve(token.Token)).Code);

            var ownWindow = automation.GetRootElement().FindFirst(TreeScope.TreeScope_Children, owner);
            var secure = ownWindow?.FindFirst(TreeScope.TreeScope_Descendants,
                automation.CreatePropertyCondition(UIA_PropertyIds.UIA_IsPasswordPropertyId, true));
            Assert.NotNull(secure);
            secure.SetFocus();
            await Task.Delay(100, TestContext.Current.CancellationToken);
            Assert.Equal(RemoteErrorCode.SecureTarget, Assert.Throws<ProtocolException>(() => capture.Capture()).Code);
            Stage("actual_wpf_password_rejected");
        }
        finally
        {
            input.ReleaseInputs();
            if (!editor.HasExited)
            {
                editor.Kill(entireProcessTree: true);
                if (!editor.WaitForExit(5000)) throw new TimeoutException("The WPF integration editor did not terminate during cleanup.");
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
    [Fact]
    public async Task ActualCursorPreservesSmallDeltasAndReleasesRemoteDrag()
    {
        Assert.True(GetCursorPos(out var original));
        var input = new InputService();
        try
        {
            input.PointerAbsolute(.5, .5);
            Assert.True(GetCursorPos(out var center));
            for (var count = 0; count < 40; count++) input.PointerMove(.25, -.25);
            Assert.True(GetCursorPos(out var moved));
            Assert.Equal(center.X + 10, moved.X); Assert.Equal(center.Y - 10, moved.Y);
            input.Drag(DragPhase.Began, 0, 0);
            for (var attempt = 0; attempt < 40 && (GetAsyncKeyState(1) & 0x8000) == 0; attempt++)
                await Task.Delay(25, TestContext.Current.CancellationToken);
            Assert.NotEqual(0, GetAsyncKeyState(1) & 0x8000);
            input.ReleaseInputs();
            for (var attempt = 0; attempt < 40 && (GetAsyncKeyState(1) & 0x8000) != 0; attempt++)
                await Task.Delay(25, TestContext.Current.CancellationToken);
            Assert.Equal(0, GetAsyncKeyState(1) & 0x8000);
        }
        finally { input.ReleaseInputs(); SetCursorPos(original.X, original.Y); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct CursorPoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out CursorPoint point);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
}
