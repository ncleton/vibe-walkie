using System.Text;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace VibeWalkie.Protocol;

[JsonConverter(typeof(JsonStringEnumConverter<VoiceAssistantProvider>))]
public enum VoiceAssistantProvider
{
    [JsonStringEnumMemberName("chatgpt")] ChatGPT,
    [JsonStringEnumMemberName("claude")] Claude,
}
[JsonConverter(typeof(JsonStringEnumConverter<VoiceControlPhase>))]
public enum VoiceControlPhase
{
    [JsonStringEnumMemberName("began")] Began,
    [JsonStringEnumMemberName("ended")] Ended,
    [JsonStringEnumMemberName("cancelled")] Cancelled,
}
public sealed record VoiceControlPayload(VoiceAssistantProvider Provider, VoiceControlPhase Phase);
public sealed record VoiceActionPayload(Guid CommandID, string Text,
    [property: JsonPropertyName("confirmation_token")] Guid? ConfirmationToken = null, bool Confirmed = false);
public sealed record VoiceActionResult(string Action, string Summary,
    [property: JsonPropertyName("requires_confirmation")] bool RequiresConfirmation = false,
    [property: JsonPropertyName("confirmation_token")] Guid? ConfirmationToken = null);
public sealed record WorkWalkingSession(Guid ID, DateTimeOffset StartedAt, DateTimeOffset EndedAt, bool IsOngoing = false);
public sealed record WorkWalkingSessionsRequestPayload(DateTimeOffset Since);
public sealed record WorkWalkingSessionsSnapshotPayload(IReadOnlyList<WorkWalkingSession> Sessions, DateTimeOffset CapturedAt);
public sealed record HealthActivitySnapshotPayload(double? BriskWalkingMinutesLast7Days,
    double WalkingDistanceMetersLast7Days, double DetectedWalkingDurationLast7Days, DateTimeOffset CapturedAt)
{
    public void Validate(DateTimeOffset now)
    {
        if (BriskWalkingMinutesLast7Days is double minutes && (!double.IsFinite(minutes) || minutes is < 0 or > 10_080)
            || !double.IsFinite(WalkingDistanceMetersLast7Days) || WalkingDistanceMetersLast7Days is < 0 or > 1_000_000
            || !double.IsFinite(DetectedWalkingDurationLast7Days) || DetectedWalkingDurationLast7Days is < 0 or > 604_800
            || CapturedAt < now.AddDays(-7) || CapturedAt > now.AddHours(1))
            throw new ProtocolException(RemoteErrorCode.ProtocolMismatch);
    }
}
public sealed record AgentTargetRequest(IReadOnlyList<string> AllowedOrigins, string? ChallengeID = null);
public sealed record AgentPageTarget(string SessionId, string Revision, string Title, string Origin,
    string? FocusEpoch = null, string? DiscoveryMarker = null);
public static class AgentOrigin
{
    public static string? Canonical(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != "https"
            || string.IsNullOrEmpty(uri.Host) || !string.IsNullOrEmpty(uri.UserInfo)) return null;
        return "https://" + uri.IdnHost.ToLowerInvariant() + (uri.IsDefaultPort ? "" : ":" + uri.Port);
    }
}
public static class AgentNativeMarker
{
    public static string? Parse(string title, string challengeID)
    {
        if (!Guid.TryParse(challengeID, out _) || Encoding.UTF8.GetByteCount(title) > 16_384 || !title.EndsWith(']')) return null;
        var prefix = " [AAC1:" + challengeID + ":";
        var index = title.LastIndexOf(prefix, StringComparison.Ordinal);
        if (index < 0) return null;
        var marker = title[(index + prefix.Length)..^1];
        return Regex.IsMatch(marker, "^[A-Za-z0-9_-]{43}$", RegexOptions.CultureInvariant) ? marker : null;
    }
}
