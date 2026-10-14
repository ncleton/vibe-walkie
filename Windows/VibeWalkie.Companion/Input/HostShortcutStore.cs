using System.Security.Cryptography;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Input;

public sealed record HostShortcutDefinition(string ID, uint KeyCode, IReadOnlyList<string> Modifiers, string DisplayName)
{
    public HostShortcutReference Reference => new(ID, DisplayName, "command");
}

public sealed class HostShortcutStore
{
    /// Commande système partagée avec le compagnon Mac : touche média
    /// Lecture/Pause, routée par Windows vers le lecteur actif (YouTube, Spotify…).
    public const string MediaPlayPauseID = "mac.media.play_pause";
    private const ushort MediaPlayPauseVirtualKey = 0xB3; // VK_MEDIA_PLAY_PAUSE
    private static readonly HostShortcutReference MediaPlayPauseReference = new(MediaPlayPauseID, "Play / Pause", "playpause.fill");

    private readonly string _path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VibeWalkie", "shortcuts.dpapi");
    private readonly object _lock = new();
    private List<HostShortcutDefinition> _definitions;

    public HostShortcutStore() => _definitions = Load();
    public IReadOnlyList<HostShortcutReference> References { get { lock (_lock) return [.. _definitions.Select(static value => value.Reference), MediaPlayPauseReference]; } }
    public IReadOnlyList<HostShortcutDefinition> Definitions { get { lock (_lock) return _definitions.ToArray(); } }

    public void Execute(string id, InputService input)
    {
        input.EnsureAvailable();
        if (id == MediaPlayPauseID)
        {
            RawShortcut.Send(MediaPlayPauseVirtualKey, []);
            return;
        }
        HostShortcutDefinition definition;
        lock (_lock) definition = _definitions.SingleOrDefault(value => value.ID == id)
            ?? throw new ProtocolException(RemoteErrorCode.UnsupportedCapability, "Raccourci inconnu");
        var modifiers = definition.Modifiers.Select(static value => value switch
        {
            "control" => (ushort)0x11,
            "alt" => (ushort)0x12,
            "shift" => (ushort)0x10,
            "windows" => (ushort)0x5B,
            _ => throw new ProtocolException(RemoteErrorCode.UnsupportedCapability),
        }).ToArray();
        RawShortcut.Send((ushort)definition.KeyCode, modifiers);
    }

    public void Upsert(HostShortcutDefinition definition)
    {
        if (string.IsNullOrWhiteSpace(definition.ID) || definition.ID.Length > 96 || definition.KeyCode > ushort.MaxValue)
            throw new ArgumentException("Invalid shortcut");
        lock (_lock)
        {
            _definitions.RemoveAll(value => value.ID == definition.ID);
            _definitions.Add(definition with { DisplayName = definition.DisplayName[..Math.Min(40, definition.DisplayName.Length)] });
            Save();
        }
    }

    public void Remove(string id)
    {
        lock (_lock)
        {
            _definitions.RemoveAll(value => value.ID == id);
            Save();
        }
    }

    private List<HostShortcutDefinition> Load()
    {
        try
        {
            if (!File.Exists(_path)) return [];
            var clear = ProtectedData.Unprotect(File.ReadAllBytes(_path), null, DataProtectionScope.CurrentUser);
            return CanonicalJson.Deserialize<List<HostShortcutDefinition>>(clear);
        }
        catch (Exception error)
        {
            LocalDiagnostics.Record("shortcuts_corrupt", error);
            throw new ProtocolException(RemoteErrorCode.InvalidControlConfiguration, "Les raccourcis enregistrés sont illisibles. Restaurez shortcuts.dpapi avant de relancer le compagnon.");
        }
    }
    private void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var clear = CanonicalJson.SerializeToUtf8Bytes(_definitions);
        File.WriteAllBytes(_path, ProtectedData.Protect(clear, null, DataProtectionScope.CurrentUser));
    }

    private static class RawShortcut
    {
        public static void Send(ushort key, ushort[] modifiers)
        {
            // Même invariant que les actions standards : tous les modificateurs
            // sont relâchés, y compris si SendInput échoue en cours de route.
            var events = new List<InputEvent>();
            events.AddRange(modifiers.Select(value => InputEvent.Key(value, false)));
            events.Add(InputEvent.Key(key, false));
            events.Add(InputEvent.Key(key, true));
            events.AddRange(modifiers.Reverse().Select(value => InputEvent.Key(value, true)));
            if (SendInput((uint)events.Count, events.ToArray(), System.Runtime.InteropServices.Marshal.SizeOf<InputEvent>()) != events.Count)
            {
                foreach (var modifier in modifiers.Reverse()) _ = SendInput(1, [InputEvent.Key(modifier, true)], System.Runtime.InteropServices.Marshal.SizeOf<InputEvent>());
                throw new ProtocolException(RemoteErrorCode.InputUnavailable);
            }
        }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct InputEvent
        {
            public uint Type;
            public InputUnion Value;
            public static InputEvent Key(ushort value, bool up) => new() { Type = 1, Value = new InputUnion { Keyboard = new KeyboardInput { VirtualKey = value, Flags = up ? 2u : 0 } } };
        }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit)] private struct InputUnion { [System.Runtime.InteropServices.FieldOffset(0)] public KeyboardInput Keyboard; }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] private struct KeyboardInput { public ushort VirtualKey; public ushort ScanCode; public uint Flags; public uint Time; public nint Extra; }
        [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint SendInput(uint count, InputEvent[] inputs, int size);
    }
}
