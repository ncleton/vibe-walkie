using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VibeWalkie.Protocol;

[JsonConverter(typeof(JsonStringEnumConverter<HostPlatform>))]
public enum HostPlatform { [JsonStringEnumMemberName("macos")] MacOS, [JsonStringEnumMemberName("windows")] Windows, [JsonStringEnumMemberName("linux")] Linux }
[JsonConverter(typeof(JsonStringEnumConverter<ClientPlatform>))]
public enum ClientPlatform { [JsonStringEnumMemberName("ios")] IOS, [JsonStringEnumMemberName("android")] Android }
[JsonConverter(typeof(JsonStringEnumConverter<HostCapability>))]
public enum HostCapability
{
    [JsonStringEnumMemberName("dictation_targeting")] DictationTargeting,
    [JsonStringEnumMemberName("keyboard")] Keyboard,
    [JsonStringEnumMemberName("pointer")] Pointer,
    [JsonStringEnumMemberName("app_windows")] AppWindows,
    [JsonStringEnumMemberName("screen_streaming")] ScreenStreaming,
    [JsonStringEnumMemberName("custom_shortcuts")] CustomShortcuts,
    [JsonStringEnumMemberName("configuration_sync")] ConfigurationSync,
    [JsonStringEnumMemberName("tailscale")] Tailscale,
    [JsonStringEnumMemberName("smooth_cursor_navigation")] SmoothCursorNavigation,
    [JsonStringEnumMemberName("voice_actions")] VoiceActions,
}

public sealed record NomadEndpoint(string MagicDNSName, string? IPv4Address = null, ushort Port = VibeWalkieInfo.ControlPort)
{
    [JsonIgnore]
    public bool IsValid => Port == VibeWalkieInfo.ControlPort && MagicDNSName.TrimEnd('.').EndsWith(".ts.net", StringComparison.OrdinalIgnoreCase)
        && (IPv4Address is null || (System.Net.IPAddress.TryParse(IPv4Address, out var ip) && ip.GetAddressBytes() is [100, >= 64 and <= 127, _, _]));
}

public sealed record HelloPayload(string DeviceName, string DeviceIdentifier, string AppVersion, int ProtocolVersion, ClientPlatform ClientPlatform);
public sealed record PairingChallengePayload(byte[] Nonce, bool RequiresPairingSecret);
public sealed record PairingResponsePayload(string DeviceIdentifier, string DeviceName, byte[] PublicKey, byte[] Signature, byte[]? PairingSecret, ClientPlatform ClientPlatform);
public sealed record PairingPendingPayload(Guid RequestID, string DeviceName, string ConfirmationCode, DateTimeOffset ExpiresAt);
public sealed record RecordingStartedPayload(string Locale, Guid DictationID);
public sealed record TargetToken(string Token, string ApplicationName, string? ApplicationIdentifier, string? WindowTitle, DateTimeOffset ExpiresAt);
public sealed record InsertTextPayload(string TargetToken, string Text, Guid DictationID);
public sealed record CancelPayload(Guid DictationID);

public sealed record RemoteWindow(string ID, string Title, bool IsMain, bool IsMinimized);
public sealed record RemoteApplication(string ID, string Name, string? ApplicationIdentifier, bool IsActive, byte[]? IconPNG, IReadOnlyList<RemoteWindow> Windows);
public sealed record WindowsSnapshotPayload(IReadOnlyList<RemoteApplication> Applications, string? ActiveApplicationID, DateTimeOffset CapturedAt);
public sealed record ListWindowsPayload(bool IncludeIcons = true);
public sealed record ActivateWindowPayload(string ApplicationID, string? WindowID);

[JsonConverter(typeof(JsonStringEnumConverter<RemoteKey>))]
public enum RemoteKey
{
    [JsonStringEnumMemberName("enter")] Enter,
    [JsonStringEnumMemberName("escape")] Escape,
    [JsonStringEnumMemberName("tab")] Tab,
    [JsonStringEnumMemberName("application_switcher")] ApplicationSwitcher,
    [JsonStringEnumMemberName("next_conversation")] NextConversation,
    [JsonStringEnumMemberName("backspace")] Backspace,
    [JsonStringEnumMemberName("delete")] Delete,
    [JsonStringEnumMemberName("arrow_up")] ArrowUp,
    [JsonStringEnumMemberName("arrow_down")] ArrowDown,
    [JsonStringEnumMemberName("arrow_left")] ArrowLeft,
    [JsonStringEnumMemberName("arrow_right")] ArrowRight,
    [JsonStringEnumMemberName("space")] Space,
    [JsonStringEnumMemberName("copy")] Copy,
    [JsonStringEnumMemberName("paste")] Paste,
    [JsonStringEnumMemberName("cut")] Cut,
    [JsonStringEnumMemberName("select_all")] SelectAll,
    [JsonStringEnumMemberName("right_click")] RightClick,
    [JsonStringEnumMemberName("close_window")] CloseWindow,
}
public sealed record KeyPressPayload(
    RemoteKey Key,
    [property: JsonPropertyName("repeat_count")] int? RepeatCount = null);
