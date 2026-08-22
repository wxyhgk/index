import SwiftUI

// MARK: - 内建选项
//
// 目前三个：图库、录屏、应用。后续要加（暂存、回收站…）在这里各写一个类型、
// 在 `registerBuiltins` 里加一行。

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
        AnyView(GalleryInspectorPanelHost())
    }
}

// MARK: - 内容库（子 tab 切换）

/// 内容库的中间内容：子 tab 栏（截图/录屏/剪切板/AI 对话）+ 对应内容。
struct ContentLibraryView: View {

    @AppStorage("contentLibrarySubTab") private var subTab = "shots"
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

            // 内容区
            Group {
                switch subTab {
                case "recordings":
                    RecordingsContent(viewModel: viewModel)
                case "clipboard":
                    ClipboardContent()
                case "ai":
                    AgentConversationListView()
                default:
                    LibraryContent()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .floatingPanel()
        .task {
            activateSubTabScope()
        }
        .onChange(of: subTab) { _, _ in
            activateSubTabScope()
        }
    }

    /// 子 tab 切换时联动 scope：录屏子 tab 固定 .recordings filter，
    /// 其他子 tab 恢复 .all。destinationID 不变时 GalleryView 的
    /// activateScope 不触发，这里补上。
    private func activateSubTabScope() {
        switch subTab {
        case "recordings":
            GalleryContentScope.recordings.activate(in: viewModel)
        default:
            GalleryContentScope.recordings.deactivate(in: viewModel)
        }
    }

    private func subTabButton(_ id: String, title: String, symbol: String) -> some View {
        Button {
            subTab = id
        } label: {
            HStack(spacing: DS.s1) {
                Image(systemName: symbol)
                    .font(.system(size: DS.font12, weight: .medium))
                Text(title)
                    .font(.system(size: DS.font13, weight: subTab == id ? .medium : .regular))
            }
            .foregroundStyle(subTab == id ? Color.primary : Color.secondary)
            .padding(.horizontal, DS.s3)
            .frame(height: DS.s4 + DS.s3)
            .background(
                subTab == id ? DS.accentFillSelected : .clear,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 图库的中间内容：页头 + 网格。
struct LibraryContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GalleryPageHeader(style: .libraryPanel)
                .padding(.horizontal, DS.s5)
                .padding(.top, DS.s5)
                .padding(.bottom, DS.s2)
            GalleryGrid(chrome: .libraryPanel)
        }
        .floatingPanel()
    }
}

// ============================================================
// MARK: - 录屏
// ============================================================

struct RecordingsContent: View {
    @ObservedObject private var store: ShotStore
    @ObservedObject private var viewModel: GalleryViewModel

    init(store: ShotStore = .shared, viewModel: GalleryViewModel? = nil) {
        _store = ObservedObject(wrappedValue: store)
        let resolvedViewModel = viewModel
            ?? .resolve(for: store)
        _viewModel = ObservedObject(wrappedValue: resolvedViewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            GalleryPageHeader(store: store, viewModel: viewModel, scope: .recordings)
                .padding(.horizontal, DS.s2)
            GalleryGrid(store: store, viewModel: viewModel, scope: .recordings)
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
