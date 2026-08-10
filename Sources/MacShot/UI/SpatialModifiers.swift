import SwiftUI
import AppKit

/// 空间 UI 的视图层实现：材质桥、卡片四态、玻璃面板、视差、滚动深度。
/// 数值一律来自 `DS`（见 DesignTokens.swift 的「空间层 token」段），这里只负责组装。
///
/// 三条使用铁律，写视图前先读：
///   1. **玻璃只给功能层**（侧边栏 / 详情栏 / 吸顶头 / 底栏 / 浮层），
///      内容层（网格画布 + 卡片）一律不上材质 —— 这既是 Apple 的硬规则
///      「绝不把玻璃放进内容层、绝不玻璃叠玻璃」，也是性能红线。
///   2. **每个窗口最多一个 `.behindWindow` 的 `NSVisualEffectView`。**
///      它的成本是「每窗口」的（整窗失去 WindowServer 图层树扁平化优化），
///      不是每视图的；几百张卡各挂一个必炸。卡片级玻璃用
///      「渐变填充 + 渐变描边 + 一次 shadow」冒充。
///   3. **深度 = 光，不是边框。** 浅色靠阴影，深色靠亮度阶梯 + 顶边高光。

// ============================================================
// MARK: - AppKit 材质桥
// ============================================================

/// behind-window 模糊的唯一入口。
///
/// SwiftUI 的 `.ultraThinMaterial` 在 macOS 上**只模糊 App 自己的背景**，
/// 不模糊窗口后面的桌面（Apple 文档原话）。要真正的透窗玻璃只能桥 AppKit。
/// 顺带一提：`.containerBackground(_:for: .window)` 是 macOS 15，本项目（部署
/// 目标 macOS 14）用不了，所以这个桥没有替代品。
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
/// 旧代码的 `isHovering && !isSelected ? 1.015 : 1` 会让「选中后再悬停」发生跳变，
/// 而 HIG 的硬要求正是：焦点和选中必须各自独立可见。
struct SpatialCardState: Equatable {
    var isHovering = false
    var isSelected = false
    var isPressed = false

    var elevation: DS.Elevation { isHovering ? .raised : .content }
}

// ============================================================
// MARK: - spatialCard
// ============================================================

/// 卡片的全部深度表达：表面填充 + 边缘高光 + 阴影 + 选中环/光晕/色调 + 四态动效。
/// 用它之后，视图里原有的 strokeOpacity / shadowColor / scaleEffect / animation
/// 应当全部删掉，避免两套数值打架。
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
            // 深色提亮罩：阴影在深色里读不出高度，用亮度当高度。
            .overlay {
                if scheme == .dark && state.isHovering {
                    shape.fill(DS.hoverBrighten).allowsHitTesting(false)
                }
            }
            // 选中色调：染色玻璃，不是实心填充（实心会把缩略图整片盖住）。
            // 浅色 .multiply（保留下方明暗），深色 .plusLighter（发光而非脏污）。
            // 反过来用 .multiply 会把深色卡片直接压黑。
            .overlay {
                if state.isSelected {
                    shape.fill(DS.accent.opacity(DS.Glow.tint(scheme)))
                        .blendMode(scheme == .dark ? .plusLighter : .multiply)
                        .allowsHitTesting(false)
                }
            }
            // 边缘高光。必须 strokeBorder —— stroke 把线画在路径中心，
            // 一半在 clip 外被削掉，得到毛边的 0.5px。
            // ReduceTransparency 下混合模式退回 .normal：加法/乘法混合本身就是
            // 半透明观感的一部分，该模式下必须给出确定的实色边。
            .overlay {
                shape.strokeBorder(rim.gradient, lineWidth: rim.lineWidth)
                    .blendMode(reduceTransparency ? .normal : rim.blend)
                    .allowsHitTesting(false)
            }
            // 混合模式必须有 compositingGroup 做边界，
            // 否则 .plusLighter / .multiply 会和任意兄弟视图混合
            //（包括你根本没打算碰的邻居卡片）。
            // 它本身开销极小 —— 只是重排效果的应用时机，不做栅格化，
            // 和会把内容栅格化成静态位图的 drawingGroup() 完全不是一回事。
            .compositingGroup()
            .shadow(color: sh.color, radius: sh.radius, x: 0, y: sh.y)
            // 选中环：外扩 2pt，同心圆角 = radius + 2（外扩量和圆角增量必须同数）。
            .overlay {
                if state.isSelected {
                    RoundedRectangle(
                        cornerRadius: DS.radiusOuter(inner: radius, offset: DS.Glow.ringOffset),
                        style: .continuous
                    )
                    .strokeBorder(
                        DS.accent.opacity(DS.Glow.ringOpacity(scheme)),
                        lineWidth: DS.Glow.ringWidth
                    )
                    .padding(-DS.Glow.ringOffset)
                    .allowsHitTesting(false)
                }
            }
            // 光晕：模糊的实心 accent 垫在环后面。
            // 只有选中的卡才付这份 blur 代价（通常 1 张），成本有界；
            // 且它是静态的，不参与动画 —— 动画化的 .blur 实测能吃掉 50% CPU。
            // ReduceTransparency 下整个关掉（环和色调仍在，选中依然可读）。
            .background {
                if state.isSelected && !reduceTransparency {
                    RoundedRectangle(
                        cornerRadius: DS.radiusOuter(inner: radius, offset: DS.Glow.ringOffset),
                        style: .continuous
                    )
                    .fill(DS.accent)
                    .blur(radius: DS.Glow.haloBlur)
                    .opacity(DS.Glow.haloOpacity(scheme))
                    .padding(-DS.Glow.ringOffset)
                    .allowsHitTesting(false)
                }
            }
            .scaleEffect(scaleValue)
            .offset(y: state.isHovering && !reduceMotion ? DS.Lift.hoverY : 0)
            // 三条 animation 各管各的 value：悬停和选中同时发生时，
            // 两者用各自的时长曲线独立播放，不会互相截断。
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
/// ⚠️ 侧边栏和 inspector 由 SwiftUI（`NavigationSplitView` / `.inspector`）
/// 自动套材质，不要再调用这个 —— 那正是「材质叠材质」变浑浊的入口。
///
/// ReduceTransparency 下整体退成 `windowBackgroundColor` 实色：
/// 材质的语义是「半透明地借用底下的内容」，该模式下必须给确定的不透明底。
struct GlassPanelModifier: ViewModifier {

    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode
    var radius: CGFloat
    /// 材质边界的发丝线画在哪条边。nil = 不画。
    /// 用它替代 `Divider()`：材质边界本身就是分界，1px 实线是多余的第二条线。
    var edge: Edge?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    // 用面板底色而不是 `windowBackgroundColor` —— 后者恰好就是
                    // 窗口底色，面板会和底板同色、缝直接消失，等于把层级抹平。
                    DS.panelFill(.resting)
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
    /// 浅色 black 0.09 是「底边自遮挡」，方向和 DS.rim 的渐变一致 ——
    /// 整个 App 的光源方向必须只有一个，否则深度线索会互相抵消。
    private var hairline: some View {
        Rectangle().fill(DS.hairlineFill(scheme))
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
///（本项目已有瀑布布局振荡的前科）。
///
/// 视差是有据可查的前庭触发源（眩晕 / 恶心），Reduce Motion 下整个关掉，不是减半。
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
            // 跟随必须零过冲（track 的阻尼是 1.0）：
            // 指针跟随一旦有 bounce，读起来是「卡顿」不是「弹性」。
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
            // 视图消失时兜底清一次，否则卡片会永久停在偏移状态。
            .onDisappear { pointer = nil }
    }

