import SwiftUI

// MARK: - 内建选项
//
// 目前三个：图库、录屏、应用。后续要加（暂存、回收站…）在这里各写一个类型、
// 在 `registerBuiltins` 里加一行。

/// 内容库子 Tab 的稳定标识。UI、scope 与持久化只传这个类型，不再传裸字符串。
enum ContentLibraryTab: String, CaseIterable {
    case shots
    case recordings
    case clipboard
    case ai

    /// 当前子页真正能消费的窗口级控件。能力跟着子 Tab 走，外壳不再把
    /// LibraryDestination 一律当成截图图库。
    var destinationChrome: GalleryDestinationChrome {
        switch self {
        case .shots:      return .library
        case .recordings: return .recordings
        case .clipboard:  return .clipboard
        case .ai:         return .conversation
        }
    }
}

/// 内容库中间页与 Inspector 共用的轻量会话。
///
/// 点击时只发布一次内存状态，页面与 Inspector 在同一轮更新；UserDefaults 延后写入，
/// 避免把偏好持久化塞进点击响应帧。实例可以注入，Preview 与测试不必借用全局状态。
@MainActor
final class ContentLibrarySession: ObservableObject {
    static let shared = ContentLibrarySession()

    static let defaultsKey = "contentLibrarySubTab"

    @Published private(set) var tab: ContentLibraryTab

    private let defaults: UserDefaults
    private var persistenceTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tab = defaults.string(forKey: Self.defaultsKey)
            .flatMap(ContentLibraryTab.init(rawValue:))
            ?? .shots
    }

    func select(_ tab: ContentLibraryTab) {
        guard tab != self.tab else { return }

        // 按钮、页面、Inspector 只观察这一份状态，因此不会出现按钮已经切换、
        // 页面仍停在旧 tab 的过渡帧。
        self.tab = tab
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self, self.tab == tab else { return }
            self.defaults.set(tab.rawValue, forKey: Self.defaultsKey)
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
    private let session: ContentLibrarySession
    private let clipboardSession: ClipboardPageSession

    /// 首帧直接读取恢复后的子 Tab，避免 `.task` 发布 override 前先闪出截图工具或详情栏。
    var defaultChrome: GalleryDestinationChrome { session.tab.destinationChrome }

    init(
        session: ContentLibrarySession? = nil,
        clipboardSession: ClipboardPageSession? = nil
    ) {
        self.session = session ?? .shared
        self.clipboardSession = clipboardSession ?? ClipboardPageSession()
    }

    func badge(reader: ShotReading) -> Int? {
        let count = reader.totalCount
        return count > 0 ? count : nil
    }

    func badge(context: GalleryDestinationContext) -> Int? { badge(reader: context.store) }

    func content(context: GalleryDestinationContext) -> AnyView {
        AnyView(ContentLibraryView(
            session: session,
            clipboardSession: clipboardSession,
            store: context.store,
            viewModel: context.viewModel,
            destinationChrome: context.chrome
        ))
    }

    /// 详情面板的开关是用户偏好，所以这里恒定返回面板，由容器按偏好决定显不显示。
    func inspector(context: GalleryDestinationContext) -> AnyView? {
        AnyView(ContentLibraryInspectorPanelHost(
            session: session,
            clipboardSession: clipboardSession,
            store: context.store,
            viewModel: context.viewModel
        ))
    }
}

/// 内容库的中间区和 Inspector 是兄弟子树，因此 Inspector 必须按同一个子 Tab
/// 切换。剪贴板使用自己的详情面板；截图和录屏继续使用图库详情面板。
private struct ContentLibraryInspectorPanelHost: View {
    @AppStorage(PagePreferences.galleryInspectorShown.key)
    private var showInspector = PagePreferences.galleryInspectorShown.defaultValue
    @ObservedObject private var session: ContentLibrarySession
    @ObservedObject private var clipboardSession: ClipboardPageSession
    let store: ShotStore
    let viewModel: GalleryViewModel

    init(
        session: ContentLibrarySession,
        clipboardSession: ClipboardPageSession,
        store: ShotStore,
        viewModel: GalleryViewModel
    ) {
        _session = ObservedObject(wrappedValue: session)
        _clipboardSession = ObservedObject(wrappedValue: clipboardSession)
        self.store = store
        self.viewModel = viewModel
    }

    @ViewBuilder
    var body: some View {
        switch session.tab {
        case .clipboard:
            ClipboardInspectorPanel(isPresented: $showInspector, session: clipboardSession)
        case .shots, .recordings:
            GalleryInspectorPanel(isPresented: $showInspector, store: store, viewModel: viewModel)
        case .ai:
            EmptyView()
        }
    }
}

// MARK: - 内容库（子 tab 切换）

/// 内容库的中间内容：子 tab 栏（截图/录屏/剪切板/AI 对话）+ 对应内容。
struct ContentLibraryView: View {

    @ObservedObject private var session: ContentLibrarySession
    @ObservedObject private var clipboardSession: ClipboardPageSession
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var selection: GallerySelection
    private let store: ShotStore
    @ObservedObject private var viewModel: GalleryViewModel
    private let destinationChrome: GalleryDestinationChromeState

    init(
        session: ContentLibrarySession = .shared,
        clipboardSession: ClipboardPageSession = .shared,
        store: ShotStore,
        viewModel: GalleryViewModel,
        destinationChrome: GalleryDestinationChromeState
    ) {
        _session = ObservedObject(wrappedValue: session)
        _clipboardSession = ObservedObject(wrappedValue: clipboardSession)
        self.store = store
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.destinationChrome = destinationChrome
    }

