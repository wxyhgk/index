#!/bin/bash
# 发布：校验 → 生成 CHANGELOG → 更新版本 → 提交 → 打 tag。
#
#   ./scripts/release.sh                发布 Info.plist 里的当前版本
#   ./scripts/release.sh patch|minor|major  先把版本号往上调，再发布
#   ./scripts/release.sh --dry-run      只打印计划，不改任何文件
#
# 脚本**不会自动推送**。它跑完会打印最后两步：
#   git push origin main
#   git push origin refs/tags/vX.Y.Z
#
# 不要用 `--follow-tags`：它只推 annotated tag。本脚本打的是轻量 tag，
# 会被漏掉，反而把本地其它历史 annotated tag 一并推上去触发发布。
#
# 为什么默认不推送：tag 一旦推上去就会触发 release.yml 组装并公开附件。
# 推送前应该由人确认签名、版本和 CHANGELOG。
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

mode=""
dry_run=0
full_check=0
for arg in "$@"; do
    case "$arg" in
        patch|minor|major) mode="$arg" ;;
        --dry-run) dry_run=1 ;;
        --full) full_check=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "未知参数：${arg}（可用：patch|minor|major --dry-run --full）" >&2
            exit 2
            ;;
    esac
done

fail() { echo "发布中止：$1" >&2; exit 1; }

# ---------------------------------------------------------------- 前置检查

[ -z "$(git status --porcelain)" ] || fail "工作区不干净，先提交或收起改动"

branch=$(git branch --show-current)
[ "$branch" = "main" ] || fail "只能在 main 上发布（当前 ${branch}）"

upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
    || fail "main 没有上游分支"
ahead=$(git rev-list --count "$upstream..HEAD")
behind=$(git rev-list --count "HEAD..$upstream")
[ "$ahead" -eq 0 ] || fail "有 $ahead 个提交未推送，先推送再发布（否则 tag 指向远端不存在的提交）"
[ "$behind" -eq 0 ] || fail "落后 $upstream $behind 个提交，先 pull"

current=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null) \
    || fail "读不到 Info.plist 的 CFBundleShortVersionString"
latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)

# ---------------------------------------------------------------- 版本号

version="$current"
if [ -n "$mode" ]; then
    IFS=. read -r major minor patch <<< "$current"
    case "$major$minor$patch" in
        *[!0-9]*) fail "版本号不是 X.Y.Z：$current" ;;
    esac
    case "$mode" in
        patch) patch=$((patch + 1)) ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        major) major=$((major + 1)); minor=0; patch=0 ;;
    esac
    version="${major}.${minor}.${patch}"
elif [ -n "$latest_tag" ] && [ "$latest_tag" = "v$current" ]; then
    fail "当前版本 $current 已经发布过；用 patch|minor|major 指定新版本"
fi

tag="v$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "tag $tag 已存在"

# ---------------------------------------------------------------- 门禁

if [ "$full_check" -eq 1 ]; then
    check_desc="./scripts/check.sh --full"
else
    check_desc="./scripts/check.sh"
fi

if [ "$dry_run" -eq 1 ]; then
    echo "==> dry-run：跳过门禁（正式发布会运行 ${check_desc}）"
else
    echo "==> 运行门禁"
    if [ "$full_check" -eq 1 ]; then
        ./scripts/check.sh --full
    else
        ./scripts/check.sh
    fi
fi

# ---------------------------------------------------------------- CHANGELOG

range="${latest_tag:+$latest_tag..}HEAD"
subjects=$(git log --no-merges --format='%s' "$range" \
    | grep -v '^chore(release)' \
    | sed 's/^/- /' || true)
[ -n "$subjects" ] || fail "自 ${latest_tag:-仓库起点} 以来没有可发布的提交"

today=$(date '+%Y-%m-%d')
section="## [$tag] - $today

$subjects"

if [ "$dry_run" -eq 1 ]; then
    echo
    echo "==> dry-run：不会修改任何文件"
    if [ "$version" = "$current" ]; then
        echo "版本：${current}（不变）"
    else
        echo "版本：${current} → $version"
    fi
    echo "tag ：${tag}（轻量 tag，与仓库现有风格一致）"
    echo
    echo "$section"
    echo
    echo "下一步会写：Resources/Info.plist、CHANGELOG.md"
    echo "然后提交：chore(release): $tag"
    exit 0
fi

# ---------------------------------------------------------------- 落盘

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" Resources/Info.plist

if [ -f CHANGELOG.md ]; then
    first_section=$(grep -n '^## \[' CHANGELOG.md | head -1 | cut -d: -f1 || true)
    if [ -n "$first_section" ]; then
        head -n $((first_section - 1)) CHANGELOG.md > CHANGELOG.md.tmp
        printf '%s\n\n' "$section" >> CHANGELOG.md.tmp
        tail -n "+$first_section" CHANGELOG.md >> CHANGELOG.md.tmp
    else
        cat CHANGELOG.md > CHANGELOG.md.tmp
        printf '\n%s\n' "$section" >> CHANGELOG.md.tmp
    fi
else
    {
        echo "# 变更日志"
        echo
        echo "由 \`scripts/release.sh\` 从 git 提交生成，按发布 tag 分组。"
        echo
        printf '%s\n' "$section"
    } > CHANGELOG.md.tmp
fi
mv CHANGELOG.md.tmp CHANGELOG.md

git add Resources/Info.plist CHANGELOG.md
git commit -q -m "chore(release): $tag"
git tag "$tag"

echo
echo "完成：$tag"
echo "  $(git log -1 --format='%h %s')"
echo
echo "下一步（手动确认后执行）："
echo "  git push origin main"
echo "  git push origin refs/tags/${tag}"
