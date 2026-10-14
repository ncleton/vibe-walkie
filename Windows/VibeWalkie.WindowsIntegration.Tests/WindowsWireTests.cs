using System.Buffers.Binary;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Runtime.InteropServices;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using VibeWalkie.Companion.Network;
using VibeWalkie.Companion.Security;
using VibeWalkie.Protocol;
using Xunit;

namespace VibeWalkie.WindowsIntegration.Tests;

// These exercise the production Windows backend over real TLS/socket frames.
// The protocol client is a test program; it is not evidence of iPhone/LAN QA.
public sealed class WindowsWireTests
{
    [Fact]
    public async Task RealTlsPairingConfigurationRetryReconnectAndRevocation()
    {
        await using var host = await NativeHost.StartAsync();
        var identity = new ClientIdentity();
        var presentation = host.Authority.BeginPairing();
        await using var client = await WireClient.OpenAsync(host.Certificate, identity);
        await client.AuthenticateAsync(host, presentation);
        Assert.NotNull(host.Peers.Find(identity.ID));
        Assert.NotEmpty(File.ReadAllBytes(host.PeerPath)); // Real per-user DPAPI storage.

        var request = client.Envelope(RemoteMessageType.ControlConfigurationRequest, new EmptyPayload());
        await client.SendAsync(request);
        var snapshot = await client.ReplyAsync(request.MessageID, RemoteMessageType.ControlConfigurationSnapshot);
        var original = snapshot.DecodePayload<ControlConfigurationPayload>().Configuration;
        Assert.Equal(7, original.Buttons.Count);
        var updated = original with
        {
            Buttons = original.Buttons.Select(button => button with { Title = "Essai Windows" }).ToArray(),
            GlobalButtons = original.GlobalButtons.Reverse().ToArray(), Revision = original.Revision + 1
        };
        var update = client.Envelope(RemoteMessageType.ControlConfigurationUpdate, new ControlConfigurationPayload(updated));
        await client.SendAsync(update);
        var first = await client.ReplyAsync(update.MessageID, RemoteMessageType.ControlConfigurationSnapshot);
        var actual = first.DecodePayload<ControlConfigurationPayload>().Configuration;
        Assert.Equal(updated.Revision, actual.Revision);
        Assert.All(actual.Buttons, button => Assert.Equal("Essai Windows", button.Title));
        Assert.Equal(updated.GlobalButtons.Select(button => button.ID), actual.GlobalButtons.Select(button => button.ID));
        await client.SendAsync(update);
        var duplicate = await client.ReplyAsync(update.MessageID, RemoteMessageType.ControlConfigurationSnapshot);
        Assert.Equal(first.Payload, duplicate.Payload);
        await client.CloseAsync();
        await Task.Delay(500, TestContext.Current.CancellationToken);

        await using var reconnected = await WireClient.OpenAsync(host.Certificate, identity);
        await reconnected.AuthenticateAsync(host, null);
        // The same command ID after a fresh TLS handshake must not execute twice.
        var retry = reconnected.Envelope(RemoteMessageType.ControlConfigurationUpdate,
            new ControlConfigurationPayload(updated)) with { MessageID = update.MessageID };
        await reconnected.SendAsync(retry);
        var cached = await reconnected.ReplyAsync(retry.MessageID, RemoteMessageType.ControlConfigurationSnapshot);
        Assert.Equal(first.Payload, cached.Payload);
        Assert.Equal(actual.Revision, host.Server.Configuration.Revision);
        host.Peers.Revoke(identity.ID);
        await reconnected.SendAsync(reconnected.Envelope(RemoteMessageType.ListWindows, new ListWindowsPayload(false)));
        Assert.Equal(RemoteErrorCode.PeerRevoked, (await reconnected.ReadAsync()).DecodePayload<RemoteErrorPayload>().Code);
        Assert.Empty(host.Peers.Active);
    }

