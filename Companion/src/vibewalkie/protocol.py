"""Language-neutral V4 framing and strict command validation."""
import asyncio
import base64
import datetime as dt
import json
import math
import struct
import time
import uuid
from collections import OrderedDict

VERSION = 4
PORT = 54389
MAX_FRAME = 524288
MAX_TEXT = 32000
KEYS = frozenset("enter escape tab application_switcher next_conversation backspace delete arrow_up arrow_down arrow_left arrow_right space copy paste cut".split())
ZONES = "upper_left lower_left upper_right lower_right bottom_left bottom_center bottom_right".split()


class RemoteError(Exception):
    def __init__(self, code, detail):
        super().__init__(detail)
        self.code, self.detail = code, detail

    def payload(self):
        return {"code": self.code, "detail": self.detail}


def now():
    return dt.datetime.now(dt.timezone.utc)


def timestamp(value=None):
    return (value or now()).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_date(value):
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("UTC date required")
    return parsed


def encode(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


def decode(data):
    def bad_constant(_):
        raise ValueError("Non-finite JSON number")
    value = json.loads(data, object_pairs_hook=_unique_object, parse_constant=bad_constant)
    if not isinstance(value, dict):
        raise ValueError("JSON object required")
    return value


def b64(value):
    return base64.b64encode(value).decode("ascii")


def unb64(value, length=None):
    result = base64.b64decode(value, validate=True)
    if length is not None and len(result) != length:
        raise ValueError("Invalid binary field length")
    return result


def frame(value):
    data = encode(value)
    if not 0 < len(data) <= MAX_FRAME:
        raise RemoteError("payload_too_large", "Message exceeds the 512 KiB protocol limit.")
    return struct.pack(">I", len(data)) + data


async def read_envelope(reader):
    length, = struct.unpack(">I", await reader.readexactly(4))
    if not 0 < length <= MAX_FRAME:
        raise RemoteError("payload_too_large", "Invalid frame length; reconnect after updating the companion.")
    envelope = decode(await reader.readexactly(length))
    if envelope.get("version") != VERSION:
        raise RemoteError("version_mismatch", "Update both Vibe Walkie apps to protocol V4.")
    uuid.UUID(envelope["messageID"])
    string(envelope, "sessionID", 128)
    string(envelope, "type", 64)
    integer(envelope, "sequence", 1, 2**64 - 1)
    if abs((now() - parse_date(envelope["sentAt"])).total_seconds()) > 300:
        raise RemoteError("replay_detected", "Message time is outside the five-minute window. Check both clocks.")
    envelope["decoded"] = decode(unb64(envelope["payload"]))
    return envelope


def string(payload, key, maximum, allow_empty=False):
    value = payload.get(key)
    if not isinstance(value, str) or len(value) > maximum or (not value and not allow_empty) or "\x00" in value:
        raise RemoteError("protocol_mismatch", f"Invalid {key} field.")
    return value


def number(payload, key, minimum, maximum):
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not minimum <= value <= maximum:
        raise RemoteError("protocol_mismatch", f"Invalid {key} value.")
    return value


def integer(payload, key, minimum, maximum):
    value = number(payload, key, minimum, maximum)
    if not isinstance(value, int):
        raise RemoteError("protocol_mismatch", f"{key} must be an integer.")
    return value


def boolean(payload, key):
    value = payload.get(key)
    if type(value) is not bool:
        raise RemoteError("protocol_mismatch", f"{key} must be boolean.")
    return value


class RateLimit:
    def __init__(self, capacity, rate):
        self.capacity = self.tokens = capacity
        self.rate, self.last = rate, time.monotonic()

    def allow(self):
        current = time.monotonic()
        self.tokens = min(self.capacity, self.tokens + (current - self.last) * self.rate)
        self.last = current
        if self.tokens < 1:
            return False
        self.tokens -= 1
        return True


class ResponseCache:
    """Peer-wide responses outlive reconnects, never crossing peer identities."""
    def __init__(self):
        self.entries = OrderedDict()

    def get(self, peer, message):
        self.expire()
        return self.entries.get((peer, message), (None, None))[1]

    def put(self, peer, message, response):
        self.expire()
        self.entries[(peer, message)] = (time.monotonic(), response)
        while len(self.entries) > 4096:
            self.entries.popitem(last=False)

    def expire(self):
        cutoff = time.monotonic() - 300
        while self.entries and next(iter(self.entries.values()))[0] < cutoff:
            self.entries.popitem(last=False)


def default_configuration():
    definitions = [
        ("upper_left", "Clavier", "keyboard", {"type": "show_keyboard"}),
        ("lower_left", "Échap", "escape", {"type": "standard_key", "key": "escape"}),
        ("upper_right", "App précédente", "arrow.left.arrow.right", {"type": "standard_key", "key": "application_switcher"}),
        ("lower_right", "Entrée", "return", {"type": "standard_key", "key": "enter"}),
        ("bottom_left", "Effacer", "delete.left", {"type": "standard_key", "key": "backspace"}),
        ("bottom_center", "Espace", "space", {"type": "standard_key", "key": "space"}),
        ("bottom_right", "Tabulation", "arrow.right.to.line.compact", {"type": "standard_key", "key": "tab"}),
    ]
    return {"buttons": [{"zone": z, "title": t, "icon": {"system": {"_0": i}}, "action": a} for z, t, i, a in definitions],
            "globalButtons": [], "availableShortcuts": [], "revision": 0, "updatedAt": timestamp()}


def validate_configuration(config, shortcut_ids):
    """Never permit network-supplied hardware keycodes or executable strings."""
    if not isinstance(config, dict) or len(encode(config)) > 200000:
        raise RemoteError("payload_too_large", "Control configuration is too large.")
    buttons = config.get("buttons")
    globals_ = config.get("globalButtons", [])
    if not isinstance(buttons, list) or len(buttons) != 7 or {b.get("zone") for b in buttons if isinstance(b, dict)} != set(ZONES):
        raise RemoteError("protocol_mismatch", "Exactly seven distinct control zones are required.")
    if not isinstance(globals_, list) or len(globals_) > 32:
        raise RemoteError("payload_too_large", "At most 32 global controls are supported.")
    for button in buttons + globals_:
        string(button, "title", 80, allow_empty=True)
        action = button.get("action", {})
        kind = action.get("type")
        if kind == "standard_key" and action.get("key") in KEYS:
            continue
        if kind in ("none", "show_keyboard"):
            continue
        if kind == "host_shortcut" and action.get("shortcut", {}).get("id") in shortcut_ids:
            continue
        raise RemoteError("unsupported_capability", "Choose a standard key or a shortcut registered on this host.")
    return config
