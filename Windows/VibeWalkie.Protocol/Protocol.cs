using System.Buffers.Binary;
using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace VibeWalkie.Protocol;

public static class ProtocolVersion
{
    public const int Current = 4;
}

/// <summary>Cross-platform constants that define a V4 host endpoint.</summary>
public static class VibeWalkieInfo
{
    public const ushort ControlPort = 54_389;
    public static readonly TimeSpan TargetTokenLifetime = TimeSpan.FromSeconds(120);
}

public static class ProtocolLimits
{
    public const int MaxFrameBytes = 512 * 1024;
    public const int MaxTextLength = 32_000;
    public static readonly TimeSpan AcknowledgementTimeout = TimeSpan.FromSeconds(8);
}

[JsonConverter(typeof(JsonStringEnumConverter<RemoteMessageType>))]
public enum RemoteMessageType
{
    [JsonStringEnumMemberName("hello")] Hello,
    [JsonStringEnumMemberName("pairing_challenge")] PairingChallenge,
    [JsonStringEnumMemberName("pairing_response")] PairingResponse,
    [JsonStringEnumMemberName("pairing_pending")] PairingPending,
    [JsonStringEnumMemberName("recording_started")] RecordingStarted,
    [JsonStringEnumMemberName("insert_text")] InsertText,
    [JsonStringEnumMemberName("cancel")] Cancel,
    [JsonStringEnumMemberName("list_windows")] ListWindows,
    [JsonStringEnumMemberName("windows_snapshot")] WindowsSnapshot,
    [JsonStringEnumMemberName("activate_window")] ActivateWindow,
    [JsonStringEnumMemberName("keyboard_text")] KeyboardText,
    [JsonStringEnumMemberName("key_press")] KeyPress,
    [JsonStringEnumMemberName("agent_target_request")] AgentTargetRequest,
    [JsonStringEnumMemberName("voice_control")] VoiceControl,
    [JsonStringEnumMemberName("voice_action")] VoiceAction,
    [JsonStringEnumMemberName("work_walking_sessions_request")] WorkWalkingSessionsRequest,
    [JsonStringEnumMemberName("work_walking_sessions_snapshot")] WorkWalkingSessionsSnapshot,
    [JsonStringEnumMemberName("health_activity_snapshot_update")] HealthActivitySnapshotUpdate,
    [JsonStringEnumMemberName("host_shortcut_press")] HostShortcutPress,
    [JsonStringEnumMemberName("control_configuration_request")] ControlConfigurationRequest,
    [JsonStringEnumMemberName("control_configuration_snapshot")] ControlConfigurationSnapshot,
    [JsonStringEnumMemberName("control_configuration_update")] ControlConfigurationUpdate,
    [JsonStringEnumMemberName("pointer_move")] PointerMove,
    [JsonStringEnumMemberName("pointer_absolute")] PointerAbsolute,
    [JsonStringEnumMemberName("pointer_click")] PointerClick,
    [JsonStringEnumMemberName("pointer_drag")] PointerDrag,
    [JsonStringEnumMemberName("scroll")] Scroll,
    [JsonStringEnumMemberName("screen_stream_request")] ScreenStreamRequest,
    [JsonStringEnumMemberName("screen_stream_status")] ScreenStreamStatus,
    [JsonStringEnumMemberName("screen_frame")] ScreenFrame,
    [JsonStringEnumMemberName("acknowledgement")] Acknowledgement,
    [JsonStringEnumMemberName("connection_status")] ConnectionStatus,
    [JsonStringEnumMemberName("error")] Error,
}

public sealed record RemoteEnvelope(
    int Version,
    RemoteMessageType Type,
    Guid MessageID,
    Guid? ReplyTo,
    string SessionID,
    ulong Sequence,
    DateTimeOffset SentAt,
    byte[] Payload)
{
    public static RemoteEnvelope Create<T>(RemoteMessageType type, string sessionID, ulong sequence, T payload, Guid? replyTo = null) =>
        new(ProtocolVersion.Current, type, Guid.NewGuid(), replyTo, sessionID, sequence, DateTimeOffset.UtcNow, CanonicalJson.SerializeToUtf8Bytes(payload));

    public T DecodePayload<T>() => CanonicalJson.Deserialize<T>(Payload);
}

public static class CanonicalJson
{
    public static readonly JsonSerializerOptions Options = CreateOptions();

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = false,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            // Swift and Kotlin emit canonical UTF-8 JSON, not escaped \uXXXX
            // sequences. Keep the exact byte-level V4 contract identical.
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        };
        options.Converters.Add(new UtcDateTimeOffsetConverter());
        return options;
    }

    public static byte[] SerializeToUtf8Bytes<T>(T value)
    {
        var element = JsonSerializer.SerializeToElement(value, Options);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Encoder = Options.Encoder })) WriteSorted(writer, element);
        return stream.ToArray();
    }

    public static string Serialize<T>(T value) => System.Text.Encoding.UTF8.GetString(SerializeToUtf8Bytes(value));

    public static T Deserialize<T>(ReadOnlySpan<byte> value) =>
        JsonSerializer.Deserialize<T>(value, Options) ?? throw new JsonException($"Unable to decode {typeof(T).Name}");

    public static T Deserialize<T>(string value) => Deserialize<T>(System.Text.Encoding.UTF8.GetBytes(value));

    private static void WriteSorted(Utf8JsonWriter writer, JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in element.EnumerateObject().OrderBy(static value => value.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteSorted(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in element.EnumerateArray()) WriteSorted(writer, item);
                writer.WriteEndArray();
                break;
            default:
                element.WriteTo(writer);
                break;
        }
    }
}

