import AppKit

/// 浮动面板的窗口策略。
///
/// 以前四个面板各自在 `init` 里重复十几行窗口配置，行为已经在漂移
/// （有的 borderless、有的 titled，有的 nonactivating）。这里把差异变成数据：
/// 功能只声明自己要什么，`FloatingPanel` 统一应用。
///
/// 不引用 `DS`：令牌属于 UI 层，需要圆角时由调用方填 `contentCornerRadius`。
struct PanelSpec {

    var styleMask: NSWindow.StyleMask
    var initialSize: CGSize

    var level: NSWindow.Level = .floating
    var collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    /// `NSPanel.isFloatingPanel`。它和 `level` 是两件事，别合并。
    var isFloatingPanel = true
    var isOpaque = true
    var backgroundColor: NSColor?
    var hasShadow = true
    var isMovable = true
    var isMovableByWindowBackground = false

    var canBecomeKey = true
    var canBecomeMain = false
    var becomesKeyOnlyIfNeeded = false

    var title: String?
    var titlebarAppearsTransparent = false
    var titleVisibility: NSWindow.TitleVisibility = .visible
    var hidesStandardButtons = false

    /// 台前调度下不把 Index 整组窗口拽出来。剪切板面板需要，其余不需要。
    var detachesFromAppStage = false

    /// 无边框面板的圆角；内容视图会 `masksToBounds`。
    var contentCornerRadius: CGFloat?

    // MARK: - 预设

    static func search(size: CGSize) -> PanelSpec {
        var spec = PanelSpec(styleMask: .borderless, initialSize: size)
        spec.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        spec.isOpaque = false
        spec.backgroundColor = .clear
        spec.isMovable = false
        return spec
    }

    static func agent(size: CGSize) -> PanelSpec {
        var spec = PanelSpec(
            styleMask: [.titled, .closable, .resizable],
            initialSize: size
        )
        spec.title = "Agent"
        spec.canBecomeMain = true
        return spec
    }

    static func clipboard(size: CGSize) -> PanelSpec {
        var spec = PanelSpec(
            styleMask: [.borderless, .nonactivatingPanel],
            initialSize: size
        )
        spec.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        spec.isOpaque = false
        spec.backgroundColor = .clear
        spec.isMovable = true
        spec.becomesKeyOnlyIfNeeded = false
        spec.detachesFromAppStage = true
        return spec
    }

    static func quickNote(size: CGSize) -> PanelSpec {
        var spec = PanelSpec(
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            initialSize: size
        )
        spec.isFloatingPanel = false
        spec.title = ""
        spec.titlebarAppearsTransparent = true
        spec.titleVisibility = .hidden
        spec.hidesStandardButtons = true
        spec.isMovableByWindowBackground = true
        return spec
    }
}
