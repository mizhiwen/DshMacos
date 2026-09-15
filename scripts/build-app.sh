#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/DeepSeek Harness.app"
ICON_FILE="$PROJECT_ROOT/Resources/DeepSeekHarness.icns"
MODULE_CACHE="$PROJECT_ROOT/.build/module-cache"
CACHE_PATH="$PROJECT_ROOT/.build/cache"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

cd "$PROJECT_ROOT"
mkdir -p "$MODULE_CACHE" "$CACHE_PATH"
"$PROJECT_ROOT/scripts/build-icon.sh"
swift build -c release --disable-sandbox --cache-path "$CACHE_PATH"
BIN_DIR="$(swift build -c release --disable-sandbox --cache-path "$CACHE_PATH" --show-bin-path)"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
install -m 755 "$BIN_DIR/DshMacos" "$APP_BUNDLE/Contents/MacOS/DshMacos"
install -m 644 "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
install -m 644 "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/DeepSeekHarness.icns"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "$APP_BUNDLE"
