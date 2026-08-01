import AppKit

/// 图库键盘导航：方向键走格、⇧方向键扩选、⌘A 全选、Esc 收拢多选、
/// 回车编辑、空格 Quick Look、⌘⌫ 删除选中（走网格上统一的确认框）。
///
/// 用 NSEvent local monitor 而不是 SwiftUI 的 .focusable/.onKeyPress ——
/// NavigationSplitView 里焦点会被侧边栏 List 和搜索框来回抢，网格自身拿不稳焦点。
/// monitor 只在 `GalleryKeyContext` 判定「按键归图库模式」时接手（窗口是 key、
/// 无 sheet / 模态、非文本输入焦点 —— 与编辑器的空格抓手 monitor 共用同一份判定），
/// 另外给侧边栏列表（NSTableView 系）只放行方向键，保留原生的筛选项键盘导航。
@MainActor
final class GalleryKeyboard {

    static let shared = GalleryKeyboard()

    /// 网格**实际使用**的列数，由 GalleryGrid 算好上报（`columnCount()` 的唯一来源）。
    /// 瀑布模式下网格会上报 1 —— 各列行高不齐，「上下 = ±列数」的假设失效。
    ///
    /// 这里刻意**不**存宽度再自己算一遍列数：那是第二份列数真相，
    /// 和网格的公式一旦漂移，上下键就会跳错行（网格改成 `.flexible` 列宽之后，
    /// 从宽度反推更是根本推不回来）。
    ///
    /// 普通 `var`，不是 `@Published`：它只是给键盘导航读的一个数，
    /// 赋值不该触发任何视图重绘（网格每次跨列数阈值都会写它）。
    var gridColumnCount = 1

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
        // 编辑器模式（单窗口双模式）下方向键/空格/回车/⌘⌫ 全放行 ——
        // 编辑器有自己的快捷键体系（SwiftUI keyboardShortcut + 空格抓手 monitor），
        // 这里一个键都不抢。判定与 EditorSpaceHandMonitor 共用 GalleryKeyContext。
        guard GalleryKeyContext.current() == .library else { return false }

        let responder = GalleryWindowController.shared.window?.firstResponder

        switch keyCode {
        case KeyCode.space where flags.isEmpty:
            QuickLookController.shared.toggle()
            return true

        case KeyCode.returnKey where flags.isEmpty,
             KeyCode.keypadEnter where flags.isEmpty:
            guard let id = selectedShot()?.id else { return false }
            GalleryWindowMode.shared.openEditor(shotID: id)
            return true

        case KeyCode.a where flags == .command:
            // ⌘A：全选当前列表（分组只是展示，选择按全局顺序）。
            GallerySelection.shared.selectAll(ShotStore.shared.displayShots.compactMap(\.id))
            return true

        case KeyCode.c where flags == .command:
            // ⌘C：把选中的截图（成品，含标注）复制到剪贴板。
            //
            // 让位判定已经在入口那道 `GalleryKeyContext` 里做过了 ——
            // 搜索框、标签输入、重命名弹窗聚焦时首响应者是 NSTextView，
            // 那里直接返回 .none，⌘C 原样交给系统去复制文字，不会被这里劫走。
            let shots = GalleryBatch.selectedShots()
            guard !shots.isEmpty else { return false }
            GalleryBatch.copyImages(shots)
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

    /// 上下键的步长 = 网格当前列数。值由网格上报（见 `gridColumnCount`），
    /// 这里只做一次下限保护 —— 步长为 0 会让上下键变成「原地不动」。
    func columnCount() -> Int {
        max(1, gridColumnCount)
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
