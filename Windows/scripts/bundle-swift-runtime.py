"""Bundle the actual Swift executable's PE dependency closure, including VC DLLs."""
import argparse
import json
from pathlib import Path
import shutil
import pefile

parser = argparse.ArgumentParser()
parser.add_argument('--executable', type=Path, required=True)
parser.add_argument('--destination', type=Path, required=True)
parser.add_argument('--runtime-dir', type=Path, action='append', required=True)
args = parser.parse_args()
# OS dependencies for the supported Windows 11 baseline. VC redistributables
# deliberately aren't here: finding them on the build machine is insufficient.
system = set('advapi32.dll bcrypt.dll crypt32.dll dbghelp.dll iphlpapi.dll kernel32.dll ntdll.dll ole32.dll oleaut32.dll rpcrt4.dll secur32.dll shell32.dll shlwapi.dll user32.dll userenv.dll version.dll winmm.dll ws2_32.dll ucrtbase.dll'.split())
candidates = {}
for directory in args.runtime_dir:
    if directory.is_dir():
        for source in directory.glob('*.dll'):
            candidates[source.name.lower()] = source
if not args.executable.is_file():
    raise FileNotFoundError(f'The compiled posture engine is missing: {args.executable}')
args.destination.mkdir(parents=True, exist_ok=True)
pending = [args.executable]
visited = set()
copied = {}
os_imports = set()
while pending:
    source = pending.pop()
    if source.name.lower() in visited:
        continue
    visited.add(source.name.lower())
    target = args.destination / source.name
    if source.resolve() != target.resolve():
        shutil.copy2(source, target)
    with pefile.PE(str(source), fast_load=True) as binary:
        binary.parse_data_directories(directories=[
            pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT'],
            pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT']])
        imports = [entry.dll.decode('ascii').lower()
                   for kind in ('DIRECTORY_ENTRY_IMPORT', 'DIRECTORY_ENTRY_DELAY_IMPORT')
                   for entry in getattr(binary, kind, [])]
    for name in imports:
        if name in system or name.startswith(('api-ms-', 'ext-ms-')):
            os_imports.add(name)
            continue
        dependency = candidates.get(name)
        if dependency is None:
            raise FileNotFoundError(f'The self-contained posture bundle lacks {name}, imported by {source.name}. Repair the configured Swift SDK/runtime paths before publishing.')
        copied[name] = dependency.name
        pending.append(dependency)
if 'swiftcore.dll' not in copied:
    raise RuntimeError('The engine has no verifiable Swift runtime dependency.')
evidence = {'executable': args.executable.name, 'bundledDlls': sorted(copied.values()), 'windowsDlls': sorted(os_imports)}
(args.destination / 'runtime-dependencies.json').write_text(json.dumps(evidence, indent=2), encoding='utf-8')
print(f'Bundled {len(copied)} DLLs required by the actual Swift executable, with no compiler/debugger tool libraries.')
