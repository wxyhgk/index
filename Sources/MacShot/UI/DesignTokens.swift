import SwiftUI
import AppKit

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

    // MARK: - 圆角（只有两档）

    /// 按钮 / 胶囊等小件。
    static let radiusSmall: CGFloat = 6
    /// 卡片 / 分组块。
    static let radiusCard: CGFloat = 10

    // MARK: - 分类色

    /// 分类名 → 颜色。侧边栏色点用；其它要按分类着色的地方也走这张表，
    /// 保证同一分类处处同色。未知分类（包括「其它」）兜底灰色。
    static func categoryColor(_ name: String) -> Color {
        switch name {
        case "代码": return .blue
        case "浏览器": return .teal
        case "聊天": return .green
        case "设计": return .pink
        case "终端": return .indigo
        case "文档": return .orange
        case "笔记": return .yellow
        case "影音": return .purple
        case "效率": return .mint
        default: return .gray
        }
    }
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
    static let windowBase = NSColor(name: "MacShotWindowBase") { appearance in
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

    private static let panelFillResting = NSColor(name: "MacShotPanelResting") { appearance in
        appearance.isDarkAqua
            ? NSColor(srgbRed: 0.090, green: 0.090, blue: 0.102, alpha: 1)  // #17171A
            : .white
    }

    private static let panelFillOverlay = NSColor(name: "MacShotPanelOverlay") { appearance in
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
        /// 左侧面板宽度（设计稿：图标轨 56 + 标签面板 168 + 缝）。
        static let sidebarWidth: CGFloat = 232
        /// 右侧详情面板宽度（设计稿 370）。
        static let inspectorWidth: CGFloat = 370
        /// 搜索胶囊的最大宽度（设计稿 460）。窗口窄时它先让位。
        static let searchWidth: CGFloat = 460
        static let searchHeight: CGFloat = 38
        /// 顶栏右侧图标按钮的边长（设计稿 36×36 圆角方）。
        static let controlSide: CGFloat = 36
        /// 筛选胶囊行的高度（设计稿 34）。
        static let chipHeight: CGFloat = 34
    }
}

extension NSAppearance {
    /// 当前外观是否深色。写在这里而不是每个 dynamicProvider 里各来一遍
    /// `bestMatch(from:)` —— 那串字面量重复四次就一定会有人抄错一个。
    var isDarkAqua: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
