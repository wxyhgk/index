#!/bin/bash
# 提交前门禁。**本地和 CI 跑的是同一个脚本** —— 两边的检查永远不会漂移，
# 这是「CI 上过了本地没过」和它的反面都不该发生的唯一保证。
#
#   ./scripts/check.sh          构建 + 测试 + 架构纪律
#   ./scripts/check.sh --full   再加上组装 .app（release 构建，慢）
#
# 架构纪律那两条不是凑数：它们是 ARCHITECTURE.md / DIRECTORY.md 白纸黑字立过、
# 但此前只靠「定期人工巡检」的规矩 —— 而人工巡检真的漏过（2026-07 那次审计发现
# 批量导出偷偷内联了一份目录选择面板）。新人不会读完两千行文档才动手，
# 机器读得完。
set -uo pipefail
cd "$(dirname "$0")/.."

failed=0
section() { printf "\n\033[1m==> %s\033[0m\n" "$1"; }
ok()      { printf "    \033[32m✓\033[0m %s\n" "$1"; }
bad()     { printf "    \033[31m✗\033[0m %s\n" "$1"; failed=1; }

# ---------------------------------------------------------------- 构建与测试

# CI 上先清干净再构建。原因是实测过的一个坑：给协议加方法要求之后，
# SwiftPM 的增量构建可能留下不一致的产物 —— 见证表错位，于是调用 `resize`
# 实际跳进了 `draw`，测试进程直接 SIGSEGV。那种崩溃看起来像代码写坏了，
# 排查能耗掉一小时。整个 clean build 也就 40 秒，CI 不值得为此省。
if [ -n "${CI:-}" ]; then
    section "清理（CI）"
    swift package clean && ok "已清空构建产物"
fi

section "构建"
if swift build 2>&1 | sed 's/^/    /'; then
    ok "swift build"
else
    bad "swift build 失败"
    # 编译不过就没必要往下跑了，后面全是噪声。
    exit 1
fi

section "测试"
test_output=$(swift test 2>&1)
test_status=$?
# 成败**只认退出码**。曾经在这里用 grep "with 0 failures" 判定，
# 结果测试进程被 SIGSEGV 打死、只跑了一半，某个 suite 的「0 failures」
# 照样匹配上，脚本报了「全部通过」—— 门禁给出假绿比没有门禁更糟。
#
# 每个 suite 各打一行 "Executed N tests"，总数是其中最大的那个
# （取 tail -1 会拿到最后一个 suite 的数，曾经把 76 报成 17）。
summary=$(printf "%s" "$test_output" \
    | grep -oE "Executed [0-9]+ tests, with [0-9]+ failures" | sort -t' ' -k2 -rn | head -1)
if [ "$test_status" -eq 0 ]; then
    ok "${summary:-测试通过}"
else
    printf "%s\n" "$test_output" \
        | grep -E "error:|signal|XCTAssert.*failed|failed \(" | head -20 | sed 's/^/    /'
    # 变量名必须加花括号：bash 3.2 会把紧随的全角「（」并进变量名，报 unbound variable。
    bad "swift test 退出码 ${test_status}（${summary:-没跑完}）"
fi

# ------------------------------------------------------------ 架构纪律（静态）
#
# 两条都只看**代码行**，注释里提到某个类型不算违例（Storage 里就有一处注释
# 提到 EditorView，那是在解释下游假设，不是依赖）。

# 只保留非注释行。注意 grep -rn 的输出前面带 `文件:行号:`，
# 判断「这行是不是注释」必须先跨过那段前缀，否则一条都过滤不掉。
code_only() { grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)'; }

section "纪律一：模态面板与弹窗只许出现在 Platform/"
# 路径不写结尾斜杠：grep -r 会把 `Sources/` 输出成 `Sources//Index/…`，
# 后面按前缀排除 Platform/ 就全落空了。
panel_hits=$(grep -rn "NSAlert()\|NSOpenPanel()\|NSSavePanel()\|\.runModal()" \
    --include="*.swift" Sources 2>/dev/null \
    | grep -v "/Platform/" | code_only || true)
if [ -z "$panel_hits" ]; then
    ok "面板/弹窗都收在 Platform/ 里"
