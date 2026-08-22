import AppKit
import SwiftUI

/// 图库键盘导航：方向键走格、⇧方向键扩选、⌘A 全选、Esc 收拢多选、
/// 回车编辑（录屏则播放）、F2 重命名、空格 Quick Look、⌘⌫ 删除选中。
///
/// 用 NSEvent local monitor 而不是 SwiftUI 的 .focusable/.onKeyPress ——
/// NavigationSplitView 里焦点会被侧边栏 List 和搜索框来回抢，网格自身拿不稳焦点。
/// monitor 只在 `GalleryKeyContext` 判定「按键归图库模式」时接手（窗口是 key、
/// 无 sheet / 模态、非文本输入焦点 —— 与编辑器的空格抓手 monitor 共用同一份判定），
/// 另外给侧边栏列表（NSTableView 系）只放行方向键，保留原生的筛选项键盘导航。
@MainActor
final class GalleryKeyboard {

    private let store: ShotReading
    private let displayedShots: () -> [Shot]
    private let matchingIDs: () async -> [Int64]

    init(store: ShotReading = ShotStore.shared) {
        self.store = store
        displayedShots = { GalleryViewModel.displayShots(for: store) ?? store.shots }
        matchingIDs = { await GalleryViewModel.allMatchingIDs(for: store) }
    }

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

    /// 由 GalleryWindowController 在建窗时调用。重复调用无害。
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 只把值类型带进 assumeIsolated，避免非 Sendable 的 NSEvent 跨隔离告警。
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let handled = MainActor.assumeIsolated {
                self?.handle(keyCode: keyCode, flags: flags) ?? false
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
            GalleryWindowController.shared.quickLook.toggle()
            return true

        case KeyCode.returnKey where flags.isEmpty,
             KeyCode.keypadEnter where flags.isEmpty:
            guard let shot = selectedShot(), let id = shot.id else { return false }
            RecordingAssetActions.performPrimary(
                recordingAsset(for: shot), shotID: id,
                presenter: GalleryWindowController.shared
            )
            return true

        case KeyCode.f2 where flags.isEmpty:
            guard let id = selectedShot()?.id else { return false }
            GalleryWindowController.shared.selection.pendingRenameID = id
            return true

        case KeyCode.a where isCommandOnly(flags):
            // ⌘A：全选**符合当前筛选/搜索的全部截图**，而不是「已经滚出来的那些」。
            //
            // 分页之后这两者不再等价：`displayShots` 只是已加载的前几页，
            // 用它会让同一个 ⌘A 因为你滚了多远而选中不同的东西 —— 那是最难解释的一类行为。
            // 只查 id 一列，十万行也就几百 KB。
            let matchingIDs = self.matchingIDs
            Task {
                let ids = await matchingIDs()
                GalleryWindowController.shared.selection.selectAll(ids)
            }
            return true

        case KeyCode.c where isCommandOnly(flags):
            // ⌘C：把选中的截图（成品，含标注）复制到剪贴板。
            //
            // 让位判定已经在入口那道 `GalleryKeyContext` 里做过了 ——
            // 搜索框、标签输入、重命名弹窗聚焦时首响应者是 NSTextView，
            // 那里直接返回 .none，⌘C 原样交给系统去复制文字，不会被这里劫走。
            guard !GalleryWindowController.shared.selection.selectedIDs.isEmpty else { return false }
            guard !GalleryWindowController.shared.batchActivity.isBusy else { return true }
            if let shots = GalleryBatch.loadedSelectedShots(
                displayedShots: displayedShots(),
                reader: store
            ) {
                GalleryBatch.copyImages(shots, reader: store)
            } else {
                Task { _ = await GalleryBatch.copySelectedImages(reader: store) }
            }
            return true

        case KeyCode.v where isCommandOnly(flags):
            // ⌘V：从剪贴板粘贴图片导入图库。
            // 网页复制的图片（⌘C 后 ⌘V）、访达复制的图片文件都走这里。
            guard let image = Clipboard.readImage() else { return false }
            var metadata = CaptureMetadata()
            metadata.scale = 1
            metadata.globalRegion = CGRect(
                x: 0, y: 0,
                width: image.width, height: image.height
            )
            metadata.windowTitle = "粘贴图片"
            do {
                _ = try ShotStore.shared.save(image: image, metadata: metadata)
            } catch {
                NSLog("[Index] 粘贴导入失败: \(error)")
            }
            return true

        case KeyCode.escape where flags.isEmpty:
            // Esc：多选收拢回主选中单张；没在多选就不拦，留给系统。
            let selection = GalleryWindowController.shared.selection
            guard selection.isMultiple else { return false }
            selection.collapseToPrimary()
            return true

        case KeyCode.delete where isCommandOnly(flags):
            // ⌘⌫ 删除所有选中。不直接弹 NSAlert —— 写 pendingDeleteIDs，
            // 由 GalleryGrid 上唯一的 confirmationDialog 出确认框（和右键同一套）。
            let selection = GalleryWindowController.shared.selection
            guard !selection.selectedIDs.isEmpty else { return false }
            guard !GalleryWindowController.shared.batchActivity.isBusy else { return true }
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
        let shots = displayedShots()
        guard !shots.isEmpty else { return }
        let selection = GalleryWindowController.shared.selection
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
        let shots = displayedShots()
        guard !shots.isEmpty else { return }
        let selection = GalleryWindowController.shared.selection
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
        return displayedShots().first { $0.id == GalleryWindowController.shared.selection.primaryID }
            ?? store.shots.first { $0.id == GalleryWindowController.shared.selection.primaryID }
    }

    private func recordingAsset(for shot: Shot) -> RecordingAsset {
        RecordingAsset(path: store.recordingPath(for: shot))
    }

    /// 选中集合按展示顺序排好（删除确认框逐条列数、顺移选中都依赖顺序）。
    private func orderedSelectedIDs() -> [Int64] {
        GalleryWindowController.shared.selection.orderedSelectedIDs
    }

    /// 仅含 ⌘ 的判定（忽略 CapsLock/Function 等与意图无关的位）。
    /// 用交集精确匹配替代 `== .command`，大小写锁定打开时仍命中。
    nonisolated func isCommandOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .shift, .control, .option]) == .command
    }
}

// MARK: - Environment 注入

private struct GalleryKeyboardKey: EnvironmentKey {
    static let defaultValue: GalleryKeyboard? = nil
}

extension EnvironmentValues {
    var galleryKeyboard: GalleryKeyboard? {
        get { self[GalleryKeyboardKey.self] }
        set { self[GalleryKeyboardKey.self] = newValue }
    }
}
