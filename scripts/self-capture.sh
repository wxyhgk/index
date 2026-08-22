#!/bin/bash
# Index 自截图：screencapture -l 按窗口 ID 截图（自动吸附窗口边界）
#
# 用法：
#   ./scripts/self-capture.sh              # 截当前窗口
#   ./scripts/self-capture.sh <windowID>   # 指定窗口 ID
#
# 输出：docs/images/index-self-<timestamp>.png

set -euo pipefail

APP="/Users/wxyhgk/Code/mac_screenshot/build/Index.app"
OUT_DIR="/Users/wxyhgk/Code/mac_screenshot/docs/images"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT="$OUT_DIR/index-self-$TIMESTAMP.png"

# 1. 确保 Index 在运行
if ! pgrep -x Index >/dev/null; then
    open "$APP"
    sleep 3
fi

# 2. 获取窗口 ID（layer 0 主窗口，或指定）
WINDOW_ID="${1:-}"
if [ -z "$WINDOW_ID" ]; then
    WINDOW_ID=$(swift -e '
    import CoreGraphics
    let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)! as! [[String: Any]]
    for w in wins where w["kCGWindowOwnerName"] as? String == "Index" && (w["kCGWindowLayer"] as? Int) == 0 {
        print(w["kCGWindowNumber"]!)
        break
    }')
fi

if [ -z "$WINDOW_ID" ]; then
    echo "错误：找不到 Index 窗口"
    exit 1
fi

# 3. 恢复窗口大小（Stage Manager 可能把窗口缩小）
osascript -e '
tell application "System Events"
    tell process "Index"
        set size of window 1 to {1240, 760}
    end tell
end tell' 2>/dev/null || true

# 4. 按窗口 ID 截图（自动吸附窗口边界）
screencapture -l "$WINDOW_ID" -o "$OUT"
echo "完成: $OUT (窗口 ID: $WINDOW_ID)"
sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null | tail -2
