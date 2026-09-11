#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CREDENTIALS_FILE="${ASC_CREDENTIALS_FILE:-$HOME/Library/Application Support/Vibe Walkie Release Tools/App Store Connect/credentials.env}"
if [[ -z "${NOTARY_PROFILE:-}" && -z "${ASC_KEY_PATH:-}" && -f "$CREDENTIALS_FILE" ]]; then
  # Les identifiants restent hors du dépôt et sont chargés automatiquement.
  # Une variable fournie explicitement conserve la priorité sur ce fichier.
  # shellcheck source=/dev/null
  source "$CREDENTIALS_FILE"
fi
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(date -u +%Y%m%d%H%M)}"
NOTES="${NOTES:-Améliorations de stabilité et d’expérience.}"
VPS_HOST="${VPS_HOST:-yaka-vps}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://app-remote.92.222.247.135.sslip.io}"
SIGN_IDENTITY="${DMG_SIGN_IDENTITY:-Developer ID Application: Benjamin Cleton (7XX6KYD3MY)}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/macos-update-$BUILD.noindex}"
ARCHIVE_PATH="$BUILD_DIR/VibeWalkie.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/Vibe Walkie.app"
DMG_PATH="$BUILD_DIR/VibeWalkie-$VERSION-$BUILD.dmg"
REMOTE_DMG="/tmp/vibe-walkie-$VERSION-$BUILD.dmg"

usage() {
  cat <<'USAGE'
Publie une mise à jour signée du compagnon Mac sur le canal mondial.

Variables facultatives :
  VERSION=1.0.1              version visible (x.y.z)
  BUILD=202609011530         build numérique, croissant
  NOTES="…"                  notes de version
  NOTARY_PROFILE=VibeWalkie  profil notarytool du Trousseau
  ASC_KEY_PATH=…             clé API App Store Connect hors dépôt
  ASC_KEY_ID=…               identifiant de cette clé
  ASC_ISSUER_ID=…            issuer de l’équipe App Store Connect
  ASC_CREDENTIALS_FILE=…     fichier local chargé automatiquement
  SKIP_BUILD=1               reprend depuis une archive déjà validée
  INSTALL_AFTER_PUBLISH=1   installe aussi cette build sur ce Mac
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "VERSION doit suivre x.y.z (reçu : $VERSION)" >&2
  exit 64
}
[[ "$BUILD" =~ ^[0-9]+$ ]] || {
  echo "BUILD doit être numérique (reçu : $BUILD)" >&2
  exit 64
}

command -v xcodebuild >/dev/null
command -v xcodegen >/dev/null
command -v ssh >/dev/null
command -v scp >/dev/null

# Empêche une ancienne copie de test d'intercepter le schéma de mise à jour ou
# de conserver le serveur pendant que la vraie app est publiée/installée.
"$ROOT_DIR/scripts/cleanup-macos-test-bundles.sh"

STABLE_SPARKLE_BIN="$HOME/Library/Application Support/Vibe Walkie Release Tools/Sparkle-2.9.6/bin"
SPARKLE_BIN="${SPARKLE_BIN:-$STABLE_SPARKLE_BIN}"
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
  SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" "$ROOT_DIR/build" "$ROOT_DIR/macOS/build-local" \
    -type f -path '*/Sparkle/bin/sign_update' -perm -111 2>/dev/null | head -1 || true)"
  [[ -n "$SIGN_UPDATE" ]] || {
    echo "Outil Sparkle sign_update introuvable. Ouvrez/compilez d’abord le projet Mac." >&2
    exit 69
  }
  SPARKLE_BIN="$(dirname "$SIGN_UPDATE")"
fi
[[ -x "$SPARKLE_BIN/sign_update" ]] || {
  echo "sign_update absent de $SPARKLE_BIN" >&2
  exit 69
}
codesign --verify --deep --strict "$SPARKLE_BIN/sign_update"

mkdir -p "$BUILD_DIR"

# Bloquant même en reprise d'archive : aucune mise à jour Sparkle ne doit
# contourner la porte dédiée aux régressions de pointeur.
POINTER_FLUIDITY_DERIVED_DATA="$BUILD_DIR/PointerFluidityDerivedData.noindex" \
  "$ROOT_DIR/scripts/verify-pointer-fluidity.sh"

