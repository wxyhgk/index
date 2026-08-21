# Index 开发目录说明

产品名是 **Index**，当前 SwiftPM target 和部分内部类型仍沿用 `Index`。目录不按技术类型分（没有 Views / Models / Controllers 这种分法），而是按**这块代码在依赖链的哪一层、允许认识谁**来分。

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
| `build.sh` | 在旁路目录组装并固定身份签名，退出旧 Index/Index 后原子替换 `Index.app`，按原运行状态自动重启；签名优先级 Developer ID → 自签名 "Index Dev"，ad-hoc 只可显式启用 |
| `Sources/Index/` | 应用源码，按依赖边界分模块 |
| `Tests/IndexTests/` | 单元、回归、架构和生命周期测试 |
| `Resources/` | `Info.plist`、应用图标及品牌 SVG 源文件 |
| `BrowserExtensions/Edge/` | Edge 图片导入扩展、Native Messaging host 与独立说明 |
| `Contracts/` | 面向未来 Windows 客户端的便携图库和标注 JSON Schema |
| `docs/` | 产品设计、开发记录、故障记录、CI 说明与 README 截图 |
| `scripts/` | 架构检查、证书、品牌资源和浏览器扩展安装脚本 |
| `scripts/make-dev-cert.sh` | 生成自签名证书。**存在的理由**：ad-hoc 签名的 cdhash 每次编译都变，macOS 会认为是另一个 App 而反复要求重新授权屏幕录制；固定证书给出稳定的 designated requirement，授权一次即可 |
| `Resources/Info.plist` | bundle 元信息与权限用途说明 |
| `ARCHITECTURE.md` | 规范文档：依赖方向、八个扩展点、类型约定、违例表、阶段进度 |
| `DIRECTORY.md` | 本文件 |
| `README.md` | 面向使用者的功能与版本说明 |
| `.build/` | SwiftPM 编译缓存，已忽略；可重新生成，不属于交付物 |
| `build/` | `build.sh` 的 Release 输出，已忽略；运行中的 `Index.app` 不得直接覆盖或删除 |

### 文档目录

```text
docs/
├── README.md         文档分类索引
├── changes/          已完成改动与修复记录
├── design/mockups/   4K 界面方案原稿，不直接用于 README
├── errors/           可复盘的捕获、签名与系统服务事故
├── images/           README 和发布页实际使用的产品截图
├── ci.md             CI 与 Release 说明
├── gallery-chrome-spec.md
└── spatial-ui-spec.md
```

根目录只保留构建入口、架构文档和项目级元数据；临时设计稿不要再新建根级 `img/`。

---

## App/ — 编排层

全场唯一认识所有人的地方，负责把各层装配起来并驱动流程。

- `AppDelegate` — 菜单栏、生命周期，以及**所有注册表的登记处**（动作、处理器、捕获源、工具条控件都在这里注册）
- `CaptureCoordinator` — 截图主流程：`begin(sourceID:)` 取捕获源 → 选区 → `handle()` 落库并触发流水线 → `run(actionID:)` 执行出口动作
- `GlobalHotKey` — Carbon `RegisterEventHotKey` 全局热键，支持临时绑定（如截图期间的 ⎋）
- `ScrollCaptureController` — 滚动截图的 SCStream 采集编排
- `URLCommandRouter` — `macshot://` 深链（SwiftPM 下无法用 App Intents 的替代方案）

> **这里是最不该被改动的目录。** 如果加一个功能时发现要改 `CaptureCoordinator`，通常说明缺一个扩展点，而不是该在这里加分支。

## Capture/ — 截图浮层与像素采集

实现「冻结截图」架构：按下热键的瞬间把所有显示器冻结成位图，之后的选区、标注、放大镜、取色、Live Text 全部在冻结像素上进行，确认即裁剪。好处是所见即所得、零延迟，而且让放大镜和文字识别可以提前跑。

- `ScreenFreezer` / `DisplaySnapshot` — 冻结与快照。`detached()` 会重新渲染一张独立位图，因为 `CGImage.cropping` 会持有整屏后备存储（四屏时曾导致内存爆到 258MB）
- `OverlayWindow` / `OverlayView` / `OverlayView+Keyboard` / `OverlayRenderer` — 浮层窗口、交互与绘制
- `SelectionModel` — 纯逻辑选区状态机，不碰绘制不碰事件循环
- `CaptureSource` / `DelayedScreenSource` — 入口契约与延时截图实现
- `WindowCapturer` — ⌥+单击整窗截图，本质是选区**之后**的事后重拍（用 SCK 拿到不被遮挡的完整窗口）
- `ScrollStitcher` — 纯函数滚动拼接（行亮度签名 + 尾部锚点匹配）
- `MagnifierRenderer` / `PixelSample` / `MetadataCollector` / `WindowInfo` / `Geometry`

