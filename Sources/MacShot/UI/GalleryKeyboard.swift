import AppKit

/// 图库键盘导航：方向键走格、⇧方向键扩选、⌘A 全选、Esc 收拢多选、
/// 回车编辑、空格 Quick Look、⌘⌫ 删除选中（走网格上统一的确认框）。
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
            EditorWindowController.open(shot)
            return true

        case KeyCode.a where flags == .command:
            // ⌘A：全选当前列表（分组只是展示，选择按全局顺序）。
            GallerySelection.shared.selectAll(ShotStore.shared.displayShots.compactMap(\.id))
            return true

        case KeyCode.escape where flags.isEmpty:
            // Esc：多选收拢回主选中单张；没在多选就不拦，留给系统。
            let selection = GallerySelection.shared
            guard selection.isMultiple else { return false }
            selection.collapseToPrimary()
            return true

        case KeyCode.delete where flags == .command:
            // ⌘⌫ 删除所有选中。不直接弹 NSAlert —— 写 pendingDeleteIDs，
            // 由 GalleryGrid 上唯一的 confirmationDialog 出确认框（和右键同一套）。
            let selection = GallerySelection.shared
            guard !selection.selectedIDs.isEmpty else { return false }
            selection.pendingDeleteIDs = orderedSelectedIDs()
            return true

        case KeyCode.left, KeyCode.right, KeyCode.up, KeyCode.down:
            guard flags.isEmpty || flags == .shift else { return false }
            // 侧边栏列表持有焦点时，方向键还给它做原生行导航。
            if responder is NSTableView { return false }
            let delta: Int
            switch keyCode {
            case KeyCode.left:  delta = -1
            case KeyCode.right: delta = 1
            case KeyCode.up:    delta = -columnCount()
            default:            delta = columnCount()
            }
            if flags == .shift {
                extendSelection(by: delta)
            } else {
                moveSelection(by: delta)
            }
            return true

        default:
            return false
        }
    }

    // MARK: - 网格导航

    /// 方向键：按全局顺序索引移动**单选**（displayShots 时间降序，与分组网格的
    /// 视觉顺序一致；多选状态下按方向键 = 收拢集合到目标一张）。
    /// 上下键传 ±列数即可跨分组自然衔接。滚动定位由网格监听 primaryID 完成。
    func moveSelection(by delta: Int) {
        let shots = ShotStore.shared.displayShots
        guard !shots.isEmpty else { return }
        let selection = GallerySelection.shared
        guard let current = shots.firstIndex(where: { $0.id == selection.primaryID }) else {
            // 还没有选中：任何方向键都从第一张开始。
            selection.select(only: shots.first?.id)
            return
        }
        let target = min(max(current + delta, 0), shots.count - 1)
        // 撞边界也要 select：多选状态下方向键必须收拢回单选。
        selection.select(only: shots[target].id)
    }

    /// ⇧方向键：锚点不动，主选中走格，选中扩展为锚点到主选中的区间。
    func extendSelection(by delta: Int) {
        let shots = ShotStore.shared.displayShots
        guard !shots.isEmpty else { return }
        let selection = GallerySelection.shared
        guard let current = shots.firstIndex(where: { $0.id == selection.primaryID }) else {
            selection.select(only: shots.first?.id)
            return
        }
        let target = min(max(current + delta, 0), shots.count - 1)
        guard let targetID = shots[target].id else { return }
        selection.selectRange(to: targetID, in: shots.compactMap(\.id))
    }

    /// 从网格容器宽度和缩放档反推当前列数。
    ///
    /// GalleryGrid 用 .adaptive(minimum: zoom, spacing: DS.s4) + 水平外边距 DS.s4：
    /// 放得下 n 列的条件是 n·zoom + (n-1)·s4 ≤ width - 2·s4，
    /// 解出 n = floor((width - 2·s4 + s4) / (zoom + s4))。
    /// 超出 minimum 的富余只会拉宽已有列（maximum = 1.5×），不会改变列数。
    /// 网格实际使用的列数（fixedColumns 算好上报）。有它就不再反推。
    var columnCountOverride: Int?

    func columnCount() -> Int {
        if let count = columnCountOverride { return count }
        var zoom = UserDefaults.standard.double(forKey: "galleryZoom")
        if zoom <= 0 { zoom = 200 } // @AppStorage("galleryZoom") 的默认值
        let available = gridWidth - 2 * DS.s4 + DS.s4
        return max(1, Int(available / (zoom + DS.s4)))
    }

    private func selectedShot() -> Shot? {
        let store = ShotStore.shared
        return store.displayShots.first { $0.id == GallerySelection.shared.primaryID }
            ?? store.shots.first { $0.id == GallerySelection.shared.primaryID }
    }

    /// 选中集合按展示顺序排好（删除确认框逐条列数、顺移选中都依赖顺序）。
    private func orderedSelectedIDs() -> [Int64] {
        let selected = GallerySelection.shared.selectedIDs
        let inDisplay = ShotStore.shared.displayShots.compactMap(\.id).filter(selected.contains)
        // 不在当前列表里的残留选中（筛选变化）兜底带上，保证删得干净。
        let rest = selected.subtracting(inDisplay)
        return inDisplay + rest.sorted()
    }
}
