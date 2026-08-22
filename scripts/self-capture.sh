#!/bin/bash
# Index 自截图脚本：打开指定面板 → 等待窗口出现 → 截图到 docs/images/
#
# 用法：
#   ./scripts/self-capture.sh library          # 内容库（默认）
#   ./scripts/self-capture.sh collections      # 专题集
#   ./scripts/self-capture.sh apps             # 应用
#   ./scripts/self-capture.sh agent            # AI Agent 面板
#
# 输出：docs/images/index-<name>.png

set -euo pipefail

PANEL="${1:-library}"
APP="/Users/wxyhgk/Code/mac_screenshot/build/Index.app"
OUT_DIR="/Users/wxyhgk/Code/mac_screenshot/docs/images"
PID=$(pgrep -x Index || true)

# 1. 确保 Index 在运行
if [ -z "$PID" ]; then
    echo "启动 Index..."
    open "$APP"
    sleep 3
    PID=$(pgrep -x Index)
fi
echo "Index PID: $PID"

# 2. 通过菜单栏打开目标面板
#    菜单项顺序：1 截图 2 延时截图 3 滚动截图 4 录屏 5 图库 6 3D分子 7 剪贴板历史 8 设置
case "$PANEL" in
    library|recordings|clipboard|ai)
        MENU_INDEX=5  # 图库
        ;;
    collections)
        MENU_INDEX=5  # 图库（打开后手动切 tab）
        ;;
    apps)
        MENU_INDEX=5  # 图库（打开后手动切 tab）
        ;;
    agent)
        MENU_INDEX=5  # 图库（Agent 面板用 ⌘⇧A）
        ;;
    *)
        echo "未知面板: $PANEL"
        exit 1
        ;;
esac

echo "打开面板: $PANEL (菜单项 #$MENU_INDEX)"
osascript <<EOF
tell application "System Events"
    tell process "Index"
        click menu bar item 1 of menu bar 2
        delay 0.5
        click menu item $MENU_INDEX of menu 1 of menu bar item 1 of menu bar 2
    end tell
end tell
EOF

# 3. 等待窗口出现（最多 5 秒）
echo "等待窗口出现..."
for i in $(seq 1 10); do
    sleep 0.5
    WINDOW_COUNT=$(osascript -e "tell application \"System Events\" to tell process \"Index\" to count windows" 2>/dev/null || echo 0)
    if [ "$WINDOW_COUNT" -gt 0 ] 2>/dev/null; then
        echo "窗口已出现 (第 $i 次检查)"
        break
    fi
done

# 4. 用 screencapture 截全屏（Index 窗口一定在屏幕上）
sleep 1  # 等窗口渲染稳定
OUTPUT="$OUT_DIR/index-$PANEL.png"
screencapture -x -o "$OUTPUT"
echo "截图已保存: $OUTPUT"

# 5. 显示截图信息
sips -g pixelWidth -g pixelHeight "$OUTPUT" 2>/dev/null