if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  [[ -d "$APP_PATH" ]] || {
    echo "Archive à reprendre introuvable : $APP_PATH" >&2
    exit 66
  }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")" == "$VERSION" ]] || {
    echo "La version de l’archive ne correspond pas à VERSION=$VERSION." >&2
    exit 65
  }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")" == "$BUILD" ]] || {
    echo "Le build de l’archive ne correspond pas à BUILD=$BUILD." >&2
    exit 65
  }
  echo "→ Reprise de l’archive Vibe Walkie $VERSION ($BUILD)"
else
  echo "→ Build Vibe Walkie $VERSION ($BUILD)"
  (
    cd "$ROOT_DIR/macOS"
    xcodegen generate
  )
  xcodebuild archive \
    -project "$ROOT_DIR/macOS/AppRemoteMac.xcodeproj" \
    -scheme AppRemoteMac \
    -derivedDataPath "$BUILD_DIR/DerivedData.noindex" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    DEVELOPMENT_TEAM=7XX6KYD3MY \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")" == "com.nicolascleton.viberemote.mac" ]] || {
  echo "L'archive Mac n'utilise pas l'identité de production attendue." >&2
  exit 65
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$APP_PATH/Contents/Info.plist")" == "vibewalkie-mac" ]] || {
  echo "L'archive Mac n'utilise pas le schéma de mise à jour de production." >&2
  exit 65
}
APP_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/Vibe Walkie")"
[[ " $APP_ARCHS " == *" arm64 "* && " $APP_ARCHS " == *" x86_64 "* ]] || {
  echo "L'archive Mac doit contenir arm64 et x86_64 (reçu : $APP_ARCHS)." >&2
  exit 65
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$APP_PATH/Contents/Info.plist")" == "true" ]] || {
  echo "La build n’active pas les mises à jour automatiques." >&2
  exit 65
}

# Les exécutables auxiliaires livrés dans le framework Sparkle sont signés ad
# hoc dans le paquet Swift. Cette signature suffit au développement, mais le
# service de notarisation Apple exige une signature Developer ID horodatée sur
# chacun de ces composants. On les signe du plus profond au plus englobant,
# puis on referme le framework et l’application.
if [[ -n "${NOTARY_PROFILE:-}${ASC_KEY_PATH:-}" ]]; then
  SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/B"
  for component in \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc"
  do
    codesign \
      --force \
      --options runtime \
      --timestamp \
      --preserve-metadata=identifier,requirements,entitlements \
      --sign "$SIGN_IDENTITY" \
      "$component"
  done
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --preserve-metadata=identifier,requirements,entitlements \
    --sign "$SIGN_IDENTITY" \
    "$SPARKLE_FRAMEWORK"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --preserve-metadata=identifier,requirements,entitlements \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

if [[ -n "${NOTARY_PROFILE:-}${ASC_KEY_PATH:-}" ]]; then
  echo "→ DMG Developer ID, notarisation et agrafage"
else
  echo "→ DMG Developer ID"
fi
DMG_SIGN_IDENTITY="$SIGN_IDENTITY" \
NOTARY_PROFILE="${NOTARY_PROFILE:-}" \
ASC_KEY_PATH="${ASC_KEY_PATH:-}" \
ASC_KEY_ID="${ASC_KEY_ID:-}" \
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}" \
  "$ROOT_DIR/scripts/create-dmg.sh" "$APP_PATH" "$DMG_PATH"

SIGNATURE_OUTPUT="$("$SPARKLE_BIN/sign_update" "$DMG_PATH")"
ED_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$SIGNATURE_OUTPUT")"
SIGNED_LENGTH="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<< "$SIGNATURE_OUTPUT")"
ACTUAL_LENGTH="$(stat -f '%z' "$DMG_PATH")"
[[ -n "$ED_SIGNATURE" && "$SIGNED_LENGTH" == "$ACTUAL_LENGTH" ]] || {
  echo "Signature EdDSA Sparkle invalide." >&2
  exit 65
}

