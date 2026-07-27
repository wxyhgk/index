# MacShot 架构规范

这份文档定义**入口、出口和依赖方向**。目的只有一个：

> 新增功能应该是「加一个文件 + 注册一行」，而不是「改动已有的 5 个文件」。

判断一个改动是否符合规范，只需要问：**它有没有修改已经写好的分支逻辑？** 如果有，说明缺一个扩展点。

---

## 1. 依赖方向

依赖只能向下。上层认识下层，下层永远不认识上层。

```
                      ┌──────────────┐
                      │     App      │  编排、生命周期、装配
                      └──────┬───────┘
        ┌────────────┬───────┴────────┬─────────────┐
        ▼            ▼                ▼             ▼
   ┌────────┐  ┌──────────┐    ┌──────────┐  ┌──────────┐
   │Capture │  │   Pin    │    │    UI    │  │ Settings │   界面与交互
   └───┬────┘  └────┬─────┘    └────┬─────┘  └────┬─────┘
       └────────────┴───────┬───────┴─────────────┘
                            ▼
            ┌───────────────────────────────┐
            │  Annotation · Toolbar · Render │  共享领域逻辑
            └───────────────┬───────────────┘
                            ▼
            ┌───────────────────────────────┐
            │      Core（模型 · 几何）        │  纯值类型，不 import AppKit
            └───────────────────────────────┘

        Storage / Intelligence / Platform 挂在侧面，
        只通过 App 层注入，不被界面层直接引用。
```

### 硬性禁止

| 禁止 | 现存违例 |
|---|---|
| 下层引用上层 | `Storage/ImageCodec.copyToPasteboard` 写 `NSPasteboard`（剪贴板是 UI 副作用） |
| 领域层引用 App 配置 | `Annotation/AnnotationState.init` 读 `AppSettings.shared` |
| 采集/智能层引用存储 | `Intelligence/OCRService` 和 `Capture/BrowserURLResolver` 直接调 `ShotStore.shared` |
| 同层互相引用 | `App/CaptureActionPerformer` ↔ `Pin/PinWindowController` 双向依赖 |
| 界面层直接建窗口/跑模态 | `UI/GalleryView` 里 `PinWindowController.pin` 和 `NSSavePanel().runModal()` |

---

## 2. 三个契约

整个系统只需要三个扩展点。**功能一律挂在这三个之一上，不改中间的编排代码。**

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

现状：协议 + `CaptureSourceRegistry` 已落地（`Capture/CaptureSource.swift`），协调器按 id 取源、注册表可注入。这一契约**已完成**。

> **废弃的设想：`CaptureCanvas` 通用画布。** 这份文档曾计划把 `makeSnapshots()` 的产物换成「不绑定显示器的通用画布」，理由是延时、单窗口、滚动拼接都会需要它。三个功能全部落地之后，没有一个用上：延时截图产出的仍是整屏冻结画面；滚动截图完全绕开了快照机制（见阶段 4 注）；单窗口截图（⌥+单击）发生在**选区之后** —— 覆盖层照常用整屏冻结画面做悬停与兜底，确认后由 `WindowCapturer` 用 SCK 重拍不被遮挡的完整窗口。它的本质是「事后重拍」，一块预先冻结的画布根本表达不了它。选区层的画布事实上就是「一块显示器」，`DisplaySnapshot` 绑定 `DisplayInfo` 不是类型缺陷而是如实建模。结论：注册表已经兑现了「加捕获方式 = 加一个文件」，画布重构没有需求方，废弃。

### 2.2 中间：`CapturePostProcessor` —— 功能怎么挂上去

```swift
/// 一次捕获落库之后运行的派生处理。互相独立，可并发，失败不影响主流程。
protocol CapturePostProcessor: Sendable {
    var id: String { get }
    var isEnabled: @MainActor () -> Bool { get }
    func process(_ context: CaptureContext, writer: ShotAttributeWriter) async
}

/// 通用属性回填通道。取代「一个派生属性 = 一个数据库列 + 一个 updateXXX 方法」。
protocol ShotAttributeWriter: Sendable {
    func write(shotID: ShotID, key: String, value: AttributeValue) async
}
```

