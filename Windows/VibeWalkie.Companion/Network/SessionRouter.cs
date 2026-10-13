using VibeWalkie.Companion.Input;
using VibeWalkie.Companion.Screen;
using VibeWalkie.Companion.Windows;
using VibeWalkie.Protocol;
using System.Text.Json;
using VibeWalkie.Companion.Accessibility;
using VibeWalkie.Companion.VoiceActions;
using VibeWalkie.Companion.Health;

namespace VibeWalkie.Companion.Network;

public sealed record RouteResponse(RemoteMessageType Type, byte[] Payload);

public sealed class SessionRouter
{
    private readonly TargetCaptureService _targets = new();
    private readonly InputService _input;
    private readonly VoiceActionsService _voiceActions;
    private readonly WindowCatalog _windows;
    private readonly ScreenCaptureService _screen;
    private readonly HostShortcutStore _shortcuts;
    private readonly ConfigurationStore _configuration;
    private readonly Action? _configurationChanged;
    private readonly RecentMessageCache<RouteResponse> _recentResponses;
    private readonly string _peerID;
    private readonly WorkWalkingSessionStore _walking;
    private readonly SemaphoreSlim _serial = new(1, 1);
    private readonly Dictionary<Guid, RouteResponse> _sessionResponses = [];
    private readonly Queue<Guid> _sessionResponseOrder = [];
    private readonly TokenBucket _commands = new(40, 20);
    private readonly TokenBucket _gestures = new(240, 180);

    public SessionRouter(
        InputService input,
        WindowCatalog windows,
        ScreenCaptureService screen,
        HostShortcutStore shortcuts,
        ConfigurationStore configuration,
        RecentMessageCache<RouteResponse> recentResponses,
        string peerID,
        WorkWalkingSessionStore walking,
        Action? configurationChanged = null)
    {
        _input = input;
        _voiceActions = new VoiceActionsService(input);
        _windows = windows;
        _screen = screen;
        _shortcuts = shortcuts;
        _configuration = configuration;
        _recentResponses = recentResponses;
        _peerID = peerID;
        _walking = walking;
        _configurationChanged = configurationChanged;
    }

    public Task<RouteResponse> RouteAsync(RemoteEnvelope envelope, Func<ScreenFramePayload, ValueTask> frameHandler) =>
        IsCrossSessionIdempotent(envelope.Type)
            ? _recentResponses.GetOrExecuteAsync(_peerID, envelope.MessageID, () => ExecuteAndRememberAsync(envelope, frameHandler))
            : ExecuteAndRememberAsync(envelope, frameHandler);

