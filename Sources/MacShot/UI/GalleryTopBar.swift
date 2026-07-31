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

    /// 详情栏开关。真相在 GalleryView 的 @AppStorage 上，这里只是它的一个入口。
    @Binding var showInspector: Bool

    @ObservedObject private var store = ShotStore.shared
    // 语义模式切换只在「开关已开 + 模型已就绪」时出现，所以要订阅这两个。
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var modelStore = CLIPModelStore.shared

    @AppStorage("galleryLayout") private var layout = GalleryLayoutKind.grid

    /// ⌘K 的落点。
    @FocusState private var searchFocused: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var semanticAvailable: Bool {
        settings.semanticSearch && modelStore.isReady
    }

    /// 「现在是不是筛着的」—— 决定漏斗按钮要不要点亮、「清除筛选」要不要可点。
    private var hasActiveFilter: Bool {
        store.filter != .all
            || !store.searchText.isEmpty
            || (store.semanticMode && store.semanticResults != nil)
    }

    var body: some View {
        HStack(spacing: DS.s3) {
            Text("MacShot")
                .font(.system(size: 17, weight: .semibold))
                .fixedSize()

            // minLength 让搜索框在窄窗口下先让位，而不是把右侧控件挤出窗口。
            Spacer(minLength: DS.s3)
            searchField
            Spacer(minLength: DS.s3)

            rightControls
        }
        .padding(.leading, DS.Shell.trafficLightInset)
        .padding(.trailing, DS.Shell.windowMargin)
        .frame(height: DS.Shell.topBarHeight)
        .onChange(of: store.searchText) { _, newValue in
            if store.semanticMode {
                // 语义搜索按回车触发；清空输入即恢复常规列表。
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.clearSemanticResults()
                }
            } else {
                store.reload()
            }
        }
        .onChange(of: store.semanticMode) { _, semantic in
            if !semantic { store.clearSemanticResults() }
        }
    }

    // MARK: - 搜索胶囊

    private var searchField: some View {
        // ZStack 而不是「胶囊 + `.background { Button }`」：background 里的按钮会被
        // 前面那层胶囊填充挡住命中（填充的 Shape 本身是可命中的），点空白处就不聚焦了。
        // 焦点按钮必须和内容在同一个 ZStack 里、垫在内容**下面**，
        // 胶囊填充再垫在整个 ZStack 后面。
        ZStack {
            // ⌘K 的实际接收者，同时兼作「点胶囊空白处也能聚焦」的命中区。
            Button {
                searchFocused = true
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("搜索截图")

            searchContent
        }
        .padding(.horizontal, DS.s3)
        .frame(maxWidth: DS.Shell.searchWidth)
        .frame(height: DS.Shell.searchHeight)
        .background(capsuleFill, in: Capsule())
        // 聚焦环：plain 样式的 TextField 自己不画焦点环，而「焦点必须可见」
        // 是无障碍硬要求（WCAG 2.4.13），所以由胶囊的描边承担。
        // `allowsHitTesting(false)`：描边是最前面一层，不关掉会吃掉落在描边上的点击。
        .overlay {
            Capsule().strokeBorder(
                searchFocused ? Color.accentColor.opacity(0.85) : capsuleStroke,
                lineWidth: searchFocused ? 2 : 1
            )
            .allowsHitTesting(false)
        }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: searchFocused)
    }

    private var searchContent: some View {
        HStack(spacing: DS.s2) {
            searchScope

            TextField("搜索", text: $store.searchText, prompt: Text(searchPrompt))
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit {
                    // 语义搜索是「一次编码 + 全库比对」，只在回车时跑。
                    guard store.semanticMode else { return }
                    Task { await store.runSemanticSearch() }
                }

            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            } else if !searchFocused {
                // ⌘K 徽章只在「没聚焦、也没输入」时出现 —— 它是提示，不是装饰。
                shortcutBadge
            }
        }
    }

    private var searchPrompt: String {
        store.semanticMode
            ? "描述画面内容，回车搜索（英文效果最好）"
            : "搜 App、标题、网址或截图里的字"
    }

    /// 胶囊左端的放大镜。语义搜索可用时它变成**搜索范围菜单** ——
    /// 这正是 AppKit `NSSearchField` 的原生位置（带小三角的放大镜 = scope 菜单），
    /// 比在顶栏另开一个分段控件更省地方，也更符合用户对搜索框的预期。
    @ViewBuilder
    private var searchScope: some View {
        if semanticAvailable {
            Menu {
                Picker("搜索模式", selection: $store.semanticMode) {
                    Text("精确匹配").tag(false)
                    Text("语义搜索").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 1) {
                    Image(systemName: scopeSymbol)
                        .font(.system(size: 13))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(store.semanticMode ? AnyShapeStyle(Color.accentColor)
                                                    : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("精确：全文匹配文字与元数据；语义：用自然语言描述画面，按回车搜索")
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var scopeSymbol: String {
        store.semanticMode ? "sparkle.magnifyingglass" : "magnifyingglass"
    }

    private var shortcutBadge: some View {
        Text("⌘K")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                in: RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var capsuleFill: Color {
        scheme == .dark ? .white.opacity(0.07) : .black.opacity(0.05)
    }

    private var capsuleStroke: Color {
        scheme == .dark ? .white.opacity(0.10) : .black.opacity(0.10)
    }

    // MARK: - 右侧控件

    private var rightControls: some View {
        HStack(spacing: DS.s2) {
            filterMenu
            layoutPicker
            inspectorToggle
            moreMenu
        }
        .fixedSize()
    }

    /// 漏斗 = 「资料库」那几个不在胶囊行里的智能入口 + 一键清除。
    /// 与筛选胶囊行（最近 / 应用 / 类型 / 标签）不重复：那四个管维度，这个管整体。
    private var filterMenu: some View {
        Menu {
            Picker("资料库", selection: filterBinding) {
                Label("全部截图", systemImage: "square.grid.2x2").tag(ShotStore.GalleryFilter.all)
                Label("收藏", systemImage: "star").tag(ShotStore.GalleryFilter.favorites)
                Label("未加标签", systemImage: "tag.slash").tag(ShotStore.GalleryFilter.untagged)
                Label("已标注", systemImage: "pencil").tag(ShotStore.GalleryFilter.annotated)
            }
            .pickerStyle(.inline)

            Divider()

            Button("清除筛选") { clearFilters() }
                .disabled(!hasActiveFilter)
        } label: {
            Image(systemName: hasActiveFilter
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.shellIcon(active: hasActiveFilter))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(hasActiveFilter ? "正在筛选 —— 点开可清除" : "筛选")
    }

    /// 网格 / 瀑布切换。和网格底栏那个分段控件是**同一个** @AppStorage 键，
    /// 两处任意一处切换，另一处立刻跟上（UserDefaults 是唯一真相）。
    private var layoutPicker: some View {
        Picker("显示模式", selection: Binding(
            get: { layout },
            set: { newValue in
                withAnimation(DS.Motion.standard(reduced: reduceMotion)) { layout = newValue }
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

    private var inspectorToggle: some View {
        Button {
            // 不在这里包 withAnimation：开合动画由 GalleryView 上那条
            // `.animation(_:value: showInspector)` 统一负责，
            // 面板自己右上角的 ✕ 走的也是它 —— 两个入口一种曲线。
            showInspector.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
        }
        .buttonStyle(.shellIcon(active: showInspector))
        .help(showInspector ? "隐藏详情栏" : "显示详情栏")
        .accessibilityLabel("详情栏")
    }

    /// 设计稿这个位置画的是头像 + 小三角。本项目没有账号体系，画一个假头像是
    /// 欺骗性 UI（承诺一个不存在的功能），换成「更多」齿轮菜单。
    private var moreMenu: some View {
        Menu {
            Button("开始截图") { CaptureCoordinator.shared.begin() }
            Divider()
            Button("设置…") { openSettings() }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.button)
        .buttonStyle(.shellIcon)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    // MARK: - 动作

    /// 筛选写回 store 并重查。侧边栏走的是同一个 `store.filter`，
    /// 所以这里选完侧边栏会跟着高亮 —— 两边是同一个真相，不是两份状态。
    private var filterBinding: Binding<ShotStore.GalleryFilter> {
        Binding(
            get: { store.filter },
            set: { newValue in
                store.filter = newValue
                store.reload()
            }
        )
    }

    private func clearFilters() {
        store.searchText = ""
        store.filter = .all
        store.clearSemanticResults()
        store.reload()
    }

    /// 设置是本窗口的一个模式（不再是独立窗口），所以直接切模式 ——
    /// 此前要绕 AppKit 响应链去找 AppDelegate 开窗，那条路连同两个
    /// 只为取 selector 的 @objc 协议一起删掉了。
    private func openSettings() {
        GalleryWindowMode.shared.openSettings()
    }
}
