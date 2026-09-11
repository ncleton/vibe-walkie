#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
if ! /usr/bin/python3 - "$SDK_VERSION" <<'PY'
import sys
version = tuple(int(part) for part in sys.argv[1].split('.')[:2])
sys.exit(0 if version >= (27, 1) else 1)
PY
then
  echo "iPhone Duo requires Xcode with iOS 27.1 SDK or newer. Selected SDK: $SDK_VERSION. Install Xcode 27.1 and select it with DEVELOPER_DIR before running this gate." >&2
  exit 1
fi

xcodebuild \
  -project "$ROOT/iOS/AppRemoteiOS.xcodeproj" \
  -scheme AppRemoteiOS \
  -destination 'generic/platform=iOS Simulator' \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) VIBE_WALKIE_DUO_SDK' \
  CODE_SIGNING_ALLOWED=NO \
  "$@" build
