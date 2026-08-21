# Index 架构规范

这份文档定义**入口、出口和依赖方向**。目的只有一个：

> 新增功能应该是「加一个文件 + 注册一行」，而不是「改动已有的 5 个文件」。

判断一个改动是否符合规范，只需要问：**它有没有修改已经写好的分支逻辑？** 如果有，说明缺一个扩展点。

> 2026-07 全面对账更新：v0.0.5 首次审计定下的三个契约全部落地并经受了二十余批功能的检验；
> 本次新增第四、五个扩展点（工具条控件、效果层），销账了全部已修缺陷，重写了违例表。

---

## 1. 依赖方向

依赖只能向下。上层认识下层，下层永远不认识上层。

```
                      ┌──────────────┐
                      │     App      │  编排、生命周期、装配（Recording 协调同级）
                      └──────┬───────┘
        ┌──────────┬─────────┼──────────┬──────────┐
        ▼          ▼         ▼          ▼          ▼
   ┌────────┐ ┌────────┐ ┌────────┐ ┌──────────┐ ┌────────┐
   │Capture │ │  Pin   │ │   UI   │ │ Settings │ │ Shelf  │   界面与交互
   └───┬────┘ └───┬────┘ └───┬────┘ └────┬─────┘ └───┬────┘
       └──────────┴────┬─────┴───────────┴───────────┘
                       ▼
    ┌─────────────────────────────────────────────────┐
    │ Actions · Pipeline    （契约实现集合，见 §1 注）  │
    ├─────────────────────────────────────────────────┤
    │ Annotation · Toolbar · Render    共享领域逻辑     │
    └───────────────────────┬─────────────────────────┘
                            ▼
            ┌───────────────────────────────┐
            │  Storage 模型（纯值类型）        │
            └───────────────────────────────┘

   Storage / Intelligence / Platform 挂在侧面。
```

**注（记录现实，不是许可新增）**：

- `Actions` 的动作实现允许回调 `Pin`/`Platform` —— 动作的职责就是把结果送到某个出口（钉图窗口、剪贴板、磁盘），这是契约设计内的单向调用，不算违例。
- 图上「侧挂层只通过 App 注入」对 `ShotStore.shared` 从未成立：它被界面/编排层十余个文件直接引用。这是**已接受的现状**，收敛属于阶段 6 的门面拆分，而不是逐处修补的对象。

### 硬性禁止与现存违例

| 禁止 | 现存违例（2026-07 对账） |
|---|---|
| 领域层引用 App 配置 | `Annotation/AnnotationState` 读写 `AppSettings.shared`（init 取种子默认值 + `setStyleIndex` 落盘单工具样式）；效果层水印描述符读 `AppSettings`（开关语义，`CapturePostProcessor.isEnabled` 同款先例，可辩护但记录在案） |
| 各层散读 `AppSettings` | `Platform/ImageExporter`、`Capture/OverlayView` 等 4 处（轻，App 层 20+ 处已收敛为 `StyleStore` 注入，剩余随重构下沉） |
| ~~界面层绕过注册表~~ | **已清零**（2026-07）：pin 直调与 `UploadAction()` 直接实例化都已迁回 `CaptureActionRegistry`。全仓再无界面层绕过注册表的地方 |
| 平台副作用散落 | `NSCursor` 5 个文件各自 set；`NSWorkspace` 2 处（取图标 / 开系统设置）。低优先级，暂不收敛 |

**已修销账**（原违例表五行，全部修复）：剪贴板 → `Platform/Clipboard`（v0.0.9）；`OCRService`/`BrowserURLResolver` 直调 ShotStore → 流水线 + attribute writer（v0.0.7）；`CaptureActionPerformer` ↔ Pin 双向依赖 → 双方走 `CaptureActionRegistry`（v0.0.6）；GalleryView 内联存盘/目录面板与裸 `NSAlert` → `ImageExporter` / `SystemNavigator.chooseDirectory` / `Platform/AppAlert`（2026-07）。

---

## 2. 扩展点契约

系统现有**八个扩展点**。功能一律挂在其中之一上，不改中间的编排代码。

### 2.1 入口：`CaptureSource` —— 像素怎么进来

```swift
protocol CaptureSource {
    var id: String { get }
    var title: String { get }
    /// 供选区层使用的冻结画面，每块显示器一张。
    func makeSnapshots() async throws -> [DisplaySnapshot]
}
```

