import AppKit
import Combine

/// 图库窗口的模式（Snagit 的 Editor/Library 单窗口双模式）。
///
/// 这不是「选中了什么」（那是 GallerySelection 的事）而是「窗口整体处于哪个视图」，
/// 所以单独建模。存的是 **ID 不是 Shot 快照** —— 需要 Shot 值的地方按 ID 现查
/// ShotStore，store 更新后拿到的永远是最新值；查不到 = 记录已被删除，
/// 宿主（GalleryView）据此退回图库模式。
@MainActor
final class GalleryWindowMode: ObservableObject {

    /// 窗口整体处于哪个视图。三者互斥，整窗切换（不是 sheet）。
    /// 设置也在这里 —— 它此前是一个独立窗口，与「单窗口多模式」的设计不一致，
    /// 用起来也割裂（改个默认颜色要跳出去再跳回来）。
    enum Mode: Equatable {
        case library
        /// 胶片条换图 = 换成目标 ID（EditorView 按 id 重建）。
        case editing(Int64)
        case settings
    }

    @Published private(set) var mode: Mode = .library

    init() {}

    var isEditing: Bool { editingShotID != nil }
    var isSettings: Bool { mode == .settings }

    /// 正在编辑的截图 ID；不在编辑模式时为 nil。
    var editingShotID: Int64? {
        if case .editing(let id) = mode { return id }
        return nil
    }

    /// 进入编辑器。id 为 nil（未入库的 Shot 值）时忽略 ——
    /// 编辑器一定对应库里的一条记录。
    func openEditor(shotID: Int64?) {
        guard let shotID else { return }
        mode = .editing(shotID)
    }

    /// 进入设置。
    func openSettings() {
        mode = .settings
    }

    /// 返回图库模式（选中状态原样保留，那是 GallerySelection 的事）。
    func returnToGallery() {
        mode = .library
    }

    /// 正在编辑的截图，按 ID 现查。nil = 没在编辑，或记录已被删除。
    func resolveEditingShot() -> Shot? {
        editingShotID.flatMap { Self.resolveShot(id: $0) }
    }

    /// 按 ID 找 Shot：先查内存列表（语义结果可能不在常规列表里，两边都找），
    /// 都没有再兜底查一次库 —— `shots` 受搜索 / 筛选影响，正在编辑的记录
    /// 可能只是被筛掉了而不是被删了。
    static func resolveShot(id: Int64, store: ShotReading = ShotStore.shared) -> Shot? {
        let displayed = GalleryViewModel.displayShots(for: store) ?? store.shots
        return displayed.first { $0.id == id }
            ?? store.shots.first { $0.id == id }
            ?? store.allShots().first { $0.id == id }
    }
}

/// 图库窗口两个按键 monitor 的**共享**让位判定。
///
/// GalleryKeyboard（图库模式接空格 / 回车 / 方向键）与 EditorSpaceHandMonitor
/// （编辑模式接空格抓手）此前各写一份互为镜像的 guard，改一边忘另一边就是
/// 同键冲突 —— 判定收敛到这里，两边只问「现在归谁管」。
@MainActor
enum GalleryKeyContext {

    /// 按键当前归谁：图库窗口不是 key / 有 sheet 或应用模态 / 文本输入焦点
    /// （NSTextView，含搜索框的字段编辑器）一律 `.none`，谁都不准抢；
    /// 否则按窗口模式归图库或编辑器。
    enum Claim { case none, library, editor }

    static func current() -> Claim {
        guard let window = GalleryWindowController.shared.window,
              NSApp.keyWindow === window,
              NSApp.modalWindow == nil,
              window.attachedSheet == nil,
              !(window.firstResponder is NSTextView)
        else { return .none }

        switch GalleryWindowController.shared.mode.mode {
        case .library:  return .library
        case .editing:  return .editor
        // 设置页里全是输入控件，空格/方向键/回车都该留给它们 ——
        // 焦点不在文本框时也不能让图库的网格导航接管。
        case .settings: return .none
        }
    }
}
