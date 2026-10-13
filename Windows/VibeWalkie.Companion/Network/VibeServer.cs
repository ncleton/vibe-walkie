using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using VibeWalkie.Companion.Input;
using VibeWalkie.Companion.Screen;
using VibeWalkie.Companion.Security;
using VibeWalkie.Companion.Windows;
using VibeWalkie.Protocol;
using VibeWalkie.Companion.Health;

namespace VibeWalkie.Companion.Network;

public sealed class VibeServer : IAsyncDisposable
{
    private readonly X509Certificate2 _certificate;
    private readonly PairingAuthority _authority;
    private readonly Func<NomadEndpoint?> _nomadEndpoint;
    private readonly InputService _input = new();
    private readonly SemaphoreSlim _controller = new(1, 1);
    public WorkWalkingSessionStore WalkingSessions { get; } = new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VibeWalkie", "work-walking-sessions.json"));
    private readonly WindowCatalog _windows = new();
    private readonly HostShortcutStore _shortcuts = new();
    private readonly RecentMessageCache<RouteResponse> _recentResponses = new();
    private readonly UnauthenticatedSessionGate _unauthenticatedSessions = new(maximumSessions: 8);
    private readonly ConfigurationStore _configuration;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly HashSet<Task> _clients = [];
    private readonly Dictionary<Guid, Func<Task>> _configurationSubscribers = [];
    private TcpListener? _listener;

    public ControlConfiguration Configuration => _configuration.Current;
    public event Action<ControlConfiguration>? ConfigurationChanged;
    public void UpdateConfiguration(ControlConfiguration configuration) { _configuration.Update(configuration); _ = BroadcastConfigurationAsync(); }
    public bool IsListening => _listener is not null;
    public bool InputControlReady => _input.IsAvailable;
    public IReadOnlyList<HostShortcutDefinition> Shortcuts => _shortcuts.Definitions;

    public void UpsertShortcut(HostShortcutDefinition shortcut)
    {
        _shortcuts.Upsert(shortcut);
        _ = BroadcastConfigurationAsync();
    }
    public void RemoveShortcut(string id)
    {
        _shortcuts.Remove(id);
        _ = BroadcastConfigurationAsync();
    }
    public event Action<string>? StatusChanged;

    public VibeServer(X509Certificate2 certificate, PairingAuthority authority, Func<NomadEndpoint?> nomadEndpoint)
    {
        _certificate = certificate;
        _authority = authority;
        _nomadEndpoint = nomadEndpoint;
        _configuration = new ConfigurationStore(_shortcuts);
    }

    public Task StartAsync()
    {
        if (_listener is not null) return Task.CompletedTask;
        _listener = new TcpListener(IPAddress.IPv6Any, 54_389);
        _listener.Server.DualMode = true;
        _listener.Start(16);
        _ = Task.Run(AcceptLoopAsync);
        StatusChanged?.Invoke("Prêt sur le port 54389");
        return Task.CompletedTask;
    }

    private async Task AcceptLoopAsync()
    {
        while (!_lifetime.IsCancellationRequested)
        {
            try
            {
                var client = await _listener!.AcceptTcpClientAsync(_lifetime.Token);
                if (!_unauthenticatedSessions.TryEnter())
                {
                    client.Dispose();
                    LocalDiagnostics.Record("unauthenticated_session_limit");
                    continue;
                }
                var task = HandleClientAsync(client, _lifetime.Token);
                lock (_clients) _clients.Add(task);
                _ = task.ContinueWith(completed => { lock (_clients) _clients.Remove(completed); }, TaskScheduler.Default);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception error)
            {
                LocalDiagnostics.Record("listener_accept", error);
                await Task.Delay(250, _lifetime.Token);
            }
        }
    }

    private async Task HandleClientAsync(TcpClient tcpClient, CancellationToken cancellationToken)
    {
        using var client = tcpClient;
        using var tls = new SslStream(client.GetStream(), leaveInnerStreamOpen: false);
        client.NoDelay = true;
        var unauthenticatedSlotHeld = true;
        var controllerHeld = false;
        try
        {
            using var handshakeTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            handshakeTimeout.CancelAfter(TimeSpan.FromSeconds(UnauthenticatedSessionGate.InitialHandshakeTimeoutSeconds));
            var handshakeToken = handshakeTimeout.Token;
            await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = _certificate,
                EnabledSslProtocols = SslProtocols.Tls13,
                ClientCertificateRequired = false,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
            }, handshakeToken);

