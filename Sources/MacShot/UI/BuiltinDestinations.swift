import SwiftUI

// MARK: - 内建选项
//
// 目前三个：图库、录屏、应用。后续要加（暂存、回收站…）在这里各写一个类型、
// 在 `registerBuiltins` 里加一行。

/// 图库：截图和录屏封面的统一时间线。这是默认落点。
struct LibraryDestination: GalleryDestination {

    static let destinationID = "destination.library"

    let id = Self.destinationID
    let title = "图库"
    let symbol = "square.grid.2x2"
    let order = 0

    func badge(reader: ShotReading = ShotStore.shared) -> Int? {
        let count = reader.totalCount
        return count > 0 ? count : nil
    }

    func badge() -> Int? { badge(reader: ShotStore.shared) }

    func content() -> AnyView {
        AnyView(LibraryContent())
    }

    /// 详情面板的开关是用户偏好，所以这里恒定返回面板，由容器按偏好决定显不显示。
    func inspector() -> AnyView? {
        AnyView(GalleryInspectorPanelHost())
    }
}

/// 图库的中间内容：页头 + 网格。
private struct LibraryContent: View {
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

/// 录屏是一等图库入口，但仍复用 Shot 网格：首帧负责封面、recording 附件
/// 负责指向 mp4。这样既有清晰入口，也不复制图库的选择、详情和时间分组体系。
struct RecordingsDestination: GalleryDestination {
    let id = "destination.recordings"
    let title = "录屏"
    let symbol = "play.rectangle"
    let order = 50

    func badge(reader: any ShotReading = ShotStore.shared) -> Int? {
        let count = reader.recordingCount()
        return count > 0 ? count : nil
    }

    func badge() -> Int? { badge(reader: ShotStore.shared) }

    func content() -> AnyView {
        AnyView(RecordingsContent())
    }

    func inspector() -> AnyView? {
        AnyView(GalleryInspectorPanelHost())
    }
}

private struct RecordingsContent: View {
    @ObservedObject private var store: ShotStore
    @ObservedObject private var viewModel: GalleryViewModel

    init(store: ShotStore = .shared, viewModel: GalleryViewModel? = nil) {
        _store = ObservedObject(wrappedValue: store)
        let resolvedViewModel = viewModel
            ?? (store === ShotStore.shared ? .shared : GalleryViewModel(store: store))
        _viewModel = ObservedObject(wrappedValue: resolvedViewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            GalleryPageHeader(store: store, viewModel: viewModel, scope: .recordings)
                .padding(.horizontal, DS.s2)
            GalleryGrid(store: store, viewModel: viewModel, scope: .recordings)
        }
        .onAppear {
            GalleryContentScope.recordings.activate(in: viewModel)
        }
        .onDisappear {
            GalleryContentScope.recordings.deactivate(in: viewModel)
        }
    }
}

// ============================================================

extension GalleryDestinationRegistry {

    /// 登记处。`AppDelegate` 启动时调一次。
    static func registerBuiltins(into registry: GalleryDestinationRegistry) {
        registry.register(LibraryDestination())
        registry.register(CollectionsDestination())
        registry.register(RecordingsDestination())
        registry.register(AppsDestination())
    }
}