**规范**：新增派生能力（OCR、CLIP 向量、自动打标签、水印、上传、通知）= 新增一个 `CapturePostProcessor` 并注册。不改 `CaptureCoordinator.handle`，不改数据库 schema。

现状差距：`handle()` 是一条 57 行的硬编码直线，OCR 和浏览器地址各自手写了一份「detached → 算 → MainActor.run → ShotStore.shared.updateXXX」—— **同一段代码的两份拷贝**，这是抽象缺失的实证，不是假想需求。

### 2.3 出口：`CaptureAction` —— 结果怎么出去

```swift
/// 用户在工具条上选择的动作。
protocol CaptureAction {
    var id: String { get }
    var title: String { get }
    var symbolName: String { get }
    /// 在哪些场景出现：截图选区确认后 / 钉图窗口上
    var scopes: Set<ActionScope> { get }
    /// 这个动作是否会自己处理剪贴板（决定要不要叠加全局自动复制）
    var handlesClipboard: Bool { get }

    func perform(_ context: CaptureContext) async throws
}
```

**规范**：新增动作（上传图床、生成 GIF、OCR 后复制文字、发到 Slack）= 新增一个 `CaptureAction` 并注册。不改工具条、不改协调器、不改钉图窗口。

现状差距：`ToolbarAction` 是封闭枚举，串起 **4 个 switch**（`CaptureActionPerformer.perform`、`PinWindowController.perform`、`CaptureCoordinator.shouldAutoCopy`、以及两个静态数组）。加一个动作至少改 8 处。更糟的是 `shouldAutoCopy` 的 `default:` 分支会让新动作**默认吃到自动复制** —— 「上传图床」会顺手覆盖剪贴板。

签名必须是 `async throws`：上传和 GIF 生成都是长耗时可失败操作，当前的 `@MainActor` 同步 `-> Void` 根本表达不了。

---

## 3. 类型层面的约定

### 3.1 坐标系必须由类型保证，不能靠注释

系统里同时存在四套坐标系：

| 空间 | 原点 | 单位 | 使用者 |
|---|---|---|---|
| AppKit 全局 | 主屏左下 | 点 | 选区、窗口 frame |
| CoreGraphics 全局 | 主屏左上 | 点 | `CGWindowListCopyWindowInfo` |
| 画布空间 | 画布左上 | 点或像素 | 标注图层 |
| 图像像素 | 图像左上 | 像素 | 渲染与导出 |

**现状是整个代码库最脆的地方**：同一个 `[Layer]` 类型承载三种互不兼容的语义（显示器点 / 图片像素 / 已换算的裁剪图像素），转换只发生在 `OverlayView.emit()` 一个点。忘调用或调用两次，编译器一声不吭，用户看到标注错位。

**规范**：用 phantom type 区分。

```swift
struct Layers<Space: CoordinateSpace> { … }
enum CanvasSpace: CoordinateSpace {}   // 画布点
enum ImageSpace: CoordinateSpace {}    // 图像像素

// 唯一的桥
extension Layers where Space == CanvasSpace {
    func projected(onto selection: CGRect, scale: CGFloat) -> Layers<ImageSpace>
}
// 渲染器只接受 ImageSpace
```

收益：把一整类静默 bug 变成编译错误。

### 3.2 一种图层，一份绘制实现

现在有**三套**：`LayerRenderer.drawVectors`（导出）、`AnnotationRenderer`（覆盖层预览，已复用前者）、`EditorView.drawPreview`（SwiftUI 手写近似）。第三套是「所见非所得」投诉的直接来源。

**规范**：`LayerRenderer` 是唯一真相。任何预览都必须走它，只允许调用方设置 CTM。

### 3.3 一份快捷键表

现在覆盖层和钉图窗口各有一份 `toolShortcuts`，而且**已经漂移**（钉图那份缺方向键）。设置页里的按键说明是第三份手写文本，和实际映射无代码关联。

**规范**：`AnnotationTool` 持有唯一的快捷键定义，设置页的帮助文本从这份表生成。

---

## 4. 平台副作用的收敛

「与系统交互」是副作用，必须收敛，否则会出现同一件事三种行为。