    [Fact]
    public async Task RealTlsDeniesUnapprovedAndInvalidlySignedClients()
    {
        await using var host = await NativeHost.StartAsync();
        await using var unsigned = await WireClient.OpenAsync(host.Certificate, new ClientIdentity());
        Assert.False(unsigned.Challenge.RequiresPairingSecret);
        await unsigned.SendAuthenticationAsync(null, corruptSignature: false);
        Assert.Equal(RemoteErrorCode.NotPaired, (await unsigned.ReadAsync()).DecodePayload<RemoteErrorPayload>().Code);

        var presentation = host.Authority.BeginPairing();
        await using var invalid = await WireClient.OpenAsync(host.Certificate, new ClientIdentity());
        await invalid.SendAuthenticationAsync(presentation, corruptSignature: true);
        Assert.Equal(RemoteErrorCode.NotPaired, (await invalid.ReadAsync()).DecodePayload<RemoteErrorPayload>().Code);
        Assert.Empty(host.Peers.Active);
    }

    [Fact]
    public async Task RealTlsEnforcesSessionSequenceAndFrameBounds()
    {
        await using var host = await NativeHost.StartAsync();
        var identity = new ClientIdentity();
        var presentation = host.Authority.BeginPairing();
        await using var client = await WireClient.OpenAsync(host.Certificate, identity);
        await client.AuthenticateAsync(host, presentation);
        var request = client.Envelope(RemoteMessageType.ListWindows, new ListWindowsPayload(false));
        await client.SendAsync(request);
        var windows = (await client.ReplyAsync(request.MessageID, RemoteMessageType.WindowsSnapshot)).DecodePayload<WindowsSnapshotPayload>();
        Assert.All(windows.Applications, application => Assert.Null(application.IconPNG));
        var stale = client.Envelope(RemoteMessageType.ListWindows, new ListWindowsPayload(false)) with { Sequence = request.Sequence };
        await client.SendAsync(stale);
        Assert.Equal(RemoteErrorCode.ReplayDetected, (await client.ReadAsync()).DecodePayload<RemoteErrorPayload>().Code);
        await client.CloseAsync();
        await Task.Delay(500, TestContext.Current.CancellationToken);
        await using var mismatch = await WireClient.OpenAsync(host.Certificate, identity);
        await mismatch.AuthenticateAsync(host, null);
        await mismatch.SendAsync(mismatch.Envelope(RemoteMessageType.ListWindows, new ListWindowsPayload(false)) with { SessionID = "wrong-session" });
        Assert.Equal(RemoteErrorCode.ReplayDetected, (await mismatch.ReadAsync()).DecodePayload<RemoteErrorPayload>().Code);
        await mismatch.CloseAsync();
        await Task.Delay(500, TestContext.Current.CancellationToken);
        await using var oversized = await WireClient.OpenAsync(host.Certificate, new ClientIdentity());
        await oversized.SendOversizedHeaderAsync();
        Assert.Equal(RemoteErrorCode.PayloadTooLarge, (await oversized.ReadAsync()).DecodePayload<RemoteErrorPayload>().Code);
    }

