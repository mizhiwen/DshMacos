#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/DeepSeek Harness.app"
DMG_NAME="DeepSeek-Harness-macOS.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
PACKAGE_TEMP="$(mktemp -d -t dsh-macos-dmg)"
VOLUME_ROOT="$PACKAGE_TEMP/DeepSeek Harness"

cleanup() {
  rm -rf "$PACKAGE_TEMP"
}
trap cleanup EXIT

"$PROJECT_ROOT/scripts/build-app.sh"

mkdir -p "$VOLUME_ROOT"
ditto "$APP_BUNDLE" "$VOLUME_ROOT/DeepSeek Harness.app"
ln -s /Applications "$VOLUME_ROOT/Applications"

hdiutil create \
  -volname "DeepSeek Harness" \
  -srcfolder "$VOLUME_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"
cd "$DIST_DIR"
shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"

echo "$DMG_PATH"
