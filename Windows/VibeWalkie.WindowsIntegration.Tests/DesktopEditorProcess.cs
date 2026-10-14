using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Security.AccessControl;
using System.Security.Principal;

namespace VibeWalkie.WindowsIntegration.Tests;

internal static class DesktopEditorProcess
{
    private static readonly Dictionary<int, List<DesktopAccess>> DesktopLeases = new();
    // Use Windows' genuine UAC-linked token for the logged-on account. WinUI
    // activation and WPF accessibility must share the desktop's user context;
    // running another account inside the runner's session tests RunAs instead.
    // No fabricated token, impersonation, elevated fallback or UAC change.
    public static Process StartUnelevatedInteractiveUser(string script)
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true")
            throw new InvalidOperationException("The UAC-linked desktop test is restricted to the disposable Windows CI machine.");
        var shell = Native.GetShellWindow();
        if (shell == 0) throw new InvalidOperationException("A logged-on interactive Explorer desktop is required.");
        Native.GetWindowThreadProcessId(shell, out var shellId);
        var shellProcess = Native.OpenProcess(0x1000, false, shellId);
        if (shellProcess == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            if (!Native.OpenProcessToken(shellProcess, 0x0008, out var shellToken))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                using var shellIdentity = new WindowsIdentity(shellToken);
                using var callerIdentity = WindowsIdentity.GetCurrent();
                if (shellIdentity.User != callerIdentity.User)
                    throw new InvalidOperationException("The test runner and interactive desktop must belong to the same Windows account.");
            }
            finally { Native.CloseHandle(shellToken); }
        }
        finally { Native.CloseHandle(shellProcess); }
        using var current = Process.GetCurrentProcess();
        if (!Native.OpenProcessToken(current.Handle, 0x000A, out var token))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            if (!Native.GetTokenPointerInformation(token, 19, out var linked, nint.Size, out _))
                throw new InvalidOperationException("Windows CI must provide the logged-on user's genuine non-elevated UAC token. No administrator fallback is allowed.");
            try
            {
                if (!Native.GetTokenIntegerInformation(linked, 20, out var elevated, sizeof(int), out _))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if (elevated != 0) throw new InvalidOperationException("The linked Windows token is elevated; this cannot validate ordinary-user behavior.");
                if (!Native.DuplicateTokenEx(linked, 0x02000000, 0, 2, 1, out var primary))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                try
                {
                    var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
                    var command = new StringBuilder($"\"{executable}\" -NoProfile -STA -ExecutionPolicy Bypass -File \"{script}\"");
                    var startup = new Native.StartupInfo { Size = Marshal.SizeOf<Native.StartupInfo>(), Desktop = "winsta0\\default" };
                    if (!Native.CreateProcessWithTokenW(primary, 1, executable, command, 0x10, 0,
                            Path.GetDirectoryName(script), ref startup, out var child))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    try { return Process.GetProcessById(child.ProcessId); }
                    finally { Native.CloseHandle(child.Thread); Native.CloseHandle(child.Process); }
                }
                finally { Native.CloseHandle(primary); }
            }
            finally { Native.CloseHandle(linked); }
        }
        finally { Native.CloseHandle(token); }
    }
    // Hosted CI runs elevated. Use the actual interactive Explorer user's
    // token so the editor has the same permissions as a normal desktop app.
    // The companion must continue to reject elevated target applications.
    public static Process Start(string script, bool writableTestDirectory = false)
    {
        var username = Environment.GetEnvironmentVariable("VIBEWALKIE_TEST_USERNAME");
        if (username is not null) return StartStandardUser(script, username, writableTestDirectory);
        var shell = Native.GetShellWindow();
        if (shell == 0) throw new InvalidOperationException("The integration test requires a real interactive Explorer desktop.");
        Native.GetWindowThreadProcessId(shell, out var shellId);
        var process = Native.OpenProcess(0x1000, false, shellId);
        if (process == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            if (!Native.OpenProcessToken(process, 0x000A, out var token))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                if (!Native.DuplicateTokenEx(token, 0x02000000, 0, 2, 1, out var primary))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                try
                {
                    var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                        "WindowsPowerShell", "v1.0", "powershell.exe");
                    var command = new StringBuilder($"\"{executable}\" -NoProfile -STA -ExecutionPolicy Bypass -File \"{script}\"");
                    var startup = new Native.StartupInfo
                    {
                        Size = Marshal.SizeOf<Native.StartupInfo>(), Desktop = "winsta0\\default"
                    };
                    if (!Native.CreateProcessWithTokenW(primary, 0, executable, command, 0x10, 0,
                            Path.GetDirectoryName(script), ref startup, out var child))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    try { return Process.GetProcessById(child.ProcessId); }
                    finally { Native.CloseHandle(child.Thread); Native.CloseHandle(child.Process); }
                }
                finally { Native.CloseHandle(primary); }
            }
            finally { Native.CloseHandle(token); }
        }
        finally { Native.CloseHandle(process); }
    }

    private static Process StartStandardUser(string script, string username, bool writableTestDirectory)
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true")
            throw new InvalidOperationException("The separate desktop test account is restricted to the disposable GitHub Actions machine.");
        var password = Environment.GetEnvironmentVariable("VIBEWALKIE_TEST_PASSWORD")
            ?? throw new InvalidOperationException("The CI standard-user credentials are not configured.");
        var directory = Path.GetDirectoryName(script)!;
        var access = new ProcessStartInfo("icacls.exe") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        var permission = writableTestDirectory ? "M" : "RX";
        foreach (var argument in new[] { directory, "/grant", $"{Environment.MachineName}\\{username}:(OI)(CI){permission}" }) access.ArgumentList.Add(argument);
        using (var acl = Process.Start(access) ?? throw new InvalidOperationException("Cannot grant read access to the integration editor."))
        {
            if (!acl.WaitForExit(5000) || acl.ExitCode != 0) throw new InvalidOperationException("The real standard user cannot read the integration editor script.");
        }
        var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        var command = new StringBuilder($"\"{executable}\" -NoProfile -STA -ExecutionPolicy Bypass -File \"{script}\"");
        var startup = new Native.StartupInfo { Size = Marshal.SizeOf<Native.StartupInfo>(), Desktop = "winsta0\\default" };
        var leases = new List<DesktopAccess>();
        var transferred = false;
        try
        {
            var sid = (SecurityIdentifier)new NTAccount(Environment.MachineName, username).Translate(typeof(SecurityIdentifier));
            leases.Add(DesktopAccess.Grant(Native.GetProcessWindowStation(), sid, 0x000F037F));
            leases.Add(DesktopAccess.Grant(Native.GetThreadDesktop(Native.GetCurrentThreadId()), sid, 0x000F01FF));
            if (!Native.CreateProcessWithLogonW(username, Environment.MachineName, password, 1, executable, command, 0x10, 0,
                    directory, ref startup, out var child)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var editor = Process.GetProcessById(child.ProcessId);
                DesktopLeases.Add(editor.Id, leases);
                transferred = true;
                return editor;
            }
            finally { Native.CloseHandle(child.Thread); Native.CloseHandle(child.Process); }
        }
        finally { if (!transferred) foreach (var lease in leases.AsEnumerable().Reverse()) lease.Restore(); }
    }

    public static void RestoreDesktopAccess(int processId)
    {
        if (!DesktopLeases.Remove(processId, out var leases)) return;
        foreach (var lease in leases.AsEnumerable().Reverse()) lease.Restore();
    }

    private sealed record DesktopAccess(nint Handle, byte[] Original)
    {
        public static DesktopAccess Grant(nint handle, SecurityIdentifier user, int access)
        {
            if (handle == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint information = 4; // DACL_SECURITY_INFORMATION; owner/SACL stay intact.
            Native.GetUserObjectSecurity(handle, ref information, null, 0, out var length);
            if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            var original = new byte[length];
            if (!Native.GetUserObjectSecurity(handle, ref information, original, length, out _))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var descriptor = new RawSecurityDescriptor(original, 0);
            if (descriptor.DiscretionaryAcl is not null)
            {
                descriptor.DiscretionaryAcl.InsertAce(descriptor.DiscretionaryAcl.Count,
                    new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, access, user, false, null));
                var updated = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(updated, 0);
                if (!Native.SetUserObjectSecurity(handle, ref information, updated)) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return new DesktopAccess(handle, original);
        }
        public void Restore()
        {
            uint information = 4;
            if (!Native.SetUserObjectSecurity(Handle, ref information, Original)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct StartupInfo
        {
            public int Size;
            public string? Reserved, Desktop, Title;
            public uint X, Y, Width, Height, XChars, YChars, FillAttribute, Flags;
            public ushort ShowWindow, ReservedSize;
            public nint ReservedPointer, StandardInput, StandardOutput, StandardError;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct ProcessInformation
        {
            public nint Process, Thread;
            public int ProcessId, ThreadId;
        }
        [DllImport("user32.dll")] public static extern nint GetShellWindow();
        [DllImport("user32.dll", SetLastError = true)] public static extern nint GetProcessWindowStation();
        [DllImport("user32.dll", SetLastError = true)] public static extern nint GetThreadDesktop(uint threadId);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll", SetLastError = true)] public static extern bool GetUserObjectSecurity(nint handle, ref uint information, [Out] byte[]? descriptor, uint length, out uint required);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool SetUserObjectSecurity(nint handle, ref uint information, byte[] descriptor);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(nint window, out uint processId);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern nint OpenProcess(uint access, bool inherit, uint processId);
        [DllImport("advapi32.dll", SetLastError = true)] public static extern bool OpenProcessToken(nint process, uint access, out nint token);
        [DllImport("advapi32.dll", EntryPoint = "GetTokenInformation", SetLastError = true)]
        public static extern bool GetTokenPointerInformation(nint token, int informationClass, out nint value, int length, out int required);
        [DllImport("advapi32.dll", EntryPoint = "GetTokenInformation", SetLastError = true)]
        public static extern bool GetTokenIntegerInformation(nint token, int informationClass, out int value, int length, out int required);
        [DllImport("advapi32.dll", SetLastError = true)] public static extern bool DuplicateTokenEx(nint token, uint access, nint attributes, int impersonationLevel, int tokenType, out nint primary);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessWithTokenW(nint token, uint logonFlags, string application,
            StringBuilder commandLine, uint flags, nint environment, string? currentDirectory,
            ref StartupInfo startup, out ProcessInformation process);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessWithLogonW(string user, string domain, string password, uint logonFlags,
            string application, StringBuilder commandLine, uint flags, nint environment, string? currentDirectory,
            ref StartupInfo startup, out ProcessInformation process);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(nint handle);
    }
}
