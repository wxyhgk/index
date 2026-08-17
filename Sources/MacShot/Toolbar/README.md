# Toolbar

工具条注册制与几何契约。控件「长什么样、什么时候可见、点一下做什么」由注册表声明；`ToolbarLayout` 只回答「这一条有多大、每个控件落在哪」——绘制与命中共用同一份 `slots`。

## 控件注册

| 文件 | 职责 |
|---|---|
| `ToolbarControl.swift` | `ToolbarControl` 协议（含显隐、禁用、可读标签与激活）及 `ToolbarContext / ToolbarGroup / ToolbarSlot`；`ToolbarFocusNavigator` 统一键盘焦点循环 |
| `ToolbarHostCapabilities.swift` | Live Text、AI 选区等不产生图层的临时宿主模式；按 mode 登记并保证互斥，不向 `ToolbarContext` 继续追加成对闭包 |
| `SelectionAIControl.swift` | AI 选区按钮本身；只有宿主提供 `.selectionAI` 能力时才出现，不认识鼠标事件、Provider 或结果面板 |
| `BuiltinControls.swift` | 唯一登记处：`ToolControl`（标注工具）、`EffectToggleControl`（效果开关，`EffectRegistry` 驱动）、`HistoryControls`、`ActionControls` 等；样式轴侧 `ToolParamControl` 按 `ToolStyleAxisDescriptor` 的 `toolbarDraw` 生成 |
| `ToolbarRegistry.swift` | `controls(for: scope)` 聚合注册表控件与 `CaptureActionRegistry` 展开的动作控件，按 `group+order` 排序；`MoreActionsControl` 折叠策略对所有 scope 一致 |
| `ToolbarStyle.swift` | 行高 `rowHeight`、锚点间距 `anchorGap`、分隔线宽度 `separatorWidth` 等定值 |
| `ToolbarLayout.swift` | 几何契约（见下） |
| `ToolbarRenderer.swift` | 底板与状态绘制：选中、悬停、按下、禁用以及键盘焦点环 |

新增控件：实现 `ToolbarControl` 并在 `BuiltinControls` 的注册表加一行（动作型走 `CaptureAction`，其余走 `ToolbarControl`）。

## 几何契约（PixPin 双行，2026-08-10）

`ToolbarLayout` 为纯函数、枚举单例，无可变状态。常规尺寸只由当前可见控件决定；宿主可传屏幕可用宽度，空间不足时先把出口动作从“图标+文字”收紧成图标，极窄屏再轻微压缩图标格与组间距，不折行、不改变高度，也不隐藏录屏、长截图等主动作。完整名称由 tooltip 与键盘焦点继续提供。

| 概念 | 规则 |
|---|---|
| 行切分 | `group == .style` 进**下行**（样式行：颜色/粗细/字号 …，仅当当前工具声明了对应 `styleAxes` 时出现），其余（`tools/history/actions`）进**上行** |
| 尺寸 | `blockSize(_:)` = `max(上行宽, 下行宽)` × 高；有样式时高 `rowHeight*2 + interRowGap(=8)`，无样式退化单行 `rowHeight` |
| 排列 | `slots(origin:context:)`：有样式时主行在 `origin.y + rowHeight + interRowGap`、样式行在 `origin.y`；主行始终最靠近锚点（贴选区下方时主行在上，翻到上方时主行在下） |
| 落位 | `slots(in:bounds,anchor:context:)`：贴锚点下方居中，放不下翻到上方；窄屏先收起动作文字，避免越过屏幕左右边缘 |
| 命中 | `slots` 既是绘制依据也是命中依据，`hitTest` 不另算；`rowFrames(of:)` 供 `ToolbarRenderer` 画双胶囊底板 |

约束：宿主（Overlay / PinToolbarWindow）只能决定工具条**落在哪**，不能决定它**长什么样**。

## 交互约定

- 鼠标按下只显示按压态，松开仍位于同一控件才激活；拖出取消。
- 临时画布模式由 `ToolbarHostCapabilities` 互斥切换；拿起任一标注工具会先退出当前临时模式。
- `Tab / Shift-Tab` 进入并循环工具栏焦点；已有焦点时左右键移动，`Space / Return` 激活，`Esc` 先退出工具栏焦点。
- 无历史时撤销/重做固定占位但禁用，避免后方动作跳位。
- 录屏、长截图、复制、保存、钉图保持平铺；窄屏只收起文字、保留图标。取字、问题报告、上传等低频出口收进“更多”。
- 钉图中的异步动作按动作 ID 去重；执行期间按钮禁用并显示沙漏，“更多”菜单中的对应项也禁用。失败统一通过宿主窗口上的错误提示反馈，不再只写日志。
- 由 XYZ 定格得到的图片钉图会额外显示分子来源图标；它是上下文控件，普通截图不占位，菜单只转发复制 XYZ、打开工作副本和重新进入 3D 三个宿主回调。

## CSS 边界

`ToolbarRenderer` 不裸写 `NSColor`，一律 `DS.toolbarBackground / toolbarStroke / toolbarSeparator / toolbarSelected / toolbarHover`（`UI/DesignTokens.swift` 的 AppKit 令牌区）。