**加捕获方式**：实现 `CaptureSource` + 注册一行，不改协调器。

## Pin/ — 钉图窗口

把截图钉在屏幕最上层。关键设计是它**复用同一套标注系统和工具条**——早期钉图有独立的第二套工具条，用起来割裂，后来统一。

结构是**上下两块**：图片一个窗口，工具条一个窗口。工具条曾画在图片窗口内部、从窗口高度里切走一条「条带」，而条带高度又取决于窗口宽度（放不下就折行）——缩放钉图会改变工具条，工具条又反过来改变图片的显示倍率。拆开之后工具条按内容开自然尺寸，钉图缩到多小、放到多大都不动它。

- `PinWindowController` — 窗口与 `CaptureActionHost` 实现，负责修订落库；把工具条窗口挂成子窗口并在父窗口 frame 变化时重新落位
- `PinImageView` — **只装图片**：图像、标注、Live Text
- `PinToolbarWindow` — 工具条子窗口（`PinToolbarPanel` + `PinToolbarView`）。不持有任何状态，画什么、点了谁处理全部回到 `PinImageView`
- `PinKeyboard` — 按键分发（工具键消费 `AnnotationTool` 的公共快捷键表）

## UI/ — 图库与编辑器

同一个窗口的两个模式：图库（浏览、搜索、多选、标签）和编辑器（标注、图层、效果）。编辑器曾做成独立窗口，因为割裂感又并回了图库窗口。

图库是**定制 chrome**：没有系统工具栏，红绿灯浮在自绘顶栏上，各功能区是浮在窗口底色上的圆角面板。

- `GalleryView` — 窗口壳：模式分支 + 浮动面板装配。**刻意只依赖模式与详情栏开关两个状态**，任何每帧变化的量（尤其宽度）都不许放这一层，否则整窗每帧重建（有过这个性能事故）
- `GalleryShell` — 浮动面板容器与通用控件：`floatingPanel` / `ShellIconButtonStyle` / `PanelCloseButton` / `GalleryInspectorPanel`
- `GalleryTopBar` / `GalleryPageHeader` — 自绘顶栏（logo、⌘K 搜索胶囊、语义搜索 scope 菜单、筛选/视图/设置）与页面头部（大标题、项目数、筛选胶囊）
- `GalleryDestination` / `BuiltinDestinations` — **顶层选项**契约与注册表（第七个扩展点）：一个选项自带 `content()` 与 `inspector()`，加一个 = 新建实现 + 注册一行。首批两个：截图库、应用。选项呈现为顶栏的分段控件——左侧曾有一整条 232pt 侧边栏放它们，那正好吃掉一列缩略图
- `GalleryGrid` / `ShotCard` / `WaterfallLayout` — 网格与卡片（无底色，图片直接浮在窗底上）、底部悬浮胶囊工具条
- `ShotDetailPane` / `ShotInfoPage` / `InspectorControls` / `MultiSelectionPane` / `TagSection` — 详情面板的摘要页与「全部信息」下钻页
- `EditorView` — Snagit 风格编辑器：工具栏、画布、图层与效果面板、胶片条
- `GalleryWindowMode` — 窗口处于哪个模式：图库 / 编辑器（存截图 ID 而非快照）/ 设置，整窗切换不是弹窗；`GalleryKeyContext` 是两个按键 monitor 的统一让位判定
- `GalleryKeyboard` / `QuickLookController` / `EditorCanvasScrollView` — 三处事件处理，靠上面那个共享判定协调
- `DesignTokens` / `SpatialModifiers` / `LayerCanvas` / `ThumbnailImage` / `TimelineView`

改视觉前**先读 `docs/gallery-chrome-spec.md`**（目标设计的逐块拆解）与 `docs/spatial-ui-spec.md`（原则、数值出处、性能红线）。两条最容易被无意推翻的铁律：**卡片不许加回底色/材质**（几百张卡的图层数会炸），**面板不许加 Material**（每窗只允许一个 behindWindow 材质，且窗底不透明、材质只会采样自家底色）。

> **现存债务**：`EditorView` 1194 行装了 6 种职责，靠 26 处手动 `annotationTick` 驱动重绘，是下一批拆分对象。`ShotDetailPane` 里的 `maskSensitiveRegions` 是业务逻辑，待下沉到存储层。

## Settings/ — 应用内设置（4 文件）

`AppSettings` 是所有配置的单一真相（UserDefaults 支撑），`ShortcutRecorder` 支持热键重绑，设置页的按键说明从 `AnnotationTool` 的快捷键表生成而不是手写。