    [Fact]
    public async Task RealTlsAllowsOnlyOneApprovedController()
    {
        await using var host = await NativeHost.StartAsync();
        var firstPairing = host.Authority.BeginPairing();
        await using var first = await WireClient.OpenAsync(host.Certificate, new ClientIdentity());
        await first.AuthenticateAsync(host, firstPairing);
        var secondPairing = host.Authority.BeginPairing();
        await using var second = await WireClient.OpenAsync(host.Certificate, new ClientIdentity());
        await second.SendAuthenticationAsync(secondPairing, false);
        Assert.Equal(RemoteMessageType.PairingPending, (await second.ReadAsync()).Type);
        host.Authority.ResolvePending(true);
        Assert.Equal(RemoteErrorCode.InputUnavailable, (await second.ReadAsync()).DecodePayload<RemoteErrorPayload>().Code);
        var drag = first.Envelope(RemoteMessageType.PointerDrag, new PointerDragPayload(DragPhase.Began, 0, 0));
        await first.SendAsync(drag);
        Assert.True((await first.ReplyAsync(drag.MessageID, RemoteMessageType.Acknowledgement)).DecodePayload<AcknowledgementPayload>().Ok);
        for (var attempt = 0; attempt < 40 && (GetAsyncKeyState(1) & 0x8000) == 0; attempt++)
            await Task.Delay(25, TestContext.Current.CancellationToken);
        Assert.NotEqual(0, GetAsyncKeyState(1) & 0x8000);
        await first.CloseAsync();
        for (var attempt = 0; attempt < 80 && (GetAsyncKeyState(1) & 0x8000) != 0; attempt++)
            await Task.Delay(25, TestContext.Current.CancellationToken);
        Assert.Equal(0, GetAsyncKeyState(1) & 0x8000);
    }

    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);

    private sealed class NativeHost : IAsyncDisposable
    {
        private readonly string _directory = Path.Combine(Path.GetTempPath(), "VibeWalkieWire-" + Guid.NewGuid().ToString("N"));
        private readonly string _configurationPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VibeWalkie", "configuration.dpapi");
        private readonly byte[]? _configurationBackup;
        public string PeerPath { get; }
        public ApprovedPeerStore Peers { get; }
        public X509Certificate2 Certificate { get; }
        public PairingAuthority Authority { get; }
        public VibeServer Server { get; }
        private NativeHost()
        {
            Directory.CreateDirectory(_directory);
            _configurationBackup = File.Exists(_configurationPath) ? File.ReadAllBytes(_configurationPath) : null;
            PeerPath = Path.Combine(_directory, "approved-peers.dpapi");
            Peers = new ApprovedPeerStore(PeerPath);
            Certificate = new CertificateIdentity().LoadOrCreate();
            Authority = new PairingAuthority(Peers, CertificateIdentity.Fingerprint(Certificate), () => null);
            Server = new VibeServer(Certificate, Authority, () => null);
        }
        public static async Task<NativeHost> StartAsync()
        {
            var host = new NativeHost();
            try { await host.Server.StartAsync(); return host; }
            catch { await host.DisposeAsync(); throw; }
        }
        public async ValueTask DisposeAsync()
        {
            await Server.DisposeAsync(); Certificate.Dispose();
            if (_configurationBackup is null)
            {
                if (File.Exists(_configurationPath)) File.Delete(_configurationPath);
            }
            else File.WriteAllBytes(_configurationPath, _configurationBackup);
            Directory.Delete(_directory, true);
        }
    }
    private sealed class ClientIdentity
    {
        public string ID { get; } = Guid.NewGuid().ToString("N");
        private readonly Ed25519PrivateKeyParameters _key = new(RandomNumberGenerator.GetBytes(32));
        public byte[] PublicKey => _key.GeneratePublicKey().GetEncoded();
        public byte[] Sign(byte[] message)
        {
            var signer = new Ed25519Signer(); signer.Init(true, _key);
            signer.BlockUpdate(message, 0, message.Length); return signer.GenerateSignature();
        }
    }
    private sealed class WireClient : IAsyncDisposable
    {
        private readonly TcpClient _tcp = new();
        private readonly ClientIdentity _identity;
        private SslStream _tls = null!;
        private string _session = "";
        private ulong _sequence;
        private bool _closed;
        public PairingChallengePayload Challenge { get; private set; } = null!;
        private WireClient(ClientIdentity identity) => _identity = identity;
        public static async Task<WireClient> OpenAsync(X509Certificate2 certificate, ClientIdentity identity)
        {
            var client = new WireClient(identity);
            try
            {
                await client._tcp.ConnectAsync("127.0.0.1", VibeWalkieInfo.ControlPort, TestContext.Current.CancellationToken);
                var fingerprint = SHA256.HashData(certificate.RawData);
                client._tls = new SslStream(client._tcp.GetStream(), false, (_, remote, _, _) => remote is not null
                    && CryptographicOperations.FixedTimeEquals(fingerprint, SHA256.HashData(remote.GetRawCertData())));
                await client._tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = "localhost", EnabledSslProtocols = SslProtocols.Tls13 }, TestContext.Current.CancellationToken);
                var challenge = await client.ReadAsync(); Assert.Equal(RemoteMessageType.PairingChallenge, challenge.Type);
                client._session = challenge.SessionID; client.Challenge = challenge.DecodePayload<PairingChallengePayload>();
                return client;
            }
            catch { await client.DisposeAsync(); throw; }
        }
        public RemoteEnvelope Envelope<T>(RemoteMessageType type, T payload) => RemoteEnvelope.Create(type, _session, ++_sequence, payload);
        public async Task SendAuthenticationAsync(PairingPresentation? pairing, bool corruptSignature)
        {
            var secret = pairing is null ? null : Convert.FromBase64String(pairing.Payload.PairingSecret);
            var signed = Challenge.Nonce.Concat(Encoding.UTF8.GetBytes(_identity.ID)).Concat(secret ?? []).ToArray();
            var signature = _identity.Sign(signed); if (corruptSignature) signature[0] ^= 0xFF;
            await SendAsync(Envelope(RemoteMessageType.PairingResponse, new PairingResponsePayload(_identity.ID,
                "Windows native integration client", _identity.PublicKey, signature, secret, ClientPlatform.IOS)));
        }
        public async Task AuthenticateAsync(NativeHost host, PairingPresentation? presentation)
        {
            await SendAuthenticationAsync(presentation, false);
            var response = await ReadAsync();
            if (presentation is not null)
            {
                Assert.Equal(RemoteMessageType.PairingPending, response.Type);
                Assert.Equal(presentation.ConfirmationCode, response.DecodePayload<PairingPendingPayload>().ConfirmationCode);
                host.Authority.ResolvePending(true); response = await ReadAsync();
            }
            Assert.Equal(RemoteMessageType.ConnectionStatus, response.Type);
            Assert.Equal(HostPlatform.Windows, response.DecodePayload<ConnectionStatusPayload>().HostPlatform);
        }
        public async Task SendAsync(RemoteEnvelope envelope)
        {
            await _tls.WriteAsync(MessageFramer.Frame(envelope), TestContext.Current.CancellationToken);
            await _tls.FlushAsync(TestContext.Current.CancellationToken);
        }
        public async Task SendOversizedHeaderAsync()
        {
            var header = new byte[4]; BinaryPrimitives.WriteInt32BigEndian(header, ProtocolLimits.MaxFrameBytes + 1);
            await _tls.WriteAsync(header, TestContext.Current.CancellationToken); await _tls.FlushAsync(TestContext.Current.CancellationToken);
        }
        public async Task<RemoteEnvelope> ReadAsync()
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(15));
            var header = new byte[4]; await _tls.ReadExactlyAsync(header, timeout.Token);
            var body = new byte[MessageFramer.ReadLength(header)]; await _tls.ReadExactlyAsync(body, timeout.Token);
            return CanonicalJson.Deserialize<RemoteEnvelope>(body);
        }
        public async Task<RemoteEnvelope> ReplyAsync(Guid id, RemoteMessageType type)
        {
            for (var count = 0; count < 20; count++)
            {
                var message = await ReadAsync();
                if (message.ReplyTo != id) continue;
                Assert.Equal(type, message.Type); return message;
            }
            throw new InvalidDataException("The actual Windows server did not reply to the command.");
        }
        public ValueTask CloseAsync() => DisposeAsync();
        public ValueTask DisposeAsync()
        {
            if (!_closed) { _closed = true; _tls?.Dispose(); _tcp.Dispose(); }
            return ValueTask.CompletedTask;
        }
    }
}
