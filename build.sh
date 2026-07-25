#!/bin/bash
# 构建 MacShot.app —— SwiftPM 只产出可执行文件，这里手工组装成 .app bundle。
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="MacShot"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "构建产物不存在: $BIN_PATH" >&2
    exit 1
fi

echo "==> 组装 $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# 签名身份优先级：Developer ID > 本地自签的「MacShot Dev」> ad-hoc。
#
# 为什么不能用 ad-hoc：ad-hoc 没有身份信息，TCC 只能按二进制 cdhash 记录「屏幕录制」授权，
# 代码一改就失效，每次构建都要重新授权。用固定证书后 TCC 记的是 bundle ID + 证书指纹，
# 重新构建不受影响。没有证书就跑一次 ./scripts/make-dev-cert.sh。
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
LOCAL_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'MacShot Dev' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

if [[ -n "$DEV_ID" ]]; then
    echo "==> 使用 Developer ID 签名: $DEV_ID"
    codesign --force --options runtime --sign "$DEV_ID" "$APP_BUNDLE"
elif [[ -n "$LOCAL_ID" ]]; then
    echo "==> 使用本地固定签名身份: $LOCAL_ID"
    codesign --force --sign "$LOCAL_ID" "$APP_BUNDLE"
else
    echo "==> 未找到签名证书，退回 ad-hoc（每次构建后都需要重新授权屏幕录制）"
    echo "    建议先运行一次: ./scripts/make-dev-cert.sh"
    codesign --force --sign - "$APP_BUNDLE"
fi

echo "==> 签名身份要求（TCC 就是按这个认 App 的）:"
codesign -d -r- "$APP_BUNDLE" 2>&1 | grep '^designated' || true

echo
echo "完成: $APP_BUNDLE"
echo "运行: open $APP_BUNDLE"
