import Combine
import Foundation

enum ClipboardWorkspaceMode: String, CaseIterable, Identifiable {
    case history
    case sessions
    case threads
    case capsules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "历史"
        case .sessions: return "项目"
        case .threads: return "线程"
        case .capsules: return "胶囊"
        }
    }

    var systemImage: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .sessions: return "folder"
        case .threads: return "point.3.connected.trianglepath.dotted"
        case .capsules: return "shippingbox"
        }
    }
}

/// 点击组卡片后聚焦显示其全部条目。
struct FocusedGroup: Equatable {
    let label: String
    let items: [ClipboardHistoryItem]
}

/// AI 推断的工作上下文分组（同一 sessionLabel 的条目聚合）。
struct ClipboardSessionGroup: Identifiable {
    let id: String
    let label: String
    let items: [ClipboardHistoryItem]

    var latestAt: Date { items.first?.capturedAt ?? .distantPast }
    var earliestAt: Date { items.last?.capturedAt ?? .distantPast }
    var duration: TimeInterval { max(0, latestAt.timeIntervalSince(earliestAt)) }

    var durationText: String {
        let secs = Int(duration)
        if secs < 60 { return "\(secs) 秒" }
        return "\(max(1, secs / 60)) 分钟"
    }
}

struct ClipboardCapsulePasteProgress: Equatable {
    let capsuleID: Int64
    let name: String
    let items: [ClipboardHistoryItem]
    var nextIndex: Int

    var progressLabel: String {
        "继续粘贴 \(nextIndex + 1)/\(items.count)"
    }
}

// MARK: - 页面会话

/// 剪贴板页面自己的单选状态。它独立于 GallerySelection，也不与浮动面板共享。
@MainActor
final class ClipboardSelection: ObservableObject {
    /// 兼容旧调用点；新的页面应从 ClipboardPageSession 取得 selection。
    static let shared = ClipboardSelection()

    @Published var selectedID: Int64?

    init(selectedID: Int64? = nil) {
        self.selectedID = selectedID
    }

    func select(_ id: Int64?) {
        selectedID = (selectedID == id) ? nil : id
    }

    func clear() {
        selectedID = nil
    }

    func clearIf(_ id: Int64?) {
        if selectedID == id { selectedID = nil }
    }
}

/// 一个剪贴板页面的完整状态边界。
///
/// 主 Clipboard Tab 使用 ViewModel 的 filteredItems；收藏和专题集页面则传入自己的
/// scopedItems。Inspector 永远从同一个 session 解析选中项，不再回头读取另一个 Tab。
/// 浮动剪贴板面板继续自己创建 ClipboardHistoryViewModel，不使用此会话。
@MainActor
final class ClipboardPageSession: ObservableObject {
    static let shared = ClipboardPageSession(selection: .shared)

    let viewModel: ClipboardHistoryViewModel
    let selection: ClipboardSelection

    /// nil 表示使用 viewModel.filteredItems；非 nil 表示页面拥有显式条目快照。
    @Published private(set) var scopedItems: [ClipboardHistoryItem]?

    init(
        store: ClipboardHistoryStore = .shared,
        viewModel: ClipboardHistoryViewModel? = nil,
        selection: ClipboardSelection? = nil,
        scopedItems: [ClipboardHistoryItem]? = nil
    ) {
        self.viewModel = viewModel ?? ClipboardHistoryViewModel(store: store)
        self.selection = selection ?? ClipboardSelection()
        self.scopedItems = scopedItems
        reconcileSelection()
    }

    var visibleItems: [ClipboardHistoryItem] {
        scopedItems ?? viewModel.filteredItems
    }

    var selectedItem: ClipboardHistoryItem? {
        guard let selectedID = selection.selectedID else { return nil }
        return visibleItems.first { $0.id == selectedID }
    }

    func setScopedItems(_ items: [ClipboardHistoryItem]?) {
        guard scopedItems != items else { return }
        scopedItems = items
        reconcileSelection()
    }

    func updateScopedItem(_ item: ClipboardHistoryItem) {
        guard var scopedItems,
              let index = scopedItems.firstIndex(where: { $0.id == item.id })
        else { return }
        scopedItems[index] = item
        self.scopedItems = scopedItems
    }

    func removeScopedItem(_ item: ClipboardHistoryItem) {
        if var scopedItems {
            scopedItems.removeAll { $0.id == item.id }
            self.scopedItems = scopedItems
        }
        selection.clearIf(item.id)
    }

    private func reconcileSelection() {
        guard let selectedID = selection.selectedID,
              !visibleItems.contains(where: { $0.id == selectedID })
        else { return }
        selection.clear()
    }
}

/// 源码兼容名；新的调用点使用 ClipboardPageSession。
typealias ClipboardTabSession = ClipboardPageSession
