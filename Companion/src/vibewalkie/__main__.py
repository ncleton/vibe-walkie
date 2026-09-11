"""Operator CLI. Pairing and shortcuts can only be approved/configured locally."""
import argparse
import asyncio
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys

from zeroconf import ServiceInfo, Zeroconf

from .protocol import PORT, b64, encode, now, parse_date, timestamp
from .server import Companion
from .state import Identity, State, atomic_write


def default_state():
    if sys.platform == "win32":
        root = os.environ.get("LOCALAPPDATA")
        if not root:
            raise RuntimeError("LOCALAPPDATA is missing. Launch the companion in your Windows user session.")
        return Path(root) / "VibeWalkie"
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "vibewalkie"


def tailscale_endpoint():
    executable = shutil.which("tailscale")
    if not executable and sys.platform == "win32":
        path = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Tailscale/tailscale.exe"
        if path.is_file():
            executable = str(path)
    if not executable:
        raise RuntimeError("Install and connect Tailscale, or specify --bind with this computer's private LAN IPv4 address.")
    result = subprocess.run([executable, "status", "--json"], check=True, capture_output=True, text=True, timeout=10)
    status = json.loads(result.stdout)
    if status.get("BackendState") != "Running":
        raise RuntimeError("Tailscale is not connected. Sign in to Tailscale on this computer and retry.")
    local = status["Self"]
    dns = local.get("DNSName", "").rstrip(".").lower()
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]{0,249}[a-z0-9])?\.ts\.net", dns):
        raise RuntimeError("Enable MagicDNS in your tailnet before using remote pairing.")
    address = next((ip for ip in local.get("TailscaleIPs", []) if ipaddress.ip_address(ip) in ipaddress.ip_network("100.64.0.0/10")), None)
    if address is None:
        raise RuntimeError("Tailscale did not provide a private IPv4 endpoint. Check its connection status.")
    return {"magicDNSName": dns, "ipv4Address": address, "port": PORT}


def validate_bind(address):
    parsed = ipaddress.ip_address(address)
    if parsed.version != 4 or parsed.is_unspecified or parsed.is_multicast or not (parsed.is_private or parsed in ipaddress.ip_network("100.64.0.0/10")):
        raise RuntimeError("Bind to a specific private LAN or Tailscale IPv4 address. Public and wildcard listeners are not supported.")
    return address


async def serve(args, state):
    if sys.platform == "win32":
        from .windows import WindowsDesktop
        factory, platform = WindowsDesktop, "windows"
    elif sys.platform == "linux":
        from .linux import LinuxDesktop
        factory, platform = LinuxDesktop, "linux"
    else:
        raise RuntimeError("Use the native Vibe Walkie Mac app on macOS. This companion runs on Windows or Linux.")
    endpoint = tailscale_endpoint() if args.bind == "auto" else None
    address = validate_bind(endpoint["ipv4Address"] if endpoint else args.bind)
    host_name = args.name or socket.gethostname()
    if not 1 <= len(host_name.encode("utf-8")) <= 60:
        raise RuntimeError("Choose a computer name between 1 and 60 UTF-8 bytes.")
    # Stable service name disambiguates hosts with the same visible name.
    identity = Identity(state.directory)
    suffix = identity.fingerprint.replace("/", "").replace("+", "")[:8]
    service_name = f"VibeWalkie-{suffix}"
    metadata = {"hostName": host_name, "hostPlatform": platform, "serviceName": service_name, "nomadEndpoint": endpoint}
    companion = Companion(state, metadata, factory)
    discovery = None
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        if sys.platform != "win32":
            loop.add_signal_handler(sig, stop.set)
    heartbeat = None
    try:
        await companion.start(address)
        if endpoint is None and not ipaddress.ip_address(address).is_loopback:
            discovery = Zeroconf(interfaces=[address])
            service = ServiceInfo("_viberemote._tcp.local.", f"{service_name}._viberemote._tcp.local.",
                                  addresses=[socket.inet_aton(address)], port=PORT,
                                  properties={"version": "4", "platform": platform}, server=f"{service_name}.local.")
            await discovery.async_register_service(service)

        async def update_heartbeat():
            while True:
                state.set_setting("runtime", {**metadata, "heartbeat": timestamp(), "pid": os.getpid()})
                await asyncio.sleep(5)

        heartbeat = asyncio.create_task(update_heartbeat())
        print(f"Vibe Walkie listening on {address}:{PORT} ({platform}). Run 'vibewalkie pair' to pair an iPhone.", flush=True)
        await stop.wait()
    finally:
        if heartbeat:
            heartbeat.cancel()
            await asyncio.gather(heartbeat, return_exceptions=True)
        if discovery:
            await discovery.async_unregister_all_services()
            await discovery.async_close()
        await companion.stop()
        state.set_setting("runtime", None)


