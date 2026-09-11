#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKPAD_SOURCE="$ROOT_DIR/iOS/AppRemoteiOS/RemoteControl/TrackpadView.swift"
CLIENT_SOURCE="$ROOT_DIR/iOS/AppRemoteiOS/Connection/MacConnectionClient.swift"
SERVER_SOURCE="$ROOT_DIR/macOS/AppRemoteMac/Connection/MacConnectionServer.swift"
ROUTER_SOURCE="$ROOT_DIR/macOS/AppRemoteMac/Connection/SessionRouter.swift"
SCREEN_SOURCE="$ROOT_DIR/macOS/AppRemoteMac/Screen/ScreenCaptureService.swift"
POINTER_SOURCE="$ROOT_DIR/macOS/AppRemoteMac/Input/CGEventFactory.swift"
CAMERA_SOURCE="$ROOT_DIR/macOS/AppRemoteMac/Posture/PostureCameraService.swift"
MAC_APP_SOURCE="$ROOT_DIR/macOS/AppRemoteMac/AppRemoteMacApp.swift"
DERIVED_DATA="${POINTER_FLUIDITY_DERIVED_DATA:-${TMPDIR:-/tmp}/vibe-walkie-pointer-fluidity.noindex}"
MAC_DERIVED_DATA="${DERIVED_DATA}-mac"

cleanup_pointer_test_app() {
  for products in "$DERIVED_DATA/Build/Products" "$MAC_DERIVED_DATA/Build/Products"; do
    VIBE_WALKIE_PRODUCTS_DIR="$products" \
      "$ROOT_DIR/scripts/cleanup-macos-test-bundles.sh" --all-registered >/dev/null 2>&1 || true
  done
}

# xcodebuild enregistre le produit iPhone Simulator auprès de Launch Services.
# Sans nettoyage de sortie, il réapparaît ensuite comme une autre Vibe Walkie.
trap cleanup_pointer_test_app EXIT

require_source_invariant() {
  local pattern="$1"
  local file="$2"
  local message="$3"
  if ! rg --quiet --fixed-strings "$pattern" "$file"; then
    echo "Fluidité curseur bloquée : $message" >&2
    exit 65
  fi
}

require_source_invariant \
  'static let minimumFramesPerSecond = 60' \
  "$TRACKPAD_SOURCE" \
  "la cadence minimale de 60 Hz a disparu."
require_source_invariant \
  'static let maximumFramesPerSecond = 120' \
  "$TRACKPAD_SOURCE" \
  "la prise en charge 120 Hz a disparu."
require_source_invariant \
  'displayLink.preferredFrameRateRange = CAFrameRateRange(' \
  "$TRACKPAD_SOURCE" \
  "les envois ne sont plus synchronisés sur l'écran."
require_source_invariant \
  'client.sendPointerMove(' \
  "$TRACKPAD_SOURCE" \
  "le pavé tactile contourne la file bornée des déplacements."
require_source_invariant \
  'pointerMoveSendInFlight = true' \
  "$CLIENT_SOURCE" \
  "la pile réseau peut de nouveau accumuler une file de mouvements périmés."
require_source_invariant \
  'self.flushPendingPointerMove()' \
  "$CLIENT_SOURCE" \
  "les deltas coalescés ne sont plus vidés après chaque envoi."
require_source_invariant \
  'acknowledgedPointerMovesEnabled' \
  "$CLIENT_SOURCE" \
  "le client ne vérifie plus l’application réelle des mouvements par le Mac."
require_source_invariant \
  'case .gestureAcknowledged:' \
  "$SERVER_SOURCE" \
  "le Mac n’accuse plus réception après injection réelle du pointeur."
require_source_invariant 'tcp.noDelay = true' "$CLIENT_SOURCE" \
  "TCP noDelay a disparu du client iPhone."
require_source_invariant 'tcp.noDelay = true' "$SERVER_SOURCE" \
  "TCP noDelay a disparu du compagnon Mac."
require_source_invariant \
  'RateLimiter(capacity: 240, refillPerSecond: 180)' \
  "$ROUTER_SOURCE" \
  "le budget Mac ne permet plus le pointeur 120 Hz."
require_source_invariant 'qos: .utility' "$CAMERA_SOURCE" \
  "Vision concurrence de nouveau les entrées interactives en haute priorité."
require_source_invariant 'latestScreenImage' "$CLIENT_SOURCE" \
  "les JPEG de l’écran peuvent de nouveau être décompressés dans la vue du trackpad."
require_source_invariant 'qos: .userInitiated' "$SCREEN_SOURCE" \
  "l’encodage de l’écran concurrence de nouveau le pointeur en priorité maximale."
