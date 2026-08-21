import SwiftUI
import AppKit

/// 全局设计 token（DS）—— CSS 层的唯一入口。
///
/// 分层：
///
///   CSS 层（本文件）：`DS` 收敛所有视觉常量（间距 / 圆角 / 颜色 / 表面 / 阴影 / 动效）。
///     视图一律 `DS.xxx`，不得裸写 `Color.primary.opacity` / `.quaternary` 等。
///     旧 `Theme` 协议已收敛为兼容转发层（见 `UI/Theme.swift`），新代码不再使用。
///
///   API 层（`Platform/`）：`Platform.swift` 定义 PAL 协议（`ClipboardWriting` 等），
///     `Platform/*.swift` 为 macOS 实现，未来 `Win*` 另实现，`App` 注入具体实现。
///     详见 `Sources/Index/README.md` 的「CSS / API 分层」与 `Platform/Platform.swift` 顶部注释。

/// 全局设计 token。图库改版期间由并行分支共同遵守的约定，
/// 间距、圆角、分类色都收敛到这里 —— 视图代码里不再出现魔法数。
///
/// 字阶约定（不需要常量，直接用系统字体）只有 4 档：
///   `.title3.weight(.semibold)`  分组标题
///   `.body`                      正文
///   `.caption.weight(.medium)`   卡片主行 / 强调小字
///   `.caption2`                  次级小字（时间戳 / 胶囊）
enum DS {

    // MARK: - 间距（4px 基数）

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24

    // MARK: - 字号（pt）
    //
    // 全项目 83 处裸字号收敛到这里，按 pt 值命名（font13 = 13pt），
    // 替换无歧义。字重不收敛 —— 字重是语义（.medium/.semibold/.bold），
    // 由调用处按上下文选，收敛成 token 反而失去表达力。
    // 比例公式（`side * 0.78`、`rect.height * 0.52`）不收敛，它们不是字号档。

    /// 极小角标（快捷键徽章、状态点文字）。
    static let font7: CGFloat = 7
    /// 极小标注（放大镜坐标、角标数字）。
    static let font9: CGFloat = 9
    /// 微图标文字（元信息行箭头 / 复制按钮）。
    static let font10: CGFloat = 10
    /// 次级小字（时间戳、胶囊、元信息行）。
    static let font11: CGFloat = 11
    /// 卡片主行 / 强调小字（caption 档）。
    static let font12: CGFloat = 12
    /// 正文（body 档）。
    static let font13: CGFloat = 13
    /// 面板标题 / 次级标题。
    static let font14: CGFloat = 14
    /// 分组标题（title3 档）。
    static let font15: CGFloat = 15
    /// 大标题（sheet 标题、空态标题）。
    static let font18: CGFloat = 18
    /// 空态大图标文字。
    static let font20: CGFloat = 20
    /// 特大标题（空态大数字）。
    static let font24: CGFloat = 24

    // MARK: - 线宽（描边 / 发丝线）

    /// 发丝线（卡片分隔、1px 描边）。
    static let hairline: CGFloat = 1
    /// 强调描边（选中环、录制角标）。
    static let strokeEmphasis: CGFloat = 2
    /// 次级描边（虚线框、工具图标轮廓）。
    static let strokeSubtle: CGFloat = 1.5

    // MARK: - 共享尺寸（多处重复的视觉常量）

    /// 工具圆点直径（计数工具圆点、工具条参数点，两处逐字重复收敛于此）。
    static let toolDotSize: CGFloat = 12
    /// 复制反馈时长（复制后图标变对勾的停留时间）。
    static let copyFeedbackDelay: Duration = .milliseconds(1500)

    // MARK: - 圆角（只有两档）

    /// 按钮 / 胶囊等小件。
    static let radiusSmall: CGFloat = 6
    /// 卡片 / 分组块。
    static let radiusCard: CGFloat = 10
    /// 工具条 / 放大镜 / AI 面板等中型圆角（原散落的 8pt 收敛于此）。
    static let radiusMedium: CGFloat = 8
    /// 预览区 / 滚动截图进度面板等（原散落的 12pt 收敛于此）。
    static let radiusLarge: CGFloat = 12

