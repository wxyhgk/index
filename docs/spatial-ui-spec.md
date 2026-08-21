# Index 图库 — macOS Spatial UI 设计规格

> 目标：macOS 14 部署目标下，用 macOS 14/15 已有能力**神似**地做出 Apple 空间设计语言的深度感。
> 本文是实施规格，不是讨论稿。每条都有数值和理由。
> 全部 API 已在 `platforms: [.macOS(.v14)]` + `swiftLanguageMode(.v5)` 的 SPM 包里**编译验证过**（见 §10）。

> ## ⚠️ 2026-07 起：部分条目已被「定制 chrome 改版」取代
>
> 用户提供了一版新设计稿（全自绘顶栏 + 图标轨 + 浮动圆角面板 + 卡片无底色），
> 图库据此重做，落地拆解见 `docs/gallery-chrome-spec.md`。**冲突时以那份为准。**
>
> 本文**仍然有效**的部分：§0 五条铁律（内容层不上玻璃、每窗一个 behindWindow 材质、
> 深度靠光、选中用光不用填充、克制是规格本身）、§3 视差幅度上限、§5 同心圆角公式、
> §6 动效令牌、§7 颜色与对比、§9 性能红线、§12 来源。这些是原则与数值，没有过时。
>
> 本文**已被取代**的部分（照做会把改版推回去）：
> - §1 的 L1/L2「卡片」两行 —— 卡片现在**没有卡面**：无填充、无卡片描边、无卡片阴影，
>   图片直接浮在窗口底色上，只有缩略图自己保留一条 rim 发丝线（深色下暗截图不糊进底色的唯一依靠）。
> - §2 卡片四态表的「填充 / 阴影」两列 —— 同上；缩放与位移（1.02 / −3pt）、
>   选中框 2px、外扩 2、圆角同心换算仍然照用。选中的**光晕与色调已刻意取消**
>   （没有卡面时色调会直接染在缩略图上，光晕是纯为醒目付的一次离屏渲染）。
> - §2 末的选中角标位置 —— 已从左上改到**右上**（收藏星移到左上，四角各一件互不重叠）。
> - §4.1/§4.2 的容器规格 —— 已不用 `NavigationSplitView` / `.inspector`，
>   系统不再自动给材质；面板改为 `DS.panelFill` 纯色 + rim 描边的浮动卡片。
>   「侧边栏/详情栏不要手加材质」这条**结论不变**，但理由从"系统已给"变成
>   "每窗一个 behindWindow 材质的红线 + 窗底本来不透明，材质只会采样自家底色"。
> - §4.3 分隔线表、§10.1/§10.2 的接线示例、§11 的 `GalleryView.swift:行号` 表 —— 文件已拆分重构，行号全部失效。

---

## 0. 结论先行：本项目的五条铁律

| # | 铁律 | 依据 |
|---|---|---|
| 1 | **玻璃只给"功能层"（侧边栏 / 详情栏 / 吸顶头 / 底栏 / 浮层），内容层（网格画布 + 卡片）一律不上材质。** | Apple Liquid Glass 硬规则："绝不把玻璃放进内容层""绝不玻璃叠玻璃"。也是性能红线（§9）。 |
| 2 | **每个窗口最多一个 `behindWindow` 的 `NSVisualEffectView`。** 卡片级玻璃用「渐变填充 + 描边 + 一次 shadow」冒充。 | `behindWindow` 会让整窗失去 WindowServer 图层树扁平化优化；成本是**每窗口**的，不是每视图的。几百张卡各一个材质必炸。 |
| 3 | **深度 = 光，不是边框。** 浅色靠阴影，深色靠亮度阶梯 + 顶边高光。深色模式的阴影会饱和成一坨黑，读不出高度。 | Apple 全部深度线索（vibrancy / 镜面边 / 自适应阴影 / tvOS 视差照明）都是光学现象；边框是「增强对比度」无障碍模式下的**降级方案**，所以才不是默认表达。 |
| 4 | **选中用「发光环 + 色调」，绝不用实心填充。** 缩略图会把填充整片盖住，填充等于没画。 | 通用图库结论：图块选中必须是 ring + badge。WCAG 2.4.13：环 ≥2px、对比 ≥3:1、外扩 2pt。 |
| 5 | **克制是规格本身，不是偏好。** 视差幅度 ≤5pt / 倾斜 ≤1.5°、悬停缩放 1.02、位移 −3pt。 | Apple 原话："Parallax is designed to be almost unnoticeable."；tvOS 那套 1.1× / 16pt 位移是为**3 米观看距离**调的，桌面照搬会像玩具。 |

---

## 1. 层级模型（4 层，到顶）

Apple 明确要求**限制不同深度平面的数量**——"每一次深度差异都要求眼睛重新对焦，太频繁会疲劳"。所以是 4 层封顶，不是 z-index 阶梯。

### L0 画布层 `.canvas`

| 属性 | 浅色 | 深色 |
|---|---|---|
| 填充 | 侧边栏/详情栏：`NSVisualEffectView(.underWindowBackground, .behindWindow)`；网格画布：`Color(nsColor: .underPageBackgroundColor)` **不透明** | 同左 |
| 阴影 | 无 | 无 |
| 边框 | 无 | 无 |
| 圆角 | 0（贴窗） | 0 |

- **网格画布必须不透明**：几百张缩略图铺在桌面模糊上 = 视觉噪音，且白付一份 behind-window 采样成本。Apple 自己的 Photos 网格就是纯不透明的。
- 侧边栏由 `NavigationSplitView` **自动**套 `sidebar` 材质 + vibrancy，**不要再手动加**。这正是"材质叠材质"陷阱的入口。
- 详情栏由 `.inspector` 自动套材质，同理不要动。

### L1 内容层 `.content` —— 卡片常态

| 属性 | 浅色 | 深色 |
|---|---|---|
| 填充 | `white 1.00`（纯白，在 `#ECECEC` 的窗背景上自然浮起） | `white 0.045` 叠在画布上 |
| 阴影 | `black 0.07`, radius **3**, y **1** | **无**（深色阴影读不出，见铁律 3） |
| 边缘 | 渐变描边：`black 0.07` 顶 → `black 0.13` 底，1px，`.normal` | 渐变描边：`white 0.14` 顶 → `white 0.035` 底，1px，`.plusLighter` |
| 圆角 | 10（`DS.radiusCard`, `.continuous`） | 同左 |

**渐变描边方向的物理含义**：光从上方来。
- 浅色表面本身接近白，顶边"被照亮"看不出来 → 主导线索是**整体暗一档的发丝线，底边更暗**（底边处于自遮挡）。
- 深色表面上，顶边斜面接光是**唯一强线索** → 顶亮底暗，`.plusLighter` 叠加保证永不压暗背景。

### L2 浮起层 `.raised` —— 卡片悬停 / 吸顶分组头 / 底栏

| 属性 | 浅色 | 深色 |
|---|---|---|
| 填充（卡片） | `white 1.00` | `white 0.075` + 悬停叠 `white 0.05` 提亮 |
| 填充（chrome） | `.bar` 或 `VisualEffectBackground(.headerView, .withinWindow)` | 同左 |
| 阴影 | `black 0.13`, radius **12**, y **5** | `black 0.55`, radius **14**, y **6** |
| 边缘 | `black 0.13` → `black 0.20`（悬停 +0.05） | `white 0.28` → `white 0.05`（悬停 +0.08） |
| 圆角 | 10 | 10 |

深色 L2 才给阴影：卡片已经抬起来了，底下的环境遮挡这时**真的能读出来**；L1 静止态给阴影只是糊一层黑。

