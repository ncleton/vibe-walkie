"""No fake backend: TLS traffic controls a GTK application on a real X server."""
import asyncio
import hashlib
import io
from pathlib import Path
import ssl
import subprocess
import sys
import time
import uuid

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from PIL import Image
import pytest

from vibewalkie.protocol import b64, decode, encode, frame, read_envelope, timestamp, unb64
from vibewalkie.server import Companion
from vibewalkie.state import State

pytestmark = pytest.mark.skipif(sys.platform != "linux", reason="Requires Linux X11 and AT-SPI")


class Client:
    def __init__(self, host, port, key=None, peer_id=None):
        self.host, self.port = host, port
        self.key = key or Ed25519PrivateKey.generate()
        self.peer_id = peer_id or str(uuid.uuid4())
        self.sequence = 0
        self.session = str(uuid.uuid4())

    async def connect(self, pairing=True, approve=True):
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        tls.check_hostname = False
        tls.verify_mode = ssl.CERT_NONE
        self.reader, self.writer = await asyncio.open_connection("127.0.0.1", self.port, ssl=tls)
        certificate = self.writer.get_extra_info("ssl_object").getpeercert(binary_form=True)
        assert b64(hashlib.sha256(certificate).digest()) == self.host.identity.fingerprint
        assert self.writer.get_extra_info("ssl_object").version() == "TLSv1.3"
        challenge = await read_envelope(self.reader)
        qr = self.host.state.new_pairing(self.host.metadata, self.host.identity.fingerprint) if pairing else None
        secret = unb64(qr["k"]) if qr else b""
        payload = {"deviceIdentifier": self.peer_id, "deviceName": "Integration iPhone", "clientPlatform": "ios",
                   "publicKey": b64(self.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)),
                   "signature": b64(self.key.sign(unb64(challenge["decoded"]["nonce"]) + self.peer_id.encode() + secret))}
        if qr:
            payload["pairingSecret"] = qr["k"]
        await self.send("pairing_response", payload, reply_to=challenge["messageID"])
        if pairing:
            pending = await read_envelope(self.reader)
            assert pending["type"] == "pairing_pending"
            if not approve:
                return pending
            self.host.state.decide(pending["decoded"]["requestID"], pending["decoded"]["confirmationCode"], True)
        ready = await read_envelope(self.reader)
        return ready

    async def send(self, kind, payload, reply_to=None, message_id=None, sequence=None):
        self.sequence += 1
        message = {"version": 4, "type": kind, "messageID": message_id or str(uuid.uuid4()).upper(),
                   "sessionID": self.session, "sequence": sequence or self.sequence, "sentAt": timestamp(), "payload": b64(encode(payload))}
        if reply_to:
            message["replyTo"] = reply_to
        self.writer.write(frame(message))
        await self.writer.drain()
        return message

    async def request(self, kind, payload, **kwargs):
        message = await self.send(kind, payload, **kwargs)
        while True:
            response = await asyncio.wait_for(read_envelope(self.reader), 10)
            if response.get("replyTo") == message["messageID"]:
                return response

    async def close(self):
        self.writer.close()
        await self.writer.wait_closed()
        for _ in range(50):
            if self.host.controller is None:
                break
            await asyncio.sleep(0.02)