    // MARK: - 分类色

    /// 分类名 → 颜色。侧边栏色点用；其它要按分类着色的地方也走这张表，
    /// 保证同一分类处处同色。未知分类（包括「其它」）兜底灰色。
    /// 枚举为单一事实来源，颜色关联到 `ShotClassifier.Category`，不再散落字符串。
    static func categoryColor(_ category: ShotClassifier.Category) -> Color {
        switch category {
        case .code: return .blue
        case .browser: return .teal
        case .chat: return .green
        case .design: return .pink
        case .terminal: return .indigo
        case .document: return .orange
        case .note: return .yellow
        case .media: return .purple
        case .productivity: return .mint
        case .other: return .gray
        }
    }

    /// 字符串重载：从落库/外部传入的中文名解析为枚举，解析失败兜底灰色。
    /// 新代码优先直接传 `ShotClassifier.Category`。
    static func categoryColor(_ name: String) -> Color {
        guard let category = ShotClassifier.Category(rawValue: name) else { return .gray }
        return categoryColor(category)
    }

    // MARK: - 状态色

    /// 警示（黄）：敏感内容提示等。背景/描边成对提供，避免视图里现写 opacity。
    static let statusWarningFill = Color.yellow.opacity(0.18)
    static let statusWarningStroke = Color.yellow.opacity(0.5)

    /// 细边框：Tag 胶囊等次级描边。
    static let borderSubtle = Color.primary.opacity(0.15)
    static let borderFaint = Color.primary.opacity(0.1)

    // MARK: - 强调色（选中 / 焦点）

    /// 工具栏选中态的浅 accent 底（EditorToolbar 等）。
    static let accentFillSelected = Color.accentColor.opacity(0.22)
    /// 历史版本高亮（EditorInspector）。
    static let accentFillHistory = Color.accentColor.opacity(0.18)
    /// 文件拖入图库时的整区浅高亮。
    static let accentFillDropTarget = Color.accentColor.opacity(0.10)
    /// 输入框焦点描边（TagSection）。
    static let accentStrokeInput = Color.accentColor.opacity(0.5)
    /// 搜索胶囊焦点描边。
    static let accentStrokeFocus = Color.accentColor.opacity(0.55)
    /// 固实 accent（前景色等不带透明度的场景，收敛写法便于后续统一换色）。
    static let accent = Color.accentColor

    /// 顶栏 / 外壳控件的选中态填充，深浅两值（GalleryShell）。
    static func accentFillActive(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.accentColor.opacity(0.22) : Color.accentColor.opacity(0.14)
    }

    // MARK: - 描边与弱化

    /// 通用中性描边（色块选中边、胶片条色块等，0.12）。
    static let borderDefault = Color.primary.opacity(0.12)
    /// 输入框空闲描边（SettingsView 等，复用 borderDefault）。
    static let focusRingIdle = borderDefault
    /// 强描边 / 斜杠（EditorEffectsPanel 透明档斜线）。
    static let borderStrong = Color.primary.opacity(0.45)
    /// 次级圆点（未选中参数点，0.75）。
    static let dimPrimary = Color.primary.opacity(0.75)
    /// 行悬停提亮（ShotInfoPage 修订行，0.06）。
    static let hoverFill = Color.primary.opacity(0.06)
    /// 时间线空心描边（Timeline 未选中，0.10）。
    static let timelineIdle = Color.primary.opacity(0.1)

    // MARK: - 不透明度常量（黑/白/灰）

    static let swatchOutline = Color.black.opacity(0.25)
    static let badgeStroke = Color.white.opacity(0.7)
    static let shadowOverlay = Color.black.opacity(0.6)
    static let connectorFill = Color.secondary.opacity(0.3)
    static let dotInactive = Color.secondary.opacity(0.55)
    /// 图标占位底（剪贴板历史行等，0.12）。
    static let iconPlaceholderFill = Color.secondary.opacity(0.12)

