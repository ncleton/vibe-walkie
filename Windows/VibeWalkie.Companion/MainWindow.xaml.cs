using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Input;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Windowing;
using Microsoft.UI;
using VibeWalkie.Companion.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Microsoft.UI.Xaml.Controls;
using VibeWalkie.Protocol;
using VibeWalkie.Companion.Posture;
using VibeWalkie.Companion.Updates;
using VibeWalkie.Companion.VoiceActions;
using System.Text.Json;

namespace VibeWalkie.Companion;

public sealed partial class MainWindow : Window
{
    private CompanionRuntime? _runtime;
    private PostureBubbleWindow? _postureBubble;
    private TrayIconService? _tray;
    private uint? _shortcutKey;
    private IReadOnlyList<string> _shortcutModifiers = [];

    public MainWindow()
    {
        LocalDiagnostics.StartupStage("window_constructor");
        InitializeComponent();
        LocalDiagnostics.StartupStage("window_xaml_ready");
    }

    public void InitializeTray()
    {
        if (_tray is not null) return;
        var tray = new TrayIconService(this);
        _tray = tray;
        LocalDiagnostics.StartupStage("tray_ready");
        tray.QuitRequested += async () => await QuitAsync();
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var id = Win32Interop.GetWindowIdFromWindow(handle);
        AppWindow.GetFromWindowId(id).Closing += (_, args) =>
        {
            if (tray.ShouldCancelClose())
            {
                args.Cancel = true;
                tray.HideWindow();
            }
        };
    }

    public void Bind(CompanionRuntime runtime)
    {
        _runtime = runtime;
        SensitivityChoice.SelectedIndex = runtime.Posture.Sensitivity switch { "relaxed" => 0, "strict" => 2, _ => 1 };
        SoundSwitch.IsOn = runtime.Posture.Preferences.SoundEnabled;
        runtime.StatusChanged += status => DispatcherQueue.TryEnqueue(() =>
        {
            StatusBar.Title = status;
            StatusBar.Severity = Microsoft.UI.Xaml.Controls.InfoBarSeverity.Success;
        });
        runtime.PairingChanged += pairing => DispatcherQueue.TryEnqueue(async () =>
        {
            ConfirmationCode.Text = pairing.ConfirmationCode;
            using var stream = new MemoryStream(pairing.QrPng);
            var image = new BitmapImage();
            await image.SetSourceAsync(stream.AsRandomAccessStream());
            PairingQr.Source = image;
        });
        runtime.PendingApprovalChanged += pending => DispatcherQueue.TryEnqueue(() =>
        {
            PendingDevice.Text = pending is null ? "Aucune" : $"{pending.DeviceName} — code {pending.ConfirmationCode}";
            ApproveButton.IsEnabled = DenyButton.IsEnabled = pending is not null;
        });
        runtime.ApprovedPeersChanged += peers => DispatcherQueue.TryEnqueue(() => ApprovedPeers.ItemsSource = peers);
        runtime.ShortcutsChanged += shortcuts => DispatcherQueue.TryEnqueue(() => ShortcutsList.ItemsSource = shortcuts);
        runtime.ConfigurationChanged += configuration => DispatcherQueue.TryEnqueue(() => PopulateControls(configuration));
        runtime.Posture.Changed += (presentation, preview) => DispatcherQueue.TryEnqueue(async () =>
        {
            using var stream = new MemoryStream(preview); var image = new BitmapImage();
            await image.SetSourceAsync(stream.AsRandomAccessStream()); CameraPreview.Source = image;
            CalibrationProgress.Value = presentation.Progress;
            PostureStatus.Text = $"{PhaseLabel(presentation.Phase)} — {ViewpointLabel(presentation.Viewpoint)} — {(presentation.Activity == "walking" ? "Marche détectée" : "À l’arrêt")}"
                + (presentation.Issue is null ? "" : " — " + IssueLabel(presentation.Issue));
            if (!presentation.EnoughLight) PostureStatus.Text += " — Augmentez l’éclairage";
            if (!presentation.HasNeck) PostureStatus.Text += " — Gardez la tête et les épaules dans le cadre";
            if (presentation.Sound && runtime.Posture.Preferences.SoundEnabled) MessageBeep(0x30);
        });
        runtime.Posture.Failed += detail => DispatcherQueue.TryEnqueue(() => { PostureStatus.Text = detail; CameraPreview.Source = null; ShowFailure(detail); });
    }