require_source_invariant 'RelativePointerIntegrator' "$POINTER_SOURCE" \
  "le Mac relit de nouveau une position système potentiellement en retard entre deux deltas."
require_source_invariant \
  'static let analysisFramesPerSecond = 5.0' \
  "$CAMERA_SOURCE" \
  "la fréquence d'analyse caméra n'est plus bornée à 5 Hz."
require_source_invariant \
  'static let cameraFramesPerSecond = 15.0' \
  "$CAMERA_SOURCE" \
  "la capture caméra n'est plus bornée à 15 FPS."
require_source_invariant \
  'static let body3DFramesPerSecond = 1.0' \
  "$CAMERA_SOURCE" \
  "Vision 3D peut de nouveau monopoliser le Mac en continu."
require_source_invariant \
  'autoreleaseFrequency: .workItem' \
  "$CAMERA_SOURCE" \
  "les objets temporaires Vision peuvent s'accumuler entre les analyses."
require_source_invariant 'final class ExclusiveProcessLock' "$MAC_APP_SOURCE" \
  "le verrou empêchant deux compagnons simultanés a disparu."
require_source_invariant 'NSWorkspace.didLaunchApplicationNotification' "$MAC_APP_SOURCE" \
  "l'app installée ne surveille plus le lancement d'une copie de développement."

for products in "$DERIVED_DATA/Build/Products" "$MAC_DERIVED_DATA/Build/Products"; do
  VIBE_WALKIE_PRODUCTS_DIR="$products" "$ROOT_DIR/scripts/cleanup-macos-test-bundles.sh" >/dev/null 2>&1 || true
done
development_copy_running=0
while IFS= read -r command; do
  [[ "$command" == *"/Vibe Walkie.app/Contents/MacOS/Vibe Walkie" ]] || continue
  [[ "$command" == "/Applications/"* ]] && continue
  [[ "$command" == "$HOME/Applications/"* ]] && continue
  development_copy_running=1
  break
done < <(ps axww -o comm=)
if [[ "$development_copy_running" == "1" ]]; then
  echo "Fluidité curseur bloquée : une copie de développement Vibe Walkie tourne encore." >&2
  exit 65
fi

if rg --quiet 'minimumFlushInterval.*1\.0 / 30\.0|preferredFramesPerSecond\s*=\s*30' \
  "$TRACKPAD_SOURCE"; then
  echo "Fluidité curseur bloquée : une limitation à 30 Hz a été réintroduite." >&2
  exit 65
fi

# Cette liste constitue la cartographie des voies de sortie. Si un nouveau
# canal est ajouté, il doit lui aussi invoquer explicitement la porte avant de
# pouvoir produire ou publier un artefact.
for guarded_release in \
  "$ROOT_DIR/scripts/ci-local.sh" \
  "$ROOT_DIR/scripts/publish-ios-ota.sh" \
  "$ROOT_DIR/scripts/publish-macos-update.sh" \
  "$ROOT_DIR/scripts/archive-ios-on-macmini.command" \
  "$ROOT_DIR/scripts/export-upload-testflight-on-macmini.command" \
  "$ROOT_DIR/.github/workflows/ci.yml" \
  "$ROOT_DIR/.github/workflows/release-ios.yml" \
  "$ROOT_DIR/.github/workflows/release-mac.yml"
do
  require_source_invariant \
    'verify-pointer-fluidity.sh' \
    "$guarded_release" \
    "$(basename "$guarded_release") peut publier sans vérifier le curseur."
done

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
  echo "Fluidité curseur non vérifiée : aucun simulateur iOS disponible." >&2
  exit 69
fi

echo "→ Garde-fou fluidité curseur (60/120 Hz + coalescence sans perte)"
xcodebuild -quiet test \
  -project "$ROOT_DIR/iOS/AppRemoteiOS.xcodeproj" \
  -scheme AppRemoteiOS \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -only-testing:AppRemoteiOSTests/DictationControllerTests/testTrackpadDeliveryNeverCapsModernScreensBelowSixtyFPS \
  -only-testing:AppRemoteiOSTests/DictationControllerTests/testPointerNetworkBackpressureCoalescesWithoutLosingDistance

xcodebuild -quiet test \
  -project "$ROOT_DIR/macOS/AppRemoteMac.xcodeproj" \
  -scheme AppRemoteMac \
  -derivedDataPath "$MAC_DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY='-' \
  -only-testing:AppRemoteMacTests/HealthSessionRouterTests/testPointerMoveIsAcknowledgedOnlyAfterRouting \
  -only-testing:AppRemoteMacTests/RelativePointerIntegratorTests

echo "✓ Garde-fou fluidité curseur validé"
