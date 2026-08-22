import SwiftUI
import AppKit

// MARK: - 自绘顶栏
//
// 取代系统工具栏。窗口是 fullSizeContentView + 透明标题栏 + 隐藏标题
//（见 GalleryWindowController），红绿灯浮在这条自绘内容上，位置留系统默认，
// 自绘内容从 `DS.Shell.trafficLightInset`(80) 才开始。
//
// 三段式：logo / 搜索胶囊 / 右侧控件组。顶栏自己**不画背景块** ——
// 它直接坐在窗口底色上（设计稿 §1）。
//
// ⚠️ 搜索框以前是靠 `sceneBridgingOptions = [.toolbars]` + `.searchable`
// 桥进 NSWindow 工具栏的。工具栏取消之后那条路没了，这里是搜索的**唯一实现**，
// 原来挂在 GalleryView 上的四件事一并搬了过来，一件都不许丢：
//   · 精确 / 语义两种模式（条件出现：设置开关 + CLIP 模型就绪）
//   · 语义模式下按回车才触发搜索，清空输入即恢复常规列表
//   · 精确模式下每次输入都 reload
//   · 退出语义模式时清掉语义结果

/// 图库显示模式。**与 `GalleryGrid` 里那个私有 `GalleryLayoutMode` 是同一份数据**
/// —— 两边用同一个 `@AppStorage("galleryLayout")` 键、同一组 rawValue，
/// UserDefaults 是它们唯一的真相，谁改了对方都会跟着变。
///
/// 之所以有两份**定义**：网格内部结构归后续的网格改版分支，这一轮不许动那个文件。
/// 等那一轮开始，第一件事就该是把这个枚举提成共享类型、删掉网格里的私有副本。
enum GalleryLayoutKind: String, CaseIterable {
    case grid
    case waterfall

    var symbol: String {
        switch self {
        case .grid:      return "square.grid.2x2"
        case .waterfall: return "square.grid.3x1.below.line.grid.1x2"
        }
    }

    var title: String {
        switch self {
        case .grid:      return "网格"
        case .waterfall: return "瀑布"
        }
    }
}

struct GalleryTopBar: View {

    /// 当前选中的顶层选项 id。真相在 `GalleryView` 的 @AppStorage 上。
    @Binding var destinationID: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 左侧占位：红绿灯避让区（不画内容，只留宽度）
            HStack {
                Spacer()
                Spacer()
            }
            .frame(width: DS.Shell.trafficLightInset)

            // tabs 绝对居中
            destinationTabs
        }
        .frame(maxWidth: .infinity)
        .frame(height: DS.Shell.topBarHeight)
        .layoutPriority(1)
    }

    // MARK: - 顶层选项

    /// 顶层选项（截图库 / 应用 / …）。**曾经是左侧一整条侧边栏**，
    /// 换到这里的账很直白：那条栏占 232pt + 12pt 缝，而卡片宽度约 228pt ——
    /// 它正好吃掉整整一列缩略图，永久地，换来的是两三个低频入口。
    /// 图库这类应用里横向空间是最稀缺的资源，而顶栏本来就在那儿，增量成本约等于零。
    ///
    /// 也顺手去掉了原来那个「Index」文字标 —— 它不提供任何信息，纯占位。
    ///
    /// 呈现方式换了，**契约没换**：仍然遍历同一份 `GalleryDestinationRegistry`，
    /// 每个选项的 `content()` / `inspector()` 一个字都没动。这正是把它抽成注册表的回报。
    ///
    /// 数量红线：分段控件在 5 个以内舒服，超过 6 个标签会挤成图标、可读性掉下去。
    /// 真到那一步该换回侧边栏 —— 同样只是换一个呈现，契约照旧。
    private var destinationTabs: some View {
        HStack(spacing: DS.s1 / 2) {
            ForEach(GalleryDestinationRegistry.shared.ordered(), id: \.id) { destination in
                DestinationTab(
                    title: destination.title,
                    symbol: destination.symbol,
                    isSelected: destinationID == destination.id
                ) {
                    destinationID = destination.id
                }
            }
        }
        .padding(DS.s1 / 2)
        .background(tabTrayFill, in: Capsule())
        .fixedSize()
    }

    private var tabTrayFill: Color {
        DS.trayFill(colorScheme)
    }
}

// MARK: - 单个选项标签

/// 顶栏上的一个选项。选中态用**实心的浅色底**（不是 accent 实心）：
/// 同屏只允许一处上强调色，而那一处归网格里的选中卡片
/// （见 docs/spatial-ui-spec.md §7.1）。图标 + 文字并排，不缩成纯图标 ——
/// 顶层导航要一眼可读，省下来的那点宽度不值。
private struct DestinationTab: View {

    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.s1) {
                Image(systemName: symbol)
                    .font(.system(size: DS.font12, weight: .medium))
                Text(title)
                    .font(.system(size: DS.font13, weight: isSelected ? .medium : .regular))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, DS.s3)
            .frame(height: DS.s4 + DS.s3)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 亮度阶梯那一套：深色加白、浅色加白（选中片浮在托盘底上，浅色下用纯白最清楚）。
    private var fill: Color {
        if isSelected {
            return DS.tabSelectedFill(scheme)
        }
        guard hovering else { return .clear }
        return DS.tabHoverFill(scheme)
    }
}

#if DEBUG
#Preview {
    // GalleryTopBar 预览：用 FakeStyleStore 验证 StyleStore 注入在 Preview 下可用
    let style: FakeStyleStore = {
        let s = FakeStyleStore()
        s.intelligence.semanticSearch = true
        s.upload.uploadEndpoint = "https://example.com/upload"
        return s
    }()
    VStack(spacing: 12) {
        Text("GalleryTopBar · StyleStore").font(.headline)
        Text("upload: \(style.upload.uploadEndpoint)").font(.caption).foregroundStyle(.secondary)
        Text("semantic: \(style.intelligence.semanticSearch ? "开" : "关")").font(.caption)
    }
    .padding()
    .frame(width: 400)
}
#endif
