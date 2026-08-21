# Platform

平台副作用收口与 PAL（平台抽象层）边界。

## 职责

`Platform/` 是全仓唯一允许触碰 `AppKit` 副作用的地方：`NSAlert / NSOpenPanel / NSSavePanel / runModal`、`NSPasteboard`、`NSWorkspace`、浏览器 AppleScript、LaunchAtLogin、LiveText 等。视图层（`Capture/Overlay` / `Pin` / `UI`）不再散落这些调用，一律通过本目录的门面间接使用——`check.sh` 纪律一按 `grep` 机器检查（注释行除外）。

## 文件

| 文件 | 现 macOS 实现 | 说明 |
|---|---|---|
| `Platform.swift` | `ClipboardWriting / ScreenshotCapturing / ScreenCapturing / WindowListing / WindowPinning` 协议 + `MacClipboard / MacScreenCapturer / MacWindowLister` 等包装 | PAL 骨架；新增能力先在此加协议 |
| `Clipboard.swift` | `Clipboard` / `MacClipboard` | 剪贴板读写（文本/单图/多图） |
| `MoleculePinPresenter.swift` | `MacMoleculePinPresenter` | XYZ + 3Dmol.js 交互式分子钉图 |
| `MoleculeSourceFilePresenter.swift` | `MoleculeSourceFilePresenter` | 为不可变 XYZ 附件建立可编辑工作副本，并用默认应用打开 |
| `PinWindowShell.swift` | `PinnedContentPanel` / `PinPassthroughRegistry` | 图片与分子钉图共用的窗口外壳和穿透恢复 |
| `AppAlert.swift` | `AppAlert` | `confirm / info / error` 三形态，`NSAlert` 唯一构造点 |
| `ImageExporter.swift` | `ImageExporter` | 存盘面板 + PNG 写盘 |
| `SystemNavigator.swift` | `SystemNavigator` | 目录选择、在访达中显示、打开 URL |
| `WindowRegistry.swift` | `WindowRegistry` | 窗口注册与前台管理 |
| `BrowserURLResolver.swift` | `BrowserURLResolver` | 浏览器前台 URL 解析（Safari/Chrome/Edge/Arc/Brave/Vivaldi） |
| `BrowserImportInbox.swift` | `BrowserImportInbox` | 校验并消费 Edge Native Messaging 写入的 UUID 专用图片收件箱；拒绝任意路径 |
| `LaunchAtLogin.swift` | `LaunchAtLogin` | `SMAppService` 开机启动 |
| `LiveTextAnalyzer.swift` | `LiveTextAnalyzer` | Vision LiveText 预跑分析 |
| `OpenAICompatibleSelectionAIProvider.swift` | `OpenAICompatibleSelectionAIProvider` | 选区局部 PNG → Responses API 严格结构化结果；不持久化请求 |
| `SelectionAIImageEncoder.swift` | `SelectionAIImageEncoder` | 按领域任务预算压缩局部选区，限制 PNG 与 Base64 前体积 |
| `SelectionAIKeychain.swift` | `MacSelectionAIKeychain` | 选区 AI API Key 的唯一持久化位置 |
| `PanelPlacement.swift` | `PanelPlacement` | 面板摆放（多屏感知） |
| `KeyCode.swift` | — | `KeyCode` 常量 |

## PAL 边界表

与 `Platform/Platform.swift` 顶部预留表保持一致；表头四列为**能力 / 现 macOS 实现 / 预留协议 / 未来 Win 实现**：

| 能力 | 现实现 | 预留协议 | Win 占位 |
|---|---|---|---|
| 弹提示/确认框 | `AppAlert` | `AlertPresenting` | `WinAlert` |
| 存盘面板+写 PNG | `ImageExporter` | `FileExporting` | `WinFileExporter` |
| 目录选择/在访达中显示/打开 URL | `SystemNavigator` | `SystemNavigating` | `WinSystemNavigator` |
| 窗口注册与前台管理 | `WindowRegistry` | `WindowRegistryManaging` | `WinWindowRegistry` |
| 浏览器 URL 解析 | `BrowserURLResolver` | `BrowserURLResolving` | `WinBrowserResolver` |
| 开机启动 | `LaunchAtLogin` | `LaunchAtLoginManaging` | `WinLaunchAtLogin` |
| LiveText 分析 | `LiveTextAnalyzer` | `LiveTextAnalyzing` | `WinLiveTextAnalyzer` |
| 面板摆放 | `PanelPlacement` | `PanelPlacing` | `WinPanelPlacement` |
| 剪贴板 | `Clipboard / MacClipboard` | `ClipboardWriting`（已落地） | `WinClipboard` |
| 屏幕捕获 | `MacScreenCapturer`（`Platform/macOS/`） | `ScreenCapturing`（已落地，`captureDisplays / captureWindow + 权限`） | `WinScreenCapturer` |
| 窗口列表 | `MacWindowLister`（`Platform/macOS/`） | `WindowListing`（已落地，`onScreenWindows / frontmost / bestMatch`） | `WinWindowLister` |
| 截图契约 | `ImmediateScreenSource`（`Capture/Snapshot` 仅作 `CaptureSource` 适配） | `ScreenshotCapturing`（已落地，`makeSnapshots` 适配层） | `WinScreenshot` |
| 钉图 | `PinWindowController` | `WindowPinning`（已落地） | `WinPin` |
| 3D 分子钉图 | `MacMoleculePinPresenter` | `MoleculePinning`（已落地） | `WinMoleculePin` |

