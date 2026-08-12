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
    /// 当前选中的顶层选项 id。真相在 `GalleryView` 的 @AppStorage 上。
    @Binding var destinationID: String

    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject private var viewModel: GalleryViewModel

    init(
        showInspector: Binding<Bool>,
        destinationID: Binding<String>,
        viewModel: GalleryViewModel = .shared,
        settings: AppSettings = .shared
    ) {
        self._showInspector = showInspector
        self._destinationID = destinationID
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._settings = ObservedObject(wrappedValue: settings)
    }
    // 语义模式切换只在「开关已开 + 模型已就绪」时出现，所以要订阅这两个。
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var modelStore = CLIPModelStore.shared
    @ObservedObject private var imageImporter = ImageImportCoordinator.shared
    @ObservedObject private var appsNavigation = AppsNavigationState.shared
    @ObservedObject private var collectionsNavigation = CollectionsNavigationState.shared

    @AppStorage("galleryLayout") private var layout = GalleryLayoutKind.grid
    @AppStorage("galleryZoom") private var zoom = 200.0

    /// ⌘K 的落点。
    @FocusState private var searchFocused: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var semanticAvailable: Bool {
        settings.semanticSearch && modelStore.isReady
    }

    var body: some View {
        HStack(spacing: DS.s3) {
            destinationTabs

            // minLength 让搜索框在窄窗口下先让位，而不是把右侧控件挤出窗口。
            Spacer(minLength: DS.s3)
            searchField
            Spacer(minLength: DS.s3)

            rightControls
        }
        .padding(.leading, DS.Shell.trafficLightInset)
        .padding(.trailing, DS.Shell.windowMargin)
        .frame(height: DS.Shell.topBarHeight)
        .onChange(of: viewModel.searchText) { _, newValue in
            if viewModel.semanticMode {
                // 语义搜索按回车触发；清空输入即恢复常规列表。
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    viewModel.clearSemanticResults()
                }
            } else {
                viewModel.reload()
            }
        }
        .onChange(of: viewModel.semanticMode) { _, semantic in
            if !semantic { viewModel.clearSemanticResults() }
        }
    }

    // MARK: - 顶层选项

    /// 顶层选项（截图库 / 应用 / …）。**曾经是左侧一整条侧边栏**，
    /// 换到这里的账很直白：那条栏占 232pt + 12pt 缝，而卡片宽度约 228pt ——
    /// 它正好吃掉整整一列缩略图，永久地，换来的是两三个低频入口。
    /// 图库这类应用里横向空间是最稀缺的资源，而顶栏本来就在那儿，增量成本约等于零。
    ///
    /// 也顺手去掉了原来那个「MacShot」文字标 —— 它不提供任何信息，纯占位。
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
            // 焦点环收到 1.5pt / 0.55 透明度：原来的 2pt 实色 accent 在浅色下
            // 是整个窗口最抢眼的东西，而它只是「光标在这儿」，不该压过内容的选中态。
            Capsule().strokeBorder(
                searchFocused ? DS.accentStrokeFocus : capsuleStroke,
                lineWidth: searchFocused ? 1.5 : 1
            )
            .allowsHitTesting(false)
        }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: searchFocused)
    }

    private var searchContent: some View {
        HStack(spacing: DS.s2) {
            searchScope

            TextField("搜索", text: $viewModel.searchText, prompt: Text(searchPrompt))
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit {
                    // 语义搜索是「一次编码 + 全库比对」，只在回车时跑。
                    guard viewModel.semanticMode else { return }
                    Task { await viewModel.runSemanticSearch() }
                }

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
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
        viewModel.semanticMode
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
                Picker("搜索模式", selection: $viewModel.semanticMode) {
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
                .foregroundStyle(viewModel.semanticMode ? AnyShapeStyle(DS.accent)
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
        viewModel.semanticMode ? "sparkle.magnifyingglass" : "magnifyingglass"
    }

    private var shortcutBadge: some View {
        Text("⌘K")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, DS.s1 + 1)
            .padding(.vertical, DS.s1 / 2)
            .background(
                DS.badgeFill(scheme),
                in: RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var capsuleFill: Color {
        DS.capsuleFill(scheme)
    }

    private var capsuleStroke: Color {
        DS.capsuleStroke(scheme)
    }

    // MARK: - 右侧控件

    private var rightControls: some View {
        HStack(spacing: DS.s2) {
            if destinationID == LibraryDestination.destinationID {
                importButton
            }
            if showsPrimaryCaptureButton {
                captureButton
            }
            if showsGridControls {
                layoutPicker
            }
            if showsInspectorToggle {
                inspectorToggle
            }
            moreMenu
        }
        .fixedSize()
    }

    private var showsPrimaryCaptureButton: Bool {
        destinationID == LibraryDestination.destinationID
            || destinationID == AppsDestination.destinationID
            || destinationID == CollectionsDestination.destinationID
    }

    private var showsGridControls: Bool {
        if destinationID == AppsDestination.destinationID { return appsNavigation.isDrilled }
        if destinationID == CollectionsDestination.destinationID { return collectionsNavigation.isDrilled }
        return true
    }

    private var showsInspectorToggle: Bool {
        if destinationID == AppsDestination.destinationID { return appsNavigation.isDrilled }
        if destinationID == CollectionsDestination.destinationID { return collectionsNavigation.isDrilled }
        return true
    }

    /// 截图是图库页的主任务，不能再藏在齿轮菜单里。只在图库 destination 提升为
    /// 蓝色主按钮，录屏与应用页的结构先保持不变。
    private var captureButton: some View {
        Button {
            CaptureCoordinator.shared.begin()
        } label: {
            Label("截图", systemImage: "viewfinder")
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .help("开始截图（⌃⌘A）")
        .accessibilityLabel("开始截图")
    }

    private var importButton: some View {
        Button {
            guard let urls = SystemNavigator.chooseImageFiles(), !urls.isEmpty else { return }
            viewModel.reset()
            imageImporter.enqueue(urls)
        } label: {
            if imageImporter.isImporting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("导入", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(imageImporter.isImporting)
        .help("导入本地图片")
        .accessibilityLabel(imageImporter.isImporting ? "正在导入图片" : "导入图片")
    }

    // 顶栏曾经还有一个漏斗菜单（全部/收藏/未加标签/已标注 + 清除筛选）。
    // 那四项在侧边栏「资料库」组里一模一样地列着，是同一份 `store.filter`
    // 的第三个入口 —— 连同页头那行下拉胶囊一起删掉了。
    // 现在：选择只在侧边栏，清除在页头标题旁的 ✕。

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

    /// 第一版设计把低频项收进省略号菜单。图库页的截图动作已经提升成主按钮，
    /// 这里改为承接缩略图大小与设置；其他 destination 暂时仍保留截图入口。
    private var moreMenu: some View {
        Menu {
            if destinationID == LibraryDestination.destinationID
                || (destinationID == AppsDestination.destinationID && appsNavigation.isDrilled)
                || (destinationID == CollectionsDestination.destinationID
                    && collectionsNavigation.isDrilled) {
                Picker("缩略图大小", selection: $zoom) {
                    Text("小").tag(160.0)
                    Text("中").tag(220.0)
                    Text("大").tag(300.0)
                }
                .pickerStyle(.inline)
            } else if !showsPrimaryCaptureButton {
                Button("开始截图") { CaptureCoordinator.shared.begin() }
            }
            Divider()
            Button("设置…") { openSettings() }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.shellIcon)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    // MARK: - 动作

    /// 设置是本窗口的一个模式（不再是独立窗口），所以直接切模式 ——
    /// 此前要绕 AppKit 响应链去找 AppDelegate 开窗，那条路连同两个
    /// 只为取 selector 的 @objc 协议一起删掉了。
    private func openSettings() {
        GalleryWindowMode.shared.openSettings()
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
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
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
        s.semanticSearch = true
        s.uploadEndpoint = "https://example.com/upload"
        return s
    }()
    VStack(spacing: 12) {
        Text("GalleryTopBar · StyleStore").font(.headline)
        Text("upload: \(style.uploadEndpoint)").font(.caption).foregroundStyle(.secondary)
        Text("semantic: \(style.semanticSearch ? "开" : "关")").font(.caption)
    }
    .padding()
    .frame(width: 400)
}
#endif