### L3 浮层 `.floating` —— Quick Look / sheet / 右键预览 / popover

| 属性 | 浅色 | 深色 |
|---|---|---|
| 填充 | `VisualEffectBackground(.popover / .hudWindow, .withinWindow)` | 同左 |
| 阴影（环境） | `black 0.18`, radius **24**, y **10** | `black 0.65`, radius **26**, y **12** |
| 阴影（直接光） | `black 0.10`, radius **2**, y **1** | `black 0.40`, radius **3**, y **1** |
| 边缘 | `black 0.09` → `black 0.17` | `white 0.24` → `white 0.06` |
| 圆角 | 14（`DS.radiusPanel`） | 14 |

**只有 L3 允许双层阴影**（Material Design 的"一层宽软环境光 + 一层短锐直接光"）。L1/L2 在网格里有几百份，双层阴影 = 双份离屏合成，禁止。

---

## 2. 卡片四态规格

坐标系：缩放锚点 center，Y 位移向上为负。

| 状态 | 缩放 | Y 位移 | 阴影（浅） | 阴影（深） | 描边 | 发光 | 动效 |
|---|---|---|---|---|---|---|---|
| **常态** | 1.00 | 0 | `black .07 / r3 / y1` | 无 | 顶 .07→底 .13 | 无 | — |
| **悬停** | **1.02** | **−3** | `black .13 / r12 / y5` | `black .55 / r14 / y6` | 顶 .12→底 .18；深色 顶 .28→底 .05 | 无（+深色 `white .05` 提亮罩） | `spring(0.22, 0.90)` |
| **选中** | 1.00 | 0 | `black .07 / r3 / y1` | 无 | 同常态 | 环 `accent @0.9` 2px 外扩 2pt + 光晕 `accent blur9 @0.22`；色调 `accent @0.09` `.multiply` | `spring(0.35, 0.85)` |
| **悬停+选中** | **1.02** | **−3** | `black .13 / r12 / y5` | `black .55 / r14 / y6` | 悬停描边 | 环 + 光晕 + 色调（**不加强**，保持选中态数值） | 两条动画各管各的 value |
| （按下） | 0.99 | 0 | 常态 | 常态 | — | — | `spring(0.22, 0.90)` |

深色选中：环 `accent @1.0`，光晕 `@0.38`，色调 `accent @0.14` 用 `.plusLighter`。

### 为什么这些数

- **1.02 / −3pt**：桌面卡片抬升的行业共识是 `translateY(-2..-5px) scale(1.02)`。tvOS 官方是 **1.1× + 25pt 阴影 + (0,16pt) 偏移**——那是 3 米观看距离标定的，桌面除以 3~4 才对。1.015（现状）偏保守，1.02 是甜点；1.05 在密集网格里会顶到邻居。
- **选中不缩放**：现状代码 `isHovering && !isSelected ? 1.015 : 1` 会让"选中后悬停"和"选中"跳变。改为缩放**只受悬停控制**，选中只加光——两个状态正交，可以同时读出。这是 Apple HIG 的硬要求：焦点和选中必须各自独立可见。
- **环外扩 2pt**：`outline-offset: 2px` 是无障碍界的默认建议——环和内容之间要有呼吸位，否则和缩略图边缘糊在一起。同心换算：环圆角 = 10 + 2 = **12**。
- **环 2px 而非 2.5px**：WCAG 2.4.13 的下限就是 2px；2.5px 在 1x 显示器上会渲染成模糊的 2.5 像素。2px 干净且达标。
- **光晕 blur 9 / 不透明度 0.22(浅) 0.38(深)**：Liquid Glass 逆向测得的镜面高光不透明度落在 **0.20–0.50** 区间——低于 0.2 消失，高于 0.5 变成一道生硬描边。取区间下沿因为这是常驻状态。

### 选中角标（可选但推荐）

图块选中的通用解是 **ring + checkmark badge**（Photos / Google Photos / Windows 一致）。多选场景下光环容易被密集网格淹没。建议在左上角加 `checkmark.circle.fill`，`accent` 填充 + `.ultraThinMaterial` 圆底，24pt——复用现有 `favoriteButton` 的尺寸约定。

---

## 3. 视差与空间感

### 3.1 卡内缩略图视差

**幅度上限（硬约束）**：

| 参数 | 值 | 理由 |
|---|---|---|
| 最大位移 | **±5pt** | tvOS 官方是 ±4pt（3 米距离）。桌面近距离可以略大，5pt 是"能感觉到、说不出来"的量。 |
| 最大倾斜 | **±1.5°** | 社区共识"密集网格 ~5°，超过 15° 会切到邻居"。图库网格间距只有 16pt，1.5° 已经是安全上限。Apple 原话：视差要"几乎不可察觉"。 |
| perspective | **0.3** | 越小透视越弱。0.3 让 1.5° 读起来像轻微抬头，不像 3D 卡片翻转。 |
| 过扫描 | `1 + 2×5/min(w,h)`，封顶 **1.12** | 位移会露出图片边缘的空白。过扫描量必须刚好补上 2×maxOffset；封顶防止小卡片被放大到糊。 |

**实现思路**：

1. **用 `.visualEffect`，不要 `GeometryReader`**。`.visualEffect`（macOS 14+）拿到 `GeometryProxy` 但**不触发布局失效**，这是它存在的全部意义。几百张卡片各套一个 `GeometryReader` 会把布局树打爆。
2. 指针位置来自 `.onContinuousHover(coordinateSpace: .local)`（macOS 13+）。归一化成 `[-1, 1]²` 的 unit vector，在 `.visualEffect` 里乘幅度。
3. **跟随动画必须零过冲**：`interactiveSpring(response: 0.16, dampingFraction: 1.0)`。指针跟随一旦有 bounce，读起来是"卡顿"不是"弹性"。
4. **未悬停的卡返回 identity**，闭包成本近似为零。
5. `pointer` 必须先落到局部常量再进 `.visualEffect` 闭包（闭包是 `@Sendable`，直接读 `@State` 在 Swift 6 严格并发下是编译错误）。

**必须尊重 Reduce Motion**：视差是有据可查的前庭触发源（眩晕/恶心）。`@Environment(\.accessibilityReduceMotion)` 为真时整个效果关掉，不是减半。

### 3.2 滚动深度

**首选：容器级滚动边缘（一份渐变，不是 N 个 transition）**

Apple 的 "scroll edge effect" 本质是内容在边界溶进背景，让上方的玻璃浮起来。用一个 `.mask` 线性渐变实现，成本 = 一个图层，与卡片数量无关：

```swift
ScrollView { ... }.scrollEdgeMask(topInset: 28)
```

顶部 28pt 的 `opacity 0 → 1` 渐变，正好覆盖吸顶分组头的高度（`.title3` + 2×`s2` padding ≈ 28pt），让卡片滑进标题时是"化开"而不是"被切"。**这一条应当替换掉网格与吸顶头之间任何 1px 实线。**

**次选（可选开关）：逐卡 `scrollTransition`**

```swift
.scrollTransition(.interactive, axis: .vertical) { view, phase in
    view.opacity(phase.isIdentity ? 1 : 0.72)
        .scaleEffect(phase.isIdentity ? 1 : 0.97)
        .offset(y: phase.value * 6)
}
```

- **只用 opacity / scale / offset，绝不用 blur**。`blur` 在 scrollTransition 里是逐帧离屏渲染，实测 SwiftUI `.blur` 动画能吃掉 50% CPU（同等效果走 CALayer 是 0%）。
- 数值克制：0.72 不透明度、0.97 缩放、6pt 位移。再大就变成"内容在打架"。
- **需要一个 `AppSettings` 开关**，默认开、几千张库时建议用户关。macOS 15 的 SwiftUI 滚动本身就有已知性能问题（trackpad 滚动时 `_hitTestForEvent` 吃掉 ~85% 执行时间），滚动预算已经被啃掉一块。