## 捕获边界（ScreenCapturing / WindowListing）

`Capture/Snapshot` 不再直接 `import ScreenCaptureKit` 或调用 `CGWindowListCopyWindowInfo / CGWindowListCreateImage / SCShareableContent / SCScreenshotManager`：

* **ScreenCapturing**（`Platform.swift` 协议，`Platform/macOS/MacScreenCapturer.swift` 实现）把普通显示器冻结与整窗重拍分成两条路径。普通截图、延时截图、录屏框选和滚动截图用 `SCShareableContent + 逐屏 SCContentFilter(display:)` 冻结全部活动显示器：精确匹配 displayID、按 `frame × scale` 请求原生 Retina 像素并校验（±1px），任意一屏失败都不返回半套位图，捕获前后通过 generation 与 `DisplayTopology` 拒绝陈旧拓扑（变化时最多重取一次）。普通截图在拓扑 generation 不变时复用已成功取得的 `SCShareableContent` 显示器描述，避免每次快捷键都重新建立 TCC/ReplayKit 内容枚举连接；拓扑通知会立即清缓存。`SCShareableContent` 枚举与 `SCScreenshotManager` 请求都带 5 秒单次完成门，并由 `ScreenCaptureRequestGate` 做会话级单飞；超时只停止客户端等待，底层请求在真实回调到达前保持 quarantine，后续截图快速失败而不再向 replayd 叠加请求。任意系统级超时会立即中断整批捕获，不再逐屏放大等待。曾尝试 `/usr/sbin/screencapture -R` 两阶段实时选区，因 macOS 15 实测 CLI 同样被代理到 replayd（故障会话三块屏各等 5 秒报错）而撤回，详见 `docs/errors/2026-08-11-sidecar-capture-path-failure.md`；已废弃的 `CGDisplayCreateImage` 同因不再使用。`⌥` 整窗重拍使用 fresh `SCShareableContent + desktopIndependentWindow`（含 `backgroundColor=.clear`、`ignoreShadows*`、`colorSpaceName=sRGB`、`captureResolution=.best`），走同一个单飞门。权限统一由 `CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess` 管理。
* **MacScreenCaptureBroker**（`Platform/macOS/`）是进程内唯一的 ScreenCaptureKit 初始化入口。普通截图、整窗重拍、选区录屏和滚动截图都把“共享内容枚举 → 截图或 SCStream 启动”包在同一个事务中，互相不能交错；超时或 Task 取消后仅结束调用方等待，系统真实回调前仍保持 quarantine。普通截图失败还会清除跨请求缓存，避免 replayd 重启后继续复用旧连接上的 `SCShareableContent`。`scripts/check.sh` 纪律八阻止调用方重新绕过这个入口。
* **WindowListing**（`Platform.swift` 协议，`Platform/macOS/MacWindowLister.swift` 实现）收敛 `CGWindowListCopyWindowInfo`（`layer==0 / 排除自身PID / >20pt 过滤 / front-to-back`）；`Capture/Snapshot/WindowInfo.swift` 的 `WindowLister` 仅保留兼容转发门面。
* 调用方（`CaptureCoordinator / ScrollCaptureController / RecordingCoordinator / AppDelegate.registerCaptureSources`）只依赖 `ScreenCapturing / WindowListing` 协议，通过 `MacScreenCapturer.shared / MacWindowLister.shared` 注入；`Capture/Overlay/OverlayView.swift` 等视图层不持有任何 `ScreenCaptureKit / CGWindowList` 符号。

验证：`grep -rn ScreenCaptureKit/CGWindowListCopyWindowInfo/SCShareableContent Sources/Index/Capture` 仅剩注释行；实现仅存于 `Platform/macOS/`。

约束：

* 新增协议保持 `@MainActor + 小接口（1–3 方法）`，优先 `CGImage / URL / String` 等跨平台值类型，避免把 `NSView / NSWindow` 等 AppKit 类型泄漏到上层；由 `App` 注入具体实现。
* 已落地三条可直接注入；其余按需逐个抽协议，不一次性抽象。
* `check.sh` 纪律一保证 `NSAlert() / NSOpenPanel() / NSSavePanel() / .runModal()` 只出现在本目录。
