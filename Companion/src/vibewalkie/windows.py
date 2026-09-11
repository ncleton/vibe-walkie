"""Windows interactive-session backend using UI Automation and SendInput."""
import ctypes as C
from ctypes import wintypes as W
import hashlib
from pathlib import PureWindowsPath
import time
import comtypes
import comtypes.client

from .protocol import RemoteError, timestamp


class WindowsDesktop:
    def __init__(self):
        self.comtypes = comtypes
        # UIA calls run on one dedicated MTA thread. An STA without a message
        # pump can deadlock when an out-of-process text provider calls back.
        comtypes.CoInitializeEx(comtypes.COINIT_MULTITHREADED)
        self.uia_types = comtypes.client.GetModule("UIAutomationCore.dll")
        self.uia = comtypes.client.CreateObject("{FF48DBA4-60EF-4201-AA87-54103EEF594E}", interface=self.uia_types.IUIAutomation)
        self.user = C.WinDLL("user32", use_last_error=True)
        self.kernel = C.WinDLL("kernel32", use_last_error=True)
        self._declare_api()
        # All capture and pointer coordinates refer to physical pixels.
        self.user.SetThreadDpiAwarenessContext(C.c_void_p(-4))
        self.dragging = False
        self.scroll_remainder = [0.0, 0.0]
        self.check_ready()

    def _declare_api(self):
        declarations = {
            "GetForegroundWindow": ([], W.HWND),
            "GetWindowThreadProcessId": ([W.HWND, C.POINTER(W.DWORD)], W.DWORD),
            "GetWindowTextW": ([W.HWND, W.LPWSTR, C.c_int], C.c_int),
            "IsWindowVisible": ([W.HWND], W.BOOL), "IsIconic": ([W.HWND], W.BOOL),
            "ShowWindow": ([W.HWND, C.c_int], W.BOOL), "SetForegroundWindow": ([W.HWND], W.BOOL),
            "GetCursorPos": ([C.POINTER(W.POINT)], W.BOOL),
            "SetCursorPos": ([C.c_int, C.c_int], W.BOOL),
            "GetSystemMetrics": ([C.c_int], C.c_int),
            "OpenInputDesktop": ([W.DWORD, W.BOOL, W.DWORD], W.HANDLE),
            "CloseDesktop": ([W.HANDLE], W.BOOL),
            "GetUserObjectInformationW": ([W.HANDLE, C.c_int, W.LPVOID, W.DWORD, C.POINTER(W.DWORD)], W.BOOL),
            "SetThreadDpiAwarenessContext": ([C.c_void_p], C.c_void_p),
            "GetAsyncKeyState": ([C.c_int], C.c_short),
            "GetClassNameW": ([W.HWND, W.LPWSTR, C.c_int], C.c_int),
            "SendMessageTimeoutW": ([W.HWND, W.UINT, W.WPARAM, W.LPARAM, W.UINT, W.UINT, C.POINTER(C.c_size_t)], W.LPARAM),
        }
        for name, (args, result) in declarations.items():
            function = getattr(self.user, name)
            function.argtypes, function.restype = args, result
        self.kernel.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
        self.kernel.OpenProcess.restype = W.HANDLE
        self.kernel.CloseHandle.argtypes = [W.HANDLE]
        self.kernel.QueryFullProcessImageNameW.argtypes = [W.HANDLE, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD)]

        class Mouse(C.Structure):
            _fields_ = [("dx", W.LONG), ("dy", W.LONG), ("mouseData", W.DWORD), ("dwFlags", W.DWORD), ("time", W.DWORD), ("dwExtraInfo", C.c_size_t)]

        class Keyboard(C.Structure):
            _fields_ = [("wVk", W.WORD), ("wScan", W.WORD), ("dwFlags", W.DWORD), ("time", W.DWORD), ("dwExtraInfo", C.c_size_t)]

        class Payload(C.Union):
            _fields_ = [("mi", Mouse), ("ki", Keyboard)]

        class Input(C.Structure):
            _anonymous_ = ("payload",)
            _fields_ = [("type", W.DWORD), ("payload", Payload)]

        self.Input, self.Mouse, self.Keyboard = Input, Mouse, Keyboard
        self.user.SendInput.argtypes = [W.UINT, C.POINTER(Input), C.c_int]
        self.user.SendInput.restype = W.UINT

    def check_ready(self):
        desktop = self.user.OpenInputDesktop(0, False, 1)
        if not desktop:
            raise RemoteError("input_unavailable", "Windows is locked, showing UAC, or has no interactive desktop. Unlock the user session and reopen screen view.")
        try:
            name, size = C.create_unicode_buffer(256), W.DWORD()
            if not self.user.GetUserObjectInformationW(desktop, 2, name, C.sizeof(name), C.byref(size)) or name.value.casefold() != "default":
                raise RemoteError("input_unavailable", "Control is unavailable on the Windows secure desktop. Return to the unlocked user desktop.")
        finally:
            self.user.CloseDesktop(desktop)

    def title(self, window):
        buffer = C.create_unicode_buffer(2048)
        self.user.GetWindowTextW(window, buffer, len(buffer))
        return buffer.value

    def pid(self, window):
        pid = W.DWORD()
        self.user.GetWindowThreadProcessId(window, C.byref(pid))
        return pid.value

    def process_name(self, pid):
        handle = self.kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return None
        try:
            buffer, size = C.create_unicode_buffer(32768), W.DWORD(32768)
            if self.kernel.QueryFullProcessImageNameW(handle, 0, buffer, C.byref(size)):
                return PureWindowsPath(buffer.value).stem
            return None
        finally:
            self.kernel.CloseHandle(handle)

    def windows(self):
        self.check_ready()
        active = self.user.GetForegroundWindow()
        active_pid = self.pid(active)
        apps = {}
        callback_type = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)

        def visit(window, _):
            title = self.title(window)
            if self.user.IsWindowVisible(window) and title:
                pid = self.pid(window)
                identifier = f"win:{pid}"
                app = apps.setdefault(identifier, {"id": identifier, "name": self.process_name(pid) or title,
                    "isActive": pid == active_pid, "windows": []})
                app["windows"].append({"id": str(int(window)), "title": title, "isMain": window == active,
                                       "isMinimized": bool(self.user.IsIconic(window))})
            return len(apps) < 256

        callback = callback_type(visit)
        self.user.EnumWindows.argtypes = [callback_type, W.LPARAM]
        self.user.EnumWindows(callback, 0)
        return {"applications": list(apps.values()), "activeApplicationID": f"win:{active_pid}", "capturedAt": timestamp()}

    def activate(self, app_id, window_id):
        apps = self.windows()["applications"]
        app = next((item for item in apps if item["id"] == app_id), None)
        window = next((item for item in app["windows"] if window_id is None or item["id"] == window_id), None) if app else None
        if not window:
            raise RemoteError("application_not_found", "The selected application window no longer exists.")
        handle = int(window["id"])
        if self.user.IsIconic(handle):
            self.user.ShowWindow(handle, 9)
        self.user.SetForegroundWindow(handle)
        for _ in range(20):
            if self.user.GetForegroundWindow() == handle:
                return
            time.sleep(0.025)
        raise RemoteError("activation_denied", "Windows refused foreground activation. Select the window in the Windows desktop and retry.")

    def focus(self):
        self.check_ready()
        element = self.uia.GetFocusedElement()
        if not element:
            raise RemoteError("no_focused_target", "Click an accessible text field in Windows first.")
        if element.CurrentIsPassword:
            raise RemoteError("secure_field", "Dictation is disabled in password fields. Use the manual keyboard.")
        return element

    def text_state(self, element):
        try:
            raw = element.GetCurrentPattern(10014)
            if not raw:
                return self.native_edit_state(element)
            pattern = raw.QueryInterface(self.uia_types.IUIAutomationTextPattern)
            document = pattern.DocumentRange
            before = document.GetText(1000001)
            selected = pattern.GetSelection()
            if selected.Length != 1 or len(before) > 1000000:
                raise RemoteError("ax_not_settable", "This field does not expose one editable selection. Choose a standard text field.")
            selection = selected.GetElement(0)
            prefix = document.Clone()
            prefix.MoveEndpointByRange(1, selection, 0)
            start = len(prefix.GetText(-1))
            end = start + len(selection.GetText(-1))
            return before, start, end
        except self.comtypes.COMError as error:
            raise RemoteError("ax_not_settable", "The application does not expose its text selection through Windows UI Automation. Use the manual keyboard or a compatible editor.") from error

    def native_edit_state(self, element):
        """Standard Win32/WinForms Edit controls have a native selection contract."""
        window = element.CurrentNativeWindowHandle
        name = C.create_unicode_buffer(256)
        self.user.GetClassNameW(window, name, len(name))
        if name.value.casefold() != "edit" and not name.value.casefold().startswith("windowsforms10.edit."):
            raise RemoteError("ax_not_settable", f"The focused control ({name.value or 'no native window'}) exposes neither UI Automation text selection nor the Win32 Edit contract. Select an editable text field or use the manual keyboard.")

        def message(kind, wparam=0, lparam=0):
            result = C.c_size_t()
            if not self.user.SendMessageTimeoutW(window, kind, wparam, lparam, 0x23, 1000, C.byref(result)):
                raise RemoteError("input_unavailable", "The Windows text field did not respond. Close any blocking dialog and use an application with the same privilege level as the companion.")
            return result.value

        length = message(0x000E)  # WM_GETTEXTLENGTH
        if length > 1000000:
            raise RemoteError("ax_not_settable", "The text field is too large to verify safely. Select a smaller editable field.")
        buffer = C.create_unicode_buffer(length + 1)
        message(0x000D, len(buffer), C.addressof(buffer))  # WM_GETTEXT
        start, end = W.DWORD(), W.DWORD()
        message(0x00B0, C.addressof(start), C.addressof(end))  # EM_GETSEL: marshalled by Windows
        encoded = buffer.value.encode("utf-16-le")
        try:
            offsets = [len(encoded[:position * 2].decode("utf-16-le")) for position in (start.value, end.value)]
        except UnicodeDecodeError as error:
            raise RemoteError("target_changed", "The Windows selection divides a Unicode character. Move the cursor and retry.") from error
        if end.value > len(encoded) // 2 or start.value > end.value:
            raise RemoteError("target_changed", "The Windows text or selection changed while it was being read. Retry dictation.")
        return buffer.value, *offsets

    def capture_target(self):
        element = self.focus()
        before, start, end = self.text_state(element)
        window = self.user.GetForegroundWindow()
        return {"element": element, "runtime": tuple(element.GetRuntimeId()), "window": int(window),
                "digest": hashlib.sha256(before.encode()).digest(), "start": start, "end": end,
                "name": self.process_name(self.pid(window)) or self.title(window)}

    def insert(self, target, value):
        current = self.capture_target()
        if any(current[key] != target[key] for key in ("runtime", "window", "digest", "start", "end")):
            raise RemoteError("target_changed", "The field, selection or text changed during dictation. Nothing was inserted.")
        before, start, end = self.text_state(current["element"])
        self._type_unicode(value)
        expected = (before[:start] + value + before[end:]).replace("\r\n", "\n").replace("\r", "\n")
        for _ in range(20):
            try:
                after, _, _ = self.text_state(current["element"])
            except RemoteError as error:
                if error.code != "target_changed":
                    raise
                # SendInput is asynchronous: text and selection can advance
                # between reads while the editor consumes our one event batch.
                # Retry the observation only; never send the batch again.
                time.sleep(0.05)
                continue
            if after.replace("\r\n", "\n").replace("\r", "\n") == expected:
                return {"method": "unicode_events", "verified": True, "applicationName": current["name"]}
            time.sleep(0.05)
        raise RemoteError("input_unavailable", "Windows accepted input events, but the application did not confirm the text. Check the field before retrying.")

    def send(self, events):
        self.check_ready()
        array = (self.Input * len(events))(*events)
        count = self.user.SendInput(len(array), array, C.sizeof(self.Input))
        if count != len(array):
            raise RemoteError("input_unavailable", "Windows refused some input events. The target may be elevated or the session locked. Return to a normal unlocked application before retrying.")

    def keyboard_event(self, virtual=0, scan=0, flags=0):
        item = self.Input(type=1)
        item.ki = self.Keyboard(virtual, scan, flags, 0, 0)
        return item

    def _type_unicode(self, value):
        if any(self.user.GetAsyncKeyState(key) & 0x8000 for key in (0x10, 0x11, 0x12, 0x5B, 0x5C)):
            raise RemoteError("input_unavailable", "Release the physical modifier keys on Windows before typing remotely.")
        encoded = value.replace("\r\n", "\n").encode("utf-16-le")
        events = []
        for index in range(0, len(encoded), 2):
            unit = int.from_bytes(encoded[index:index + 2], "little")
            if unit in (10, 13):
                events += [self.keyboard_event(virtual=13), self.keyboard_event(virtual=13, flags=2)]
            else:
                events += [self.keyboard_event(scan=unit, flags=4), self.keyboard_event(scan=unit, flags=6)]
        if events:
            self.send(events)

    def type_text(self, value):
        self._type_unicode(value)
        return {"method": "unicode_events", "verified": False, "applicationName": self.title(self.user.GetForegroundWindow())}

    def shortcut(self, keys):
        names = {"control": 0x11, "shift": 0x10, "alt": 0x12, "super": 0x5B, "Return": 13, "Escape": 27,
                 "Tab": 9, "BackSpace": 8, "Delete": 46, "space": 32, "Up": 38, "Down": 40, "Left": 37, "Right": 39}
        names.update({f"F{i}": 0x6F + i for i in range(1, 13)})
        codes = []
        for key in keys:
            code = names.get(key)
            if code is None and len(key) == 1 and key.isascii() and key.isalnum():
                code = ord(key.upper())
            if code is None:
                raise RemoteError("unsupported_capability", "This shortcut contains an unsupported Windows key.")
            codes.append(code)
        events = [self.keyboard_event(virtual=code) for code in codes]
        events += [self.keyboard_event(virtual=code, flags=2) for code in reversed(codes)]
        self.send(events)

    def key(self, key):
        mapping = {"enter": ["Return"], "escape": ["Escape"], "tab": ["Tab"], "backspace": ["BackSpace"],
                   "delete": ["Delete"], "space": ["space"], "arrow_up": ["Up"], "arrow_down": ["Down"],
                   "arrow_left": ["Left"], "arrow_right": ["Right"], "application_switcher": ["alt", "Tab"],
                   "next_conversation": ["control", "Tab"], "copy": ["control", "c"], "paste": ["control", "v"], "cut": ["control", "x"]}
        self.shortcut(mapping[key])

    def move(self, dx, dy):
        self.check_ready()
        point = W.POINT()
        if not self.user.GetCursorPos(C.byref(point)) or not self.user.SetCursorPos(round(point.x + dx), round(point.y + dy)):
            raise RemoteError("input_unavailable", "Windows refused pointer movement. Check the interactive session.")

    def absolute(self, x, y):
        self.check_ready()
        if not self.user.SetCursorPos(round(x * (self.user.GetSystemMetrics(0) - 1)), round(y * (self.user.GetSystemMetrics(1) - 1))):
            raise RemoteError("input_unavailable", "Windows refused absolute pointer movement.")

    def mouse_event(self, flags, data=0):
        item = self.Input(type=0)
        item.mi = self.Mouse(0, 0, data & 0xFFFFFFFF, flags, 0, 0)
        return item

    def click(self, button, count):
        down, up = (2, 4) if button == "left" else (8, 16)
        self.send([event for _ in range(count) for event in (self.mouse_event(down), self.mouse_event(up))])

    def drag(self, phase, dx, dy):
        if phase == "began":
            self.send([self.mouse_event(2)])
            self.dragging = True
        elif phase == "moved":
            if not self.dragging:
                raise RemoteError("protocol_mismatch", "Start a drag before moving it.")
            self.move(dx, dy)
        else:
            self.release_inputs()

    def scroll(self, dx, dy, zoom):
        events = [self.keyboard_event(virtual=0x11)] if zoom else []
        for axis, delta, flag in [(0, dx, 0x1000), (1, -dy, 0x800)]:
            self.scroll_remainder[axis] += delta * 6
            units = int(self.scroll_remainder[axis])
            self.scroll_remainder[axis] -= units
            if units:
                events.append(self.mouse_event(flag, units))
        if zoom:
            events.append(self.keyboard_event(virtual=0x11, flags=2))
        if events:
            self.send(events)

    def release_inputs(self):
        if self.dragging:
            self.send([self.mouse_event(4)])
            self.dragging = False

    def close(self):
        self.release_inputs()
        self.uia = None
        self.comtypes.CoUninitialize()
