import Foundation

/// 入口契约：像素怎么进来（ARCHITECTURE §2.1）。
///
/// 新增捕获方式 = 新增一个实现并注册到 `CaptureSourceRegistry`，不改 `CaptureCoordinator`。
///
/// 产物是 `[DisplaySnapshot]` —— 选区层的画布事实上就是「一块显示器」，这是如实建模。
/// 曾设想的「不绑定显示器的 CaptureCanvas」已废弃：滚动截图、单窗口截图、延时截图
/// 最终没有一个需要它，原因见 ARCHITECTURE §2.1 与阶段 4 注。
@MainActor
protocol CaptureSource {
    var id: String { get }
    /// 菜单显示用。
    var title: String { get }
    var symbolName: String { get }
    /// 准备阶段（`makeSnapshots` 进行中）是否允许用户取消。
    /// 协调器据此临时监听 ⎋ 和快捷键再按，通过 Task 取消打断等待。
    var isCancellableWhilePreparing: Bool { get }
    /// 产出同一次显示器拓扑下的冻结画布。普通截图返回全部活动屏幕，
    /// 这样用户可在任意屏开始选区；取消时抛 `CancellationError`。
    func makeSnapshots() async throws -> [DisplaySnapshot]
}

extension CaptureSource {
    var isCancellableWhilePreparing: Bool { false }
}

/// 内置捕获方式的 id。菜单和快捷键按 id 引用，避免散落字符串字面量。
enum CaptureSourceID {
    static let immediate = "immediate"
    static let delayed = "delayed"
}

/// 捕获方式注册表。
///
/// 菜单问它「有哪些捕获方式」，协调器问它「这个 id 对应哪个实现」。
/// 两边都不认识具体类型，所以增删捕获方式不会波及它们。
@MainActor
final class CaptureSourceRegistry {

    static let shared = CaptureSourceRegistry()

    private var sources: [String: CaptureSource] = [:]
    /// 注册顺序即菜单上的显示顺序。
    private var order: [String] = []

    init() {}

    func register(_ source: CaptureSource) {
        if sources[source.id] == nil { order.append(source.id) }
        sources[source.id] = source
    }

    func source(id: String) -> CaptureSource? {
        sources[id]
    }

    var all: [CaptureSource] {
        order.compactMap { sources[$0] }
    }
}
