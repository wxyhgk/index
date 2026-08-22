import SwiftUI
import AppKit

// MARK: - 图库外壳：浮动面板容器与外壳控件
//
// 新版图库是「深色窗口底 + 浮在上面的圆角面板」：侧栏、详情栏、（后续的）图标轨
// 与底部工具条都是同一种容器。这个文件放的就是那个容器本身和它的配件 ——
// 面板修饰器、外壳图标按钮样式、面板关闭按钮、详情栏面板。
//
// 与 SpatialModifiers 的分工：那边是**内容层**（卡片四态、视差、滚动深度）
// 和 behindWindow 材质桥；这边是**外壳层**（窗口 chrome 与功能面板）。
// 两边共用 DS 的深度 / 描边 / 阴影 / 动效 token，不各自发明数值。

// ============================================================
// MARK: - floatingPanel
// ============================================================

/// 浮动面板：纯色填充 + 渐变描边 + （只在浅色下）阴影 + 圆角裁切。
///
/// 三条设计取舍：
///
/// 1. **不上材质。** 每个窗口只允许一个 `behindWindow` 材质（成本是每窗口的，
///    见 SpatialModifiers 铁律 2），而这套布局里同屏面板有三四块。而且窗口底色
///    本身不透明（`isOpaque` 没关），面板下面根本没有桌面可借 —— 材质只会
///    采样到自家的底色，白付一份模糊。顺带的好处：ReduceTransparency 不需要
///    降级分支，面板本来就是实色。
///
/// 2. **深色不给阴影。** 黑阴影落在 `#0D0D0F` 的底上读不出任何高度，只是多一次
///    离屏合成。深色的高度差交给亮度阶梯（面板比窗底亮 4~8 个 RGB 点）+ 顶边高光；
///    浅色反过来 —— 纯白面板在浅灰窗底上只能靠阴影分层，所以浅色必须给。
///
/// 3. **描边用 `.floating` 那一档的 rim**（深色顶 0.24 / 底 0.06，浅色顶 0.09 /
///    底 0.17）。方向和卡片描边同源：全 App 只有一个光源，从上方来。
struct FloatingPanelModifier: ViewModifier {

    var radius: CGFloat
    var level: DS.PanelLevel

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let rim = DS.rim(.floating, scheme, hovering: false)
        let surface = content
            .background(DS.panelFill(level), in: shape)
            .clipShape(shape)
            // strokeBorder 而不是 stroke：stroke 把线画在路径中心线上，
            // 一半会被 clipShape 削掉，得到毛边的 0.5px。
            .overlay {
                shape.strokeBorder(rim.gradient, lineWidth: rim.lineWidth)
                    .blendMode(reduceTransparency ? .normal : rim.blend)
                    .allowsHitTesting(false)
            }

        if scheme == .dark {
            surface
        } else {
            // 分支切换只发生在深浅模式切换那一下（整棵树本来就要重建），
            // 不是每帧 —— 用 `.shadow(radius: 0)` 空转反而可能白付一次离屏。
            let sh = DS.shadow(level == .overlay ? .floating : .raised, scheme)
            surface
                .compositingGroup()
                .shadow(color: sh.color, radius: sh.radius, x: 0, y: sh.y)
        }
    }
}

extension View {

    /// 把自己包成一块浮在窗口底色上的圆角面板。
    ///
    /// 用在面板的**最外层**：先 `.frame()` 定尺寸，再调它 —— 反过来的话
    /// 填充和描边只会包住内容的自然尺寸。
    ///
    /// - Parameters:
    ///   - radius: 圆角。默认 `DS.radiusFloating`(18)。小面板（图标轨、悬浮胶囊）
    ///     用 `DS.radiusPanel`(14)，再小的内嵌件用 `DS.radiusCard`(10)。
    ///   - level: `.resting` = 直接坐在窗口底色上（侧栏 / 详情栏 / 图标轨）；
    ///     `.overlay` = 压在别的面板或内容之上（底部工具条 / 展开的标签面板），
    ///     底色亮一档、浅色下阴影更重。
    func floatingPanel(
        radius: CGFloat = DS.radiusFloating,
        level: DS.PanelLevel = .resting
    ) -> some View {
        modifier(FloatingPanelModifier(radius: radius, level: level))
    }
}

// ============================================================
// MARK: - 外壳图标按钮
// ============================================================

/// 顶栏 / 面板头上的图标按钮：正方圆角、悬停浮出底色、选中态填 accent。
///
/// `@State` 不能写在 `ButtonStyle` 上（它不是 View，没有视图身份，悬停状态会串），
/// 所以真正的实现是下面那个嵌套的视图 —— 这是 ButtonStyle 想要悬停/动画时的标准做法。
///（名字不能叫 `Body`：那会撞上 `ButtonStyle` 的 `associatedtype Body`，
/// 编译器要求它和外层类型一样可见。）
struct ShellIconButtonStyle: ButtonStyle {

