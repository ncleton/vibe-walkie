using System.Diagnostics;
using System.Runtime.InteropServices;
using Interop.UIAutomationClient;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.VoiceActions;

public static class AssistantVoiceControl
{
    public static async Task HandleAsync(VoiceControlPayload payload)
    {
        var automation = new CUIAutomation8();
        var handle = GetForegroundWindow();
        var root = automation.ElementFromHandle(handle);
        var names = payload.Provider == VoiceAssistantProvider.Claude ? new[] { "Claude" } : new[] { "Codex", "ChatGPT" };
        var foregroundName = Process.GetProcessById(root.CurrentProcessId).ProcessName;
        if (!names.Contains(foregroundName, StringComparer.OrdinalIgnoreCase))
        {
            var running = names.SelectMany(Process.GetProcessesByName).Where(process => process.MainWindowHandle != 0).ToArray();
            if (running.Length != 1) throw new ProtocolException(RemoteErrorCode.NoFocusedTarget);
            handle = running[0].MainWindowHandle;
            if (!SetForegroundWindow(handle)) throw new ProtocolException(RemoteErrorCode.ActivationDenied);
            root = automation.ElementFromHandle(handle);
        }
        var name = Process.GetProcessById(root.CurrentProcessId).ProcessName.ToLowerInvariant();
        var supported = payload.Provider == VoiceAssistantProvider.Claude ? name == "claude" : name is "chatgpt" or "codex";
        if (!supported) throw new ProtocolException(RemoteErrorCode.NoFocusedTarget);
        var listening = payload.Phase == VoiceControlPhase.Began;
        var start = new[] { "unmute", "unmute microphone", "activer le microphone", "activer le micro", "réactiver le micro", "resume listening", "reprendre l’écoute", "start listening", "commencer l’écoute" };
        var stop = new[] { "mute", "mute microphone", "couper le microphone", "couper le micro", "désactiver le micro", "stop listening", "arrêter l’écoute", "pause listening", "suspendre l’écoute" };
        var previous = Find(automation, root, listening ? stop : start);
        if (previous is not null) return;
        var button = Find(automation, root, listening ? start : stop);
        if (button is null) throw new ProtocolException(RemoteErrorCode.NoFocusedTarget);
        if (GetForegroundWindow() != handle) throw new ProtocolException(RemoteErrorCode.TargetChanged);
        if (button.GetCurrentPattern(UIA_PatternIds.UIA_InvokePatternId) is not IUIAutomationInvokePattern invoke)
            throw new ProtocolException(RemoteErrorCode.UnsupportedCapability);
        invoke.Invoke();
        for (var attempt = 0; attempt < 20; attempt++)
        {
            await Task.Delay(150);
            if (GetForegroundWindow() != handle) throw new ProtocolException(RemoteErrorCode.TargetChanged);
            if (Find(automation, root, listening ? stop : start) is not null) return;
        }
        throw new ProtocolException(RemoteErrorCode.InputUnavailable);
    }
    private static IUIAutomationElement? Find(IUIAutomation automation, IUIAutomationElement root, string[] labels)
    {
        var queue = new Queue<(IUIAutomationElement Element, int Depth)>(); queue.Enqueue((root, 0));
        var walker = automation.ControlViewWalker;
        for (var count = 0; queue.Count > 0 && count < 6_000; count++)
        {
            var (element, depth) = queue.Dequeue();
            if (element.CurrentIsPassword != 0 || element.CurrentIsOffscreen != 0) continue;
            if (element.CurrentControlType == UIA_ControlTypeIds.UIA_ButtonControlTypeId
                && labels.Any(label => element.CurrentName.Equals(label, StringComparison.OrdinalIgnoreCase) || element.CurrentName.StartsWith(label + " (", StringComparison.OrdinalIgnoreCase))) return element;
            if (depth >= 32) continue;
            for (var child = walker.GetFirstChildElement(element); child is not null; child = walker.GetNextSiblingElement(child)) queue.Enqueue((child, depth + 1));
        }
        return null;
    }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
}