public sealed class UtcDateTimeOffsetConverter : JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        DateTimeOffset.Parse(reader.GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options)
    {
        var utc = value.ToUniversalTime();
        var format = utc.Millisecond == 0 ? "yyyy-MM-dd'T'HH:mm:ss'Z'" : "yyyy-MM-dd'T'HH:mm:ss.fff'Z'";
        writer.WriteStringValue(utc.ToString(format, CultureInfo.InvariantCulture));
    }
}

public static class MessageFramer
{
    public static byte[] Frame(ReadOnlySpan<byte> body)
    {
        if (body.Length > ProtocolLimits.MaxFrameBytes) throw new ProtocolException(RemoteErrorCode.PayloadTooLarge);
        var frame = new byte[sizeof(int) + body.Length];
        BinaryPrimitives.WriteInt32BigEndian(frame, body.Length);
        body.CopyTo(frame.AsSpan(sizeof(int)));
        return frame;
    }

    public static byte[] Frame(RemoteEnvelope envelope) => Frame(CanonicalJson.SerializeToUtf8Bytes(envelope));

    public static int ReadLength(ReadOnlySpan<byte> header)
    {
        if (header.Length != sizeof(int)) throw new InvalidDataException("Invalid frame header");
        var length = BinaryPrimitives.ReadInt32BigEndian(header);
        if (length < 0 || length > ProtocolLimits.MaxFrameBytes) throw new ProtocolException(RemoteErrorCode.PayloadTooLarge);
        return length;
    }
}

public sealed class ReplayGuard
{
    private readonly object _lock = new();
    private ulong _lastSequence;
    private readonly HashSet<Guid> _messageIDs = [];
    private readonly Queue<Guid> _order = [];

    public ReplayDisposition Accept(RemoteEnvelope envelope)
    {
        lock (_lock)
        {
            if (envelope.Version != ProtocolVersion.Current) throw new ProtocolException(RemoteErrorCode.VersionMismatch);
            if (_messageIDs.Contains(envelope.MessageID)) return ReplayDisposition.Duplicate;
            if (envelope.Sequence <= _lastSequence) throw new ProtocolException(RemoteErrorCode.ReplayDetected);
            _messageIDs.Add(envelope.MessageID);
            _lastSequence = envelope.Sequence;
            _order.Enqueue(envelope.MessageID);
            if (_order.Count > 2_048) _messageIDs.Remove(_order.Dequeue());
            return ReplayDisposition.Accepted;
        }
    }
}

public enum ReplayDisposition { Accepted, Duplicate }

/// <summary>
/// Replays the original response for a retried command, including after a TLS
/// reconnect. Entries are scoped to an approved peer, bounded in both peer and
/// command count, and coalesce concurrent retries before their action runs.
/// </summary>
public sealed class RecentMessageCache<T>
{
    private const int MaximumPeers = 32;
    private const int EntriesPerPeer = 2_048;
    private readonly object _lock = new();
    private readonly Dictionary<string, PeerEntries> _peers = [];
    private readonly LinkedList<string> _peerOrder = [];

    public Task<T> GetOrExecuteAsync(string peerID, Guid messageID, Func<Task<T>> action)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(peerID);
        ArgumentNullException.ThrowIfNull(action);

        TaskCompletionSource<T>? owner = null;
        lock (_lock)
        {
            var entries = EntriesFor(peerID);
            if (entries.Completed.TryGetValue(messageID, out var prior)) return Task.FromResult(prior);
            if (entries.InFlight.TryGetValue(messageID, out var pending)) return pending.Task;

            owner = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
            entries.InFlight[messageID] = owner;
        }

        return CompleteAsync(peerID, messageID, owner, action);
    }

    private async Task<T> CompleteAsync(string peerID, Guid messageID, TaskCompletionSource<T> owner, Func<Task<T>> action)
    {
        try
        {
            var response = await action().ConfigureAwait(false);
            lock (_lock)
            {
                var entries = EntriesFor(peerID);
                entries.InFlight.Remove(messageID);
                entries.Completed[messageID] = response;
                entries.Order.Enqueue(messageID);
                if (entries.Order.Count > EntriesPerPeer) entries.Completed.Remove(entries.Order.Dequeue());
            }
            owner.TrySetResult(response);
            return response;
        }
        catch (Exception error)
        {
            lock (_lock) EntriesFor(peerID).InFlight.Remove(messageID);
            owner.TrySetException(error);
            throw;
        }
    }

    private PeerEntries EntriesFor(string peerID)
    {
        if (_peers.TryGetValue(peerID, out var existing))
        {
            _peerOrder.Remove(existing.OrderNode);
            _peerOrder.AddLast(existing.OrderNode);
            return existing;
        }

        if (_peers.Count == MaximumPeers)
        {
            var oldest = _peerOrder.First!;
            _peers.Remove(oldest.Value);
            _peerOrder.RemoveFirst();
        }
        var node = _peerOrder.AddLast(peerID);
        var created = new PeerEntries(node);
        _peers.Add(peerID, created);
        return created;
    }

    private sealed class PeerEntries(LinkedListNode<string> orderNode)
    {
        public LinkedListNode<string> OrderNode { get; } = orderNode;
        public Dictionary<Guid, T> Completed { get; } = [];
        public Dictionary<Guid, TaskCompletionSource<T>> InFlight { get; } = [];
        public Queue<Guid> Order { get; } = [];
    }
}

public sealed class ProtocolException(RemoteErrorCode code, string? detail = null) : Exception(detail ?? code.ToString())
{
    public RemoteErrorCode Code { get; } = code;
}
