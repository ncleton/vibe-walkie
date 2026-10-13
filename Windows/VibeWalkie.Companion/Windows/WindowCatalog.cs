using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Windows;

public sealed class WindowCatalog
{
    public WindowsSnapshotPayload Snapshot()
    {
        var foreground = Native.GetForegroundWindow();
        var windows = new List<(int ProcessID, nint Handle, string Title, bool Minimized)>();
        Native.EnumWindows((handle, parameter) =>
        {
            if (!Native.IsWindowVisible(handle) || Native.GetWindowTextLength(handle) == 0 || IsCloaked(handle)) return true;
            Native.GetWindowThreadProcessId(handle, out var processID);
            if (processID == Environment.ProcessId) return true;
            var length = Native.GetWindowTextLength(handle);
            var title = new StringBuilder(length + 1);
            _ = Native.GetWindowText(handle, title, title.Capacity);
            var text = title.ToString().Trim();
            if (text.Length == 0) return true;
            windows.Add(((int)processID, handle, text, Native.IsIconic(handle)));
            return true;
        }, 0);

        var applications = windows.GroupBy(static item => item.ProcessID).Select(group =>
        {
            var processName = TryProcessName(group.Key);
            return new RemoteApplication(
                group.Key.ToString(), processName, group.Key.ToString(),
                group.Any(item => item.Handle == foreground), null,
                group.Select(item => new RemoteWindow(
                    item.Handle.ToInt64().ToString("x"), item.Title, item.Handle == foreground, item.Minimized)).ToArray());
        }).OrderByDescending(static app => app.IsActive).ThenBy(static app => app.Name).ToArray();
        return new WindowsSnapshotPayload(applications, applications.FirstOrDefault(static app => app.IsActive)?.ID, DateTimeOffset.UtcNow);
    }

    public void Activate(string applicationID, string? windowID)
    {
        if (!int.TryParse(applicationID, out var processID)) throw new ProtocolException(RemoteErrorCode.ApplicationNotFound);
        nint handle = 0;
        if (windowID is not null)
        {
            if (!long.TryParse(windowID, System.Globalization.NumberStyles.HexNumber, null, out var parsed))
                throw new ProtocolException(RemoteErrorCode.ApplicationNotFound);
            handle = (nint)parsed;
            if (!IsWindowForProcess(handle, processID)) throw new ProtocolException(RemoteErrorCode.ApplicationNotFound);
        }
        if (handle == 0 || !Native.IsWindow(handle))
        {
            Native.EnumWindows((candidate, parameter) =>
            {
                if (IsWindowForProcess(candidate, processID)) { handle = candidate; return false; }
                return true;
            }, 0);
        }
        if (handle == 0) throw new ProtocolException(RemoteErrorCode.ApplicationNotFound);
        if (Native.IsIconic(handle)) Native.ShowWindow(handle, 9);
        if (!Native.SetForegroundWindow(handle)) throw new ProtocolException(RemoteErrorCode.ActivationDenied);
    }

    private static bool IsWindowForProcess(nint handle, int processID)
    {
        if (!Native.IsWindow(handle) || !Native.IsWindowVisible(handle) || Native.GetWindowTextLength(handle) == 0 || IsCloaked(handle)) return false;
        Native.GetWindowThreadProcessId(handle, out var candidateProcess);
        return candidateProcess == processID;
    }

    private static string TryProcessName(int id) { try { return Process.GetProcessById(id).ProcessName; } catch { return "Application"; } }
    private static bool IsCloaked(nint window) => Native.DwmGetWindowAttribute(window, 14, out var cloaked, sizeof(int)) == 0 && cloaked != 0;

    private static class Native
    {
        public delegate bool EnumWindowsCallback(nint window, nint parameter);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsCallback callback, nint parameter);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(nint window);
        [DllImport("user32.dll")] public static extern bool IsWindow(nint window);
        [DllImport("user32.dll")] public static extern bool IsIconic(nint window);
        [DllImport("user32.dll")] public static extern nint GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(nint window);
        [DllImport("user32.dll")] public static extern bool ShowWindow(nint window, int command);
        [DllImport("user32.dll")] public static extern int GetWindowTextLength(nint window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(nint window, StringBuilder value, int maximum);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(nint window, out uint processID);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(nint window, int attribute, out int value, int size);
    }
}
