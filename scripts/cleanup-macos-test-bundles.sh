#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
INSTALLED_SYSTEM_APP="/Applications/Vibe Walkie.app"
INSTALLED_USER_APP="$HOME/Applications/Vibe Walkie.app"
RELAUNCH_INSTALLED=0
ALL_REGISTERED=0
PRODUCTS_SCOPE="${VIBE_WALKIE_PRODUCTS_DIR:-}"

within_products_scope() {
  [[ -z "$PRODUCTS_SCOPE" || "$1" == "$PRODUCTS_SCOPE/"* ]]
}

is_vibe_walkie_bundle_identifier() {
  case "$1" in
    app.vibewalkie|com.nicolascleton.viberemote|com.nicolascleton.viberemote.mac|com.nicolascleton.viberemote.mac.debug|com.yakaperformance.appremote|com.yakaperformance.appremote.mac)
      return 0
      ;;
  esac
  return 1
}

bundle_identifier() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  [[ -f "$plist" ]] || plist="$app/Info.plist"
  [[ -f "$plist" ]] || return 1
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null
}

is_disposable_bundle_path() {
  local app="$1"
  [[ "$app" == "$HOME/Library/Developer/Xcode/DerivedData/"* \
    || "$app" == "$ROOT/build/"* \
    || "$app" == "$ROOT/macOS/build"* \
    || "$app" == "$HOME/.Trash/"* \
    || "$app" == /private/tmp/* \
    || "$app" == "${TMPDIR:-/tmp}/"* \
    || ( -n "${VIBE_WALKIE_PRODUCTS_DIR:-}" && "$app" == "$VIBE_WALKIE_PRODUCTS_DIR/"* ) ]]
}

remove_disposable_bundle() {
  local app="$1"
  # Les apps déplacées par Finder/Sparkle dans la Corbeille peuvent conserver
  # des ACL et attributs étendus qui rendent un `rm` ordinaire inopérant.
  if [[ "$app" == "$HOME/.Trash/"* ]]; then
    xattr -cr "$app" 2>/dev/null || true
    chflags -R nouchg,noschg "$app" 2>/dev/null || true
    chmod -R u+rwX "$app" 2>/dev/null || true
  fi
  rm -rf -- "$app" 2>/dev/null || true
}

for argument in "$@"; do
  case "$argument" in
    --relaunch-installed) RELAUNCH_INSTALLED=1 ;;
    --all-registered) ALL_REGISTERED=1 ;;
    *)
      echo "Usage: $0 [--relaunch-installed] [--all-registered]" >&2
      exit 64
      ;;
  esac
done

is_installed_executable() {
  local command="$1"
  [[ "$command" == "$INSTALLED_SYSTEM_APP/Contents/MacOS/"* \
    || "$command" == "$INSTALLED_USER_APP/Contents/MacOS/"* ]]
}

is_vibe_walkie_executable() {
  local command="$1"
  [[ "$command" == *"/Vibe Walkie.app/Contents/MacOS/"* \
    || "$command" == *"/Vibe Walkie Dev.app/Contents/MacOS/"* \
    || "$command" == *"/Vibe Remote.app/Contents/MacOS/"* \
    || "$command" == *"/App Remote.app/Contents/MacOS/"* ]]
}

has_running_app() {
  local pid command
  while read -r pid command; do
    if [[ -n "$pid" ]] && is_installed_executable "$command"; then
      return 0
    fi
  # `comm` returns the executable path only. Using the full command line here
  # can match (and kill) an unrelated shell whose arguments merely mention
  # "Vibe Walkie.app".
  done < <(ps axww -o pid=,comm=)
  return 1
}

# An unsigned/ad-hoc test host can outlive xcodebuild. Because older Debug
# builds shared the production bundle identifier and URL scheme, Launch
# Services could subsequently open that copy instead of /Applications. TCC
# then evaluated a different code requirement even though System Settings
# continued to show the production app as enabled.
while read -r pid command; do
  if [[ -z "$pid" ]] || ! is_vibe_walkie_executable "$command"; then
    continue
  fi
  within_products_scope "$command" || continue
  if ! is_installed_executable "$command"; then
    kill "$pid" 2>/dev/null || true
  elif [[ "$RELAUNCH_INSTALLED" == "1" ]]; then
    kill "$pid" 2>/dev/null || true
  fi
done < <(ps axww -o pid=,comm=)

if [[ -x "$LSREGISTER" ]]; then
  apps_to_unregister=()
  bundle_candidates=(
    "$HOME"/Library/Developer/Xcode/DerivedData/*/Build/Products/*/*.app
    "$ROOT"/build/*/Build/Products/*/*.app
    "$ROOT"/build/*/*DerivedData*/Build/Products/*/*.app
    "$ROOT"/build/*/*DerivedData*/Build/Intermediates.noindex/ArchiveIntermediates/*/InstallationBuildProductsLocation/Applications/*.app
    "$ROOT"/macOS/build*/Build/Products/*/*.app
    "$ROOT"/macOS/build*/DerivedData/Build/Products/*/*.app
    "${TMPDIR:-/tmp}"/vibe-walkie-*/Build/Products/*/*.app
    "${TMPDIR:-/tmp}"/vibe-walkie-*/*/Build/Products/*/*.app
    "${TMPDIR:-/tmp}"/VibeWalkie*/Build/Products/*/*.app
    /private/tmp/vibe-walkie-*/Build/Products/*/*.app
    /private/tmp/VibeWalkie*/Build/Products/*/*.app
    "$HOME"/.Trash/*.app
  )
  if [[ -n "${VIBE_WALKIE_PRODUCTS_DIR:-}" ]]; then
    while IFS= read -r -d '' app; do
      bundle_candidates+=("$app")
    done < <(find "$VIBE_WALKIE_PRODUCTS_DIR" -maxdepth 12 -type d -name '*.app' -prune -print0 2>/dev/null)
  fi

  # Retirer aussi les fichiers eux-mêmes est indispensable : Spotlight peut
  # réinscrire un bundle de test encore présent après un simple `lsregister -u`.
  for app in "${bundle_candidates[@]}"; do
    within_products_scope "$app" || continue
    [[ -d "$app" ]] || continue
    [[ "$app" == "$INSTALLED_SYSTEM_APP" || "$app" == "$INSTALLED_USER_APP" ]] && continue
    identifier="$(bundle_identifier "$app" || true)"
    is_vibe_walkie_bundle_identifier "$identifier" || continue
    apps_to_unregister+=("$app")
  done

  if [[ "$ALL_REGISTERED" == "1" ]]; then
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      within_products_scope "$app" || continue
      [[ "$app" == "$INSTALLED_SYSTEM_APP" || "$app" == "$INSTALLED_USER_APP" ]] && continue
      # `lsregister -u` sait aussi retirer une entrée dont le bundle a déjà
      # disparu du disque. Ces chemins orphelins peuvent sinon rester affichés
      # comme une seconde app dans Confidentialité et sécurité.
      apps_to_unregister+=("$app")
    done < <(
      "$LSREGISTER" -dump 2>/dev/null | awk '
        /^path:/ {
          path = $0
          sub(/^path:[[:space:]]*/, "", path)
          sub(/[[:space:]]+\(0x[[:xdigit:]]+\)$/, "", path)
        }
        /^identifier:[[:space:]]+(app\.vibewalkie|com\.nicolascleton\.viberemote(\.mac(\.debug)?)?|com\.yakaperformance\.appremote(\.mac)?)$/ {
          print path
        }
      '
    )
  fi

  # Launch Services sérialise ses écritures dans une base partagée. Plusieurs
  # `lsregister -u` simultanés peuvent tous réussir tout en réintroduisant les
  # entrées écrites par un autre processus. On les retire donc séquentiellement
  # afin que les archives de build ne réapparaissent pas dans les réglages TCC.
  for app in "${apps_to_unregister[@]}"; do
    "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    if [[ -d "$app" ]] && is_disposable_bundle_path "$app"; then
      remove_disposable_bundle "$app"
    fi
  done
  if [[ -z "$PRODUCTS_SCOPE" ]]; then
    "$LSREGISTER" -gc >/dev/null 2>&1 || true

  if [[ -d "$INSTALLED_SYSTEM_APP" ]]; then
    "$LSREGISTER" -f -R "$INSTALLED_SYSTEM_APP" >/dev/null 2>&1 || true
  elif [[ -d "$INSTALLED_USER_APP" ]]; then
    "$LSREGISTER" -f -R "$INSTALLED_USER_APP" >/dev/null 2>&1 || true
  fi
  fi
fi

if [[ "$RELAUNCH_INSTALLED" == "1" ]]; then
  installed_app=""
  if [[ -d "$INSTALLED_SYSTEM_APP" ]]; then
    installed_app="$INSTALLED_SYSTEM_APP"
  elif [[ -d "$INSTALLED_USER_APP" ]]; then
    installed_app="$INSTALLED_USER_APP"
  fi
  [[ -n "$installed_app" ]] || {
    echo "Aucune copie installée de Vibe Walkie n'a été trouvée." >&2
    exit 66
  }

  for _ in {1..20}; do
    if ! has_running_app; then
      break
    fi
    sleep 0.1
  done
  /usr/bin/open "$installed_app"
fi
