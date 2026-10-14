namespace VibeWalkie.Companion.Network;

/// <summary>
/// Bounds the work that an unauthenticated TCP peer can reserve. The permit is
/// released as soon as Ed25519 authentication succeeds, so it never caps the
/// user's established remote-control sessions.
/// </summary>
public sealed class UnauthenticatedSessionGate
{
    public const int InitialHandshakeTimeoutSeconds = 10;
    private readonly SemaphoreSlim _permits;

    public UnauthenticatedSessionGate(int maximumSessions)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumSessions, 1);
        _permits = new SemaphoreSlim(maximumSessions, maximumSessions);
    }

    public bool TryEnter() => _permits.Wait(0);
    public void Exit() => _permits.Release();
}
