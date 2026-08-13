#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="Resources/Brand/index-app-icon.svg"
APP_ICON="Resources/Index.icns"
EDGE_ICON_DIR="BrowserExtensions/Edge/icons"
ICON_WORK_DIR="$(mktemp -d /tmp/index-brand-icons.XXXXXX)"
trap 'rm -rf -- "$ICON_WORK_DIR"' EXIT

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "缺少 rsvg-convert；请先安装 librsvg。" >&2
    exit 1
fi

ICONSET="$ICON_WORK_DIR/Index.iconset"
mkdir -p "$ICONSET" "$EDGE_ICON_DIR"
rsvg-convert -w 1024 -h 1024 "$SOURCE" > "$ICON_WORK_DIR/index-1024.png"

make_png() {
    local size="$1"
    local target="$2"
    sips -z "$size" "$size" "$ICON_WORK_DIR/index-1024.png" --out "$target" >/dev/null
}

make_png 16 "$ICONSET/icon_16x16.png"
make_png 32 "$ICONSET/icon_16x16@2x.png"
make_png 32 "$ICONSET/icon_32x32.png"
make_png 64 "$ICONSET/icon_32x32@2x.png"
make_png 128 "$ICONSET/icon_128x128.png"
make_png 256 "$ICONSET/icon_128x128@2x.png"
make_png 256 "$ICONSET/icon_256x256.png"
make_png 512 "$ICONSET/icon_256x256@2x.png"
make_png 512 "$ICONSET/icon_512x512.png"
cp "$ICON_WORK_DIR/index-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP_ICON"

for size in 16 32 48 128; do
    make_png "$size" "$EDGE_ICON_DIR/index-$size.png"
done

echo "已生成 $APP_ICON 与 $EDGE_ICON_DIR/"
