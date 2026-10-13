using System.Diagnostics;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Interop.UIAutomationClient;
using Microsoft.Win32;
using VibeWalkie.Companion.Input;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.VoiceActions;

/// Jev chooses only identifiers from the current, bounded local observation.
/// It never supplies code, paths, URLs, text or arbitrary hardware key codes.
public sealed class VoiceActionsService(InputService input)
{
    private readonly SemaphoreSlim _serial = new(1, 1);
    private readonly Dictionary<Guid, (Guid Command, string Text, DateTimeOffset Expires)> _confirmations = [];
    private readonly Dictionary<Guid, VoiceActionResult> _completed = [];
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(30) };
    private static string KeyPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VibeWalkie", "voice-actions-key.dpapi");
    private sealed record Candidate(IUIAutomationElement Element, int[] Runtime, string Label, IReadOnlySet<string> Actions);
    private sealed record ApplicationCandidate(string Name, string Path);
    private sealed record ShortcutCandidate(ushort Key, ushort[] Modifiers, string Description);
    private sealed record CoordinateCandidate(int X, int Y);
    private sealed record Observation(nint Window, int ProcessID, Dictionary<string, Candidate> Elements, string Description);
    private static readonly string[] ActionNames = ["complete", "open_app", "click_element", "double_click_element", "right_click_element", "hover_element", "drag_element", "focus_element", "type_text", "set_element_value", "open_resource", "upload_file", "press_key", "press_shortcut", "scroll", "increment_element", "decrement_element", "perform_accessibility_action", "window_layout", "browser", "click_coordinate", "double_click_coordinate", "right_click_coordinate", "hover_coordinate", "drag_coordinate", "wait"];

    public async Task ValidateAndSaveKeyAsync(string key)
    {
        key = key.Trim();
        if (key.Length is < 1 or > 1024) throw new InvalidOperationException("Saisissez une clé TypeSafe ou OpenRouter valide.");
        _ = await DecideAsync(key, "Vérification de la connexion Jev pour Vibe Walkie.", new { ready = Choice("Confirmer la disponibilité", new Dictionary<string, string> { ["ready"] = "Prêt" }) });
        Directory.CreateDirectory(Path.GetDirectoryName(KeyPath)!);
        File.WriteAllBytes(KeyPath, ProtectedData.Protect(Encoding.UTF8.GetBytes(key), null, DataProtectionScope.CurrentUser));
    }
    public void RemoveKey() { if (File.Exists(KeyPath)) File.Delete(KeyPath); }
    private static string? LoadKey() => File.Exists(KeyPath)
        ? Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(KeyPath), null, DataProtectionScope.CurrentUser)) : null;

    public async Task<VoiceActionResult> ExecuteAsync(VoiceActionPayload payload)
    {
        if (string.IsNullOrWhiteSpace(payload.Text) || payload.Text.Length > 2_000 || payload.CommandID == Guid.Empty)
            throw new ProtocolException(RemoteErrorCode.ProtocolMismatch);
        await _serial.WaitAsync();
        try
        {
            if (_completed.TryGetValue(payload.CommandID, out var completed)) return completed;
            input.EnsureAvailable();
            var automation = new CUIAutomation8();
            if (automation.GetFocusedElement()?.CurrentIsPassword != 0) throw new ProtocolException(RemoteErrorCode.SecureField);
            var apps = InstalledApplications();
            // Exact local commands share the Mac's deterministic fast path.
            var simple = Regex.Match(payload.Text.Trim(), "^(?:ouvre|ouvrir|lance|lancer) (?:l[’']application |l[’']app )?([\\p{L}0-9 .-]+)$", RegexOptions.IgnoreCase);
            if (simple.Success && apps.Values.Where(app => app.Name.Equals(simple.Groups[1].Value, StringComparison.OrdinalIgnoreCase)).ToArray() is [var app])
            {
                Process.Start(new ProcessStartInfo(app.Path) { UseShellExecute = true });
                return Complete(payload.CommandID, "Application ouverte : " + app.Name);
            }
            var key = LoadKey() ?? throw new ProtocolException(RemoteErrorCode.UnsupportedCapability);
            if (payload.Confirmed)
            {
                if (payload.ConfirmationToken is not { } token || !_confirmations.Remove(token, out var pending)
                    || pending.Command != payload.CommandID || pending.Text != payload.Text || pending.Expires <= DateTimeOffset.UtcNow)
                    throw new ProtocolException(RemoteErrorCode.TargetExpired);
            }
            else
            {
                using var danger = await DecideAsync(key, payload.Text, new { destructive = Noul("La commande peut-elle supprimer/remplacer des données, envoyer/publier, acheter/payer, fermer un travail non enregistré ou modifier des droits ?") });
                if (Probability(danger, "destructive") >= .35)
                {
                    foreach (var expired in _confirmations.Where(item => item.Value.Expires <= DateTimeOffset.UtcNow).Select(item => item.Key).ToArray()) _confirmations.Remove(expired);
                    var token = Guid.NewGuid(); _confirmations[token] = (payload.CommandID, payload.Text, DateTimeOffset.UtcNow.AddSeconds(120));
                    return new VoiceActionResult("confirmation", "Cette commande nécessite votre confirmation.", true, token);
                }
            }
            var textChoices = Regex.Matches(payload.Text, "[«\"“]([^»\"”]+)[»\"”]").Select((match, index) => (ID: "text_" + index, Text: match.Groups[1].Value)).ToDictionary(value => value.ID, value => value.Text);
            var resources = Regex.Matches(payload.Text, @"https://[^\s<>\""»]+|[A-Za-z]:\\[^\r\n\""»]+")
                .Select((match, index) => (ID: "resource_" + index, Text: match.Value.TrimEnd('.', ','))).ToDictionary(value => value.ID, value => value.Text);
            var coordinates = Regex.Matches(payload.Text, @"\bx\s*[=:]\s*(\d{1,5})\s*[,; ]+y\s*[=:]\s*(\d{1,5})", RegexOptions.IgnoreCase)
                .Select((match, index) => (ID: "coordinate_" + index, Value: new CoordinateCandidate(int.Parse(match.Groups[1].Value), int.Parse(match.Groups[2].Value))))
                .Where(item => item.Value.X < GetSystemMetrics(0) && item.Value.Y < GetSystemMetrics(1)).ToDictionary(item => item.ID, item => item.Value);
            var shortcuts = ExtractShortcuts(payload.Text);
            var keys = Enum.GetValues<RemoteKey>().ToDictionary(value => CanonicalJson.Serialize(value).Trim('"'), value => value);
            var history = new List<string>(); var rejectedCompletion = 0;
            for (var step = 0; step < 32; step++)
            {
                var observation = Observe(automation);
                var elements = observation.Elements.ToDictionary(item => item.Key, item => item.Value.Label + ": " + string.Join(", ", item.Value.Actions));
                var state = "Objectif : " + payload.Text + "\nJournal : " + string.Join("\n", history) + "\nÉtat actuel : " + observation.Description
                    + "\nChoisir une prochaine action unique. Complete seulement quand tous les résultats demandés sont visibles. Ne jamais inventer un résultat.";
                using var decision = await DecideAsync(key, state, new
                {
                    action = Choice("Prochaine action Windows", ActionNames.ToDictionary(value => value, value => value)),
                    application = Choice("Application à ouvrir", apps.ToDictionary(item => item.Key, item => item.Value.Name)),
                    target = Choice("Contrôle à utiliser", elements), destination = Choice("Destination du glisser", elements),
                    text = Choice("Texte explicitement dicté", textChoices), resource = Choice("Ressource explicitement dictée", resources),
                    coordinate = Choice("Coordonnée explicitement dictée", coordinates.ToDictionary(item => item.Key, item => $"x={item.Value.X} y={item.Value.Y}")),
                    destination_coordinate = Choice("Destination explicitement dictée", coordinates.ToDictionary(item => item.Key, item => $"x={item.Value.X} y={item.Value.Y}")),
                    shortcut = Choice("Raccourci explicitement dicté", shortcuts.ToDictionary(item => item.Key, item => item.Value.Description)),
                    key = Choice("Touche nécessaire", keys.ToDictionary(item => item.Key, item => item.Key)),
                    scroll = Choice("Direction du défilement", new[] { "up", "down", "left", "right" }.ToDictionary(value => value, value => value)),
                    browser = Choice("Commande navigateur", new[] { "back", "forward", "reload", "new_tab", "close_tab", "reopen_tab", "next_tab", "previous_tab", "address_bar", "zoom_in", "zoom_out", "zoom_reset" }.ToDictionary(value => value, value => value)),
                    layout = Choice("Disposition fenêtre", new[] { "left_half", "right_half", "maximize", "minimize" }.ToDictionary(value => value, value => value))
                });
                var action = Selected(decision, "action", ActionNames);
                if (action == "complete")
                {
                    using var completion = await DecideAsync(key, state, new { complete = Noul("Tous les résultats explicitement demandés sont-ils visibles ou confirmés dans l’état courant, sans se fier uniquement aux actions tentées ?") });
                    if (Probability(completion, "complete") >= .85) return Complete(payload.CommandID, "Commande terminée et résultat vérifié.");
                    if (++rejectedCompletion >= 2) throw new ProtocolException(RemoteErrorCode.InputUnavailable);
                    continue;
                }
                if (GetForegroundWindow() != observation.Window) throw new ProtocolException(RemoteErrorCode.TargetChanged);
                var summary = ExecuteStep(action, decision, observation, apps, textChoices, resources, keys, shortcuts, coordinates);
                history.Add(summary); await Task.Delay(action is "open_app" or "open_resource" or "browser" ? 900 : 250);
            }
            throw new ProtocolException(RemoteErrorCode.InputUnavailable);
        }
        finally { _serial.Release(); }
    }
    private VoiceActionResult Complete(Guid command, string summary)
    {
        if (_completed.Count >= 128) _completed.Clear();
        return _completed[command] = new VoiceActionResult("complete", summary);
    }
    private string ExecuteStep(string action, JsonDocument decision, Observation observation,
        Dictionary<string, ApplicationCandidate> apps, Dictionary<string, string> texts, Dictionary<string, string> resources, Dictionary<string, RemoteKey> keys, Dictionary<string, ShortcutCandidate> shortcuts, Dictionary<string, CoordinateCandidate> coordinates)
    {
        Candidate Target(string question = "target")
        {
            var candidate = observation.Elements[Selected(decision, question, observation.Elements.Keys)];
            if (candidate.Element.CurrentProcessId != observation.ProcessID || !candidate.Element.GetRuntimeId().SequenceEqual(candidate.Runtime)
                || candidate.Element.CurrentIsPassword != 0 || candidate.Element.CurrentIsOffscreen != 0) throw new ProtocolException(RemoteErrorCode.TargetChanged);
            return candidate;
        }
        void MoveTo(Candidate candidate)
        {
            var rect = candidate.Element.CurrentBoundingRectangle;
            if (!SetCursorPos((rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2)) throw new ProtocolException(RemoteErrorCode.InputUnavailable);
        }
        switch (action)
        {
            case "wait": Thread.Sleep(500); break;
            case "press_shortcut":
                var shortcut = shortcuts[Selected(decision, "shortcut", shortcuts.Keys)];
                input.PressCombination(shortcut.Key, shortcut.Modifiers); break;
            case "click_coordinate":
            case "double_click_coordinate":
            case "right_click_coordinate":
            case "hover_coordinate":
            case "drag_coordinate":
                var coordinate = coordinates[Selected(decision, "coordinate", coordinates.Keys)];
                if (!SetCursorPos(coordinate.X, coordinate.Y)) throw new ProtocolException(RemoteErrorCode.InputUnavailable);
                if (action == "drag_coordinate")
                {
                    var destinationPoint = coordinates[Selected(decision, "destination_coordinate", coordinates.Keys)];
                    input.Drag(DragPhase.Began, 0, 0);
                    try { if (!SetCursorPos(destinationPoint.X, destinationPoint.Y)) throw new ProtocolException(RemoteErrorCode.InputUnavailable); }
                    finally { input.ReleaseInputs(); }
                }
                else if (action != "hover_coordinate") input.Click(action == "right_click_coordinate" ? PointerButton.Right : PointerButton.Left, action == "double_click_coordinate" ? 2 : 1);
                break;
            case "upload_file":
                var file = resources[Selected(decision, "resource", resources.Keys)];
                if (!File.Exists(file)) throw new ProtocolException(RemoteErrorCode.ApplicationNotFound);
                var chooser = Target();
                if (chooser.Element.GetCurrentPattern(UIA_PatternIds.UIA_InvokePatternId) is not IUIAutomationInvokePattern openChooser) throw new ProtocolException(RemoteErrorCode.UnsupportedCapability);
                openChooser.Invoke(); Thread.Sleep(500);
                var dialogHandle = GetForegroundWindow(); var dialogClass = new StringBuilder(256); GetClassName(dialogHandle, dialogClass, dialogClass.Capacity);
                if (dialogClass.ToString() != "#32770") throw new ProtocolException(RemoteErrorCode.NoFocusedTarget);
                input.PressCombination((ushort)'L', [0x11]); input.TypeManually(file, true); input.Press(RemoteKey.Enter); Thread.Sleep(250); input.Press(RemoteKey.Enter); break;
            case "open_app": Process.Start(new ProcessStartInfo(apps[Selected(decision, "application", apps.Keys)].Path) { UseShellExecute = true }); break;
            case "open_resource":
                var resource = resources[Selected(decision, "resource", resources.Keys)];
                if (!resource.StartsWith("https://", StringComparison.Ordinal) && !File.Exists(resource) && !Directory.Exists(resource)) throw new ProtocolException(RemoteErrorCode.ApplicationNotFound);
                Process.Start(new ProcessStartInfo(resource) { UseShellExecute = true }); break;
            case "press_key": input.Press(keys[Selected(decision, "key", keys.Keys)]); break;
            case "scroll":
                var direction = Selected(decision, "scroll", ["up", "down", "left", "right"]);
                input.Scroll(direction == "left" ? -30 : direction == "right" ? 30 : 0, direction == "up" ? -30 : direction == "down" ? 30 : 0); break;
            case "browser":
                var process = Process.GetProcessById(observation.ProcessID).ProcessName.ToLowerInvariant();
                if (process is not ("chrome" or "msedge" or "brave" or "firefox")) throw new ProtocolException(RemoteErrorCode.NoFocusedTarget);
                var browser = Selected(decision, "browser", ["back", "forward", "reload", "new_tab", "close_tab", "reopen_tab", "next_tab", "previous_tab", "address_bar", "zoom_in", "zoom_out", "zoom_reset"]);
                var combination = browser switch { "back" => (0x25, new ushort[] { 0x12 }), "forward" => (0x27, [0x12]), "reload" => (0x74, []), "new_tab" => ('T', [0x11]), "close_tab" => ('W', [0x11]), "reopen_tab" => ('T', [0x11, 0x10]), "next_tab" => (9, [0x11]), "previous_tab" => (9, [0x11, 0x10]), "address_bar" => ('L', [0x11]), "zoom_in" => (0xBB, [0x11]), "zoom_out" => (0xBD, [0x11]), _ => ('0', [0x11]) };
                input.PressCombination((ushort)combination.Item1, combination.Item2); break;
            case "window_layout":
                var layout = Selected(decision, "layout", ["left_half", "right_half", "maximize", "minimize"]);
                input.PressCombination((ushort)(layout switch { "left_half" => 0x25, "right_half" => 0x27, "maximize" => 0x26, _ => 0x28 }), [0x5B]); break;
            case "focus_element": Target().Element.SetFocus(); break;
            case "type_text":
                var field = Target(); field.Element.SetFocus();
                var targeting = new TargetCaptureService(); var token = targeting.Capture();
                try { input.InsertText(texts[Selected(decision, "text", texts.Keys)], targeting.Resolve(token.Token)); }
                finally { targeting.Consume(); } break;
            case "set_element_value":
                var target = Target(); var text = texts[Selected(decision, "text", texts.Keys)];
                if (target.Element.GetCurrentPattern(UIA_PatternIds.UIA_ValuePatternId) is not IUIAutomationValuePattern value || value.CurrentIsReadOnly != 0) throw new ProtocolException(RemoteErrorCode.AXNotSettable);
                value.SetValue(text);
                if (value.CurrentValue != text) throw new ProtocolException(RemoteErrorCode.InputUnavailable); break;
            case "click_element":
                var click = Target();
                if (click.Element.GetCurrentPattern(UIA_PatternIds.UIA_InvokePatternId) is IUIAutomationInvokePattern invoke) invoke.Invoke();
                else if (click.Element.GetCurrentPattern(UIA_PatternIds.UIA_SelectionItemPatternId) is IUIAutomationSelectionItemPattern selection) selection.Select();
                else { MoveTo(click); input.Click(PointerButton.Left, 1); } break;
            case "double_click_element": MoveTo(Target()); input.Click(PointerButton.Left, 2); break;
            case "right_click_element": MoveTo(Target()); input.Click(PointerButton.Right, 1); break;
            case "hover_element": MoveTo(Target()); break;
            case "drag_element":
                var source = Target(); var destination = Target("destination"); MoveTo(source);
                input.Drag(DragPhase.Began, 0, 0);
                try { MoveTo(destination); } finally { input.ReleaseInputs(); } break;
            case "increment_element":
            case "decrement_element":
                if (Target().Element.GetCurrentPattern(UIA_PatternIds.UIA_RangeValuePatternId) is not IUIAutomationRangeValuePattern range || range.CurrentIsReadOnly != 0) throw new ProtocolException(RemoteErrorCode.UnsupportedCapability);
                range.SetValue(Math.Clamp(range.CurrentValue + (action == "increment_element" ? 1 : -1) * range.CurrentSmallChange, range.CurrentMinimum, range.CurrentMaximum)); break;
            case "perform_accessibility_action":
                var accessible = Target();
                if (accessible.Element.GetCurrentPattern(UIA_PatternIds.UIA_TogglePatternId) is IUIAutomationTogglePattern toggle) toggle.Toggle();
                else throw new ProtocolException(RemoteErrorCode.UnsupportedCapability); break;
            default: throw new ProtocolException(RemoteErrorCode.UnsupportedCapability);
        }
        return "Étape exécutée : " + action;
    }
    private static Observation Observe(IUIAutomation automation)
    {
        var handle = GetForegroundWindow(); var root = automation.ElementFromHandle(handle);
        if (automation.GetFocusedElement()?.CurrentIsPassword != 0) throw new ProtocolException(RemoteErrorCode.SecureField);
        var elements = new Dictionary<string, Candidate>(); var queue = new Queue<(IUIAutomationElement, int)>(); queue.Enqueue((root, 0));
        var walker = automation.ControlViewWalker;
        for (var visited = 0; queue.Count > 0 && visited < 6_000 && elements.Count < 240; visited++)
        {
            var (element, depth) = queue.Dequeue();
            if (element.CurrentIsPassword != 0 || element.CurrentIsOffscreen != 0) continue;
            var label = element.CurrentName;
            if (label.Length is > 0 and <= 300 && element.CurrentIsEnabled != 0)
            {
                var actions = new HashSet<string> { "focus" };
                if (element.GetCurrentPattern(UIA_PatternIds.UIA_InvokePatternId) is IUIAutomationInvokePattern) actions.Add("invoke");
                if (element.GetCurrentPattern(UIA_PatternIds.UIA_ValuePatternId) is IUIAutomationValuePattern value && value.CurrentIsReadOnly == 0) actions.Add("fill");
                elements["element_" + elements.Count] = new Candidate(element, element.GetRuntimeId(), label, actions);
            }
            if (depth >= 32) continue;
            for (var child = walker.GetFirstChildElement(element); child is not null; child = walker.GetNextSiblingElement(child)) queue.Enqueue((child, depth + 1));
        }
        return new Observation(handle, root.CurrentProcessId, elements, root.CurrentName + "\n" + string.Join("\n", elements.Select(item => item.Key + " " + item.Value.Label)));
    }
    private static Dictionary<string, ApplicationCandidate> InstalledApplications()
    {
        var apps = new Dictionary<string, ApplicationCandidate>();
        foreach (var registry in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            using var paths = registry.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths");
            if (paths is null) continue;
            foreach (var name in paths.GetSubKeyNames().Take(512))
            {
                using var item = paths.OpenSubKey(name);
                if (item?.GetValue(null) is not string path || !File.Exists(path.Trim('"'))) continue;
                path = path.Trim('"'); var product = FileVersionInfo.GetVersionInfo(path).ProductName ?? Path.GetFileNameWithoutExtension(path);
                apps["app_" + apps.Count] = new ApplicationCandidate(product, path);
            }
        }
        return apps;
    }
    private static Dictionary<string, ShortcutCandidate> ExtractShortcuts(string text)
    {
        var result = new Dictionary<string, ShortcutCandidate>();
        foreach (Match match in Regex.Matches(text, @"\b(?:Ctrl|Control|Alt|Shift|Maj|Win)(?:\s*\+\s*(?:Ctrl|Control|Alt|Shift|Maj|Win|F(?:1[0-2]|[1-9])|[A-Za-z0-9]))+\b", RegexOptions.IgnoreCase))
        {
            var parts = match.Value.Split('+', StringSplitOptions.TrimEntries); var modifiers = new List<ushort>(); ushort? key = null;
            foreach (var part in parts)
            {
                var normalized = part.ToLowerInvariant();
                if (normalized is "ctrl" or "control") modifiers.Add(0x11);
                else if (normalized is "shift" or "maj") modifiers.Add(0x10);
                else if (normalized == "alt") modifiers.Add(0x12);
                else if (normalized == "win") modifiers.Add(0x5B);
                else if (normalized.StartsWith('f') && int.TryParse(normalized[1..], out var function) && function is >= 1 and <= 12) key = (ushort)(0x6F + function);
                else if (part.Length == 1 && char.IsAsciiLetterOrDigit(part[0])) key = char.ToUpperInvariant(part[0]);
            }
            if (key is not null) result["shortcut_" + result.Count] = new ShortcutCandidate(key.Value, modifiers.Distinct().ToArray(), match.Value);
        }
        return result;
    }
    private static object Choice(string instructions, Dictionary<string, string> criteria)
    {
        var choices = new Dictionary<string, string>(criteria) { ["none"] = "Aucun choix observé et compatible" };
        return new { type = "choice", instructions, criteria = choices };
    }
    private static object Noul(string instructions) => new { type = "noul", instructions };
    private static async Task<JsonDocument> DecideAsync(string key, string state, object questions)
    {
        var openRouter = key.StartsWith("sk-or-", StringComparison.Ordinal);
        using var request = new HttpRequestMessage(HttpMethod.Post, openRouter ? "https://openrouter.ai/api/alpha/decisions" : "https://api.typesafe.ai/v1/systemone");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        request.Content = new StringContent(JsonSerializer.Serialize(new { state, model = openRouter ? "~typesafe/jev-latest" : "jev-latest", questions }), Encoding.UTF8, "application/json");
        using var response = await Client.SendAsync(request);
        if (!response.IsSuccessStatusCode) throw new ProtocolException(RemoteErrorCode.UnsupportedCapability);
        return JsonDocument.Parse(await response.Content.ReadAsStringAsync());
    }
    private static double Probability(JsonDocument decision, string question)
    {
        var number = decision.RootElement.GetProperty("answers").GetProperty(question).GetProperty("noul").GetDouble();
        if (!double.IsFinite(number) || number is < 0 or > 1) throw new ProtocolException(RemoteErrorCode.ProtocolMismatch);
        return number;
    }
    private static string Selected(JsonDocument decision, string question, IEnumerable<string> allowed)
    {
        var answer = decision.RootElement.GetProperty("answers").GetProperty(question);
        var choice = answer.GetProperty("choice").GetString();
        if (choice is null || !allowed.Contains(choice, StringComparer.Ordinal)) throw new ProtocolException(RemoteErrorCode.UnsupportedCapability);
        var probability = answer.GetProperty("probabilities").GetProperty(choice).GetDouble();
        var confidence = answer.GetProperty("confidence").GetDouble();
        if (!double.IsFinite(probability) || !double.IsFinite(confidence) || probability is < .62 or > 1 || confidence is < .5 or > 1)
            throw new ProtocolException(RemoteErrorCode.UnsupportedCapability);
        return choice;
    }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint window, StringBuilder name, int size);
}
