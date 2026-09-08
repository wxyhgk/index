import AppKit

/// 图库窗口展示能力。Plugins/ 层通过此协议与图库窗口交互，
/// 不直接引用 GalleryWindowController（UI 层具体类）。
///
/// 由 App 装配层注入给各动作包（ScrollCaptureController、ShelfCardController 等）。
/// 默认值由 `GalleryPresentingDefaults` 提供（App 层启动时设置），
/// Plugins 层不直接引用 GalleryWindowController（UI 层具体类）。
@MainActor
protocol GalleryPresenting: AnyObject {
    /// 打开图库窗口，可选定位到某张截图。
    func show(selecting shot: Shot?)
    /// 打开图库窗口并直接进入编辑器模式。
    func showEditor(for shot: Shot)
    /// 进入编辑器（按 ID）。窗口未打开时仅切换模式。
    func openEditor(shotID: Int64?)
    /// 图库窗口（用于 alert host 等）。
    var hostWindow: NSWindow? { get }
}

/// 全局默认值。App 层启动时设置，Plugins 层的 controller 在 init 里用它做 fallback。
/// 这样 Plugins 层不直接引用 UI 层的 `GalleryWindowController`。
@MainActor
enum GalleryPresentingDefaults {
    static var presenter: (any GalleryPresenting)?
}

/// 测试 / 预览环境的空实现（`GalleryPresentingDefaults.presenter` 未设置时的兜底）。
@MainActor
final class NoOpGalleryPresenter: GalleryPresenting {
    func show(selecting shot: Shot?) {}
    func showEditor(for shot: Shot) {}
    func openEditor(shotID: Int64?) {}
    var hostWindow: NSWindow? { nil }
}
