using System.Security.Cryptography;
using System.Text.Json;
using VibeWalkie.Companion.Input;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion;

public sealed class ConfigurationStore
{
    private static readonly HashSet<string> ControlZones = new(StringComparer.Ordinal)
    {
        "upper_left", "lower_left", "upper_right", "lower_right",
        "bottom_left", "bottom_center", "bottom_right",
    };
    private readonly string _path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VibeWalkie", "configuration.dpapi");
    private readonly HostShortcutStore _shortcuts;
    private ControlConfiguration _configuration;

    public ConfigurationStore(HostShortcutStore shortcuts)
    {
        _shortcuts = shortcuts;
        var stored = Load();
        // The first Windows preview stored an empty global palette at revision
        // zero. Upgrade that known default without overwriting a user's later
        // deliberate empty palette.
        _configuration = stored is { Revision: 0 } && stored.GlobalButtons.Count == 0
            ? DefaultConfiguration()
            : stored ?? DefaultConfiguration();
        // Explicitly empty or customized palettes are user choices.
        // Defaults are installed only for the known revision-zero migration.
    }

    public ControlConfiguration Current => _configuration with { AvailableShortcuts = _shortcuts.References };

    public void Update(ControlConfiguration requested)
    {
        if (requested.Buttons.Count != ControlZones.Count || requested.Buttons.Any(button => !ControlZones.Contains(button.Zone))
            || requested.Buttons.Select(static button => button.Zone).Distinct(StringComparer.Ordinal).Count() != ControlZones.Count)
            throw new ProtocolException(RemoteErrorCode.UnsupportedCapability, "Disposition des commandes invalide");
        if (requested.GlobalButtons.Count > 32 || requested.GlobalButtons.Any(button => string.IsNullOrWhiteSpace(button.ID) || button.ID.Length > 80)
            || requested.GlobalButtons.Select(static button => button.ID).Distinct(StringComparer.Ordinal).Count() != requested.GlobalButtons.Count)
            throw new ProtocolException(RemoteErrorCode.UnsupportedCapability, "Palette globale invalide");
        var references = _shortcuts.References.ToDictionary(static value => value.ID, StringComparer.Ordinal);
        foreach (var button in requested.Buttons)
            ValidatePresentation(button.Title, button.Icon);
        foreach (var button in requested.GlobalButtons)
            ValidatePresentation(button.Title, button.Icon);
        var buttons = requested.Buttons.Select(button => button with { Action = ValidateAction(button.Action, references) }).ToArray();
        var globalButtons = requested.GlobalButtons.Select(button => button with { Action = ValidateAction(button.Action, references) }).ToArray();
        var next = requested with
        {
            Buttons = buttons,
            GlobalButtons = globalButtons,
            Revision = Math.Max(_configuration.Revision + 1, requested.Revision),
            UpdatedAt = DateTimeOffset.UtcNow,
            AvailableShortcuts = null,
        };
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var clear = CanonicalJson.SerializeToUtf8Bytes(next);
        var temporary = _path + ".tmp";
        File.WriteAllBytes(temporary, ProtectedData.Protect(clear, null, DataProtectionScope.CurrentUser));
        File.Move(temporary, _path, overwrite: true);
        _configuration = next;
    }

    private static ControlButtonAction ValidateAction(
        ControlButtonAction action,
        IReadOnlyDictionary<string, HostShortcutReference> references)
    {
        return action.Type switch
        {
            "standard_key" when action.Key is { } key && Enum.IsDefined(key) => action with { Shortcut = null },
            "host_shortcut" when action.Shortcut is not null && references.TryGetValue(action.Shortcut.ID, out var reference) =>
                action with { Key = null, Shortcut = reference },
            "show_keyboard" => new ControlButtonAction("show_keyboard"),
            "none" => new ControlButtonAction("none"),
            _ => throw new ProtocolException(RemoteErrorCode.UnsupportedCapability, "Action de commande non prise en charge"),
        };
    }

    private static void ValidatePresentation(string title, JsonElement icon)
    {
        if (title is null || title.Length > 80 || icon.ValueKind != JsonValueKind.Object)
            throw new ProtocolException(RemoteErrorCode.ProtocolMismatch);
        if (icon.TryGetProperty("system", out var system) && system.TryGetProperty("_0", out var name)
            && name.ValueKind == JsonValueKind.String && name.GetString() is { Length: > 0 and <= 128 }) return;
        if (icon.TryGetProperty("customImage", out var image) && image.TryGetProperty("_0", out var encoded)
            && encoded.ValueKind == JsonValueKind.String)
        {
            try { if (Convert.FromBase64String(encoded.GetString()!).Length <= 65_536) return; }
            catch (FormatException) { }
        }
        throw new ProtocolException(RemoteErrorCode.ProtocolMismatch);
    }
    private ControlConfiguration? Load()
    {
        try
        {
            if (!File.Exists(_path)) return null;
            var clear = ProtectedData.Unprotect(File.ReadAllBytes(_path), null, DataProtectionScope.CurrentUser);
            return CanonicalJson.Deserialize<ControlConfiguration>(clear);
        }
        catch (Exception error)
        {
            LocalDiagnostics.Record("configuration_corrupt", error);
            throw new ProtocolException(RemoteErrorCode.InvalidControlConfiguration, "La configuration enregistrée est illisible. Restaurez configuration.dpapi ou réinitialisez les commandes dans le compagnon.");
        }
    }

