using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace VibeWalkie.WindowsIntegration.Tests;

internal static class DesktopEditorProcess
{
    // Hosted CI runs elevated. Use the actual interactive Explorer user's
    // token so the editor has the same permissions as a normal desktop app.
    // The companion must continue to reject elevated target applications.
    public static Process Start(string script)
    {
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
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(nint window, out uint processId);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern nint OpenProcess(uint access, bool inherit, uint processId);
        [DllImport("advapi32.dll", SetLastError = true)] public static extern bool OpenProcessToken(nint process, uint access, out nint token);
        [DllImport("advapi32.dll", SetLastError = true)] public static extern bool DuplicateTokenEx(nint token, uint access, nint attributes, int impersonationLevel, int tokenType, out nint primary);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessWithTokenW(nint token, uint logonFlags, string application,
            StringBuilder commandLine, uint flags, nint environment, string? currentDirectory,
            ref StartupInfo startup, out ProcessInformation process);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(nint handle);
    }
}