    // MARK: - 剪贴板历史卡片

    /// 卡片标题栏背景色（按类型）。
    static let clipboardTextBar = Color(white: 0.22)
    static let clipboardImageBar = Color.blue
    static let clipboardFileBar = Color.orange
    /// 卡片选中边框。
    static let clipboardSelectedRing = Color.blue
    static let overlayDim = Color.black.opacity(0.45)
    static let hoverBrighten = Color.white.opacity(0.05)

    // MARK: - 动态透明度（样式轴图标等需按档位取不同 alpha，收敛到 DS 避免裸写 Color.*.opacity）
    static func whiteOpacity(_ alpha: Double) -> Color { Color.white.opacity(alpha) }
    static func blackOpacity(_ alpha: Double) -> Color { Color.black.opacity(alpha) }
    static func primaryOpacity(_ alpha: Double) -> Color { Color.primary.opacity(alpha) }
}

// ============================================================
// MARK: - 空间层 token
//
// 「空间 UI」底座：深度、边缘光、阴影、发光、动效、视差。
// 一条总原则：**深度 = 光，不是边框**。
// 浅色靠阴影，深色靠亮度阶梯 + 顶边高光；边框只是「增强对比度」
// 无障碍模式下的降级方案，所以它才不是默认表达。
// ============================================================

extension DS {

    // MARK: - 圆角新增档
    //
    // 连同已有的 radiusSmall(6) / radiusCard(10)，圆角共 5 档，到顶。
    // 全项目一律 `style: .continuous`：10pt 处它和 .circular 肉眼几乎不可分
    //（可见阈值在 16–24pt），但它零成本，而 14/18 这两档确实需要。
    // 注意废弃的 `.cornerRadius(_:)` 只能画圆弧角，必须走
    // `.clipShape(RoundedRectangle(cornerRadius:style:.continuous))`。

    /// 极小件（时间戳胶囊、微角标）。
    /// 4 是「还看得出是圆角」的下限 —— 再小按同心公式会被归零成直角。
    static let radiusChip: CGFloat = 4
    /// 浮层 / sheet / Quick Look。
    /// 比卡片(10)大一档：浮层面积更大、离用户更近，圆角要跟着涨才不显得「削角」。
    static let radiusPanel: CGFloat = 14
    /// 全屏模态（暂无用例，占位）。
    /// 预留最大一档，避免将来有人在视图里现编一个魔法数。
    static let radiusModal: CGFloat = 18

    /// 同心圆角：内层 = 外层 − 内缩量。低于 2 视觉上等于直角，直接归零。
    ///
    /// 为什么必须同心：两条曲线共圆心时，间隙在整圈上恒定；不同心时间隙会在
    /// 拐角处被「掐细」或张成「喇叭口」，那种视觉张力就是廉价感的来源。
    /// 实例：卡片外 10、缩略图内缩 s1(4) → 内圆角 6，正好落在 radiusSmall 上，
    /// 阶梯自洽，不需要新常量。
    static func radiusInner(outer: CGFloat, inset: CGFloat) -> CGFloat {
        let r = outer - inset
        return r < 2 ? 0 : r
    }

    /// 外扩环（选中环画在卡片外侧 offset 处）：外层 = 内层 + 外扩量。
    ///
    /// 外扩量和圆角增量必须是**同一个数**。旧代码 `radiusCard + 3` 配 `padding(-4)`
    /// 就是外扩 4 却只加 3 圆角，四个拐角全是喇叭口。
    static func radiusOuter(inner: CGFloat, offset: CGFloat) -> CGFloat {
        inner + offset
    }

    // MARK: - 深度层
    //
    // 只有 4 档，且不打算再加。Apple 的理由是生理性的：
    // 每一次深度差异都要求眼睛重新对焦，深度平面太多会造成视觉疲劳。
    // 所以这是「层级模型」，不是可以随手 +1 的 z-index 阶梯。

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