else
    printf "%s\n" "$panel_hits" | sed 's/^/    /'
    bad "界面层不许自己拼 runModal —— 走 AppAlert / ImageExporter / SystemNavigator"
fi

section "纪律二：依赖只向下，下层不认识界面层"
layer_hits=""
for dir in Capture Render Annotation Storage Toolbar Actions Pipeline Intelligence Plugins Plugin; do
    hits=$(grep -rn "GalleryView\|EditorView\|GalleryGrid\|ShotDetailPane\|GalleryWindowController" \
        --include="*.swift" "Sources/IndexApp/$dir" 2>/dev/null | code_only || true)
    # 排除 init 默认值兜底（`?? GalleryWindowController.shared`）—— 那是装配逻辑，不是业务引用
    hits=$(printf "%s" "$hits" | grep -v '?? GalleryWindowController\.shared' || true)
    [ -n "$hits" ] && layer_hits="${layer_hits}${hits}"$'\n'
done
if [ -z "${layer_hits// }" ]; then
    ok "领域层与平台层都不认识界面层"
else
    printf "%s" "$layer_hits" | sed 's/^/    /'
    bad "下层引用了上层 —— 反过来，让界面层去认识领域层"
fi

section "纪律三：工具契约没有被绕过"
# 加一个标注工具应当只碰 Tools/ 与登记处。这里查的是反向症状：
# 领域层里重新长出按图层种类分派的 switch。
switch_hits=$(grep -rn "switch layer.kind\|switch original.kind\|switch shape.kind" \
    --include="*.swift" Sources/IndexApp/Annotation Sources/IndexApp/Render 2>/dev/null \
    | grep -v "/Tools/" | code_only || true)
if [ -z "$switch_hits" ]; then
    ok "没有按图层种类分派的 switch"
else
    printf "%s\n" "$switch_hits" | sed 's/^/    /'
    bad "别按 kind 分派 —— 把行为写进 AnnotationToolDescriptor（见 Annotation/Tools/）"
fi

section "纪律四：CSS token 只认 DS（无裸写回潮）"
# 视图层不得裸写 Color.primary.opacity / Color.accentColor.opacity 等，
# 一律走 DS.*。DesignTokens.swift 是唯一允许出现 .opacity 的 CSS 源，
# 其它 .opacity 仅允许 1) DS.xxx.opacity(...) 的 token 派生 2) .opacity(0/1) 的显隐开关
# 3) mask/overlay 的技术性透明（已收敛到 DS.mask*）。这里按最严的一档拦：
# 只要视图里出现 Color.(primary|secondary|accentColor|black|white).opacity 就判违例，
# 例外仅 DS.swift 本身。
css_hits=$(grep -rn "Color\.\(primary\|secondary\|accentColor\|black\|white\)\.opacity" \
    --include="*.swift" Sources 2>/dev/null | grep -v "DesignTokens\.swift" | grep -v "DS\.accent\.opacity" | code_only || true)
css_hits=$(printf "%s" "$css_hits" | grep -v "DS\." || true)
if [ -z "$css_hits" ]; then
    ok "视图层无裸 Color.*.opacity，CSS 只认 DS"
else
    printf "%s\n" "$css_hits" | sed 's/^/    /'
    bad "视图层裸写 Color.*.opacity —— 请收敛到 DS（见 DesignTokens.swift）"
fi

section "纪律五：DS vs Theme 双轨已收敛"
# Theme 仅作兼容转发，新代码不得新增 Theme/MacTheme 调用点。
# 允许的唯一 Theme 出现位置是 UI/Design/Theme.swift 本身（定义处）。
theme_hits=$(grep -rn "Theme\.\|MacTheme\|: Theme" --include="*.swift" Sources 2>/dev/null | grep -v "UI/Design/Theme\.swift" | grep -v "//" | code_only || true)
if [ -z "$theme_hits" ]; then
    ok "Theme 仅在 UI/Design/Theme.swift 兼容转发，调用点只认 DS"
else
    printf "%s\n" "$theme_hits" | sed 's/^/    /'
    bad "新增 Theme/MacTheme 调用点 —— 请改为 DS（Theme 已收敛为兼容层）"
fi

