"""Runs only on Windows, against a real WinForms editor and Win32 desktop."""
import asyncio
import io
import subprocess
import sys
import uuid

from PIL import Image
import pytest

from vibewalkie.protocol import read_envelope, unb64
from vibewalkie.server import Companion
from vibewalkie.state import State
from test_linux_integration import Client

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Requires an interactive Windows desktop")


@pytest.mark.parametrize("framework", ["winforms", "wpf"])
def test_real_windows_desktop_through_pinned_tls(tmp_path, framework):
    script = tmp_path / "editor.ps1"
    script.write_text('''Add-Type -AssemblyName System.Windows.Forms
$form = New-Object System.Windows.Forms.Form
$form.Text = "Vibe Walkie Windows integration editor"
$form.Width = 640
$form.Height = 480
$text = New-Object System.Windows.Forms.TextBox
$text.Multiline = $true
$text.Text = "Initial "
$text.Width = 600
$text.Height = 300
$text.TabIndex = 0
$password = New-Object System.Windows.Forms.TextBox
$password.Top = 320
$password.Width = 600
$password.UseSystemPasswordChar = $true
$password.TabIndex = 1
$form.Controls.Add($text)
$form.Controls.Add($password)
$form.Add_Shown({$form.Activate(); $text.Focus(); $text.Select($text.TextLength, 0)})
[System.Windows.Forms.Application]::Run($form)
''')
    if framework == "wpf":
        script.write_text('''Add-Type -AssemblyName PresentationFramework
$window = New-Object System.Windows.Window
$window.Title = "Vibe Walkie Windows integration editor"
$window.Width = 640
$window.Height = 480
$panel = New-Object System.Windows.Controls.StackPanel
$text = New-Object System.Windows.Controls.TextBox
$text.Text = "Initial "
$text.Height = 300
$text.AcceptsReturn = $true
$password = New-Object System.Windows.Controls.PasswordBox
$password.Height = 40
$panel.Children.Add($text) | Out-Null
$panel.Children.Add($password) | Out-Null
$window.Content = $panel
$window.Add_ContentRendered({$window.Activate(); $text.Focus(); $text.Select($text.Text.Length, 0)})
$window.ShowDialog() | Out-Null
''')
    editor = subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    async def exercise():
        from vibewalkie.windows import WindowsDesktop
        state = State(tmp_path / "state")
        host = Companion(state, {"hostName": "Integration Windows", "hostPlatform": "windows", "serviceName": "Integration"}, WindowsDesktop)
        try:
            listener = await host.start("127.0.0.1", 0)
            for attempt in range(100):
                try:
                    target = await host.desktop("capture_target")
                    assert "powershell" in target["name"].lower()
                    break
                except Exception:
                    if attempt == 99:
                        raise
                    await asyncio.sleep(0.1)
            client = Client(host, listener.sockets[0].getsockname()[1])
            assert (await client.connect())["decoded"]["hostPlatform"] == "windows"
            snapshot = await client.request("list_windows", {"includeIcons": True})
            assert any("Windows integration editor" in window["title"] for app in snapshot["decoded"]["applications"] for window in app["windows"])
            dictation = str(uuid.uuid4())
            started = await client.request("recording_started", {"locale": "fr-FR", "dictationID": dictation})
            assert started["type"] == "acknowledgement", started
            inserted = await client.request("insert_text", {"dictationID": dictation,
                "targetToken": started["decoded"]["targetToken"]["token"], "text": "Bonjour été 🌍"})
            assert inserted["decoded"].get("insertion", {}).get("verified") is True, inserted
            # Read a selection after a surrogate pair and insert a newline.
            # This detects UTF-16/Python-index confusion in both provider APIs.
            started = await client.request("recording_started", {"locale": "fr-FR", "dictationID": dictation})
            assert started["type"] == "acknowledgement", started
            inserted = await client.request("insert_text", {"dictationID": dictation,
                "targetToken": started["decoded"]["targetToken"]["token"], "text": "\nEncore café"})
            assert inserted["decoded"].get("insertion", {}).get("verified") is True, inserted
            await client.request("key_press", {"key": "tab"})
            await asyncio.sleep(0.1)
            secure = await client.request("recording_started", {"locale": "fr-FR", "dictationID": dictation})
            assert secure["decoded"]["code"] == "secure_field", secure
            await client.send("pointer_absolute", {"normalizedX": 0.4, "normalizedY": 0.4})
            await client.send("pointer_drag", {"phase": "began", "deltaX": 0, "deltaY": 0})
            await client.request("hello", {})
            assert host.backend.dragging
            await client.send("screen_stream_request", {"enabled": True, "maxWidth": 640, "framesPerSecond": 4, "jpegQuality": 0.4})
            while True:
                response = await asyncio.wait_for(read_envelope(client.reader), 10)
                if response["type"] == "screen_frame":
                    image = Image.open(io.BytesIO(unb64(response["decoded"]["jpegData"])))
                    assert image.width <= 640 and image.height > 0
                    assert len(set(image.get_flattened_data())) > 20
                    image.save(tmp_path / "windows-live-screen.png")
                    break
            await client.close()
            assert not host.backend.dragging
        finally:
            await host.stop()
            state.close()
    try:
        asyncio.run(exercise())
    finally:
        editor.terminate()
        editor.wait(timeout=10)
