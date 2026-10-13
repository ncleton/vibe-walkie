using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace VibeWalkie.Companion;

public partial class App : Application
{
    private MainWindow? _window;
    public static CompanionRuntime Runtime { get; private set; } = null!;

    public App()
    {
        LocalDiagnostics.StartupStage("app_constructor");
        InitializeComponent();
        LocalDiagnostics.StartupStage("app_resources_ready");
        UnhandledException += (_, args) =>
        {
            LocalDiagnostics.Record("unhandled", args.Exception);
            _window?.ShowFailure("Vibe Walkie a rencontré une erreur. Copiez le diagnostic local puis relancez le compagnon.");
            args.Handled = _window is not null;
        };
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        LocalDiagnostics.StartupStage("on_launched");
        var instance = AppInstance.FindOrRegisterForKey("VibeWalkie.Companion");
        LocalDiagnostics.StartupStage(instance.IsCurrent ? "primary_instance" : "secondary_instance");
        if (!instance.IsCurrent)
        {
            await instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs());
            Environment.Exit(0);
            return;
        }
        instance.Activated += (_, _) => _window?.DispatcherQueue.TryEnqueue(() => _window.ShowFromTray());
        _window = new MainWindow();
        _window.Activate();
        LocalDiagnostics.StartupStage("window_activated");
        try
        {
            _window.InitializeTray();
            Runtime = new CompanionRuntime(_window.DispatcherQueue);
            _window.Bind(Runtime);
            LocalDiagnostics.StartupStage("runtime_bound");
            await Runtime.StartAsync();
            LocalDiagnostics.StartupStage("runtime_started");
        }
        catch (Exception error)
        {
            LocalDiagnostics.Record("startup_failed", error);
            LocalDiagnostics.StartupStage("runtime_error_" + error.GetType().Name);
            _window.ShowFailure(error is InvalidOperationException or System.IO.InvalidDataException ? error.Message : "Le compagnon n’a pas démarré. Vérifiez le diagnostic et les autorisations Windows, puis relancez Vibe Walkie.");
        }
    }
}
