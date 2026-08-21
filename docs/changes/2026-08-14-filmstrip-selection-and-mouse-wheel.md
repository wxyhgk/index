# Filmstrip 换图稳定性与鼠标滚轮横向浏览

*日期：2026-08-14；验证版本：0.1.9*

## 背景

图库编辑器底部有一条 Filmstrip（胶片条），用于在不退出编辑器的情况下浏览并切换图库图片。本次集中处理了两个连续出现的问题：

1. 点击 Filmstrip 中的另一张图片后，其余缩略图会消失或整条内容被重建；
2. 普通鼠标放在 Filmstrip 上滚动滚轮时，横向缩略图列表不会移动。

## 问题一：点击缩略图后其它图片消失

### 现象

在编辑器中点击 Filmstrip 的另一张图片后，当前编辑会话切换，但胶片条也随之被销毁并重新创建。重新加载期间可能只剩当前图片，或者视觉上像是其它图片全部消失；同时，列表还可能自动横移，使问题更明显。

### 根因

编辑器根视图以当前 `shotID` 作为会话身份。切换图片时，SwiftUI 会销毁旧的编辑器子树并创建新子树，而 Filmstrip 当时也位于这棵会话化子树中，因此它的 `@State shots`、滚动位置和缩略图加载状态会一起丢失。

此外，缩略图按钮的宽度原先由图片自身宽高比决定：超长截图会变成几乎无法点击的细条，超宽截图则可能占据大部分列表。这使换图后的布局跳动更明显。

### 修复过程

1. 新增稳定的 `EditorModeView` 宿主，把 Filmstrip 放到以 `shotID` 区分的画布会话之外；切换图片只替换画布会话，不再销毁胶片条。
2. 使用 `EditorSessionRelay` 保存当前会话的落库动作。点击另一张图时，先保存当前标注，再切换 `shotID`，避免为了稳定 UI 而牺牲数据一致性。
3. Filmstrip 使用只比较 `currentShotID` 的 `Equatable` 规则，画布中的连续标注变化不会反复重建缩略图列表。
4. 每个缩略图使用固定 `96 × 56 pt` 点击外框，图片只在外框内等比适配，不再让原图宽高比决定命中区域。
5. 只在 Filmstrip 首次得到图库数据时定位当前图片；用户点击视野内缩略图后，不再强制把它居中并推动整条列表。

相关实现：

- `Sources/Index/UI/EditorView.swift`
- `Sources/Index/UI/EditorModel.swift`
- `Sources/Index/UI/EditorFilmstrip.swift`
- `Tests/IndexTests/EditorFilmstripLayoutTests.swift`

## 问题二：普通鼠标无法横向滚动 Filmstrip

### 现象

Filmstrip 是 SwiftUI 的横向 `ScrollView`。触控板横向手势可以使用，但普通鼠标通常只产生纵向滚轮事件，SwiftUI 不会稳定地把该事件转换成横向位移。

### 约束

- 只在鼠标位于 Filmstrip 区域时转换，不能抢走画布或右侧检查器的滚轮事件；
- 触控板原生横向手势继续交给系统；
- 带 Shift、Command、Option 或 Control 的事件不改写；
- 到达列表两端后必须停止，不能产生越界或回弹坐标。

### 修复过程

1. 在 Filmstrip 的横向 `ScrollView` 背景中放置一个无视觉内容的 `NSViewRepresentable`。
2. 该桥接视图安装本地 `scrollWheel` 监听器，并同时校验窗口和命中坐标，确保事件确实发生在 Filmstrip 内。
3. 仅当纵向 delta 大于横向 delta 时执行转换；横向手势原样返回给 SwiftUI。
4. 找到 Filmstrip 对应且确实存在横向溢出的 `NSScrollView`，直接更新其 clip view 的横向 origin。
5. 普通鼠标的离散滚轮 delta 乘以 `18`，使每一格有可感知的移动距离；精确触控板 delta 保持系统原始速度。
6. 最终位置限制在 `0 ... documentWidth - viewportWidth`。
7. Filmstrip 被销毁时移除本地事件监听器，避免窗口关闭后残留监听和生命周期泄漏。

核心计算位于 `EditorFilmstripWheel`，AppKit 事件桥接位于 `EditorFilmstripWheelBridge`，均在：

- `Sources/Index/UI/EditorFilmstrip.swift`

## 验证中发现的独立竞态

第一次运行完整检查时，测试停在缩略图队列的阻塞解码器。原因是大量排队请求被取消后，取消操作先异步返回 actor；极少数请求可能在取消真正传到共享解码任务前获得刚释放的并发槽，并开始不可中断的解码。

修复方式是把共享请求的 waiter 集合放入带锁的 `InFlight` 对象。最后一个 waiter 取消时同步调用底层 `Task.cancel()`，随后再异步清理 actor 字典。这样排队任务即便同时获得槽位，也会在进入解码前看到取消状态。

相关实现：

- `Sources/Index/UI/ThumbnailImage.swift`
- `Tests/IndexTests/ThumbnailLoadingTests.swift`

## 自动化验证

Filmstrip 定向测试覆盖：

- 普通鼠标纵向滚轮转换为横向距离；
- 横向手势不转换；
- 零 delta 不处理；
- 左右边界正确截断；
- 极宽、极高图片都保持固定缩略图外框；
- 换图前保存当前编辑会话；
- 旧会话不能清除新会话的保存回调。

最终执行结果：

```text
git diff --check       通过
./scripts/check.sh     249 项测试，0 失败；8 项架构纪律全部通过
./build.sh release     使用 Index Dev 签名，旁路组装后原子替换并启动 Index
```

## 人工回归步骤

1. 打开图库并进入任意图片的编辑器；
2. 展开 Filmstrip，连续点击多张缩略图；
3. 确认其它缩略图不消失，当前图片高亮正确，上一张图片的标注已保存；
4. 将普通鼠标放在 Filmstrip 内，上下滚动滚轮；
5. 确认列表横向移动，移出 Filmstrip 后画布和右侧区域不受影响；
6. 使用触控板横向滑动，确认仍保持系统原生行为。

自动化测试无法证明真实鼠标事件在所有设备驱动下完全一致，因此第 4～6 步仍属于发布前人工桌面回归项。
