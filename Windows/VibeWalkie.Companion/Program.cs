using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace VibeWalkie.Companion;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            LocalDiagnostics.StartupStage("managed_entry");
            WinRT.ComWrappersSupport.InitializeComWrappers();
            LocalDiagnostics.StartupStage("com_wrappers_ready");
            Application.Start(parameters =>
            {
                LocalDiagnostics.StartupStage("application_callback");
                SynchronizationContext.SetSynchronizationContext(
                    new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
                _ = new App();
            });
            return 0;
        }
        catch (Exception error)
        {
            LocalDiagnostics.Record("framework_startup_failed", error);
            LocalDiagnostics.StartupStage($"framework_startup_error_{error.GetType().Name}_{error.HResult:X8}");
            MessageBoxW(0,
                $"Le composant d’interface Windows n’a pas démarré (code 0x{error.HResult:X8}). " +
                "Fermez cette fenêtre, relancez Vibe Walkie depuis votre session Windows et transmettez ce code si le problème persiste.",
                "Vibe Walkie — démarrage impossible", 0x10);
            return 1;
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int MessageBoxW(nint window, string text, string caption, uint type);
}