            var sessionID = Guid.NewGuid().ToString();
            ulong sequence = 0;
            var sendLock = new SemaphoreSlim(1, 1);
            var guard = new ReplayGuard();
            var nonce = RandomNumberGenerator.GetBytes(32);
            var requiresSecret = _authority.IsPairingOpen;

            async Task SendAsync(RemoteMessageType type, object payload, Guid? replyTo = null, CancellationToken? operationToken = null)
            {
                using var writeTimeout = CancellationTokenSource.CreateLinkedTokenSource(operationToken ?? cancellationToken);
                writeTimeout.CancelAfter(ProtocolLimits.AcknowledgementTimeout);
                var token = writeTimeout.Token;
                byte[] body = payload is byte[] bytes ? bytes : CanonicalJson.SerializeToUtf8Bytes(payload);
                await sendLock.WaitAsync(token);
                try
                {
                    sequence++;
                    var envelope = new RemoteEnvelope(
                        ProtocolVersion.Current, type, Guid.NewGuid(), replyTo, sessionID, sequence,
                        DateTimeOffset.UtcNow, body);
                    await tls.WriteAsync(MessageFramer.Frame(envelope), token);
                    await tls.FlushAsync(token);
                }
                finally { sendLock.Release(); }
            }

            await SendAsync(RemoteMessageType.PairingChallenge, new PairingChallengePayload(nonce, requiresSecret), operationToken: handshakeToken);
            var responseEnvelope = await ReadEnvelopeAsync(tls, handshakeToken);
            guard.Accept(responseEnvelope);
            if (responseEnvelope.Type != RemoteMessageType.PairingResponse) throw new ProtocolException(RemoteErrorCode.NotPaired);
            PairingResponsePayload response;
            try { response = responseEnvelope.DecodePayload<PairingResponsePayload>(); }
            catch (JsonException) { throw new ProtocolException(RemoteErrorCode.ProtocolMismatch); }
            if (response.ClientPlatform is not (ClientPlatform.IOS or ClientPlatform.Android))
                throw new ProtocolException(RemoteErrorCode.NotPaired);

            var peer = await _authority.AuthenticateAsync(
                response,
                nonce,
                requiresSecret,
                pending => SendAsync(
                    RemoteMessageType.PairingPending,
                    new PairingPendingPayload(Guid.NewGuid(), pending.DeviceName, pending.ConfirmationCode, pending.ExpiresAt),
                    responseEnvelope.MessageID),
                cancellationToken);

            _unauthenticatedSessions.Exit();
            unauthenticatedSlotHeld = false;