---

## 4. 容器规格

### 4.1 窗口

现状 `GalleryWindowController` 已经是 `.fullSizeContentView` + `toolbarStyle = .unified`。**保持，不要改成 `.hiddenTitleBar`**——搜索框已经通过 `sceneBridgingOptions = [.toolbars]` 桥进了窗口工具栏，藏掉标题栏会把它踢回内容区。

**唯一新增**：如果要让侧边栏真的透出桌面（推荐），需要

```swift
window.isOpaque = false
window.backgroundColor = .clear
```

然后**网格区自己铺一层不透明背景**把桌面挡住（见 L0）。不这么做的话整窗透明，缩略图后面透出壁纸 = 灾难。

> 注意：`.containerBackground(_:for: .window)` 是 **macOS 15**，本项目用不了。behind-window 模糊必须走 `NSViewRepresentable`。

### 4.2 三栏材质关系

| 区域 | 层 | 材质 | 谁负责 |
|---|---|---|---|
| 侧边栏 | L0 | `sidebar` 材质 + vibrancy | **SwiftUI 自动**（`NavigationSplitView`），不要手加 |
| 网格画布 | L0 | 不透明 `underPageBackgroundColor` | 手动，需 `.scrollContentBackground(.hidden)` 否则 ScrollView 自己的不透明底会盖住 |
| 卡片 | L1/L2 | **无材质**，纯填充 + 描边 | 手动 |
| 吸顶分组头 | L2 | `.bar`（现状即正确语义） | 保持 |
| 底栏 | L2 | `.bar`（现状即正确） | 保持 |
| 详情栏 | L0 | inspector 材质 | **SwiftUI 自动**，不要手加 |
| 详情栏内的信息卡 | L1 | `.quaternary.opacity(0.5)`（现状） | 保持——**详情栏已经在材质上了，里面绝不能再放材质** |
| Quick Look / sheet / 右键预览 | L3 | `.popover` / `.hudWindow` | 手动 |

### 4.3 分隔线：用材质边界代替 1px 实线

现状有 4 处 `Divider()`。逐一替换：

| 位置 | 现状 | 改为 |
|---|---|---|
| 网格 ↔ 底栏 | `Divider()` | 删掉。底栏的 `.bar` 材质本身就是边界；再叠一条 1px 渐变发丝：深色 `white 0.10`，浅色 `black 0.09`，`overlay(alignment: .top)` |
| 网格顶 ↔ 吸顶头 | 无 | 加 `scrollEdgeMask(topInset: 28)` |
| 侧边栏 ↔ 网格 | 系统画 | 不动（`NavigationSplitView` 自己管） |
| 详情栏内分组间 | `Divider()` | 保持——**信息密度区的分隔线是功能，不是装饰**，删了会读不出分组 |

发丝线的不透明度不对称是有意的：深色下 `white 0.10` 是"顶边接光"，浅色下 `black 0.09` 是"底边自遮挡"，方向和 §1 的描边渐变一致。

---

## 5. 同心圆角规则

**公式（Apple 官方）**：

```
内层圆角 = 外层圆角 − 内缩量        // inner = outer − padding
外扩圆角 = 内层圆角 + 外扩量        // outer = inner + offset
胶囊     = 高度 / 2
结果 < 2 时归零（视觉上等同直角）
```

**理由**：圆角同心时两条曲线共圆心，间隙在整圈上恒定。不同心时间隙在拐角处会被"掐细"或"喇叭口"，那种视觉张力就是廉价感的来源。

**本项目的圆角阶梯**：

| token | 值 | 用途 |
|---|---|---|
| `radiusChip` | **4**（新增） | 时间戳胶囊、极小角标 |
| `radiusSmall` | 6 | 按钮、分类胶囊、相似卡片 |
| `radiusCard` | 10 | 卡片、分组块 |
| `radiusPanel` | **14**（新增） | sheet、Quick Look、大浮层 |
| `radiusModal` | **18**（新增） | 全屏模态（暂无用例，占位） |

**落地换算实例**：

- 卡片外圆角 10，缩略图内缩 `s1`(4) → 内圆角 = 10 − 4 = **6** = `radiusSmall`。阶梯自洽，不需要新常量。
- 选中环外扩 `2` → 环圆角 = 10 + 2 = **12**。（现状是 `radiusCard + 3` 配 `padding(-4)`，两者不匹配——外扩 4 却只加 3，拐角是喇叭口。修掉。）
- 详情栏信息卡外圆角 10，内缩 `s3`(12) → 内层 = −2 → **归零**，内部元素用直角。这正是公式该给出的答案。

**全项目统一用 `style: .continuous`**。10pt 圆角处 `.continuous` 与 `.circular` 肉眼几乎不可分（可见阈值在 16–24pt），但它零成本、且 14/18 那两档确实需要。注意废弃的 `.cornerRadius(_:)` 只能给圆弧角，必须用 `.clipShape(RoundedRectangle(cornerRadius:style:.continuous))`。

---

## 6. 动效令牌

Apple WWDC23 的现代轴是 `duration + bounce`：bounce **0 = 默认**，**0.15 = 俏皮**，**0.3 = 物理感**，**>0.4 = UI 里绝不用**。项目沿用 `spring(response:dampingFraction:)` 轴（等价换算 `dampingFraction ≈ 1 − bounce`）：

| token | 参数 | 用于 | 理由 |
|---|---|---|---|
| `DS.Motion.micro` | `spring(response: 0.22, dampingFraction: 0.90)` | 悬停抬升、按下、角标出没、收藏星 | 微交互要跟手。0.22 是"立刻发生"的感知阈；0.90 阻尼 ≈ bounce 0.1，有一点点生命力但不弹。 |
| `DS.Motion.standard` | `spring(response: 0.35, dampingFraction: 0.85)` | 选中切换、布局模式切换（网格↔瀑布）、inspector 开合 | 系统默认是 `0.55 / 0.825`；0.35 更利落，适合高频操作。阻尼 0.85 ≈ bounce 0.15。 |
| `DS.Motion.ambient` | `spring(response: 0.50, dampingFraction: 1.0)` | 侧边栏展开、sheet 出现、大面积表面 | Liquid Glass 规则："大面积 = 更厚的材质 = 应该动得更慢"。阻尼 1.0 = 临界阻尼，零过冲——大面块过冲会晃眼。 |
| `DS.Motion.track` | `interactiveSpring(response: 0.16, dampingFraction: 1.0)` | 视差跟随指针 | 唯一的指针跟随档。零过冲是硬要求。 |

**Reduce Motion 降级**：Apple 要求的是"收紧弹簧减少弹性"，不是禁用动画。`micro`/`standard` 各提供 `(reduced:)` 重载，降级为 `.easeOut(0.12)` / `.easeOut(0.16)`；`track`（视差）整个关掉。

**绝对禁止**：动画 `.shadow()` 的参数（color/radius/y）。SwiftUI 会逐帧重新离屏渲染阴影。要"阴影变化"的观感，就靠 scale + offset 的位移把已有阴影"推开"，或在两个静态阴影之间做 opacity 交叉——**本规格的悬停态直接切换阴影值并由 `spring` 隐式插值，这是可接受的（radius 12↔3 的插值代价有限），但绝不能把 shadow 挂在连续手势上。**

---

## 7. 颜色与对比

### 7.1 强调色的三种用法（只用于选中/焦点，不用于装饰）