NOTES_B64="$(printf '%s' "$NOTES" | base64 | tr -d '\n')"
echo "→ Envoi chiffré vers $VPS_HOST"
scp -q "$DMG_PATH" "$VPS_HOST:$REMOTE_DMG"
ssh "$VPS_HOST" bash -s -- "$REMOTE_DMG" "$VERSION" "$BUILD" "$NOTES_B64" "$ED_SIGNATURE" "$PUBLIC_BASE_URL" <<'REMOTE'
set -euo pipefail
artifact="$1"
version="$2"
build="$3"
notes_b64="$4"
ed_signature="$5"
public_base_url="$6"
cleanup() { rm -f "$artifact"; }
trap cleanup EXIT
set -a
source /opt/app-remote/.env
set +a
curl --fail --silent --show-error \
  --request POST "$public_base_url/api/releases/macos/upload" \
  --header "Authorization: Bearer $RELEASE_DEPLOY_KEY" \
  --header "X-Release-Version: $version" \
  --header "X-Release-Build: $build" \
  --header "X-Release-Notes: $notes_b64" \
  --header "X-Release-Ed-Signature: $ed_signature" \
  --header 'Content-Type: application/octet-stream' \
  --data-binary "@$artifact"
REMOTE

echo
echo "→ Vérification de l’appcast et de l’archive servie"
APPCAST_PATH="$BUILD_DIR/appcast.xml"
DOWNLOADED_DMG="$BUILD_DIR/downloaded-$VERSION-$BUILD.dmg"
curl --fail --silent --show-error "$PUBLIC_BASE_URL/releases/macos/appcast.xml" -o "$APPCAST_PATH"
APPCAST_BUILD="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="version"])' "$APPCAST_PATH")"
APPCAST_SIGNATURE="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$APPCAST_PATH")"
APPCAST_CONTENT_TYPE="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@type)' "$APPCAST_PATH")"
DOWNLOAD_URL="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@url)' "$APPCAST_PATH")"
[[ "$APPCAST_BUILD" == "$BUILD" && "$APPCAST_SIGNATURE" == "$ED_SIGNATURE" ]] || {
  echo "L’appcast ne correspond pas à la build publiée." >&2
  exit 65
}
DOWNLOAD_PATH="${DOWNLOAD_URL%%\?*}"
[[ "$DOWNLOAD_PATH" == *.dmg && "$APPCAST_CONTENT_TYPE" == "application/x-apple-diskimage" ]] || {
  echo "L’appcast doit servir une URL .dmg avec le type application/x-apple-diskimage." >&2
  exit 65
}
DOWNLOAD_HEADERS="$BUILD_DIR/download-headers.txt"
curl --fail --silent --show-error --dump-header "$DOWNLOAD_HEADERS" "$DOWNLOAD_URL" -o "$DOWNLOADED_DMG"
REMOTE_CONTENT_TYPE="$(awk 'BEGIN { IGNORECASE=1 } /^content-type:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0 } END { print value }' "$DOWNLOAD_HEADERS")"
REMOTE_FILENAME="$(awk 'BEGIN { IGNORECASE=1 } /^content-disposition:/ { sub(/\r$/, ""); value=$0 } END { print value }' "$DOWNLOAD_HEADERS")"
[[ "$REMOTE_CONTENT_TYPE" == "application/x-apple-diskimage" && "$REMOTE_FILENAME" == *'.dmg"'* ]] || {
  echo "Le serveur ne renvoie pas un nom et un type de DMG reconnus par Sparkle." >&2
  exit 65
}
"$SPARKLE_BIN/sign_update" --verify "$DOWNLOADED_DMG" "$APPCAST_SIGNATURE"
cmp -s "$DMG_PATH" "$DOWNLOADED_DMG" || {
  echo "L’archive téléchargée diffère de celle envoyée." >&2
  exit 65
}

if [[ "${INSTALL_AFTER_PUBLISH:-0}" == "1" ]]; then
  echo "→ Installation locale de la build publiée"
  pkill -x 'Vibe Walkie' 2>/dev/null || true
  rm -rf "/Applications/Vibe Walkie.app"
  ditto "$APP_PATH" "/Applications/Vibe Walkie.app"
  "$ROOT_DIR/scripts/cleanup-macos-test-bundles.sh" --relaunch-installed
fi

# xcodebuild archive enregistre également son produit intermédiaire auprès de
# Launch Services. Il doit être retiré après publication, sinon un lien
# vibewalkie-mac peut rouvrir l'archive plutôt que /Applications.
"$ROOT_DIR/scripts/cleanup-macos-test-bundles.sh" --all-registered

echo "✓ Mise à jour mondiale publiée : $VERSION ($BUILD)"
echo "  Appcast : $PUBLIC_BASE_URL/releases/macos/appcast.xml"
echo "  DMG local : $DMG_PATH"