**规范**：新增捕获方式 = 新增一个 `CaptureSource` 实现并注册。不改 `CaptureCoordinator`。

已完成（`Capture/CaptureSource.swift` + 注册表），立即 / 延时两个实现。

> **废弃的设想：`CaptureCanvas` 通用画布。** 曾计划把 `makeSnapshots()` 的产物换成「不绑定显示器的通用画布」，理由是延时、单窗口、滚动拼接都会需要它。三个功能全部落地之后，没有一个用上（详见 §6 阶段 4 结论）。教训：为「假想需求」预留的抽象，等真需求落地时往往长得完全不一样。

### 2.2 中间：`CapturePostProcessor` —— 派生能力怎么挂上去

已落地（v0.0.7），真实签名以 `Pipeline/CapturePostProcessor.swift` 为准：

```swift
protocol CapturePostProcessor {
    var id: String { get }
    @MainActor var isEnabled: Bool { get }        // 通常读设置开关
    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async
}
protocol ShotAttributeWriter {
    func write(shotID: Int64, key: String, value: AttributeValue) async
}
```

`PostProcessInput` 刻意不复用 `CaptureContext` —— 流水线不该认识 UI 概念。

**实测成绩单**（git 可考）：Upload、取字、报告、分类、敏感检测、CLIP 每次都守约。
诚实记录实际改动面：一个派生能力 = 新处理器文件 + **两处注册**（`CapturePipeline` + `AttributeBackfill.jobs()` 回填表）+ `AttributeKey` 常量 + 设置开关 + 消费侧 UI。约束住的是 schema 与协调器零改动。

### 2.3 出口：`CaptureAction` —— 结果怎么出去

已落地（v0.0.6），真实签名以 `Actions/CaptureAction.swift` 为准：

```swift
protocol CaptureAction {
    var id: String { get }
    var title: String { get }
    var symbolName: String { get }
    var scopes: Set<ActionScope> { get }
    var suppressesAutoCopy: Bool { get }     // 动作自己管剪贴板时抑制全局自动复制
    var isPrimaryAction: Bool { get }        // 截图工具条上是否直接露出（默认实现 false）
    func perform(_ context: CaptureContext) async throws
}
```

`CaptureContext` 自 v0.0.6 至今**零膨胀**（base / layers / shot / region / host，唯一变化是 `[Layer]` → `Layers<ImageSpace>`）。契约演进（如加 `isPrimaryAction`）必须带默认实现，一次性完成，不许逐动作散弹。

### 2.4 工具条：`ToolbarControl` —— 按钮怎么上条

事实上的第四个扩展点（`Toolbar/ToolbarControl.swift`），控件数量已超过动作数量：
`group / order / isVisible / view(context:)`，`ToolbarRegistry.controls(for:)` 聚合注册控件与动作控件。counter / spotlight / 效果开关的接入都验证了「加控件 = 注册一行」。

**几何契约（2026-07 补）**：工具条是**独立的一块**，尺寸只由「此刻有哪些控件可见」决定，宿主只能决定它落在哪。`ToolbarLayout.blockSize` 不接受任何画布尺寸参数，宿主也不许自己排控件。钉图据此把工具条搬进了独立子窗口（`Pin/PinToolbarWindow.swift`）——此前它画在钉图窗口内部并按窗口宽度折行，形成「缩放窗口 → 工具条折行 → 条带变高 → 图片显示倍率变」的反馈回路。

**宿主能力（2026-08 收敛）**：Live Text 原先往 `ToolbarContext` 直接加入 `isLiveTextActive` / `toggleLiveText` 一对回调；在 AI 选区成为第二个临时画布模式时，已收敛为 `ToolbarHostCapabilities`。宿主现在按 `ToolbarHostMode` 登记生命周期回调，工具栏统一处理显隐、选中和模式互斥，不再为每项能力膨胀 Context。
（`MoreActionsControl` 的折叠策略原先写在注册表的 `.capture` 分支里，**已于 2026-07 收敛**：折叠对所有场景一视同仁，注册表不再认识具体场景。）

### 2.5 标注工具：`AnnotationToolDescriptor` —— 一个工具是什么（2026-07 新增，2026-08 扩成完整契约）

起初只管**样式**：从前所有工具共用一份全局 `colorIndex` / `widthIndex`，字号还是从线宽
派生的（`线宽 × 4 + 8`）；高亮透明度、马赛克颗粒、聚光灯压暗则是彻底硬编码。

