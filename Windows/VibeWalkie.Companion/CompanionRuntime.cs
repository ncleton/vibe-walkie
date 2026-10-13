using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Security.Principal;
using Microsoft.UI.Dispatching;
using VibeWalkie.Companion.Network;
using VibeWalkie.Companion.Input;
using VibeWalkie.Companion.Screen;
using VibeWalkie.Companion.Security;
using VibeWalkie.Protocol;
using VibeWalkie.Companion.Posture;
using VibeWalkie.Companion.Updates;

namespace VibeWalkie.Companion;

public sealed class CompanionRuntime : IAsyncDisposable
{
    private readonly DispatcherQueue _dispatcher;
    private readonly ApprovedPeerStore _peers = new();
    private readonly DnsSdPublisher _publisher = new();
    private readonly PairingAuthority _authority;
    private readonly VibeServer _server;
    private NomadEndpoint? _nomad;
    private bool _disposed;
    public PostureCoachService Posture { get; }
    public UpdateController Updates { get; } = new();
    public VibeWalkie.Companion.Health.WorkWalkingSessionStore WalkingSessions => _server.WalkingSessions;
    public ControlConfiguration Configuration => _server.Configuration;
    public event Action<ControlConfiguration>? ConfigurationChanged;

    public event Action<string>? StatusChanged;
    public event Action<PairingPresentation>? PairingChanged;
    public event Action<PendingApproval?>? PendingApprovalChanged;
    public event Action<IReadOnlyList<ApprovedPeer>>? ApprovedPeersChanged;
    public event Action<IReadOnlyList<HostShortcutDefinition>>? ShortcutsChanged;

    public CompanionRuntime(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
        var certificate = new CertificateIdentity().LoadOrCreate();
        _authority = new PairingAuthority(_peers, CertificateIdentity.Fingerprint(certificate), () => _nomad);
        _server = new VibeServer(certificate, _authority, () => _nomad);
        Posture = new PostureCoachService(_server.WalkingSessions);
        _server.ConfigurationChanged += value => ConfigurationChanged?.Invoke(value);
        _server.StatusChanged += value => StatusChanged?.Invoke(value);
        _authority.PairingChanged += value => PairingChanged?.Invoke(value);
        _authority.PendingApprovalChanged += value => PendingApprovalChanged?.Invoke(value);
        _authority.PeersChanged += () => ApprovedPeersChanged?.Invoke(_peers.Active);
    }

    public async Task StartAsync()
    {
        _nomad = await TailscaleDetector.DetectAsync();
        await _server.StartAsync();
        try
        {
            _publisher.Start($"VibeWalkie-{Environment.MachineName}", 54_389);
        }
        catch (Exception error)
        {
            LocalDiagnostics.Record("dns_sd_publish", error);
            StatusChanged?.Invoke("Serveur prêt, mais publication réseau à réparer");
        }
        ApprovedPeersChanged?.Invoke(_peers.Active);
        ShortcutsChanged?.Invoke(_server.Shortcuts);
        ConfigurationChanged?.Invoke(Configuration);
        BeginPairing();
    }

    public void UpdateConfiguration(ControlConfiguration configuration) => _server.UpdateConfiguration(configuration);
    public void BeginPairing() => _authority.BeginPairing();
    public void ResolvePendingApproval(bool approved) => _authority.ResolvePending(approved);
    public void RevokePeer(string id)
    {
        _peers.Revoke(id);
        ApprovedPeersChanged?.Invoke(_peers.Active);
        StatusChanged?.Invoke("Téléphone révoqué");
    }
    public void UpsertShortcut(HostShortcutDefinition shortcut)
    {
        _server.UpsertShortcut(shortcut);
        ShortcutsChanged?.Invoke(_server.Shortcuts);
    }
    public void RemoveShortcut(string id)
    {
        _server.RemoveShortcut(id);
        ShortcutsChanged?.Invoke(_server.Shortcuts);
    }

    public async Task<string> RunDiagnosticsAsync()
    {
        _nomad = await TailscaleDetector.DetectAsync();
        var elevated = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
        await using var screen = new ScreenCaptureService();
        var listening = _server.IsListening;
        var published = _publisher.IsPublished;
        var inputReady = _server.InputControlReady;
        var screenReady = screen.IsAvailable;
        var lines = new[]
        {
            $"TLS : {(listening ? "écoute sur 54389" : "indisponible — relancez le compagnon")}",
            $"DNS-SD : {(published ? "publié" : "en attente — autorisez Vibe Walkie sur les réseaux privés dans le pare-feu Windows, puis relancez le compagnon")}",
            $"Saisie : {(inputReady ? "session utilisateur prête" : "indisponible — déverrouillez Windows et quittez le bureau sécurisé")}",
            $"Capture : {(screenReady ? "disponible" : "indisponible — déverrouillez Windows ou fermez le contenu protégé")}",
            $"Tailscale : {(_nomad is null ? "non détecté — installez/ouvrez Tailscale si vous voulez une connexion hors LAN" : _nomad.MagicDNSName)}",
            "UAC, écran verrouillé et applications administrateur restent volontairement hors périmètre.",
        };
        if (elevated) lines = [.. lines, "Ce compagnon est élevé : relancez-le comme utilisateur standard pour le comportement de production."];
        return string.Join(Environment.NewLine, lines);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        await Posture.DisposeAsync();
        _publisher.Dispose();
        await _server.DisposeAsync();
    }
}
