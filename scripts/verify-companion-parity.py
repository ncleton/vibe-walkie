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
parser.add_argument('--preflight', action='store_true')
parser.add_argument('--mac-source', type=Path, help='Current Mac publication source to compare with the port audit')
args = parser.parse_args()
reference = json.loads((root / 'Documentation/Validation/windows-parity/mac-reference.json').read_text(encoding="utf-8"))
errors = []
if args.mac_source:
    for filename, expected in reference['sourceSha256'].items():
        source = args.mac_source / filename
        if not source.is_file() or hashlib.sha256(source.read_bytes().replace(b'\r\n', b'\n')).hexdigest() != expected:
            errors.append(f'The current Mac source changed: {filename}. Port and validate Windows in the same change, then refresh the audit.')
for name in ('PostureTypes.swift', 'PostureAnalysisEngine.swift'):
    source = (root / 'Shared/PostureCore/Sources/PostureCore' / name).read_text(encoding="utf-8").lstrip('\n')
    for module in ('CoreGraphics', 'simd'):
        source = source.replace(f'#if canImport({module})\nimport {module}\n#endif', f'import {module}')
    expected = reference['sourceSha256'][f'macOS/AppRemoteMac/Posture/{name}']
    if hashlib.sha256(source.encode()).hexdigest() != expected:
        errors.append(f'The shared posture engine differs from the audited Mac source: {name}. Align both engines and rerun the camera and posture tests.')
current_mac_paths = sorted(path.relative_to(root).as_posix() for path in (root / "macOS/AppRemoteMac").rglob("*.swift"))
if current_mac_paths != reference["repositoryMacPaths"]:
    errors.append("Mac companion files were added or removed: update the Windows parity audit and tests.")
for filename, expected in reference['repositorySha256'].items():
    actual = hashlib.sha256((root / filename).read_bytes().replace(b'\r\n', b'\n')).hexdigest()
    if actual != expected:
        errors.append(f'{filename} changed: update Windows, shared contracts, tests and mac-reference.json in the same change.')
protocol = (root / 'Windows/VibeWalkie.Protocol/Protocol.cs').read_text(encoding="utf-8")
router = (root / 'Windows/VibeWalkie.Companion/Network/SessionRouter.cs').read_text(encoding="utf-8")
required = {'agent_target_request':'AgentTargetRequest','voice_control':'VoiceControl','voice_action':'VoiceAction',
    'work_walking_sessions_request':'WorkWalkingSessionsRequest','health_activity_snapshot_update':'HealthActivitySnapshotUpdate',
    'recording_started':'RecordingStarted','insert_text':'InsertText','keyboard_text':'KeyboardText','key_press':'KeyPress',
    'pointer_move':'PointerMove','pointer_absolute':'PointerAbsolute','pointer_click':'PointerClick','pointer_drag':'PointerDrag',
    'scroll':'Scroll','list_windows':'ListWindows','activate_window':'ActivateWindow','screen_stream_request':'ScreenStreamRequest',
    'host_shortcut_press':'HostShortcutPress','control_configuration_request':'ControlConfigurationRequest','control_configuration_update':'ControlConfigurationUpdate'}
for wire, name in required.items():
    if f'"{wire}"' not in protocol or f'RemoteMessageType.{name} =>' not in router:
        errors.append(f'Windows has no implemented route for {wire}.')
workflow = (root / '.github/workflows/native-companions.yml').read_text(encoding="utf-8")
if 'paths:' in workflow:
    errors.append('Windows CI must also run for Mac-only changes; remove path filtering.')
mac_release = (root / '.github/workflows/release-mac.yml').read_text(encoding="utf-8")
if 'scripts/require-windows-release.py' not in mac_release or 'verify-companion-parity.py --preflight' not in mac_release:
    errors.append('Mac publication must require real Windows readiness and the signed Windows release from the same commit.')
if args.release or args.preflight:
    evidence = root / 'Documentation/Validation/windows-parity/release-evidence.json'
    if not evidence.is_file():
        errors.append('Windows release evidence is absent: require real Windows 11 camera, native UI, LAN/Tailscale, UAC/lock/RDP tests, trusted MSIX signature and verified public App Installer.')
    else:
        results = json.loads(evidence.read_text(encoding="utf-8"))
        gates = ('windows11','camera','native_ui','lan','tailscale','lock_uac_rdp')
        if args.release: gates += ('trusted_msix','public_appinstaller')
        for gate in gates:
            if results.get(gate) is not True:
                errors.append(f'Windows release gate is not validated: {gate}.')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Mac/Windows contract guard passed. Runtime and release evidence remain separate.')