section "纪律六：普通截图不准退回废弃的 CoreGraphics 代理"
# macOS 15 会把这些 API 转发到 ReplayKit 的 proxyCoreGraphics；多屏串行调用
# 会把一次系统故障放大成 N 次 5 秒超时。普通截图统一走带 5 秒完成门的 SCK 逐屏冻结。
legacy_capture_hits=$(grep -rn "CGDisplayCreateImage\|CGWindowListCreateImage" \
    --include="*.swift" Sources 2>/dev/null | code_only || true)
if [ -z "$legacy_capture_hits" ]; then
    ok "没有废弃的 CoreGraphics 截图调用"
else
    printf "%s\n" "$legacy_capture_hits" | sed 's/^/    /'
    bad "不要恢复 CGDisplayCreateImage/CGWindowListCreateImage —— macOS 15 会转发到旧 ReplayKit 代理"
fi

section "纪律七：运行中的 App 不得被原地覆盖"
# 旧 PID 存活时删除/重建同一路径 bundle，会让进程 audit token 对应的旧 code object
# 与磁盘上的新签名不一致。必须旁路签名、退出旧进程，再原子替换；无证书时
# 也不得静默退回 ad-hoc。
unsafe_bundle_replace=$(grep -nF 'rm -rf "$APP_BUNDLE"' build.sh || true)
if [ -z "$unsafe_bundle_replace" ] \
    && grep -q 'STAGED_APP=' build.sh \
    && grep -q 'PRODUCT_NAME="Index"' build.sh \
    && grep -q 'running_pids()' build.sh \
    && grep -qF 'mv "$STAGED_APP" "$APP_BUNDLE"' build.sh \
    && grep -q 'INDEX_ALLOW_ADHOC' build.sh; then
    ok "Release 先旁路签名，旧进程退出后再替换，ad-hoc 只能显式启用"
else
    [ -n "$unsafe_bundle_replace" ] && printf "%s\n" "$unsafe_bundle_replace" | sed 's/^/    /'
    bad "build.sh 必须保持 staging → 退出旧 PID → 原子替换，并禁止隐式 ad-hoc"
fi

section "纪律八：ScreenCaptureKit 初始化只走统一事务门"
# 内容枚举、静态截图和 SCStream 启动必须串成完整事务。若录屏/长截图直接调用，
# 就可能和普通截图在 replayd 内交错，把一次超时扩散成多个在途请求。
sck_entry_hits=$(grep -rn \
    "SCShareableContent\.getExcludingDesktopWindows\|SCShareableContent\.excludingDesktopWindows\|SCScreenshotManager\.captureImage\|stream\.startCapture(" \
    --include="*.swift" Sources/IndexApp 2>/dev/null \
    | grep -v "Platform/macOS/MacScreenCaptureBroker\.swift" \
    | code_only || true)
if [ -z "$sck_entry_hits" ]; then
    ok "截图、录屏和长截图的 SCK 初始化都经过 MacScreenCaptureBroker"
else
    printf "%s\n" "$sck_entry_hits" | sed 's/^/    /'
    bad "不得绕过 MacScreenCaptureBroker 直接枚举、截图或启动 SCStream"
fi

section "纪律九：插件框架层不引用设计令牌"
# Plugin/ 是插件框架（注册表 + 协议 + 上下文），不得引用 DS 设计令牌 ——
# 那些是 UI 层的事。具体插件的视图放 UI/ 或 Plugins/。
plugin_ui_hits=$(grep -rn "DS\." \
    --include="*.swift" Sources/IndexApp/Plugin 2>/dev/null | code_only || true)
if [ -z "$plugin_ui_hits" ]; then
    ok "Plugin/ 框架层无 DS 设计令牌引用"
else
    printf "%s\n" "$plugin_ui_hits" | sed 's/^/    /'
    bad "Plugin/ 框架层引用了 DS —— 设计令牌走 UI 层注入"
fi

section "纪律十：商店分发配置与直装版隔离"
store_config_ok=1
if ! plutil -lint Resources/Info.plist Resources/IndexAppStore.entitlements >/dev/null; then
    bad "Info.plist 或商店 entitlements 不是有效 plist"
    store_config_ok=0