| 用途 | 浅色 | 深色 |
|---|---|---|
| 选中环 | `accentColor @0.90`, 2px | `accentColor @1.00`, 2px |
| 选中光晕 | `accentColor`, blur 9, `@0.22` | `accentColor`, blur 9, `@0.38` |
| 选中色调 | `accentColor @0.09`, `.multiply` | `accentColor @0.14`, `.plusLighter` |

**深色数值全线更高**：深色模式需要**更多**层级区分，不是更少——这是最反直觉也最实用的一条。深色背景上同样的不透明度看起来更弱。

**混合模式分流的理由**：浅色下 `.multiply` 让 accent 像一层染色玻璃压在白卡上（保留下方明暗）；深色下 `.plusLighter` 是加法，让 accent 像发光而不是脏污。`.multiply` 用在深色上会把卡片压黑。

**绝不给多个控件同时上强调色**——Liquid Glass 明确规定"最多一个控件加色"。图库里 accent 的唯一归属是选中态。分类色（`DS.categoryColor`）只出现在分类图标和胶囊上，不参与深度表达。（原先侧边栏是「色点 + 图标」双重编码，2026-07 收敛成给图标本身染色。）

### 7.2 材质上的文字对比

**只用语义层级色，不用字面颜色**：`.primary` / `.secondary` / `.tertiary` / `.quaternary`。系统会替你算 vibrancy。现状代码已经这么做了，保持。

**硬约束**：`.quaternary` 绝不放在 `.thin` / `.ultraThinMaterial` 上——对比度不够。现状 `dimensionBar` 用 `.ultraThinMaterial` + `.secondary`，合规。

**AppKit 陷阱**：盖在 `NSVisualEffectView` **上方**的内容不会自动 vibrant——只有加进它的**视图层级内部**才继承。`VisualEffectBackground` 走 `.background { }` 是"盖在上方"，所以 SwiftUI 的 `.secondary` 等语义色仍是主渠道，不要指望 AppKit vibrancy 免费到位。

**永远不要覆写 `allowsVibrancy`**。一旦开启，整个下游视图层级都无法关闭。

### 7.3 无障碍降级（必须实现，不是加分项）

| 环境值 | 行为 |
|---|---|
| `accessibilityReduceTransparency` | 所有 `VisualEffectBackground` → `Color(nsColor: .windowBackgroundColor)` 实色；卡片光晕关掉；描边 `.blendMode` 退回 `.normal` |
| `accessibilityReduceMotion` | 视差全关；`micro`/`standard` 降为 easeOut；`scrollDepth` 直接 passthrough |
| 增强对比度 | 描边升到全不透明 1px（系统对 `NSVisualEffectView` 自动处理；自绘描边需自己判断） |

---

## 8. 亮度阶梯速查（深色模式的骨架）

深色模式的深度**不是**阴影，是这张表。数值参考 Raycast / Linear 的做法：4–5 档，每档只差几个 RGB 点，靠发丝线撑边界。

| 层 | 深色叠加值 | 浅色填充 |
|---|---|---|
| L0 画布 | `white 0.000`（基底） | `underPageBackgroundColor` |
| L1 卡片 | `white 0.045` | `white 1.000` |
| L2 悬停 | `white 0.075` (+ `white 0.05` 提亮罩) | `white 1.000` |
| L3 浮层 | `white 0.100` | `white 1.000` |

浅色模式所有层都是纯白：在 `#ECECEC` 左右的窗背景上，纯白本身就是"高一层"，再叠亮度会溢出。浅色的层级差由**阴影**承担。

---

## 9. 性能红线

网格里同时可能有几百张卡片。以下是允许/禁止清单，实施时逐条对照。

### 禁止 ❌

| 做法 | 后果 |
|---|---|
| 每张卡一个 `NSVisualEffectView` | 每个实例 = 一个 layer-backed NSView + 私有 `CABackdropLayer`。AppKit 官方指导是单窗口约 100 个 NSView 就该警惕；几百个必卡。 |
| 卡片上用 `.ultraThinMaterial` / 任何 `Material` | 同上量级。而且材质叠在自动 sidebar/inspector 材质上会浑浊。 |
| `.blur()` 参与动画 | SwiftUI `.blur` 动画实测吃到 **50% CPU**（等价效果走 CALayer 是 0%）。 |
| `scrollTransition` 里用 `blur` | 逐帧离屏渲染 × 可见卡片数。 |
| 卡片外套 `drawingGroup()` | 会把材质**栅格化成静态位图**，实时模糊直接失效；且多加一次离屏渲染 pass。 |
| L1/L2 用双层阴影 | 双份离屏合成 × 几百。双层阴影只给 L3。 |
| 把 `.shadow` 参数挂在连续手势/滚动上 | 逐帧重算阴影。 |
| 每张卡套 `GeometryReader` | 触发布局失效，网格重排风暴（本项目已有瀑布布局振荡的前科）。 |
| 卡片 `body` 里做同步 I/O / 数据库查询 | 现状已规避（父级批量查好下发、`ThumbnailCache` 同步命中），**继续保持**。 |

### 允许 ✅

| 做法 | 说明 |
|---|---|
| **每窗口一个** `behindWindow` 的 `NSVisualEffectView` | 成本是每窗口的（失去图层树扁平化），不是每视图的。 |
| 卡片用「静态渐变填充 + `strokeBorder` 渐变描边 + 单层 `.shadow`」冒充玻璃 | 全是 GPU 上的便宜原语。**"边缘比表面重要"**——一条从亮到暗的渐变描边比任何背景不透明度调整都管用。 |
| `.visualEffect`（macOS 14+）做视差 | 拿得到几何信息且**不触发布局失效**，这是它的设计目的。 |
| `.compositingGroup()` | 官方描述"开销极小——只是重排效果的应用时机，不做栅格化"。混合模式（`.plusLighter` 等）**必须**有它做边界，否则会和任意兄弟视图混合。 |
| `.scrollTransition` 只用 opacity/scale/offset | 纯 transform，GPU 友好。 |
| 容器级 `.mask` 渐变做滚动边缘 | **一个图层，与卡片数无关**。优先于逐卡 transition。 |
| `strokeBorder` 而非 `stroke` | `stroke` 把线画在路径中心，一半在 clip 外被削掉，得到毛边的 0.5px。 |
| 缩略图 `CGImageSourceCreateThumbnailAtIndex` 降采样 | `kCGImageSourceThumbnailMaxPixelSize` **必填**（不填返回原尺寸）；配合 `ShouldCache: false` + `ShouldCacheImmediately: true`，Image IO 内存降到接近零。项目已有 `ThumbnailCache`，检查生成端是否走了这条路。 |

### 需要开关

- **逐卡 `scrollTransition`**：默认开，`AppSettings` 提供关闭。已知 macOS 15 SwiftUI 滚动本身有性能回归。
- **视差**：默认开，Reduce Motion 自动关。

### 分级阈值参考

| 库规模 | 建议 |
|---|---|
| 几百张 | `LazyVGrid` + 本规格全开，够用 |
| 几千张 | 关掉逐卡 `scrollTransition`，保留容器级边缘 |
| 几万张 | 需要换 `NSCollectionView`（cell 复用），本规格的卡片视觉可原样移植 |

现状按时间段分组 + 段级懒加载已经把单次实例化量级压住了，这个结构要保住。

---

## 10. 可落地的 Swift 骨架

以下代码在 `platforms: [.macOS(.v14)]` + `swiftLanguageMode(.v5)` 的 SPM 包里**编译通过、零警告**（含 Swift 6 严格并发检查）。

