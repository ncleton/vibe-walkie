#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CREDENTIALS_FILE="${ASC_CREDENTIALS_FILE:-$HOME/Library/Application Support/Vibe Walkie Release Tools/App Store Connect/credentials.env}"
if [[ -z "${ASC_KEY_PATH:-}" && -f "$CREDENTIALS_FILE" ]]; then
  # Les identifiants restent hors du dépôt. Ils permettent à Xcode de créer
  # un profil Ad Hoc à jour lorsque les capabilities (HealthKit, par exemple)
  # changent, sans dépendre d'une session Apple interactive.
  # shellcheck disable=SC1090
  source "$CREDENTIALS_FILE"
fi
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(date -u +%Y%m%d%H%M)}"
NOTES="${NOTES:-Améliorations de stabilité et d’expérience.}"
DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-99QF92KRR7}}"
VPS_HOST="${VPS_HOST:-yaka-vps}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://app-remote.92.222.247.135.sslip.io}"
DEVICE_UDID="${DEVICE_UDID:-00008120-001260191462201E}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/ios-ota-$BUILD.noindex}"
ARCHIVE_PATH="$BUILD_DIR/VibeWalkie.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
REMOTE_IPA="/tmp/vibe-walkie-$BUILD.ipa"
INSTALL_ICON="$ROOT_DIR/iOS/AppRemoteiOS/Assets.xcassets/VibeWalkieAppIcon.appiconset/VibeWalkieAppIcon-1024.png"
REMOTE_ICON="/tmp/vibe-walkie-$BUILD-icon.png"
MANUAL_EXPORT_OPTIONS="$ROOT_DIR/Distribution/ExportOptions-OTA-Manual.plist"
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  # Une clé App Store Connect permet à Xcode de récupérer un profil à jour
  # avec toutes les capabilities de la build (HealthKit notamment).
  DEFAULT_EXPORT_OPTIONS="$ROOT_DIR/Distribution/ExportOptions-OTA.plist"
elif [[ -f "$MANUAL_EXPORT_OPTIONS" ]]; then
  DEFAULT_EXPORT_OPTIONS="$MANUAL_EXPORT_OPTIONS"
else
  DEFAULT_EXPORT_OPTIONS="$ROOT_DIR/Distribution/ExportOptions-OTA.plist"
fi
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$DEFAULT_EXPORT_OPTIONS}"

usage() {
  cat <<'USAGE'
Publie une build iPhone Ad Hoc sur le canal OTA privé.

Variables facultatives :
  VERSION=1.0.0
  BUILD=202609031330
  NOTES="Correctifs…"
  DEVICE_UDID=00008120-001260191462201E
  EXPORT_OPTIONS_PLIST=Distribution/ExportOptions-OTA-Manual.plist
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

for command in xcodebuild xcodegen unzip codesign security ssh scp curl plutil shasum; do
  command -v "$command" >/dev/null || {
    echo "Commande absente : $command" >&2
    exit 69
  }
done
test -f "$ROOT_DIR/Localization/locale-manifest.json"
test -f "$EXPORT_OPTIONS_PLIST"
test -f "$INSTALL_ICON"

authentication_arguments=()
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  authentication_arguments+=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

mkdir -p "$BUILD_DIR"
(
  cd "$ROOT_DIR/iOS"
  xcodegen generate
)

POINTER_FLUIDITY_DERIVED_DATA="$BUILD_DIR/PointerFluidityDerivedData.noindex" \
  "$ROOT_DIR/scripts/verify-pointer-fluidity.sh"

echo "→ Archive iPhone OTA $VERSION ($BUILD)"
xcodebuild archive \
  -project "$ROOT_DIR/iOS/AppRemoteiOS.xcodeproj" \
  -scheme AppRemoteiOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$BUILD_DIR/DerivedData.noindex" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) OTA_UPDATES" \
  -allowProvisioningUpdates \
  "${authentication_arguments[@]}"

echo "→ Export Ad Hoc"
rm -rf "$EXPORT_DIR"
export_arguments=(
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_DIR"
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)
if [[ "$EXPORT_OPTIONS_PLIST" != "$MANUAL_EXPORT_OPTIONS" ]]; then
  export_arguments+=(-allowProvisioningUpdates)
fi
xcodebuild "${export_arguments[@]}" "${authentication_arguments[@]}"

IPA_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
[[ -n "$IPA_PATH" ]] || {
  echo "IPA introuvable après export." >&2
  exit 65
}

VERIFY_DIR="$BUILD_DIR/verify"
rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"
unzip -q "$IPA_PATH" -d "$VERIFY_DIR"
APP_PATH="$(find "$VERIFY_DIR/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP_PATH" ]] || {
  echo "Application introuvable dans l’IPA." >&2
  exit 65
}