fi
if ! bash -n scripts/package-app-store.sh; then
    bad "商店打包脚本语法错误"
    store_config_ok=0
fi
store_sandbox=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' \
    Resources/IndexAppStore.entitlements 2>/dev/null || true)
if [ "$store_sandbox" != "true" ]; then
    bad "商店 entitlements 必须启用 App Sandbox"
    store_config_ok=0
fi
if grep -q 'temporary-exception' Resources/IndexAppStore.entitlements; then
    bad "商店 entitlements 不得静默加入临时沙盒例外"
    store_config_ok=0
fi
if [ "$store_config_ok" -eq 1 ]; then
    ok "商店沙盒与旁路打包配置有效，且没有临时例外"
fi

section "纪律十一：Plugins 层窗口/视图子类需登记白名单"
# Plugins 层允许持有 NSWindow/NSPanel/NSWindowController/NSView 子类
# （选区覆盖层、钉图、暂存卡片是插件的本职 UI），但必须登记在白名单里 ——
# 新增窗口逻辑时显式加一行，防止窗口代码无声扩散进插件层。
window_whitelist="OverlayView
LiveTextHitTestView
OverlayWindow
ChromeView
PinImageView
PinToolbarView
PinToolbarPanel
PinWindowController
ShelfCardController
ShelfCardView"
window_subclass_hits=$(grep -rn -E '^\s*(final |private |public |open )?(class|struct) [A-Za-z_][A-Za-z0-9_]*\s*:\s*(NSWindow|NSPanel|NSWindowController|NSView|NSViewController|NSControl)\b' \
    --include="*.swift" Sources/IndexApp/Plugins 2>/dev/null | code_only || true)
window_violations=""
if [ -n "$window_subclass_hits" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        cls=$(printf "%s\n" "$line" | sed -E 's/.*(class|struct) ([A-Za-z_][A-Za-z0-9_]*)\s*:?.*/\2/')
        if ! printf "%s\n" "$window_whitelist" | grep -qx "$cls"; then
            window_violations="${window_violations}${line}"$'\n'
        fi
    done <<< "$window_subclass_hits"
fi

section "纪律十二：输入即检索的输入法 bundle 与主 App 分离"
input_method_ok=1
if ! plutil -lint Resources/IndexInputMethod-Info.plist >/dev/null; then
    bad "输入法 Info.plist 不是有效 plist"
    input_method_ok=0
fi
input_controller=$(/usr/libexec/PlistBuddy -c 'Print :InputMethodServerControllerClass' \
    Resources/IndexInputMethod-Info.plist 2>/dev/null || true)
input_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    Resources/IndexInputMethod-Info.plist 2>/dev/null || true)
input_connection=$(/usr/libexec/PlistBuddy -c 'Print :InputMethodConnectionName' \
    Resources/IndexInputMethod-Info.plist 2>/dev/null || true)
input_mode=$(/usr/libexec/PlistBuddy -c \
    'Print :ComponentInputModeDict:tsVisibleInputModeOrderedArrayKey:0' \
    Resources/IndexInputMethod-Info.plist 2>/dev/null || true)
input_platform=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' \
    Resources/IndexInputMethod-Info.plist 2>/dev/null || true)
