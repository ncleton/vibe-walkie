using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using QRCoder;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Security;

public sealed record PairingPresentation(PairingQrPayload Payload, string EncodedPayload, string ConfirmationCode, byte[] QrPng);
public sealed record PendingApproval(string DeviceIdentifier, string DeviceName, string ConfirmationCode, DateTimeOffset ExpiresAt);

public sealed class PairingAuthority
{
    private readonly IApprovedPeerRegistry _peers;
    private readonly string _certificateFingerprint;
    private readonly Func<NomadEndpoint?> _nomadEndpoint;
    private readonly object _lock = new();
    private PairingPresentation? _activePairing;
    private PendingApproval? _pending;
    private TaskCompletionSource<bool>? _pendingDecision;

    public event Action<PairingPresentation>? PairingChanged;
    public event Action<PendingApproval?>? PendingApprovalChanged;
    public event Action? PeersChanged;
    public bool IsRevoked(string peerID) => _peers.Find(peerID) is null;
    public bool IsPairingOpen { get { lock (_lock) return _activePairing is { Payload.IsExpired: false }; } }

    public PairingAuthority(IApprovedPeerRegistry peers, string certificateFingerprint, Func<NomadEndpoint?> nomadEndpoint)
    {
        _peers = peers;
        _certificateFingerprint = certificateFingerprint;
        _nomadEndpoint = nomadEndpoint;
    }

    public PairingPresentation BeginPairing()
    {
        var secret = RandomNumberGenerator.GetBytes(16);
        var payload = new PairingQrPayload(
            ProtocolVersion.Current,
            Environment.MachineName,
            HostPlatform.Windows,
            $"VibeWalkie-{Environment.MachineName}",
            _certificateFingerprint,
            Convert.ToBase64String(secret),
            DateTimeOffset.UtcNow.AddMinutes(2),
            _nomadEndpoint());
        var json = CanonicalJson.SerializeToUtf8Bytes(payload);
        var encoded = Convert.ToBase64String(json);
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(encoded, QRCodeGenerator.ECCLevel.M);
        var qr = new PngByteQRCode(data).GetGraphic(8, drawQuietZones: true);
        var presentation = new PairingPresentation(payload, encoded, payload.ConfirmationCode, qr);
        lock (_lock) _activePairing = presentation;
        PairingChanged?.Invoke(presentation);
        return presentation;
    }

    public async Task<ApprovedPeer> AuthenticateAsync(
        PairingResponsePayload response,
        ReadOnlyMemory<byte> nonce,
        bool requiresPairingSecret,
        Func<PendingApproval, Task>? pendingObserver,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(response.DeviceIdentifier) || response.DeviceIdentifier.Length > 128
            || string.IsNullOrWhiteSpace(response.DeviceName) || response.DeviceName.Length > 80
            || response.PublicKey is null || response.Signature is null)
            throw new ProtocolException(RemoteErrorCode.ProtocolMismatch);

        var known = _peers.Find(response.DeviceIdentifier);
        byte[]? expectedSecret = null;
        PairingPresentation? pairing;
        lock (_lock) pairing = _activePairing;

        if (known is null)
        {
            if (!requiresPairingSecret || pairing is null || pairing.Payload.IsExpired)
                throw new ProtocolException(RemoteErrorCode.NotPaired);
            expectedSecret = Convert.FromBase64String(pairing.Payload.PairingSecret);
            if (response.PairingSecret is null || response.PairingSecret.Length != expectedSecret.Length
                || !CryptographicOperations.FixedTimeEquals(response.PairingSecret, expectedSecret))
                throw new ProtocolException(RemoteErrorCode.NotPaired);
        }
        else if (!CryptographicOperations.FixedTimeEquals(known.PublicKey, response.PublicKey))
        {
            throw new ProtocolException(RemoteErrorCode.PeerRevoked);
        }

        var signedMessage = nonce.ToArray()
            .Concat(Encoding.UTF8.GetBytes(response.DeviceIdentifier))
            .Concat(expectedSecret ?? Array.Empty<byte>())
            .ToArray();
        if (!VerifyEd25519(response.PublicKey, signedMessage, response.Signature))
            throw new ProtocolException(RemoteErrorCode.NotPaired, "Signature Ed25519 invalide");

        if (known is not null)
        {
            _peers.Seen(known.ID);
            return known;
        }

        var pending = new PendingApproval(
            response.DeviceIdentifier,
            response.DeviceName,
            pairing!.ConfirmationCode,
            DateTimeOffset.UtcNow.AddMinutes(1));
        var decision = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_lock)
        {
            // One visible confirmation maps to exactly one cryptographic
            // challenge. Replacing it would let a later request receive the
            // user's decision for an unrelated phone.
            if (_pending is not null) throw new ProtocolException(RemoteErrorCode.RateLimited, "Approbation déjà en attente");
            _pending = pending;
            _pendingDecision = decision;
        }
        PendingApprovalChanged?.Invoke(pending);
        if (pendingObserver is not null) await pendingObserver(pending);

        bool approved;
        try { approved = await decision.Task.WaitAsync(TimeSpan.FromMinutes(1), cancellationToken); }
        catch (TimeoutException) { throw new ProtocolException(RemoteErrorCode.PairingApprovalExpired); }
        finally
        {
            lock (_lock) { _pending = null; _pendingDecision = null; _activePairing = null; }
            PendingApprovalChanged?.Invoke(null);
        }
        if (!approved) throw new ProtocolException(RemoteErrorCode.PairingDenied);
        if (DateTimeOffset.UtcNow >= pending.ExpiresAt)
            throw new ProtocolException(RemoteErrorCode.PairingApprovalExpired);

        var peer = new ApprovedPeer(
            response.DeviceIdentifier,
            response.DeviceName[..Math.Min(response.DeviceName.Length, 80)],
            response.PublicKey,
            response.ClientPlatform,
            DateTimeOffset.UtcNow,
            DateTimeOffset.UtcNow);
        _peers.Approve(peer);
        PeersChanged?.Invoke();
        return peer;
    }

    public void ResolvePending(bool approved)
    {
        lock (_lock) _pendingDecision?.TrySetResult(approved);
    }

    private static bool VerifyEd25519(byte[] publicKey, byte[] message, byte[] signature)
    {
        if (publicKey.Length != 32 || signature.Length != 64) return false;
        var verifier = new Ed25519Signer();
        verifier.Init(false, new Ed25519PublicKeyParameters(publicKey));
        verifier.BlockUpdate(message, 0, message.Length);
        return verifier.VerifySignature(signature);
    }
}
