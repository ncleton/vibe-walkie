using System.Runtime.InteropServices;
using System.Text;
using VibeWalkie.Protocol;

namespace VibeWalkie.Companion.Input;

public sealed class InputService
{
    private readonly object _lock = new();
    private readonly RelativePointerIntegrator _pointer = new();
    private bool _dragging;
    private double _horizontalScroll, _verticalScroll;
    public bool IsAvailable => Native.InputDesktopAvailable();
    public void EnsureAvailable()
    {
        if (!IsAvailable) throw new ProtocolException(RemoteErrorCode.InputUnavailable);
    }

    public InsertionResult InsertText(string text, TargetCaptureService.TargetRecord target)
    {
        lock (_lock)
        {
            EnsureAvailable();
            target.VerifyUnchanged();
            var expected = target.Snapshot.ReplacingSelection(text);
            TypeUnicode(text);
            for (var attempt = 0; attempt < 40; attempt++)
            {
                if (TextSelectionSnapshot.Normalize(TargetCaptureService.ReadText(target.Element).Text) == expected)
                    return new InsertionResult(InsertionMethod.UnicodeEvents, true, null, target.ApplicationName);
                Thread.Sleep(25);
            }
            // Never retry through paste: SendInput may already have inserted
            // some or all of the text. The single-use token prevents duplicates.
            throw new ProtocolException(RemoteErrorCode.InputUnavailable,
                "Windows a reçu la saisie mais le champ ne confirme pas son contenu. Vérifiez le texte avant une nouvelle dictée.");
        }
    }

    public InsertionResult TypeManually(string text, bool userInitiated)
    {
        if (!userInitiated) throw new ProtocolException(RemoteErrorCode.InputUnavailable);
        if (text.Length > 512) throw new ProtocolException(RemoteErrorCode.PayloadTooLarge);
        TypeUnicode(text);
        return new InsertionResult(InsertionMethod.UnicodeEvents, false, null, "Application active");
    }

    public void Press(RemoteKey key, int repeatCount = 1)
    {
        lock (_lock)
        {
            if (key == RemoteKey.RightClick)
            {
                Click(PointerButton.Right, 1);
                return;
            }
            repeatCount = Math.Clamp(repeatCount, 1, 32);
            var (virtualKey, modifiers) = key switch
            {
                RemoteKey.Enter => ((ushort)0x0D, Array.Empty<ushort>()),
                RemoteKey.Escape => ((ushort)0x1B, []),
                RemoteKey.Tab => ((ushort)0x09, []),
                RemoteKey.Backspace => ((ushort)0x08, []),
                RemoteKey.Delete => ((ushort)0x2E, []),
                RemoteKey.ArrowUp => ((ushort)0x26, []),
                RemoteKey.ArrowDown => ((ushort)0x28, []),
                RemoteKey.ArrowLeft => ((ushort)0x25, []),
                RemoteKey.ArrowRight => ((ushort)0x27, []),
                RemoteKey.Space => ((ushort)0x20, []),
                RemoteKey.Copy => ((ushort)'C', [(ushort)0x11]),
                RemoteKey.Paste => ((ushort)'V', [(ushort)0x11]),
                RemoteKey.Cut => ((ushort)'X', [(ushort)0x11]),
                RemoteKey.SelectAll => ((ushort)'A', [(ushort)0x11]),
                RemoteKey.ApplicationSwitcher => ((ushort)0x09, [(ushort)0x12]),
                RemoteKey.NextConversation => ((ushort)0x09, [(ushort)0x11]),
                RemoteKey.CloseWindow => ((ushort)0x73, [(ushort)0x12]),
                _ => throw new ProtocolException(RemoteErrorCode.UnsupportedCapability),
            };
            try
            {
                foreach (var modifier in modifiers) SendVirtualKey(modifier, keyUp: false);
                for (var index = 0; index < repeatCount; index++)
                {
                    SendVirtualKey(virtualKey, keyUp: false);
                    SendVirtualKey(virtualKey, keyUp: true);
                }
            }
            finally
            {
                foreach (var modifier in modifiers.Reverse()) SendVirtualKey(modifier, keyUp: true);
            }
        }
    }

    public void PressCombination(ushort key, ushort[] modifiers)
    {
        lock (_lock)
        {
            try
            {
                foreach (var modifier in modifiers) SendVirtualKey(modifier, false);
                SendVirtualKey(key, false); SendVirtualKey(key, true);
            }
            finally { foreach (var modifier in modifiers.Reverse()) SendVirtualKey(modifier, true); }
        }
    }

    public void PointerMove(double x, double y)
    {
        lock (_lock)
        {
            EnsureAvailable();
            if (!Native.GetCursorPos(out var point)) throw new ProtocolException(RemoteErrorCode.InputUnavailable);
            var delta = _pointer.Integrate(x, y);
            if (!Native.SetCursorPos(point.X + delta.X, point.Y + delta.Y))
                throw new ProtocolException(RemoteErrorCode.InputUnavailable);
        }
    }

    public void PointerAbsolute(double normalizedX, double normalizedY)
    {
        lock (_lock)
        {
            EnsureAvailable();
            _pointer.Reset();
            var x = (int)Math.Round(InputControlPolicy.NormalizedCoordinate(normalizedX) * (Native.GetSystemMetrics(0) - 1));
            var y = (int)Math.Round(InputControlPolicy.NormalizedCoordinate(normalizedY) * (Native.GetSystemMetrics(1) - 1));
            if (!Native.SetCursorPos(x, y)) throw new ProtocolException(RemoteErrorCode.InputUnavailable);
        }
    }

