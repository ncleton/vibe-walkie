using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Security;

public sealed record ApprovedPeer(
    string ID,
    string DeviceName,
    byte[] PublicKey,
    ClientPlatform ClientPlatform,
    DateTimeOffset PairedAt,
    DateTimeOffset? LastSeenAt = null,
    bool IsRevoked = false);

public interface IApprovedPeerRegistry
{
    ApprovedPeer? Find(string id);
    void Approve(ApprovedPeer peer);
    void Seen(string id);
}
