#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
MODULE_CACHE="$PROJECT_ROOT/.build/module-cache"
CACHE_PATH="$PROJECT_ROOT/.build/cache"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

cd "$PROJECT_ROOT"
mkdir -p "$MODULE_CACHE" "$CACHE_PATH"
swift test --disable-sandbox --cache-path "$CACHE_PATH"