public sealed record KeyboardTextPayload(string Text, bool UserInitiated);
public sealed record HostShortcutPressPayload(string ShortcutID);

[JsonConverter(typeof(JsonStringEnumConverter<PointerButton>))]
public enum PointerButton { [JsonStringEnumMemberName("left")] Left, [JsonStringEnumMemberName("right")] Right }
[JsonConverter(typeof(JsonStringEnumConverter<DragPhase>))]
public enum DragPhase { [JsonStringEnumMemberName("began")] Began, [JsonStringEnumMemberName("moved")] Moved, [JsonStringEnumMemberName("ended")] Ended }
public sealed record PointerMovePayload(double DeltaX, double DeltaY);
public sealed record PointerAbsolutePayload(double NormalizedX, double NormalizedY);
public sealed record PointerClickPayload(PointerButton Button, int ClickCount);
public sealed record PointerDragPayload(DragPhase Phase, double DeltaX, double DeltaY);
public sealed record ScrollPayload(double DeltaX, double DeltaY, bool? Zoom = null);

public sealed record ScreenStreamRequestPayload(bool Enabled, int MaxWidth = 1_280, int FramesPerSecond = 10, double JpegQuality = .45);
public sealed record ScreenStreamStatusPayload(bool IsStreaming, bool PermissionGranted, string? Detail = null);
public sealed record ScreenFramePayload(byte[] JpegData, int Width, int Height, DateTimeOffset CapturedAt);

[JsonConverter(typeof(JsonStringEnumConverter<InsertionMethod>))]
public enum InsertionMethod
{
    [JsonStringEnumMemberName("ax_selected_text")] AXSelectedText,
    [JsonStringEnumMemberName("ax_range")] AXRange,
    [JsonStringEnumMemberName("paste")] Paste,
    [JsonStringEnumMemberName("keyboard_events")] KeyboardEvents,
    [JsonStringEnumMemberName("ui_automation")] UIAutomation,
    [JsonStringEnumMemberName("unicode_events")] UnicodeEvents,
}
public sealed record InsertionResult(InsertionMethod Method, bool Verified, bool? PasteboardRestored, string ApplicationName);
public sealed record AcknowledgementPayload(bool Ok, TargetToken? TargetToken = null, InsertionResult? Insertion = null, VoiceActionResult? VoiceAction = null);
public sealed record ConnectionStatusPayload(
    bool InputControlReady,
    bool ScreenCaptureReady,
    string HostName,
    HostPlatform HostPlatform,
    IReadOnlyList<HostCapability> Capabilities,
    string CompanionVersion,
    NomadEndpoint? NomadEndpoint = null);

