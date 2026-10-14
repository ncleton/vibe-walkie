using System.Security.Cryptography;
using System.Text;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Input;

public sealed record TextSelectionSnapshot(string Text, int Start, int End)
{
    public static string Normalize(string value) => value.Replace("\r\n", "\n").Replace('\r', '\n');
    public string ReplacingSelection(string value)
    {
        if (Start < 0 || End < Start || End > Text.Length)
            throw new ProtocolException(RemoteErrorCode.TargetChanged);
        return Normalize(Text[..Start] + value + Text[End..]);
    }
    public void Verify(TextSelectionSnapshot current)
    {
        if (Start != current.Start || End != current.End || !CryptographicOperations.FixedTimeEquals(
            SHA256.HashData(Encoding.UTF8.GetBytes(Text)), SHA256.HashData(Encoding.UTF8.GetBytes(current.Text))))
            throw new ProtocolException(RemoteErrorCode.TargetChanged);
    }
}

public sealed class RelativePointerIntegrator
{
    private double _x, _y;
    public (int X, int Y) Integrate(double x, double y)
    {
        _x += InputControlPolicy.GestureDelta(x); _y += InputControlPolicy.GestureDelta(y);
        var result = ((int)_x, (int)_y);
        _x -= result.Item1; _y -= result.Item2;
        return result;
    }
    public void Reset() => _x = _y = 0;
}
