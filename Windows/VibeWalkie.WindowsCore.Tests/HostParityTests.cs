using VibeWalkie.Companion.Health;
using VibeWalkie.Companion.Input;
using VibeWalkie.Protocol;
using Xunit;

namespace VibeWalkie.WindowsCore.Tests;

public sealed class HostParityTests
{
    [Fact]
    public void TinyPointerMovementsAccumulateAcrossFramesAndResetBetweenSessions()
    {
        var pointer = new RelativePointerIntegrator();
        var sum = (X: 0, Y: 0);
        for (var index = 0; index < 1000; index++)
        {
            var delta = pointer.Integrate(.12, -.12); sum.X += delta.X; sum.Y += delta.Y;
        }
        Assert.InRange(sum.X, 119, 120); Assert.InRange(sum.Y, -120, -119);
        pointer.Reset(); Assert.Equal((0, 0), pointer.Integrate(.01, -.01));
    }
    [Fact]
    public void ChangedSelectionsAndDocumentsAreRejectedBeforeTextInsertion()
    {
        var capture = new TextSelectionSnapshot("Bonjour 🌍 fin", 8, 10);
        Assert.Equal("Bonjour café fin", capture.ReplacingSelection("café"));
        Assert.Throws<ProtocolException>(() => capture.Verify(capture with { Start = 7 }));
        Assert.Throws<ProtocolException>(() => capture.Verify(capture with { Text = "Bonjour 🌍 FIN" }));
        capture.Verify(capture with { });
    }
    [Fact]
    public void HealthAggregatesRejectNonFiniteOutOfRangeAndStaleValues()
    {
        var now = DateTimeOffset.UtcNow;
        var valid = new HealthActivitySnapshotPayload(null, 12000, 1200, now); valid.Validate(now);
        foreach (var invalid in new[] { valid with { WalkingDistanceMetersLast7Days = double.NaN },
            valid with { BriskWalkingMinutesLast7Days = 10081 }, valid with { CapturedAt = now.AddDays(-8) } })
            Assert.Throws<ProtocolException>(() => invalid.Validate(now));
    }
    [Fact]
    public void WalkingSessionsRecoverAfterInterruptionWithoutInventingUnobservedTime()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var path = Path.Combine(directory, "sessions.json");
        try
        {
            var now = DateTimeOffset.UtcNow;
            var store = new WorkWalkingSessionStore(path);
            store.Observe(true, now); store.Observe(true, now.AddSeconds(10));
            var restored = new WorkWalkingSessionStore(path);
            var session = Assert.Single(restored.Snapshot(now.AddMinutes(-1), now.AddHours(1)).Sessions);
            Assert.False(session.IsOngoing); Assert.InRange((now.AddSeconds(10) - session.EndedAt).TotalMilliseconds, 0, 1);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
    [Fact]
    public void DiscoveryMarkerIsBoundToExactChallengeAndStrictPublicMarker()
    {
        var challenge = Guid.NewGuid().ToString(); var marker = new string('a', 43);
        Assert.Equal(marker, AgentNativeMarker.Parse("CRM [AAC1:" + challenge + ":" + marker + "]", challenge));
        Assert.Null(AgentNativeMarker.Parse("CRM [AAC1:" + Guid.NewGuid() + ":" + marker + "]", challenge));
        Assert.Null(AgentOrigin.Canonical("https://user:password@example.com"));
        Assert.Equal("https://example.com", AgentOrigin.Canonical("https://EXAMPLE.com/path"));
    }
}