[JsonConverter(typeof(JsonStringEnumConverter<RemoteErrorCode>))]
public enum RemoteErrorCode
{
    [JsonStringEnumMemberName("version_mismatch")] VersionMismatch,
    [JsonStringEnumMemberName("unsupported_capability")] UnsupportedCapability,
    [JsonStringEnumMemberName("input_unavailable")] InputUnavailable,
    [JsonStringEnumMemberName("screen_unavailable")] ScreenUnavailable,
    [JsonStringEnumMemberName("secure_target")] SecureTarget,
    [JsonStringEnumMemberName("target_lost")] TargetLost,
    [JsonStringEnumMemberName("activation_denied")] ActivationDenied,
    [JsonStringEnumMemberName("permission_accessibility_denied")] PermissionAccessibilityDenied,
    [JsonStringEnumMemberName("local_network_denied")] LocalNetworkDenied,
    [JsonStringEnumMemberName("mac_unavailable")] HostUnavailable,
    [JsonStringEnumMemberName("speech_asset_missing")] SpeechAssetMissing,
    [JsonStringEnumMemberName("speech_unavailable")] SpeechUnavailable,
    [JsonStringEnumMemberName("no_focused_target")] NoFocusedTarget,
    [JsonStringEnumMemberName("target_changed")] TargetChanged,
    [JsonStringEnumMemberName("target_expired")] TargetExpired,
    [JsonStringEnumMemberName("secure_field")] SecureField,
    [JsonStringEnumMemberName("ax_not_settable")] AXNotSettable,
    [JsonStringEnumMemberName("paste_not_consumed")] PasteNotConsumed,
    [JsonStringEnumMemberName("pasteboard_changed")] PasteboardChanged,
    [JsonStringEnumMemberName("window_unavailable_on_space")] WindowUnavailableOnSpace,
    [JsonStringEnumMemberName("application_not_found")] ApplicationNotFound,
    [JsonStringEnumMemberName("peer_revoked")] PeerRevoked,
    [JsonStringEnumMemberName("not_paired")] NotPaired,
    [JsonStringEnumMemberName("pairing_denied")] PairingDenied,
    [JsonStringEnumMemberName("pairing_approval_expired")] PairingApprovalExpired,
    [JsonStringEnumMemberName("protocol_mismatch")] ProtocolMismatch,
    [JsonStringEnumMemberName("replay_detected")] ReplayDetected,
    [JsonStringEnumMemberName("payload_too_large")] PayloadTooLarge,
    [JsonStringEnumMemberName("rate_limited")] RateLimited,
    [JsonStringEnumMemberName("internal_failure")] InternalFailure,
    [JsonStringEnumMemberName("invalid_control_configuration")] InvalidControlConfiguration,
}
public sealed record RemoteErrorPayload(RemoteErrorCode Code, string? Detail = null);
public sealed record EmptyPayload;

public sealed record HostShortcutReference(string ID, string DisplayName, string? Icon = null);
public sealed record ControlButtonAction(string Type, RemoteKey? Key = null, HostShortcutReference? Shortcut = null);
public sealed record ControlButtonConfiguration(string Zone, string Title, JsonElement Icon, ControlButtonAction Action);
public sealed record GlobalButtonConfiguration(string ID, string Title, JsonElement Icon, ControlButtonAction Action);
public sealed record ControlConfiguration(
    IReadOnlyList<ControlButtonConfiguration> Buttons,
    IReadOnlyList<GlobalButtonConfiguration> GlobalButtons,
    ulong Revision,
    DateTimeOffset UpdatedAt,
    IReadOnlyList<HostShortcutReference>? AvailableShortcuts = null);
public sealed record ControlConfigurationPayload(ControlConfiguration Configuration);

public sealed record PairingQrPayload(
    [property: JsonPropertyName("v")] int Version,
    [property: JsonPropertyName("m")] string HostName,
    [property: JsonPropertyName("p")] HostPlatform HostPlatform,
    [property: JsonPropertyName("s")] string ServiceName,
    [property: JsonPropertyName("f")] string CertificateFingerprint,
    [property: JsonPropertyName("k")] string PairingSecret,
    [property: JsonPropertyName("e")] DateTimeOffset ExpiresAt,
    [property: JsonPropertyName("n")] NomadEndpoint? NomadEndpoint = null)
{
    [JsonIgnore]
    public bool IsExpired => DateTimeOffset.UtcNow >= ExpiresAt;
    [JsonIgnore]
    public string ConfirmationCode
    {
        get
        {
            var digest = SHA256.HashData(Encoding.UTF8.GetBytes(CertificateFingerprint + PairingSecret));
            var value = ((uint)digest[0] << 24) | ((uint)digest[1] << 16) | ((uint)digest[2] << 8) | digest[3];
            return (value % 1_000_000).ToString("D6", System.Globalization.CultureInfo.InvariantCulture);
        }
    }

    public void Validate()
    {
        if (Version != ProtocolVersion.Current) throw new ProtocolException(RemoteErrorCode.VersionMismatch);
        if (IsExpired) throw new ProtocolException(RemoteErrorCode.PairingApprovalExpired);
        try
        {
            if (string.IsNullOrWhiteSpace(HostName) || string.IsNullOrWhiteSpace(ServiceName)
                || CertificateFingerprint is null
                || PairingSecret is null
                || Convert.FromBase64String(CertificateFingerprint).Length != 32
                || Convert.FromBase64String(PairingSecret).Length != 16
                || NomadEndpoint?.IsValid == false)
                throw new ProtocolException(RemoteErrorCode.ProtocolMismatch);
        }
        catch (FormatException)
        {
            throw new ProtocolException(RemoteErrorCode.ProtocolMismatch);
        }
    }
}
