import AppKit
import Combine
import UniformTypeIdentifiers

// ============================================================
// MARK: - 剪贴板历史视图模型：条目操作 + 拖拽 + 收藏集
// ============================================================

extension ClipboardHistoryViewModel {
    func deleteSelected() {
        let visible = filteredItems
        guard selectedIndex < visible.count else { return }
        let item = visible[selectedIndex]
        removeFromPasteQueue(item)
        store.delete(item)
        if selectedIndex >= filteredItems.count {
            selectedIndex = max(0, filteredItems.count - 1)
        }
        refresh()
    }

    func copySelected() {
        let visible = filteredItems
        guard visible.indices.contains(selectedIndex) else {
            pasteFeedback = "请先选择要复制的卡片"
            return
        }
        pasteFeedback = copyBack(visible[selectedIndex]) ? nil : "这条记录的内容已不可用"
    }

    // MARK: 动作

    @discardableResult
    func copyBack(_ item: ClipboardHistoryItem) -> Bool {
        let content = store.content(of: item)
        let didCopy: Bool
        switch item.kind {
        case .text:
            guard let text = content.text else { return false }
            didCopy = Clipboard.copy(text: text)
        case .image:
            guard let url = content.assetURL,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else {
                return false
            }
            didCopy = Clipboard.copy(pngData: data)
        case .file:
            guard let urls = fileURLs(for: item) else { return false }
            didCopy = Clipboard.copy(fileURLs: urls)
        }
        guard didCopy else { return false }
        store.markUsed(item)
        return true
    }

    func dragProvider(for item: ClipboardHistoryItem) -> NSItemProvider {
        let content = store.content(of: item)
        let provider = NSItemProvider()
        switch item.kind {
        case .text:
            let text = content.text ?? ""
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.utf8PlainText.identifier,
                visibility: .all
            ) { completion in
                completion(text.data(using: .utf8), nil)
                return Progress()
            }
        case .image:
            guard let url = content.assetURL, FileManager.default.fileExists(atPath: url.path) else { return provider }
            // 同时注册 data（UTType.png）和 fileURL（UTType.fileURL），
            // 不同应用接受的方式不同：备忘录/微信接受 data，Finder 接受 fileURL。
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.png.identifier,
                visibility: .all
            ) { completion in
                completion(try? Data(contentsOf: url), nil)
                return Progress()
            }
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier,
                visibility: .all
            ) { completion in
                completion(url, true, nil)
                return Progress()
            }
        case .file:
            if let url = content.assetURL,
               let data = try? Data(contentsOf: url),
               let paths = try? JSONDecoder().decode([String].self, from: data) {
                let fileURLs = paths.map { URL(fileURLWithPath: $0) }
                provider.registerFileRepresentation(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    visibility: .all
                ) { completion in
                    completion(fileURLs.first, true, nil)
                    return Progress()
                }
            }
        }
        return provider
    }

    func togglePin(_ item: ClipboardHistoryItem) {
        store.setPinned(!item.pinned, for: item)
        refresh()
    }

    func rename(_ title: String?, for item: ClipboardHistoryItem) {
        store.rename(title, for: item)
        refresh()
    }

    func toggleFavorite(_ item: ClipboardHistoryItem) {
        store.setFavorite(!item.isFavorite, for: item)
        refresh()
    }

    func delete(_ item: ClipboardHistoryItem) {
        removeFromPasteQueue(item)
        store.delete(item)
        refresh()
    }

    // MARK: 专题收藏集

    func toggleCollectionMembership(_ item: ClipboardHistoryItem, collectionID: Int64) {
        guard let id = item.id else { return }
        let isIn = collectionMemberships[id]?.contains(collectionID) == true
        if isIn {
            store.removeFromCollection(clipboardID: id, collectionID: collectionID)
        } else {
            do {
                try store.addToCollection(clipboardID: id, collectionID: collectionID)
            } catch {
                NSLog("[Index] 剪贴板加入收藏集失败: \(error)")
                return
            }
        }
        // 只更新当前条目的成员关系，不整体 refresh（避免重查数据库 + 重解码图片）。
        var updated = collectionMemberships
        if isIn {
            updated[id]?.remove(collectionID)
        } else {
            updated[id, default: []].insert(collectionID)
        }
        collectionMemberships = updated
    }
}