2026-08 扩成完整契约。起因是一次面向多人协同的边界体检：「一个标注工具」这个概念
散在**十个文件**里 —— 造层与落笔方式、命中测试、缩放语义、最小尺寸在
`AnnotationState`（973 行），控制点在 `ResizeHandle`，快捷键在 `AnnotationTool` 的一张
手写表，常驻工具条与否在 `BuiltinControls` 的一个数组，样式轴在 `ToolStyle`，绘制在
`LayerRenderer`（1064 行）。每处都是一个 switch。git 历史里
`AnnotationState ↔ BuiltinControls` 共现 84%、`↔ LayerRenderer` 83% ——
加一个工具必然同时改这几个大文件，两个人并行必撞车。

```swift
protocol AnnotationToolDescriptor: Sendable {
    var tool: AnnotationTool { get }
    var axes: [ToolStyleAxis] { get }        // 声明顺序即工具条顺序；只有这里列出的轴才会出现
    var defaultStyle: ToolStyle { get }
    var input: ToolInput { get }             // 拖拽 / 点击落点
    var shortcut: (keyCode: UInt16, label: String)? { get }
    var isPinnedToBar: Bool { get }
    var resizeHandles: [ResizeHandle] { get }

    func makeLayer(_ context: ToolLayerContext) -> Layer
    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool
    func resize(_ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double) -> Layer
    func meetsMinimumSize(_ layer: Layer) -> Bool
}
```

默认实现覆盖「拖一个矩形、按外接框命中、八个控制点」这一类，绝大多数工具只需声明
`tool` / `axes` / `defaultStyle` 三样。契约**刻意不绑主线程**（`Sendable`）：描述符是
无状态值类型、方法都是纯函数，而渲染路径是 nonisolated 的，绑上去会逼着渲染一起搬。

**规范**：加一种工具 = 新写一个实现 + 在 `BuiltinTools.all` 里加一行。
**不许**回头改 `AnnotationState`、`ResizeHandle`、`BuiltinControls` 或任何快捷键表。

**绘制也在契约里**（2026-08 第二批）。`LayerRenderer` 从前是一个 `switch layer.kind`
加七个私有绘制函数，现在只剩编排、不认识任何一种具体图层：

```swift
func draw(_ layer: Layer, in ctx: CGContext)          // 逐层，默认什么都不画
var drawsMerged: Bool { get }                         // 多层合并成一次绘制
func drawMerged(_ layers: [Layer], in ctx: CGContext) // 聚光灯是唯一用例
```

`drawsMerged` 表达的是一个真实约束而不是特例开关：聚光灯的所有亮区必须合成**一张**
遮罩、并画在其余矢量层**之下**，否则标注自己也会被压暗。编排因此是
「先画声明了合并的，再逐层画」，两步都由注册表驱动。

实现按**一个工具一个文件**放在 `Annotation/Tools/` 下，`BuiltinTools.all` 只留登记。
这是为多人协同定的：两个人同时加工具时**只在那一行相遇**。

**仍留在管线里的两处**：马赛克（图像级滤镜，必须在矢量层之前作用到底图）和裁剪
（改画布，永远最后应用）。它们是管线阶段而非绘制，形状上更接近 `EffectDescriptor`；
两者的描述符不实现 `draw`，交互语义（样式轴、快捷键、命中）照常在契约里。
工具条**不许**自己判断该显示哪些样式控件，一律问 `annotation.styleAxes`
（`ColorControl` / `ToolParamControl` 的 `isVisible` 就是这么写的）——
马赛克/聚光灯/裁剪的渲染根本不读 `layer.color`，从前却照样给它们摆一排色块。
每个工具的样式各存一份并持久化（`AppSettings.toolStyles`，JSON）；
设置页那两个全局默认降级为**首次使用的种子**。

新增的单工具参数落到图层上时**必须用可选字段**（`Layer.blockScale` / `Layer.dim`）：
`Layer` 的 Codable 是合成的，而合成的解码器不会使用默认值 ——
加一个非可选字段会让所有旧修订的 JSON 直接解不出来。渲染器遇到 nil 退回旧的硬编码值。

### 2.6 效果层：`EffectDescriptor` —— 整图效果怎么加（2026-07 新增）

水印 / 美化 / 外壳 / 捕获信息四个「单例语义、不参与命中、导出期套用」的效果层曾靠四段同构 API + 四份手维护黑名单镜像维持，并产生过一次真实漂移（`ResizeHandle` 漏排除 captureInfo）。现收敛为契约（`Annotation/EffectLayer.swift`）：

