using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Interop.UIAutomationClient;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Input;

public sealed class TargetCaptureService
{
    private readonly IUIAutomation _automation = new CUIAutomation8();
    private TargetRecord? _target;

    public TargetToken Capture()
    {
        var element = _automation.GetFocusedElement() ?? throw new ProtocolException(RemoteErrorCode.NoFocusedTarget);
        if (element.CurrentIsPassword != 0) throw new ProtocolException(RemoteErrorCode.SecureTarget);
        if (IsElevated(element.CurrentProcessId)) throw new ProtocolException(RemoteErrorCode.InputUnavailable, "Application élevée hors périmètre");
        var token = Guid.NewGuid().ToString("N");
        var expires = DateTimeOffset.UtcNow.Add(VibeWalkieInfo.TargetTokenLifetime);
        var snapshot = ReadText(element);
        var window = Native.GetForegroundWindow();
        _target = new TargetRecord(token, element, element.GetRuntimeId(), element.CurrentProcessId,
            window, snapshot, TryProcessName(element.CurrentProcessId), expires);
        var processName = TryProcessName(element.CurrentProcessId);
        return new TargetToken(token, processName, element.CurrentProcessId.ToString(), TryWindowTitle(_target.WindowHandle), expires);
    }

    public TargetRecord Resolve(string token)
    {
        var target = _target;
        if (target is null || !CryptographicOperations.FixedTimeEquals(
                System.Text.Encoding.UTF8.GetBytes(target.Token), System.Text.Encoding.UTF8.GetBytes(token)))
            throw new ProtocolException(RemoteErrorCode.TargetLost);
        if (DateTimeOffset.UtcNow >= target.ExpiresAt)
        {
            _target = null;
            throw new ProtocolException(RemoteErrorCode.TargetExpired);
        }
        try
        {
            if (target.Element.CurrentProcessId != target.ProcessID || !target.Element.GetRuntimeId().SequenceEqual(target.RuntimeID))
                throw new ProtocolException(RemoteErrorCode.TargetChanged);
            if (target.Element.CurrentIsPassword != 0) throw new ProtocolException(RemoteErrorCode.SecureTarget);
            if (IsElevated(target.ProcessID)) throw new ProtocolException(RemoteErrorCode.InputUnavailable);
            if (!Native.SetForegroundWindow(target.WindowHandle))
                throw new ProtocolException(RemoteErrorCode.ActivationDenied);
            target.Element.SetFocus();
            target.VerifyUnchanged();
            return target;
        }
        catch (COMException)
        {
            _target = null;
            throw new ProtocolException(RemoteErrorCode.TargetLost);
        }
    }

    public void Consume() => _target = null;

    private static string TryProcessName(int id)
    {
        try { return Process.GetProcessById(id).ProcessName; }
        catch { return "Application"; }
    }

    private static string? TryWindowTitle(nint handle)
    {
        var length = Native.GetWindowTextLength(handle);
        if (length <= 0) return null;
        var value = new char[length + 1];
        _ = Native.GetWindowText(handle, value, value.Length);
        return new string(value).TrimEnd('\0');
    }

    private static bool IsElevated(int processID)
    {
        nint process = Native.OpenProcess(0x1000, false, processID);
        if (process == 0) return true;
        try
        {
            if (!Native.OpenProcessToken(process, 0x0008, out var token)) return true;
            try
            {
                var elevation = new Native.TokenElevation();
                return !Native.GetTokenInformation(token, 20, ref elevation, Marshal.SizeOf<Native.TokenElevation>(), out _)
                    || elevation.TokenIsElevated != 0;
            }
            finally { Native.CloseHandle(token); }
        }
        finally { Native.CloseHandle(process); }
    }