    // MARK: - 表面填充（亮度阶梯）
    //
    // 深色模式的「高度」是亮度，不是阴影 —— 深色下阴影会饱和成一坨黑，
    // 读不出高度差（浅色只需 10–15% 的阴影，深色要 40–70% 才看得见，
    // 那时候已经脏了）。所以深色走 4 档亮度叠加，每档只差几个 RGB 点，
    // 边界交给发丝线撑（Raycast / Linear 都是这个做法）。
    //
    // 浅色模式所有层都是纯白：在 #ECECEC 左右的窗背景上纯白本身就高一层，
    // 再往上叠亮度会直接溢出，层级差只能交给阴影。

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

    // MARK: 两条颜色铁律
    //
    // 浅色模式此前「有时白、有时灰」，灰的那些地方尤其难看。根因是同屏出现了
    // 四五种深浅不一的面：系统窗背景灰、纯白面板、半透明白合成出的浅灰、
    // `.quaternary` 渲染出的中灰方块、材质的半透明灰……彼此都差一点点，
    // 读起来就是脏。
    //
    // 现在只认两条：
    //   1. **灰 = 底板**，全窗口只有一种灰（`windowBase`），且只出现在
    //      「内容之间的空隙」——面板缝、网格背景、分组头。
    //   2. **白 = 内容表面**，且必须**不透明**。半透明白叠在灰底上合成出来的
    //      是灰不是白，这正是上一轮把缩略图衬底做成 `.white.opacity(0.92)`
    //      时踩的坑。
    //
    // 需要「在白面板里再嵌一块」时用 `insetSurface`——它是**极淡**的一层，
    // 不是 `.quaternary` 那种中灰色块。

    /// 缩略图的衬底（图片按比例缩放后四周留下的那圈「信箱」）。
    ///
    /// **这里最容易把浅色模式做反。** 深色下衬底比窗底亮 → 卡片是「浮起的一块」；
    /// 浅色如果沿用 `.quaternary` 那类语义灰，它比窗底**更暗**，
    /// 每张卡片就读成在底色上「挖了个洞」——层级整个翻过来，满屏灰块。
    static func thumbnailBacking(_ scheme: ColorScheme) -> Color {
        // 浅色给**不透明**纯白：这是内容表面，不是一层蒙版。
        scheme == .dark ? .white.opacity(0.05) : .white
    }

    /// 嵌在面板/表面**内部**的一块（详情栏的信息卡、预览衬底、标签胶囊…）。
    ///
    /// 取代散在八处的 `.quaternary` —— 那个语义色在浅色下约等于 20% 的黑，
    /// 渲染成中灰方块压在白面板上，是「灰色部分特别丑」的直接来源。
    /// 这里给的是**极淡**的一层：深色加白 6%，浅色加黑 3.5%，
    /// 刚好读得出「这是嵌进去的一块」，又不会自成一种颜色。
    ///
    /// 做成**自适应外观的动态色**而不是 `(ColorScheme) -> Color`：
    /// 八个调用点里只有一个手上有 `@Environment(\.colorScheme)`，
    /// 为了配色去给每个视图加一个环境变量是本末倒置。
    static let insetSurface = Color(nsColor: insetSurfaceColor)

    private static let insetSurfaceColor = NSColor(name: "IndexInsetSurface") { appearance in
        appearance.isDarkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : NSColor(white: 0, alpha: 0.035)
    }

    // MARK: - 边缘高光（rim）
    //
    // 「边缘比表面重要」：一条从亮到暗的渐变描边，比任何背景不透明度调整
    // 都更能做出玻璃感，而且全是 GPU 上的便宜原语（几百张卡也扛得住）。
    //
    // 渐变方向的物理含义是「光从上方来」：
    // 深色 —— 顶边斜面接光是唯一强线索，所以顶亮底暗；`.plusLighter` 是加法混合，
    //         保证这条线永远只提亮、不会压暗底下的内容。
    // 浅色 —— 白表面的顶边接光根本看不出来，主导线索变成「整体暗一档的发丝线」，
    //         且底边更暗（底边处于自遮挡），所以是顶浅底深、`.normal` 直接压上去。

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

