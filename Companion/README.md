# Vibe Walkie companion for Windows and Linux

The companion exposes the real desktop to the iPhone over the same pinned TLS
V4 protocol as the Mac app. It captures the primary display, controls the pointer
and keyboard, lists and activates windows, and verifies dictation in accessible
text fields. The iPhone keeps speech recognition on-device.

Windows requires an unlocked interactive user session. Linux requires X11,
AT-SPI and a window manager; the VPS launcher creates a real virtual desktop
with a terminal when no physical display exists. A bare SSH service does not
provide a screen and cannot substitute for this desktop.

## Install on Windows

Install Python 3.11 or newer with the Python launcher, and connect Tailscale.
From the repository in PowerShell:

```powershell
& .\Companion\scripts\install-windows.ps1
```

The installer creates a user-owned virtualenv and a Desktop shortcut. Run the
shortcut while logged in. It does not create a Session 0 service or elevate the
companion. To bind to a local network instead, run the installed executable with
`serve --bind 192.168.1.20`, substituting the computer's actual private address.

## Install on Linux

For Ubuntu 24.04 or compatible Debian systems:

```bash
sudo apt-get update
sudo apt-get install python3-venv python3-gi gir1.2-atspi-2.0 at-spi2-core \
  dbus-x11 xvfb xauth openbox xfce4-terminal
python3 -m venv --system-site-packages ~/.local/share/vibewalkie/venv
source ~/.local/share/vibewalkie/venv/bin/activate
python -m pip install ./Companion
```

From an existing X11 desktop, run `vibewalkie serve`. The default binds only to
the host's connected Tailscale IPv4. Enable MagicDNS and allow TCP 54389 from
the iPhone to the host in your tailnet policy. Nothing is opened publicly and
the companion does not modify Tailscale policies.

For a VPS without a desktop, activate the same virtualenv and run:

```bash
./Companion/scripts/start-vps-desktop.sh --name 'My VPS'
```

Xvfb provides a 1440 × 900 display, Openbox manages windows and xfce4-terminal
opens the actual user shell. The session remains alive while the launcher is
running, independently of the iPhone connection. To keep it running after SSH
disconnects, install the supplied systemd user service after the virtualenv:

```bash
install -m 755 Companion/scripts/start-vps-desktop.sh ~/.local/share/vibewalkie/start-vps-desktop
mkdir -p ~/.config/systemd/user
install -m 644 Companion/systemd/vibewalkie-vps.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now vibewalkie-vps.service
sudo loginctl enable-linger "$USER"
journalctl --user -u vibewalkie-vps.service -f
```

Stop an existing foreground launcher before starting the service. The unit uses
the connected Tailscale address. If Tailscale or a desktop component fails, it
logs the cause and retries with a limit; after fixing it, use
`systemctl --user reset-failed vibewalkie-vps` and
`systemctl --user restart vibewalkie-vps`. Stop it with
`systemctl --user stop vibewalkie-vps`.

Do not start it as root: remote commands have the desktop user's permissions.

The companion deliberately refuses a native Wayland session. Wayland support
requires a portal/PipeWire backend with explicit desktop consent; silently
controlling only XWayland windows would be incomplete.

## Pair and approve

In a second terminal on the same host, using the same virtualenv/user:

```bash
vibewalkie pair --qr pairing.png
vibewalkie pending
vibewalkie approve REQUEST_ID SIX_DIGIT_CODE
```

Scan or import the QR in the iPhone app, compare its six digits with the pending
request, and approve using the actual request ID and code. For remote pairing,
transfer the QR through your existing SSH connection. The QR is private, expires
after ten minutes and is consumed by one request; delete the image after use.
An approval must arrive within 60 seconds. Generating a QR alone grants no control.

Use `vibewalkie peers` and `vibewalkie revoke PEER_ID` to remove access. A revoked
device's next command or screen frame fails. Reconnecting never restores a revoked
identity without a new locally approved pairing.

## Configure shortcuts

```bash
vibewalkie shortcut search 'Search' control f
```

Reconnect the iPhone and select the new shortcut in its controls configurator.
Hardware key combinations stay on the host. The network carries only the chosen
shortcut's identifier and display metadata. Shell command strings and arbitrary
executable paths are not shortcut payloads.

## Data and failure handling

State lives in `%LOCALAPPDATA%\VibeWalkie` on Windows and
`~/.local/state/vibewalkie` on Linux. It contains the TLS identity, approved public
keys, configuration and expiring pairing requests. Unix modes / Windows ACLs limit
access to the current user (and Windows SYSTEM). No audio, transcripts or screen
history are persisted. Losing the private key requires pairing again; corrupted
identity files produce an explicit error and are never replaced silently.

The companion checks the focused element and selection again at dictation
insertion and consumes its token even on failure. Password fields reject dictation.
Windows verifies UI Automation TextPattern selections and standard Win32/WinForms
Edit selections. Linux dictation currently requires an AT-SPI EditableText field; terminal input is
available through the manual keyboard. A field that cannot confirm insertion
returns an error rather than claiming text was written. Manual input reports the
actual input-event method and its verification status separately.

Windows UAC, secure desktop, locked sessions and applications running at higher
integrity can block control. Dismissing UAC or unlocking Windows must happen through
the host's normal access mechanisms. An oversized screen frame stops with an
instruction to reduce quality; the protocol never grows an unbounded queue.

## Verify

```bash
python -m pip install './Companion[test]'
python -m pytest Companion/tests/test_protocol.py
docker build -f Companion/tests/Dockerfile -t vibewalkie-companion-test .
docker run --rm --init vibewalkie-companion-test
```

The Linux container starts Xvfb, Openbox and a real GTK editor. Integration tests
exercise a real TLS 1.3 connection, Ed25519 pairing with operator approval, Unicode
dictation, changed/secure targets, command deduplication, revocation and JPEG
capture. Windows must also be tested in a real interactive Windows session;
passing Linux tests does not validate Win32 APIs or RDP disconnection behavior.
