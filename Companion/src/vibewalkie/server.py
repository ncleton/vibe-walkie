"""TLS V4 companion: authentication precedes every desktop operation."""
import asyncio
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import hashlib
import hmac
import io
import json
import secrets
import time
import uuid

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from PIL import Image
import mss

from . import __version__
from .protocol import (KEYS, PORT, VERSION, RemoteError, RateLimit, ResponseCache, b64, boolean,
                       default_configuration, encode, frame, integer, now, number, parse_date,
                       read_envelope, string, timestamp, unb64, validate_configuration)
from .state import Identity


class Companion:
    def __init__(self, state, metadata, backend_factory):
        self.state, self.metadata = state, metadata
        self.identity = Identity(state.directory)
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="desktop")
        self.capture_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="screen")
        self.backend_factory, self.backend = backend_factory, None
        self.responses = ResponseCache()
        self.connection_limit = RateLimit(16, 0.5)
        self.connections = set()
        self.controller = None
        self.listener = None

    async def desktop(self, method, *args):
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self.executor, lambda: getattr(self.backend, method)(*args))

    async def start(self, address, port=PORT):
        loop = asyncio.get_running_loop()
        self.backend = await loop.run_in_executor(self.executor, self.backend_factory)
        # Fail before listening if capture, accessibility or the desktop is missing.
        await self.desktop("check_ready")
        await loop.run_in_executor(self.capture_executor, self.capture, 640, 0.4)
        self.listener = await asyncio.start_server(self.accept, address, port, ssl=self.identity.context,
                                                  ssl_handshake_timeout=10, limit=524292)
        self.state.set_setting("runtime", {**self.metadata, "pid": __import__("os").getpid(), "startedAt": timestamp()})
        return self.listener

    async def stop(self):
        if self.listener:
            self.listener.close()
        for task in list(self.connections):
            task.cancel()
        await asyncio.gather(*list(self.connections), return_exceptions=True)
        if self.listener:
            await self.listener.wait_closed()
        if self.backend:
            await self.desktop("close")
        self.executor.shutdown(wait=True, cancel_futures=True)
        self.capture_executor.shutdown(wait=True, cancel_futures=True)

    async def accept(self, reader, writer):
        task = asyncio.current_task()
        if len(self.connections) >= 8 or not self.connection_limit.allow():
            writer.close()
            return
        self.connections.add(task)
        session = Session(self, reader, writer)
        try:
            await session.run()
        except asyncio.CancelledError:
            raise
        except (ConnectionError, asyncio.IncompleteReadError, TimeoutError):
            pass  # Transport closure is not a successful command.
        except RemoteError as error:
            await session.send_error(error)
        except (ValueError, KeyError, TypeError, InvalidSignature):
            await session.send_error(RemoteError("protocol_mismatch", "Invalid authentication or protocol data. Re-pair using a fresh QR."))
        except Exception as error:
            # Exception category only: system messages may contain field content.
            print(f"Companion session failed: {type(error).__name__}. Check desktop availability.", flush=True)
            await session.send_error(RemoteError("internal_failure", "The companion could not process this request. Check its local console."))
        finally:
            await session.stop_stream()
            if self.controller is session:
                try:
                    await self.desktop("release_inputs")
                except Exception as error:
                    print(f"Input release failed: {type(error).__name__}. Check and release input on the host desktop.", flush=True)
                finally:
                    self.controller = None
            session.target = None
            self.connections.discard(task)
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, TimeoutError):
                pass

    def capture(self, width, quality):
        with mss.MSS() as capture:
            if len(capture.monitors) < 2:
                raise RemoteError("screen_unavailable", "No active display. Start a desktop session or the VPS desktop service.")
            shot = capture.grab(capture.monitors[1])
            image = Image.frombytes("RGB", shot.size, shot.rgb)
            if image.width > width:
                image = image.resize((width, max(1, round(image.height * width / image.width))), Image.Resampling.LANCZOS)
            output = io.BytesIO()
            image.save(output, format="JPEG", quality=round(quality * 100))
            return {"jpegData": b64(output.getvalue()), "width": image.width, "height": image.height, "capturedAt": timestamp()}

    def configuration(self):
        config = self.state.setting("configuration") or default_configuration()
        config["availableShortcuts"] = [{"id": key, "displayName": item["name"], "icon": "command"}
                                        for key, item in (self.state.setting("shortcuts") or {}).items()]
        return config


