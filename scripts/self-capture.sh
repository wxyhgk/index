#!/bin/bash
# Index 自截图：打开指定面板 → 按窗口区域截图（自动吸附，无需裁剪）
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

# 4. 获取窗口位置和尺寸
REGION=$(osascript <<'EOF'
tell application "System Events"
    tell process "Index"
        if (count of windows) > 0 then
            set p to position of window 1
            set s to size of window 1
            return (item 1 of p) & "," & (item 2 of p) & "," & (item 1 of s) & "," & (item 2 of s)
        end if
    end tell
end tell
EOF
)

# osascript 返回 "1660, ,, 823, ,, 240, ,, 176"，去掉所有空格变 "1660,823,240,176"
REGION=$(echo "$REGION" | tr -d ' ')

if [ -z "$REGION" ]; then
    echo "错误：找不到 Index 窗口"
    exit 1
fi

# 5. 按窗口区域截图（-R x,y,w,h，自动吸附窗口边界）
screencapture -R "$REGION" -o "$OUT"
echo "完成: $OUT (区域: $REGION)"
sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null | tail -2
