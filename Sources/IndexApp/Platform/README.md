# Platform

平台副作用收口与 PAL（平台抽象层）边界。

## 职责

`Platform/` 是全仓唯一允许触碰 `AppKit` 副作用的地方：`NSAlert / NSOpenPanel / NSSavePanel / runModal`、`NSPasteboard`、`NSWorkspace`、浏览器 AppleScript、LaunchAtLogin、LiveText 等。视图层（`Capture/Overlay` / `Pin` / `UI`）不再散落这些调用，一律通过本目录的门面间接使用——`check.sh` 纪律一按 `grep` 机器检查（注释行除外）。

## 目录

macOS 实现按能力放在 `macOS/` 的子目录中；根目录只保留 PAL 协议。

| 路径 | 现 macOS 实现 | 说明 |
|---|---|---|
| `Platform.swift` | `ClipboardWriting / ClipboardReading / ScreenCapturing / WindowListing / MoleculePinning` 等协议 | PAL 骨架；只为已有实现和真实消费者保留协议 |
| `macOS/Capture/` | `MacScreenCaptureBroker / MacScreenCapturer / MacWindowLister / ScreenCaptureRequestGate` | ScreenCaptureKit 捕获、窗口枚举与请求门 |
| `macOS/Clipboard/` | `Clipboard / ClipboardWatcher / ClipboardPasteDispatcher` | 剪贴板读写、监听与粘贴派发 |
| `macOS/Windowing/` | `AppAlert / ImageExporter / SystemNavigator / WindowRegistry / PanelPlacement` 等 | 系统窗口、面板、导航与应用窗口生命周期 |
| `macOS/Browser/` | `BrowserURLResolver / BrowserImportInbox` | 浏览器前台 URL 解析与 Native Messaging 图片收件箱 |
| `macOS/Pin/` | `MacMoleculePinPresenter / MoleculeSourceFilePresenter / PinnedContentPanel` | 分子钉图、源文件打开及共用窗口外壳 |
| `macOS/Input/` | `KeyCode` | macOS 虚拟键码常量 |
| `macOS/InputSearch/` | `FocusedTextSearchController / ContextSearchPanelController` | Accessibility 焦点读取、事件监听及检索结果面板 |
| `macOS/Vision/` | `LiveTextAnalyzer` | Vision LiveText 预跑分析 |
| `macOS/Security/` | `MacSelectionAIKeychain / MacAgentKeychain` | AI API Key 的唯一持久化位置；实现 `Intelligence/SelectionAI` 定义的窄协议 |
| `macOS/Distribution/` | `IndexDistribution` | 运行时分发渠道判断 |

## 已落地契约

这里只记录同时拥有生产实现和真实消费者的协议，不保留尚未实现的占位抽象：

| 能力 | 协议 | 生产实现 |
|---|---|---|
| 剪贴板读写 | `ClipboardReading / ClipboardWriting` | `MacClipboard` |
| 屏幕捕获 | `ScreenCapturing` | `MacScreenCapturer` |
| 窗口枚举 | `WindowListing` | `MacWindowLister` |
| 3D 分子钉图 | `MoleculePinning` | `MacMoleculePinPresenter` |
| 钉图穿透恢复 | `PinPassthroughControlling` | `PinWindowController / MoleculePinWindowController` |

## 捕获边界（ScreenCapturing / WindowListing）

`Capture/Snapshot` 不再直接 `import ScreenCaptureKit` 或调用 `CGWindowListCopyWindowInfo / CGWindowListCreateImage / SCShareableContent / SCScreenshotManager`：

* **ScreenCapturing**（`Platform.swift` 协议，`Platform/macOS/Capture/MacScreenCapturer.swift` 实现）把普通显示器冻结与整窗重拍分成两条路径。普通截图、延时截图、录屏框选和滚动截图用 `SCShareableContent + 逐屏 SCContentFilter(display:)` 冻结全部活动显示器：精确匹配 displayID、按 `frame × scale` 请求原生 Retina 像素并校验（±1px），任意一屏失败都不返回半套位图，捕获前后通过 generation 与 `DisplayTopology` 拒绝陈旧拓扑（变化时最多重取一次）。普通截图在拓扑 generation 不变时复用已成功取得的 `SCShareableContent` 显示器描述，避免每次快捷键都重新建立 TCC/ReplayKit 内容枚举连接；拓扑通知会立即清缓存。`SCShareableContent` 枚举与 `SCScreenshotManager` 请求都带 5 秒单次完成门，并由 `ScreenCaptureRequestGate` 做会话级单飞；超时只停止客户端等待，底层请求在真实回调到达前保持 quarantine，后续截图快速失败而不再向 replayd 叠加请求。任意系统级超时会立即中断整批捕获，不再逐屏放大等待。曾尝试 `/usr/sbin/screencapture -R` 两阶段实时选区，因 macOS 15 实测 CLI 同样被代理到 replayd（故障会话三块屏各等 5 秒报错）而撤回，详见 `docs/errors/2026-08-11-sidecar-capture-path-failure.md`；已废弃的 `CGDisplayCreateImage` 同因不再使用。`⌥` 整窗重拍使用 fresh `SCShareableContent + desktopIndependentWindow`（含 `backgroundColor=.clear`、`ignoreShadows*`、`colorSpaceName=sRGB`、`captureResolution=.best`），走同一个单飞门。权限统一由 `CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess` 管理。
* **MacScreenCaptureBroker**（`Platform/macOS/Capture/`）是进程内唯一的 ScreenCaptureKit 初始化入口。普通截图、整窗重拍、选区录屏和滚动截图都把“共享内容枚举 → 截图或 SCStream 启动”包在同一个事务中，互相不能交错；超时或 Task 取消后仅结束调用方等待，系统真实回调前仍保持 quarantine。普通截图失败还会清除跨请求缓存，避免 replayd 重启后继续复用旧连接上的 `SCShareableContent`。`scripts/check.sh` 纪律八阻止调用方重新绕过这个入口。
* **WindowListing**（`Platform.swift` 协议，`Platform/macOS/Capture/MacWindowLister.swift` 实现）收敛 `CGWindowListCopyWindowInfo`（`layer==0 / 排除自身PID / >20pt 过滤 / front-to-back`）；`Capture/Snapshot/WindowInfo.swift` 的 `WindowLister` 仅保留兼容转发门面。
* 调用方（`CaptureCoordinator / ScrollCaptureController / RecordingCoordinator / AppDelegate.registerCaptureSources`）只依赖 `ScreenCapturing / WindowListing` 协议，通过 `MacScreenCapturer.shared / MacWindowLister.shared` 注入；`Capture/Overlay/OverlayView.swift` 等视图层不持有任何 `ScreenCaptureKit / CGWindowList` 符号。

验证：`grep -rn ScreenCaptureKit/CGWindowListCopyWindowInfo/SCShareableContent Sources/Index/Capture` 仅剩注释行；实现仅存于 `Platform/macOS/`。

约束：

* 新增协议保持 `@MainActor + 小接口（1–3 方法）`，优先 `CGImage / URL / String` 等跨平台值类型，避免把 `NSView / NSWindow` 等 AppKit 类型泄漏到上层；由 `App` 注入具体实现。
* 已落地协议必须同时有生产实现和真实消费者；不为假设中的移植场景保留空协议。
* `check.sh` 纪律一保证 `NSAlert() / NSOpenPanel() / NSSavePanel() / .runModal()` 只出现在本目录。
