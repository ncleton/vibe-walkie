#!/bin/bash
set -euo pipefail

EXPECTED_APP_ID="${EXPECTED_APP_ID:-app.vibewalkie}"
EXPECTED_EXTENSION_ID="${EXPECTED_EXTENSION_ID:-app.vibewalkie.controls}"

usage() {
  echo "Usage: $0 <Vibe Walkie.ipa|VibeWalkie.xcarchive>" >&2
}

[[ $# -eq 1 ]] || {
  usage
  exit 64
}

artifact="$1"
[[ -e "$artifact" ]] || {
  echo "Artefact iOS introuvable : $artifact" >&2
  exit 66
}

read_plist_value() {
  local plist="$1"
  local key="$2"

  if [[ -d "$artifact" ]]; then
    plutil -extract "$key" raw -o - "$plist"
  else
    unzip -p "$artifact" "$plist" | plutil -extract "$key" raw -o - -
  fi
}

if [[ -d "$artifact" ]]; then
  app_plist="$artifact/Products/Applications/Vibe Walkie.app/Info.plist"
  extension_plist="$artifact/Products/Applications/Vibe Walkie.app/PlugIns/Vibe Walkie Controls.appex/Info.plist"
else
  [[ "$artifact" == *.ipa ]] || {
    usage
    exit 64
  }
  app_plist="$(unzip -Z1 "$artifact" | sed -n '/^Payload\/[^/]*\.app\/Info.plist$/p' | head -1)"
  extension_plist="$(unzip -Z1 "$artifact" | sed -n '/^Payload\/[^/]*\.app\/PlugIns\/[^/]*\.appex\/Info.plist$/p' | head -1)"
fi

[[ -n "$app_plist" && -n "$extension_plist" ]] || {
  echo "Vibe Walkie ou son extension est absente de l’artefact : $artifact" >&2
  exit 65
}

app_id="$(read_plist_value "$app_plist" CFBundleIdentifier)"
extension_id="$(read_plist_value "$extension_plist" CFBundleIdentifier)"

[[ "$app_id" == "$EXPECTED_APP_ID" ]] || {
  echo "Publication refusée : bundle iOS $app_id, attendu $EXPECTED_APP_ID." >&2
  echo "Un autre bundle installe une deuxième Vibe Walkie au lieu de mettre l’app à jour." >&2
  exit 65
}

[[ "$extension_id" == "$EXPECTED_EXTENSION_ID" ]] || {
  echo "Publication refusée : bundle extension $extension_id, attendu $EXPECTED_EXTENSION_ID." >&2
  exit 65
}

echo "✓ Identité iOS canonique : $app_id + $extension_id"