    var body: some View {
        VStack(spacing: 0) {
            // 子 tab 栏
            HStack(spacing: DS.s1 / 2) {
                subTabButton(.shots, title: "截图", symbol: "photo")
                subTabButton(.recordings, title: "录屏", symbol: "play.rectangle")
                subTabButton(.clipboard, title: "剪切板", symbol: "doc.on.clipboard")
                subTabButton(.ai, title: "AI 对话", symbol: "bubble.left.and.bubble.right")
            }
            .padding(DS.s1 / 2)
            .background(DS.trayFill(colorScheme), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.s5)
            .padding(.top, DS.s3)
            .padding(.bottom, DS.s2)

            ContentLibraryPageHost(
                session: session,
                clipboardSession: clipboardSession,
                store: store,
                viewModel: viewModel,
                destinationChrome: destinationChrome
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .floatingPanel()
        // 只读 100 条轻量会话元数据并缓存在窗口级 session。用户第一次点击
        // AI 对话时通常已经就绪；页面本身的 task 仍保留作兜底。
        .task { await AgentConversationListSession.shared.loadIfNeeded() }
    }

    private func subTabButton(_ tab: ContentLibraryTab, title: String, symbol: String) -> some View {
        Button {
            select(tab)
        } label: {
            HStack(spacing: DS.s1) {
                Image(systemName: symbol)
                    .font(.system(size: DS.font12, weight: .medium))
                Text(title)
                    .font(.system(size: DS.font13, weight: session.tab == tab ? .medium : .regular))
            }
            .foregroundStyle(session.tab == tab ? Color.primary : Color.secondary)
            .padding(.horizontal, DS.s3)
            .frame(height: DS.s4 + DS.s3)
            .background(
                session.tab == tab ? DS.accentFillSelected : .clear,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 点击路径必须先准备目标页的数据范围和 chrome，再发布 tab。
    /// SwiftUI 会把同一个按钮 action 里的同步写入合并到一轮事务，因此首帧
    /// 直接拿到目标状态，不会先画一帧上一页数据再异步纠正。
    private func select(_ tab: ContentLibraryTab) {
        guard tab != session.tab else { return }
        if selection.primaryID != nil || !selection.selectedIDs.isEmpty {
            selection.select(only: nil)
        }
        if tab == .recordings {
            GalleryContentScope.recordings.activate(in: viewModel)
        } else {
            GalleryContentScope.recordings.deactivate(in: viewModel)
        }
        destinationChrome.set(tab.destinationChrome, for: LibraryDestination.destinationID)
        session.select(tab)
    }
}

/// 大页面观察内存态；持久化不会阻塞页面切换。
private struct ContentLibraryPageHost: View {
    @ObservedObject private var session: ContentLibrarySession
    @ObservedObject private var clipboardSession: ClipboardPageSession
    let store: ShotStore
    @ObservedObject var viewModel: GalleryViewModel
    let destinationChrome: GalleryDestinationChromeState
    @EnvironmentObject private var selection: GallerySelection

    init(
        session: ContentLibrarySession,
        clipboardSession: ClipboardPageSession,
        store: ShotStore,
        viewModel: GalleryViewModel,
        destinationChrome: GalleryDestinationChromeState
    ) {
        _session = ObservedObject(wrappedValue: session)
        _clipboardSession = ObservedObject(wrappedValue: clipboardSession)
        self.store = store
        self.viewModel = viewModel
        self.destinationChrome = destinationChrome
    }

    @ViewBuilder
    var body: some View {
        Group {
            if session.tab == .clipboard {
                ClipboardContent(session: clipboardSession)
            } else if session.tab == .ai {
                AgentConversationListView()
            } else {
                MediaLibraryContent(
                    store: store,
                    scope: session.tab == .recordings ? .recordings : .library,
                    viewModel: viewModel
                )
            }
        }
        .task { apply(tab: session.tab, clearsSelection: false) }
        .onChange(of: session.tab) { oldTab, newTab in
            guard oldTab != newTab else { return }
            apply(tab: newTab, clearsSelection: true)
        }
        .onDisappear {
            destinationChrome.clear(for: LibraryDestination.destinationID)
        }
    }

    private func apply(tab: ContentLibraryTab, clearsSelection: Bool) {
        if clearsSelection,
           selection.primaryID != nil || !selection.selectedIDs.isEmpty {
            // 截图与录屏使用同一 Selection，但可见集合不同。跨子页保留旧 ID
            // 会让 Inspector 在新页面短暂展示上一页详情；一次事务清空最稳妥。
            selection.select(only: nil)
        }

        if tab == .recordings {
            GalleryContentScope.recordings.activate(in: viewModel)
        } else {
            GalleryContentScope.recordings.deactivate(in: viewModel)
        }
        destinationChrome.set(tab.destinationChrome, for: LibraryDestination.destinationID)
    }
}

/// 截图与录屏共用同一个结构身份，只改变 scope。两者来回切换时保留 GalleryGrid
/// 的 StateObject、滚动位置与缩略图缓存，不再销毁后重建整棵网格。
private struct MediaLibraryContent: View {
    @ObservedObject private var store: ShotStore
    @ObservedObject private var viewModel: GalleryViewModel
    let scope: GalleryContentScope

    init(
        store: ShotStore,
        scope: GalleryContentScope,
        viewModel: GalleryViewModel
    ) {
        _store = ObservedObject(wrappedValue: store)
        _viewModel = ObservedObject(wrappedValue: viewModel)
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
                // 窗口底栏是内容库唯一的布局/缩略图控制入口；截图与录屏都
                // 不再叠一套 GalleryFloatingToolbar。
                chrome: .libraryPanel
            )
        }
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