```swift
struct EffectDescriptor {
    let kind: Layer.Kind
    let renderOrder: Int                     // EffectRegistry.ordered 是导出套用次序的唯一定义
    let makeLayer: @MainActor (EffectContext) -> Layer
    let previewDraw: (…)?                    // nil = 不参与画布预览
}
```

**规范**：新增效果 = 一个描述符 + 注册一行 + `Layer.Kind` 一个 case（`isEffect` 返回 true）。
排除逻辑（命中测试、控制点、矢量绘制、图层面板列表）一律从 `kind.isEffect` 派生，**不许再写按 kind 枚举的黑名单**。元数据注入统一走 `EffectContext` 值对象，三宿主各一处赋值。Spec 序列化类型住在 `Annotation/EffectSpecs.swift`，与渲染分离。

### 2.7 顶层导航：`GalleryDestination` —— 图库窗口的一个「选项」（2026-08 新增）

```swift
protocol GalleryDestination {
    var id: String { get }          // 稳定标识；选中状态按它持久化，插新选项不会让位置漂移
    var title: String { get }
    var symbol: String { get }
    var order: Int { get }
    func badge() -> Int?            // 可选计数
    func content() -> AnyView       // 中间内容
    func inspector() -> AnyView?    // 右侧面板；nil = 不要右侧栏，宽度让给中间
}
```

**规范**：新增顶层功能（录屏、暂存、回收站…）= 一个实现 + 注册一行。容器、布局、选中态不动。

立这个扩展点的起因：侧边栏此前把四组筛选行硬编码在一个 500 行的视图里，加一组要改视图 + 加计数 + 加折叠状态 + 改布局，而且列表长度随库里的数据在 4 到 20 行之间浮动。**筛选行是数据的切片，选项是功能的入口**——把后者抽出来之后，导航的**呈现方式**（顶栏分段控件 / 左侧栏）成了容器的实现细节，换过一次只动了十几行，两个内建选项一个字没改。

### 2.8 选区智能：`SelectionAIProvider` —— 局部像素如何得到结构化结果（2026-08 新增）

```swift
protocol SelectionAIProvider: Sendable {
    var id: String { get }
    var isAvailable: Bool { get }
    var supportedTasks: Set<SelectionAITaskKind> { get }
    func perform(_ request: SelectionAIRequest) async throws -> SelectionAIResult
}
```

领域契约只接收用户明确框选后的 `CGImage`、任务和可选 OCR 文本，不接收整张截图、
`shotID` 或数据库对象。结果按解释、翻译、LaTeX、表格四种 case 返回，UI 不得从一段
混合文本反猜结果类型。实现按职责拆在 `Intelligence/SelectionAI/`：任务、请求、结果、
错误、Provider、安全默认实现和执行器各自独立；宿主无关的选区几何与交互会话也分别独立。
后续具体模型、Tool Palette 控件和宿主鼠标事件不得回填成聚合文件。

Tool Palette 接入同样拆开：`SelectionAIControl` 只发出模式切换意图，
`ToolbarHostCapabilities` 只管理临时模式能力与互斥；具体 Overlay、Pin、Editor 的坐标转换和
鼠标事件仍留在各宿主薄适配中。Capture 首个适配位于 `OverlayView+SelectionAI.swift`：
会话矩形以裁剪图左上原点像素保存，Chrome 只绘制映回视图的虚线框；Pin 与 Editor 尚未接入。
宿主尚未提供 `.selectionAI` 时按钮不会出现。

Capture 的 Provider 输入必须走 `OverlaySelectionAIInputBuilder`：从冻结快照直接裁出独立局部
位图，再把相交的普通可见标注换算到局部坐标并合成。禁止先合成整张 4K 选区后再裁，也禁止
把马赛克遮挡前的原像素作为旁路字段交给 Provider。裁剪、水印、外壳、美化等不属于当前
局部画布的成品效果不得改变 AI 选区几何。

`SelectionAIExecutor` 对每个宿主执行严格单飞并传播 Task 取消；Provider 尚未真正结束时
不得因 UI 超时继续扇出新请求。真实 HTTP、鉴权和 Keychain 实现必须放在 `Platform/`，
本地模型实现可以留在 `Intelligence/`。未配置时使用不触网的
`UnavailableSelectionAIProvider`。

