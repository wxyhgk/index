# Overlay

全屏浮层。每块屏一个 `OverlayWindow`，其 `contentView` 为 `OverlayView`；`OverlayRenderer` 纯函数绘制，`ChromeView` 只做矢量。

## 职责分层

| 文件 | 职责 | 持有状态 |
|---|---|---|
| `OverlayView.swift` | 事件翻译与装配：鼠标/触控 → `SelectionModel` / `AnnotationState`，`CALayer` 冻结画面 + `ChromeView` 矢量；组合子状态，不直接存光标/选字细节 | `model`/`annotation`/`mode`/`imageLayer`/`chrome` + 3 个子宿主 |
| `OverlayView+Keyboard.swift` + `OverlayInteractionState` | 键盘优先级与悬停状态：`Esc`/`↩`/`⌘C`/`⌘Z`/`C` 逐级处理，`hoveredControlID`（工具条高亮）与 `optionHeld`（紫框/蓝框）集中一处 | `hoveredControlID`、`optionHeld` |
| `OverlayView+LiveText.swift` + `LiveTextOverlayHost` / `LiveTextHitTestView` | 选字层生命周期：`wantsLiveTextOverlay = tool==nil && pointerEngaged` 时挂载 `ImageAnalysisOverlayView`，预跑 `LiveTextAnalyzer`（键=选区+马赛克） | `container`、`overlay`、`analysis` |
| `OverlayView+Magnifier.swift` + `OverlayMagnifierState` | 放大镜采样：`cursor`/`cursorSample`（`DisplaySnapshot.sample` 纯内存），仅 `idle/dragging/adjusting` 显示 | `cursor`、`cursorSample` |
| `OverlayRenderer.swift` | 纯渲染：`draw(model:annotation:slots:hoveredControlID:magnifier:…)` 无状态枚举，输入即输出，不持有可变状态 | 无 |
| `OverlayWindow.swift` + `ChromeView` | 窗口与透明矢量层：无边框 `.screenSaver` 窗，`ChromeView.render` 闭包绘制，`hitTest` 穿透回 `OverlayView` | 无 |

几何：`Selection/OverlayGeometry` 统一三坐标系（视图局部↔AppKit全局↔标注空间），绘制与事件同一换算。

事件顺序（`mouseDown`）：工具条 → ⌥整窗捕获 → 标注绘制/图层操作 → 选区调整/拖拽。`LiveTextHitTestView` 以 `passesToHost` 明确三级归属，不依赖系统层穿透的偶然行为。

规模：`OverlayView.swift` 已从 661→529 行，`+LiveText/+Magnifier/+Keyboard` 各自收敛。
