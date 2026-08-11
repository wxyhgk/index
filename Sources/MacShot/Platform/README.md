# Platform

平台副作用收口与 PAL（平台抽象层）边界。

## 职责

`Platform/` 是全仓唯一允许触碰 `AppKit` 副作用的地方：`NSAlert / NSOpenPanel / NSSavePanel / runModal`、`NSPasteboard`、`NSWorkspace`、浏览器 AppleScript、LaunchAtLogin、LiveText 等。视图层（`Capture/Overlay` / `Pin` / `UI`）不再散落这些调用，一律通过本目录的门面间接使用——`check.sh` 纪律一按 `grep` 机器检查（注释行除外）。

## 文件

| 文件 | 现 macOS 实现 | 说明 |
|---|---|---|
| `Platform.swift` | `ClipboardWriting / ScreenshotCapturing / ScreenCapturing / WindowListing / WindowPinning` 协议 + `MacClipboard / MacScreenCapturer / MacWindowLister` 等包装 | PAL 骨架；新增能力先在此加协议 |
| `Clipboard.swift` | `Clipboard` / `MacClipboard` | 剪贴板读写（文本/单图/多图） |
| `AppAlert.swift` | `AppAlert` | `confirm / info / error` 三形态，`NSAlert` 唯一构造点 |
| `ImageExporter.swift` | `ImageExporter` | 存盘面板 + PNG 写盘 |
| `SystemNavigator.swift` | `SystemNavigator` | 目录选择、在访达中显示、打开 URL |
| `WindowRegistry.swift` | `WindowRegistry` | 窗口注册与前台管理 |
| `BrowserURLResolver.swift` | `BrowserURLResolver` | 浏览器前台 URL 解析（Safari/Chrome/Edge/Arc/Brave/Vivaldi） |
| `LaunchAtLogin.swift` | `LaunchAtLogin` | `SMAppService` 开机启动 |
| `LiveTextAnalyzer.swift` | `LiveTextAnalyzer` | Vision LiveText 预跑分析 |
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

## 捕获边界（ScreenCapturing / WindowListing）

`Capture/Snapshot` 不再直接 `import ScreenCaptureKit` 或调用 `CGWindowListCopyWindowInfo / CGWindowListCreateImage / SCShareableContent / SCScreenshotManager`：

* **ScreenCapturing**（`Platform.swift` 协议，`Platform/macOS/MacScreenCapturer.swift` 实现）把普通显示器冻结与整窗重拍分成两条路径。普通截图、延时截图、录屏框选和滚动截图用 `NSScreen → displayID → CGDisplayCreateImage` 直接读取每块显示器的原生 Retina 位图，不建立 ScreenCaptureKit/replayd 会话；三块 2× 屏现场返回 `3840×2160`、`1440×2560`、`3360×1890`，总耗时约 `0.09–0.15s`。任意一屏失败都不返回半套位图，捕获前后通过 generation 与 `DisplayTopology` 拒绝陈旧拓扑。`SCScreenshotManager.captureImage(in:)` 未用于主路径，因为现场只返回不可配置的统一 1× 位图；逐屏 SCK 也未作为回退，因为它会在故障主机上再次触发 replayd 崩溃。只有 `⌥` 整窗重拍才使用 fresh `SCShareableContent + desktopIndependentWindow`（含 `backgroundColor=.clear`、`ignoreShadows*`、`colorSpaceName=sRGB`、`captureResolution=.best`），并由 5 秒单次完成门阻止无界等待。权限统一由 `CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess` 管理。
* **WindowListing**（`Platform.swift` 协议，`Platform/macOS/MacWindowLister.swift` 实现）收敛 `CGWindowListCopyWindowInfo`（`layer==0 / 排除自身PID / >20pt 过滤 / front-to-back`）；`Capture/Snapshot/WindowInfo.swift` 的 `WindowLister` 仅保留兼容转发门面。
* 调用方（`CaptureCoordinator / ScrollCaptureController / RecordingCoordinator / AppDelegate.registerCaptureSources`）只依赖 `ScreenCapturing / WindowListing` 协议，通过 `MacScreenCapturer.shared / MacWindowLister.shared` 注入；`Capture/Overlay/OverlayView.swift` 等视图层不持有任何 `ScreenCaptureKit / CGWindowList` 符号。

验证：`grep -rn ScreenCaptureKit/CGWindowListCopyWindowInfo/SCShareableContent Sources/MacShot/Capture` 仅剩注释行；实现仅存于 `Platform/macOS/`。

约束：

* 新增协议保持 `@MainActor + 小接口（1–3 方法）`，优先 `CGImage / URL / String` 等跨平台值类型，避免把 `NSView / NSWindow` 等 AppKit 类型泄漏到上层；由 `App` 注入具体实现。
* 已落地三条可直接注入；其余按需逐个抽协议，不一次性抽象。
* `check.sh` 纪律一保证 `NSAlert() / NSOpenPanel() / NSSavePanel() / .runModal()` 只出现在本目录。