| 副作用 | 现状 | 规范 |
|---|---|---|
| 存盘面板 | 3 份独立实现，行为已不一致（只有一份带默认目录和 `NSApp.activate`） | 单一 `ImageExporter` |
| 剪贴板 | 实现在 `Storage/ImageCodec`（层级倒置），5 个调用点 | 移到 `Platform/Clipboard` |
| 激活策略 | 3 份重复，其中 `GalleryWindowController` 无守卫（真 bug） | `ActivationPolicyManager` 引用计数 |
| 窗口生命周期 | 4 套机制：单例 / `static var living` ×2 / 实例数组 | 统一 `WindowRegistry` |
| 访达 / 系统设置 | 4 处散落 | `Platform/SystemNavigator` |

---

## 5. 已确认的缺陷

审计中发现的、与架构无关但真实存在的问题：

1. **钉图修订按图层数量判重** —— 撤销一层再画一层，改动被静默丢弃。应比较内容（`Layer` 已是 `Equatable`）。
2. **`GalleryWindowController.windowWillClose` 无守卫** —— 设置窗口开着时关图库，App 掉回 `.accessory`，菜单栏消失。
3. **`appendRevision` 是跨事务的 read-then-write** —— 父指针可能重复，产生非预期分叉；而下游全部假设修订链是线性的。
4. **`BrowserURLResolver` 忙等** —— `while process.isRunning { usleep(50_000) }` 最长阻塞一条协作线程池线程 3 秒。
5. **`EditorWindowController` 是死代码** —— 零调用点。
6. **FTS5 虚表在加列后不会自动跟进** —— `synchronize(withTable:)` 生成的触发器绑定建表时的列集合，新字段要可搜必须重建虚表。

---

## 6. 落地顺序

每一阶段独立可交付、可回滚，不要求一次做完。

| 阶段 | 内容 | 解锁什么 |
|---|---|---|
| **0** | 修复第 5 节的确认缺陷；删死代码 | 无风险清场 |
| **1** | 出口契约：`CaptureAction` 协议 + 注册表 | 加动作 = 加一个文件 |
| **2** | 中间契约：`CapturePostProcessor` + `ShotAttributeWriter` + `shotAttribute` 表 | 加派生能力 = 加一个文件，不动 schema |
| **3** | 平台副作用收敛：`ImageExporter` / `Clipboard` / `WindowRegistry` / `ActivationPolicyManager` | 消除三份存盘面板与激活策略 bug |
| **4** ✅ 完成 | 入口契约：`CaptureSource` + 注册表（`CaptureCanvas` 设想废弃） | 延时、单窗口、滚动截图 |
| **5** | 坐标系 phantom type；三套绘制合一；单一快捷键表 | 消除静默错位与所见非所得 |
| **6** | 拆 `ShotStore`；DB 读写移出主线程 | 存储可测、可替换 |

阶段 1 和 2 优先：它们直接消除已经存在的重复，而不是为假想需求做准备。

阶段 4 结论（完成）：`CaptureSource` 协议、`CaptureSourceRegistry` 与两个实现（立即 / 延时）已落地，`CaptureCoordinator.begin(sourceID:)` 从注册表取源、注册表可注入。当初属于这一阶段的另一半 —— `CaptureCanvas` 通用画布 —— **废弃**，因为它设想的三个需求方最终没有一个用它：

- **滚动截图**（`App/ScrollCaptureController` + `Capture/ScrollStitcher`）完全绕开了覆盖层的快照机制：框选只借用覆盖层的简单模式（`finishOnConfirm`，松手即返回选区），之后用 SCStream 连续采集屏幕区域（画面静止时 SCK 不发帧）、纯函数拼接、直接产出 CGImage 走 `ShotStore.save` 入库，不产生也不消费任何画布类型。
- **单窗口截图**（⌥+单击，`Capture/WindowCapturer`）是选区**之后**的事后重拍：覆盖层照常用 `[DisplaySnapshot]` 做悬停高亮和失败兜底，确认后用 `SCContentFilter(desktopIndependentWindow:)` 重新捕获不被遮挡的完整窗口。整窗像素从不进入选区层，「不绑定显示器的画布」对它无从谈起。
- **延时截图**产出的本来就是整屏冻结画面。

教训被如实记下：为「假想需求」预留的抽象，等真需求落地时往往长得完全不一样。注册表（加捕获方式 = 加一个文件）是这一阶段真正兑现的价值；画布重构是过度设计。
