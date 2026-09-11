"""Starts the shipped VPS launcher, then controls its actual terminal over TLS."""
import asyncio
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
from types import SimpleNamespace

from PIL import Image
import pytest

from test_linux_integration import Client
from vibewalkie.protocol import read_envelope, unb64
from vibewalkie.state import Identity, State

pytestmark = pytest.mark.skipif(sys.platform != "linux", reason="Requires the Linux VPS desktop prerequisites")


def test_shipped_vps_launcher_controls_a_real_shell(tmp_path):
    launcher = Path(__file__).parents[1] / "scripts/start-vps-desktop.sh"
    environment = {**os.environ, "XDG_STATE_HOME": str(tmp_path)}
    log = (tmp_path / "desktop.log").open("w")
    process = subprocess.Popen(["bash", str(launcher), "--bind", "127.0.0.1", "--name", "VPS Launcher QA"],
                               env=environment, stdout=log, stderr=log, start_new_session=True)

    async def exercise():
        state = State(tmp_path / "vibewalkie")
        client = None
        try:
            for _ in range(100):
                assert process.poll() is None, (tmp_path / "desktop.log").read_text()
                runtime = state.setting("runtime")
                if runtime and runtime.get("heartbeat"):
                    break
                await asyncio.sleep(0.1)
            assert runtime and runtime.get("heartbeat"), (tmp_path / "desktop.log").read_text()
            # Read the running process's real identity and operator database;
            # all desktop operations below cross the TLS socket.
            endpoint = SimpleNamespace(state=state, identity=Identity(state.directory), metadata=runtime)
            client = Client(endpoint, 54389)
            assert (await client.connect())["decoded"]["hostPlatform"] == "linux"
            windows = await client.request("list_windows", {"includeIcons": False})
            terminal = next(app for app in windows["decoded"]["applications"]
                            if any("Vibe Walkie VPS" in item["title"] for item in app["windows"]))
            activated = await client.request("activate_window", {"applicationID": terminal["id"]})
            assert activated["type"] == "acknowledgement", activated
            output = tmp_path / "shell-proof.txt"
            typed = await client.request("keyboard_text", {"text": f"printf VPS_LAUNCHER_OK > {output}", "userInitiated": True})
            assert typed["type"] == "acknowledgement", typed
            await client.request("key_press", {"key": "enter"})
            for _ in range(50):
                if output.exists():
                    break
                await asyncio.sleep(0.1)
            assert output.read_text() == "VPS_LAUNCHER_OK"
            await client.send("screen_stream_request", {"enabled": True, "maxWidth": 640, "framesPerSecond": 4, "jpegQuality": 0.4})
            while True:
                response = await asyncio.wait_for(read_envelope(client.reader), 10)
                if response["type"] == "screen_frame":
                    screen = Image.open(io.BytesIO(unb64(response["decoded"]["jpegData"])))
                    assert screen.size == (640, 400)
                    assert len(set(screen.get_flattened_data())) > 20
                    screen.save(tmp_path / "vps-live-screen.png")
                    break
        finally:
            if client:
                await client.close()
            state.close()
    try:
        asyncio.run(exercise())
    finally:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=15)
        log.close()