    /// 悬停时描边整体加浓（深色 +0.08 / 浅色 +0.05）：
    /// 抬起来的表面接光更多，边缘对比理应更强 —— 这比单纯加阴影更省、也更准。
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

    // MARK: - 阴影
    //
    // 深色的 L1 故意没有阴影：静止卡片的黑阴影落在黑底上只是糊一层脏，
    // 读不出任何高度信息。L2 才给 —— 卡片这时已经真的抬起来了，
    // 环境遮挡有了参照物，才读得出来。
    //
    // 硬约束：绝不把 shadow 的参数（color/radius/y）挂在连续手势或滚动上，
    // SwiftUI 会逐帧重新离屏渲染阴影。悬停态直接切换两组静态值、
    // 由 spring 隐式插值是可接受的（radius 12↔3 的插值代价有限）。

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

    /// 「直接光」硬阴影，配合上面那层宽软的「环境光」构成双层阴影。
    ///
    /// **只有 L3 允许**叠这一层 —— 双层阴影 = 双份离屏合成，
    /// 网格里几百张 L1/L2 卡片各来两份是性能自杀。浮层同屏通常只有一个，成本有界。
    static func shadowKey(_ scheme: ColorScheme) -> Shadow {
        scheme == .dark
            ? Shadow(color: .black.opacity(0.40), radius: 3, y: 1)
            : Shadow(color: .black.opacity(0.10), radius: 2, y: 1)
    }

    // MARK: - 发光（选中）
    //
    // 选中绝不用实心填充 —— 缩略图会把填充整片盖住，填充等于没画。
    // 通用解是「发光环 + 色调」（Photos / Google Photos / Windows 一致）。
    //
    // 深色数值全线更高（环 1.00 vs 0.90、光晕 0.38 vs 0.22、色调 0.14 vs 0.09）：
    // 深色模式需要**更多**层级区分而不是更少 —— 同样的不透明度在深色背景上看起来更弱。
    // 这是最反直觉也最实用的一条。

    enum Glow {
        /// WCAG 2.4.13 Focus Appearance 的下限就是 2px。
        /// 旧代码的 2.5px 在 1x 显示器上会渲染成模糊的 2.5 像素，2px 干净且达标。
        static let ringWidth: CGFloat = 2
        /// 等价于 CSS 的 `outline-offset: 2px`：环和缩略图之间要留呼吸位，
        /// 否则会和图片边缘糊在一起。同心换算 → 环圆角 = radiusCard + 2 = 12。
        static let ringOffset: CGFloat = 2
        /// 逆向 Liquid Glass 测得的镜面高光不透明度落在 0.20–0.50：
        /// 低于 0.2 直接消失，高于 0.5 会退化成一道生硬描边。
        /// blur 9 让光晕刚好溢出环外一圈而不散成一团雾。
        static let haloBlur: CGFloat = 9

        static func ringOpacity(_ s: ColorScheme) -> Double { s == .dark ? 1.00 : 0.90 }
        /// 取 0.20–0.50 区间的下沿：这是常驻状态，长期挂在屏幕上不能太抢。
        static func haloOpacity(_ s: ColorScheme) -> Double { s == .dark ? 0.38 : 0.22 }
        /// 配套混合模式见 SpatialCardModifier：
        /// 浅色 `.multiply`（accent 像染色玻璃压在白卡上，保留下方明暗），
        /// 深色 `.plusLighter`（加法，accent 像发光而不是脏污）。
        /// 反过来用会把深色卡片直接压黑。
        static func tint(_ s: ColorScheme) -> Double        { s == .dark ? 0.14 : 0.09 }
    }

    // MARK: - 动效
    //
    // Apple WWDC23 之后的现代轴是 duration + bounce：
    // bounce 0 = 默认 / 0.15 = 俏皮 / 0.3 = 物理感 / >0.4 = UI 里绝不用。
    // 这里沿用项目已有的 response + dampingFraction 轴，换算关系是
    // dampingFraction ≈ 1 − bounce。

