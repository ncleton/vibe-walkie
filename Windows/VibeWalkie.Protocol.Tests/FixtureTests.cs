using System.Text;
using System.Text.Json;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using VibeWalkie.Protocol;
using Xunit;

namespace VibeWalkie.Protocol.Tests;

public sealed class FixtureTests
{
    private static string Fixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", name)).Trim();

    [Fact]
    public void EnvelopeMatchesSwiftAndKotlin()
    {
        var envelope = new RemoteEnvelope(
            4,
            RemoteMessageType.KeyPress,
            Guid.Parse("00000000-0000-0000-0000-000000000001"),
            null,
            "fixture-session",
            1,
            DateTimeOffset.Parse("2026-09-02T00:00:00Z"),
            Convert.FromBase64String("eyJrZXkiOiJlbnRlciJ9"));

        Assert.Equal(Fixture("envelope-keypress.json"), CanonicalJson.Serialize(envelope));
        var keyPress = envelope.DecodePayload<KeyPressPayload>();
        Assert.Equal(RemoteKey.Enter, keyPress.Key);
        Assert.Null(keyPress.RepeatCount);
    }

    [Fact]
    public void KeyPressRepeatCountUsesTheSharedSnakeCaseWireField()
    {
        var payload = CanonicalJson.Deserialize<KeyPressPayload>("{\"key\":\"backspace\",\"repeat_count\":32}");

        Assert.Equal(RemoteKey.Backspace, payload.Key);
        Assert.Equal(32, payload.RepeatCount);
        Assert.Equal("{\"key\":\"backspace\",\"repeat_count\":32}", CanonicalJson.Serialize(payload));
    }

    [Fact]
    public void WindowsPairingQrMatchesFixture()
    {
        var qr = CanonicalJson.Deserialize<PairingQrPayload>(Fixture("pairing-qr-windows.json"));
        Assert.Equal(HostPlatform.Windows, qr.HostPlatform);
        Assert.Equal("PC Bureau", qr.HostName);
        qr.Validate();
        Assert.Equal(Fixture("pairing-qr-windows.json"), CanonicalJson.Serialize(qr));
    }

    [Fact]
    public void PairingQrRejectsMalformedCryptographicMaterial()
    {
        var qr = new PairingQrPayload(
            ProtocolVersion.Current,
            "PC Bureau",
            HostPlatform.Windows,
            "VibeRemote-PC",
            "cGFzLXVuLXNoYTI1Ng==",
            "MDEyMzQ1Njc4OWFiY2RlZg==",
            DateTimeOffset.UtcNow.AddMinutes(1));

        var error = Assert.Throws<ProtocolException>(qr.Validate);
        Assert.Equal(RemoteErrorCode.ProtocolMismatch, error.Code);
    }

    [Fact]
    public void WindowsCapabilitiesMatchFixture()
    {
        var status = CanonicalJson.Deserialize<ConnectionStatusPayload>(Fixture("connection-status-windows.json"));
        Assert.True(status.InputControlReady);
        Assert.Contains(HostCapability.Pointer, status.Capabilities);
        Assert.DoesNotContain(HostCapability.SmoothCursorNavigation, status.Capabilities);
    }

    [Fact]
    public void ShortcutPaletteMatchesSwiftAndKotlin()
    {
        var configuration = CanonicalJson.Deserialize<ControlConfiguration>(Fixture("control-configuration-palette.json"));
        Assert.Equal(["search", "focus-main"], configuration.AvailableShortcuts!.Select(static value => value.ID));
        Assert.Equal(Fixture("control-configuration-palette.json"), CanonicalJson.Serialize(configuration));
    }

    [Fact]
    public void FramingIsBigEndianAndBounded()
    {
        var fixture = CanonicalJson.Deserialize<FramingFixture>(Fixture("framing.json"));
        var frame = MessageFramer.Frame(Convert.FromBase64String(fixture.Body));
        Assert.Equal(fixture.FrameHex, Convert.ToHexStringLower(frame));
        Assert.Equal(fixture.BodyLength, MessageFramer.ReadLength(frame.AsSpan(0, 4)));
        Assert.Equal(ProtocolLimits.MaxFrameBytes, fixture.MaximumBodyBytes);
        Assert.Throws<ProtocolException>(() => MessageFramer.Frame(new byte[fixture.MaximumBodyBytes + 1]));
    }

    [Fact]
    public void ErrorsMatchSharedV4Fixture()
    {
        var fixture = CanonicalJson.Deserialize<ErrorFixture>(Fixture("errors.json"));
        Assert.Equal([
            RemoteErrorCode.VersionMismatch,
            RemoteErrorCode.UnsupportedCapability,
            RemoteErrorCode.InputUnavailable,
            RemoteErrorCode.ScreenUnavailable,
            RemoteErrorCode.SecureTarget,
            RemoteErrorCode.TargetLost,
            RemoteErrorCode.ActivationDenied,
            RemoteErrorCode.RateLimited,
            RemoteErrorCode.InvalidControlConfiguration,
        ], fixture.Codes);
    }