def main():
    parser = argparse.ArgumentParser(description="Vibe Walkie Windows / Linux companion")
    parser.add_argument("--state-dir", type=Path, default=default_state())
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("serve", help="Run in an unlocked user desktop; Tailscale is the default private route")
    run.add_argument("--bind", default="auto", help="auto for Tailscale, or an explicit private LAN IPv4")
    run.add_argument("--name")
    pair = commands.add_parser("pair", help="Generate a ten-minute QR for a running companion")
    pair.add_argument("--qr", type=Path, help="Save a PNG for scanning or importing on iPhone")
    for name in ("approve", "deny"):
        command = commands.add_parser(name)
        command.add_argument("request_id")
        command.add_argument("code", help="Six digits displayed on the iPhone")
    commands.add_parser("pending")
    commands.add_parser("peers")
    revoke = commands.add_parser("revoke")
    revoke.add_argument("peer_id")
    shortcut = commands.add_parser("shortcut", help="Register a shortcut locally; clients only receive its opaque ID")
    shortcut.add_argument("id")
    shortcut.add_argument("name")
    shortcut.add_argument("keys", nargs="+", help="For example: control shift f")
    args = parser.parse_args()
    state = None
    try:
        state = State(args.state_dir)
        if args.command == "serve":
            asyncio.run(serve(args, state))
        elif args.command == "pair":
            metadata = state.setting("runtime")
            if not metadata or "heartbeat" not in metadata or (now() - parse_date(metadata["heartbeat"])).total_seconds() > 15:
                raise RuntimeError("No live companion is registered. Start 'vibewalkie serve' in the desktop session, then generate the QR.")
            identity = Identity(state.directory)
            qr = state.new_pairing(metadata, identity.fingerprint)
            encoded = b64(encode(qr))
            print(encoded)
            import qrcode
            image = qrcode.QRCode(border=2)
            image.add_data(encoded)
            image.make(fit=True)
            if args.qr:
                import io
                output = io.BytesIO()
                image.make_image().save(output, format="PNG")
                atomic_write(args.qr.absolute(), output.getvalue())
                print(f"Private QR saved to {args.qr}. Delete it after pairing.")
            else:
                image.print_ascii(invert=True)
        elif args.command in ("approve", "deny"):
            state.decide(args.request_id, args.code, args.command == "approve")
            print("Pairing approved." if args.command == "approve" else "Pairing denied.")
        elif args.command == "pending":
            rows = state.database.execute("SELECT id, name, code, expires FROM requests WHERE decision IS NULL AND expires > ?", (timestamp(),))
            for row in rows:
                print(json.dumps(dict(row), ensure_ascii=True))
        elif args.command == "peers":
            for row in state.database.execute("SELECT id, name, platform, revoked FROM peers"):
                print(json.dumps(dict(row), ensure_ascii=True))
        elif args.command == "revoke":
            state.revoke(args.peer_id)
            print("Device revoked. Active access is revoked on its next command or screen frame.")
        elif args.command == "shortcut":
            allowed = {"control", "shift", "alt", "super", "Return", "Escape", "Tab", "BackSpace", "Delete", "space", "Up", "Down", "Left", "Right"}
            allowed.update(f"F{i}" for i in range(1, 13))
            allowed.update("abcdefghijklmnopqrstuvwxyz0123456789")
            if not re.fullmatch(r"[a-zA-Z0-9_-]{1,96}", args.id) or not 1 <= len(args.keys) <= 4 or not set(args.keys) <= allowed:
                raise RuntimeError("Use an alphanumeric shortcut ID and 1–4 known keys (control, shift, alt, super, letters, digits, F1–F12 or standard key names).")
            if not 1 <= len(args.name) <= 80:
                raise RuntimeError("Shortcut names must contain 1–80 characters.")
            shortcuts = state.setting("shortcuts") or {}
            shortcuts[args.id] = {"name": args.name, "keys": args.keys}
            state.set_setting("shortcuts", shortcuts)
            print("Shortcut registered. Reconnect the iPhone to refresh the palette.")
    except KeyboardInterrupt:
        pass
    except Exception as error:
        print(f"Vibe Walkie: {error}", file=sys.stderr)
        return 1
    finally:
        if state:
            state.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