class Session:
    def __init__(self, companion, reader, writer):
        self.host, self.reader, self.writer = companion, reader, writer
        self.identifier = str(uuid.uuid4()).upper()
        self.sequence, self.received_sequence = 0, 0
        self.peer_id = self.client_session = None
        self.write_lock = asyncio.Lock()
        self.commands, self.gestures = RateLimit(40, 20), RateLimit(240, 180)
        self.stream = None
        self.target = None

    async def send(self, kind, payload, reply_to=None):
        async with self.write_lock:
            self.sequence += 1
            envelope = {"version": VERSION, "type": kind, "messageID": str(uuid.uuid4()).upper(),
                        "sessionID": self.identifier, "sequence": self.sequence, "sentAt": timestamp(), "payload": b64(encode(payload))}
            if reply_to:
                envelope["replyTo"] = reply_to
            self.writer.write(frame(envelope))
            await asyncio.wait_for(self.writer.drain(), timeout=8)
            return envelope["messageID"]

    async def send_error(self, error, reply_to=None):
        try:
            await self.send("error", error.payload(), reply_to)
        except (ConnectionError, TimeoutError):
            pass

    async def run(self):
        nonce = secrets.token_bytes(32)
        challenge = await self.send("pairing_challenge", {"nonce": b64(nonce), "requiresPairingSecret": True})
        envelope = await asyncio.wait_for(read_envelope(self.reader), 10)
        if envelope["type"] != "pairing_response" or envelope.get("replyTo") != challenge:
            raise RemoteError("not_paired", "A signed pairing response is required before control is allowed.")
        payload = envelope["decoded"]
        self.peer_id = string(payload, "deviceIdentifier", 128)
        string(payload, "deviceName", 128)
        if payload.get("clientPlatform") not in ("ios", "android"):
            raise ValueError("Unknown client platform")
        public_key = unb64(payload["publicKey"], 32)
        signature = unb64(payload["signature"], 64)
        secret = unb64(payload["pairingSecret"], 16) if payload.get("pairingSecret") else None
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, nonce + self.peer_id.encode() + (secret or b""))
        peer = self.host.state.peer(self.peer_id)
        if secret:
            pending = self.host.state.request_pairing(payload, secret, self.host.identity.fingerprint)
            await self.send("pairing_pending", pending)
            print(f"Pairing request {pending['requestID']} from {json.dumps(payload['deviceName'])}; compare code {pending['confirmationCode']} and run vibewalkie approve.", flush=True)
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                decision = self.host.state.decision(pending["requestID"])
                if decision == "denied":
                    raise RemoteError("pairing_denied", "Pairing was denied on the host.")
                if decision == "approved":
                    break
                await asyncio.sleep(0.2)
            else:
                raise RemoteError("pairing_approval_expired", "Approve the iPhone on the host within 60 seconds. Scan a new QR.")
            peer = self.host.state.peer(self.peer_id)
        if peer is None or not hmac.compare_digest(peer["public_key"], payload["publicKey"]):
            raise RemoteError("not_paired", "This device is not paired. Scan a QR generated on the host.")
        if peer["revoked"]:
            raise RemoteError("peer_revoked", "This device was revoked. Pair it again with approval on the host.")
        if self.host.controller is not None:
            raise RemoteError("input_unavailable", "Another device controls this desktop. Disconnect it before connecting here.")
        self.host.controller = self
        self.client_session = envelope["sessionID"]
        self.received_sequence = envelope["sequence"]
        status = {"inputControlReady": True, "screenCaptureReady": True,
                  "hostName": self.host.metadata["hostName"], "hostPlatform": self.host.metadata["hostPlatform"],
                  "companionVersion": __version__, "capabilities": sorted([
                      "dictation_targeting", "keyboard", "pointer", "app_windows", "screen_streaming", "custom_shortcuts", "configuration_sync"
                  ] + (["tailscale"] if self.host.metadata.get("nomadEndpoint") else []))}
        if self.host.metadata.get("nomadEndpoint"):
            status["nomadEndpoint"] = self.host.metadata["nomadEndpoint"]
        await self.send("connection_status", status)
        while True:
            envelope = await asyncio.wait_for(read_envelope(self.reader), 90)
            peer = self.host.state.peer(self.peer_id)
            if peer is None or peer["revoked"]:
                raise RemoteError("peer_revoked", "This device was revoked on the host.")
            if envelope["sessionID"] != self.client_session:
                raise RemoteError("replay_detected", "Session identity changed. Reconnect the iPhone.")
            digest = hashlib.sha256(encode({"type": envelope["type"], "payload": envelope["payload"]})).digest()
            cached = self.host.responses.get(self.peer_id, envelope["messageID"])
            if cached:
                if not hmac.compare_digest(cached[0], digest):
                    raise RemoteError("replay_detected", "A message identifier was reused with different content.")
                await self.send(cached[1], cached[2], envelope["messageID"])
                continue
            if envelope["sequence"] <= self.received_sequence:
                raise RemoteError("replay_detected", "Message sequence is not increasing. Reconnect the iPhone.")
            self.received_sequence = envelope["sequence"]
            gesture = envelope["type"] in ("pointer_move", "pointer_absolute", "pointer_drag", "scroll")
            if not (self.gestures if gesture else self.commands).allow():
                await self.send_error(RemoteError("rate_limited", "Commands arrived too quickly. Slow down and retry."), envelope["messageID"])
                continue
            try:
                kind, response = await self.execute(envelope["type"], envelope["decoded"])
            except RemoteError as error:
                kind, response = "error", error.payload()
            except (ValueError, KeyError, TypeError):
                kind, response = "error", RemoteError("protocol_mismatch", "Malformed command payload.").payload()
            self.host.responses.put(self.peer_id, envelope["messageID"], (digest, kind, response))
            # Fire-and-forget gestures are deduplicated but don't congest the return path.
            if not gesture or kind == "error":
                await self.send(kind, response, envelope["messageID"])

    async def execute(self, kind, payload):
        ack = {"ok": True}
        if kind == "hello":
            return "acknowledgement", ack
        if kind == "recording_started":
            dictation_id = str(uuid.UUID(string(payload, "dictationID", 36)))
            self.target = None
            captured = await self.host.desktop("capture_target")
            self.target = {"id": secrets.token_urlsafe(24), "dictation": dictation_id, "captured": captured, "expires": now() + dt.timedelta(seconds=120)}
            ack["targetToken"] = {"token": self.target["id"], "applicationName": captured["name"],
                                  "expiresAt": timestamp(self.target["expires"])}
        elif kind == "insert_text":
            target, self.target = self.target, None
            if target is None or not hmac.compare_digest(target["id"], string(payload, "targetToken", 128)):
                raise RemoteError("target_lost", "Start dictation again: the target token is missing or consumed.")
            if str(uuid.UUID(string(payload, "dictationID", 36))) != target["dictation"]:
                raise RemoteError("target_lost", "Dictation identity changed; the text was not inserted.")
            if now() >= target["expires"]:
                raise RemoteError("target_expired", "The target expired. Start dictation again.")
            text = string(payload, "text", 32000)
            ack["insertion"] = await self.host.desktop("insert", target["captured"], text)
        elif kind == "cancel":
            self.target = None
        elif kind == "keyboard_text":
            if not boolean(payload, "userInitiated"):
                raise RemoteError("secure_target", "Open the remote keyboard before typing manually.")
            ack["insertion"] = await self.host.desktop("type_text", string(payload, "text", 512))
        elif kind == "key_press":
            if payload.get("key") not in KEYS:
                raise RemoteError("unsupported_capability", "Unknown standard key.")
            await self.host.desktop("key", payload["key"])
        elif kind == "pointer_move":
            await self.host.desktop("move", number(payload, "deltaX", -4096, 4096), number(payload, "deltaY", -4096, 4096))
        elif kind == "pointer_absolute":
            await self.host.desktop("absolute", number(payload, "normalizedX", 0, 1), number(payload, "normalizedY", 0, 1))
        elif kind == "pointer_click":
            if payload.get("button") not in ("left", "right"):
                raise ValueError("Invalid mouse button")
            await self.host.desktop("click", payload["button"], integer(payload, "clickCount", 1, 2))
        elif kind == "pointer_drag":
            if payload.get("phase") not in ("began", "moved", "ended"):
                raise ValueError("Invalid drag phase")
            await self.host.desktop("drag", payload["phase"], number(payload, "deltaX", -4096, 4096), number(payload, "deltaY", -4096, 4096))
        elif kind == "scroll":
            zoom = boolean(payload, "zoom") if "zoom" in payload else False
            await self.host.desktop("scroll", number(payload, "deltaX", -4096, 4096), number(payload, "deltaY", -4096, 4096), zoom)
        elif kind == "list_windows":
            boolean(payload, "includeIcons")
            return "windows_snapshot", await self.host.desktop("windows")
        elif kind == "activate_window":
            await self.host.desktop("activate", string(payload, "applicationID", 128), payload.get("windowID"))
        elif kind == "screen_stream_request":
            await self.stop_stream()
            enabled = boolean(payload, "enabled")
            if enabled:
                width = integer(payload, "maxWidth", 320, 1920)
                fps = integer(payload, "framesPerSecond", 1, 20)
                quality = number(payload, "jpegQuality", 0.1, 0.9)
                self.stream = asyncio.create_task(self.stream_frames(width, fps, quality))
            await self.send("screen_stream_status", {"isStreaming": enabled, "permissionGranted": True})
        elif kind == "control_configuration_request":
            return "control_configuration_snapshot", {"configuration": self.host.configuration()}
        elif kind == "control_configuration_update":
            config = validate_configuration(payload.get("configuration"), set((self.host.state.setting("shortcuts") or {}).keys()))
            config["revision"] = self.host.configuration()["revision"] + 1
            config["updatedAt"] = timestamp()
            self.host.state.set_setting("configuration", config)
            await self.send("control_configuration_snapshot", {"configuration": self.host.configuration()})
        elif kind == "host_shortcut_press":
            shortcut = (self.host.state.setting("shortcuts") or {}).get(string(payload, "shortcutID", 96))
            if shortcut is None:
                raise RemoteError("unsupported_capability", "Register this shortcut locally on the companion first.")
            await self.host.desktop("shortcut", shortcut["keys"])
        else:
            raise RemoteError("unsupported_capability", "This message is not an allowed desktop command.")
        return "acknowledgement", ack

    async def stream_frames(self, width, fps, quality):
        try:
            while True:
                peer = self.host.state.peer(self.peer_id)
                if peer is None or peer["revoked"]:
                    raise RemoteError("peer_revoked", "Screen access was revoked on the host.")
                await self.host.desktop("check_ready")
                started = time.monotonic()
                payload = await asyncio.get_running_loop().run_in_executor(self.host.capture_executor, self.host.capture, width, quality)
                await self.send("screen_frame", payload)
                await asyncio.sleep(max(0, 1 / fps - (time.monotonic() - started)))
        except asyncio.CancelledError:
            raise
        except Exception as error:
            detail = error.detail if isinstance(error, RemoteError) else "Screen capture failed. Unlock or restart the desktop session, then reopen screen view."
            if isinstance(error, RemoteError) and error.code == "payload_too_large":
                detail = "The screen frame exceeds 512 KiB. Reduce screen quality in iPhone settings and reopen screen view."
            try:
                await self.send("screen_stream_status", {"isStreaming": False, "permissionGranted": False, "detail": detail})
            except (ConnectionError, TimeoutError):
                pass

    async def stop_stream(self):
        if self.stream:
            self.stream.cancel()
            await asyncio.gather(self.stream, return_exceptions=True)
            self.stream = None
