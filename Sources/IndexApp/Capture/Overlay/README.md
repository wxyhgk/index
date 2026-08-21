# Overlay

全屏浮层。每块屏一个 `OverlayWindow`，其 `contentView` 为 `OverlayView`；`OverlayRenderer` 纯函数绘制，`ChromeView` 只做矢量。

## 职责分层

| 文件 | 职责 | 持有状态 |
|---|---|---|
| `OverlayView.swift` | 事件翻译与装配：鼠标/触控 → `SelectionModel` / `AnnotationState`，`CALayer` 冻结画面 + `ChromeView` 矢量；组合子状态，不直接存光标/选字/AI 细节 | `model`/`annotation`/`mode`/`imageLayer`/`chrome` + 4 个子宿主 |
| `OverlayView+Keyboard.swift` + `OverlayInteractionState` | 键盘优先级与悬停状态：编辑后第一次 `Esc` 一次性退出整套编辑态、第二次取消截图；中性态一次退出。`↩`/`⌘C`/`⌘Z`/`C` 分层处理，`hoveredControlID`（工具条高亮）与 `optionHeld`（紫框/蓝框）集中一处 | `hoveredControlID`、`optionHeld` |
| `OverlayView+LiveText.swift` + `LiveTextOverlayHost` / `LiveTextHitTestView` | 选字层生命周期：`wantsLiveTextOverlay = tool==nil && pointerEngaged` 时挂载 `ImageAnalysisOverlayView`，预跑 `LiveTextAnalyzer`（键=选区+马赛克） | `container`、`overlay`、`analysis` |
| `OverlayView+SelectionAI.swift` + `OverlaySelectionAIHost` | AI 选区薄适配：AppKit 全局点 ↔ 裁剪图左上原点像素，复用 `SelectionAISession`；不执行 Provider | `session` |
| `OverlaySelectionAIInputBuilder.swift` | 先裁局部像素，再把马赛克/文字/箭头等可见标注烤入；不把整张确认截图或遮挡前像素交给 Provider | 无 |
| `OverlaySelectionAITaskPalette.swift` + `OverlaySelectionAIExecution.swift` | 四任务浮条的布局/绘制/命中，以及一次请求的 UI 状态；真实单飞由领域执行器保证 | `status` / 请求 Task |
| `OverlaySelectionAIResultPanel.swift` | 内嵌结果卡片的布局、绘制、按钮命中与导出选择；不创建额外窗口，完整复制内容不受预览截断影响 | 无 |
| `OverlayView+Magnifier.swift` + `OverlayMagnifierState` | 放大镜采样：`cursor`/`cursorSample`（`DisplaySnapshot.sample` 纯内存），仅 `idle/dragging/adjusting` 显示 | `cursor`、`cursorSample` |
| `OverlayRenderer.swift` | 纯渲染：`draw(model:annotation:slots:hoveredControlID:magnifier:…)` 无状态枚举，输入即输出，不持有可变状态 | 无 |
| `OverlayWindow.swift` + `ChromeView` | 窗口与透明矢量层：无边框 `.screenSaver` 窗，`ChromeView.render` 闭包绘制，`hitTest` 穿透回 `OverlayView` | 无 |

几何：`Selection/OverlayGeometry` 统一三坐标系（视图局部↔AppKit全局↔标注空间），绘制与事件同一换算。

事件顺序（`mouseDown`）：工具条 → AI 选区 → ⌥整窗捕获 → 标注绘制/图层操作 → 原截图选区调整/拖拽。`LiveTextHitTestView` 以 `passesToHost` 明确三级归属，不依赖系统层穿透的偶然行为。

AI 选区以裁剪图像素保存，支持多屏偏移与 Retina；Chrome 只接收映回视图的矩形绘制。框选完成后显示“解释 / 翻译 / 公式 / 表格”四项；输入先裁成局部独立位图，再烤入当前可见标注，避免小选区制造整张 4K 合成峰值，也避免马赛克泄露原像素。完成结果在覆盖层内显示：解释复制 Markdown、翻译复制纯文本、公式复制 LaTeX、表格可分别复制 Markdown/CSV；关闭结果后仍保留当前 AI 选区。Esc 顺序为“清当前 AI 选区 → 退出 AI 模式 → 取消截图”。生产 Provider 由 `SelectionAIAssembly` 注入；未在“设置 → AI”保存钥匙串凭据时明确提示，不会触网。
