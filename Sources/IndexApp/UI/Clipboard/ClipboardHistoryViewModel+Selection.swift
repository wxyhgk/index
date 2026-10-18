import AppKit
import Combine
import UniformTypeIdentifiers

// ============================================================
// MARK: - 剪贴板历史视图模型：键盘导航 + 粘贴队列
// ============================================================

extension ClipboardHistoryViewModel {
    // MARK: 键盘导航

    func moveSelection(_ delta: Int, preservingQueue: Bool = false) {
        let count = filteredItems.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        if !preservingQueue {
            resetPasteQueueToCurrentItem()
        }
    }

    /// 普通浏览时点击替换队列；Command 点击或连续模式点击都会切换成员。
    func select(
        _ item: ClipboardHistoryItem,
        extending: Bool = false,
        continuingQueue: Bool = false
    ) {
        guard let index = filteredItems.firstIndex(where: { $0.id == item.id }) else { return }
        selectedIndex = index
        pasteFeedback = nil
        autoSelectsCurrentWhenQueueEmpty = true
        guard item.id != nil else {
            pasteQueueItems = []
            return
        }
        if extending || continuingQueue {
            if let existing = pasteQueueItems.firstIndex(where: { $0.id == item.id }) {
                pasteQueueItems.remove(at: existing)
                if pasteQueueItems.isEmpty { autoSelectsCurrentWhenQueueEmpty = false }
            } else {
                pasteQueueItems.append(item)
            }
        } else {
            pasteQueueItems = [item]
        }
    }

    func removeFromPasteQueue(_ item: ClipboardHistoryItem) {
        pasteQueueItems.removeAll { $0.id == item.id }
        pasteFeedback = nil
        if pasteQueueItems.isEmpty { autoSelectsCurrentWhenQueueEmpty = false }
    }

    func clearPasteQueue() {
        pasteQueueItems = []
        pasteFeedback = nil
        autoSelectsCurrentWhenQueueEmpty = false
    }

    func loadPasteQueue(
        _ items: [ClipboardHistoryItem],
        switchingToHistory: Bool = true
    ) {
        let unique = items.reduce(into: [ClipboardHistoryItem]()) { result, item in
            guard item.id != nil, !result.contains(where: { $0.id == item.id }) else { return }
            result.append(item)
        }
        pasteQueueItems = unique
        isContinuousSelectionEnabled = true
        autoSelectsCurrentWhenQueueEmpty = false
        pasteFeedback = unique.isEmpty ? "没有可加入队列的内容" : "已加入 \(unique.count) 项"
        if switchingToHistory { workspaceMode = .history }
    }

    func movePasteQueueItem(_ item: ClipboardHistoryItem, by delta: Int) {
        guard let source = pasteQueueItems.firstIndex(where: { $0.id == item.id }) else { return }
        let destination = min(max(0, source + delta), pasteQueueItems.count - 1)
        guard destination != source else { return }
        let moved = pasteQueueItems.remove(at: source)
        pasteQueueItems.insert(moved, at: destination)
        pasteFeedback = nil
    }

    func resetPasteQueueToCurrentItem() {
        pasteFeedback = nil
        let visible = filteredItems
        guard visible.indices.contains(selectedIndex), visible[selectedIndex].id != nil else {
            pasteQueueItems = []
            return
        }
        pasteQueueItems = [visible[selectedIndex]]
        autoSelectsCurrentWhenQueueEmpty = true
    }

    /// 数据库有新记录时更新可见条目的快照；搜索中的缺席表示“不匹配”，不是删除。
}
