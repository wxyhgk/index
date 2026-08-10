# Capture

冻结截图链路。`CaptureCoordinator` 串 4 步：`CaptureSource → 选区 → 入库/Pipeline → 动作`。

```
Snapshot/   像素怎么来：CaptureSource 契约、ScreenFreezer 定格、DisplaySnapshot 载体、WindowCapturer 整窗
Selection/  框怎么算：SelectionModel 纯值状态机 + SelectionResult + OverlayGeometry
Overlay/    怎么盖屏上：见下方分层（OverlayView 事件翻译 / OverlayRenderer 纯渲染 / 子状态下沉）
Magnifier/  放大镜：MagnifierRenderer + PixelSample（无状态绘制，采样在 DisplaySnapshot.sample）
Metadata/   元数据：MetadataCollector + ScrollStitcher（滚动拼接，成熟后移 Pipeline）
```

## Overlay 分层（拆分后）

- `OverlayView` 仅做事件翻译与装配：`SelectionModel` 管选区、`AnnotationState` 管标注、`OverlayGeometry` 管坐标、`CALayer` 挂冻结位图（合成器负责，不重采样）。
- `OverlayRenderer` 纯函数、无可变状态：`enum` + `static draw(...)`，所有输入当帧传入（`hoveredControlID`、`magnifier` 亦然），只读不写回。
- 子状态下沉为小组件（由 `OverlayView` 组合持有）：
  - `OverlayInteractionState`（`+Keyboard`）— `hoveredControlID` / `optionHeld`
  - `OverlayMagnifierState`（`+Magnifier`）— `cursor` / `cursorSample` + `magnifierPayload` / `updateCursor`
  - `LiveTextOverlayHost` + `LiveTextHitTestView`（`+LiveText`）— `container`/`overlay`/`analysis` + 命中测试与预跑分析
- 窗口与矢量层：`OverlayWindow` 无边框 `.screenSaver`，`ChromeView` 透明 `render` 闭包、`hitTest` 穿透。

* 新增捕获方式：`Snapshot/` 加 `CaptureSource` 实现 + 注册一行，不动 `CaptureCoordinator`。
* 选区逻辑不碰 AppKit，`Selection/` 可单测。
* 新增覆盖层交互：优先在对应小组件/extension 加状态与处理，不回灌 `OverlayView.swift`。
