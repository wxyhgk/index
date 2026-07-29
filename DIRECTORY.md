# MacShot 目录说明

一个 SwiftPM target（`MacShot`），目录不按技术类型分（没有 Views / Models / Controllers 这种分法），而是按**这块代码在依赖链的哪一层、允许认识谁**来分。

规则只有一条，来自 `ARCHITECTURE.md`：**依赖只向下，同层互不认识。** 想知道一段代码该放哪，就问它需要认识谁——需要认识窗口和用户操作的，放界面层；只需要认识图层和像素的，放领域层；碰系统 API 的，放 `Platform/`。

```
App/                    编排：只有它认识所有人
  ├── Capture/ Pin/ UI/ Settings/ Shelf/      界面与交互，彼此不认识
  ├── Actions/ Pipeline/                      三个契约的实现集合
  ├── Annotation/ Toolbar/ Render/            共享领域逻辑
  └── Storage/                                模型与持久化
Platform/ Intelligence/ Recording/            侧挂，被各层调用
```

---

## 顶层

| 路径 | 说明 |
|---|---|
| `Package.swift` | 单 target + GRDB 依赖 + 测试 target，`swiftLanguageMode(.v5)` |
| `build.sh` | 组装 `.app` bundle 并签名，签名优先级 Developer ID → 自签名 "MacShot Dev" → ad-hoc |
| `scripts/make-dev-cert.sh` | 生成自签名证书。**存在的理由**：ad-hoc 签名的 cdhash 每次编译都变，macOS 会认为是另一个 App 而反复要求重新授权屏幕录制；固定证书给出稳定的 designated requirement，授权一次即可 |
| `Resources/Info.plist` | bundle 元信息与权限用途说明 |
| `ARCHITECTURE.md` | 规范文档：依赖方向、五个扩展点、类型约定、违例表、阶段进度 |
| `DIRECTORY.md` | 本文件 |
| `README.md` | 面向使用者的功能与版本说明 |
| `Tests/MacShotTests/` | 迁移链、清理豁免规则、引用计数删文件。2026-07 才有，此前零测试 |

---

## App/ — 编排层（5 文件 / 1396 行）

全场唯一认识所有人的地方，负责把各层装配起来并驱动流程。

- `AppDelegate` — 菜单栏、生命周期，以及**所有注册表的登记处**（动作、处理器、捕获源、工具条控件都在这里注册）
- `CaptureCoordinator` — 截图主流程：`begin(sourceID:)` 取捕获源 → 选区 → `handle()` 落库并触发流水线 → `run(actionID:)` 执行出口动作
- `GlobalHotKey` — Carbon `RegisterEventHotKey` 全局热键，支持临时绑定（如截图期间的 ⎋）
- `ScrollCaptureController` — 滚动截图的 SCStream 采集编排
- `URLCommandRouter` — `macshot://` 深链（SwiftPM 下无法用 App Intents 的替代方案）

> **这里是最不该被改动的目录。** 如果加一个功能时发现要改 `CaptureCoordinator`，通常说明缺一个扩展点，而不是该在这里加分支。

## Capture/ — 截图浮层与像素采集（19 文件 / 2692 行）

实现「冻结截图」架构：按下热键的瞬间把所有显示器冻结成位图，之后的选区、标注、放大镜、取色、Live Text 全部在冻结像素上进行，确认即裁剪。好处是所见即所得、零延迟，而且让放大镜和文字识别可以提前跑。

- `ScreenFreezer` / `DisplaySnapshot` — 冻结与快照。`detached()` 会重新渲染一张独立位图，因为 `CGImage.cropping` 会持有整屏后备存储（四屏时曾导致内存爆到 258MB）
- `OverlayWindow` / `OverlayView` / `OverlayView+Keyboard` / `OverlayRenderer` — 浮层窗口、交互与绘制
- `SelectionModel` — 纯逻辑选区状态机，不碰绘制不碰事件循环
- `CaptureSource` / `DelayedScreenSource` — 入口契约与延时截图实现
- `WindowCapturer` — ⌥+单击整窗截图，本质是选区**之后**的事后重拍（用 SCK 拿到不被遮挡的完整窗口）
- `ScrollStitcher` — 纯函数滚动拼接（行亮度签名 + 尾部锚点匹配）
- `MagnifierRenderer` / `PixelSample` / `MetadataCollector` / `WindowInfo` / `Geometry`

