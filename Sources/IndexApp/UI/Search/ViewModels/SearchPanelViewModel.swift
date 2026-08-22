import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - 搜索面板 ViewModel
//
// 混合搜索截图（FTS）+ 剪贴板历史（LIKE），按时间倒序合并。
// 150ms 防抖，后台查询不阻塞主线程。

@MainActor
final class SearchPanelViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var entries: [SearchEntry] = []
    @Published var selectedIndex: Int = 0
    @Published var previewImage: NSImage?
    @Published var previewText: String?
    @Published var isSearching = false

    private var searchTask: Task<Void, Never>?
    private var previewLoadTask: Task<Void, Never>?
    private var shotThumbnails: [Int64: NSImage] = [:]
    private var clipboardThumbnails: [Int64: NSImage] = [:]
    private var shotOriginals: [Int64: NSImage] = [:]

    var selectedEntry: SearchEntry? {
        guard entries.indices.contains(selectedIndex) else { return nil }
        return entries[selectedIndex]
    }

    func searchChanged() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.performSearch(q)
        }
    }

    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = max(0, min(entries.count - 1, selectedIndex + delta))
        updatePreview()
    }

    func select(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        selectedIndex = index
        updatePreview()
    }

    func clear() {
        query = ""
        entries = []
        selectedIndex = 0
        previewImage = nil
        previewText = nil
        searchTask?.cancel()
    }

    /// 面板打开时加载最近的截图 + 剪贴板（不走防抖，立即执行）。
    func loadRecent() {
        performSearch("")
    }

    /// 操作后刷新列表（保存/删除后重新加载当前搜索）。
    func refresh() {
        performSearch(query.trimmingCharacters(in: .whitespaces))
    }

    // MARK: 搜索

    private func performSearch(_ q: String) {
        isSearching = true
        let shotStore = ShotStore.shared
        let clipboardStore = ClipboardHistoryStore.shared

        Task { [weak self] in
            guard let self else { return }
            async let shots: [Shot] = Task.detached(priority: .userInitiated) {
                let ids = await shotStore.allMatchingIDs(query: q, filter: .all)
                return await shotStore.shotsInBackground(ids: Array(ids.prefix(30)))
            }.value
            async let clips: [ClipboardHistoryItem] = Task.detached(priority: .userInitiated) {
                (try? clipboardStore.recent(limit: 50, query: q.isEmpty ? nil : q)) ?? []
            }.value

            let shotResults = await shots
            let clipResults = await clips

            guard !Task.isCancelled else { return }

            var results: [SearchEntry] = []

            for shot in shotResults {
                results.append(SearchEntry(
                    id: "shot-\(shot.id ?? 0)",
                    source: .shot(shot),
                    title: shot.customTitle ?? shot.windowTitle ?? "截图",
                    subtitle: shot.appName ?? "",
                    timestamp: shot.capturedAt,
                    kind: .screenshot
                ))
            }

            for clip in clipResults {
                let kind: SearchEntry.EntryKind
                switch clip.kind {
                case .text: kind = .clipboardText
                case .image: kind = .clipboardImage
                case .file: kind = .clipboardFile
                }
                let title: String
                switch clip.kind {
                case .text:
                    title = clip.text?.prefix(60).description ?? "文本"
                case .image:
                    title = clip.title ?? "图片"
                case .file:
                    title = clip.title ?? "文件"
                }
                results.append(SearchEntry(
                    id: "clip-\(clip.id ?? 0)",
                    source: .clipboard(clip),
                    title: title,
                    subtitle: clip.sourceApp ?? "",
                    timestamp: clip.capturedAt,
                    kind: kind
                ))
            }

            results.sort { $0.timestamp > $1.timestamp }
            results = Array(results.prefix(30))

            self.entries = results
            self.selectedIndex = 0
            self.isSearching = false
            self.updatePreview()
            self.loadThumbnails()
        }
    }

    // MARK: 预览

    private func updatePreview() {
        previewLoadTask?.cancel()
        previewImage = nil
        previewText = nil
        guard let entry = selectedEntry else { return }

        switch entry.source {
        case .shot(let shot):
            guard let id = shot.id else { return }
            // 先显示已有缓存（缩略图或原图），快速反馈
            if let original = shotOriginals[id] {
                previewImage = original
            } else if let thumb = shotThumbnails[id] {
                previewImage = thumb
            } else {
                let url = ShotStore.shared.thumbnailURL(for: shot)
                previewImage = NSImage(contentsOf: url)
            }
            // 后台加载原图（放大不模糊）
            if shotOriginals[id] == nil {
                let originalURL = ShotStore.shared.originalURL(for: shot)
                previewLoadTask = Task { [weak self] in
                    let image = await Task.detached {
                        NSImage(contentsOf: originalURL)
                    }.value
                    guard !Task.isCancelled, let image,
                          let self, self.selectedEntry?.id == entry.id else { return }
                    self.shotOriginals[id] = image
                    self.previewImage = image
                }
            }
        case .clipboard(let clip):
            switch clip.kind {
            case .text:
                previewText = clip.text
            case .image:
                if let id = clip.id, let cached = clipboardThumbnails[id] {
                    previewImage = cached
                } else if let url = ClipboardHistoryStore.shared.content(of: clip).assetURL {
                    previewImage = NSImage(contentsOf: url)
                }
            case .file:
                if let url = ClipboardHistoryStore.shared.content(of: clip).assetURL {
                    previewImage = NSImage(contentsOf: url)
                }
            }
        }
    }

    private func loadThumbnails() {
        for entry in entries {
            switch entry.source {
            case .shot(let shot):
                guard let id = shot.id, shotThumbnails[id] == nil else { continue }
                let url = ShotStore.shared.thumbnailURL(for: shot)
                Task.detached { [weak self] in
                    guard let image = NSImage(contentsOf: url) else { return }
                    await MainActor.run { self?.shotThumbnails[id] = image }
                }
            case .clipboard(let clip):
                guard clip.kind == .image, let id = clip.id, clipboardThumbnails[id] == nil else { continue }
                let url = ClipboardHistoryStore.shared.content(of: clip).assetURL
                Task.detached { [weak self] in
                    guard let url, let image = NSImage(contentsOf: url) else { return }
                    await MainActor.run { self?.clipboardThumbnails[id] = image }
                }
            }
        }
    }

    // MARK: 原图 URL（弹窗放大用）

    func originalURL(for entry: SearchEntry?) -> URL? {
        guard let entry else { return nil }
        switch entry.source {
        case .shot(let shot):
            return ShotStore.shared.originalURL(for: shot)
        case .clipboard(let clip):
            return ClipboardHistoryStore.shared.content(of: clip).assetURL
        }
    }

    // MARK: 缩略图（列表用）

    func thumbnail(for entry: SearchEntry) -> NSImage? {
        switch entry.source {
        case .shot(let shot):
            guard let id = shot.id else { return nil }
            if let cached = shotThumbnails[id] { return cached }
            let url = ShotStore.shared.thumbnailURL(for: shot)
            return NSImage(contentsOf: url)
        case .clipboard(let clip):
            guard clip.kind == .image, let id = clip.id else { return nil }
            if let cached = clipboardThumbnails[id] { return cached }
            if let url = ClipboardHistoryStore.shared.content(of: clip).assetURL {
                return NSImage(contentsOf: url)
            }
            return nil
        }
    }

    // MARK: 元信息（预览区第二行）

    /// 图片尺寸 + 文件大小 / 文本字数 / 来源 App。
    func metaLine(for entry: SearchEntry?) -> String {
        guard let entry else { return "" }
        var parts: [String] = []

        switch entry.source {
        case .shot(let shot):
            if let url = ShotStore.shared.originalURL(for: shot) as URL?,
               let image = NSImage(contentsOf: url) {
                let w = Int(image.size.width)
                let h = Int(image.size.height)
                parts.append("\(w)×\(h)")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int {
                    parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
            }
            if let app = shot.appName, !app.isEmpty {
                parts.append(app)
            }
        case .clipboard(let clip):
            switch clip.kind {
            case .text:
                if let text = clip.text {
                    parts.append("\(text.count) 字")
                }
            case .image, .file:
                if let url = ClipboardHistoryStore.shared.content(of: clip).assetURL,
                   let image = NSImage(contentsOf: url) {
                    parts.append("\(Int(image.size.width))×\(Int(image.size.height))")
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let size = attrs[.size] as? Int {
                        parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                }
            }
            if let app = clip.sourceApp, !app.isEmpty {
                parts.append("来自 \(app)")
            }
        }
        return parts.joined(separator: " · ")
    }

    var isClipboardEntry: Bool {
        if case .clipboard = selectedEntry?.source { return true }
        return false
    }

    // MARK: 操作

    /// 复制选中条目到剪贴板（图片→PNG / 文本→纯文本 / 截图→PNG）。
    func copySelected() {
        guard let entry = selectedEntry else { return }
        switch entry.source {
        case .shot(let shot):
            if let url = ShotStore.shared.originalURL(for: shot) as URL?,
               let image = ImageCodec.load(from: url) {
                Clipboard.copy(image)
            }
        case .clipboard(let clip):
            ClipboardHistoryViewModel.shared.copyBack(clip)
        }
    }

    /// 复制 + 恢复前台应用 + Cmd+V（一步到位粘贴）。
    func copyAndPasteSelected() {
        copySelected()
        SearchPanelCoordinator.shared.closePanel()
        let frontmost = NSWorkspace.shared.frontmostApplication
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let app = frontmost, app.bundleIdentifier != Bundle.main.bundleIdentifier {
                app.activate(options: [])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            vDown?.flags = .maskCommand
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            vUp?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
        }
    }

    /// 剪贴板条目保存到截图库。
    func saveSelectedToLibrary() {
        guard let entry = selectedEntry,
              case .clipboard(let clip) = entry.source else { return }
        let content = ClipboardHistoryStore.shared.content(of: clip)
        guard clip.kind == .image,
              let url = content.assetURL,
              let image = ImageCodec.load(from: url) else { return }
        var meta = CaptureMetadata()
        meta.appName = clip.sourceApp
        meta.windowTitle = clip.title
        do {
            _ = try ShotStore.shared.save(image: image, metadata: meta)
            refresh()
        } catch {
            NSLog("[Index] 剪贴板保存到图库失败: \(error)")
        }
    }

    /// 删除剪贴板条目。
    func deleteSelected() {
        guard let entry = selectedEntry,
              case .clipboard(let clip) = entry.source else { return }
        ClipboardHistoryViewModel.shared.delete(clip)
        refresh()
    }

    /// 拖拽载荷（图片→data+fileURL / 文本→utf8 / 截图→fileURL）。
    func dragProvider(for entry: SearchEntry) -> NSItemProvider {
        switch entry.source {
        case .shot(let shot):
            let url = ShotStore.shared.originalURL(for: shot)
            return NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        case .clipboard(let clip):
            return ClipboardHistoryViewModel.shared.dragProvider(for: clip)
        }
    }
}
