import SwiftUI

// MARK: - 内建选项
//
// 目前三个：图库、录屏、应用。后续要加（暂存、回收站…）在这里各写一个类型、
// 在 `registerBuiltins` 里加一行。

/// 内容库子 Tab 的轻量会话状态。
///
/// `@AppStorage` 的 setter 会在按钮动作里同步写 UserDefaults，并让内容区与
/// Inspector 的两个 property wrapper 分别失效。子 Tab 是高频交互，先发布内存状态，
/// 等首帧提交后再持久化，避免把磁盘偏好写入塞进点击响应帧。
@MainActor
private final class ContentLibraryTabSelection: ObservableObject {
    @Published fileprivate var value: String

    init(_ value: String) { self.value = value }
}

@MainActor
private final class ContentLibraryDisplayedTab: ObservableObject {
    @Published fileprivate var value: String

    init(_ value: String) { self.value = value }
}

@MainActor
private final class ContentLibraryTabSession {
    static let shared = ContentLibraryTabSession()

    let selection: ContentLibraryTabSelection
    let displayed: ContentLibraryDisplayedTab

    private let defaults: UserDefaults
    private var transitionTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "contentLibrarySubTab")
        let initial = ["shots", "recordings", "clipboard", "ai"].contains(saved ?? "")
            ? saved!
            : "shots"
        selection = ContentLibraryTabSelection(initial)
        displayed = ContentLibraryDisplayedTab(initial)
    }

    func select(_ id: String) {
        guard id != selection.value else { return }

        // 第一帧只更新四个小按钮，立刻给出按下反馈。大页面与 Inspector 的替换
        // 放到下一帧，避免 100–200 ms 的页面布局阻塞选中胶囊出现。
        selection.value = id
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            // 留出至少两个 60 Hz 帧，让选中胶囊真正提交到 WindowServer；16 ms
            // 在复杂窗口里可能和当前布局事务重叠，仍会被后续大页面创建拖住。
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self, self.selection.value == id else { return }
            self.displayed.value = id

            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, self.selection.value == id else { return }
            self.defaults.set(id, forKey: "contentLibrarySubTab")
        }
    }
}

/// 内容库：截图/录屏/剪切板/AI 对话的统一入口。这是默认落点。
struct LibraryDestination: GalleryDestination {

    static let destinationID = "destination.library"

    let id = Self.destinationID
    let title = "内容库"
    let symbol = "square.grid.2x2"
    let order = 0

    func badge(reader: ShotReading = ShotStore.shared) -> Int? {
        let count = reader.totalCount
        return count > 0 ? count : nil
    }

    func badge() -> Int? { badge(reader: ShotStore.shared) }

    func content() -> AnyView {
        AnyView(ContentLibraryView())
    }

    /// 详情面板的开关是用户偏好，所以这里恒定返回面板，由容器按偏好决定显不显示。
    func inspector() -> AnyView? {
        AnyView(ContentLibraryInspectorPanelHost())
    }
}

/// 内容库的中间区和 Inspector 是兄弟子树，因此 Inspector 必须按同一个子 Tab
/// 切换。剪贴板使用自己的详情面板；截图和录屏继续使用图库详情面板。
private struct ContentLibraryInspectorPanelHost: View {
    @AppStorage("galleryInspectorShown") private var showInspector = true
    @ObservedObject private var displayedTab = ContentLibraryTabSession.shared.displayed

    @ViewBuilder
    var body: some View {
        if displayedTab.value == "clipboard" {
            ClipboardInspectorPanel(isPresented: $showInspector)
        } else {
            GalleryInspectorPanel(isPresented: $showInspector)
        }
    }
}

// MARK: - 内容库（子 tab 切换）

/// 内容库的中间内容：子 tab 栏（截图/录屏/剪切板/AI 对话）+ 对应内容。
struct ContentLibraryView: View {

    @ObservedObject private var tabSelection = ContentLibraryTabSession.shared.selection
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var viewModel = GalleryViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            // 子 tab 栏
            HStack(spacing: DS.s1 / 2) {
                subTabButton("shots", title: "截图", symbol: "photo")
                subTabButton("recordings", title: "录屏", symbol: "play.rectangle")
                subTabButton("clipboard", title: "剪切板", symbol: "doc.on.clipboard")
                subTabButton("ai", title: "AI 对话", symbol: "bubble.left.and.bubble.right")
            }
            .padding(DS.s1 / 2)
            .background(DS.trayFill(colorScheme), in: Capsule())
            .padding(.horizontal, DS.s5)
            .padding(.top, DS.s4)
            .padding(.bottom, DS.s2)

