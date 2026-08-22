import SwiftUI

/// 图库底部悬浮工具条（设计稿 §5）：居中悬浮的圆角胶囊，不再是贴底通栏。
/// 左边显示模式分段控件、右边缩放滑杆，中间留空（只有语义搜索状态会临时
/// 占用那段空白，见 `semanticStatus`）。
///
/// 从 `GalleryGrid` 拆成独立子视图：它只依赖两个偏好（显示模式 / 缩放，
/// 经 Binding 传入，键名仍归 GalleryGrid 的 @AppStorage 管）和 ViewModel
/// 的语义搜索状态，不碰网格的列宽数学与分页状态。
///
/// 三个落地取舍：
///
/// 1. **圆角用 `DS.radiusPanel`(14) 而不是设计稿的 16。** DS 的圆角阶梯是
///    6 / 10 / 14 / 18 五档，没有 16 那一档，而 GalleryShell 的 `floatingPanel`
///    文档本来就写着「小面板（图标轨、悬浮胶囊）用 `DS.radiusPanel`(14)」——
///    为了 2pt 新开一档 token 不值得（而且 DesignTokens 这一轮不许改）。
///
/// 2. **`level: .overlay`。** 这块是压在内容之上的，不是坐在窗口底色上：
///    底色亮一档、浅色下阴影更重，两者都是「它离用户更近」的线索。
///
/// 3. **只有两个图标，不是设计稿画的三个。** 理由见 `layoutPicker`。
struct GalleryFloatingToolbar: View {

    /// 设计稿 §5 的 540 × 56。宽度是**上限**不是定值 ——
    /// 窗口收到最小宽（1000）时中栏只剩 350 上下，写死 540 会横向溢出。
    /// 网格的底部让位高度（`contentBottomInset`）也读这里，两边同一份常量。
    static let barHeight: CGFloat = 56
    static let maxWidth: CGFloat = 540

    @ObservedObject var viewModel: GalleryViewModel
    /// 语义搜索命中数（`visibleShots.count`）——状态文案要报它。
    let visibleCount: Int
    @Binding var layoutMode: GalleryLayoutKind
    @Binding var zoom: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.s3) {
            layoutPicker
            Spacer(minLength: DS.s2)
            semanticStatus
            Spacer(minLength: DS.s2)
            zoomSlider
        }
        .padding(.horizontal, DS.s4)
        .frame(height: Self.barHeight)
        .frame(maxWidth: Self.maxWidth)
        .floatingPanel(radius: DS.radiusPanel, level: .overlay)
        // 12 + GalleryView 给中栏的 12(`DS.Shell.windowMargin`) = 距窗底 24（设计稿）。
        .padding(.bottom, DS.s3)
    }

    /// 显示模式分段控件。
    ///
    /// **设计稿画了三个图标（网格 / 分栏 / 列表），这里只有两个** —— 本项目真实存在的
    /// 布局就是网格与瀑布两种，为了凑数量摆一个点了没反应（或者和网格几乎一样）的
    /// 第三个图标是欺骗性 UI，比少一个图标糟得多。
    ///
    /// 「真的实现一个列表模式」在这一轮也做不成：`GalleryLayoutKind` 定义在
    /// `GalleryTopBar.swift`，加一个 case 会同时打断那个文件里 `symbol` / `title`
    /// 两个穷尽 switch，而那个文件本轮不在可改范围内。等它开放时再补，
    /// 届时顶栏的分段控件会自动多出一格（它是 `ForEach(allCases)` 驱动的）。
    ///
    /// 布局切换是「整片内容重排」，用 standard（0.35 / 0.85）：比系统默认的 0.55 利落，
    /// 又不像 micro 那样快到读不出内容是怎么挪的。动画包在 setter 的事务里而不是给网格
    /// 挂常驻 `.animation(value:)` —— 后者会让网格里任何一次尺寸变化（比如缩放滑杆）
    /// 都被顺带动画掉。
    private var layoutPicker: some View {
        Picker("显示模式", selection: Binding(
            get: { layoutMode },
            set: { newValue in
                withAnimation(DS.Motion.standard(reduced: reduceMotion)) { layoutMode = newValue }
            }
        )) {
            ForEach(GalleryLayoutKind.allCases, id: \.self) { kind in
                Image(systemName: kind.symbol).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("网格：整齐等高，超出裁切；瀑布：等宽不裁切，完整显示长图")
    }

    /// 缩放滑杆：左端小图标、中间滑杆、右端大图标（设计稿 §5）。
    /// 两个图标是「更多列 / 更少列」的图示，不是按钮 —— 语义上它们是滑杆两端的标尺。
    private var zoomSlider: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: DS.font10))
                .foregroundStyle(.tertiary)
            // maxWidth 而不是 width：窗口窄到中栏只剩几百点时，滑杆先让位，
            // 而不是把分段控件挤出胶囊。
            Slider(value: $zoom, in: 140...320)
                .frame(maxWidth: 200)
                .controlSize(.small)
                .accessibilityLabel("缩略图大小")
            Image(systemName: "square.grid.2x2")
                .font(.system(size: DS.font13))
                .foregroundStyle(.tertiary)
        }
        .help("缩略图大小")
    }

    /// 语义搜索状态。设计稿的胶囊里没有这一段，但**它是唯一能报告「正在跑语义搜索」
    /// 的地方**，删不得（设计稿没画的功能不许删）。占的是两组控件之间那段留白 ——
    /// 平时空着，有话说时才出现，不改变两组控件的位置。
    ///
    /// 旧底栏那句「N 张截图」没有搬过来：`GalleryPageHeader` 的「N 个项目」是同一个
    /// `viewModel.displayShots.count`，同屏两处报同一个数是冗余。
    @ViewBuilder
    private var semanticStatus: some View {
        if viewModel.isSemanticSearching {
            HStack(spacing: DS.s2) {
                ProgressView().controlSize(.mini)
                Text("语义搜索中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if viewModel.semanticMode, viewModel.semanticResults != nil {
            Text("语义搜索：最相关的 \(visibleCount) 张")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}