    public void Drag(DragPhase phase, double x, double y)
    {
        lock (_lock)
        {
            switch (phase)
            {
                case DragPhase.Began:
                    if (_dragging) throw new ProtocolException(RemoteErrorCode.ProtocolMismatch);
                    Send([Native.Input.Mouse(0, 0, 0x0002)]); _dragging = true; break;
                case DragPhase.Moved:
                    if (!_dragging) throw new ProtocolException(RemoteErrorCode.ProtocolMismatch);
                    PointerMove(x, y); break;
                case DragPhase.Ended: ReleaseInputs(); break;
            }
        }
    }

    public void ReleaseInputs()
    {
        lock (_lock)
        {
            if (_dragging)
            {
                _dragging = false;
                // Release even if the session has just been locked; never
                // carry a remote drag into the next controller's session.
                Native.SendInput(1, [Native.Input.Mouse(0, 0, 0x0004)], Marshal.SizeOf<Native.Input>());
            }
            _pointer.Reset();
            _horizontalScroll = _verticalScroll = 0;
        }
    }

    public void Scroll(double x, double y, bool zoom = false)
    {
        lock (_lock)
        {
            if (zoom) SendVirtualKey(0x11, false);
            try
            {
                _horizontalScroll += x * 10;
                _verticalScroll -= y * 10;
                var horizontal = (int)_horizontalScroll;
                var vertical = (int)_verticalScroll;
                _horizontalScroll -= horizontal; _verticalScroll -= vertical;
                if (vertical != 0) Send([Native.Input.Mouse(0, 0, 0x0800, unchecked((uint)vertical))]);
                if (horizontal != 0) Send([Native.Input.Mouse(0, 0, 0x01000, unchecked((uint)horizontal))]);
            }
            finally { if (zoom) SendVirtualKey(0x11, true); }
        }
    }

    public void Click(PointerButton button, int count)
    {
        var flags = button == PointerButton.Left ? (0x0002u, 0x0004u) : (0x0008u, 0x0010u);
        var inputs = Enumerable.Range(0, Math.Clamp(count, 1, 3))
            .SelectMany(_ => new[] { Native.Input.Mouse(0, 0, flags.Item1), Native.Input.Mouse(0, 0, flags.Item2) }).ToArray();
        Send(inputs);
    }

    private static void TypeUnicode(string text)
    {
        if (text.Length > ProtocolLimits.MaxTextLength) throw new ProtocolException(RemoteErrorCode.PayloadTooLarge);
        if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => (Native.GetAsyncKeyState(key) & 0x8000) != 0))
            throw new ProtocolException(RemoteErrorCode.InputUnavailable, "Relâchez les touches de modification sur le clavier Windows.");
        var events = new List<Native.Input>();
        foreach (var character in TextSelectionSnapshot.Normalize(text))
        {
            if (character == '\n')
                events.AddRange([Native.Input.Key(0x0D, false), Native.Input.Key(0x0D, true)]);
            else
                events.AddRange([Native.Input.Unicode(character, false), Native.Input.Unicode(character, true)]);
        }
        if (events.Count > 0) Send(events.ToArray());
    }

    private static void SendVirtualKey(ushort key, bool keyUp) => Send([Native.Input.Key(key, keyUp)]);

    private static void Send(Native.Input[] inputs)
    {
        if (!Native.InputDesktopAvailable()) throw new ProtocolException(RemoteErrorCode.InputUnavailable);
        if (Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.Input>()) != inputs.Length)
            throw new ProtocolException(RemoteErrorCode.InputUnavailable);
    }

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct Input
        {
            public uint Type;
            public InputUnion Value;
            public static Input Key(ushort key, bool up) => new() { Type = 1, Value = new InputUnion { Keyboard = new KeyboardInput { VirtualKey = key, Flags = up ? 0x0002u : 0 } } };
            public static Input Unicode(char value, bool up) => new() { Type = 1, Value = new InputUnion { Keyboard = new KeyboardInput { ScanCode = value, Flags = 0x0004u | (up ? 0x0002u : 0) } } };
            public static Input Mouse(int x, int y, uint flags, uint data = 0) => new() { Type = 0, Value = new InputUnion { Mouse = new MouseInput { X = x, Y = y, Flags = flags, MouseData = data } } };
        }
        [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public MouseInput Mouse; [FieldOffset(0)] public KeyboardInput Keyboard; }
        [StructLayout(LayoutKind.Sequential)] public struct MouseInput { public int X; public int Y; public uint MouseData; public uint Flags; public uint Time; public nint ExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] public struct KeyboardInput { public ushort VirtualKey; public ushort ScanCode; public uint Flags; public uint Time; public nint ExtraInfo; }
        [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint count, Input[] inputs, int size);
        [DllImport("user32.dll")] private static extern nint OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseDesktop(nint desktop);

        [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetUserObjectInformation(nint handle, int index, StringBuilder name, int length, out uint required);

        public static bool InputDesktopAvailable()
        {
            var desktop = OpenInputDesktop(0, false, 0x0100 /* DESKTOP_SWITCHDESKTOP */);
            if (desktop == 0) return false;
            try
            {
                var name = new StringBuilder(256);
                return GetUserObjectInformation(desktop, 2, name, 512, out _) && name.ToString().Equals("Default", StringComparison.OrdinalIgnoreCase);
            }
            finally { _ = CloseDesktop(desktop); }
        }
    }

}