    private async Task<RouteResponse> ExecuteAndRememberAsync(RemoteEnvelope envelope, Func<ScreenFramePayload, ValueTask> frameHandler)
    {
        await _serial.WaitAsync();
        try
        {
            if (_sessionResponses.TryGetValue(envelope.MessageID, out var prior)) return prior;
            var gesture = envelope.Type is RemoteMessageType.PointerMove or RemoteMessageType.PointerAbsolute or RemoteMessageType.PointerDrag or RemoteMessageType.Scroll or RemoteMessageType.KeyPress;
            if (!(gesture ? _gestures : _commands).Allow()) return RememberSession(envelope.MessageID, Error(RemoteErrorCode.RateLimited));

            try
            {
                var response = envelope.Type switch
                {
                    RemoteMessageType.Hello => Ack(),
                    RemoteMessageType.VoiceAction => new RouteResponse(RemoteMessageType.Acknowledgement, CanonicalJson.SerializeToUtf8Bytes(new AcknowledgementPayload(true, VoiceAction: await _voiceActions.ExecuteAsync(envelope.DecodePayload<VoiceActionPayload>())))),
                    RemoteMessageType.AgentTargetRequest => new RouteResponse(RemoteMessageType.Acknowledgement, CanonicalJson.SerializeToUtf8Bytes(await BrowserAgentTarget.CaptureAsync(envelope.DecodePayload<AgentTargetRequest>()))),
                    RemoteMessageType.VoiceControl => await VoiceControl(envelope.DecodePayload<VoiceControlPayload>()),
                    RemoteMessageType.WorkWalkingSessionsRequest => WalkingSnapshot(envelope.DecodePayload<WorkWalkingSessionsRequestPayload>()),
                    RemoteMessageType.HealthActivitySnapshotUpdate => UpdateHealth(envelope.DecodePayload<HealthActivitySnapshotPayload>()),
                    RemoteMessageType.RecordingStarted => Ack(target: _targets.Capture()),
                    RemoteMessageType.InsertText => Insert(envelope.DecodePayload<InsertTextPayload>()),
                    RemoteMessageType.Cancel => Cancel(),
                    RemoteMessageType.KeyboardText => Keyboard(envelope.DecodePayload<KeyboardTextPayload>()),
                    RemoteMessageType.KeyPress => Key(envelope.DecodePayload<KeyPressPayload>()),
                    RemoteMessageType.HostShortcutPress => Shortcut(envelope.DecodePayload<HostShortcutPressPayload>()),
                    RemoteMessageType.ListWindows => Snapshot(envelope.DecodePayload<ListWindowsPayload>().IncludeIcons),
                    RemoteMessageType.ActivateWindow => Activate(envelope.DecodePayload<ActivateWindowPayload>()),
                    RemoteMessageType.PointerMove => Move(envelope.DecodePayload<PointerMovePayload>()),
                    RemoteMessageType.PointerAbsolute => Absolute(envelope.DecodePayload<PointerAbsolutePayload>()),
                    RemoteMessageType.PointerClick => Click(envelope.DecodePayload<PointerClickPayload>()),
                    RemoteMessageType.PointerDrag => Drag(envelope.DecodePayload<PointerDragPayload>()),
                    RemoteMessageType.Scroll => Scroll(envelope.DecodePayload<ScrollPayload>()),
                    RemoteMessageType.ScreenStreamRequest => Screen(envelope.DecodePayload<ScreenStreamRequestPayload>(), frameHandler),
                    RemoteMessageType.ControlConfigurationRequest => ConfigurationSnapshot(),
                    RemoteMessageType.ControlConfigurationUpdate => ConfigurationUpdate(envelope.DecodePayload<ControlConfigurationPayload>()),
                    _ => Error(RemoteErrorCode.UnsupportedCapability),
                };
                return RememberSession(envelope.MessageID, response);
            }
            // ProtocolException details can originate in an integration layer.
            // Mobile clients map the common code locally and never receive it.
            catch (ProtocolException error) { return RememberSession(envelope.MessageID, Error(error.Code)); }
            catch (JsonException) { return RememberSession(envelope.MessageID, Error(RemoteErrorCode.ProtocolMismatch)); }
            catch (Exception error)
            {
                LocalDiagnostics.Record("command_failed", error);
                return RememberSession(envelope.MessageID, Error(RemoteErrorCode.InternalFailure));
            }
        }
        finally { _serial.Release(); }
    }

    public void Close()
    {
        _targets.Consume();
        _screen.Stop();
        _input.ReleaseInputs();
    }

