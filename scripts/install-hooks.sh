#!/bin/bash
# 安装 pre-push hook：推送前跑一次完整门禁。
#
#   ./scripts/install-hooks.sh          安装/更新
#   ./scripts/install-hooks.sh --remove 卸载
#
# 为什么不是手抄 docs/ci.md 里的命令：手抄的路径会漂、会忘、会被跳过。
set -euo pipefail

root=$(git rev-parse --show-toplevel)
hook="$root/.git/hooks/pre-push"

if [ "${1:-}" = "--remove" ]; then
    if [ -f "$hook" ] && grep -q 'scripts/check.sh' "$hook"; then
        rm -f "$hook"
        echo "已移除 pre-push hook"
    else
        echo "没有由本脚本安装的 pre-push hook"
    fi
    exit 0
fi

if [ -e "$hook" ] && ! grep -q 'scripts/check.sh' "$hook"; then
    backup="$hook.backup.$(date +%Y%m%d%H%M%S)"
    mv "$hook" "$backup"
    echo "已有自定义 hook，已备份到 $backup"
fi

cat > "$hook" <<'HOOK'
#!/bin/sh
# 由 scripts/install-hooks.sh 生成：推送前跑完整门禁（构建 + 全部测试 + 架构纪律）。
# 用 --no-verify 跳过只应发生在「明确知道自己在做什么」的时候。
set -e
cd "$(git rev-parse --show-toplevel)"
exec ./scripts/check.sh
HOOK
chmod +x "$hook"

echo "已安装 pre-push：$hook"
echo "推送时将先运行 ./scripts/check.sh；需要临时跳过用 git push --no-verify。"
