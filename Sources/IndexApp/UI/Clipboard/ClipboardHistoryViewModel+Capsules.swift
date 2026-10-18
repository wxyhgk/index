import AppKit
import Combine
import UniformTypeIdentifiers

// ============================================================
// MARK: - 剪贴板历史视图模型：胶囊全生命周期
// ============================================================

extension ClipboardHistoryViewModel {
    // MARK: 线程 / 胶囊

    func createCapsuleFromQueue() {
        createCapsule(items: pasteQueueItems, proposedName: "")
    }

    func createCapsule(from thread: ClipboardThread) {
        createCapsule(items: Array(thread.items.reversed()), proposedName: thread.title)
    }

    func renameCapsule(_ name: String, snapshot: ClipboardCapsuleSnapshot) {
        guard snapshot.id >= 0 else { return }
        store.renameCapsule(name, capsuleID: snapshot.id)
        refreshCapsules()
    }

    func toggleCapsulePin(_ snapshot: ClipboardCapsuleSnapshot) {
        guard snapshot.id >= 0 else { return }
        store.setCapsulePinned(!snapshot.capsule.isPinned, capsuleID: snapshot.id)
        refreshCapsules()
    }

    func deleteCapsule(_ snapshot: ClipboardCapsuleSnapshot) {
        guard snapshot.id >= 0 else { return }
        store.deleteCapsule(snapshot.id)
        if activeCapsulePaste?.capsuleID == snapshot.id { activeCapsulePaste = nil }
        if editingCapsuleID == snapshot.id {
            editingCapsuleID = nil
            editingCapsuleName = nil
            pasteQueueItems = []
        }
        refreshCapsules()
    }

    func beginEditingCapsule(_ snapshot: ClipboardCapsuleSnapshot) {
        editingCapsuleID = snapshot.id
        editingCapsuleName = snapshot.capsule.name
        loadPasteQueue(snapshot.items, switchingToHistory: true)
        pasteFeedback = "拖动顺序可用上下箭头调整；也可以继续添加或移除卡片"
    }

    func saveCapsuleEditing() {
        guard let capsuleID = editingCapsuleID else { return }
        do {
            try store.replaceCapsuleItems(capsuleID: capsuleID, items: pasteQueueItems)
            editingCapsuleID = nil
            editingCapsuleName = nil
            pasteQueueItems = []
            autoSelectsCurrentWhenQueueEmpty = false
            pasteFeedback = "胶囊顺序已保存"
            refreshCapsules(selectMode: true)
        } catch {
            pasteFeedback = "胶囊至少需要保留一项内容"
        }
    }

    func cancelCapsuleEditing() {
        editingCapsuleID = nil
        editingCapsuleName = nil
        clearPasteQueue()
        workspaceMode = .capsules
    }

    /// 同类型胶囊一次粘贴；混合类型自动进入安全的逐项粘贴，不合成含糊的 pasteboard。
    func pasteCapsule(_ snapshot: ClipboardCapsuleSnapshot) {
        guard !snapshot.items.isEmpty else {
            pasteFeedback = "这个胶囊已经没有可用内容"
            return
        }
        let kinds = Set(snapshot.items.map(\.kind))
        if kinds.count > 1 {
            activeCapsulePaste = ClipboardCapsulePasteProgress(
                capsuleID: snapshot.id,
                name: snapshot.capsule.name,
                items: snapshot.items,
                nextIndex: 0
            )
            continueCapsulePaste()
            return
        }

        store.markCapsuleUsed(snapshot.id)
        if snapshot.items[0].kind == .text {
            let texts = snapshot.items.compactMap { store.content(of: $0).text }
            guard texts.count == snapshot.items.count else {
                pasteFeedback = "胶囊中的部分文字已不可用"
                return
            }
            finishPaste(
                items: snapshot.items,
                didCopy: Clipboard.copy(text: texts.joined(separator: snapshot.capsule.separator.value))
            )
        } else {
            loadPasteQueue(snapshot.items, switchingToHistory: false)
            pasteSelected()
        }
    }

    func continueCapsulePaste() {
        guard var progress = activeCapsulePaste,
              progress.items.indices.contains(progress.nextIndex)
        else {
            activeCapsulePaste = nil
            return
        }
        let item = progress.items[progress.nextIndex]
        if progress.nextIndex == 0 { store.markCapsuleUsed(progress.capsuleID) }
        progress.nextIndex += 1
        activeCapsulePaste = progress.nextIndex < progress.items.count ? progress : nil
        paste(item)
    }

    func cancelCapsulePaste() {
        activeCapsulePaste = nil
        pasteFeedback = nil
    }

    private func createCapsule(items: [ClipboardHistoryItem], proposedName: String) {
        guard !items.isEmpty else {
            pasteFeedback = "请先选择要保存的卡片"
            return
        }
        let store = self.store
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try store.createCapsule(name: proposedName, items: items) }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                self.pasteFeedback = "已保存为上下文胶囊"
                self.refreshCapsules(selectMode: true)
            case .failure:
                self.pasteFeedback = "无法保存胶囊"
            }
        }
    }

    private func refreshCapsules(selectMode: Bool = false) {
        let store = self.store
        Task { [weak self] in
            let snapshots = await Task.detached(priority: .utility) {
                (try? store.capsuleSnapshots()) ?? []
            }.value
            guard let self else { return }
            self.capsules = snapshots
            if selectMode { self.workspaceMode = .capsules }
        }
    }

    /// 连续选择是显式模式，不能由“当前是否正在搜索”隐式推断。
    /// 关闭时立即回到当前候选的单选语义。
}
