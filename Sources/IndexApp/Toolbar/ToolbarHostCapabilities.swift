import Foundation

/// 工具栏可以向宿主请求进入的临时交互模式。它们不产生标注图层，也不进入
/// AnnotationState 的撤销栈；同一时刻至多激活一个。
enum ToolbarHostMode: String, Hashable, Sendable {
    case liveText
    case selectionAI
}

/// 一个临时模式的生命周期由宿主实现。工具栏只负责查询状态和发出切换意图，
/// 不认识 Overlay、Pin 或 Editor 的具体视图。
struct ToolbarHostModeCapability {
    let isActive: @MainActor () -> Bool
    let activate: @MainActor () -> Void
    let deactivate: @MainActor () -> Void
}

/// 宿主按需提供的工具栏能力集合。新增临时画布能力只需登记一个 mode，
/// 不再向 ToolbarContext 继续追加 `isXxx/toggleXxx` 字段。
struct ToolbarHostCapabilities {
    static let none = ToolbarHostCapabilities()

    private let modes: [ToolbarHostMode: ToolbarHostModeCapability]

    init(modes: [ToolbarHostMode: ToolbarHostModeCapability] = [:]) {
        self.modes = modes
    }

    func supports(_ mode: ToolbarHostMode) -> Bool {
        modes[mode] != nil
    }

    @MainActor
    func isActive(_ mode: ToolbarHostMode) -> Bool {
        modes[mode]?.isActive() ?? false
    }

    @MainActor
    var hasActiveMode: Bool {
        modes.values.contains { $0.isActive() }
    }

    /// 激活目标前先退出其他临时模式；再次点击当前模式则只退出它。
    @MainActor
    func toggleExclusive(_ mode: ToolbarHostMode) {
        guard let target = modes[mode] else { return }
        if target.isActive() {
            target.deactivate()
            return
        }

        for (otherMode, capability) in modes where otherMode != mode && capability.isActive() {
            capability.deactivate()
        }
        target.activate()
    }

    @MainActor
    func deactivateAll() {
        for capability in modes.values where capability.isActive() {
            capability.deactivate()
        }
    }
}
