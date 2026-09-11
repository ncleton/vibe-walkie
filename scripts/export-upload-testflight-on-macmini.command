#!/bin/bash
set -euo pipefail

project_root="${VIBE_WALKIE_PROJECT_ROOT:-/Volumes/Docker/App Remote}"
credentials="$HOME/Library/Application Support/Vibe Walkie Release Tools/App Store Connect/credentials.env"
log_file="$HOME/Desktop/Vibe Walkie TestFlight upload.log"

# shellcheck source=/dev/null
source "$credentials"
export ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_PATH

archive_path="${VIBE_WALKIE_ARCHIVE_PATH:-}"
if [[ -z "$archive_path" ]]; then
  archive_path="$(find "$project_root/build" -type d -name '*.xcarchive' -print0 \
    | xargs -0 ls -td \
    | head -1)"
fi
[[ -d "$archive_path" ]] || { echo "Archive iOS introuvable." >&2; exit 65; }

build="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$archive_path/Info.plist")"
export_path="$project_root/build/TestFlight/upload-$build"

POINTER_FLUIDITY_DERIVED_DATA="${TMPDIR:-/tmp}/vibe-walkie-pointer-fluidity-$build.noindex" \
  "$project_root/scripts/verify-pointer-fluidity.sh" 2>&1 | tee -a "$log_file"

cd "$project_root"
xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$project_root/Distribution/ExportOptions-TestFlight.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -quiet 2>&1 | tee "$log_file"

TESTFLIGHT_GROUPS="${TESTFLIGHT_GROUPS:-Équipe Vibe Walkie}" \
BUILD_NUMBER="$build" node "$project_root/scripts/publish-testflight.mjs" --wait --assign 2>&1 | tee -a "$log_file"
echo "TESTFLIGHT_BUILD=$build" | tee -a "$log_file"
