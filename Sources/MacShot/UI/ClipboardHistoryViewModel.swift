import AppKit
import Combine

// ============================================================
// MARK: - 剪贴板历史视图模型
//
// 数据加载、搜索、类型过滤、键盘导航、复制/删除/固定动作。
// ============================================================

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {

    /// 主窗口 tab 和浮动面板共享同一个实例，避免数据不同步。
    static let shared = ClipboardHistoryViewModel(store: .shared)

    let store: ClipboardHistoryStore

    @Published var items: [ClipboardHistoryItem] = []
    @Published var query = ""
    @Published var imageThumbnails: [Int64: NSImage] = [:]
    @Published var appIcons: [String: NSImage] = [:]
    @Published var selectedIndex: Int = 0
    @Published var typeFilter: ClipboardHistoryKind? = nil

    private var searchTask: Task<Void, Never>?

    init(store: ClipboardHistoryStore) {
        self.store = store
    }

    var filteredItems: [ClipboardHistoryItem] {
        guard let typeFilter else { return items }
        return items.filter { $0.kind == typeFilter }
    }

    func refresh() {
        do {
            items = try store.recent(limit: 100, query: query.isEmpty ? nil : query)
        } catch {
            NSLog("[MacShot] 剪贴板历史读取失败: \(error)")
        }
        selectedIndex = 0
        loadThumbnails()
    }

    func searchChanged() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.applyFilter(q)
        }
    }

    func setTypeFilter(_ kind: ClipboardHistoryKind?) {
        typeFilter = kind
        selectedIndex = 0
    }

    private func applyFilter(_ q: String) {
        do {
            items = try store.recent(limit: 100, query: q.isEmpty ? nil : q)
        } catch {
            NSLog("[MacShot] 剪贴板历史搜索失败: \(error)")
        }
        selectedIndex = 0
        loadThumbnails()
    }

    private func loadThumbnails() {
        imageThumbnails.removeAll()
        for item in items where item.kind == .image {
            guard let id = item.id, let url = store.content(of: item).assetURL,
                  let image = NSImage(contentsOf: url) else { continue }
            imageThumbnails[id] = image
        }
        // 来源 App 图标（标题栏右上角）：走共享 AppIconProvider，异步解析不卡主线程。
        for item in items {
            guard let app = item.sourceApp, appIcons[app] == nil else { continue }
            Task { [weak self] in
                guard let icon = await AppIconProvider.shared.icon(forName: app) else { return }
                self?.appIcons[app] = icon
            }
        }
    }

    // MARK: 键盘导航

    func moveSelection(_ delta: Int) {
        let count = filteredItems.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    func copySelected() {
        let visible = filteredItems
        guard selectedIndex < visible.count else { return }
        let item = visible[selectedIndex]
        copyBack(item)
        ClipboardHistoryCoordinator.shared.togglePanel()
    }

    func deleteSelected() {
        let visible = filteredItems
        guard selectedIndex < visible.count else { return }
        let item = visible[selectedIndex]
        store.delete(item)
        if selectedIndex >= filteredItems.count {
            selectedIndex = max(0, filteredItems.count - 1)
        }
        refresh()
    }

    // MARK: 动作

    func copyBack(_ item: ClipboardHistoryItem) {
        let content = store.content(of: item)
        switch item.kind {
        case .text:
            if let text = content.text {
                Clipboard.copy(text: text)
            }
        case .image:
            if let url = content.assetURL, let image = ImageCodec.load(from: url) {
                Clipboard.copy(image)
            }
        case .file:
            if let url = content.assetURL,
               let data = try? Data(contentsOf: url),
               let paths = try? JSONDecoder().decode([String].self, from: data) {
                let urls = paths.map { URL(fileURLWithPath: $0) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls as [NSURL])
            }
        }
        store.markUsed(item)
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
        store.delete(item)
        refresh()
    }
}
