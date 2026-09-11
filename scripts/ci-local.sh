#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Xcode can retain a launched test host inside a persistent DerivedData tree.
# A unique temporary root gives every local CI run the same clean state as a
# GitHub Actions checkout, without deleting user build artefacts.
CI_DERIVED_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe-walkie-ci.XXXXXX")"
IOS_DERIVED_DATA="$CI_DERIVED_ROOT/ios"
MAC_DERIVED_DATA="$CI_DERIVED_ROOT/macos"
MAC_TEST_DERIVED_DATA="$CI_DERIVED_ROOT/macos-tests"
SIMULATOR_ID=""

cleanup_test_apps() {
  if [[ -n "$SIMULATOR_ID" ]]; then
    xcrun simctl uninstall "$SIMULATOR_ID" app.vibewalkie 2>/dev/null || true
    xcrun simctl uninstall "$SIMULATOR_ID" com.yakaperformance.appremote 2>/dev/null || true
  fi

  VIBE_WALKIE_PRODUCTS_DIR="$CI_DERIVED_ROOT" \
    "$ROOT/scripts/cleanup-macos-test-bundles.sh" --all-registered >/dev/null 2>&1 || true
  rm -rf -- "$CI_DERIVED_ROOT"
}

trap cleanup_test_apps EXIT

mkdir -p "$IOS_DERIVED_DATA" "$MAC_DERIVED_DATA" "$MAC_TEST_DERIVED_DATA"

swift test --package-path "$ROOT/Packages/RemoteCore"
bash "$ROOT/scripts/verify-privacy-invariants.sh"

if command -v xcodegen >/dev/null 2>&1; then
  (cd "$ROOT/iOS" && xcodegen generate)
  (cd "$ROOT/macOS" && xcodegen generate)
fi

xcodebuild \
  -project "$ROOT/iOS/AppRemoteiOS.xcodeproj" \
  -scheme AppRemoteiOS \
  -derivedDataPath "$IOS_DERIVED_DATA" \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

SIMULATOR_ID="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime, candidates in devices.items():
    if ".SimRuntime.iOS-" not in runtime:
        continue
    for device in candidates:
        if device.get("isAvailable"):
            print(device["udid"])
            raise SystemExit
')"
if [[ -z "$SIMULATOR_ID" ]]; then
  echo "Aucun simulateur iPhone disponible. Installez un runtime iOS dans Xcode." >&2
  exit 1
fi

xcodebuild test \
  -project "$ROOT/iOS/AppRemoteiOS.xcodeproj" \
  -scheme AppRemoteiOS \
  -derivedDataPath "$IOS_DERIVED_DATA" \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  CODE_SIGNING_ALLOWED=NO

# Cette porte reste distincte de la suite générale : elle vérifie aussi les
# invariants de cadence, de transport et de priorité qui ne se prouvent pas par
# une simple compilation. Les workflows de release appellent tous ci-local.
POINTER_FLUIDITY_DERIVED_DATA="$CI_DERIVED_ROOT/pointer-fluidity" \
  "$ROOT/scripts/verify-pointer-fluidity.sh"

xcodebuild \
  -project "$ROOT/macOS/AppRemoteMac.xcodeproj" \
  -scheme AppRemoteMac \
  -derivedDataPath "$MAC_DERIVED_DATA" \
  -configuration Debug \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build

MAC_APP="$MAC_DERIVED_DATA/Build/Products/Debug/Vibe Walkie.app"
MAC_ARCHS="$(lipo -archs "$MAC_APP/Contents/MacOS/Vibe Walkie")"
[[ " $MAC_ARCHS " == *" arm64 "* && " $MAC_ARCHS " == *" x86_64 "* ]] || {
  echo "La build Mac n'est pas universelle : $MAC_ARCHS" >&2
  exit 1
}

xcodebuild test \
  -project "$ROOT/macOS/AppRemoteMac.xcodeproj" \
  -scheme AppRemoteMac \
  -derivedDataPath "$MAC_TEST_DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY="-"

if command -v swiftlint >/dev/null 2>&1; then
  swiftlint lint --strict --config "$ROOT/.swiftlint.yml" \
    "$ROOT/Packages/RemoteCore/Sources" \
    "$ROOT/Packages/RemoteCore/Tests" \
    "$ROOT/iOS/AppRemoteControls" \
    "$ROOT/iOS/AppRemoteiOS" \
    "$ROOT/iOS/AppRemoteiOSTests" \
    "$ROOT/iOS/SharedIntents" \
    "$ROOT/macOS/AppRemoteMac" \
    "$ROOT/macOS/AppRemoteMacTests"
fi

if rg -n \
  'remoteHost|remotePort|keyboard_edit|keyboardEdit|_appremote\._tcp|com\.yakaperformance\.appremote|relais distant|accès à distance' \
  "$ROOT/Packages" "$ROOT/iOS" "$ROOT/macOS" \
  --glob '!**/Tests/**' --glob '!**/*Tests/**' \
  --glob '!**/build*/**' --glob '!**/.build/**' --glob '!**/*.xcodeproj/**'; then
  echo "Une référence interdite au prototype subsiste." >&2
  exit 1
fi
