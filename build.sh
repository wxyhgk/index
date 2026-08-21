#!/bin/bash
# 构建 Index.app
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
PRODUCT_NAME="Index"
# SwiftPM 产物名（模块索引目录固定叫 index，和 Index 在 APFS 上冲突，故用 IndexApp）。
# 组装进 .app 时改名为 Index，匹配 Info.plist 的 CFBundleExecutable。
EXECUTABLE_NAME="Index"
SWIFTPM_EXECUTABLE="IndexApp"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$PRODUCT_NAME.app"
APP_EXECUTABLE="$PWD/$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

# 同一时间只允许一个组装/替换流程。SwiftPM 自己能并发，但两个脚本同时移动
# .app 会让签名、TCC 路径和正在运行的进程再次错位。
mkdir -p "$BUILD_DIR"
BUILD_LOCK="$BUILD_DIR/.index-bundle.lock"
if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
    echo "另一个 Index 组装流程正在运行: $BUILD_LOCK" >&2
    exit 1
fi

STAGE_ROOT="$(mktemp -d "$BUILD_DIR/.Index-stage.XXXXXX")"
STAGED_APP="$STAGE_ROOT/$PRODUCT_NAME.app"
BACKUP_APP="$BUILD_DIR/.Index-previous.$$.app"
cleanup() {
    rm -rf -- "$STAGE_ROOT"
    rmdir "$BUILD_LOCK" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$SWIFTPM_EXECUTABLE"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "构建产物不存在: $BIN_PATH" >&2
    exit 1
fi

echo "==> 在旁路目录组装 $STAGED_APP"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_PATH" "$STAGED_APP/Contents/MacOS/$EXECUTABLE_NAME"
cp Resources/Info.plist "$STAGED_APP/Contents/Info.plist"
cp Resources/Index.icns "$STAGED_APP/Contents/Resources/Index.icns"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

# 签名身份优先级：Developer ID > 本地自签的「Index Dev」。
#
# 为什么不能用 ad-hoc：ad-hoc 没有身份信息，TCC 只能按二进制 cdhash 记录「屏幕录制」授权，
# 代码一改就失效，每次构建都要重新授权。用固定证书后 TCC 记的是 bundle ID + 证书指纹，
# 重新构建不受影响。没有证书就跑一次 ./scripts/make-dev-cert.sh。
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
LOCAL_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Index Dev' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

if [[ -n "$DEV_ID" ]]; then
    echo "==> 使用 Developer ID 签名: $DEV_ID"
    codesign --force --options runtime --sign "$DEV_ID" "$STAGED_APP"
elif [[ -n "$LOCAL_ID" ]]; then
    echo "==> 使用本地固定签名身份: $LOCAL_ID"
    codesign --force --sign "$LOCAL_ID" "$STAGED_APP"
elif [[ "${INDEX_ALLOW_ADHOC:-0}" == "1" ]]; then
    echo "==> 显式允许 ad-hoc 签名；本构建的屏幕录制授权不会跨版本稳定"
    codesign --force --sign - "$STAGED_APP"
else
    echo "未找到稳定的代码签名身份，拒绝生成会破坏 TCC 授权的 ad-hoc App。" >&2
    echo "请先运行一次: ./scripts/make-dev-cert.sh" >&2
    echo "仅无 TCC 的临时环境可显式设置 INDEX_ALLOW_ADHOC=1。" >&2
    exit 1
fi

codesign --verify --deep --strict "$STAGED_APP"

echo "==> 签名身份要求（TCC 就是按这个认 App 的）:"
NEW_REQUIREMENT="$(codesign -d -r- "$STAGED_APP" 2>&1 | grep '^designated' || true)"
echo "$NEW_REQUIREMENT"

EXISTING_APP=""
if [[ -d "$APP_BUNDLE" ]]; then
    EXISTING_APP="$APP_BUNDLE"
fi
if [[ -n "$EXISTING_APP" ]]; then
    OLD_REQUIREMENT="$(codesign -d -r- "$EXISTING_APP" 2>&1 | grep '^designated' || true)"
    if [[ -n "$OLD_REQUIREMENT" && "$OLD_REQUIREMENT" != "$NEW_REQUIREMENT" ]]; then
        echo "警告：本次签名身份与现有 App 不同，TCC 可能只需重新授权一次。" >&2
        echo "旧: $OLD_REQUIREMENT" >&2
        echo "新: $NEW_REQUIREMENT" >&2
    fi
fi

# 绝不能在旧进程存活时原地覆盖 bundle。旧进程的 audit token / code object
# 仍属于旧版本，而 replayd/tccd 会从同一路径重新解析新签名，实测会造成授权记录
# 不一致，表现为“每次构建后必须重启”。先完整退出，再做同卷 rename。
WAS_RUNNING=0
running_pids() {
    ps -axo pid=,command= \
        | awk -v target="$APP_EXECUTABLE" \
            '$2 == target { print $1 }'
}

PIDS="$(running_pids)"
if [[ -n "$PIDS" ]]; then
    WAS_RUNNING=1
    echo "==> 退出正在运行的旧 Index: $PIDS"
    osascript -e 'tell application id "com.wxyhgk.index" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        [[ -z "$(running_pids)" ]] && break
        sleep 0.1
    done
    PIDS="$(running_pids)"
    if [[ -n "$PIDS" ]]; then
        echo "==> 旧进程未及时退出，发送 TERM: $PIDS"
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && kill -TERM "$pid"
        done <<< "$PIDS"
        for _ in {1..20}; do
            [[ -z "$(running_pids)" ]] && break
            sleep 0.1
        done
    fi
    PIDS="$(running_pids)"
    if [[ -n "$PIDS" ]]; then
        echo "旧 Index 仍在运行，拒绝覆盖 App: $PIDS" >&2
        exit 1
    fi
fi

echo "==> 原子替换 $APP_BUNDLE"
if [[ -e "$APP_BUNDLE" ]]; then
    mv "$APP_BUNDLE" "$BACKUP_APP"
fi
if mv "$STAGED_APP" "$APP_BUNDLE"; then
    rm -rf -- "$BACKUP_APP"
else
    [[ -e "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$APP_BUNDLE"
    echo "替换失败，已恢复旧 App。" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP_BUNDLE"

if [[ "$WAS_RUNNING" == "1" ]]; then
    echo "==> 启动新 Index"
    # 旧进程刚退出时 LaunchServices 偶尔仍把 bundle 记成“正在终止”，
    # `open` 会瞬时返回 -600。App 已经原子替换成功，此时有限重试并以新 PID
    # 真正出现为准，不能只信 `open` 的退出码。
    STARTED=0
    for attempt in {1..5}; do
        open "$PWD/$APP_BUNDLE" || true
        for _ in {1..10}; do
            if [[ -n "$(running_pids)" ]]; then
                STARTED=1
                break
            fi
            sleep 0.1
        done
        [[ "$STARTED" == "1" ]] && break
        echo "==> 新进程尚未出现，重试启动（$attempt/5）"
        sleep 0.2
    done
    if [[ "$STARTED" != "1" ]]; then
        echo "新 Index 未能自动启动；App 已安全替换，可手动运行: open $APP_BUNDLE" >&2
        exit 1
    fi
fi

echo
echo "完成: $APP_BUNDLE"
if [[ "$WAS_RUNNING" == "1" ]]; then
    echo "旧进程已退出，App 已原位替换并自动重启。"
else
    echo "运行: open $APP_BUNDLE"
fi