def test_real_desktop_through_pinned_tls(tmp_path):
    async def exercise():
        from vibewalkie.linux import LinuxDesktop
        state = State(tmp_path)
        host = Companion(state, {"hostName": "Integration Linux", "hostPlatform": "linux", "serviceName": "Integration"}, LinuxDesktop)
        try:
            listener = await host.start("127.0.0.1", 0)
            port = listener.sockets[0].getsockname()[1]
            # Wait for the separate GTK process and its accessibility registration.
            for attempt in range(60):
                try:
                    captured = await host.desktop("capture_target")
                    break
                except Exception:
                    if attempt == 59:
                        raise
                    await asyncio.sleep(0.1)
            client = Client(host, port)
            ready = await client.connect()
            assert ready["type"] == "connection_status"
            assert ready["decoded"]["hostPlatform"] == "linux"

            snapshot = await client.request("list_windows", {"includeIcons": True})
            assert any("integration editor" in w["title"] for app in snapshot["decoded"]["applications"] for w in app["windows"])
            configuration = await client.request("control_configuration_request", {})
            assert len(configuration["decoded"]["configuration"]["buttons"]) == 7

            dictation = str(uuid.uuid4())
            started = await client.request("recording_started", {"locale": "fr-FR", "dictationID": dictation})
            assert started["type"] == "acknowledgement", started
            payload = {"targetToken": started["decoded"]["targetToken"]["token"], "dictationID": dictation, "text": "Bonjour été 🌍"}
            original_payload = dict(payload)
            message_id = str(uuid.uuid4()).upper()
            inserted = await client.request("insert_text", payload, message_id=message_id)
            assert inserted["type"] == "acknowledgement", inserted
            assert inserted["decoded"]["insertion"]["verified"] is True
            after = await host.desktop("capture_target")
            replayed = await client.request("insert_text", payload, message_id=message_id)
            assert replayed["decoded"] == inserted["decoded"]
            assert (await host.desktop("capture_target"))["digest"] == after["digest"]
            consumed = await client.request("insert_text", payload)
            assert consumed["decoded"]["code"] == "target_lost"

            manually_typed = await client.request("keyboard_text", {"text": " café", "userInitiated": True})
            assert manually_typed["type"] == "acknowledgement", manually_typed
            await asyncio.sleep(0.1)
            assert (await host.desktop("capture_target"))["digest"] != after["digest"]

            # A focus/selection change during dictation must prevent insertion.
            started = await client.request("recording_started", {"locale": "fr-FR", "dictationID": dictation})
            await client.request("key_press", {"key": "arrow_left"})
            payload["targetToken"] = started["decoded"]["targetToken"]["token"]
            changed = await client.request("insert_text", payload)
            assert changed["decoded"]["code"] == "target_changed"

            # Password fields remain unavailable to dictation.
            await client.request("key_press", {"key": "tab"})
            await asyncio.sleep(0.1)
            secure = await client.request("recording_started", {"locale": "fr-FR", "dictationID": dictation})
            assert secure["decoded"]["code"] == "secure_field", secure
            await host.desktop("shortcut", ["shift", "Tab"])

            await client.send("pointer_absolute", {"normalizedX": 0.5, "normalizedY": 0.5})
            await client.send("pointer_drag", {"phase": "began", "deltaX": 0, "deltaY": 0})
            await client.request("hello", {})  # Barrier: gesture operations have completed.
            assert host.backend.dragging
            await client.close()
            assert not host.backend.dragging

            # Known peers reconnect without QR secrets. Dedupe survives reconnect.
            reconnected = Client(host, port, client.key, client.peer_id)
            assert (await reconnected.connect(pairing=False))["type"] == "connection_status"
            duplicate = await reconnected.request("insert_text", original_payload, message_id=message_id)
            assert duplicate["decoded"] == inserted["decoded"]
            # Exercise live screen capture, not a fixture image.
            await reconnected.send("screen_stream_request", {"enabled": True, "maxWidth": 640, "framesPerSecond": 4, "jpegQuality": 0.4})
            while True:
                response = await asyncio.wait_for(read_envelope(reconnected.reader), 10)
                if response["type"] == "screen_frame":
                    image = Image.open(io.BytesIO(unb64(response["decoded"]["jpegData"])))
                    assert image.size == (640, 400)
                    assert len(set(image.get_flattened_data())) > 20
                    image.save(tmp_path / "linux-live-screen.png")
                    break

            # The VPS view is backed by a real shell, not a rendered terminal imitation.
            terminal = subprocess.Popen(["xterm", "-T", "Vibe Walkie shell integration", "-e", "/bin/sh"],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(50):
                    windows = await host.desktop("windows")
                    shell = next((app for app in windows["applications"] if any("shell integration" in w["title"] for w in app["windows"])), None)
                    if shell:
                        break
                    await asyncio.sleep(0.1)
                assert shell is not None
                await reconnected.request("activate_window", {"applicationID": shell["id"]})
                output = tmp_path / "terminal-output"
                response = await reconnected.request("keyboard_text", {"text": f"printf VIBE_WALKIE_TERMINAL_OK > {output}", "userInitiated": True})
                assert response["type"] == "acknowledgement", response
                await reconnected.request("key_press", {"key": "enter"})
                for _ in range(50):
                    if output.exists():
                        break
                    await asyncio.sleep(0.1)
                assert output.read_text() == "VIBE_WALKIE_TERMINAL_OK"
            finally:
                terminal.terminate()
                terminal.wait(timeout=5)
            state.revoke(client.peer_id)
            while True:
                response = await asyncio.wait_for(read_envelope(reconnected.reader), 10)
                if response["type"] == "screen_stream_status" and not response["decoded"]["isStreaming"]:
                    assert "revoked" in response["decoded"]["detail"]
                    break
            await reconnected.send("key_press", {"key": "enter"})
            denied = await asyncio.wait_for(read_envelope(reconnected.reader), 10)
            assert denied["decoded"]["code"] == "peer_revoked"
            await reconnected.close()
        finally:
            await host.stop()
            state.close()
    asyncio.run(exercise())
