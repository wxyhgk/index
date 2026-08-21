# Index 源码目录

`Sources/Index` 单 target（`swiftLanguageMode(.v5)` + GRDB），按**依赖方向**而非技术类型分层。

## 依赖方向

```
App（编排，唯一认识所有人）
 ├─ Capture / Pin / Gallery / Editor / Shelf / Settings（界面层，互不认识）
 ├─ Actions / Pipeline（契约实现集合）
 ├─ Annotation / Toolbar / Render（共享领域）
 └─ Storage（纯值模型）
Services/Platform + Intelligence + Recording 侧挂
```

`check.sh` 五纪律：面板只在 `Platform/`、下层不认 `GalleryView`、不许 `switch kind`、CSS 只认 DS、API 走 PAL。

## 分层：CSS / API

### CSS 层（视觉）—— `DS` 唯一入口

| 层 | 文件 | 职责 |
|---|---|---|
| CSS | `UI/DesignTokens.swift` (`DS`) | 间距 s1…s5 / 圆角 4→18 / 分类色 / 状态色 / 表面填充 / 描边 / 阴影 / 动效 / 外壳。与 `Theme` 双轨已收敛：`Theme` 仅为兼容转发（`UI/Theme.swift` deprecated），新代码一律 `DS.xxx`。 |
| 视图 | `UI/*.swift` / `Annotation/Tools/*` | 只读 `DS`，不裸写 `Color.primary.opacity` / `Color.accentColor.opacity` / `.quaternary` 等。裸写一律收敛为 `DS` token（见 `DesignTokens.swift` 顶部注释）。 |

### API 层（平台）—— `Platform/Platform.swift` PAL 骨架

| 层 | 文件 | 职责 |
|---|---|---|
| PAL 协议 | `Platform/Platform.swift` | 定义 `ClipboardWriting` / `ScreenshotCapturing` / `WindowPinning` 等协议，`App` 注入具体实现。未来 Windows 另实现 `WinClipboard` 等，上层不改。 |
| macOS 实现 | `Platform/Clipboard.swift` `ImageExporter.swift` `SystemNavigator.swift` `AppAlert.swift` `WindowRegistry.swift` 等 | 真正调 `AppKit` / `NSPasteboard` / `NSAlert` / `NSOpenPanel` 的地方。`check.sh` 纪律一保证 `NSAlert`/`NSOpenPanel`/`runModal` 只在此目录。 |

预留 PAL 映射（已在 `Platform/Platform.swift` 顶部注释成表）：`AppAlert→AlertPresenting`、`ImageExporter→FileExporting`、`SystemNavigator→SystemNavigating`、`WindowRegistry→WindowRegistryManaging` 等，按需逐个抽协议，保持 `@MainActor` 小接口。

## 目录

| 目录 | 职责 | 关键文件 |
|---|---|---|
| `App/` | 装配与主流程：`CaptureCoordinator` 串 `Source→选区→入库→Pipeline→Action` | `AppDelegate/CaptureCoordinator/GlobalHotKey` |
| `Capture/` | 冻结截图：`Snapshot/`定格、`Selection/`纯逻辑选区、`Overlay/`浮层、`Magnifier/`放大、`Metadata/`元数据 | `OverlayView 529` 曾 661，已拆 `+LiveText/+Magnifier` |
| `Pin/` | 钉图：图片窗+工具条子窗分离 | `PinImageView/PinWindowController` |
| `UI/` | 图库与编辑器（原 8790 行，已拆 `Gallery`/`Editor`） | `GalleryGrid/EditorView 619/EditorToolbar/EditorInspector` |
| `Annotation/` | 标注域：`AnnotationState`+`ToolDescriptor` 11 工具各一文件 | `Tools/` |
| `Toolbar/` | 工具条注册：`ToolbarControl/Registry/Layout`，尺寸不依赖画布 | `ToolbarLayout` |
| `Render/` | 唯一绘制：`LayerRenderer` | `LayerRenderer` |
| `Storage/` | 非破坏修订：`ShotStore` + `ShotReading/Writing` 协议首刀 | `ShotStore/ShotReading` |
| `Services/Platform` | 副作用收口：剪贴板、导出、窗口、AI HTTP/Keychain | `Clipboard/OpenAICompatibleSelectionAIProvider/SelectionAIKeychain` |
| `Services/Intelligence` | OCR/CLIP/分类/敏感/选区智能契约 | `VisionOCR/CLIP*/SelectionAI/*` |
| `Services/Recording` | 录屏 `ScreenRecorder/GIFExporter` | `ScreenRecorder` |
| `Settings/` | 普通配置由 `AppSettings`（UserDefaults）管理；AI 密钥只经 Keychain | `AppSettings/SelectionAISettings` |
| `Shelf/` | 暂存卡片真文件拖拽 | `ShelfController` |

## 扩展点

`CaptureSource` / `PostProcessor` / `CaptureAction` / `ToolbarControl` / `ToolDescriptor` / `EffectLayer` / `GalleryDestination` / `SelectionAIProvider`——新增即“加文件+装配或注册一行”，不改协调器。

## 构建

`swift build` / `swift test` / `./scripts/check.sh`（构建+测试+架构纪律），`./build.sh` 会先旁路组装和固定身份签名，旧 Index/Index 完全退出后再原子替换 `build/Index.app`，并按原运行状态自动拉起。签名顺序是 `Developer ID → Index Dev`；ad-hoc 只允许通过环境变量显式启用。