设置**没有自己的窗口**：它是图库窗口的第三个模式（`GalleryWindowMode.Mode.settings`，与图库/编辑器并列），所以 `SettingsView` 的宽度由宿主决定。独立设置窗口曾经存在，与「单窗口多模式」的设计不一致，用起来也割裂——改个默认颜色要跳出去再跳回来。

## Shelf/ — 暂存架

截图后浮出的临时卡片，可直接拖进别的 App。拖拽用的临时文件由 `ShelfController` 统一清理。

## Actions/ — 出口契约

「结果怎么出去」：钉图、复制、保存、上传图床、OCR 取字、Bug 报告。

`CaptureAction` 协议要求 `async throws`（上传和 GIF 是长耗时可失败操作），并用 `suppressesAutoCopy` 表达「这个动作自己管剪贴板」、`isPrimaryAction` 表达「是否在截图工具条上直接露出」。

**加动作**：新文件 + 注册一行，工具条和协调器都不用动。

## Pipeline/ — 中间契约

「派生能力怎么挂上去」：截图落库后跑的异步处理，互相独立，失败不影响主流程。结果通过 `ShotAttributeWriter` 写进通用属性表，因此**加能力不需要改数据库 schema**。

`AttributeBackfill` 负责给老截图补跑新能力。

**加派生能力**：新处理器文件 + 两处注册（流水线 + 回填表）+ 一个属性 key。

## Annotation/ — 标注领域逻辑

截图浮层、钉图、编辑器三个宿主共用的同一套东西——这是「三处标注行为一致」的根本原因。

- `AnnotationToolDescriptor` — **工具契约**：一个工具是什么，全写在这里（造层、落笔方式、命中测试、控制点、缩放、最小尺寸、样式轴、快捷键、常驻与否、绘制）
- `Tools/` — **一个工具一个文件**，11 个内建工具各自独立；`BuiltinTools.all` 只留登记的那一行
- `AnnotationState` — 状态机 + 撤销栈（撤销记录里存马赛克贴片，保证撤销后像素完全还原）。它**不再认识任何一种具体工具**——按图层种类分派的 switch 已经归零
- `LayerSpace` — phantom type，用类型区分「画布点」和「图像像素」两套坐标，唯一的桥是 `projected(onto:scale:)`
- `EffectLayer` / `EffectSpecs` — 效果层契约（水印/美化/外壳/捕获信息），排除逻辑一律从 `kind.isEffect` 派生
- `ToolStyle` — 样式轴的定义与档位值
- `ResizeHandle` / `AnnotationRenderer` / `AnnotationTool`

**加一个标注工具**：在 `Tools/` 下新建一个文件写实现，`BuiltinTools.all` 加一行。剩下要碰的只有两个 enum 各一个 case（`AnnotationTool` 与持久化用的 `Layer.Kind`）。改造之前，这件事要同时改十个文件。

## Toolbar/ — 工具条注册制

工具条不是写死的按钮列表，而是控件注册表：每个控件声明自己的分组、次序、可见条件和视图，注册表按 scope（截图 / 钉图 / 编辑器）聚合，动作控件由 `CaptureActionRegistry` 自动展开。

**加按钮**：注册一行。

`ToolbarLayout` 只回答两件事：这一条有多宽（`blockSize`，只看内容）、每个控件落在哪（`slots`，绘制与命中共用同一份结果）。**尺寸不许依赖画布**——按可用宽度折行的老做法制造过一个反馈回路，见 `Pin/`。宿主只能改工具条的位置，改不了它的形状。

`ToolbarHostCapabilities` 承载 Live Text、AI 选区等不产生图层的临时模式，并统一保证互斥；`SelectionAIControl` 只是按能力显隐和发出切换意图。具体框选手势不得写进 Toolbar。

## Render/ — 绘制唯一真相

`LayerRenderer` 是全项目唯一的图层绘制实现。所有预览（浮层、钉图、编辑器画布）和导出都走它，调用方只允许设置 CTM——这解决了早期「编辑器手写近似绘制」导致的所见非所得。

公共入口只接受 `Layers<ImageSpace>`，坐标错误在编译期就被挡住。导出套用次序固定：裁剪 → 水印 → 捕获信息 → 外壳 → 美化背景。

> **现存债务**：单文件 1043 行。

## Storage/ — 持久化

SQLite + GRDB。核心设计是**非破坏性编辑**：原图永不修改，每次改动追加一条修订记录（图层 JSON），因此可以无限回溯。

- `Models` — `Layer` / `Shot` / `Revision` 等纯值类型
- `AppDatabase` — v1→v4 迁移链 + FTS5 虚表（trigram 分词，中文可子串搜索）
- `ShotStore` — 数据门面，写路径带 reload 节流合并
- `ShotAttribute` — 属性 key 常量表
- `StorageJanitor` / `ImageCodec` / `ShotStoreAttributeWriter`（连接 Pipeline 的桥）