    enum Motion {
        /// 悬停抬升 / 按下 / 角标出没 / 收藏星。
        /// 微交互要跟手：0.22 是「立刻发生」的感知阈；
        /// 阻尼 0.90 ≈ bounce 0.1，有一点点生命力但不弹。
        static let micro = Animation.spring(response: 0.22, dampingFraction: 0.90)
        /// 选中切换 / 布局模式切换（网格↔瀑布）/ inspector 开合。
        /// 系统默认是 0.55/0.825，对高频操作太拖沓；0.35 更利落。
        /// 阻尼 0.85 ≈ bounce 0.15。
        static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)
        /// 侧边栏展开 / sheet 出现 / 大面积表面。
        /// Liquid Glass 规则：大面积 = 更厚的材质 = 应该动得更慢。
        /// 阻尼 1.0 = 临界阻尼、零过冲 —— 大面块过冲会晃眼。
        static let ambient = Animation.spring(response: 0.50, dampingFraction: 1.00)
        /// 指针跟随（视差）唯一的一档。
        /// 零过冲是硬要求：跟随一旦有 bounce，读起来是「卡顿」而不是「弹性」。
        static let track = Animation.interactiveSpring(response: 0.16, dampingFraction: 1.00)

        // Reduce Motion 下 Apple 要求的是「收紧弹簧、减少弹性」，不是禁用动画 ——
        // 突变没有过程，用户反而会丢失「这是同一个元素」的连续性。
        // 所以 micro/standard 降级成同量级的 easeOut，只有视差（track）整个关掉。
        static func micro(reduced: Bool) -> Animation {
            reduced ? .easeOut(duration: 0.12) : micro
        }
        static func standard(reduced: Bool) -> Animation {
            reduced ? .easeOut(duration: 0.16) : standard
        }
    }

    // MARK: - 视差
    //
    // Apple 原话：视差要「几乎不可察觉」（almost unnoticeable）。
    // tvOS 官方那套是 ±4pt 位移 / ±10° 倾斜，但那是按 **3 米观看距离**标定的，
    // 桌面在 50cm 处照搬会像玩具。

    enum Parallax {
        /// ±5pt：桌面比 tvOS 近，可以略大于它的 ±4pt，
        /// 5 是「能感觉到、但说不出哪里动了」的量。
        static let maxOffset: CGFloat = 5
        /// ±1.5°：图库网格的卡间距只有 16pt，倾斜再大就会视觉上切到邻居卡片。
        /// 社区共识是密集网格 ~5°、超过 15° 一定翻车，1.5° 已是安全上限。
        static let maxTilt: Double = 1.5
        /// 透视越小、3D 感越弱。0.3 让 1.5° 读起来像「轻微抬头」，
        /// 而不是一张卡在翻面。
        static let perspective: CGFloat = 0.3
        /// 位移会把图片边缘的空白露出来，所以要先放大补上 2×maxOffset。
        /// 封顶 1.12 是防止小卡片被放大到糊。
        static let maxOverscale: CGFloat = 1.12
    }

    // MARK: - 卡片形变
    //
    // 1.02 / −3pt 是桌面卡片抬升的行业共识（translateY(-2..-5px) + scale(1.02)）。
    // tvOS 的 1.1× + 16pt 位移同样是 3 米距离标定的，桌面要除以 3~4 才对。
    // 1.015 偏保守、1.05 在密集网格里会顶到邻居，1.02 是甜点值。

    enum Lift {
        static let hoverScale: CGFloat = 1.02
        static let hoverY: CGFloat = -3
        /// 按下轻微内陷。0.99 足够给出「按到了」的触感，再深会像塌陷。
        static let pressScale: CGFloat = 0.99
    }
}

