#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SOURCE_SVG="$PROJECT_ROOT/Resources/AppIcon.svg"
OUTPUT_ICNS="$PROJECT_ROOT/Resources/DeepSeekHarness.icns"
ICON_TEMP="$(mktemp -d -t dsh-macos-icon)"
RENDER_DIR="$ICON_TEMP/render"
ICONSET_DIR="$ICON_TEMP/DeepSeekHarness.iconset"

cleanup() {
  rm -rf "$ICON_TEMP"
}
trap cleanup EXIT

mkdir -p "$RENDER_DIR" "$ICONSET_DIR"
qlmanage -t -s 1024 -o "$RENDER_DIR" "$SOURCE_SVG" >/dev/null
SOURCE_PNG="$RENDER_DIR/AppIcon.svg.png"

if [[ ! -f "$SOURCE_PNG" ]]; then
  echo "无法渲染应用图标：$SOURCE_SVG" >&2
  exit 1
fi

while read -r name size; do
  sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET_DIR/$name" >/dev/null
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES

iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"
echo "$OUTPUT_ICNS"
