import SwiftUI

// MARK: - 侧边栏选项（顶层导航）
//
// 窗口的结构是：
//
//     选项 1 │
//     选项 2 │  中间内容        右侧面板
//     选项 3 │  （随选项切换）   （随选项切换）
//     选项 4 │
//
// 左侧是一列**固定的**选项，选中哪个，中间和右侧就换成谁的内容。
// 这与「侧边栏是一堆筛选行」是两种东西：筛选行是数据的切片，会随库里的
// 分类 / 标签 / 应用增减而长短不定（那正是它此前显得杂的原因）；
// 选项是功能的入口，数量由我们决定，固定、可预期。
//
// **一个大组件（窗口） + 一个个小组件（选项）**：每个选项自带中间内容和右侧面板，
// 容器只负责画那一列选项、记住选中了谁、把两块内容摆到位。
//
// 加一个选项 = 新建一个 `GalleryDestination` 实现 + 在登记处注册一行。
// 容器、布局、选中态一律不用改。这是本项目第七个这样的扩展点
// （前六个见 ARCHITECTURE.md §2）。

/// 一个侧边栏选项：它同时决定中间内容与右侧面板。
@MainActor
protocol GalleryDestination {

    /// 稳定标识。注册表按它去重，选中状态也按它持久化 ——
    /// **不要**用序号，插入新选项会让用户上次停留的位置漂移。
    var id: String { get }

    var title: String { get }
    /// SF Symbol。
    var symbol: String { get }
    /// 排序，小的在上。
    var order: Int { get }

    /// 右上角的计数徽章。nil = 不显示。每次刷新调一次，可以查库。
    func badge() -> Int?

    /// 中间内容。
    func content() -> AnyView

    /// 右侧面板。**nil = 这个选项不需要右侧栏**，容器会把整块宽度让给中间 ——
    /// 不是画一块空白板子。
    func inspector() -> AnyView?

    /// 这个选项固定使用的 GalleryContentScope。
    /// 默认 `.library`（无固定筛选）；录屏等需要固定范围的选项覆盖。
    /// ZStack 下所有 tab 始终存在，scope 切换由容器在 destinationID 变化时统一处理。
    var contentScope: GalleryContentScope { get }
}

extension GalleryDestination {
    func badge() -> Int? { nil }
    func inspector() -> AnyView? { nil }
    var contentScope: GalleryContentScope { .library }
}

/// 选项注册表。
@MainActor
final class GalleryDestinationRegistry {

    static let shared = GalleryDestinationRegistry()

    private var destinations: [any GalleryDestination] = []

    init() {}

    func register(_ destination: any GalleryDestination) {
        destinations.removeAll { $0.id == destination.id }
        destinations.append(destination)
    }

    /// 按 order 排好的全部选项。
    func ordered() -> [any GalleryDestination] {
        destinations.sorted { $0.order < $1.order }
    }

    func destination(id: String) -> (any GalleryDestination)? {
        destinations.first { $0.id == id }
    }

    /// 详情面板的显隐是**用户偏好**（`galleryInspectorShown`），不是选项的属性。
    /// 选项只回答「我有没有右侧栏」；关掉它是容器的事。
    /// 这里给选项一个现成的宿主，省得每个选项各自去接那个 @AppStorage。

    /// 选中 id 解析成选项；解析不到（选项被移除、旧的持久化值）就退回第一个，
    /// 而不是让窗口空着。
    func resolve(id: String?) -> (any GalleryDestination)? {
        id.flatMap { destination(id: $0) } ?? ordered().first
    }
}

/// 详情面板的现成宿主：自己接那个偏好开关，选项直接 `AnyView(GalleryInspectorPanelHost())`。
struct GalleryInspectorPanelHost: View {

    @AppStorage("galleryInspectorShown") private var showInspector = true

    var body: some View {
        GalleryInspectorPanel(isPresented: $showInspector)
    }
}
