#!/bin/bash
# Builds build/ClipHistory.app from the Swift package.
#   scripts/build-app.sh            release build
#   CONFIG=debug scripts/build-app.sh
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/ClipHistory.app"

# Prefer the stable identity from scripts/setup-signing.sh so Accessibility access survives rebuilds.
LOCAL_IDENTITY="ClipHistory Local Signing"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$LOCAL_IDENTITY\""; then
    SIGN_IDENTITY="$LOCAL_IDENTITY"
  else
    SIGN_IDENTITY="-" # ad-hoc
    echo "note: signing ad-hoc; macOS will forget the Accessibility permission after this rebuild." >&2
    echo "      Run scripts/setup-signing.sh once to keep it across rebuilds." >&2
  fi
fi

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClipHistory" "$APP/Contents/MacOS/ClipHistory"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign "$SIGN_IDENTITY" --identifier app.cliphistory.ClipHistory "$APP"
echo "Built $APP (signed with: $SIGN_IDENTITY)"