    private void NewPairing_Click(object sender, RoutedEventArgs e) => _runtime?.BeginPairing();
    private void Approve_Click(object sender, RoutedEventArgs e) => _runtime?.ResolvePendingApproval(true);
    private void Deny_Click(object sender, RoutedEventArgs e) => _runtime?.ResolvePendingApproval(false);
    private void RevokePeer_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string id }) _runtime?.RevokePeer(id);
    }
    private void ShortcutKeyBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu or VirtualKey.LeftWindows or VirtualKey.RightWindows) return;
        var modifiers = new List<string>();
        if (IsPressed(VirtualKey.Control)) modifiers.Add("control");
        if (IsPressed(VirtualKey.Menu)) modifiers.Add("alt");
        if (IsPressed(VirtualKey.Shift)) modifiers.Add("shift");
        if (IsPressed(VirtualKey.LeftWindows) || IsPressed(VirtualKey.RightWindows)) modifiers.Add("windows");
        _shortcutKey = (uint)e.Key;
        _shortcutModifiers = modifiers;
        ShortcutKeyBox.Text = string.Join(" + ", modifiers.Select(static value => value switch { "control" => "Ctrl", "alt" => "Alt", "shift" => "Maj", "windows" => "Win", _ => value }).Append(e.Key.ToString()));
        e.Handled = true;
    }
    private static bool IsPressed(VirtualKey key) => (InputKeyboardSource.GetKeyStateForCurrentThread(key) & global::Windows.UI.Core.CoreVirtualKeyStates.Down) != 0;
    private void SaveShortcut_Click(object sender, RoutedEventArgs e)
    {
        var name = ShortcutNameBox.Text.Trim();
        if (_shortcutKey is null || string.IsNullOrWhiteSpace(name)) { ShowFailure("Donnez un nom et choisissez une combinaison pour ce raccourci."); return; }
        var id = "win-" + Guid.NewGuid().ToString("N");
        _runtime?.UpsertShortcut(new HostShortcutDefinition(id, _shortcutKey.Value, _shortcutModifiers, name));
        ShortcutNameBox.Text = string.Empty;
        ShortcutKeyBox.Text = string.Empty;
        _shortcutKey = null;
        _shortcutModifiers = [];
    }
    private void RemoveShortcut_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string id }) _runtime?.RemoveShortcut(id);
    }
    private async void RunDiagnostics_Click(object sender, RoutedEventArgs e)
    {
        if (_runtime is not null) DiagnosticsText.Text = await _runtime.RunDiagnosticsAsync();
    }
    private void CopyDiagnostics_Click(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage();
        package.SetText(LocalDiagnostics.ExportRedacted());
        Clipboard.SetContent(package);
        DiagnosticsText.Text = "Diagnostic expurgé copié. Il ne contient ni texte dicté, ni frappe, ni image d’écran.";
    }
    private readonly Dictionary<string, (ControlButtonConfiguration Original, TextBox Title, ComboBox Action)> _controlEditors = [];
    private readonly List<(GlobalButtonConfiguration Original, TextBox Title, ComboBox Action)> _globalEditors = [];
    private Dictionary<string, ControlButtonAction> ActionChoices()
    {
        var choices = Enum.GetValues<RemoteKey>().ToDictionary(KeyLabel, value => new ControlButtonAction("standard_key", value));
        choices["Clavier"] = new ControlButtonAction("show_keyboard"); choices["Aucune action"] = new ControlButtonAction("none");
        foreach (var shortcut in _runtime?.Configuration.AvailableShortcuts ?? []) choices[shortcut.DisplayName + " (raccourci)"] = new ControlButtonAction("host_shortcut", Shortcut: shortcut);
        return choices;
    }
    private void PopulateControls(ControlConfiguration configuration)
    {
        ControlsEditor.Children.Clear(); GlobalEditor.Children.Clear(); _controlEditors.Clear(); _globalEditors.Clear();
        var choices = ActionChoices();
        foreach (var button in configuration.Buttons)
        {
            var title = new TextBox { Text = button.Title, Header = button.Zone, MaxLength = 80 };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(title, "control-title-" + button.Zone);
            var action = new ComboBox { ItemsSource = choices.Keys.ToArray(), HorizontalAlignment = HorizontalAlignment.Stretch };
            action.SelectedItem = choices.FirstOrDefault(item => item.Value == button.Action).Key;
            var row = new StackPanel { Spacing = 4 }; row.Children.Add(title); row.Children.Add(action);
            var icon = new Button { Content = "Choisir une image" };
            icon.Click += async (_, _) =>
            {
                try { var image = await PickIconAsync(); if (image is { } selected) { var editor = _controlEditors[button.Zone]; _controlEditors[button.Zone] = (editor.Original with { Icon = selected }, editor.Title, editor.Action); } }
                catch (Exception error) { LocalDiagnostics.Record("icon_selection_failed", error); ShowFailure("Choisissez une image PNG ou JPEG valide pour cette commande."); }
            };
            row.Children.Add(icon); ControlsEditor.Children.Add(row);
            _controlEditors[button.Zone] = (button, title, action);
        }
        foreach (var button in configuration.GlobalButtons) AddGlobalEditor(button);
    }
    private void AddGlobalEditor(GlobalButtonConfiguration button)
    {
        var choices = ActionChoices(); var title = new TextBox { Text = button.Title, MaxLength = 80 };
        var action = new ComboBox { ItemsSource = choices.Keys.ToArray(), HorizontalAlignment = HorizontalAlignment.Stretch };
        action.SelectedItem = choices.FirstOrDefault(item => item.Value == button.Action).Key;
        var row = new StackPanel { Spacing = 4 }; row.Children.Add(title); row.Children.Add(action);
        var movement = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var direction in new[] { -1, 1 })
        {
            var move = new Button { Content = direction < 0 ? "Monter" : "Descendre" };
            move.Click += (_, _) =>
            {
                var index = _globalEditors.FindIndex(item => item.Original.ID == button.ID); var next = index + direction;
                if (index < 0 || next < 0 || next >= _globalEditors.Count) return;
                var editor = _globalEditors[index]; _globalEditors.RemoveAt(index); _globalEditors.Insert(next, editor);
                GlobalEditor.Children.Remove(row); GlobalEditor.Children.Insert(next, row);
            };
            movement.Children.Add(move);
        }
        var icon = new Button { Content = "Choisir une image" };
        icon.Click += async (_, _) =>
        {
            try
            {
                var image = await PickIconAsync(); var index = _globalEditors.FindIndex(item => item.Original.ID == button.ID);
                if (image is { } selected && index >= 0) { var editor = _globalEditors[index]; _globalEditors[index] = (editor.Original with { Icon = selected }, editor.Title, editor.Action); }
            }
            catch (Exception error) { LocalDiagnostics.Record("icon_selection_failed", error); ShowFailure("Choisissez une image PNG ou JPEG valide pour cette commande."); }
        };
        row.Children.Add(icon); row.Children.Add(movement);
        var remove = new Button { Content = "Supprimer cette commande" };
        remove.Click += (_, _) => { GlobalEditor.Children.Remove(row); _globalEditors.RemoveAll(item => item.Original.ID == button.ID); };
        row.Children.Add(remove); GlobalEditor.Children.Add(row); _globalEditors.Add((button, title, action));
    }
    private void AddGlobal_Click(object sender, RoutedEventArgs e)
    {
        if (_globalEditors.Count >= 32) { ShowFailure("La palette Global peut contenir jusqu’à 32 commandes."); return; }
        var icon = JsonDocument.Parse("{\"system\":{\"_0\":\"command\"}}").RootElement.Clone();
        AddGlobalEditor(new GlobalButtonConfiguration(Guid.NewGuid().ToString(), "Nouvelle commande", icon, new ControlButtonAction("none")));
    }
    private void ApplyControls_Click(object sender, RoutedEventArgs e)
    {
        if (_runtime is null) return;
        try
        {
            var choices = ActionChoices();
            var configuration = _runtime.Configuration with
            {
                Buttons = _controlEditors.Values.Select(item => item.Original with { Title = item.Title.Text, Action = choices[(string)item.Action.SelectedItem] }).ToArray(),
                GlobalButtons = _globalEditors.Select(item => item.Original with { Title = item.Title.Text, Action = choices[(string)item.Action.SelectedItem] }).ToArray()
            };
            _runtime.UpdateConfiguration(configuration);
        }
        catch (Exception error) { LocalDiagnostics.Record("configuration_edit_failed", error); ShowFailure("Choisissez une action pour chaque commande avant d’appliquer la disposition."); }
    }
    private async Task<JsonElement?> PickIconAsync()
    {
        var picker = new global::Windows.Storage.Pickers.FileOpenPicker();
        picker.FileTypeFilter.Add(".png"); picker.FileTypeFilter.Add(".jpg"); picker.FileTypeFilter.Add(".jpeg");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync(); if (file is null) return null;
        using var source = System.Drawing.Image.FromFile(file.Path);
        var scale = Math.Min(1, 128d / Math.Max(source.Width, source.Height));
        using var bitmap = new System.Drawing.Bitmap(source, new System.Drawing.Size(Math.Max(1, (int)(source.Width * scale)), Math.Max(1, (int)(source.Height * scale))));
        using var bytes = new MemoryStream(); bitmap.Save(bytes, System.Drawing.Imaging.ImageFormat.Png);
        if (bytes.Length > 65_536) throw new InvalidDataException("Image trop volumineuse.");
        return JsonSerializer.SerializeToElement(new { customImage = new { _0 = Convert.ToBase64String(bytes.ToArray()) } });
    }
    private static string KeyLabel(RemoteKey key) => key switch
    {
        RemoteKey.Enter => "Entrée", RemoteKey.Escape => "Échap", RemoteKey.Tab => "Tabulation", RemoteKey.ApplicationSwitcher => "App précédente",
        RemoteKey.NextConversation => "Suivant", RemoteKey.Backspace => "Effacer", RemoteKey.Delete => "Supprimer", RemoteKey.ArrowUp => "Haut", RemoteKey.ArrowDown => "Bas",
        RemoteKey.ArrowLeft => "Gauche", RemoteKey.ArrowRight => "Droite", RemoteKey.Space => "Espace", RemoteKey.Copy => "Copier", RemoteKey.Paste => "Coller",
        RemoteKey.Cut => "Couper", RemoteKey.SelectAll => "Tout sélectionner", RemoteKey.RightClick => "Clic droit", RemoteKey.CloseWindow => "Fermer la fenêtre", _ => throw new InvalidOperationException("Commande inconnue.")
    };
    public void ShowFromTray()
    {
        if (_tray is null) throw new InvalidOperationException("L’icône de notification Windows n’est pas initialisée. Relancez le compagnon.");
        _tray.ShowWindow(); Activate();
    }
    public void ShowFailure(string detail) { StatusBar.Title = detail; StatusBar.Severity = InfoBarSeverity.Error; StatusBar.IsOpen = true; }
    private async void RefreshCameras_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var cameras = await PostureCoachService.CamerasAsync(); CameraChoice.ItemsSource = cameras;
            var previous = _runtime?.Posture.Preferences.CameraName;
            CameraChoice.SelectedIndex = previous is null ? (cameras.Count > 0 ? 0 : -1) : cameras.ToList().IndexOf(previous);
            if (CameraChoice.SelectedIndex < 0) ShowFailure("Choisissez une caméra disponible. La caméra enregistrée est absente ou inaccessible.");
        }
        catch (Exception error) { ShowFailure(error.Message); }
    }
    private void StartPosture_Click(object sender, RoutedEventArgs e)
    {
        if (CameraChoice.SelectedIndex < 0) { ShowFailure("Actualisez les caméras puis choisissez celle à utiliser."); return; }
        if (_runtime is not null) { _runtime.Posture.SetPreferences(_runtime.Posture.Preferences with { CameraName = (string)CameraChoice.SelectedItem }); _runtime.Posture.Start(CameraChoice.SelectedIndex); }
    }
    private async void StopPosture_Click(object sender, RoutedEventArgs e)
    {
        if (_runtime is not null) await _runtime.Posture.DisposeAsync(); CameraPreview.Source = null; PostureStatus.Text = "Coach arrêté";
    }
    private void ShowPostureBubble_Click(object sender, RoutedEventArgs e)
    {
        if (_runtime is null) return;
        if (_postureBubble is null) { _postureBubble = new PostureBubbleWindow(_runtime.Posture); _postureBubble.Closed += (_, _) => _postureBubble = null; }
        _postureBubble.Activate();
    }
    private void CalibratePosture_Click(object sender, RoutedEventArgs e) => _runtime?.Posture.Calibrate(false);
    private void CalibrateLean_Click(object sender, RoutedEventArgs e) => _runtime?.Posture.Calibrate(true);
    private void Sensitivity_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_runtime is not null && SensitivityChoice.SelectedItem is ComboBoxItem { Tag: string sensitivity }) _runtime.Posture.SetPreferences(_runtime.Posture.Preferences with { Sensitivity = sensitivity });
    }
    private void Sound_Toggled(object sender, RoutedEventArgs e)
    {
        if (_runtime is not null) _runtime.Posture.SetPreferences(_runtime.Posture.Preferences with { SoundEnabled = SoundSwitch.IsOn });
    }
    private void RefreshHealth_Click(object sender, RoutedEventArgs e)
    {
        if (_runtime is null) return;
        var now = DateTimeOffset.Now;
        var sessions = _runtime.WalkingSessions.Snapshot(now.Date, now).Sessions;
        var walking = sessions.Sum(session => Math.Max(0, (session.EndedAt - (session.StartedAt < now.Date ? now.Date : session.StartedAt)).TotalMinutes));
        var health = _runtime.WalkingSessions.HealthSnapshot;
        HealthSummary.Text = $"Marche observée aujourd’hui : {walking:F0} minutes."
            + (health is null ? " Connectez l’iPhone et autorisez Santé pour obtenir le bilan des sept derniers jours." : $" Distance sur sept jours : {health.WalkingDistanceMetersLast7Days / 1000:F1} km. Travail connecté : {health.DetectedWalkingDurationLast7Days / 60:F0} minutes.");
    }
    private async void SaveVoiceKey_Click(object sender, RoutedEventArgs e)
    {
        try { await new VoiceActionsService(new InputService()).ValidateAndSaveKeyAsync(VoiceKey.Password); VoiceKey.Password = ""; StatusBar.Title = "Connexion aux Actions vocales vérifiée."; StatusBar.Severity = InfoBarSeverity.Success; }
        catch (Exception error) { LocalDiagnostics.Record("voice_key_failed", error); ShowFailure("La connexion n’a pas pu être validée. Vérifiez la clé, ses droits et votre connexion réseau."); }
    }
    private void RemoveVoiceKey_Click(object sender, RoutedEventArgs e) { new VoiceActionsService(new InputService()).RemoveKey(); VoiceKey.Password = ""; }
    private async void CheckUpdate_Click(object sender, RoutedEventArgs e)
    {
        try { if (_runtime is not null) UpdateStatus.Text = await _runtime.Updates.CheckAsync(); }
        catch (Exception error) { ShowFailure(error.Message); }
    }
    private async void InstallUpdate_Click(object sender, RoutedEventArgs e)
    {
        try { if (_runtime is not null) await _runtime.Updates.InstallAsync(); }
        catch (Exception error) { ShowFailure(error.Message); }
    }
    private bool _settingStartup;
    private async void Startup_Toggled(object sender, RoutedEventArgs e)
    {
        if (_runtime is null || _settingStartup) return;
        var requested = StartupSwitch.IsOn;
        _settingStartup = true;
        try { StartupSwitch.IsOn = await UpdateController.SetStartupAsync(requested); }
        catch (Exception error) { StartupSwitch.IsOn = !requested; ShowFailure(error.Message); }
        finally { _settingStartup = false; }
    }
    private async void Quit_Click(object sender, RoutedEventArgs e) => await QuitAsync();
    private async Task QuitAsync() { if (_runtime is not null) await _runtime.DisposeAsync(); _tray?.Dispose(); Application.Current.Exit(); }
    private static string ViewpointLabel(string viewpoint) => viewpoint switch { "front" => "Face", "profile" => "Profil", "back" => "Dos", "threeQuarter" => "Trois quarts", _ => "Angle à vérifier" };
    private static string PhaseLabel(string phase) => phase switch { "positioning" => "Ajustez le cadrage", "calibratingStatic" => "Calibration de la bonne posture", "awaitingLeanSample" => "Enregistrez votre posture penchée", "calibratingLean" => "Apprentissage de la posture penchée", "calibratingWalking" => "Calibration de la marche", "monitoring" => "Surveillance active", _ => phase };
    private static string IssueLabel(string issue) => issue switch { "neckForward" => "Cou vers l’avant", "headDown" => "Tête baissée", "headTurned" => "Tête tournée", "trunkInclined" => "Buste incliné", _ => issue };
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool MessageBeep(uint type);

}