生产装配目前使用 `OpenAICompatibleSelectionAIProvider`：默认连接可配置的 HTTPS
Responses API，并以 `input_image` 发送已裁剪 PNG、用严格 JSON Schema 接收四类结构化结果。
Base URL 与模型名存入 `AppSettings`，API Key 只进入 macOS 钥匙串；请求固定
`store=false`，鉴权值不得写入 UserDefaults、日志或请求体。多屏覆盖层共享同一个执行器，
因此一次截图会话仍只有一个在途 AI 请求。

上传前必须经过 `SelectionAIRequestPolicy + SelectionAIImagePreprocessor`：只缩小、不放大，
按解释、翻译、公式、表格分别保留递增的像素预算；公式和表格继续使用 PNG，不能为了体积
静默改成会损伤细线与上下标的有损编码。Provider 还要按最终 PNG 字节预算有限降采样，
不得把 Retina 原尺寸大选区直接 Base64 后再依赖 HTTP 上限兜底。

Provider 的结构化结果先转换为 `SelectionAIResultDocument`，统一给出阅读预览与完整导出项。
解释导出 Markdown、翻译导出纯文本、公式导出 LaTeX、表格同时导出 Markdown/CSV；宿主不得
复制被 UI 截断的预览文本。Capture 用 `OverlaySelectionAIResultPanel` 在原覆盖层内呈现，不创建
新的 NSPanel，也不改变截图窗口层级。Pin 与 Editor 后续可以用自己的界面复用同一 document。

**规范**：接一种模型服务 = 新增一个 Provider 实现并在 App 装配；Tool Palette、结果
浮层和存储只认识领域契约，不得直接 import 某家模型 SDK 或拼接供应商请求。

---

## 3. 类型层面的约定（已全部落地，v0.0.8）

### 3.1 坐标系由类型保证

`Layers<CanvasSpace>` / `Layers<ImageSpace>` phantom type，唯一的桥是 `projected(onto:scale:)`，`LayerRenderer` 公共入口只收 `ImageSpace`。裸 `[Layer]` 仅存于三处合法边界：持久化编解码（`Storage/Models.swift`）、`LayerSpace.persisted` 逃生门、渲染器内部私有函数。
已知渗漏（可接受）：`EditorView.baselineLayers` 用持久化形态做未保存比对。

标度语义约定：`pixelScale` / `chromeScale` 一类属性表示「每**视觉点**的画布单位」—— 投影时不得再乘一次比例（历史上 frame 线宽双重缩放的教训）。

### 3.2 一种图层，一份绘制实现

`LayerRenderer` 是唯一真相：覆盖层预览（`AnnotationRenderer` 委托）、编辑器画布（`LayerCanvas` → `AnnotationRenderer`）、钉图、导出全部走它，调用方只设置 CTM。效果预览也经描述符 `previewDraw` 分发回同一份绘制代码。

### 3.3 一份快捷键表

工具键唯一真相是 `AnnotationTool.shortcuts`：覆盖层 / 钉图 / 编辑器（bareKey 派生）/ 设置页帮助文本全部消费这张表。
边界：非工具键（图库导航、Quick Look、空格抓手、钉图专属键）按面分治、各自持有；图库/编辑器的按键**让位判定**统一走 `GalleryKeyContext`（2026-07），禁止再写镜像 guard。设置页对非工具键的说明仍是手写文本，改键时人工同步。

---

## 4. 平台副作用的收敛（表内全部完成）

| 副作用 | 收敛点 | 状态 |
|---|---|---|
| 存盘/导出 | `Platform/ImageExporter`（文件名模板唯一实现） | ✅ v0.0.9 |
| 目录选择 | `Platform/SystemNavigator.chooseDirectory`（带默认目录参数） | ✅ 2026-07 |
| 剪贴板 | `Platform/Clipboard` | ✅ v0.0.9 |
| 激活策略 + 窗口生命周期 | `Platform/WindowRegistry`（显式 dock 图标引用计数；原设想的独立 `ActivationPolicyManager` 被它吸收，未单独成型） | ✅ v0.0.9 |
| 访达 / 系统设置 | `Platform/SystemNavigator` | ✅ v0.0.9 |
| 弹窗 | `Platform/AppAlert`（confirm / info / error，sheet 优先 modal 兜底） | ✅ 2026-07 |

尚未收敛（低优先级，记录在 §1 违例表）：`NSCursor`、`NSWorkspace` 零星散落。
纪律：SwiftUI 视图里不许出现 `NSAlert()` / `NSOpenPanel()` / `runModal()` 字样 —— 2026-07 审计曾抓到「三份存盘面板」模式在批量导出上复发，收敛不是一次性动作而是需要巡检的纪律。

