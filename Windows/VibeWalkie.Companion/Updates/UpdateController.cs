using Windows.ApplicationModel;
using Windows.System;
using System.Runtime.InteropServices;
using System.Text;

namespace VibeWalkie.Companion.Updates;

public sealed class UpdateController
{
    private static Package RequirePackage()
    {
        uint length = 0;
        var status = GetCurrentPackageFullName(ref length, null);
        if (status == 15700) // APPMODEL_ERROR_NO_PACKAGE
            throw new InvalidOperationException("Installez le paquet MSIX signé de Vibe Walkie via App Installer pour activer les mises à jour et le démarrage automatique.");
        if (status != 122) throw new System.ComponentModel.Win32Exception(status, "Windows ne peut pas lire l’identité installée du compagnon. Réparez son installation MSIX.");
        return Package.Current;
    }
    [DllImport("kernel32.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern int GetCurrentPackageFullName(ref uint length, StringBuilder? fullName);

    public async Task<string> CheckAsync()
    {
        var package = RequirePackage();
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
        var info = RequirePackage().GetAppInstallerInfo()
            ?? throw new InvalidOperationException("Installez le paquet MSIX signé via App Installer pour mettre à jour Vibe Walkie.");
        if (info.Uri.Scheme != "https") throw new InvalidOperationException("Le canal Windows doit utiliser une adresse HTTPS.");
        if (!await Launcher.LaunchUriAsync(new Uri("ms-appinstaller:?source=" + Uri.EscapeDataString(info.Uri.AbsoluteUri))))
            throw new InvalidOperationException("App Installer n’a pas démarré. Installez ou réparez Microsoft App Installer depuis le Microsoft Store.");
    }
    public static async Task<bool> SetStartupAsync(bool enabled)
    {
        _ = RequirePackage();
        var task = await StartupTask.GetAsync("VibeWalkieStartup");
        if (!enabled) { task.Disable(); return false; }
        var result = await task.RequestEnableAsync();
        if (result is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy) return true;
        throw new InvalidOperationException("Le démarrage automatique est désactivé dans Windows. Autorisez Vibe Walkie dans le Gestionnaire des tâches, Applications de démarrage.");
    }
}