    [Fact]
    public void ScreenFramePreservesJpegBase64Fixture()
    {
        var expected = Fixture("screen-frame.json");
        var frame = CanonicalJson.Deserialize<ScreenFramePayload>(expected);
        Assert.Equal([0xFF, 0xD8, 0xFF, 0xD9], frame.JpegData);
        Assert.Equal(expected, CanonicalJson.Serialize(frame));
    }

    [Fact]
    public void ReplayGuardClassifiesDuplicateAndRejectsUnknownOldSequence()
    {
        var envelope = RemoteEnvelope.Create(RemoteMessageType.Hello, "session", 1, new EmptyPayload());
        var guard = new ReplayGuard();
        Assert.Equal(ReplayDisposition.Accepted, guard.Accept(envelope));
        Assert.Equal(ReplayDisposition.Duplicate, guard.Accept(envelope));
        var replay = envelope with { MessageID = Guid.NewGuid() };
        Assert.Throws<ProtocolException>(() => guard.Accept(replay));
    }

    [Fact]
    public void V3EnvelopeIsRejectedBeforeReplayStateChanges()
    {
        var guard = new ReplayGuard();
        var legacy = RemoteEnvelope.Create(RemoteMessageType.KeyPress, "v3", 1, new KeyPressPayload(RemoteKey.Enter)) with { Version = 3 };

        var error = Assert.Throws<ProtocolException>(() => guard.Accept(legacy));
        Assert.Equal(RemoteErrorCode.VersionMismatch, error.Code);
        Assert.Equal(ReplayDisposition.Accepted, guard.Accept(RemoteEnvelope.Create(RemoteMessageType.KeyPress, "v4", 1, new KeyPressPayload(RemoteKey.Enter))));
    }

    [Fact]
    public async Task RecentMessageCacheReplaysOneThousandCommandsAcrossReconnects()
    {
        var cache = new RecentMessageCache<string>();
        var peer = "phone-a";
        var ids = Enumerable.Range(0, 1_000).Select(_ => Guid.NewGuid()).ToArray();
        var executions = 0;

        foreach (var (id, index) in ids.Select((id, index) => (id, index)))
        {
            var response = await cache.GetOrExecuteAsync(peer, id, () => Task.FromResult($"ack-{++executions}"));
            Assert.Equal($"ack-{index + 1}", response);
        }

        foreach (var id in ids.Reverse())
        {
            var response = await cache.GetOrExecuteAsync(peer, id, () => Task.FromResult($"unexpected-{++executions}"));
            Assert.StartsWith("ack-", response);
        }

        Assert.Equal(1_000, executions);
        Assert.Equal("ack-1001", await cache.GetOrExecuteAsync("phone-b", ids[0], () => Task.FromResult($"ack-{++executions}")));
        Assert.Equal(1_001, executions);
    }

    [Fact]
    public async Task RecentMessageCacheCoalescesConcurrentReconnectRetries()
    {
        var cache = new RecentMessageCache<string>();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var executions = 0;
        var id = Guid.NewGuid();

        var first = cache.GetOrExecuteAsync("phone-a", id, async () =>
        {
            executions++;
            entered.SetResult();
            await release.Task;
            return "ack";
        });
        await entered.Task;
        var retry = cache.GetOrExecuteAsync("phone-a", id, () => Task.FromResult("must-not-run"));

        release.SetResult();
        Assert.Equal("ack", await first);
        Assert.Equal("ack", await retry);
        Assert.Equal(1, executions);
    }

    [Fact]
    public void Ed25519SignatureMatchesSwiftAndKotlin()
    {
        using var fixture = JsonDocument.Parse(Fixture("signature-ed25519.json"));
        var root = fixture.RootElement;
        var nonce = Convert.FromBase64String(root.GetProperty("nonce").GetString()!);
        var identifier = root.GetProperty("deviceIdentifier").GetString()!;
        var secret = Convert.FromBase64String(root.GetProperty("pairingSecret").GetString()!);
        var message = nonce.Concat(Encoding.UTF8.GetBytes(identifier)).Concat(secret).ToArray();
        Assert.Equal(Convert.FromBase64String(root.GetProperty("message").GetString()!), message);
        var signer = new Ed25519Signer();
        signer.Init(false, new Ed25519PublicKeyParameters(Convert.FromBase64String(root.GetProperty("publicKey").GetString()!)));
        signer.BlockUpdate(message, 0, message.Length);
        Assert.True(signer.VerifySignature(Convert.FromBase64String(root.GetProperty("signature").GetString()!)));
    }

    private sealed record FramingFixture(string Body, int BodyLength, string FrameHex, int MaximumBodyBytes);
    private sealed record ErrorFixture(RemoteErrorCode[] Codes);
}