    /// Même disposition initiale que le compagnon Mac : sept zones autour du
    /// PTT. Seules des actions abstraites traversent le réseau.
    private static ControlConfiguration DefaultConfiguration() => new(
        [
            Button("upper_left", "Suivant", "arrow.right.to.line", RemoteKey.NextConversation),
            new ControlButtonConfiguration("lower_left", "Clavier", SystemIcon("keyboard"), new ControlButtonAction("show_keyboard")),
            Button("upper_right", "App précédente", "arrow.left.arrow.right", RemoteKey.ApplicationSwitcher),
            Button("lower_right", "Entrée", "return", RemoteKey.Enter),
            Button("bottom_left", "Effacer", "delete.left", RemoteKey.Backspace),
            Button("bottom_center", "Espace", "space", RemoteKey.Space),
            Button("bottom_right", "Tabulation", "arrow.right.to.line.compact", RemoteKey.Tab),
        ],
        [
            GlobalButton("standard.next", "Suivant", "arrow.right.to.line", new ControlButtonAction("standard_key", RemoteKey.NextConversation)),
            GlobalButton("standard.keyboard", "Clavier", "keyboard", new ControlButtonAction("show_keyboard")),
            GlobalButton("standard.switcher", "App précédente", "arrow.left.arrow.right", new ControlButtonAction("standard_key", RemoteKey.ApplicationSwitcher)),
            GlobalButton("standard.enter", "Entrée", "return", new ControlButtonAction("standard_key", RemoteKey.Enter)),
            GlobalButton("standard.backspace", "Effacer", "delete.left", new ControlButtonAction("standard_key", RemoteKey.Backspace)),
            GlobalButton("standard.space", "Espace", "space", new ControlButtonAction("standard_key", RemoteKey.Space)),
            GlobalButton("standard.tab", "Tabulation", "arrow.right.to.line.compact", new ControlButtonAction("standard_key", RemoteKey.Tab)),
            GlobalButton("standard.escape", "Échap", "escape", new ControlButtonAction("standard_key", RemoteKey.Escape)),
            GlobalButton("standard.delete", "Supprimer", "delete.right", new ControlButtonAction("standard_key", RemoteKey.Delete)),
            GlobalButton("standard.up", "Haut", "arrow.up", new ControlButtonAction("standard_key", RemoteKey.ArrowUp)),
            GlobalButton("standard.down", "Bas", "arrow.down", new ControlButtonAction("standard_key", RemoteKey.ArrowDown)),
            GlobalButton("standard.left", "Gauche", "arrow.left", new ControlButtonAction("standard_key", RemoteKey.ArrowLeft)),
            GlobalButton("standard.right", "Droite", "arrow.right", new ControlButtonAction("standard_key", RemoteKey.ArrowRight)),
            GlobalButton("standard.copy", "Copier", "doc.on.doc", new ControlButtonAction("standard_key", RemoteKey.Copy)),
            GlobalButton("standard.select-all", "Tout sélectionner", "checkmark.square", new ControlButtonAction("standard_key", RemoteKey.SelectAll)),
            GlobalButton("standard.paste", "Coller", "doc.on.clipboard", new ControlButtonAction("standard_key", RemoteKey.Paste)),
            GlobalButton("standard.cut", "Couper", "scissors", new ControlButtonAction("standard_key", RemoteKey.Cut)),
            GlobalButton("standard.right-click", "Clic droit", "cursorarrow.click.2", new ControlButtonAction("standard_key", RemoteKey.RightClick)),
            GlobalButton("standard.close-window", "Fermer la fenêtre", "xmark.rectangle", new ControlButtonAction("standard_key", RemoteKey.CloseWindow)),
        ],
        0,
        DateTimeOffset.UnixEpoch);

    private static ControlConfiguration InstallingBuiltInButtons(ControlConfiguration configuration)
    {
        var buttons = configuration.GlobalButtons.ToList();
        foreach (var builtIn in DefaultConfiguration().GlobalButtons)
            if (buttons.All(button => !string.Equals(button.ID, builtIn.ID, StringComparison.Ordinal)))
                buttons.Add(builtIn);
        return configuration with { GlobalButtons = buttons };
    }

    private static ControlButtonConfiguration Button(string zone, string title, string icon, RemoteKey key) => new(
        zone,
        title,
        SystemIcon(icon),
        new ControlButtonAction("standard_key", key));

    private static GlobalButtonConfiguration GlobalButton(string id, string title, string icon, ControlButtonAction action) =>
        new(id, title, SystemIcon(icon), action);

    // Forme Codable synthétisée de ControlButtonIcon.system côté Swift.
    private static JsonElement SystemIcon(string icon) =>
        JsonDocument.Parse("{\"system\":{\"_0\":" + JsonSerializer.Serialize(icon) + "}}").RootElement.Clone();
}
