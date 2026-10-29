#!/bin/bash
# Builds build/ClipHistory.app from the Swift package.
#   scripts/build-app.sh            release build
#   CONFIG=debug scripts/build-app.sh
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}" # "-" = ad-hoc
APP="build/ClipHistory.app"

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
echo "Built $APP"
