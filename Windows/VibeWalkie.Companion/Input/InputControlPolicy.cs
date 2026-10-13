using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Input;

/// <summary>Validates numeric control values before they reach SendInput or D3D.</summary>
public static class InputControlPolicy
{
    public static double GestureDelta(double value)
    {
        if (!double.IsFinite(value)) throw new ProtocolException(RemoteErrorCode.ProtocolMismatch, "Coordonnée invalide");
        return Math.Clamp(value, -600, 600);
    }

    public static double NormalizedCoordinate(double value)
    {
        if (!double.IsFinite(value)) throw new ProtocolException(RemoteErrorCode.ProtocolMismatch, "Coordonnée invalide");
        return Math.Clamp(value, 0, 1);
    }

    public static int KeyRepeatCount(int? value) => Math.Clamp(value ?? 1, 1, 32);

    public static ScreenStreamRequestPayload ScreenRequest(ScreenStreamRequestPayload request)
    {
        if (!double.IsFinite(request.JpegQuality)) throw new ProtocolException(RemoteErrorCode.ProtocolMismatch, "Qualité d’image invalide");
        return request with
        {
            MaxWidth = Math.Clamp(request.MaxWidth, 640, 1_920),
            FramesPerSecond = Math.Clamp(request.FramesPerSecond, 4, 20),
            JpegQuality = Math.Clamp(request.JpegQuality, .2, .8),
        };
    }
}
