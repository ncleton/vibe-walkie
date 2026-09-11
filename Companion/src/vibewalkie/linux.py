"""X11 desktop backend for Linux workstations and explicit Xvfb VPS sessions."""
import hashlib
import os
import time

from .protocol import RemoteError, timestamp


class LinuxDesktop:
    def __init__(self):
        if os.environ.get("XDG_SESSION_TYPE") == "wayland":
            raise RuntimeError("This companion requires an X11 session. Choose Xorg at login or use the dedicated VPS desktop service; Wayland requires a separate portal backend.")
        if not os.environ.get("DISPLAY") or not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
            raise RuntimeError("DISPLAY and DBUS_SESSION_BUS_ADDRESS are required. Start Vibe Walkie from the desktop session or run the VPS desktop launcher.")
        try:
            import gi
            gi.require_version("Atspi", "2.0")
            from gi.repository import Atspi
            from Xlib import X, XK, display
            from Xlib.ext import xtest
        except ImportError as error:
            raise RuntimeError("Install python3-gi gir1.2-atspi-2.0 at-spi2-core and the companion dependencies, then launch with the system Python virtualenv (--system-site-packages).") from error
        self.atspi, self.X, self.XK, self.xtest = Atspi, X, XK, xtest
        Atspi.init()
        Atspi.set_timeout(1000, 2000)
        self.display = display.Display()
        if not self.display.has_extension("XTEST"):
            raise RuntimeError("The X server must enable its XTEST extension for pointer and keyboard control.")
        self.root = self.display.screen().root
        self.dragging = False
        self.scroll_remainder = [0.0, 0.0]

    def check_ready(self):
        self.display.sync()
        if self.root.get_geometry().width < 1:
            raise RemoteError("screen_unavailable", "No active X11 desktop. Restart the VPS desktop service.")

    def property(self, window, name):
        value = window.get_full_property(self.display.intern_atom(name), self.X.AnyPropertyType)
        return value.value if value is not None else None

    def active_window(self):
        active = self.property(self.root, "_NET_ACTIVE_WINDOW")
        if active is None or not len(active) or not active[0]:
            raise RemoteError("no_focused_target", "Click an application in the Linux desktop first.")
        return self.display.create_resource_object("window", int(active[0]))

    def windows(self):
        ids = self.property(self.root, "_NET_CLIENT_LIST")
        if ids is None:
            raise RemoteError("input_unavailable", "An EWMH window manager is required. Start Openbox or the configured VPS desktop.")
        active = self.property(self.root, "_NET_ACTIVE_WINDOW")
        active_id = int(active[0]) if active is not None and len(active) else 0
        applications = []
        for identifier in ids[:256]:
            window = self.display.create_resource_object("window", int(identifier))
            try:
                title = self.property(window, "_NET_WM_NAME")
                title = title.decode("utf-8", errors="replace") if isinstance(title, bytes) else (window.get_wm_name() or "")
                classes = window.get_wm_class()
                name = classes[-1] if classes else title
                identifier = f"x11:{window.id}"
                applications.append({"id": identifier, "name": name or "X11", "applicationIdentifier": name,
                    "isActive": window.id == active_id, "windows": [{"id": identifier, "title": title,
                    "isMain": True, "isMinimized": window.get_attributes().map_state != self.X.IsViewable}]})
            except __import__("Xlib.error", fromlist=["BadWindow"]).BadWindow:
                continue  # A window that closed during inventory no longer exists.
        return {"applications": applications, "activeApplicationID": f"x11:{active_id}", "capturedAt": timestamp()}

    def activate(self, application_id, window_id):
        from Xlib.protocol import event
        identifier = window_id or application_id
        if identifier != application_id or identifier not in {app["id"] for app in self.windows()["applications"]}:
            raise RemoteError("application_not_found", "The selected window no longer exists. Refresh the application list.")
        window = self.display.create_resource_object("window", int(identifier.split(":")[1]))
        window.map()
        self.root.send_event(event.ClientMessage(window=window, client_type=self.display.intern_atom("_NET_ACTIVE_WINDOW"),
                              data=(32, [2, self.X.CurrentTime, 0, 0, 0])),
                              event_mask=self.X.SubstructureRedirectMask | self.X.SubstructureNotifyMask)
        self.display.flush()
        for _ in range(20):
            time.sleep(0.025)
            if self.active_window().id == window.id:
                return
        raise RemoteError("activation_denied", "The window manager refused activation. Open the window in the desktop and retry.")

    def focus(self):
        window = self.active_window()
        pid_property = self.property(window, "_NET_WM_PID")
        pid = int(pid_property[0]) if pid_property is not None else None
        desktop = self.atspi.get_desktop(0)
        stack = []
        for index in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(index)
            if pid is None or app.get_process_id() == pid:
                stack.append(app)
        deadline = time.monotonic() + 3
        visited = 0
        while stack and visited < 10000 and time.monotonic() < deadline:
            item = stack.pop()
            visited += 1
            item.clear_cache()
            states = item.get_state_set()
            if states.contains(self.atspi.StateType.FOCUSED):
                if item.get_role() == self.atspi.Role.PASSWORD_TEXT:
                    raise RemoteError("secure_field", "Dictation is disabled in password fields. Use the manual keyboard.")
                if "Text" in item.get_interfaces():
                    return item, window.id
            if not states.contains(self.atspi.StateType.DEFUNCT):
                stack.extend(item.get_child_at_index(i) for i in range(min(item.get_child_count(), 1000)))
        raise RemoteError("no_focused_target", "Focus an accessible text field. Enable accessibility in the application if it does not expose its focused field.")

    def capture_target(self):
        element, window = self.focus()
        if "EditableText" not in element.get_interfaces():
            raise RemoteError("ax_not_settable", "This field does not expose editable text to AT-SPI. Use the manual keyboard or an accessible text editor for dictation.")
        text = element.get_text_iface()
        if text.get_character_count() > 1000000:
            raise RemoteError("payload_too_large", "The focused field is too large to validate safely. Use a smaller document.")
        before = self.atspi.Text.get_text(text, 0, -1)
        if text.get_n_selections():
            selection = text.get_selection(0)
            start, end = selection.start_offset, selection.end_offset
        else:
            start = end = text.get_caret_offset()
        return {"element": element, "window": window, "name": element.get_application().get_name(),
                "digest": hashlib.sha256(before.encode()).digest(), "start": start, "end": end}

    def insert(self, target, value):
        current = self.capture_target()
        if any(current[key] != target[key] for key in ("element", "window", "digest", "start", "end")):
            raise RemoteError("target_changed", "The focused field, selection or text changed during dictation. Nothing was inserted.")
        element = current["element"]
        editable, text = element.get_editable_text_iface(), element.get_text_iface()
        before = self.atspi.Text.get_text(text, 0, -1)
        start, end = current["start"], current["end"]
        if end > start and not editable.delete_text(start, end):
            raise RemoteError("input_unavailable", "The application refused replacing the selected text.")
        if not editable.insert_text(start, value, len(value.encode("utf-8"))):
            raise RemoteError("input_unavailable", "The application refused text insertion. Check the field before retrying.")
        text.set_caret_offset(start + len(value))
        if self.atspi.Text.get_text(text, 0, -1) != before[:start] + value + before[end:]:
            raise RemoteError("input_unavailable", "The application did not confirm the inserted text. Check the field before retrying.")
        return {"method": "ax_range", "verified": True, "applicationName": target["name"]}

    def type_text(self, value):
        # Explicit manual typing uses the accessibility input synthesis service.
        # A false result is an error, never a successful insertion acknowledgement.
        if not self.atspi.generate_keyboard_event(0, value, self.atspi.KeySynthType.STRING):
            raise RemoteError("input_unavailable", "AT-SPI could not type the text. Check that the accessibility service and an input field are active.")
        return {"method": "keyboard_events", "verified": False, "applicationName": self.active_window().get_wm_name() or "X11"}

    def shortcut(self, keys):
        codes = []
        names = {"control": "Control_L", "shift": "Shift_L", "alt": "Alt_L", "super": "Super_L"}
        for key in keys:
            code = self.display.keysym_to_keycode(self.XK.string_to_keysym(names.get(key, key)))
            if code == 0:
                raise RemoteError("unsupported_capability", "A shortcut key is absent from this desktop's keyboard map.")
            codes.append(code)
        try:
            for code in codes:
                self.xtest.fake_input(self.display, self.X.KeyPress, code)
        finally:
            for code in reversed(codes):
                self.xtest.fake_input(self.display, self.X.KeyRelease, code)
            self.display.sync()

    def key(self, key):
        mapping = {"enter": ["Return"], "escape": ["Escape"], "tab": ["Tab"], "backspace": ["BackSpace"],
                   "delete": ["Delete"], "space": ["space"], "arrow_up": ["Up"], "arrow_down": ["Down"],
                   "arrow_left": ["Left"], "arrow_right": ["Right"], "application_switcher": ["alt", "Tab"],
                   "next_conversation": ["control", "Tab"], "copy": ["control", "c"], "paste": ["control", "v"], "cut": ["control", "x"]}
        self.shortcut(mapping[key])

    def move(self, dx, dy):
        position = self.root.query_pointer()
        geometry = self.root.get_geometry()
        self.xtest.fake_input(self.display, self.X.MotionNotify,
                             x=round(min(geometry.width - 1, max(0, position.root_x + dx))),
                             y=round(min(geometry.height - 1, max(0, position.root_y + dy))))
        self.display.sync()

    def absolute(self, x, y):
        geometry = self.root.get_geometry()
        self.xtest.fake_input(self.display, self.X.MotionNotify, x=round(x * (geometry.width - 1)), y=round(y * (geometry.height - 1)))
        self.display.sync()

    def click(self, button, count):
        for _ in range(count):
            self.xtest.fake_input(self.display, self.X.ButtonPress, 1 if button == "left" else 3)
            self.xtest.fake_input(self.display, self.X.ButtonRelease, 1 if button == "left" else 3)
        self.display.sync()

    def drag(self, phase, dx, dy):
        if phase == "began":
            self.xtest.fake_input(self.display, self.X.ButtonPress, 1)
            self.dragging = True
        elif phase == "moved":
            if not self.dragging:
                raise RemoteError("protocol_mismatch", "Start a drag before moving it.")
            self.move(dx, dy)
        else:
            self.release_inputs()
        self.display.sync()

    def scroll(self, dx, dy, zoom):
        control = self.display.keysym_to_keycode(self.XK.string_to_keysym("Control_L"))
        if zoom:
            self.xtest.fake_input(self.display, self.X.KeyPress, control)
        try:
            for axis, delta, negative, positive in [(0, dx, 6, 7), (1, dy, 4, 5)]:
                self.scroll_remainder[axis] += delta
                clicks = int(self.scroll_remainder[axis] / 20)
                self.scroll_remainder[axis] -= clicks * 20
                for _ in range(min(abs(clicks), 64)):
                    button = positive if clicks > 0 else negative
                    self.xtest.fake_input(self.display, self.X.ButtonPress, button)
                    self.xtest.fake_input(self.display, self.X.ButtonRelease, button)
        finally:
            if zoom:
                self.xtest.fake_input(self.display, self.X.KeyRelease, control)
            self.display.sync()

    def release_inputs(self):
        if self.dragging:
            self.xtest.fake_input(self.display, self.X.ButtonRelease, 1)
            self.dragging = False
            self.display.sync()

    def close(self):
        self.release_inputs()
        self.display.close()