    public static TextSelectionSnapshot ReadText(IUIAutomationElement element)
    {
        if (element.CurrentIsPassword != 0) throw new ProtocolException(RemoteErrorCode.SecureField);
        if (element.GetCurrentPattern(UIA_PatternIds.UIA_TextPatternId) is IUIAutomationTextPattern pattern)
        {
            var document = pattern.DocumentRange;
            var text = document.GetText(1_000_001);
            var ranges = pattern.GetSelection();
            if (text.Length > 1_000_000 || ranges.Length != 1)
                throw new ProtocolException(RemoteErrorCode.AXNotSettable);
            var selection = ranges.GetElement(0);
            var prefix = document.Clone();
            prefix.MoveEndpointByRange(TextPatternRangeEndpoint.TextPatternRangeEndpoint_End,
                selection, TextPatternRangeEndpoint.TextPatternRangeEndpoint_Start);
            var start = prefix.GetText(-1).Length;
            return new TextSelectionSnapshot(text, start, start + selection.GetText(-1).Length);
        }
        // Standard Win32/WinForms Edit controls lack TextPattern, but expose
        // their exact UTF-16 selection through marshalled window messages.
        var handle = (nint)element.CurrentNativeWindowHandle;
        var className = new System.Text.StringBuilder(256);
        Native.GetClassName(handle, className, className.Capacity);
        if (!className.ToString().Equals("Edit", StringComparison.OrdinalIgnoreCase)
            && !className.ToString().StartsWith("WindowsForms10.EDIT.", StringComparison.OrdinalIgnoreCase))
            throw new ProtocolException(RemoteErrorCode.AXNotSettable);
        nint Message(uint message, nint wParam, nint lParam)
        {
            if (Native.SendMessageTimeout(handle, message, wParam, lParam, 0x23, 1000, out var value) == 0)
                throw new ProtocolException(RemoteErrorCode.InputUnavailable);
            return (nint)value;
        }
        var length = checked((int)Message(0x000E, 0, 0));
        if (length is < 0 or > 1_000_000) throw new ProtocolException(RemoteErrorCode.AXNotSettable);
        var buffer = Marshal.AllocHGlobal((length + 1) * 2);
        var startPointer = Marshal.AllocHGlobal(4); var endPointer = Marshal.AllocHGlobal(4);
        try
        {
            Message(0x000D, length + 1, buffer); Message(0x00B0, startPointer, endPointer);
            return new TextSelectionSnapshot(Marshal.PtrToStringUni(buffer) ?? "",
                Marshal.ReadInt32(startPointer), Marshal.ReadInt32(endPointer));
        }
        finally { Marshal.FreeHGlobal(buffer); Marshal.FreeHGlobal(startPointer); Marshal.FreeHGlobal(endPointer); }
    }

    public sealed record TargetRecord(string Token, IUIAutomationElement Element, int[] RuntimeID,
        int ProcessID, nint WindowHandle, TextSelectionSnapshot Snapshot, string ApplicationName, DateTimeOffset ExpiresAt)
    {
        public void VerifyUnchanged() => Snapshot.Verify(ReadText(Element));
    }

    private static class Native
    {
        [DllImport("user32.dll")] public static extern nint GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(nint window, System.Text.StringBuilder name, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern nint SendMessageTimeout(nint window, uint message, nint wParam, nint lParam, uint flags, uint timeout, out nuint result);
        [StructLayout(LayoutKind.Sequential)] public struct TokenElevation { public int TokenIsElevated; }
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetForegroundWindow(nint window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(nint window, [Out] char[] text, int maximum);
        [DllImport("user32.dll")] public static extern int GetWindowTextLength(nint window);
        [DllImport("kernel32.dll")] public static extern nint OpenProcess(uint access, bool inherit, int processID);
        [DllImport("advapi32.dll")] public static extern bool OpenProcessToken(nint process, uint access, out nint token);
        [DllImport("advapi32.dll")] public static extern bool GetTokenInformation(nint token, int informationClass, ref TokenElevation info, int length, out int returnLength);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(nint handle);
    }
}