            ContentLibraryPageHost(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .floatingPanel()
    }

    private func subTabButton(_ id: String, title: String, symbol: String) -> some View {
        Button {
            ContentLibraryTabSession.shared.select(id)
        } label: {
            HStack(spacing: DS.s1) {
                Image(systemName: symbol)
                    .font(.system(size: DS.font12, weight: .medium))
                Text(title)
                    .font(.system(size: DS.font13, weight: tabSelection.value == id ? .medium : .regular))
            }
            .foregroundStyle(tabSelection.value == id ? Color.primary : Color.secondary)
            .padding(.horizontal, DS.s3)
            .frame(height: DS.s4 + DS.s3)
            .background(
                tabSelection.value == id ? DS.accentFillSelected : .clear,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 大页面只观察延后一帧发布的 displayedTab。按钮选中态更新时这个子树保持稳定，
/// 从而先把点击反馈提交给 WindowServer，再开始较重的页面布局。
private struct ContentLibraryPageHost: View {
    @ObservedObject private var displayedTab = ContentLibraryTabSession.shared.displayed
    @ObservedObject var viewModel: GalleryViewModel

    @ViewBuilder
    var body: some View {
        Group {
            if displayedTab.value == "clipboard" {
                ClipboardContent()
            } else if displayedTab.value == "ai" {
                AgentConversationListView()
            } else {
                MediaLibraryContent(
                    scope: displayedTab.value == "recordings" ? .recordings : .library,
                    viewModel: viewModel
                )
            }
        }
        .task { activateSubTabScope() }
        .onChange(of: displayedTab.value) { _, _ in activateSubTabScope() }
    }

    private func activateSubTabScope() {
        if displayedTab.value == "recordings" {
            GalleryContentScope.recordings.activate(in: viewModel)
        } else {
            GalleryContentScope.recordings.deactivate(in: viewModel)
        }
    }
}

/// 截图与录屏共用同一个结构身份，只改变 scope。两者来回切换时保留 GalleryGrid
/// 的 StateObject、滚动位置与缩略图缓存，不再销毁后重建整棵网格。
private struct MediaLibraryContent: View {
    @ObservedObject private var store: ShotStore
    @ObservedObject private var viewModel: GalleryViewModel
    let scope: GalleryContentScope

    init(
        store: ShotStore = .shared,
        scope: GalleryContentScope,
        viewModel: GalleryViewModel? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        let resolvedViewModel = viewModel
            ?? .resolve(for: store)
        _viewModel = ObservedObject(wrappedValue: resolvedViewModel)
        self.scope = scope
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scope == .library ? 0 : DS.s3) {
            if scope == .library {
                GalleryPageHeader(
                    store: store,
                    viewModel: viewModel,
                    scope: scope,
                    style: .libraryPanel
                )
                .padding(.horizontal, DS.s5)
                .padding(.top, DS.s5)
                .padding(.bottom, DS.s2)
            } else {
                GalleryPageHeader(store: store, viewModel: viewModel, scope: scope)
                    .padding(.horizontal, DS.s2)
            }
            GalleryGrid(
                store: store,
                viewModel: viewModel,
                scope: scope,
                chrome: scope == .library ? .libraryPanel : .standard
            )
        }
        .modifier(MediaLibraryPanelModifier(isLibrary: scope == .library))
    }
}

private struct MediaLibraryPanelModifier: ViewModifier {
    let isLibrary: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLibrary { content.floatingPanel() } else { content }
    }
}

// ============================================================

extension GalleryDestinationRegistry {

    /// 登记处。`AppDelegate` 启动时调一次。
    /// 录屏和剪切板已并入内容库的子 tab，不再作为顶层 destination。
    static func registerBuiltins(into registry: GalleryDestinationRegistry) {
        registry.register(LibraryDestination())
        registry.register(CollectionsDestination())
        registry.register(AppsDestination())
    }
}
