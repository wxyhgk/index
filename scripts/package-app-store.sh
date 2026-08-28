#!/bin/bash
# 从 build.sh 产出的固定 Release App 制作 Mac App Store 上传包。
#
# 这个脚本绝不就地重签或替换 build/Index.app：它先调用仓库唯一允许的
# `./build.sh release`，再复制到旁路目录，给副本嵌入描述文件和商店沙盒签名。
set -euo pipefail

cd "$(dirname "$0")/.."

PRODUCT_NAME="Index"
BUNDLE_ID="com.wxyhgk.index"
SOURCE_APP="build/$PRODUCT_NAME.app"
OUTPUT_DIR="build/app-store"
PROFILE="${INDEX_APP_STORE_PROFILE:-}"
APP_IDENTITY="${INDEX_APP_STORE_APP_IDENTITY:-}"
INSTALLER_IDENTITY="${INDEX_APP_STORE_INSTALLER_IDENTITY:-}"
BASE_ENTITLEMENTS="Resources/IndexAppStore.entitlements"

# 商店包必须能回溯到明确源码状态。开发中确实需要验证未提交改动时可以显式
# 覆盖，但正式上传不再悄悄把 dirty worktree 打进不可追踪的 pkg。
if [[ "${INDEX_ALLOW_DIRTY_APP_STORE:-0}" != "1" ]] \
    && [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "工作区存在未提交改动，拒绝制作正式商店包。" >&2
    echo "仅本地验证可显式设置 INDEX_ALLOW_DIRTY_APP_STORE=1。" >&2
    exit 1
fi

assert_no_quarantine() {
    local root="$1"
    local item

    while IFS= read -r -d '' item; do
        if /usr/bin/xattr -p com.apple.quarantine "$item" >/dev/null 2>&1; then
            echo "商店副本仍包含 com.apple.quarantine: $item" >&2
            return 1
        fi
    done < <(/usr/bin/find "$root" -print0)
}

if [[ -z "$PROFILE" || ! -f "$PROFILE" ]]; then
    echo "请把 INDEX_APP_STORE_PROFILE 指向已下载的 Mac App Store Connect provisioning profile。" >&2
    exit 1
fi

find_identity() {
    local pattern="$1"
    security find-identity -v 2>/dev/null \
        | sed -nE "s/^[[:space:]]*[0-9]+\) [0-9A-F]+ \"(${pattern}[^\"]*)\".*/\1/p" \
        | head -1
}

if [[ -z "$APP_IDENTITY" ]]; then
    APP_IDENTITY="$(find_identity 'Apple Distribution:|Mac App Distribution:|3rd Party Mac Developer Application:')"
fi
if [[ -z "$INSTALLER_IDENTITY" ]]; then
    INSTALLER_IDENTITY="$(find_identity 'Mac Installer Distribution:|3rd Party Mac Developer Installer:')"
fi

if [[ -z "$APP_IDENTITY" ]]; then
    echo "未找到 Apple Distribution 或 Mac App Distribution 签名身份。" >&2
    exit 1
fi
if [[ -z "$INSTALLER_IDENTITY" ]]; then
    echo "未找到 Mac Installer Distribution 签名身份。" >&2
    exit 1
fi

echo "==> 使用仓库标准流程组装 Release App"
INDEX_BUILD_INPUT_METHOD=0 ./build.sh release

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Release App 不存在: $SOURCE_APP" >&2
    exit 1
fi

SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
SOURCE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$SOURCE_VERSION" || "$BUILT_BUILD" != "$SOURCE_BUILD" ]]; then
    echo "Release App 版本与源码不一致: 源码 $SOURCE_VERSION($SOURCE_BUILD)，App $BUILT_VERSION($BUILT_BUILD)" >&2
    exit 1
fi

mkdir -p build
WORK_ROOT="$(mktemp -d "build/.Index-app-store-stage.XXXXXX")"
STAGED_OUTPUT="$WORK_ROOT/output"
STAGED_APP="$STAGED_OUTPUT/$PRODUCT_NAME.app"
PROFILE_PLIST="$WORK_ROOT/profile.plist"
EFFECTIVE_ENTITLEMENTS="$WORK_ROOT/effective.entitlements"
BACKUP_OUTPUT="build/.Index-app-store-previous.$$"

cleanup() {
    rm -rf -- "$WORK_ROOT"
}
trap cleanup EXIT

mkdir -p "$STAGED_OUTPUT"
cp -R "$SOURCE_APP" "$STAGED_APP"

echo "==> 校验并嵌入 provisioning profile"
security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
PROFILE_PLATFORM="$(/usr/libexec/PlistBuddy -c 'Print :Platform:0' "$PROFILE_PLIST")"
TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
EXPECTED_APP_ID="$TEAM_ID.$BUNDLE_ID"

if [[ "$PROFILE_PLATFORM" != "OSX" ]]; then
    echo "描述文件平台不是 macOS: $PROFILE_PLATFORM" >&2
    exit 1
fi
if [[ "$PROFILE_APP_ID" != "$EXPECTED_APP_ID" ]]; then
    echo "描述文件 App ID 不匹配。期望 $EXPECTED_APP_ID，实际 $PROFILE_APP_ID" >&2
    exit 1
fi

cp "$PROFILE" "$STAGED_APP/Contents/embedded.provisionprofile"
cp "$BASE_ENTITLEMENTS" "$EFFECTIVE_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_APP_ID" "$EFFECTIVE_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$EFFECTIVE_ENTITLEMENTS"

echo "==> 收紧商店副本的网络声明"
STORE_INFO="$STAGED_APP/Contents/Info.plist"
plutil -remove NSAppTransportSecurity.NSAllowsArbitraryLoads "$STORE_INFO" 2>/dev/null || true
plutil -insert NSAppTransportSecurity.NSAllowsLocalNetworking -bool YES "$STORE_INFO" 2>/dev/null \
    || plutil -replace NSAppTransportSecurity.NSAllowsLocalNetworking -bool YES "$STORE_INFO"
plutil -insert IndexDistributionChannel -string app-store "$STORE_INFO" 2>/dev/null \
    || plutil -replace IndexDistributionChannel -string app-store "$STORE_INFO"

echo "==> 清除商店副本的扩展属性"
# 下载的 provisioning profile 通常带有 com.apple.quarantine。cp 会把它复制进
# App bundle，而 App Store Connect 会以 91109 拒绝包含该属性的 payload。
# 这里只处理旁路副本；固定路径 build/Index.app 不会被修改。
/usr/bin/xattr -cr "$STAGED_APP"
assert_no_quarantine "$STAGED_APP"

echo "==> 使用 Mac App Store 身份签名旁路副本"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$EFFECTIVE_ENTITLEMENTS" \
    --sign "$APP_IDENTITY" \
    "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
assert_no_quarantine "$STAGED_APP"

SIGNED_APP_ID="$(codesign -d --entitlements - --xml "$STAGED_APP" 2>/dev/null \
    | plutil -extract 'com\.apple\.application-identifier' raw -o - -)"
if [[ "$SIGNED_APP_ID" != "$EXPECTED_APP_ID" ]]; then
    echo "签名后的 application-identifier 不匹配: $SIGNED_APP_ID" >&2
    exit 1
fi

echo "==> 生成 Transporter 可上传的安装包"
productbuild \
    --component "$STAGED_APP" /Applications \
    --sign "$INSTALLER_IDENTITY" \
    "$STAGED_OUTPUT/$PRODUCT_NAME.pkg"
pkgutil --check-signature "$STAGED_OUTPUT/$PRODUCT_NAME.pkg"

echo "==> 原子替换商店构建产物"
if [[ -e "$OUTPUT_DIR" ]]; then
    mv "$OUTPUT_DIR" "$BACKUP_OUTPUT"
fi
if mv "$STAGED_OUTPUT" "$OUTPUT_DIR"; then
    rm -rf -- "$BACKUP_OUTPUT"
else
    [[ -e "$BACKUP_OUTPUT" ]] && mv "$BACKUP_OUTPUT" "$OUTPUT_DIR"
    echo "商店产物替换失败，已恢复旧版本。" >&2
    exit 1
fi

echo
echo "完成: $OUTPUT_DIR/$PRODUCT_NAME.pkg  $SOURCE_VERSION($SOURCE_BUILD)"
echo "下一步：用 Transporter 登录同一开发者账号，添加该 pkg 并交付。"
