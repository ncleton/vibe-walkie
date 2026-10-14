using System.Security.Cryptography;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Security;

public sealed class ApprovedPeerStore : IApprovedPeerRegistry
{
    private readonly object _lock = new();
    private readonly string _path;
    private List<ApprovedPeer> _peers;

    /// <summary>
    /// The optional path exists solely for isolated tests. Production always
    /// uses the per-user DPAPI-backed peer registry.
    /// </summary>
    public ApprovedPeerStore(string? path = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "VibeWalkie", "approved-peers.dpapi");
        _peers = Load();
    }

    public IReadOnlyList<ApprovedPeer> Active
    {
        get { lock (_lock) return _peers.Where(static peer => !peer.IsRevoked).ToArray(); }
    }

    public ApprovedPeer? Find(string id)
    {
        lock (_lock) return _peers.FirstOrDefault(peer => peer.ID == id && !peer.IsRevoked);
    }

    public void Approve(ApprovedPeer peer)
    {
        lock (_lock)
        {
            _peers.RemoveAll(item => item.ID == peer.ID);
            _peers.Add(peer);
            Save();
        }
    }

    public void Seen(string id)
    {
        lock (_lock)
        {
            var index = _peers.FindIndex(peer => peer.ID == id);
            if (index >= 0) _peers[index] = _peers[index] with { LastSeenAt = DateTimeOffset.UtcNow };
            Save();
        }
    }

    public void Revoke(string id)
    {
        lock (_lock)
        {
            var index = _peers.FindIndex(peer => peer.ID == id);
            if (index >= 0) _peers[index] = _peers[index] with { IsRevoked = true };
            Save();
        }
    }

    private List<ApprovedPeer> Load()
    {
        try
        {
            if (!File.Exists(_path)) return [];
            var encrypted = File.ReadAllBytes(_path);
            var clear = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            return CanonicalJson.Deserialize<List<ApprovedPeer>>(clear);
        }
        catch (Exception error)
        {
            LocalDiagnostics.Record("peer_store_read", error);
            throw new InvalidDataException("Les téléphones autorisés sont illisibles. Restaurez approved-peers.dpapi avant de relancer le compagnon.", error);
        }
    }

    private void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var clear = CanonicalJson.SerializeToUtf8Bytes(_peers);
        var encrypted = ProtectedData.Protect(clear, null, DataProtectionScope.CurrentUser);
        var temporary = _path + ".tmp";
        File.WriteAllBytes(temporary, encrypted);
        File.Move(temporary, _path, true);
    }
}
