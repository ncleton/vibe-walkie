#!/bin/bash
# Archive iOS dans la session graphique du Mac mini : c'est nécessaire pour
# utiliser les clés privées du Trousseau login sans exposer leur mot de passe.
set -euo pipefail

project_root="${VIBE_WALKIE_PROJECT_ROOT:-/Volumes/Docker/App Remote}"
credentials="$HOME/Library/Application Support/Vibe Walkie Release Tools/App Store Connect/credentials.env"
login="$HOME/Library/Keychains/login.keychain-db"
legacy="$HOME/Library/Keychains/yakacrm-build.keychain-db"
build_keychain="$HOME/Library/Keychains/vibe-walkie-99QF92KRR7.keychain-db"
build_keychain_password="$HOME/Library/Application Support/Vibe Walkie Release Tools/Signing/99QF92KRR7/p12.pass"
log_file="$HOME/Desktop/App Remote iOS archive.log"

if [[ -f "$credentials" ]]; then
  # shellcheck source=/dev/null
  source "$credentials"
fi
DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-99QF92KRR7}}"

restore_keychains() {
  security list-keychains -d user -s "$build_keychain" "$legacy" "$login" >/dev/null 2>&1 || true
}
trap restore_keychains EXIT

if [[ -f "$build_keychain" && -f "$build_keychain_password" ]]; then
  security unlock-keychain -p "$(<"$build_keychain_password")" "$build_keychain"
  security list-keychains -d user -s "$build_keychain" "$login"
else
  security list-keychains -d user -s "$login"
fi
cd "$project_root"

build="${VIBE_WALKIE_BUILD:-$(date -u +%Y%m%d%H%M)}"
archive_path="${VIBE_WALKIE_ARCHIVE_PATH:-$project_root/build/OTA/VibeWalkie-1.0.0-$build-macmini.xcarchive}"
extra_settings=()
authentication_args=()
if [[ "${VIBE_WALKIE_OTA:-0}" == "1" ]]; then
  extra_settings+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=OTA_UPDATES")
fi
if [[ -n "${ASC_PRIVATE_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  authentication_args+=(
    -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

if [[ "${VIBE_WALKIE_EXPORT_ONLY:-0}" != "1" ]]; then
  POINTER_FLUIDITY_DERIVED_DATA="${TMPDIR:-/tmp}/vibe-walkie-pointer-fluidity-$build.noindex" \
    "$project_root/scripts/verify-pointer-fluidity.sh" 2>&1 | tee -a "$log_file"

  set +u
  xcodebuild archive \
    -project iOS/AppRemoteiOS.xcodeproj \
    -scheme AppRemoteiOS \
    -configuration Release \
    -archivePath "$archive_path" \
    -destination generic/platform=iOS \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    MARKETING_VERSION=1.0.0 \
    CURRENT_PROJECT_VERSION="$build" \
    "${extra_settings[@]}" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    "${authentication_args[@]}" \
    -quiet 2>&1 | tee "$log_file"
  set -u
  "$project_root/scripts/verify-ios-app-identity.sh" "$archive_path" | tee -a "$log_file"
fi

if [[ "${VIBE_WALKIE_OTA:-0}" == "1" ]]; then
  if [[ "${VIBE_WALKIE_MANUAL_SIGNING:-0}" == "1" ]]; then
    default_export_options="$project_root/Distribution/ExportOptions-OTA-Manual.plist"
    default_export_path="$project_root/build/OTA/export-update-fix-$build-manual"
  else
    default_export_options="$project_root/build/OTA/ExportOptions.plist"
    default_export_path="$project_root/build/OTA/export-update-fix-$build-automatic"
  fi
  export_path="${VIBE_WALKIE_EXPORT_PATH:-$default_export_path}"
  export_options="${VIBE_WALKIE_EXPORT_OPTIONS:-$default_export_options}"
  xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$export_options" \
    -allowProvisioningUpdates \
    -quiet 2>&1 | tee -a "$log_file"
  ipa_path="$(find "$export_path" -maxdepth 2 -name '*.ipa' -print -quit)"
  [[ -n "$ipa_path" ]] || {
    echo "IPA exportée introuvable dans $export_path" | tee -a "$log_file" >&2
    exit 65
  }
  "$project_root/scripts/verify-ios-app-identity.sh" "$ipa_path" | tee -a "$log_file"
  echo "VIBE_WALKIE_EXPORT_PATH=$export_path" | tee -a "$log_file"
fi

echo "VIBE_WALKIE_BUILD=$build" | tee -a "$log_file"
echo "VIBE_WALKIE_ARCHIVE_PATH=$archive_path" | tee -a "$log_file"
echo "Archive terminée : $log_file"