**加捕获方式**：实现 `CaptureSource` + 注册一行，不改协调器。

## Pin/ — 钉图窗口（3 文件 / 813 行）

把截图钉在屏幕最上层。关键设计是它**复用同一套标注系统和工具条**——早期钉图有独立的第二套工具条，用起来割裂，后来统一。

- `PinWindowController` — 窗口与 `CaptureActionHost` 实现，负责修订落库
- `PinImageView` — 图像、标注、Live Text、悬停时浮现的工具条
- `PinKeyboard` — 按键分发（工具键消费 `AnnotationTool` 的公共快捷键表）

## UI/ — 图库与编辑器（24 文件 / 6571 行）

同一个窗口的两个模式：图库（浏览、搜索、多选、标签）和编辑器（标注、图层、效果）。编辑器曾做成独立窗口，因为割裂感又并回了图库窗口。

- `GalleryView` — 三栏布局（侧边栏 / 网格 / 详情栏）、卡片、批量操作、相似 sheet
- `EditorView` — Snagit 风格编辑器：工具栏、画布、图层与效果面板、胶片条
- `GalleryWindowMode` — 窗口处于哪个模式（存截图 ID 而非快照）+ `GalleryKeyContext` 统一按键让位判定
- `GalleryKeyboard` / `QuickLookController` / `EditorCanvasScrollView` — 三处事件处理，靠上面那个共享判定协调
- `LayerCanvas` / `ThumbnailImage` / `WaterfallLayout` / `TimelineView` / `TagSection` / `DesignTokens`

图库部分已按「空间 UI」设计语言改版：`DesignTokens`（`extension DS`）定义深度层、渐变描边、发光、动效四档等 token，`SpatialModifiers` 提供 `spatialCard` / `glassPanel` / `parallaxThumbnail` 等修饰器。改视觉时**先读 `docs/spatial-ui-spec.md`**——里面每个数值都有出处，尤其"内容层不上玻璃""深色靠亮度阶梯不靠阴影"两条铁律，违反了会浑浊或卡顿。

> **现存债务**：`EditorView` 1194 行装了 6 种职责，靠 26 处手动 `annotationTick` 驱动重绘，是下一批拆分对象。`ShotDetailPane` 里的 `maskSensitiveRegions` 是业务逻辑，待下沉到存储层。

## Settings/ — 应用内设置（5 文件 / 1319 行）

`AppSettings` 是所有配置的单一真相（UserDefaults 支撑），`ShortcutRecorder` 支持热键重绑，设置页的按键说明从 `AnnotationTool` 的快捷键表生成而不是手写。

## Shelf/ — 暂存架（3 文件 / 483 行）

截图后浮出的临时卡片，可直接拖进别的 App。拖拽用的临时文件由 `ShelfController` 统一清理。

## Actions/ — 出口契约（6 文件 / 388 行）

「结果怎么出去」：钉图、复制、保存、上传图床、OCR 取字、Bug 报告。

`CaptureAction` 协议要求 `async throws`（上传和 GIF 是长耗时可失败操作），并用 `suppressesAutoCopy` 表达「这个动作自己管剪贴板」、`isPrimaryAction` 表达「是否在截图工具条上直接露出」。

**加动作**：新文件 + 注册一行，工具条和协调器都不用动。

## Pipeline/ — 中间契约（4 文件 / 298 行）

「派生能力怎么挂上去」：截图落库后跑的异步处理，互相独立，失败不影响主流程。结果通过 `ShotAttributeWriter` 写进通用属性表，因此**加能力不需要改数据库 schema**。

`AttributeBackfill` 负责给老截图补跑新能力。