// ============================================================
// MARK: - 外壳层 token（浮动面板窗口）
//
// 图库窗口从「NavigationSplitView 齐平分栏」改成「深底 + 浮起圆角面板」之后
// 新增的一组 token：窗口底色、面板底色、面板圆角、外壳尺寸。
//
// 两条约定，改这里之前先读：
//   1. **窗口底色是不透明的。** 面板之间的间隙露出的是这层底色，不是桌面 ——
//      窗口**没有**开 `isOpaque = false`（那会让任何没人上色的区域透出壁纸，
//      是整窗级事故）。所以「透明度」在这套外壳里只是亮度差，不是真透。
//   2. **面板一律纯色填充，不上材质。** 每窗口只允许一个 behindWindow 材质
//      （见 SpatialModifiers 的铁律 2），而这套布局里同屏面板有三四块；
//      纯色也顺手让 ReduceTransparency 无需降级 —— 本来就不透明。
// ============================================================

extension DS {

    /// 浮动面板圆角（18）。
    ///
    /// 与 `radiusModal` 同值但**不是同一个 token**：那一档的语义是「全屏模态」，
    /// 这一档是「浮在窗口底色上的功能面板」。两者哪天要分开调，各调各的。
    static let radiusFloating: CGFloat = 18

    /// 面板离窗口底色有多远。
    enum PanelLevel {
        /// 直接坐在窗口底色上：侧栏、详情栏、图标轨。
        case resting
        /// 压在别的面板或内容之上：底部工具条、展开的标签面板。亮一档、阴影更重。
        case overlay
    }

    // MARK: 窗口与面板底色
    //
    // 用**动态 NSColor** 而不是 `Color` + `@Environment(\.colorScheme)`：
    //   · 同一个实例既能给 SwiftUI（`Color(nsColor:)`）也能给 `NSWindow.backgroundColor`，
    //     「窗口自己那层底」和「内容铺的那层底」保证同色 ——
    //     两边各写一遍常量的话，live resize 时会在边缘闪出一条不同的灰。
    //   · 深浅切换由 AppKit 解析，视图层不需要为了取色而订阅 colorScheme。

    /// 窗口底色。深色近黑 `#0D0D0F`（所有浮起面板都比它亮一档），
    /// 浅色用系统窗背景色 —— 浅色侧的层级差由阴影承担，底色不该自己发明一个灰。
    static let windowBase = NSColor(name: "IndexWindowBase") { appearance in
        appearance.isDarkAqua
            ? NSColor(srgbRed: 0.051, green: 0.051, blue: 0.059, alpha: 1)  // #0D0D0F
            : .windowBackgroundColor
    }

    /// 面板底色。深色 `#17171A` / `#1C1C1F`（比窗底亮 4~8 个 RGB 点，
    /// 正是 §8 亮度阶梯的做法）；浅色一律纯白 —— 在 #ECECEC 的窗背景上
    /// 纯白本身就是「高一层」，再叠亮度只会溢出。
    static func panelFill(_ level: PanelLevel) -> Color {
        Color(nsColor: level == .overlay ? panelFillOverlay : panelFillResting)
    }

    private static let panelFillResting = NSColor(name: "IndexPanelResting") { appearance in
        appearance.isDarkAqua
            ? NSColor(srgbRed: 0.090, green: 0.090, blue: 0.102, alpha: 1)  // #17171A
            : .white
    }

