import AppKit

/// 图库键盘导航：方向键走格、回车编辑、空格 Quick Look、⌘⌫ 删除。
///
/// 用 NSEvent local monitor 而不是 SwiftUI 的 .focusable/.onKeyPress ——
/// NavigationSplitView 里焦点会被侧边栏 List 和搜索框来回抢，网格自身拿不稳焦点。
/// monitor 只在「key window 是图库 + 没有 sheet」时接手，并给两类首响应者让路：
/// 文本输入（NSTextView，搜索框的字段编辑器）全部放行；
/// 侧边栏列表（NSTableView 系）只放行方向键，保留原生的筛选项键盘导航。
@MainActor
final class GalleryKeyboard {

    static let shared = GalleryKeyboard()

    /// 网格内容列的当前宽度，由 GalleryView 挂 GeometryReader 报告，算列数用。
    var gridWidth: CGFloat = 0

    private var monitor: Any?

    private init() {}

    /// 由 GalleryWindowController 在建窗时调用。重复调用无害。
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 只把值类型带进 assumeIsolated，避免非 Sendable 的 NSEvent 跨隔离告警。
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let handled = MainActor.assumeIsolated {
                GalleryKeyboard.shared.handle(keyCode: keyCode, flags: flags)
            }
            return handled ? nil : event
        }
    }

    // MARK: - 事件分发

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard let window = GalleryWindowController.shared.window,
              NSApp.keyWindow === window,
              window.attachedSheet == nil
        else { return false }

        let responder = window.firstResponder
        // 搜索框输入中（字段编辑器是 NSTextView）：一个键都不抢。
        if responder is NSTextView { return false }

        switch keyCode {
        case KeyCode.space where flags.isEmpty:
            QuickLookController.shared.toggle()
            return true

        case KeyCode.returnKey where flags.isEmpty,
             KeyCode.keypadEnter where flags.isEmpty:
            guard let shot = selectedShot() else { return false }
            GallerySelection.shared.editing = shot
            return true

        case KeyCode.delete where flags == .command:
            guard let shot = selectedShot() else { return false }
            confirmDelete(shot, in: window)
            return true

        case KeyCode.left where flags.isEmpty,
             KeyCode.right where flags.isEmpty,
             KeyCode.up where flags.isEmpty,
             KeyCode.down where flags.isEmpty:
            // 侧边栏列表持有焦点时，方向键还给它做原生行导航。
            if responder is NSTableView { return false }
            switch keyCode {
            case KeyCode.left:  moveSelection(by: -1)
            case KeyCode.right: moveSelection(by: 1)
            case KeyCode.up:    moveSelection(by: -columnCount())
            default:            moveSelection(by: columnCount())
            }
            return true

        default:
            return false
        }
    }

    // MARK: - 网格导航

    /// 按全局顺序索引移动选中（displayShots 时间降序，与分组网格的视觉顺序一致）。
    /// 上下键传 ±列数即可跨分组自然衔接。滚动定位由网格监听 selectedID 完成。
    func moveSelection(by delta: Int) {
        let shots = ShotStore.shared.displayShots
        guard !shots.isEmpty else { return }
        let selection = GallerySelection.shared
        guard let current = shots.firstIndex(where: { $0.id == selection.selectedID }) else {
            // 还没有选中：任何方向键都从第一张开始。
            selection.selectedID = shots.first?.id
            return
        }
        let target = min(max(current + delta, 0), shots.count - 1)
        guard target != current else { return }
        selection.selectedID = shots[target].id
    }

    /// 从网格容器宽度和缩放档反推当前列数。
    ///
    /// GalleryGrid 用 .adaptive(minimum: zoom, spacing: 16) + 外边距 18：
    /// 放得下 n 列的条件是 n·zoom + (n-1)·16 ≤ width - 2·18，
    /// 解出 n = floor((width - 36 + 16) / (zoom + 16))。
    /// 超出 minimum 的富余只会拉宽已有列（maximum = 1.5×），不会改变列数。
    func columnCount() -> Int {
        var zoom = UserDefaults.standard.double(forKey: "galleryZoom")
        if zoom <= 0 { zoom = 200 } // @AppStorage("galleryZoom") 的默认值
        let available = gridWidth - 36 + 16
        return max(1, Int(available / (zoom + 16)))
    }

    private func selectedShot() -> Shot? {
        let store = ShotStore.shared
        return store.displayShots.first { $0.id == GallerySelection.shared.selectedID }
            ?? store.shots.first { $0.id == GallerySelection.shared.selectedID }
    }

    // MARK: - 删除

    private func confirmDelete(_ shot: Shot, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "删除这张截图？"
        alert.informativeText = "原图、缩略图和全部修订记录会一并删除，无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                Self.deleteSelectingNeighbor(shot)
            }
        }
    }

    /// 删除后顺移选中到相邻一张，键盘导航不断档。
    private static func deleteSelectingNeighbor(_ shot: Shot) {
        let store = ShotStore.shared
        let index = store.displayShots.firstIndex { $0.id == shot.id }
        store.delete(shot)
        guard GallerySelection.shared.selectedID == shot.id else { return }
        let remaining = store.displayShots
        if let index, !remaining.isEmpty {
            GallerySelection.shared.selectedID = remaining[min(index, remaining.count - 1)].id
        } else {
            GallerySelection.shared.selectedID = nil
        }
    }
}
