#!/usr/bin/env bash
set -euo pipefail

# Vibe Walkie deliberately keeps dictation, keystrokes and screen pixels off
# disk and out of diagnostics. Android has a module-local version of this
# check; this guard covers the shipping Mac and Python companion sources.

mac_sources=(macOS/AppRemoteMac)
companion_sources=(Companion/src/vibewalkie/server.py Companion/src/vibewalkie/linux.py Companion/src/vibewalkie/windows.py)
ios_sources=(iOS/AppRemoteiOS iOS/AppRemoteControls iOS/SharedIntents)

if rg -n 'NSLog\([^\n]*(localizedDescription|error\.)|\b(print|os_log)\([^\n]*(localizedDescription|error\.)' "${mac_sources[@]}" --glob '*.swift'; then
  echo 'macOS diagnostics must not serialise raw system error descriptions.' >&2
  exit 1
fi

if rg -n 'detail:\s*error\.localizedDescription' "${mac_sources[@]}" --glob '*.swift'; then
  echo 'Network status sent to a mobile device must not contain raw system errors.' >&2
  exit 1
fi

if rg -n 'applicationError\s*=\s*error\.localizedDescription' "${ios_sources[@]}" --glob '*.swift'; then
  echo 'iPhone diagnostics must not persist raw error descriptions.' >&2
  exit 1
fi

for source in "${companion_sources[@]}"; do
  [[ -f "$source" ]] || { echo "Missing companion source: $source" >&2; exit 1; }
done

if rg -n '\b(print|logging\.(debug|info|warning|error|exception))\(' "${companion_sources[@]:1}"; then
  echo 'Desktop adapters must not log screen or input contents.' >&2
  exit 1
fi

# The server may print local pairing prompts and stable exception type names.
# Dictated text, screen bytes and raw exception messages must never enter them.
if rg -n 'print\(.*(payload\[.(text|jpegData|audio)|frame\.|error\.message|str\(error\))' "${companion_sources[0]}"; then
  echo 'Protocol diagnostics must not print remote contents or raw exceptions.' >&2
  exit 1
fi