---

## 5. 已确认缺陷（全部修复，存档备查）

1. 钉图修订按数量判重 → 已改内容比较（`PinWindowController.saveRevisionIfNeeded`）。
2. `windowWillClose` 激活策略无守卫 → `WindowRegistry` 引用计数接管（顺带修了覆盖层被计为正经窗口的第二个 bug）。
3. `appendRevision` 跨事务 read-then-write → 已收进单个 `dbQueue.write` 事务。
4. `BrowserURLResolver` 忙等 → terminationHandler + continuation。
5. `EditorWindowController` 死代码 → v0.0.6 删除；曾于编辑器独立窗口方案中复活，编辑器并回图库窗口后二次删除，现为零引用。
6. FTS5 加列陷阱 → 属性走独立 `attributeFts` 虚表；v4 迁移的重建策略有注释与**迁移测试**（2026-07 起）双重看守。

---

## 6. 落地顺序与现状

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 | 缺陷清场、删死代码 | ✅ v0.0.6 |
| 1 | 出口契约 `CaptureAction` | ✅ v0.0.6 |
| 2 | 中间契约 `CapturePostProcessor` | ✅ v0.0.7 |
| 3 | 平台副作用收敛 | ✅ v0.0.9（弹窗/目录面板补于 2026-07） |
| 4 | 入口契约 `CaptureSource`（`CaptureCanvas` 废弃） | ✅ |
| 5 | phantom type / 绘制合一 / 快捷键表 | ✅ v0.0.8 |
| 6 | 拆 `ShotStore`；DB 读写移出主线程 | **进行中**（见下） |

**阶段 6 现状（2026-07）**：止血已完成 —— 测试安全网（迁移链 / 清理豁免 / 引用计数删文件，项目首批测试）、写路径 reload 节流合并（leading+trailing 0.5s，回填/批删风暴坍缩为 ≤2Hz）、批量删除单事务。
**第二批（2026-08）已完成**：`DatabasePool` + WAL（读连接 4 条）—— `DatabaseQueue` 是串行的，一次写入把所有读堵住，而回滚日志每次写要 fsync 整库；WAL 下写只追加、读走写入前的快照，两者互不阻塞，这是「重查询挪出主线程」的地基。连接类型放宽成 `any DatabaseWriter`（生产 Pool / 测试内存 Queue）。
同批修掉两处审计点名的重灾区：`relatedShots` 不再把全库带网址的行整个取回（改为 SQL 前缀缩候选 + Swift 精确判定，前缀能成立是因为归一化只截短；有测试盯着「前缀多命中要被挡掉」），`attributePayloads` 新增后台读版本，相似图 / 语义搜索不再在主线程上拉几十 MB 的向量 blob。三处硬编码的 `LIMIT 500` 收敛成 `listFetchLimit`（暂定 2000）。

**第三批（2026-08）已完成**：列表查询搬出主线程。查询体抽成 `nonisolated static fetchShots`（同步与后台两条路**共用同一份 SQL**，有测试守着「两条路径结果一致」），新增 `reloadInBackground()`，**节流路径（截图落库、属性回填、批量操作）整条改走它** —— 那些场景没有「调完立刻读 `shots`」的需求，UI 是订阅式的。同步 `reload()` 保留给需要立即结果的调用方（测试、「打开窗口并定位到某张」）。赋值与通知收敛到 `publish(shots:favorites:)`，两条路不会有一条忘了发 `libraryDidChange`。

**第四批（2026-08）已完成**：分页。列表按 `pageSize`(300) 取，网格滚到「倒数一屏」时取下一页，`listFetchLimit` 那个临时上限随之取消 —— 第一屏的等待从此与库的大小无关。

翻页用**游标**（上一页末尾的 `(capturedAt, id)`）而不是 `OFFSET`：截图库是边看边新增的，OFFSET 在两页之间插入新行时会让下一页整体后移，表现为重复或漏项。为此排序补上 `id DESC` 作为并列打破键——`capturedAt` 会并列（同秒连拍），排序不唯一时游标定位不确定。测试覆盖「607 张翻完不重不漏（含 10 张同时刻并列）」与「库存观察刷新第一页并重置游标后，继续翻页仍不重不漏」。