建议落到 `Sources/Index/UI/DesignTokens.swift`（扩展现有 `enum DS`）+ 新增 `Sources/Index/UI/SpatialModifiers.swift`。

```swift
import SwiftUI
import AppKit

// ============================================================
// MARK: - DS 扩展（空间层 token）
// ============================================================

extension DS {

    // MARK: 圆角新增档

    /// 极小件（时间戳胶囊、微角标）。
    static let radiusChip: CGFloat = 4
    /// 浮层 / sheet / Quick Look。
    static let radiusPanel: CGFloat = 14
    /// 全屏模态。
    static let radiusModal: CGFloat = 18

    /// 同心圆角：内层 = 外层 − 内缩量。低于 2 视觉上等于直角，直接归零。
    static func radiusInner(outer: CGFloat, inset: CGFloat) -> CGFloat {
        let r = outer - inset
        return r < 2 ? 0 : r
    }

    /// 外扩环（选中环画在卡片外侧 offset 处）：外层 = 内层 + 外扩量。
    static func radiusOuter(inner: CGFloat, offset: CGFloat) -> CGFloat {
        inner + offset
    }

    // MARK: 深度层
    //
    // 只有 4 档，且不打算再加。Apple 的理由是生理性的：
    // 每一次深度差异都要求眼睛重新对焦，太频繁会疲劳。

    enum Elevation: Int, Comparable, CaseIterable {
        /// 窗口画布：侧边栏 / 详情栏（系统材质）、网格底（不透明）。
        case canvas = 0
        /// 卡片常态、详情栏信息卡。
        case content = 1
        /// 卡片悬停、吸顶分组头、底栏。
        case raised = 2
        /// Quick Look / sheet / popover / 右键预览。
        case floating = 3

        static func < (a: Elevation, b: Elevation) -> Bool { a.rawValue < b.rawValue }

        var radius: CGFloat {
            switch self {
            case .canvas:   return 0
            case .content:  return DS.radiusCard
            case .raised:   return DS.radiusCard
            case .floating: return DS.radiusPanel
            }
        }
    }

    // MARK: 表面填充（亮度阶梯）
    //
    // 深色模式的「高度」是亮度，不是阴影 —— 深色下阴影会饱和成一坨黑。
    // 浅色模式所有层都是纯白：在 #ECECEC 的窗背景上纯白本身就高一层，
    // 层级差交给阴影。

    static func surfaceFill(_ e: Elevation, _ scheme: ColorScheme) -> Color {
        switch (e, scheme) {
        case (.canvas, _):        return .white.opacity(0.00)
        case (.content, .dark):   return .white.opacity(0.045)
        case (.content, _):       return .white.opacity(1.00)
        case (.raised, .dark):    return .white.opacity(0.075)
        case (.raised, _):        return .white.opacity(1.00)
        case (.floating, .dark):  return .white.opacity(0.10)
        case (.floating, _):      return .white.opacity(1.00)
        }
    }

    // MARK: 边缘高光（rim）
    //
    // 光从上方来。
    // 深色：顶边接光是唯一强线索 —— 顶亮底暗，.plusLighter 保证永不压暗背景。
    // 浅色：白表面顶边接光看不出来 —— 主导线索是整体暗一档的发丝线，底边更暗（自遮挡）。

    struct Rim {
        var top: Double
        var bottom: Double
        var isLight: Bool
        var lineWidth: CGFloat = 1

        var gradient: LinearGradient {
            let c: Color = isLight ? .white : .black
            return LinearGradient(
                colors: [c.opacity(top), c.opacity(bottom)],
                startPoint: .top, endPoint: .bottom
            )
        }
        var blend: BlendMode { isLight ? .plusLighter : .normal }
    }

    static func rim(_ e: Elevation, _ scheme: ColorScheme, hovering: Bool) -> Rim {
        if scheme == .dark {
            let boost = hovering ? 0.08 : 0.0
            switch e {
            case .canvas:   return Rim(top: 0, bottom: 0, isLight: true)
            case .content:  return Rim(top: 0.14 + boost, bottom: 0.035, isLight: true)
            case .raised:   return Rim(top: 0.20 + boost, bottom: 0.05,  isLight: true)
            case .floating: return Rim(top: 0.24,         bottom: 0.06,  isLight: true)
            }
        } else {
            let boost = hovering ? 0.05 : 0.0
            switch e {
            case .canvas:   return Rim(top: 0, bottom: 0, isLight: false)
            case .content:  return Rim(top: 0.07 + boost, bottom: 0.13 + boost, isLight: false)
            case .raised:   return Rim(top: 0.08 + boost, bottom: 0.15 + boost, isLight: false)
            case .floating: return Rim(top: 0.09,         bottom: 0.17,         isLight: false)
            }
        }
    }

    // MARK: 阴影
    //
    // 深色的 L1 故意没有阴影：静止卡片的黑阴影在黑底上只是糊一层脏。
    // L2 才给 —— 卡片已经抬起来了，环境遮挡这时真的能读出来。

    struct Shadow {
        var color: Color
        var radius: CGFloat
        var y: CGFloat
        static let none = Shadow(color: .clear, radius: 0, y: 0)
    }

    static func shadow(_ e: Elevation, _ scheme: ColorScheme) -> Shadow {
        if scheme == .dark {
            switch e {
            case .canvas, .content: return .none
            case .raised:           return Shadow(color: .black.opacity(0.55), radius: 14, y: 6)
            case .floating:         return Shadow(color: .black.opacity(0.65), radius: 26, y: 12)
            }
        } else {
            switch e {
            case .canvas:   return .none
            case .content:  return Shadow(color: .black.opacity(0.07), radius: 3,  y: 1)
            case .raised:   return Shadow(color: .black.opacity(0.13), radius: 12, y: 5)
            case .floating: return Shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            }
        }
    }

    /// 「直接光」硬阴影。**只有 L3 允许**叠这一层 ——
    /// 双层阴影 = 双份离屏合成，几百张卡片上是性能自杀。
    static func shadowKey(_ scheme: ColorScheme) -> Shadow {
        scheme == .dark
            ? Shadow(color: .black.opacity(0.40), radius: 3, y: 1)
            : Shadow(color: .black.opacity(0.10), radius: 2, y: 1)
    }

    // MARK: 发光（选中）
    //
    // 选中绝不用实心填充 —— 缩略图会把填充整片盖住。
    // 深色数值全线更高：深色模式需要「更多」层级区分，不是更少。

    enum Glow {
        static let ringWidth: CGFloat = 2      // WCAG 2.4.13 下限
        static let ringOffset: CGFloat = 2     // outline-offset，给环留呼吸位
        static let haloBlur: CGFloat = 9

        static func ringOpacity(_ s: ColorScheme) -> Double { s == .dark ? 1.00 : 0.90 }
        static func haloOpacity(_ s: ColorScheme) -> Double { s == .dark ? 0.38 : 0.22 }
        static func tint(_ s: ColorScheme) -> Double        { s == .dark ? 0.14 : 0.09 }
    }

    // MARK: 动效
    //
    // Apple 的现代轴是 duration + bounce（0 默认 / 0.15 俏皮 / 0.3 物理 / >0.4 禁用）。
    // 这里沿用 response + dampingFraction 轴，dampingFraction ≈ 1 − bounce。

    enum Motion {
        /// 悬停 / 按下 / 角标出没。0.22 是「立刻发生」的感知阈。
        static let micro = Animation.spring(response: 0.22, dampingFraction: 0.90)
        /// 选中、布局切换、面板开合。系统默认是 0.55/0.825，这里更利落。
        static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)
        /// 大面积表面。阻尼 1.0 = 临界阻尼，零过冲 —— 大面块过冲会晃眼。
        static let ambient = Animation.spring(response: 0.50, dampingFraction: 1.00)
        /// 指针跟随（视差）。零过冲是硬要求：跟随一旦有 bounce，读起来是「卡顿」。
        static let track = Animation.interactiveSpring(response: 0.16, dampingFraction: 1.00)

        // Reduce Motion 要求的是「收紧弹簧减少弹性」，不是禁用动画。
        static func micro(reduced: Bool) -> Animation {
            reduced ? .easeOut(duration: 0.12) : micro
        }
        static func standard(reduced: Bool) -> Animation {
            reduced ? .easeOut(duration: 0.16) : standard
        }
    }

    // MARK: 视差
    //
    // Apple 原话：视差要「几乎不可察觉」。tvOS 官方是 ±4pt / ±10°，
    // 但那是 3 米观看距离标定的。桌面密集网格里倾斜必须压到 1.5° 以内，
    // 否则会切到邻居卡片。

    enum Parallax {
        static let maxOffset: CGFloat = 5
        static let maxTilt: Double = 1.5
        static let perspective: CGFloat = 0.3
        static let maxOverscale: CGFloat = 1.12
    }

    // MARK: 卡片形变
    //
    // 1.02 / −3pt 是桌面共识。tvOS 的 1.1× / 16pt 位移是 3 米距离标定的，
    // 桌面照搬会像玩具。

    enum Lift {
        static let hoverScale: CGFloat = 1.02
        static let hoverY: CGFloat = -3
        static let pressScale: CGFloat = 0.99
    }
}

// ============================================================
// MARK: - AppKit 材质桥
// ============================================================

/// behind-window 模糊的唯一入口。
///
/// SwiftUI 的 `.ultraThinMaterial` 在 macOS 上**只模糊 App 自己的背景**，
/// 不模糊窗口后面的桌面（Apple 文档原话）。要真正的透窗玻璃只能桥 AppKit。
///
/// ⚠️ 每个窗口最多用一个 `.behindWindow` 实例 ——
/// 它会让整窗失去 WindowServer 的图层树扁平化优化，成本是每窗口的。
struct VisualEffectBackground: NSViewRepresentable {

    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    /// 默认 `.followsWindowActiveState`：窗口失焦时材质自动褪色。
    /// 这是正确的 macOS 原生行为，也是一条免费的深度线索。
    /// 强行设 `.active` 是大多数教程的做法，也是「不够 Mac」的来源。
    var state: NSVisualEffectView.State = .followsWindowActiveState
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.autoresizingMask = [.width, .height]
        // .withinWindow 混合模式要求 wantsLayer = true（AppKit 头文件明确要求）。
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = state
        v.isEmphasized = emphasized
    }
}

// ============================================================
// MARK: - 卡片状态
// ============================================================

/// 卡片四态。缩放**只受悬停控制**，选中只加光 ——
/// 两个状态正交，才能同时读出「这张被选中」和「鼠标在这张上」。
struct SpatialCardState: Equatable {
    var isHovering = false
    var isSelected = false
    var isPressed = false

    var elevation: DS.Elevation { isHovering ? .raised : .content }
}

// ============================================================
// MARK: - spatialCard
// ============================================================

struct SpatialCardModifier: ViewModifier {

    var state: SpatialCardState
    var radius: CGFloat = DS.radiusCard

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
    private var elevation: DS.Elevation { state.elevation }
    private var rim: DS.Rim { DS.rim(elevation, scheme, hovering: state.isHovering) }
    private var sh: DS.Shadow { DS.shadow(elevation, scheme) }

    func body(content: Content) -> some View {
        content
            .background(DS.surfaceFill(elevation, scheme), in: shape)
            .clipShape(shape)
            // 深色提亮：阴影在深色里读不出，用亮度当高度。
            .overlay {
                if scheme == .dark && state.isHovering {
                    shape.fill(.white.opacity(0.05)).allowsHitTesting(false)
                }
            }
            // 选中色调：染色玻璃，不是实心填充。
            // 浅色 .multiply（保留下方明暗），深色 .plusLighter（发光而非脏污）。
            .overlay {
                if state.isSelected {
                    shape.fill(Color.accentColor.opacity(DS.Glow.tint(scheme)))
                        .blendMode(scheme == .dark ? .plusLighter : .multiply)
                        .allowsHitTesting(false)
                }
            }
            // 边缘高光。必须 strokeBorder —— stroke 把线画在路径中心，
            // 一半在 clip 外被削掉，得到毛边的 0.5px。
            .overlay {
                shape.strokeBorder(rim.gradient, lineWidth: rim.lineWidth)
                    .blendMode(reduceTransparency ? .normal : rim.blend)
                    .allowsHitTesting(false)
            }
            // 混合模式必须有 compositingGroup 做边界，
            // 否则会和任意兄弟视图混合（包括你没打算碰的邻居卡片）。
            .compositingGroup()
            .shadow(color: sh.color, radius: sh.radius, x: 0, y: sh.y)
            // 选中环：外扩 2pt，同心圆角 = radius + 2。
            .overlay {
                if state.isSelected {
                    RoundedRectangle(
                        cornerRadius: DS.radiusOuter(inner: radius, offset: DS.Glow.ringOffset),
                        style: .continuous
                    )
                    .strokeBorder(
                        Color.accentColor.opacity(DS.Glow.ringOpacity(scheme)),
                        lineWidth: DS.Glow.ringWidth
                    )
                    .padding(-DS.Glow.ringOffset)
                    .allowsHitTesting(false)
                }
            }
            // 光晕：模糊的实心 accent 垫在环后面。
            // 只有选中的卡才付这份代价（通常 1 张），成本有界。
            .background {
                if state.isSelected && !reduceTransparency {
                    RoundedRectangle(
                        cornerRadius: DS.radiusOuter(inner: radius, offset: DS.Glow.ringOffset),
                        style: .continuous
                    )
                    .fill(Color.accentColor)
                    .blur(radius: DS.Glow.haloBlur)
                    .opacity(DS.Glow.haloOpacity(scheme))
                    .padding(-DS.Glow.ringOffset)
                    .allowsHitTesting(false)
                }
            }
            .scaleEffect(scaleValue)
            .offset(y: state.isHovering && !reduceMotion ? DS.Lift.hoverY : 0)
            .animation(DS.Motion.micro(reduced: reduceMotion), value: state.isHovering)
            .animation(DS.Motion.micro(reduced: reduceMotion), value: state.isPressed)
            .animation(DS.Motion.standard(reduced: reduceMotion), value: state.isSelected)
    }

    private var scaleValue: CGFloat {
        if state.isPressed { return DS.Lift.pressScale }
        return state.isHovering ? DS.Lift.hoverScale : 1
    }
}

// ============================================================
// MARK: - glassPanel
// ============================================================

/// 功能层玻璃。**只给 chrome（吸顶头 / 底栏 / 浮层），绝不给网格卡片。**
///
/// ⚠️ 侧边栏和 inspector 由 SwiftUI 自动套材质，不要再调用这个 ——
/// 那正是「材质叠材质」变浑浊的入口。
struct GlassPanelModifier: ViewModifier {

    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode
    var radius: CGFloat
    /// 材质边界的发丝线画在哪条边。nil = 不画。
    var edge: Edge?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    VisualEffectBackground(material: material, blending: blending)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(alignment: hairlineAlignment) {
                if let edge {
                    hairline
                        .frame(height: (edge == .top || edge == .bottom) ? 1 : nil)
                        .frame(width: (edge == .leading || edge == .trailing) ? 1 : nil)
                }
            }
    }

    private var hairlineAlignment: Alignment {
        switch edge {
        case .top:      return .top
        case .bottom:   return .bottom
        case .leading:  return .leading
        case .trailing: return .trailing
        case nil:       return .center
        }
    }

    /// 不对称是有意的：深色 white 0.10 是「顶边接光」，
    /// 浅色 black 0.09 是「底边自遮挡」，方向和 rim 渐变一致。
    private var hairline: some View {
        Rectangle().fill(
            scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09)
        )
    }
}

// ============================================================
// MARK: - parallaxThumbnail
// ============================================================

/// 缩略图随指针的轻微位移 + 倾斜。
///
/// 用 `.visualEffect`（macOS 14+）而不是 `GeometryReader`：
/// 前者拿得到几何信息且**不触发布局失效**，这是它存在的全部意义。
/// 几百张卡片各套一个 GeometryReader 会把布局树打爆
/// （本项目已有瀑布布局振荡的前科）。
struct ParallaxThumbnailModifier: ViewModifier {

    var isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer: CGPoint?

    func body(content: Content) -> some View {
        // pointer 先落到局部常量：visualEffect 的闭包是 @Sendable，
        // 直接在里面读 @State 在 Swift 6 严格并发下是编译错误。
        let p = pointer
        return content
            .visualEffect { view, proxy in
                let size = proxy.size
                let u = Self.unit(pointer: p, size: size)
                let over = Self.overscale(size: size, active: u != .zero)
                return view
                    .scaleEffect(over)
                    .offset(
                        x: u.width * DS.Parallax.maxOffset,
                        y: u.height * DS.Parallax.maxOffset
                    )
                    .rotation3DEffect(
                        .degrees(-u.height * DS.Parallax.maxTilt),
                        axis: (x: 1, y: 0, z: 0),
                        anchor: .center, anchorZ: 0,
                        perspective: DS.Parallax.perspective
                    )
                    .rotation3DEffect(
                        .degrees(u.width * DS.Parallax.maxTilt),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: .center, anchorZ: 0,
                        perspective: DS.Parallax.perspective
                    )
            }
            .animation(DS.Motion.track, value: pointer)
            .onContinuousHover(coordinateSpace: .local) { phase in
                // 视差是有据可查的前庭触发源，Reduce Motion 下整个关掉，不是减半。
                guard isEnabled, !reduceMotion else { pointer = nil; return }
                switch phase {
                case .active(let pt): pointer = pt
                case .ended:          pointer = nil
                }
            }
            // .onHover / .onContinuousHover 在 Mac 上有已知的「快速划过不回调 ended」缺陷，
            // 视图消失时兜底清一次。
            .onDisappear { pointer = nil }
    }

    nonisolated private static func unit(pointer: CGPoint?, size: CGSize) -> CGSize {
        guard let pointer, size.width > 1, size.height > 1 else { return .zero }
        return CGSize(
            width:  max(-1, min(1, (pointer.x / size.width  - 0.5) * 2)),
            height: max(-1, min(1, (pointer.y / size.height - 0.5) * 2))
        )
    }

    /// 位移会露出图片边缘的空白。过扫描量必须刚好补上 2×maxOffset；
    /// 封顶 1.12 防止小卡片被放大到糊。
    nonisolated private static func overscale(size: CGSize, active: Bool) -> CGFloat {
        guard active else { return 1 }
        let minSide = max(1, min(size.width, size.height))
        let need = 1 + (2 * DS.Parallax.maxOffset) / minSide
        return min(DS.Parallax.maxOverscale, need)
    }
}

// ============================================================
// MARK: - scrollDepth（逐卡，可关）
// ============================================================

/// ⚠️ 只用 opacity / scale / offset，**绝不用 blur** ——
/// blur 在 scrollTransition 里是逐帧离屏渲染 × 可见卡片数。
/// 建议由 AppSettings 提供开关：macOS 15 的 SwiftUI 滚动本身有已知性能回归。
struct ScrollDepthModifier: ViewModifier {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition(.interactive, axis: .vertical) { view, phase in
                view
                    .opacity(phase.isIdentity ? 1 : 0.72)
                    .scaleEffect(phase.isIdentity ? 1 : 0.97)
                    .offset(y: phase.value * 6)
            }
        }
    }
}

// ============================================================
// MARK: - 滚动边缘（容器级：一份渐变代替 N 个 scrollTransition）
// ============================================================

/// Apple 的 "scroll edge effect"：内容在边界溶进背景，让上方的玻璃浮起来。
/// **一个图层，成本与卡片数无关** —— 优先于逐卡 scrollTransition。
/// 这一条应当替换掉网格与吸顶头之间任何 1px 实线。
struct ScrollEdgeMask: ViewModifier {
    /// 默认 28pt = 吸顶分组头的高度（.title3 + 2×s2）。
    var topInset: CGFloat = 28

    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0), .black],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: topInset)
                Rectangle()
            }
        }
    }
}

// ============================================================
// MARK: - View 扩展
// ============================================================

extension View {

    func spatialCard(_ state: SpatialCardState, radius: CGFloat = DS.radiusCard) -> some View {
        modifier(SpatialCardModifier(state: state, radius: radius))
    }

    func glassPanel(
        _ material: NSVisualEffectView.Material = .underWindowBackground,
        blending: NSVisualEffectView.BlendingMode = .behindWindow,
        radius: CGFloat = 0,
        hairline edge: Edge? = nil
    ) -> some View {
        modifier(GlassPanelModifier(
            material: material, blending: blending, radius: radius, edge: edge
        ))
    }

    func parallaxThumbnail(isEnabled: Bool = true) -> some View {
        modifier(ParallaxThumbnailModifier(isEnabled: isEnabled))
    }

    func scrollDepth() -> some View { modifier(ScrollDepthModifier()) }

    func scrollEdgeMask(topInset: CGFloat = 28) -> some View {
        modifier(ScrollEdgeMask(topInset: topInset))
    }
}
```

