#!/bin/bash
# Index 自截图：打开指定面板 → 按窗口 ID 截图（自动吸附窗口边界）
#
# 用法：
#   ./scripts/self-capture.sh              # 截内容库（默认）
#   ./scripts/self-capture.sh agent        # 截 AI Agent 面板
#
# 输出：docs/images/index-<panel>.png

set -euo pipefail

PANEL="${1:-library}"
APP="/Users/wxyhgk/Code/mac_screenshot/build/Index.app"
OUT="/Users/wxyhgk/Code/mac_screenshot/docs/images/index-$PANEL.png"

# 1. 确保 Index 在运行
if ! pgrep -x Index >/dev/null; then
    open "$APP"
    sleep 3
fi

# 2. 打开目标面板（通过菜单栏）
osascript <<'EOF'
tell application "System Events"
    tell process "Index"
        click menu bar item 1 of menu bar 2
        delay 0.5
        click menu item 5 of menu 1 of menu bar item 1 of menu bar 2
    end tell
end tell
EOF

# 3. 等窗口渲染稳定
sleep 1.5

# 4. 获取 Index 主窗口的 CGWindowID（layer 0）
WINDOW_ID=$(swift -e '
import CoreGraphics
let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)! as! [[String: Any]]
for w in wins where w["kCGWindowOwnerName"] as? String == "Index" && (w["kCGWindowLayer"] as? Int) == 0 {
    print(w["kCGWindowNumber"]!)
    break
}')

if [ -z "$WINDOW_ID" ]; then
    echo "错误：找不到 Index 窗口"
    exit 1
fi

# 5. 按窗口 ID 截图（自动吸附窗口边界，-o 去掉阴影）
screencapture -l "$WINDOW_ID" -o "$OUT"
echo "完成: $OUT (窗口 ID: $WINDOW_ID)"
sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null | tail -2