「全选」改查 `allMatchingIDs()`（只取 id 一列，不受分页限制）——否则同一个 ⌘A 会因为用户滚了多远而选中不同的东西。翻页只发 `objectWillChange` 不发 `libraryDidChange`：库存没变，只是多显示了一段，发了会让胶片条无谓重查。

**第五批（2026-08）已完成**：附件实体化。v6 新增精简的 `shotAsset`，录屏 MP4 与分子 XYZ 不再伪装成无类型 `shotAttribute.payload`；Shot 继续作为统一时间线里的可标注封面，附件只记录 `kind / path / payload / schemaVersion` 与时间。迁移会搬走旧 `recording.path` / `source.molecule.xyz.v1`，历史 key 只保留在 v5→v6 迁移边界，业务层统一走类型化附件接口；带附件的 Shot 永久豁免自动清理。录屏写入改走 `ShotWriting.attachRecording`，不再按 `ShotStore` / `FakeShotStore` 类型强转或兜底污染全局单例。附件自身的 CRUD 与直接查询已收进非 MainActor 的 `ShotAssetRepository`；图库筛选、搜索、游标分页与自动清理候选已收进 `ShotQueryRepository`；专题收藏集 CRUD、多对多成员关系与首页摘要已收进 `ShotCollectionRepository`；派生属性、收藏标记、多值标签、FTS 同步读写与后台载荷读取已收进 `ShotAttributeRepository`；Shot 与初始修订的原子创建、append-only 修订链及标注聚合已收进 `ShotRevisionRepository`；Shot 本体查询、来源聚合、同源候选和删除引用计数事务已收进 `ShotMetadataRepository`。`ShotStore` 已不再直接执行 SQL，只协调领域值、文件副作用与发布状态；筛选条件提升为独立 `ShotFilter` 值类型，查询层不再反向依赖状态容器。

**第六批（2026-08）已完成**：图库查询状态拆分。`searchText / filter / semanticMode / semanticResults / isSemanticSearching` 已从 `ShotStore` 迁入 `GalleryViewModel`，顶栏、固定 destination、网格、Quick Look、键盘全选与 URL 自动化共享同一个会话状态。`ShotStore` 只保留当前列表的查询快照，用于库存观察和游标翻页；同步/后台查询均接收显式条件，后台旧请求迟到时按快照丢弃，不得覆盖新筛选。

**第七批（2026-08）已完成**：`ValueObservation` 接管库存刷新。`ShotQueryRepository` 在同一数据库快照中读取当前页与收藏集合，显式观察 Shot、属性、附件和收藏集表；写路径不再手工安排 leading/trailing reload。查询切换会取消旧观察并以 generation 拒收迟到回调，异步首帧在观察失败或被替换时也会恢复等待者。普通修订不触发库存观察，只有 `.annotated` 筛选纳入 revision region，保留编辑自动保存不刷新胶片条的性能边界。

**第八批（2026-08）已完成**：网格卡片元数据合并成 `ShotPageMetadataRepository` 的单个后台数据库快照，分类、标注、录屏附件和专题成员关系原子发布，并以 generation 拒收旧页结果。收藏集摘要从 1+N 预览查询改为固定两条窗口查询；图库窗口先显示，再后台建立库存观察。

**第九批（2026-08）已完成**：跨分页批量语义。`GallerySelection` 同时保存全量 ID 集合与稳定展示顺序；复制、导出按 ID 在后台分块解析，收藏和删除直接走单事务 ID 批量写入，不能再从当前已加载的 300 张反推全选结果。SQLite `IN` 查询统一按 500 个参数分块；专题集菜单对大选中集合只保存每个集合的命中计数，不构造逐图成员字典。

**第十批（2026-08）已完成**：批量成品管线。`ShotMetadataRepository` 在同一个后台数据库快照中按稳定顺序批量取得 Shot 与最新修订，复制/导出不再在主线程逐张查询修订；原图解码、图层渲染和 PNG 编码整体在后台运行。`GalleryBatchActivity` 为跨页复制与导出提供全局单飞 token、进度和协作取消，详情栏、右键菜单与快捷键不能重复启动多份像素重活；任务运行期间删除等会改变源文件的动作被禁用，迟到进度也不能污染下一次任务。