### 10.1 接到现有 `ShotCard` 上

```swift
// 缩略图：内圆角 = 外 10 − 内缩 4 = 6，正好是 DS.radiusSmall。
CachedImage(url: thumbnailURL, key: shot.sha256)
    .parallaxThumbnail(isEnabled: isHovering)
    .clipShape(RoundedRectangle(
        cornerRadius: DS.radiusInner(outer: DS.radiusCard, inset: DS.s1),
        style: .continuous
    ))
    .padding(DS.s1)

// 整卡：四态一次给全，删掉现有的 strokeOpacity / shadowColor / scaleEffect / 两条 animation。
.spatialCard(SpatialCardState(isHovering: isHovering, isSelected: isSelected))
.scrollDepth()
```

### 10.2 接到容器上

```swift
// 网格画布：必须不透明，且要关掉 ScrollView 自带的不透明底
ScrollView { ... }
    .scrollContentBackground(.hidden)
    .background(Color(nsColor: .underPageBackgroundColor))
    .scrollEdgeMask()

// 底栏：删掉上方的 Divider()，改用材质边界 + 发丝线
bottomBar
    .glassPanel(.headerView, blending: .withinWindow, hairline: .top)

// 侧边栏 / 详情栏：什么都不做。SwiftUI 已经给了材质。
```

