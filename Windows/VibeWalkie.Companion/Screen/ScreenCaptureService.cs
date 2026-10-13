using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using VibeWalkie.Protocol;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace VibeWalkie.Companion.Screen;

/// <summary>
/// Capture le moniteur principal par DXGI Desktop Duplication. Le texture GPU
/// est copié dans une texture staging lisible CPU uniquement le temps de
/// produire un JPEG borné. Après une veille, un changement d'affichage ou un
/// reset GPU, le backend est détruit puis recréé au prochain tick.
/// </summary>
public sealed class ScreenCaptureService : IAsyncDisposable
{
    private readonly object _backendLock = new();
    private CancellationTokenSource? _captureCancellation;
    private Task? _captureTask;
    private DesktopDuplicator? _desktop;

    public event Action<ProtocolException>? Failed;
    public bool IsAvailable => Native.OpenInputDesktop(0, false, 0x0100) is var desktop && desktop != 0 && Native.CloseDesktop(desktop);

    public void Start(ScreenStreamRequestPayload request, Func<ScreenFramePayload, ValueTask> frameHandler)
    {
        Stop();
        if (!IsAvailable) throw new ProtocolException(RemoteErrorCode.ScreenUnavailable);
        var cancellation = new CancellationTokenSource();
        _captureCancellation = cancellation;
        _captureTask = Task.Run(async () =>
        {
            var interval = TimeSpan.FromSeconds(1d / Math.Clamp(request.FramesPerSecond, 4, 20));
            using var timer = new PeriodicTimer(interval);
            while (await timer.WaitForNextTickAsync(cancellation.Token))
            {
                try
                {
                    var frame = Capture(request);
                    cancellation.Token.ThrowIfCancellationRequested();
                    await frameHandler(frame);
                }
                catch (OperationCanceledException) { break; }
                catch (Exception error)
                {
                    ResetBackend();
                    LocalDiagnostics.Record("screen_failed", error);
                    Failed?.Invoke(error as ProtocolException ?? new ProtocolException(RemoteErrorCode.ScreenUnavailable));
                    break;
                }
            }
        }, cancellation.Token);
    }

    public void Stop()
    {
        _captureCancellation?.Cancel();
        _captureCancellation?.Dispose();
        _captureCancellation = null;
        _captureTask = null;
        ResetBackend();
    }

    private ScreenFramePayload Capture(ScreenStreamRequestPayload request)
    {
        lock (_backendLock)
        {
            var desktop = _desktop ??= new DesktopDuplicator();
            using var source = desktop.AcquireFrame();
            var width = Math.Min(source.Width, request.MaxWidth);
            var height = Math.Max(1, (int)Math.Round(source.Height * width / (double)source.Width));
            using var resized = new Bitmap(source, new Size(width, height));
            var bytes = EncodeJpeg(resized, request.JpegQuality);
            // JPEG is base64 in the payload, itself base64 in the envelope.
            if (bytes.Length > (ProtocolLimits.MaxFrameBytes - 4096) * 9 / 16)
                throw new ProtocolException(RemoteErrorCode.PayloadTooLarge,
                    "La capture dépasse la limite réseau. Réduisez la largeur ou la qualité dans les réglages vidéo de l’iPhone.");
            return new ScreenFramePayload(bytes, width, height, DateTimeOffset.UtcNow);
        }
    }

    private void ResetBackend()
    {
        lock (_backendLock)
        {
            _desktop?.Dispose();
            _desktop = null;
        }
    }

    private static byte[] EncodeJpeg(Bitmap bitmap, double quality)
    {
        using var stream = new MemoryStream();
        var codec = ImageCodecInfo.GetImageEncoders().Single(static encoder => encoder.FormatID == ImageFormat.Jpeg.Guid);
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(Encoder.Quality, (long)Math.Round(quality * 100));
        bitmap.Save(stream, codec, parameters);
        return stream.ToArray();
    }

    public ValueTask DisposeAsync() { Stop(); return ValueTask.CompletedTask; }

    /// Le duplicateur ne conserve aucun octet de capture entre deux appels.
    private sealed class DesktopDuplicator : IDisposable
    {
        private readonly IDXGIFactory1 _factory;
        private readonly IDXGIAdapter1 _adapter;
        private readonly IDXGIOutput1 _output;
        private readonly ID3D11Device _device;
        private readonly IDXGIOutputDuplication _duplication;
        private readonly ID3D11Texture2D _staging;
        private readonly int _width;
        private readonly int _height;
        private bool _hasFrame;