**第十一批（2026-08）已完成**：缩略图快速滚动背压。四路 ImageIO 解码限制与同 key 请求合并继续保留，但等待队列改为“FIFO 顺序 + UUID 字典 + tombstone”，取消从数组 O(n) 查删降为 O(1)；大量卡片离屏不会形成 O(n²) 取消风暴。失效 token 改成弱值表，生命周期跟随可见 View，不再按浏览历史永久增长。缩略图重画会递增 generation 并进入独立的 in-flight key，旧文件内容即使迟到完成也无法回填新缓存。

**第十二批（2026-08）已完成**：网格失效范围与分页元数据增量化。`GalleryGrid` 不再观察整个查询 ViewModel，而只订阅会改变卡片集合的语义模式/结果投影，搜索框逐字符输入和搜索 spinner 不再重建几百张卡片；`.task(id:)` 从全量 ID 数组改为常量大小的修订号、数量与首尾 ID。分页到来只查询新增后缀的卡片元数据并与前缀合并，完整库存变更仍强制重读；五份独立 `@State` 收敛为一次快照发布。元数据查询按 500 个 ID 分块但保持在同一数据库 read transaction 内，深度分页不会重复读取前 N 页或撞 SQLite 参数上限。

**Windows 迁移第一批（2026-08）已完成**：跨平台边界从“共享 Swift 源码”改为“共享便携数据契约”。`Contracts/` 冻结 v1 manifest 与图层 JSON Schema；`PortableLibraryExporter` 在一个 SQLite read snapshot 中读取 Shot、完整修订链、用户标签/收藏/分类、专题关系和附件，再经旁路目录组装、最后同卷移动为独立包。原图以 SHA-256 去重复制，外置附件丢失时保留类型身份但不泄露绝对路径；原图缺失、图层 JSON 损坏或目标已存在则整体失败。FTS、缩略图、CLIP/Vision 向量属于可重建平台缓存，不进入迁移包。v1 包内整数引用只服务单次导入，不承担双向同步身份；Windows 端不得与 macOS 共同打开运行中的 SQLite/WAL。

**拆巨文件（进行中）**：`GalleryView` 已于 2026-07 拆成 9 个文件（壳 171 行，最大的 `GalleryGrid` 548 行），拆分为纯搬家、逐行对账过。
剩余：`maskSensitiveRegions` 业务逻辑仍留在 `ShotDetailPane` 待下沉；`EditorView`（1194 行）切 Toolbar / Canvas / EffectsPanel / LayersPanel 四件，用 ObservableObject 包装消灭 26 处 `annotationTick` 手动失效。

**图库视觉规范（2026-07）**：图库采用**定制 chrome**——自绘顶栏（无系统工具栏，含顶层选项分段控件）+ 浮在窗口底色上的圆角面板 + 无底色卡片。顶层导航由 `GalleryDestination` 注册表驱动（§2.7），呈现方式（顶栏 tab / 侧边栏）可以换，契约不动。目标设计的逐块拆解见 `docs/gallery-chrome-spec.md`（**冲突时以它为准**）；`docs/spatial-ui-spec.md` 仍是原则与数值的来源（铁律、视差上限、同心圆角、动效令牌、性能红线），其中已被改版取代的条目在文件开头逐条列明。

token 与容器在 `UI/DesignTokens.swift`（`extension DS` + `DS.Shell`）、`UI/GalleryShell.swift`（`floatingPanel` / `ShellIconButtonStyle` / `PanelCloseButton`）、`UI/SpatialModifiers.swift`（视差等）。三条不可违反的铁律：**内容层不上材质**（卡片现在干脆没有底色）；**每窗口最多一个 `behindWindow` 材质**——面板一律用 `DS.panelFill` 纯色 + rim 描边，因为窗底本来不透明，材质只会采样自家底色；**深色的深度是亮度阶梯与发丝线，不是阴影**。

阶段 4 结论（存档）：`CaptureCanvas` 通用画布废弃，因为它设想的三个需求方最终没有一个用它 ——

- **滚动截图**（`App/ScrollCaptureController` + `Capture/ScrollStitcher`）完全绕开快照机制：框选借用覆盖层简单模式，之后 SCStream 连续采集、纯函数拼接、直接产出 CGImage 入库，不产生也不消费任何画布类型。
- **单窗口截图**（⌥+单击，`Capture/WindowCapturer`）是选区**之后**的事后重拍：确认后用 `SCContentFilter(desktopIndependentWindow:)` 重新捕获完整窗口，整窗像素从不进入选区层。
- **延时截图**产出的本来就是整屏冻结画面。

注册表（加捕获方式 = 加一个文件）是这一阶段真正兑现的价值；画布重构是过度设计。
