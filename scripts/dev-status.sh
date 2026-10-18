#!/bin/bash
# 开发健康度快照：只读，不修改工作区，不跑构建。
#
#   ./scripts/dev-status.sh
#
# 只回答四个问题：WIP 是否有界、是否有未验证提交、版本与 tag 是否一致、
# 仓库里是否堆了陈旧分支。周复盘看它就够了。
set -uo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "不在 git 仓库里" >&2
    exit 1
}
cd "$root" || exit 1

branch=$(git branch --show-current)
[ -n "$branch" ] || branch="(detached)"

dirty=$(git status --porcelain | wc -l | tr -d ' ')

upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
if [ -n "$upstream" ]; then
    ahead=$(git rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
    behind=$(git rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)
    sync_text="领先 ${ahead} / 落后 ${behind}（${upstream}）"
else
    ahead="?"
    sync_text="未设置上游"
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo "?")
tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$tag" ]; then
    since_tag=$(git rev-list --count "$tag..HEAD" 2>/dev/null || echo 0)
    tag_text="${tag} 之后 ${since_tag} 个提交"
    if [ "$tag" = "v$version" ]; then
        version_text="${version}（与 tag 一致）"
    else
        version_text="${version}（尚未发布；最新 tag ${tag}）"
    fi
else
    tag_text="没有 tag"
    version_text="$version"
fi

now=$(date +%s)
cutoff=$((now - 30 * 86400))
stale=""
while IFS=' ' read -r ts name; do
    [ -z "${name:-}" ] && continue
    [ "$name" = "main" ] && continue
    [ -z "${ts:-}" ] && continue
    if [ "$ts" -lt "$cutoff" ] 2>/dev/null; then
        days=$(((now - ts) / 86400))
        stale="${stale}${name}（${days} 天） "
    fi
done <<< "$(git for-each-ref --format='%(committerdate:unix) %(refname:short)' refs/heads)"

todo=$(grep -rn "TODO\|FIXME" Sources --include='*.swift' 2>/dev/null | wc -l | tr -d ' ')
changes=$(ls docs/changes/*.md 2>/dev/null | wc -l | tr -d ' ')

printf '\nIndex 开发状态  %s\n\n' "$(date '+%Y-%m-%d %H:%M')"
printf '  分支        %s\n' "$branch"
printf '  同步        %s\n' "$sync_text"
printf '  工作区      %s 个未提交文件\n' "$dirty"
printf '  版本        %s\n' "$version_text"
printf '  提交        %s\n' "$tag_text"
if [ -n "$stale" ]; then
    printf '  陈旧分支    %s\n' "$stale"
else
    printf '  陈旧分支    无（30 天内都有提交）\n'
fi
printf '  待办标记    %s 处 TODO/FIXME\n' "$todo"
printf '  变更记录    %s 篇\n' "$changes"

warnings=""
[ "$dirty" -gt 0 ] && warnings="${warnings}  工作区不干净：先落盘或收起再开新变更\n"
if [ "$ahead" != "?" ] && [ "$ahead" -gt 0 ]; then
    warnings="${warnings}  有 ${ahead} 个提交未推送：合并前未经过 CI\n"
fi
if [ -n "$tag" ] && [ "$tag" != "v$version" ]; then
    warnings="${warnings}  版本与 tag 不一致：发布前确认 Info.plist\n"
fi
if [ -n "$stale" ]; then
    warnings="${warnings}  有超过 30 天的分支：合掉或删掉\n"
fi

if [ -n "$warnings" ]; then
    printf '\n提醒：\n'
    printf '%b' "$warnings"
else
    printf '\n提醒：无。\n'
fi
printf '\n'
