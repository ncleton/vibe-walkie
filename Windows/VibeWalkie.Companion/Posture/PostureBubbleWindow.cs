using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using System.Runtime.InteropServices.WindowsRuntime;

namespace VibeWalkie.Companion.Posture;

/// Compact always-visible view of the real local camera and calibrated pose.
public sealed class PostureBubbleWindow : Window
{
    private readonly PostureCoachService _coach;
    private readonly Image _image = new() { Stretch = Stretch.UniformToFill };
    private readonly Canvas _overlay = new() { IsHitTestVisible = false };
    private readonly TextBlock _status = new() { Text = "Démarrez le coach depuis Vibe Walkie.", TextWrapping = TextWrapping.Wrap };
    private PosturePresentation? _latest;
    public PostureBubbleWindow(PostureCoachService coach)
    {
        _coach = coach; Title = "Vibe Walkie — posture";
        var root = new StackPanel { Spacing = 10, Padding = new Thickness(12), RequestedTheme = ElementTheme.Dark };
        var preview = new Grid { Height = 240 }; preview.Children.Add(_image); preview.Children.Add(_overlay);
        root.Children.Add(preview); root.Children.Add(_status);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var calibrate = new Button { Content = "Bonne posture" }; calibrate.Click += (_, _) => coach.Calibrate(false);
        var lean = new Button { Content = "Posture penchée" }; lean.Click += (_, _) => coach.Calibrate(true);
        controls.Children.Add(calibrate); controls.Children.Add(lean); root.Children.Add(controls); Content = root;
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(handle));
        appWindow.Resize(new global::Windows.Graphics.SizeInt32(360, 390));
        var presenter = OverlappedPresenter.Create(); presenter.IsAlwaysOnTop = true; presenter.IsResizable = false;
        presenter.IsMaximizable = false; appWindow.SetPresenter(presenter);
        _coach.Changed += OnChanged; _coach.Failed += OnFailed;
        _overlay.SizeChanged += (_, _) => Draw();
        Closed += (_, _) => { _coach.Changed -= OnChanged; _coach.Failed -= OnFailed; };
    }
    private void OnChanged(PosturePresentation presentation, byte[] preview) => DispatcherQueue.TryEnqueue(async () =>
    {
        _latest = presentation;
        using var stream = new MemoryStream(preview); var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream.AsRandomAccessStream()); _image.Source = bitmap;
        _status.Text = presentation.Severity switch
        {
            0 => "Suivi indisponible : ajustez le cadrage ou l’éclairage.",
            2 => "Redressez doucement votre posture.",
            3 => "Corrigez votre posture.",
            _ => presentation.Activity == "walking" ? "Marche détectée · posture suivie" : "Posture suivie"
        };
        if (presentation.Phase.StartsWith("calibrating", StringComparison.Ordinal)) _status.Text = $"Calibration : {presentation.Progress:P0}";
        Draw();
    });
    private void OnFailed(string detail) => DispatcherQueue.TryEnqueue(() => { _status.Text = detail; _image.Source = null; _overlay.Children.Clear(); });
    private void Draw()
    {
        _overlay.Children.Clear(); if (_latest is not { } presentation) return;
        var width = _overlay.ActualWidth; var height = _overlay.ActualHeight; if (width <= 0 || height <= 0) return;
        var scale = Math.Max(width / presentation.FrameWidth, height / presentation.FrameHeight);
        var originX = (width - presentation.FrameWidth * scale) / 2; var originY = (height - presentation.FrameHeight * scale) / 2;
        var links = new[] { ("leftShoulder", "rightShoulder"), ("neck", "nose"), ("leftShoulder", "leftHip"), ("rightShoulder", "rightHip"), ("leftHip", "rightHip"), ("leftShoulder", "leftElbow"), ("rightShoulder", "rightElbow"), ("leftHip", "leftKnee"), ("rightHip", "rightKnee"), ("leftKnee", "leftAnkle"), ("rightKnee", "rightAnkle") };
        void Pose(IReadOnlyDictionary<string, double[]>? points, global::Windows.UI.Color color, double opacity)
        {
            if (points is null) return;
            foreach (var (from, to) in links)
            {
                if (!points.TryGetValue(from, out var a) || !points.TryGetValue(to, out var b) || a.Length != 3 || b.Length != 3 || a[2] < .4 || b[2] < .4) continue;
                _overlay.Children.Add(new Line
                {
                    X1 = originX + (1 - a[0]) * presentation.FrameWidth * scale, Y1 = originY + (1 - a[1]) * presentation.FrameHeight * scale,
                    X2 = originX + (1 - b[0]) * presentation.FrameWidth * scale, Y2 = originY + (1 - b[1]) * presentation.FrameHeight * scale,
                    Stroke = new SolidColorBrush(color), StrokeThickness = 3, Opacity = opacity
                });
            }
        }
        Pose(presentation.GhostPoints, Colors.White, .45);
        Pose(presentation.CurrentPoints, presentation.Severity >= 3 ? Colors.OrangeRed : presentation.Severity == 2 ? Colors.Gold : Colors.LightGreen, .9);
    }
}