            controllerHeld = await _controller.WaitAsync(0, cancellationToken);
            if (!controllerHeld) throw new ProtocolException(RemoteErrorCode.InputUnavailable);
            await using var screen = new ScreenCaptureService();
            screen.Failed += error => _ = SendAsync(RemoteMessageType.Error, new RemoteErrorPayload(error.Code));
            var router = new SessionRouter(
                _input,
                _windows,
                screen,
                _shortcuts,
                _configuration,
                _recentResponses,
                peer.ID,
                WalkingSessions,
                () => _ = BroadcastConfigurationAsync());
            var subscriberID = Guid.NewGuid();
            lock (_configurationSubscribers)
            {
                _configurationSubscribers[subscriberID] = () => SendAsync(
                    RemoteMessageType.ControlConfigurationSnapshot,
                    new ControlConfigurationPayload(_configuration.Current));
            }
            try
            {
                await SendAsync(RemoteMessageType.ConnectionStatus, new ConnectionStatusPayload(
                    InputControlReady,
                    screen.IsAvailable,
                    Environment.MachineName,
                    HostPlatform.Windows,
                    Enum.GetValues<HostCapability>().Where(capability => (capability != HostCapability.Tailscale || _nomadEndpoint() is not null)).ToArray(),
                    typeof(VibeServer).Assembly.GetName().Version?.ToString() ?? "1.0.0",
                    _nomadEndpoint()));
                while (!cancellationToken.IsCancellationRequested)
                {
                    using var readTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    readTimeout.CancelAfter(TimeSpan.FromSeconds(90));
                    var request = await ReadEnvelopeAsync(tls, readTimeout.Token);
                    if (_authority.IsRevoked(peer.ID)) throw new ProtocolException(RemoteErrorCode.PeerRevoked);
                    if (request.SessionID != responseEnvelope.SessionID) throw new ProtocolException(RemoteErrorCode.ReplayDetected);
                    // A duplicate is not a hostile replay: the router owns
                    // the per-session response cache and must see it to
                    // resend the original acknowledgement without executing
                    // the command again. Unknown stale sequences still throw
                    // from ReplayGuard and close the session.
                    _ = guard.Accept(request);
                    var result = await router.RouteAsync(request, frame =>
                    {
                        if (_authority.IsRevoked(peer.ID)) throw new ProtocolException(RemoteErrorCode.PeerRevoked);
                        return new ValueTask(SendAsync(RemoteMessageType.ScreenFrame, frame));
                    });
                    await SendAsync(result.Type, result.Payload, request.MessageID);
                }
            }
            finally
            {
                lock (_configurationSubscribers) _configurationSubscribers.Remove(subscriberID);
                router.Close();
            }
        }
        catch (ProtocolException error)
        {
            try
            {
                var envelope = new RemoteEnvelope(
                    ProtocolVersion.Current, RemoteMessageType.Error, Guid.NewGuid(), null, Guid.NewGuid().ToString(), 1,
                    DateTimeOffset.UtcNow, CanonicalJson.SerializeToUtf8Bytes(new RemoteErrorPayload(error.Code)));
                await tls.WriteAsync(MessageFramer.Frame(envelope), cancellationToken);
                await tls.FlushAsync(cancellationToken);
            }
            catch { }
        }
        catch (Exception error) when (error is IOException or AuthenticationException or SocketException or OperationCanceledException)
        {
            LocalDiagnostics.Record("session_closed", error);
        }
        catch (Exception error)
        {
            LocalDiagnostics.Record("session_failed", error);
            try
            {
                var envelope = new RemoteEnvelope(
                    ProtocolVersion.Current, RemoteMessageType.Error, Guid.NewGuid(), null, Guid.NewGuid().ToString(), 1,
                    DateTimeOffset.UtcNow, CanonicalJson.SerializeToUtf8Bytes(new RemoteErrorPayload(RemoteErrorCode.InternalFailure)));
                await tls.WriteAsync(MessageFramer.Frame(envelope), cancellationToken);
                await tls.FlushAsync(cancellationToken);
            }
            catch { }
        }
        finally
        {
            if (controllerHeld) { _input.ReleaseInputs(); _controller.Release(); }
            if (unauthenticatedSlotHeld) _unauthenticatedSessions.Exit();
        }
    }

    private static async Task<RemoteEnvelope> ReadEnvelopeAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[sizeof(int)];
        await stream.ReadExactlyAsync(header, cancellationToken);
        var length = MessageFramer.ReadLength(header);
        var body = new byte[length];
        await stream.ReadExactlyAsync(body, cancellationToken);
        try { return CanonicalJson.Deserialize<RemoteEnvelope>(body); }
        catch (JsonException) { throw new ProtocolException(RemoteErrorCode.ProtocolMismatch); }
    }

    private async Task BroadcastConfigurationAsync()
    {
        ConfigurationChanged?.Invoke(_configuration.Current);
        Func<Task>[] subscribers;
        lock (_configurationSubscribers) subscribers = _configurationSubscribers.Values.ToArray();
        foreach (var publish in subscribers)
        {
            try { await publish(); }
            catch (Exception error) { LocalDiagnostics.Record("configuration_sync", error); }
        }
    }

    public async ValueTask DisposeAsync()
    {
        _lifetime.Cancel();
        _listener?.Stop();
        _listener = null;
        Task[] clients;
        lock (_clients) clients = _clients.ToArray();
        try { await Task.WhenAll(clients).WaitAsync(TimeSpan.FromSeconds(2)); } catch { }
        _lifetime.Dispose();
    }
}