        public DesktopDuplicator()
        {
            _factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
            _factory.EnumAdapters1(0, out var adapter).CheckError();
            _adapter = adapter ?? throw new ProtocolException(RemoteErrorCode.ScreenUnavailable);
            _adapter.EnumOutputs(0, out var rawOutput).CheckError();
            using var output = rawOutput ?? throw new ProtocolException(RemoteErrorCode.ScreenUnavailable);
            _output = output.QueryInterface<IDXGIOutput1>();
            var bounds = _output.Description.DesktopCoordinates;
            _width = bounds.Right - bounds.Left;
            _height = bounds.Bottom - bounds.Top;
            if (_width <= 0 || _height <= 0) throw new ProtocolException(RemoteErrorCode.ScreenUnavailable);

            D3D11.D3D11CreateDevice(
                _adapter,
                DriverType.Unknown,
                DeviceCreationFlags.BgraSupport,
                new[] { FeatureLevel.Level_11_0, FeatureLevel.Level_10_1 },
                out var device).CheckError();
            _device = device ?? throw new ProtocolException(RemoteErrorCode.ScreenUnavailable);
            _duplication = _output.DuplicateOutput(_device) ?? throw new ProtocolException(RemoteErrorCode.ScreenUnavailable);
            _staging = _device.CreateTexture2D(new Texture2DDescription
            {
                Width = checked((uint)_width),
                Height = checked((uint)_height),
                MipLevels = 1u,
                ArraySize = 1u,
                Format = Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Staging,
                BindFlags = BindFlags.None,
                CPUAccessFlags = CpuAccessFlags.Read,
                MiscFlags = ResourceOptionFlags.None,
            });
        }

        public Bitmap AcquireFrame()
        {
            ID3D11Texture2D? source = null;
            var acquired = false;
            try
            {
                var acquisition = _duplication.AcquireNextFrame(50, out _, out var resource);
                // A static desktop has no new DXGI texture. Re-encode the last
                // valid staging texture; do not destroy a healthy capture path.
                if (acquisition.Code == unchecked((int)0x887A0027) && _hasFrame)
                    return ReadStaging();
                acquisition.CheckError();
                acquired = true;
                using (resource)
                {
                    source = resource.QueryInterface<ID3D11Texture2D>();
                    _device.ImmediateContext.CopyResource(_staging, source);
                }
                source?.Dispose();
                source = null;

                _hasFrame = true;
                return ReadStaging();
            }
            finally
            {
                source?.Dispose();
                if (acquired) _duplication.ReleaseFrame();
            }
        }

        private Bitmap ReadStaging()
        {
                var mapped = _device.ImmediateContext.Map(_staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
                try { return CopyMappedBitmap(mapped.DataPointer, checked((int)mapped.RowPitch)); }
                finally { _device.ImmediateContext.Unmap(_staging, 0); }
        }

        private Bitmap CopyMappedBitmap(nint source, int rowPitch)
        {
            var bitmap = new Bitmap(_width, _height, PixelFormat.Format32bppArgb);
            var lockData = bitmap.LockBits(new Rectangle(0, 0, _width, _height), ImageLockMode.WriteOnly, bitmap.PixelFormat);
            try
            {
                var rowBytes = _width * 4;
                var pixels = new byte[rowBytes * _height];
                for (var row = 0; row < _height; row++)
                    Marshal.Copy(source + row * rowPitch, pixels, row * rowBytes, rowBytes);
                Marshal.Copy(pixels, 0, lockData.Scan0, pixels.Length);
                return bitmap;
            }
            catch
            {
                bitmap.Dispose();
                throw;
            }
            finally { bitmap.UnlockBits(lockData); }
        }

        public void Dispose()
        {
            _staging.Dispose();
            _duplication.Dispose();
            _device.Dispose();
            _output.Dispose();
            _adapter.Dispose();
            _factory.Dispose();
        }
    }

    private static class Native
    {
        [DllImport("user32.dll")] public static extern nint OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll")] public static extern bool CloseDesktop(nint desktop);
    }
}