    /// 选中 / 已激活（如「筛选中」「详情栏已开」）：填实心 accent。
    var isActive: Bool = false
    var side: CGFloat = DS.Shell.controlSide

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, isActive: isActive, side: side)
    }

    private struct Surface: View {

        let configuration: ButtonStyleConfiguration
        let isActive: Bool
        let side: CGFloat

        @Environment(\.colorScheme) private var scheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
        }

        /// 悬停底色走「亮度阶梯」那一套：深色加白、浅色加黑，都是几个点的量。
        ///
        /// **激活态不再填实心 accent。** 顶栏上同时有搜索框焦点环、详情栏开关、
        /// 网格里的选中环、详情栏的「编辑」主按钮、缩放滑杆 —— 五处一起发蓝，
        /// 而 spatial-ui-spec §7.1 的规矩是同屏最多一处上强调色。
        /// 这里改成「淡染 + accent 图标」：状态一样读得出，但不跟内容抢注意力。
        /// 强调色的归属留给**内容的选中态**，那才是用户真正要找的东西。
        private var fill: Color {
            if isActive { return DS.accentFillActive(scheme) }
            guard hovering else { return .clear }
            return DS.shellHoverFill(scheme)
        }

        var body: some View {
            configuration.label
                .font(.system(size: DS.font14, weight: .medium))
                .foregroundStyle(isActive ? DS.accent : Color.primary)
                .frame(width: side, height: side)
                .background(fill, in: shape)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? DS.Lift.pressScale : 1)
                .onHover { hovering = $0 }
                .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
                .animation(DS.Motion.micro(reduced: reduceMotion), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == ShellIconButtonStyle {

    /// 顶栏图标按钮。
    static var shellIcon: ShellIconButtonStyle { ShellIconButtonStyle() }

    /// 带激活态的顶栏图标按钮（筛选中 / 详情栏已开 / 面板已展开…）。
    static func shellIcon(
        active: Bool,
        side: CGFloat = DS.Shell.controlSide
    ) -> ShellIconButtonStyle {
        ShellIconButtonStyle(isActive: active, side: side)
    }
}

// ============================================================
// MARK: - 面板关闭按钮
// ============================================================

/// 浮动面板右上角的 ✕（设计稿 §6：圆形浅底，直径 28）。
/// 面板是浮起来的卡片、不是齐平分栏，所以关闭入口必须画在面板自己身上 ——
/// 顶栏那个开关是「另一个入口」，不是唯一入口。
struct PanelCloseButton: View {

    /// 无障碍标签与 tooltip 用。默认「关闭」，具体面板可以说得更清楚。
    /// 排在 `action` 前面是为了让调用方能把动作写成尾随闭包。
    var label: String = "关闭"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: DS.font10, weight: .bold))
        }
        .buttonStyle(ShellIconButtonStyle(side: 28))
        .clipShape(Circle())
        .accessibilityLabel(label)
        .help(label)
    }
}

// ============================================================
// MARK: - 详情栏面板
// ============================================================

/// 右侧详情面板：单选 → `ShotDetailPane`，多选 → `MultiSelectionPane`，
/// 没选中 → 空态。三种内容照旧，只是外面多了一层浮动卡片和一个关闭按钮。
///
/// 内容解析（两趟全列表扫描）留在**这一层**而不是 GalleryView：
/// 那是三块面板的共同父层，把 store / selection 的订阅放在那里，
/// 意味着任何一次选中变化都要重算整棵外壳的 body。这里订阅，失效范围就只有详情栏。
struct GalleryInspectorPanel: View {

    @Binding var isPresented: Bool

    @ObservedObject private var store: ShotStore
    @ObservedObject private var viewModel: GalleryViewModel
    @ObservedObject private var selection = GalleryWindowController.shared.selection

    init(
        isPresented: Binding<Bool>,
        store: ShotStore = .shared,
        viewModel: GalleryViewModel? = nil
    ) {
        self._isPresented = isPresented
        self._store = ObservedObject(wrappedValue: store)
        let resolvedViewModel = viewModel
            ?? .resolve(for: store)
        self._viewModel = ObservedObject(wrappedValue: resolvedViewModel)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ScrollView 在 macOS 上会垫一层不透明的 windowBackgroundColor，
            // 不关掉会盖住面板自己的底色（两种灰打架）。
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topTrailing) {
                PanelCloseButton(label: "隐藏详情栏") { isPresented = false }
                    .padding(DS.s2)
            }
            .floatingPanel()
    }

    @ViewBuilder
    private var content: some View {
        let multi = multiSelectedShots
        if selection.isMultiple {
            MultiSelectionPane(shots: multi)
        } else if let shot = selectedShot ?? multi.first {
            ShotDetailPane(shot: shot)
        } else {
            ContentUnavailableView(
                "未选择截图",
                systemImage: "photo.on.rectangle",
                description: Text("在网格中选择一张截图查看详情")
            )
        }
    }

    private var selectedShot: Shot? {
        // 语义结果可能不在常规列表（最近 500 张）里，两边都找。
        viewModel.displayShots.first { $0.id == selection.primaryID }
            ?? store.shots.first { $0.id == selection.primaryID }
    }

    /// 多选时按展示顺序解析出的截图（选中集合里可能残留已删除的 ID，以解析结果为准）。
    private var multiSelectedShots: [Shot] {
        guard selection.isMultiple else { return [] }
        var picked = viewModel.displayShots.filter { selection.isSelected($0.id) }
        let seen = Set(picked.compactMap(\.id))
        picked += store.shots.filter { shot in
            guard let id = shot.id else { return false }
            return selection.selectedIDs.contains(id) && !seen.contains(id)
        }
        return picked
    }
}
