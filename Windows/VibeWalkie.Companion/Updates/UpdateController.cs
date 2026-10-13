using Windows.ApplicationModel;
using Windows.System;

namespace VibeWalkie.Companion.Updates;

public sealed class UpdateController
{
    public async Task<string> CheckAsync()
    {
        var package = Package.Current;
        if (package.GetAppInstallerInfo() is null)
            throw new InvalidOperationException("Les mises à jour nécessitent l’installation MSIX signée de Vibe Walkie via App Installer. Installez ce paquet pour activer ce canal.");
        var result = await package.CheckUpdateAvailabilityAsync();
        return result.Availability switch
        {
            PackageUpdateAvailability.Available or PackageUpdateAvailability.Required => "Une mise à jour est disponible.",
            PackageUpdateAvailability.NoUpdates => "Vibe Walkie est à jour.",
            _ => throw new InvalidOperationException("Windows ne peut pas vérifier la mise à jour. Vérifiez votre connexion et l’accès HTTPS au canal App Installer.")
        };
    }
    public async Task InstallAsync()
    {
        var info = Package.Current.GetAppInstallerInfo()
            ?? throw new InvalidOperationException("Installez le paquet MSIX signé via App Installer pour mettre à jour Vibe Walkie.");
        if (info.Uri.Scheme != "https") throw new InvalidOperationException("Le canal Windows doit utiliser une adresse HTTPS.");
        if (!await Launcher.LaunchUriAsync(new Uri("ms-appinstaller:?source=" + Uri.EscapeDataString(info.Uri.AbsoluteUri))))
            throw new InvalidOperationException("App Installer n’a pas démarré. Installez ou réparez Microsoft App Installer depuis le Microsoft Store.");
    }
    public static async Task<bool> SetStartupAsync(bool enabled)
    {
        var task = await StartupTask.GetAsync("VibeWalkieStartup");
        if (!enabled) { task.Disable(); return false; }
        var result = await task.RequestEnableAsync();
        if (result is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy) return true;
        throw new InvalidOperationException("Le démarrage automatique est désactivé dans Windows. Autorisez Vibe Walkie dans le Gestionnaire des tâches, Applications de démarrage.");
    }
}