    /// 归一化成 [-1, 1]² 的 unit vector；未悬停时返回 .zero，
    /// 此时整个闭包退化成 identity 变换，成本近似为零。
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
/// blur 在 scrollTransition 里是逐帧离屏渲染 × 可见卡片数
///（SwiftUI 的 .blur 动画实测吃掉 50% CPU，等价效果走 CALayer 是 0%）。
///
/// 数值同样克制：0.72 / 0.97 / 6pt，再大就变成「内容在打架」。
/// 建议由 AppSettings 提供开关、几千张库时让用户关掉：
/// macOS 15 的 SwiftUI 滚动本身有已知性能回归（trackpad 滚动时
/// `_hitTestForEvent` 吃掉约 85% 执行时间），滚动预算已经被啃掉一块。
/// 优先考虑成本恒定的容器级 `scrollEdgeMask`。
struct ScrollDepthModifier: ViewModifier {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            // Reduce Motion 下直接 passthrough：滚动联动的位移/缩放是典型的运动触发源。
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
    /// 渐变高度必须刚好等于吸顶头高度，卡片滑进标题时才是「化开」而不是「被切」。
    var topInset: CGFloat = 28

    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [DS.maskTransparent, DS.maskOpaque],
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

    /// 卡片四态一次给全。用在整卡最外层，替换掉原有的描边/阴影/缩放/动画。
    func spatialCard(_ state: SpatialCardState, radius: CGFloat = DS.radiusCard) -> some View {
        modifier(SpatialCardModifier(state: state, radius: radius))
    }

    /// 功能层玻璃。只给 chrome；侧边栏 / inspector 不要调用（系统已自动套材质）。
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

    /// 缩略图视差。`isEnabled` 一般接卡片自己的 isHovering，只让当前那张付成本。
    func parallaxThumbnail(isEnabled: Bool = true) -> some View {
        modifier(ParallaxThumbnailModifier(isEnabled: isEnabled))
    }

    /// 逐卡滚动深度（可关）。必须用在 ScrollView 内部的元素上。
    func scrollDepth() -> some View { modifier(ScrollDepthModifier()) }

    /// 容器级滚动边缘。用在 ScrollView 自身上，成本与卡片数无关。
    ///
    /// ⚠️ **目前全项目没有调用点**，保留是因为它只差一个参数就能用。
    /// 图库网格用了 `pinnedViews` 吸顶分组头，实测（探针量几何 + 位图回读）
    /// 发现 ScrollView 帧顶端 `y = 52` 与吸顶头顶端**完全重合** ——
    /// 渐变带从 0 起算就直接淡掉了标题本身，而不是「卡片滑进标题时化开」。
    /// 要让它可用，需要加一个渐变起点下移量（如 `startAt:` 或读 safeAreaInsets），
    /// 让渐变从吸顶头下沿才开始。在那之前，顶部的深度感由逐卡 `scrollDepth()` 承担。
    func scrollEdgeMask(topInset: CGFloat = 28) -> some View {
        modifier(ScrollEdgeMask(topInset: topInset))
    }
}