    private RouteResponse Insert(InsertTextPayload payload)
    {
        var target = _targets.Resolve(payload.TargetToken);
        try { return Ack(insertion: _input.InsertText(payload.Text, target)); }
        finally { _targets.Consume(); }
    }
    private RouteResponse WalkingSnapshot(WorkWalkingSessionsRequestPayload payload) => new(RemoteMessageType.WorkWalkingSessionsSnapshot, CanonicalJson.SerializeToUtf8Bytes(_walking.Snapshot(payload.Since, DateTimeOffset.UtcNow)));
    private RouteResponse UpdateHealth(HealthActivitySnapshotPayload payload) { _walking.UpdateHealth(payload); return Ack(); }
    private static async Task<RouteResponse> VoiceControl(VoiceControlPayload payload) { await AssistantVoiceControl.HandleAsync(payload); return Ack(); }
    private RouteResponse Cancel() { _targets.Consume(); return Ack(); }
    private RouteResponse Keyboard(KeyboardTextPayload payload) => Ack(insertion: _input.TypeManually(payload.Text, payload.UserInitiated));
    private RouteResponse Key(KeyPressPayload payload)
    {
        _input.Press(payload.Key, InputControlPolicy.KeyRepeatCount(payload.RepeatCount));
        return Ack();
    }
    private RouteResponse Shortcut(HostShortcutPressPayload payload) { _shortcuts.Execute(payload.ShortcutID, _input); return Ack(); }
    private RouteResponse Snapshot(bool includeIcons) => new(RemoteMessageType.WindowsSnapshot, CanonicalJson.SerializeToUtf8Bytes(_windows.Snapshot(includeIcons)));
    private RouteResponse Activate(ActivateWindowPayload payload) { _windows.Activate(payload.ApplicationID, payload.WindowID); return Ack(); }
    private RouteResponse Move(PointerMovePayload payload) { _input.PointerMove(InputControlPolicy.GestureDelta(payload.DeltaX), InputControlPolicy.GestureDelta(payload.DeltaY)); return Ack(); }
    private RouteResponse Absolute(PointerAbsolutePayload payload) { _input.PointerAbsolute(InputControlPolicy.NormalizedCoordinate(payload.NormalizedX), InputControlPolicy.NormalizedCoordinate(payload.NormalizedY)); return Ack(); }
    private RouteResponse Click(PointerClickPayload payload) { _input.Click(payload.Button, payload.ClickCount); return Ack(); }
    private RouteResponse Drag(PointerDragPayload payload) { _input.Drag(payload.Phase, InputControlPolicy.GestureDelta(payload.DeltaX), InputControlPolicy.GestureDelta(payload.DeltaY)); return Ack(); }
    private RouteResponse Scroll(ScrollPayload payload) { _input.Scroll(InputControlPolicy.GestureDelta(payload.DeltaX), InputControlPolicy.GestureDelta(payload.DeltaY), payload.Zoom == true); return Ack(); }
    private RouteResponse Screen(ScreenStreamRequestPayload payload, Func<ScreenFramePayload, ValueTask> handler)
    {
        var request = InputControlPolicy.ScreenRequest(payload);
        if (request.Enabled) _screen.Start(request, handler); else _screen.Stop();
        return new(RemoteMessageType.ScreenStreamStatus, CanonicalJson.SerializeToUtf8Bytes(new ScreenStreamStatusPayload(request.Enabled, _screen.IsAvailable)));
    }
    private RouteResponse ConfigurationSnapshot() => new(RemoteMessageType.ControlConfigurationSnapshot, CanonicalJson.SerializeToUtf8Bytes(new ControlConfigurationPayload(_configuration.Current)));
    private RouteResponse ConfigurationUpdate(ControlConfigurationPayload payload)
    {
        _configuration.Update(payload.Configuration);
        _configurationChanged?.Invoke();
        return ConfigurationSnapshot();
    }

    private static RouteResponse Ack(TargetToken? target = null, InsertionResult? insertion = null) =>
        new(RemoteMessageType.Acknowledgement, CanonicalJson.SerializeToUtf8Bytes(new AcknowledgementPayload(true, target, insertion)));
    private static RouteResponse Error(RemoteErrorCode code, string? detail = null) =>
        new(RemoteMessageType.Error, CanonicalJson.SerializeToUtf8Bytes(new RemoteErrorPayload(code, detail)));

    private static bool IsCrossSessionIdempotent(RemoteMessageType type) => type is not (
        RemoteMessageType.Hello or
        RemoteMessageType.AgentTargetRequest or
        RemoteMessageType.RecordingStarted or
        RemoteMessageType.ListWindows or
        RemoteMessageType.WorkWalkingSessionsRequest or
        RemoteMessageType.ScreenStreamRequest or
        RemoteMessageType.ControlConfigurationRequest);

    private RouteResponse RememberSession(Guid id, RouteResponse response)
    {
        _sessionResponses[id] = response;
        _sessionResponseOrder.Enqueue(id);
        if (_sessionResponseOrder.Count > 2_048) _sessionResponses.Remove(_sessionResponseOrder.Dequeue());
        return response;
    }

}

internal sealed class TokenBucket
{
    private readonly object _lock = new();
    private readonly double _capacity;
    private readonly double _refillPerSecond;
    private double _tokens;
    private DateTimeOffset _last = DateTimeOffset.UtcNow;
    public TokenBucket(double capacity, double refillPerSecond)
    {
        _capacity = capacity;
        _refillPerSecond = refillPerSecond;
        _tokens = capacity;
    }
    public bool Allow()
    {
        lock (_lock)
        {
            var now = DateTimeOffset.UtcNow;
            _tokens = Math.Min(_capacity, _tokens + (now - _last).TotalSeconds * _refillPerSecond);
            _last = now;
            if (_tokens < 1) return false;
            _tokens--;
            return true;
        }
    }
}
