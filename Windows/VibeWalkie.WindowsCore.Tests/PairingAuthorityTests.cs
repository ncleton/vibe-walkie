using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using VibeWalkie.Companion.Security;
using VibeWalkie.Companion.Network;
using VibeWalkie.Companion.Input;
using VibeWalkie.Protocol;
using Xunit;

namespace VibeWalkie.WindowsCore.Tests;

public sealed class PairingAuthorityTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "VibeWalkie.Tests", Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task SecondConcurrentApprovalIsRateLimitedAndCannotReplaceTheVisibleRequest()
    {
        var store = new InMemoryPeerStore();
        var authority = new PairingAuthority(store, "fixture-certificate", static () => null);
        var pairing = authority.BeginPairing();
        var nonce = RandomNumberGenerator.GetBytes(32);
        var firstVisible = new TaskCompletionSource<PendingApproval>(TaskCreationOptions.RunContinuationsAsynchronously);

        var first = authority.AuthenticateAsync(
            SignedResponse("phone-one", pairing, nonce),
            nonce,
            requiresPairingSecret: true,
            pending =>
            {
                firstVisible.TrySetResult(pending);
                return Task.CompletedTask;
            },
            TestContext.Current.CancellationToken);
        var pending = await firstVisible.Task.WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);

        var second = await Assert.ThrowsAsync<ProtocolException>(() => authority.AuthenticateAsync(
            SignedResponse("phone-two", pairing, nonce),
            nonce,
            requiresPairingSecret: true,
            pendingObserver: null,
            TestContext.Current.CancellationToken));
        Assert.Equal(RemoteErrorCode.RateLimited, second.Code);
        Assert.Equal("phone-one", pending.DeviceIdentifier);

        authority.ResolvePending(approved: false);
        var denied = await Assert.ThrowsAsync<ProtocolException>(() => first);
        Assert.Equal(RemoteErrorCode.PairingDenied, denied.Code);
    }

    [Fact]
    public async Task MalformedPairingIdentityIsRejectedBeforeAuthentication()
    {
        var authority = new PairingAuthority(new InMemoryPeerStore(), "fixture-certificate", static () => null);
        var response = new PairingResponsePayload("phone", "Vibe phone", null!, null!, null, ClientPlatform.Android);

        var error = await Assert.ThrowsAsync<ProtocolException>(() => authority.AuthenticateAsync(
            response,
            RandomNumberGenerator.GetBytes(32),
            requiresPairingSecret: false,
            pendingObserver: null,
            TestContext.Current.CancellationToken));
        Assert.Equal(RemoteErrorCode.ProtocolMismatch, error.Code);
    }

    private static PairingResponsePayload SignedResponse(string identifier, PairingPresentation pairing, byte[] nonce)
    {
        var privateKey = new Ed25519PrivateKeyParameters(RandomNumberGenerator.GetBytes(32));
        var publicKey = privateKey.GeneratePublicKey().GetEncoded();
        var secret = Convert.FromBase64String(pairing.Payload.PairingSecret);
        var message = nonce.Concat(Encoding.UTF8.GetBytes(identifier)).Concat(secret).ToArray();
        var signer = new Ed25519Signer();
        signer.Init(true, privateKey);
        signer.BlockUpdate(message, 0, message.Length);
        return new PairingResponsePayload(
            identifier,
            "Vibe phone",
            publicKey,
            signer.GenerateSignature(),
            secret,
            ClientPlatform.Android);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    private sealed class InMemoryPeerStore : IApprovedPeerRegistry
    {
        private readonly Dictionary<string, ApprovedPeer> _peers = [];

        public ApprovedPeer? Find(string id) => _peers.GetValueOrDefault(id) is { IsRevoked: false } peer ? peer : null;
        public void Approve(ApprovedPeer peer) => _peers[peer.ID] = peer;
        public void Seen(string id)
        {
            if (_peers.TryGetValue(id, out var peer)) _peers[id] = peer with { LastSeenAt = DateTimeOffset.UtcNow };
        }
    }
}

public sealed class UnauthenticatedSessionGateTests
{
    [Fact]
    public void ItCapsUnauthenticatedSessionsWithoutBlockingReleasedSlots()
    {
        var gate = new UnauthenticatedSessionGate(maximumSessions: 8);

        Assert.Equal(10, UnauthenticatedSessionGate.InitialHandshakeTimeoutSeconds);
        Assert.All(Enumerable.Range(0, 8), _ => Assert.True(gate.TryEnter()));
        Assert.False(gate.TryEnter());

        gate.Exit();
        Assert.True(gate.TryEnter());
    }
}

public sealed class InputControlPolicyTests
{
    [Fact]
    public void SharedTargetTokenLifetimeIsExactlyTwoMinutes()
    {
        Assert.Equal(TimeSpan.FromSeconds(120), VibeWalkieInfo.TargetTokenLifetime);
    }

    [Fact]
    public void GestureAndScreenSettingsAreBounded()
    {
        Assert.Equal(-600, InputControlPolicy.GestureDelta(-9_000));
        Assert.Equal(600, InputControlPolicy.GestureDelta(9_000));
        Assert.Equal(0, InputControlPolicy.NormalizedCoordinate(-3));
        Assert.Equal(1, InputControlPolicy.NormalizedCoordinate(3));
        Assert.Equal(1, InputControlPolicy.KeyRepeatCount(null));
        Assert.Equal(1, InputControlPolicy.KeyRepeatCount(-4));
        Assert.Equal(12, InputControlPolicy.KeyRepeatCount(12));
        Assert.Equal(32, InputControlPolicy.KeyRepeatCount(99));

        var request = InputControlPolicy.ScreenRequest(new ScreenStreamRequestPayload(true, 9_000, 200, .99));
        Assert.Equal(1_920, request.MaxWidth);
        Assert.Equal(20, request.FramesPerSecond);
        Assert.Equal(.8, request.JpegQuality);
    }

    [Fact]
    public void NonFiniteControlValuesAreRejectedBeforeInput()
    {
        var gesture = Assert.Throws<ProtocolException>(() => InputControlPolicy.GestureDelta(double.NaN));
        Assert.Equal(RemoteErrorCode.ProtocolMismatch, gesture.Code);
        var quality = Assert.Throws<ProtocolException>(() => InputControlPolicy.ScreenRequest(new ScreenStreamRequestPayload(true, JpegQuality: double.PositiveInfinity)));
        Assert.Equal(RemoteErrorCode.ProtocolMismatch, quality.Code);
    }
}
