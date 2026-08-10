# Toolbar

工具条注册制与几何契约。控件「长什么样、什么时候可见、点一下做什么」由注册表声明；`ToolbarLayout` 只回答「这一条有多大、每个控件落在哪」——绘制与命中共用同一份 `slots`。

## 控件注册

| 文件 | 职责 |
|---|---|
| `ToolbarControl.swift` | `ToolbarControl` 协议（`id / group / order / scopes / isVisible / isSelected / draw / activate`）与 `ToolbarContext / ToolbarGroup / ToolbarSlot` 值类型 |
| `BuiltinControls.swift` | 唯一登记处：`ToolControl`（标注工具）、`EffectToggleControl`（效果开关，`EffectRegistry` 驱动）、`HistoryControls`、`ActionControls` 等；样式轴侧 `ToolParamControl` 按 `ToolStyleAxisDescriptor` 的 `toolbarDraw` 生成 |
| `ToolbarRegistry.swift` | `controls(for: scope)` 聚合注册表控件与 `CaptureActionRegistry` 展开的动作控件，按 `group+order` 排序；`MoreActionsControl` 折叠策略对所有 scope 一致 |
| `ToolbarStyle.swift` | 行高 `rowHeight`、锚点间距 `anchorGap`、分隔线宽度 `separatorWidth` 等定值 |
| `ToolbarLayout.swift` | 几何契约（见下） |
| `ToolbarRenderer.swift` | 底板与高亮绘制：两行各自 `DS.toolbarBackground/Stroke` 圆角底板，`DS.toolbarSelected/Hover` 选中/悬停，`DS.toolbarSeparator` 分隔线 |

新增控件：实现 `ToolbarControl` 并在 `BuiltinControls` 的注册表加一行（动作型走 `CaptureAction`，其余走 `ToolbarControl`）。

## 几何契约（PixPin 双行，2026-08-10）

`ToolbarLayout` 为纯函数、枚举单例，无可变状态；**尺寸恒定**——只由「此刻哪些控件可见」决定，不接受画布/窗口尺寸参数（此前钉图按可用宽度折行形成「缩放→条带变高→倍率变」的反馈回路，已拆除）。

| 概念 | 规则 |
|---|---|
| 行切分 | `group == .style` 进**下行**（样式行：颜色/粗细/字号 …，仅当当前工具声明了对应 `styleAxes` 时出现），其余（`tools/history/actions`）进**上行** |
| 尺寸 | `blockSize(_:)` = `max(上行宽, 下行宽)` × 高；有样式时高 `rowHeight*2 + interRowGap(=8)`，无样式退化单行 `rowHeight` |
| 排列 | `slots(origin:context:)`：有样式时主行在 `origin.y + rowHeight + interRowGap`、样式行在 `origin.y`；主行始终最靠近锚点（贴选区下方时主行在上，翻到上方时主行在下） |
| 落位 | `slots(in:bounds,anchor:context:)`：贴锚点下方居中，放不下翻到上方，再放不下压在锚点内侧——只换位置，尺寸与内容不变 |
| 命中 | `slots` 既是绘制依据也是命中依据，`hitTest` 不另算；`rowFrames(of:)` 供 `ToolbarRenderer` 画双胶囊底板 |

约束：宿主（Overlay / PinToolbarWindow）只能决定工具条**落在哪**，不能决定它**长什么样**。

## CSS 边界

`ToolbarRenderer` 不裸写 `NSColor`，一律 `DS.toolbarBackground / toolbarStroke / toolbarSeparator / toolbarSelected / toolbarHover`（`UI/DesignTokens.swift` 的 AppKit 令牌区）。