---

## 11. 现状代码需要修掉的具体问题

| 位置 | 问题 | 修法 |
|---|---|---|
| `GalleryView.swift:1185` | 选中环 `radiusCard + 3` 配 `padding(-DS.s1)`（=−4），外扩 4 却只加 3 圆角，拐角是喇叭口 | 改 `radiusOuter(inner:offset:)`，外扩和圆角都用 2 |
| `GalleryView.swift:1195` | `isHovering && !isSelected` —— 选中后悬停不缩放，状态跳变 | 缩放只看 `isHovering` |
| `GalleryView.swift:1186` | 环 `lineWidth: 2.5`，1x 屏上渲染成模糊的 2.5 像素 | 改 2（也是 WCAG 下限） |
| `GalleryView.swift:1196-97` | `.easeOut(0.12)` 两条 | 换 `DS.Motion.micro` / `.standard` |
| `GalleryView.swift:1158/1161/1166/…` | 全部 `RoundedRectangle(cornerRadius:)` 缺 `style: .continuous` | 全项目统一加 |
| `GalleryView.swift:561` | 网格与底栏之间的 `Divider()` | 删掉，改材质边界 + 发丝线 |
| `GalleryView.swift:1190-94` | 深色下 `shadowColor` 返回 `.clear` 但仍调用 `.shadow()` | 保留（本规格同样在深色 L1 给 `.none`），但改为走 `DS.shadow()` 统一出数 |
| `GalleryView.swift:2001` | 相似卡片 `cornerRadius: 8` 魔法数 | 用 `DS.radiusSmall`(6) 或 `radiusCard`(10) |
| `GalleryWindowController.swift:23` | 已有 `.fullSizeContentView` ✅ | 若要侧边栏透窗，补 `isOpaque = false` + `backgroundColor = .clear` |

