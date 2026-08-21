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
  - `OverlaySelectionAIHost`（`+SelectionAI`）— 裁剪图像素坐标的 `SelectionAISession` + Overlay 坐标薄适配；`OverlaySelectionAIInputBuilder` 先裁局部、再烤入可见标注；任务条、执行状态和内嵌结果面板继续独立拆分
- 窗口与矢量层：`OverlayWindow` 无边框 `.screenSaver`，`ChromeView` 透明 `render` 闭包、`hitTest` 穿透。

* 新增捕获方式：`Snapshot/` 加 `CaptureSource` 实现 + 注册一行，不动 `CaptureCoordinator`。
* 选区逻辑不碰 AppKit，`Selection/` 可单测。
* 新增覆盖层交互：优先在对应小组件/extension 加状态与处理，不回灌 `OverlayView.swift`。

## 中文输入（IME，2026-08-10）

标注文字（`T`）在截图覆盖层与钉图两处均支持输入法合成——拼音/候选窗口与系统输入法闭环，落盘前可见、提交后入库。

| 构件 | 职责 |
|---|---|
| `Annotation/AnnotationState.markedText` | 合成串预览（不入撤销栈）；`displayLayers` 在 `editingTextID` 行拼 `text+marked` 或 `text+"|"`，`endTextEditing()` 清空 |
| `Capture/Overlay/OverlayView+Keyboard`（`OverlayView` 的 `NSTextInputClient`）与 `Pin/PinImageView` + `Pin/PinKeyboard` | `setMarkedText → markedText` 预览、`insertText → markedText=nil + insertText` 落盘、`firstRect → IMECaretGeometry` 候选跟随，其余协议端（`selectedRange/markedRange/hasMarkedText`）补齐 |
| `Annotation/IMECaretGeometry` | 纯函数几何：`prefixWidth/fullText+prefixLength` 与 `lineHeight` 均与 `Layer.handleBounds` 同源（`semibold systemFont + CTLine typographicBounds`），`overlayViewRect`（无缩放+Y翻转）与 `pinViewRect`（等比缩放+Y翻转，`scale` 同步缩字符） |

## 样式轴与效果注册（2026-08-10）

截图工具条下行（`Toolbar/Layout` 的 `style` 行）与图库编辑器效果面板均由注册表驱动，**新增轴/效果只需加一行描述符**，不再跨文件手写多份列表。

| 契约 | 文件 | 改动点 | 驱动的界面 |
|---|---|---|---|
| `ToolStyleAxisDescriptor` | `Annotation/ToolStyle.swift`（`ToolStyleAxisDescriptor.all`） | `axis/steps/order/title/defaultIndex/codingKey/keyPath/toolbarDraw/editorIcon/applyToLayer/bakeToLayer` 九字段同处；`ToolStyle` 解/编码改遍历 `all`，缺键以 `defaultIndex` 兜底 | `Toolbar/BuiltinControls.ToolParamControl`（AppKit）与 `UI/EditorToolbar`（SwiftUI）同源 |
| `EffectDescriptor` / `EffectRegistry` | `Annotation/EffectLayer.swift` | `kind + id/symbolName/toolbarOrder/panelTitle + renderOrder + makeLayer(EffectContext) + previewDraw`；`displayOrdered` 按 `toolbarOrder`，`ordered` 按 `renderOrder` | 工具条 `EffectToggleControl` 与 `UI/EditorEffectsPanel` 分组卡片均按 `displayOrdered` 循环；开关 `AnnotationState.toggleEffect`、导出 `LayerRenderer.render` 按注册表编排 |
| `EffectContext` | `Annotation/EffectLayer.swift` | 聚合 `imagePixelWidth/Height/pixelScale/chromeScale/watermark*/backdrop*` 注入，描述符不再直读 `AppSettings.shared` | 同上 |

## 工具条双行与 DS 令牌（2026-08-10）

`Toolbar/` 见 `Sources/Index/Toolbar/README.md` 的几何契约；截图工具条形态更新如下：

* 尺寸 `blockSize = max(上行宽, 下行宽)`，有样式高 `76 (=34*2+8)` 无样式单行 `34`；`slots(origin:)` 主行在上、样式行在下，主行始终最靠近锚点，`interRowGap=8`；绘制与命中共用 `slots`。
* `ToolbarRenderer` 双胶囊底板与选中/悬停均走 `DS.toolbarBackground/Stroke/Separator/Selected/Hover`（`UI/DesignTokens.swift` AppKit 令牌区），无裸写 `NSColor`；`check.sh` 纪律四覆盖。

## PAL 边界

平台副作用（面板/弹窗/剪贴板/浏览器 URL 等）只许出现在 `Platform/`，见 `Sources/Index/Platform/README.md` 与 `Sources/Index/README.md` 的 CSS/API 分层表；`Platform/Platform.swift` 为 PAL 骨架。
