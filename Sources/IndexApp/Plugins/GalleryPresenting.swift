import AppKit

/// 图库窗口展示能力。Plugins/ 层通过此协议与图库窗口交互，
/// 不直接引用 GalleryWindowController（UI 层具体类）。
///
/// 由 App 装配层注入给各动作包（ScrollCaptureController、ShelfCardController 等），
/// 默认实现是 GalleryWindowController.shared。
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