EXPECTED_APP_ID="${EXPECTED_APP_ID:-app.vibewalkie}"
EXPECTED_EXTENSION_ID="${EXPECTED_EXTENSION_ID:-app.vibewalkie.controls}"
ACTUAL_BUNDLE="$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Info.plist")"
ACTUAL_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP_PATH/Info.plist")"
[[ "$ACTUAL_BUNDLE" == "$EXPECTED_APP_ID" && "$ACTUAL_BUILD" == "$BUILD" ]] || {
  echo "Identité IPA invalide : $ACTUAL_BUNDLE ($ACTUAL_BUILD)." >&2
  exit 65
}

EXTENSION_PLIST="$APP_PATH/PlugIns/Vibe Walkie Controls.appex/Info.plist"
ACTUAL_EXTENSION_BUNDLE="$(plutil -extract CFBundleIdentifier raw -o - "$EXTENSION_PLIST")"
[[ "$ACTUAL_EXTENSION_BUNDLE" == "$EXPECTED_EXTENSION_ID" ]] || {
  echo "Bundle de l’extension invalide : $ACTUAL_EXTENSION_BUNDLE." >&2
  exit 65
}
strings "$APP_PATH/Vibe Walkie" | grep -Fq "$PUBLIC_BASE_URL/api/releases/ios/check" || {
  echo "Le contrôle OTA n’est pas compilé dans l’application." >&2
  exit 65
}

PROFILE_PLIST="$VERIFY_DIR/profile.plist"
security cms -D -i "$APP_PATH/embedded.mobileprovision" > "$PROFILE_PLIST"
plutil -extract ProvisionedDevices json -o - "$PROFILE_PLIST" | grep -Fq "$DEVICE_UDID" || {
  echo "L’iPhone attendu n’est pas inclus dans le profil Ad Hoc." >&2
  exit 65
}
codesign --verify --deep --strict "$APP_PATH"

NOTES_B64="$(printf '%s' "$NOTES" | base64 | tr -d '\n')"
echo "→ Publication chiffrée vers $VPS_HOST"
scp -q "$IPA_PATH" "$VPS_HOST:$REMOTE_IPA"
scp -q "$INSTALL_ICON" "$VPS_HOST:$REMOTE_ICON"
ssh "$VPS_HOST" bash -s -- "$REMOTE_IPA" "$REMOTE_ICON" "$VERSION" "$BUILD" "$NOTES_B64" "$PUBLIC_BASE_URL" <<'REMOTE'
set -euo pipefail
artifact="$1"
icon_artifact="$2"
version="$3"
build="$4"
notes_b64="$5"
public_base_url="$6"
cleanup() { rm -f "$artifact" "$icon_artifact"; }
trap cleanup EXIT
set -a
source /opt/app-remote/.env
set +a
curl --fail --silent --show-error \
  --request POST "$public_base_url/api/releases/ios/upload" \
  --header "Authorization: Bearer $RELEASE_DEPLOY_KEY" \
  --header "X-Release-Version: $version" \
  --header "X-Release-Build: $build" \
  --header "X-Release-Notes: $notes_b64" \
  --header "X-Release-Force: false" \
  --header 'Content-Type: application/octet-stream' \
  --data-binary "@$artifact"
install -m 0644 "$icon_artifact" /opt/app-remote/data/ios/icon.png
REMOTE

echo
echo "→ Vérification distante"
CHECK_PATH="$BUILD_DIR/check.json"
MANIFEST_PATH="$BUILD_DIR/manifest.plist"
DOWNLOADED_IPA="$BUILD_DIR/downloaded-$BUILD.ipa"
curl --fail --silent --show-error "$PUBLIC_BASE_URL/api/releases/ios/check" -o "$CHECK_PATH"
PUBLISHED_BUILD="$(plutil -extract latestBuild raw -o - "$CHECK_PATH")"
MANIFEST_URL="$(plutil -extract manifestUrl raw -o - "$CHECK_PATH")"
[[ "$PUBLISHED_BUILD" == "$BUILD" ]] || {
  echo "Le service OTA annonce la build $PUBLISHED_BUILD au lieu de $BUILD." >&2
  exit 65
}
curl --fail --silent --show-error "$MANIFEST_URL" -o "$MANIFEST_PATH"
MANIFEST_BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :items:0:metadata:bundle-identifier' "$MANIFEST_PATH")"
DOWNLOAD_URL="$(/usr/libexec/PlistBuddy -c 'Print :items:0:assets:0:url' "$MANIFEST_PATH")"
[[ "$MANIFEST_BUNDLE" == "$ACTUAL_BUNDLE" ]] || {
  echo "Bundle du manifeste invalide : $MANIFEST_BUNDLE." >&2
  exit 65
}
curl --fail --silent --show-error "$DOWNLOAD_URL" -o "$DOWNLOADED_IPA"
[[ "$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')" == "$(shasum -a 256 "$DOWNLOADED_IPA" | awk '{print $1}')" ]] || {
  echo "L’IPA téléchargée diffère de l’IPA publiée." >&2
  exit 65
}

echo "✓ Mise à jour iPhone OTA publiée : $VERSION ($BUILD)"
echo "  Installation : $PUBLIC_BASE_URL/install/ios"
echo "  IPA locale : $IPA_PATH"
