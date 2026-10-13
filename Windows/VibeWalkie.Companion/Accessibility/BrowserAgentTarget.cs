using System.Diagnostics;
using System.Runtime.InteropServices;
using Interop.UIAutomationClient;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Accessibility;

public static class BrowserAgentTarget
{
    public static async Task<AgentPageTarget> CaptureAsync(AgentTargetRequest request)
    {
        if (request.AllowedOrigins.Count is < 1 or > 8 || request.AllowedOrigins.Any(origin => AgentOrigin.Canonical(origin) != origin)
            || !Guid.TryParse(request.ChallengeID, out _)) throw new ProtocolException(RemoteErrorCode.UnsupportedCapability);
        var automation = new CUIAutomation8();
        var window = GetForegroundWindow();
        var root = automation.ElementFromHandle(window);
        var process = Process.GetProcessById(root.CurrentProcessId).ProcessName.ToLowerInvariant();
        if (process is not ("chrome" or "msedge" or "brave")) throw new ProtocolException(RemoteErrorCode.NoFocusedTarget);
        var initial = ReadTab(automation, root);
        var origin = AgentOrigin.Canonical(initial.Url);
        if (origin is null || !request.AllowedOrigins.Contains(origin)) throw new ProtocolException(RemoteErrorCode.NoFocusedTarget);
        var deadline = DateTimeOffset.UtcNow.AddSeconds(6);
        do
        {
            if (GetForegroundWindow() != window) throw new ProtocolException(RemoteErrorCode.TargetChanged);
            var tab = ReadTab(automation, root);
            if (tab.Url != initial.Url || !tab.Runtime.SequenceEqual(initial.Runtime)) throw new ProtocolException(RemoteErrorCode.TargetChanged);
            var marker = AgentNativeMarker.Parse(tab.Title, request.ChallengeID!);
            if (marker is not null) return new AgentPageTarget("", "", "Page active", origin, DiscoveryMarker: marker);
            await Task.Delay(150);
        } while (DateTimeOffset.UtcNow < deadline);
        throw new ProtocolException(RemoteErrorCode.NoFocusedTarget);
    }
    private sealed record Tab(string Url, string Title, int[] Runtime);
    private static Tab ReadTab(IUIAutomation automation, IUIAutomationElement root)
    {
        var queue = new Queue<(IUIAutomationElement Element, bool Toolbar)>();
        queue.Enqueue((root, false));
        var walker = automation.ControlViewWalker;
        string? url = null, title = null;
        int[]? runtime = null;
        for (var count = 0; queue.Count > 0 && count < 500; count++)
        {
            var (element, toolbar) = queue.Dequeue();
            var type = element.CurrentControlType;
            // Never read an address-like field supplied by web content.
            if (type == UIA_ControlTypeIds.UIA_DocumentControlTypeId) continue;
            toolbar |= type == UIA_ControlTypeIds.UIA_ToolBarControlTypeId;
            if (toolbar && type == UIA_ControlTypeIds.UIA_EditControlTypeId
                && element.GetCurrentPattern(UIA_PatternIds.UIA_ValuePatternId) is IUIAutomationValuePattern value)
            {
                var candidate = value.CurrentValue;
                if (Uri.TryCreate(candidate, UriKind.Absolute, out var parsed) && parsed.Scheme == "https")
                {
                    if (url is not null) throw new ProtocolException(RemoteErrorCode.NoFocusedTarget);
                    url = candidate;
                }
            }
            if (type == UIA_ControlTypeIds.UIA_TabItemControlTypeId
                && element.GetCurrentPattern(UIA_PatternIds.UIA_SelectionItemPatternId) is IUIAutomationSelectionItemPattern selection
                && selection.CurrentIsSelected != 0)
            {
                title = element.CurrentName; runtime = element.GetRuntimeId();
            }
            for (var child = walker.GetFirstChildElement(element); child is not null; child = walker.GetNextSiblingElement(child))
                queue.Enqueue((child, toolbar));
        }
        return url is not null && title is not null && runtime is not null ? new Tab(url, title, runtime)
            : throw new ProtocolException(RemoteErrorCode.NoFocusedTarget);
    }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
}