> **现存债务**：`ShotStore` 801 行 13 种职责，且仍是主线程同步 IO。拆门面 + 移出主线程是 ARCHITECTURE 阶段 6 的剩余部分。

## Intelligence/ — 视觉与模型

Vision 与 CoreML 的封装，**纯计算，不认识数据库**——后台派生结果通过 Pipeline 的 writer 落库；交互式选区结果由调用方决定复制、显示或显式保存。

OCR、场景标签、内容分类、敏感信息检测、相似图特征指纹，以及 CLIP 三件套（模型下载管理 / 编码 / 分词），支撑自然语言语义搜索。

`SelectionAIProvider` 是第八个扩展点：只接收用户已裁好的局部像素，输出解释、翻译、LaTeX 或表格结构；`SelectionAIExecutor` 负责单飞、取消与迟到结果隔离，`SelectionAIResultDocument` 把结构化结果统一投影为预览与 Markdown/纯文本/LaTeX/CSV 导出项。网络 Provider 必须实现在 `Platform/`，不能让 Tool Palette 直接依赖模型厂商。

选区智能领域类型放在 `Intelligence/SelectionAI/` 子目录：任务、请求、结果、导出文档、错误、Provider、安全默认实现和执行器各自独立；`SelectionAIGeometry` 与 `SelectionAISession` 负责宿主无关的选区规则和交互状态。该目录不放 Tool Palette 按钮、宿主鼠标事件或结果面板；Capture 的首个薄适配位于 `Capture/Overlay/OverlayView+SelectionAI.swift`，结果卡片位于同宿主的 `OverlaySelectionAIResultPanel.swift`，Pin 与 UI 后续各自接入。

## Platform/ — 系统副作用唯一出口

凡是「与系统打交道」的操作都必须收敛到这里：剪贴板、导出存盘、弹窗、访达与系统设置跳转、窗口生命周期与 Dock 图标、浏览器地址获取、图床上传、Live Text 分析、开机自启、键码映射，以及 AI HTTP 鉴权与钥匙串凭据。`OpenAICompatibleSelectionAIProvider` 负责 Responses API；`SelectionAIKeychain` 是 API Key 的唯一持久化位置。

**纪律**：其他地方不许出现 `NSAlert()` / `NSOpenPanel()` / `runModal()`。这条规矩是因为早期出现过「三份存盘面板行为不一致」，而 2026-07 审计又发现批量导出偷偷内联了一份目录选择面板——收敛不是做完一次就结束，需要定期巡检。

收敛的另一份红利是 `PanelPlacement`：模态面板（存盘、选目录、无宿主的 `NSAlert`）该弹在哪块屏、归谁管，只需要在这一处说清楚。它解决两个叠在一起的毛病：

1. **跑错屏**。Index 是 accessory App，选区覆盖层在动作执行前就收掉了，面板打开时往往没有 key 窗口，AppKit 会退回菜单栏那块屏。存盘面板因此接收一个可选的锚点矩形（截图选区），没有锚点时按 key 窗口 → 指针 → 主屏兜底。注意摆放**必须**发生在 `runModal()` 之后（登记一个主队列 block），之前设置会被面板自己恢复的上次位置覆盖。
2. **把用户正在用的 App 挤进侧边条**。默认行为下面板算 Index 的主窗口，和图库同属一组 stage；台前调度开着时，在别的屏截图点保存会把 Index 整组 stage 拽到前台。`detachFromAppStage` 用 macOS 13 为此新增的 `.auxiliary` + `.canJoinAllApplications`（再加 `.moveToActiveSpace`）把面板摘出这一组。三对标志位互斥，所以先摘对立面再设。

截图路径还要多走一步。那里 Index 一个窗口都没有，想让面板拿到键盘焦点就得 `NSApp.activate(ignoringOtherApps:)`，而它的旧语义是「顺带把 App 的所有窗口都拉到前台」——图库那组 stage 正是这样被拽出来的。逐个实测过的结论：`NSApp.activate()`（新 API）、光立宿主窗口、宿主 + `runModal`，面板都拿不到 key；**只有 `.nonactivatingPanel` 宿主 + `beginSheetModal` 两者兼得**——面板是 key，且不需要那句 activate。所以 `ImageExporter` 有两条呈现路径（形状与 `AppAlert` 一致）：有窗口在眼前的场合走同步 `runModal`，截图流程走 `makeSheetHost` + sheet。sheet 天然跟着宿主那块屏走，落点因此不用再手动补救。

## Recording/ — 录屏

相对独立的子系统：`ScreenRecorder` 用 SCK 分段录制再无损拼接（支持暂停继续），`GIFExporter` 转 GIF，`MicrophonePermission` 处理麦克风授权。
