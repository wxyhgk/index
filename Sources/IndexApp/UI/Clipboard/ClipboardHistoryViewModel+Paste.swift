import AppKit
import Combine
import UniformTypeIdentifiers

// ============================================================
// MARK: - 剪贴板历史视图模型：粘贴执行
// ============================================================

extension ClipboardHistoryViewModel {
    func setContinuousSelectionEnabled(_ enabled: Bool) {
        guard enabled != isContinuousSelectionEnabled else { return }
        isContinuousSelectionEnabled = enabled
        pasteFeedback = nil
        if enabled {
            if pasteQueueItems.isEmpty {
                resetPasteQueueToCurrentItem()
            }
        } else {
            resetPasteQueueToCurrentItem()
        }
    }

    /// 按显式队列顺序写入一次剪贴板，然后只发送一次 Cmd+V。
    /// 文本用换行拼接；图片/文件使用系统的多条目剪贴板表示。
    func pasteSelected() {
        let selectedItems = pasteQueueItems
        NSLog(
            "[Index][ClipboardPaste] selected count=%d visible=%d index=%d",
            selectedItems.count,
            filteredItems.count,
            selectedIndex
        )
        guard !selectedItems.isEmpty else {
            pasteFeedback = "请先选择要粘贴的卡片"
            return
        }
        guard selectedItems.count > 1 else {
            paste(selectedItems[0])
            return
        }
        guard selectedItems.dropFirst().allSatisfy({ $0.kind == selectedItems[0].kind }) else {
            pasteFeedback = "文字、图片和文件暂不能混合一次粘贴"
            return
        }

        let didCopy: Bool
        switch selectedItems[0].kind {
        case .text:
            let texts = selectedItems.compactMap { store.content(of: $0).text }
            guard texts.count == selectedItems.count else {
                pasteFeedback = "部分文字内容已不可用"
                return
            }
            didCopy = Clipboard.copy(text: Self.joinedTexts(texts))

        case .image:
            let urls = selectedItems.compactMap { store.content(of: $0).assetURL }
            guard urls.count == selectedItems.count else {
                pasteFeedback = "部分图片文件已不可用"
                return
            }
            prepareImagePaste(items: selectedItems, urls: urls)
            return

        case .file:
            var urls: [URL] = []
            for item in selectedItems {
                guard let itemURLs = fileURLs(for: item) else {
                    pasteFeedback = "部分文件记录已不可用"
                    return
                }
                urls.append(contentsOf: itemURLs)
            }
            didCopy = Clipboard.copy(fileURLs: urls)
        }

        guard didCopy else {
            pasteFeedback = "无法写入系统剪贴板"
            return
        }
        finishPaste(items: selectedItems, didCopy: didCopy)
    }

    /// Paste 的 Shift+Enter 语义：无论来源中以后是否保留富文本表示，
    /// 都只向系统剪贴板写 public.utf8-plain-text 再执行一次粘贴。
    func pasteSelectedAsPlainText() {
        pasteAsPlainText(pasteQueueItems)
    }

    nonisolated static func joinedTexts(_ texts: [String]) -> String {
        texts.joined(separator: "\n")
    }

    /// 鼠标双击直接粘贴命中的记录，不能再通过可能正在变化的 selectedIndex 回查。
    func paste(_ item: ClipboardHistoryItem) {
        if item.kind == .image {
            guard let url = store.content(of: item).assetURL else {
                pasteFeedback = "这条记录的内容已不可用"
                return
            }
            prepareImagePaste(items: [item], urls: [url])
            return
        }
        guard copyBack(item) else {
            pasteFeedback = "这条记录的内容已不可用"
            return
        }
        pasteFeedback = nil
        ClipboardHistoryCoordinator.shared.performPaste()
    }

    func pasteAsPlainText(_ item: ClipboardHistoryItem) {
        pasteAsPlainText([item])
    }

    private func pasteAsPlainText(_ items: [ClipboardHistoryItem]) {
        guard !items.isEmpty else {
            pasteFeedback = "请先选择要粘贴的文字卡片"
            return
        }
        guard items.allSatisfy({ $0.kind == .text }) else {
            pasteFeedback = "只有文字卡片可以按纯文本粘贴"
            return
        }
        let texts = items.compactMap { store.content(of: $0).text }
        guard texts.count == items.count else {
            pasteFeedback = "部分文字内容已不可用"
            return
        }
        finishPaste(
            items: items,
            didCopy: Clipboard.copy(text: Self.joinedTexts(texts))
        )
    }

    /// 图片历史本来就是 PNG 文件。文件读取移到后台，主线程只负责一次
    /// NSPasteboard 写入，避免双击/连续粘贴大图时解码再编码造成选中动画卡顿。
    private func prepareImagePaste(items: [ClipboardHistoryItem], urls: [URL]) {
        pastePreparationTask?.cancel()
        pasteFeedback = "正在准备图片…"
        pastePreparationTask = Task { [weak self] in
            let dataItems = await Task.detached(priority: .userInitiated) {
                var values: [Data] = []
                values.reserveCapacity(urls.count)
                for url in urls {
                    guard !Task.isCancelled,
                          let data = try? Data(contentsOf: url, options: .mappedIfSafe)
                    else { return [Data]() }
                    values.append(data)
                }
                return values
            }.value
            guard let self, !Task.isCancelled else { return }
            guard dataItems.count == items.count else {
                self.pasteFeedback = "部分图片文件已不可用"
                return
            }
            self.finishPaste(items: items, didCopy: Clipboard.copy(pngDataItems: dataItems))
        }
    }

    func finishPaste(items: [ClipboardHistoryItem], didCopy: Bool) {
        NSLog(
            "[Index][ClipboardPaste] pasteboard write=%d count=%d kind=%@",
            didCopy ? 1 : 0,
            items.count,
            items.first.map { String(describing: $0.kind) } ?? "none"
        )
        guard didCopy else {
            pasteFeedback = "无法写入系统剪贴板"
            return
        }
        let store = self.store
        Task.detached(priority: .utility) { store.markUsed(items) }
        pasteFeedback = nil
        ClipboardHistoryCoordinator.shared.performPaste()
    }

    func fileURLs(for item: ClipboardHistoryItem) -> [URL]? {
        guard let url = store.content(of: item).assetURL,
              let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data),
              !paths.isEmpty
        else { return nil }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// 拖拽到目标应用：按类型提供 NSItemProvider（图片/文本/文件）。
}