input_background_only=$(/usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' \
    Resources/IndexInputMethod-Info.plist 2>/dev/null || true)
if [ "$input_bundle_id" != "com.wxyhgk.index.inputmethod.contentshelf" ] \
    || [ "$input_controller" != "IndexSearchInputController" ] \
    || [ "$input_connection" != "com.wxyhgk.index.inputmethod.contentshelf_Connection" ] \
    || [ "$input_mode" != "com.wxyhgk.index.inputmethod.contentshelf.Search" ] \
    || [ "$input_platform" != "MacOSX" ] \
    || [ "$input_background_only" != "true" ]; then
    bad "输入法必须使用 .inputmethod. Bundle ID，并声明稳定的 controller 与 connection name"
    input_method_ok=0
fi
if ! grep -q 'CommandLine.arguments.contains("--install")' Sources/IndexInputMethod/main.swift \
    || ! grep -q 'TISRegisterInputSource' \
        Sources/IndexInputMethod/Platform/IndexInputSourceRegistrar.swift; then
    bad "输入法必须由安装路径内的自身进程完成注册"
    input_method_ok=0
fi
if ! grep -q 'TISEnableInputSource(parentSource)' \
    Sources/IndexInputMethod/Platform/IndexInputSourceRegistrar.swift; then
    bad "安装器必须先请求启用 parent source，由系统完成用户确认"
    input_method_ok=0
fi
if ! grep -q '<key>TISInputSourceID</key>' Resources/IndexInputMethod-Info.plist \
    || ! grep -A1 '<key>tsInputModeDefaultStateKey</key>' Resources/IndexInputMethod-Info.plist \
        | grep -q '<true/>'; then
    bad "输入法必须声明顶层 source ID，且唯一主模式必须是默认模式"
    input_method_ok=0
fi
if ! grep -q 'name: "IndexInputMethod"' Package.swift \
    || ! grep -q 'INPUT_METHOD_APP_BUNDLE=' build.sh \
    || ! grep -q 'STAGED_INPUT_METHOD=' build.sh \
    || ! grep -q 'Resources/Index.icns' build.sh \
    || ! grep -q 'Resources/IndexInputMethod/PinyinIME' build.sh \
    || ! grep -q 'Resources/IndexInputMethod/\*.lproj' build.sh \
    || [ ! -f Resources/IndexInputMethod/PinyinIME/dict_pinyin.dat ] \
    || [ ! -f Resources/IndexInputMethod/PinyinIME/NOTICE ] \
    || [ ! -f Resources/IndexInputMethod/en.lproj/InfoPlist.strings ] \
    || [ ! -f Resources/IndexInputMethod/zh-Hans.lproj/InfoPlist.strings ]; then
    bad "输入法 target 必须由 build.sh 在旁路目录组装，不能另起替换脚本"
    input_method_ok=0
fi
input_side_effect_hits=$(grep -rn "NSPanel(" --include="*.swift" Sources/IndexInputMethod 2>/dev/null \
    | grep -v "/Platform/" | code_only || true)
if [ -n "$input_side_effect_hits" ]; then
    printf "%s\n" "$input_side_effect_hits" | sed 's/^/    /'
    bad "输入法窗口副作用必须收在自己的 Platform/ 目录"
    input_method_ok=0
fi
if [ "$input_method_ok" -eq 1 ]; then
    ok "输入法 target、Info.plist 与安全组装入口有效"
fi
if [ -z "$window_violations" ]; then
    ok "Plugins/ 层窗口/视图子类均在白名单内"
else
    printf "%s" "$window_violations" | sed 's/^/    /'
    bad "Plugins/ 层出现未登记的窗口/视图子类 —— 加进白名单或移回 UI 层"
fi

# -------------------------------------------------------------------- 可选：打包

if [ "${1:-}" = "--full" ]; then
    section "组装 .app（release）"
    if INDEX_BUILD_INPUT_METHOD=1 ./build.sh release >/tmp/index-bundle.log 2>&1; then
        ok "$(du -h build/Index.app/Contents/MacOS/Index | cut -f1) 可执行文件已签名"
        codesign --verify --deep build/Index.app 2>/dev/null \
            && ok "签名校验通过" || bad "签名校验失败"
        if [ -d build/IndexSearchInputMethod.app ]; then
            input_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                build/IndexSearchInputMethod.app/Contents/Info.plist 2>/dev/null || true)
            app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                build/Index.app/Contents/Info.plist 2>/dev/null || true)
            [ "$input_version" = "$app_version" ] \
                && ok "输入法版本与主 App 一致（${input_version}）" \
                || bad "输入法版本与主 App 不一致"
            codesign --verify --deep build/IndexSearchInputMethod.app 2>/dev/null \
                && ok "输入法签名校验通过" || bad "输入法签名校验失败"
        else
            bad "build.sh 未生成 IndexSearchInputMethod.app"
        fi
    else
        tail -20 /tmp/index-bundle.log | sed 's/^/    /'
        bad "build.sh 失败"
    fi
fi

echo
if [ "$failed" -eq 0 ]; then
    printf "\033[32m全部通过\033[0m\n"
else
    printf "\033[31m有检查未通过\033[0m\n"
fi
exit "$failed"