    private static let panelFillOverlay = NSColor(name: "IndexPanelOverlay") { appearance in
        appearance.isDarkAqua
            ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.122, alpha: 1)  // #1C1C1F
            : .white
    }

    // MARK: 外壳尺寸
    //
    // 设计稿是 1586×992 量出来的，这里按比例落到 1240 宽的默认窗口上。

    enum Shell {
        /// 自绘顶栏高度。红绿灯（中心约 y=20）落在它上半部，logo 与搜索框垂直居中。
        static let topBarHeight: CGFloat = 72
        /// 顶栏左侧安全区：红绿灯是系统画的，位置留系统默认，自绘内容从这里才开始。
        /// 三颗按钮右沿约 x=72，留 80 是给「窗口变大时按钮不动」的余量。
        static let trafficLightInset: CGFloat = 80
        /// 面板与窗口边缘的距离。
        static let windowMargin: CGFloat = DS.s3
        /// 面板之间的缝。缝就是深度线索本身 —— 不要为了「多点内容」把它压到 8 以下。
        static let panelGap: CGFloat = DS.s3
        // 曾经还有一个 `sidebarWidth`(232)。顶层选项从左侧栏搬到顶栏的分段控件之后，
        // 左边整栏消失，这个 token 随之没有了使用者。
        /// 右侧详情面板宽度（设计稿 370）。
        static let inspectorWidth: CGFloat = 370
        /// 搜索胶囊的最大宽度（设计稿 460）。窗口窄时它先让位。
        static let searchWidth: CGFloat = 460
        static let searchHeight: CGFloat = 34
        /// 顶栏右侧图标按钮的边长（设计稿 36×36 圆角方）。
        static let controlSide: CGFloat = 36
        /// 筛选胶囊行的高度（设计稿 34）。
        static let chipHeight: CGFloat = 34
        /// 底部 bar 高度（搜索框 38 + 上下各 3pt）。
        static let bottomBarHeight: CGFloat = 44
    }

    // MARK: - 悬停 / 容器填充（深浅两值，视图不再现写 white/black opacity）

    /// 顶栏选项托盘底。
    static func trayFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.05)
    }

    /// 搜索胶囊填充。
    static func capsuleFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.07) : .black.opacity(0.05)
    }

    /// 搜索胶囊描边。
    static func capsuleStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.10) : .black.opacity(0.10)
    }

    /// 顶栏选中胶囊填充（深色半透亮，浅色实白）。
    static func tabSelectedFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.13) : .white
    }

    /// 顶栏未选中胶囊悬停填充。
    static func tabHoverFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.04)
    }

    /// 外壳图标悬停填充（GalleryShell）。
    static func shellHoverFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.09) : .black.opacity(0.06)
    }

    /// 快捷键徽章底。
    static func badgeFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06)
    }

    /// 1px 发丝线（SpatialModifiers hairline，深色顶边光、浅色自遮挡）。
    static func hairlineFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.10) : .black.opacity(0.09)
    }

    /// 详情面板柔和底（InspectorMetrics.softFill 的 DS 版，深色加白、浅色加黑）。
    static func softFill(_ scheme: ColorScheme, hovering: Bool) -> Color {
        scheme == .dark
            ? .white.opacity(hovering ? 0.16 : 0.09)
            : .black.opacity(hovering ? 0.11 : 0.06)
    }

    /// 行悬停底（InspectorMetrics.rowHoverFill 的 DS 版）。
    static func rowHoverFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.045)
    }

    /// 带语义色淡底（InspectorCircle tinted，hover 30% / 常态 18%）。
    static func tintFill(_ color: Color, hovering: Bool) -> Color {
        color.opacity(hovering ? 0.30 : 0.18)
    }

    // MARK: - 遮罩与边缘（视图不再裸写 .black.opacity）
    static let maskTransparent = Color.black.opacity(0)
    static let maskOpaque = Color.black

    // MARK: - 工具条 AppKit 令牌（ToolbarRenderer 专用，避免裸写 NSColor）
    static let toolbarBackground = NSColor(calibratedWhite: 0.13, alpha: 0.96)
    static let toolbarStroke = NSColor.white.withAlphaComponent(0.14)
    static let toolbarSeparator = NSColor.white.withAlphaComponent(0.18)
    static let toolbarSelected = NSColor.controlAccentColor.withAlphaComponent(0.9)
    static let toolbarHover = NSColor.controlAccentColor.withAlphaComponent(0.5)
    static let toolbarForeground = NSColor.white.withAlphaComponent(0.92)
}

extension NSAppearance {
    /// 当前外观是否深色。写在这里而不是每个 dynamicProvider 里各来一遍
    /// `bestMatch(from:)` —— 那串字面量重复四次就一定会有人抄错一个。
    var isDarkAqua: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