**加派生能力**：新处理器文件 + 两处注册（流水线 + 回填表）+ 一个属性 key。

## Annotation/ — 标注领域逻辑（7 文件 / 1693 行）

截图浮层、钉图、编辑器三个宿主共用的同一套东西——这是「三处标注行为一致」的根本原因。

- `AnnotationState` — 状态机 + 撤销栈（撤销记录里存马赛克贴片，保证撤销后像素完全还原）
- `AnnotationTool` — 工具定义与**唯一的快捷键表**
- `LayerSpace` — phantom type，用类型区分「画布点」和「图像像素」两套坐标，唯一的桥是 `projected(onto:scale:)`
- `EffectLayer` / `EffectSpecs` — 效果层契约（水印/美化/外壳/捕获信息），排除逻辑一律从 `kind.isEffect` 派生
- `ResizeHandle` / `AnnotationRenderer`

## Toolbar/ — 工具条注册制（6 文件 / 767 行）

工具条不是写死的按钮列表，而是控件注册表：每个控件声明自己的分组、次序、可见条件和视图，注册表按 scope（截图 / 钉图 / 编辑器）聚合，动作控件由 `CaptureActionRegistry` 自动展开。

**加按钮**：注册一行。

## Render/ — 绘制唯一真相（1 文件 / 1043 行）

`LayerRenderer` 是全项目唯一的图层绘制实现。所有预览（浮层、钉图、编辑器画布）和导出都走它，调用方只允许设置 CTM——这解决了早期「编辑器手写近似绘制」导致的所见非所得。

公共入口只接受 `Layers<ImageSpace>`，坐标错误在编译期就被挡住。导出套用次序固定：裁剪 → 水印 → 捕获信息 → 外壳 → 美化背景。

> **现存债务**：单文件 1043 行。

## Storage/ — 持久化（7 文件 / 1450 行）

SQLite + GRDB。核心设计是**非破坏性编辑**：原图永不修改，每次改动追加一条修订记录（图层 JSON），因此可以无限回溯。

- `Models` — `Layer` / `Shot` / `Revision` 等纯值类型
- `AppDatabase` — v1→v4 迁移链 + FTS5 虚表（trigram 分词，中文可子串搜索）
- `ShotStore` — 数据门面，写路径带 reload 节流合并
- `ShotAttribute` — 属性 key 常量表
- `StorageJanitor` / `ImageCodec` / `ShotStoreAttributeWriter`（连接 Pipeline 的桥）

> **现存债务**：`ShotStore` 801 行 13 种职责，且仍是主线程同步 IO。拆门面 + 移出主线程是 ARCHITECTURE 阶段 6 的剩余部分。

## Intelligence/ — 视觉与模型（8 文件 / 1117 行）

Vision 与 CoreML 的封装，**纯计算，不认识数据库**——结果一律通过 Pipeline 的 writer 落库。

OCR、场景标签、内容分类、敏感信息检测、相似图特征指纹，以及 CLIP 三件套（模型下载管理 / 编码 / 分词），支撑自然语言语义搜索。

## Platform/ — 系统副作用唯一出口（10 文件 / 689 行）

凡是「与系统打交道」的操作都必须收敛到这里：剪贴板、导出存盘、弹窗、访达与系统设置跳转、窗口生命周期与 Dock 图标、浏览器地址获取、图床上传、Live Text 分析、开机自启、键码映射。

**纪律**：其他地方不许出现 `NSAlert()` / `NSOpenPanel()` / `runModal()`。这条规矩是因为早期出现过「三份存盘面板行为不一致」，而 2026-07 审计又发现批量导出偷偷内联了一份目录选择面板——收敛不是做完一次就结束，需要定期巡检。

## Recording/ — 录屏（4 文件 / 861 行）

相对独立的子系统：`ScreenRecorder` 用 SCK 分段录制再无损拼接（支持暂停继续），`GIFExporter` 转 GIF，`MicrophonePermission` 处理麦克风授权。
