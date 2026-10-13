#!/usr/bin/env python3
"""Fail on unreviewed Mac contract changes or missing Windows routes."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--release', action='store_true')
args = parser.parse_args()
reference = json.loads((root / 'Documentation/Validation/windows-parity/mac-reference.json').read_text())
errors = []
current_mac_paths = sorted(path.relative_to(root).as_posix() for path in (root / "macOS/AppRemoteMac").rglob("*.swift"))
if current_mac_paths != reference["repositoryMacPaths"]:
    errors.append("Mac companion files were added or removed: update the Windows parity audit and tests.")
for filename, expected in reference['repositorySha256'].items():
    actual = hashlib.sha256((root / filename).read_bytes().replace(b'\r\n', b'\n')).hexdigest()
    if actual != expected:
        errors.append(f'{filename} changed: update Windows, shared contracts, tests and mac-reference.json in the same change.')
protocol = (root / 'Windows/VibeWalkie.Protocol/Protocol.cs').read_text()
router = (root / 'Windows/VibeWalkie.Companion/Network/SessionRouter.cs').read_text()
required = {'agent_target_request':'AgentTargetRequest','voice_control':'VoiceControl','voice_action':'VoiceAction',
    'work_walking_sessions_request':'WorkWalkingSessionsRequest','health_activity_snapshot_update':'HealthActivitySnapshotUpdate',
    'recording_started':'RecordingStarted','insert_text':'InsertText','keyboard_text':'KeyboardText','key_press':'KeyPress',
    'pointer_move':'PointerMove','pointer_absolute':'PointerAbsolute','pointer_click':'PointerClick','pointer_drag':'PointerDrag',
    'scroll':'Scroll','list_windows':'ListWindows','activate_window':'ActivateWindow','screen_stream_request':'ScreenStreamRequest',
    'host_shortcut_press':'HostShortcutPress','control_configuration_request':'ControlConfigurationRequest','control_configuration_update':'ControlConfigurationUpdate'}
for wire, name in required.items():
    if f'"{wire}"' not in protocol or f'RemoteMessageType.{name} =>' not in router:
        errors.append(f'Windows has no implemented route for {wire}.')
workflow = (root / '.github/workflows/native-companions.yml').read_text()
if 'paths:' in workflow:
    errors.append('Windows CI must also run for Mac-only changes; remove path filtering.')
if args.release:
    evidence = root / 'Documentation/Validation/windows-parity/release-evidence.json'
    if not evidence.is_file():
        errors.append('Windows release evidence is absent: require real Windows 11 camera, native UI, LAN/Tailscale, UAC/lock/RDP tests, trusted MSIX signature and verified public App Installer.')
    else:
        results = json.loads(evidence.read_text())
        for gate in ('windows11','camera','native_ui','lan','tailscale','lock_uac_rdp','trusted_msix','public_appinstaller'):
            if results.get(gate) is not True:
                errors.append(f'Windows release gate is not validated: {gate}.')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Mac/Windows contract guard passed. Runtime and release evidence remain separate.')
