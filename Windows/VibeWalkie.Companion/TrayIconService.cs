using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace VibeWalkie.Companion;

public sealed class TrayIconService : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private readonly nint _window;
    private readonly Native.SubclassProcedure _procedure;
    private Native.NotifyIconData _icon;
    private bool _allowClose;

    public TrayIconService(Window window)
    {
        LocalDiagnostics.StartupStage("tray_window_handle_start");
        _window = WinRT.Interop.WindowNative.GetWindowHandle(window);
        LocalDiagnostics.StartupStage("tray_window_handle_ready");
        _procedure = WindowProcedure;
        if (!Native.SetWindowSubclass(_window, _procedure, 1, 0)) throw new InvalidOperationException("Windows refuse l’intégration de l’icône de notification. Relancez Vibe Walkie dans votre session utilisateur.");
        LocalDiagnostics.StartupStage("tray_subclass_ready");
        LocalDiagnostics.StartupStage("tray_icon_load_start");
        _icon = new Native.NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<Native.NotifyIconData>(),
            Window = _window,
            ID = 1,
            Flags = 0x1 | 0x2 | 0x4,
            CallbackMessage = CallbackMessage,
            Icon = Native.LoadImage(0, Path.Combine(AppContext.BaseDirectory, "Assets", "VibeWalkie.ico"), 1, 32, 32, 0x10),
            Tip = "Vibe Walkie — compagnon Windows",
        };
        LocalDiagnostics.StartupStage("tray_icon_loaded");
        if (_icon.Icon == 0) throw new InvalidOperationException("L’icône du compagnon est absente ou endommagée. Réinstallez le paquet Windows complet.");
        if (!Native.ShellNotifyIcon(0, ref _icon)) throw new InvalidOperationException("La zone de notification Windows est indisponible. Vérifiez que l’Explorateur Windows est actif dans votre session, puis relancez Vibe Walkie.");
        LocalDiagnostics.StartupStage("tray_icon_registered");
    }

    public event Action? QuitRequested;
    public bool ShouldCancelClose() => !_allowClose;
    public void HideWindow() => Native.ShowWindow(_window, 0);
    public void ShowWindow()
    {
        Native.ShowWindow(_window, 5);
        Native.SetForegroundWindow(_window);
    }

    private nint WindowProcedure(nint window, uint message, nint wParam, nint lParam, nint subclass, nint data)
    {
        if (message == CallbackMessage)
        {
            var action = (uint)lParam;
            if (action == 0x0202 || action == 0x0203) ShowWindow();
            if (action == 0x0205) ShowMenu();
        }
        return Native.DefSubclassProc(window, message, wParam, lParam);
    }

    private void ShowMenu()
    {
        var menu = Native.CreatePopupMenu();
        try
        {
            Native.AppendMenu(menu, 0, 1, "Ouvrir Vibe Walkie");
            Native.AppendMenu(menu, 0, 2, "Quitter");
            Native.GetCursorPos(out var point);
            Native.SetForegroundWindow(_window);
            var selection = Native.TrackPopupMenu(menu, 0x0100 | 0x0002, point.X, point.Y, 0, _window, 0);
            if (selection == 1) ShowWindow();
            if (selection == 2)
            {
                _allowClose = true;
                Dispose();
                QuitRequested?.Invoke();
            }
        }
        finally { Native.DestroyMenu(menu); }
    }

    public void Dispose()
    {
        if (_icon.Size != 0)
        {
            _ = Native.ShellNotifyIcon(2, ref _icon);
            if (_icon.Icon != 0) _ = Native.DestroyIcon(_icon.Icon);
            _icon.Icon = 0;
        }
        _icon.Size = 0;
        _ = Native.RemoveWindowSubclass(_window, _procedure, 1);
    }

    private static class Native
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern nint LoadImage(nint instance, string name, uint type, int cx, int cy, uint flags);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct NotifyIconData
        {
            public uint Size; public nint Window; public uint ID; public uint Flags; public uint CallbackMessage; public nint Icon;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
            public uint State; public uint StateMask;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
            public uint TimeoutOrVersion;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
            public uint InfoFlags; public Guid Guid; public nint BalloonIcon;
        }
        [StructLayout(LayoutKind.Sequential)] public struct Point { public int X; public int Y; }
        public delegate nint SubclassProcedure(nint window, uint message, nint wParam, nint lParam, nint subclass, nint data);
        [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", ExactSpelling = true, CharSet = CharSet.Unicode)] public static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(nint icon);
        [DllImport("comctl32.dll")] public static extern bool SetWindowSubclass(nint window, SubclassProcedure procedure, nint id, nint data);
        [DllImport("comctl32.dll")] public static extern bool RemoveWindowSubclass(nint window, SubclassProcedure procedure, nint id);
        [DllImport("comctl32.dll")] public static extern nint DefSubclassProc(nint window, uint message, nint wParam, nint lParam);
        [DllImport("user32.dll")] public static extern bool ShowWindow(nint window, int command);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(nint window);
        [DllImport("user32.dll")] public static extern nint CreatePopupMenu();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool AppendMenu(nint menu, uint flags, nint id, string text);
        [DllImport("user32.dll")] public static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint rectangle);
        [DllImport("user32.dll")] public static extern bool DestroyMenu(nint menu);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
    }
}