---

## 12. 关键结论来源

**Apple 官方**
- [HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials) — 材质语义、vibrancy、"按语义选材质不按观感选"
- [HIG: Spatial layout](https://developer.apple.com/design/human-interface-guidelines/spatial-layout) — 限制深度平面数量、深度只给大元素、文字绝不加深度
- [HIG: Motion](https://developer.apple.com/design/human-interface-guidelines/motion) — 0.2Hz 振荡禁区、边缘运动、大物体运动需提高半透明度
- [HIG: Images](https://developer.apple.com/design/human-interface-guidelines/images) — "Parallax is designed to be almost unnoticeable"、2–5 层
- [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) — Reduce Motion 要"收紧弹簧"而非禁用
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) — 两层模型、绝不玻璃叠玻璃、Regular vs Clear、tint 只给一个控件
- [WWDC25 356 — Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/) — 同心圆角公式、capsule = height/2
- [WWDC23 10158 — Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/) — bounce 0/0.15/0.3/>0.4 分档、duration 优先
- [NSVisualEffectView.Material](https://developer.apple.com/documentation/appkit/nsvisualeffectview/material) — 语义材质表

**工程现实**
- [逆向 NSVisualEffectView — Oskar Groth](https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview) — 三层结构、`CABackdropLayer.scale = 0.25`、饱和度 ≈1.8、behind-window 阻止图层树扁平化
- [AuroraView](https://github.com/OskarGroth/AuroraView) — SwiftUI `.blur` 动画 50% CPU vs CALayer 0%
- [macOS Vibrancy 对比 — Ohanaware](https://ohanaware.com/swift/macOSVibrancy.html) — SwiftUI Material 在 macOS 上不做真正的透窗模糊
- [Vibrancy / NSAppearance — philz.blog](https://philz.blog/vibrancy-nsappearance-and-visual-effects-in-modern-appkit-apps/) — 材质**之上**的内容不继承 vibrancy；绝不覆写 `allowsVibrancy`
- [Apple: Optimizing View Drawing](https://developer.apple.com/library/content/documentation/Cocoa/Conceptual/CocoaViewsGuide/Optimizing/Optimizing.html) — 单窗口约 100 个 NSView 的经验上限
- [SwiftUI vs AppKit 性能实测](https://digitalblake.com/2026/04/28/swiftui-vs-appkit-macos-ui-performance/) — LazyVGrid 几百张够用 / 几千张掉帧 / 几万张需 NSCollectionView
- [Apple Forums 764264](https://developer.apple.com/forums/thread/764264) — macOS 15 trackpad 滚动 `_hitTestForEvent` 占 85%
- [compositingGroup vs drawingGroup — nilcoalescing](https://nilcoalescing.com/blog/GeometryCompositingAndDrawingGroupsInSwiftUI/)
- [Building Liquid Glass UI on macOS — Klarity](https://www.klaritydisk.com/blog/building-liquid-glass-ui-macos) — "边缘比表面重要"、渐变描边 > 背景模糊
- [squircle.js.org: continuous vs circular](https://squircle.js.org/blog/squircle-vs-rounded-rectangle) — 可见阈值 16–24pt

**对标与通用规范**
- [tvOS 焦点效果实测 — devsign](https://devsign.co/notes/custom-focus-effects-in-tvos) — 1.1× 缩放 / 阴影 r25 y16 / 视差 ±4pt / 倾斜 ±10°（3 米距离标定）
- [Raycast DESIGN.md](https://github.com/VoltAgent/awesome-design-md/blob/main/design-md/raycast/DESIGN.md) — 无阴影、四阶表面梯、发丝线撑深度
- [Linear DESIGN.md](https://github.com/voltagent/awesome-design-md/blob/main/design-md/linear.app/DESIGN.md) — 五阶表面梯、悬停=表面变化、顶边白色高光
- [Arc 设计拆解](https://blakecrosley.com/guides/design/arc) — `0 0 0 1px rgba(255,255,255,0.1)` 假发丝环
- [Sara Soueidan — 无障碍焦点指示器](https://www.sarasoueidan.com/blog/focus-indicators/) — 焦点≠选中、3:1 对比、offset 2px
- [W3C SC 2.4.13 Focus Appearance](https://www.w3.org/WAI/WCAG22/Understanding/focus-appearance.html) — 最小 2px
- [Material Design — Elevation](https://m1.material.io/material-design/elevation-shadows.html) — 桌面卡片 0dp→4dp 悬停、双层阴影（环境光+直接光）
- [深色模式阴影 — cssshowcase](https://www.cssshowcase.com/articles/color/shadows-in-dark-mode-adjusting-for-dark-backgrounds) — 浅色 10–15% vs 深色需 40–70%，故改用亮度阶梯
- [Google Photos Web UI](https://medium.com/google-design/google-photos-45b714dfbed1) — 虚拟化、统一边距不可协商

---

## 附：本规格已验证 / 已排除的 API

| API | 状态 | 验证方式 |
|---|---|---|
| `.visualEffect` | ✅ macOS 14 | 本地编译通过 |
| `.scrollTransition(_:axis:)` | ✅ macOS 14 | 本地编译通过 |
| `.onContinuousHover` | ✅ macOS 13 | 本地编译通过 |
| `.symbolEffect` | ✅ macOS 14 | 本地编译通过 |
| `.smooth` / `.snappy` / `interactiveSpring` | ✅ macOS 14 | 本地编译通过 |
| `RoundedRectangle(style: .continuous)` | ✅ | 本地编译通过 |
| `AngularGradient` / `EllipticalGradient` / `.blendMode(.plusLighter/.softLight)` | ✅ | 本地编译通过 |
| `rotation3DEffect(perspective:)` on `VisualEffect` | ✅ | 本地编译通过 |
| **`.hoverEffect`** | ❌ **macOS 不可用** | 编译器报 `'hoverEffect(_:isEnabled:)' is unavailable in macOS`（研究里两方来源有分歧，此处以编译器为准） |
| **`MeshGradient`** | ❌ **macOS 15**，本项目用不了 | 编译器报 `only available in macOS 15.0 or newer` |
| **`.containerBackground(_:for: .window)`** | ❌ macOS 15 | — |
| **`glassEffect` / `GlassEffectContainer`** | ❌ macOS 26 | — |
