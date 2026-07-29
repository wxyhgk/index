# MacShot 架构规范

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
| 领域层引用 App 配置 | `Annotation/AnnotationState.init` 读 `AppSettings.shared`（取默认颜色）；效果层水印描述符读 `AppSettings`（开关语义，`CapturePostProcessor.isEnabled` 同款先例，可辩护但记录在案） |
| 各层散读 `AppSettings` | `Storage/StorageJanitor`、`Platform/ImageExporter`、`Capture/OverlayView` 等 5 处（轻，逐步随重构下沉为注入参数） |
| 界面层绕过注册表 | `UI/ShotDetailPane` 直接 `UploadAction().perform(…)`（轻；pin 直调已于 2026-07 迁回注册表） |
| 平台副作用散落 | `NSCursor` 5 个文件各自 set；`NSWorkspace` 2 处（取图标 / 开系统设置）。低优先级，暂不收敛 |

**已修销账**（原违例表五行，全部修复）：剪贴板 → `Platform/Clipboard`（v0.0.9）；`OCRService`/`BrowserURLResolver` 直调 ShotStore → 流水线 + attribute writer（v0.0.7）；`CaptureActionPerformer` ↔ Pin 双向依赖 → 双方走 `CaptureActionRegistry`（v0.0.6）；GalleryView 内联存盘/目录面板与裸 `NSAlert` → `ImageExporter` / `SystemNavigator.chooseDirectory` / `Platform/AppAlert`（2026-07）。

---

## 2. 扩展点契约

系统现有**五个扩展点**。功能一律挂在其中之一上，不改中间的编排代码。

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

**记录在案的膨胀风险**：Live Text 往 `ToolbarContext` 加了 `isLiveTextActive` / `toggleLiveText` 一对宿主回调 —— 「每个要宿主配合的控件加一对闭包」是注册制的经典逃生门。**第二个**同类控件出现之前，必须把它们收敛成一个 `hostCapabilities` 结构。`MoreActionsControl` 的折叠策略目前写在注册表的 `.capture` 分支里，同属待收敛项。

### 2.5 效果层：`EffectDescriptor` —— 整图效果怎么加（2026-07 新增）

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
剩余（按序独立交付）：`ShotDatabase` 非 MainActor 仓库类型承接全部 SQL、`DatabasePool` + WAL、async 读接口逐点迁移（顺手修 `relatedShots` 全表拉取与 `attributePayloads` 主线程拉 blob）、按职责拆门面、`ValueObservation` 替代手动通知。UI 状态（searchText / filter / semantic）届时迁出 ShotStore 成为 GalleryViewModel。

**拆巨文件（进行中）**：`GalleryView` 已于 2026-07 拆成 9 个文件（壳 171 行，最大的 `GalleryGrid` 548 行），拆分为纯搬家、逐行对账过。
剩余：`maskSensitiveRegions` 业务逻辑仍留在 `ShotDetailPane` 待下沉；`EditorView`（1194 行）切 Toolbar / Canvas / EffectsPanel / LayersPanel 四件，用 ObservableObject 包装消灭 26 处 `annotationTick` 手动失效。

**图库视觉规范（2026-07 新增）**：图库采用「空间 UI」设计语言，token 与修饰器在 `UI/DesignTokens.swift` 的 `extension DS` 与 `UI/SpatialModifiers.swift`。三条不可违反的铁律：**玻璃只给功能层**（侧边栏/详情栏/吸顶头/底栏/浮层），内容层（网格画布 + 卡片）一律不上材质；**每窗口最多一个 `behindWindow` 材质**，卡片的玻璃感用渐变描边冒充；**深色模式的深度是亮度阶梯不是阴影**。完整规格（含数值出处与性能红线）见 `docs/spatial-ui-spec.md`。

阶段 4 结论（存档）：`CaptureCanvas` 通用画布废弃，因为它设想的三个需求方最终没有一个用它 ——

- **滚动截图**（`App/ScrollCaptureController` + `Capture/ScrollStitcher`）完全绕开快照机制：框选借用覆盖层简单模式，之后 SCStream 连续采集、纯函数拼接、直接产出 CGImage 入库，不产生也不消费任何画布类型。
- **单窗口截图**（⌥+单击，`Capture/WindowCapturer`）是选区**之后**的事后重拍：确认后用 `SCContentFilter(desktopIndependentWindow:)` 重新捕获完整窗口，整窗像素从不进入选区层。
- **延时截图**产出的本来就是整屏冻结画面。

注册表（加捕获方式 = 加一个文件）是这一阶段真正兑现的价值；画布重构是过度设计。
