import AppKit
import Combine

// MARK: - 便签 ViewModel
//
// 便签面板的全部业务状态与逻辑。
// Panel 只负责窗口壳（show/close/动画/键盘事件），View 只负责渲染。

@MainActor
final class QuickNoteViewModel: ObservableObject {

    // MARK: 数据

    @Published var text: String = ""
    @Published var searchQuery: String = ""
    @Published var shots: [Shot] = []
    @Published var selectedShotID: Int64?
    @Published var pinnedIDs: Set<Int64> = []
    @Published var sidebarCollapsed = true
    @Published var confirmDeleteID: Int64?

    // MARK: 私有

    private let store: any ShotReading & ShotWriting & ShotObserving & ShotNoteStore
    private var saveTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lastSavedText = ""
    private var undoStack: [String] = []
    private var redoStack: [String] = []
    private var lastPushTime = Date.distantPast

    // MARK: 计算属性

    var selectedShot: Shot? {
        shots.first { $0.id == selectedShotID }
    }

    var selectedTitle: String {
        if let shot = selectedShot { return shotTitle(for: shot) }
        return "新便签"
    }

    var todos: [TodoItem] {
        Self.parseTodos(text)
    }

    var libraryDidChangePublisher: AnyPublisher<Void, Never> {
        store.libraryDidChangePublisher
    }

    // MARK: 初始化

    init(store: any ShotReading & ShotWriting & ShotObserving & ShotNoteStore = ShotStore.shared) {
        self.store = store
        // 侧边栏展开状态持久化；默认展开（便签核心是快速找上一条）
        sidebarCollapsed = UserDefaults.standard.bool(forKey: Self.sidebarCollapsedKey)
    }

    // MARK: 生命周期

    func onAppear() {
        reload()
        reloadPinned()
    }

    /// 面板关闭前调用：保存未落盘的文本。
    func flushPendingSave() {
        saveTask?.cancel()
        if text != lastSavedText, !text.isEmpty {
            persist(text)
        }
    }

    // MARK: 列表

    func reload() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        shots = store.markdownShots(query: query.isEmpty ? nil : query, limit: 50)
    }

    func reloadPinned() {
        pinnedIDs = store.pinnedShotIDs()
    }

    func searchChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.reload()
        }
    }

    // MARK: 编辑器

    func resetEditor() {
        selectedShotID = nil
        text = ""
        lastSavedText = ""
        undoStack.removeAll()
        redoStack.removeAll()
        lastPushTime = Date.distantPast
        saveTask?.cancel()
    }

    func loadLatest() {
        let latest = store.markdownShots(query: nil, limit: 1).first
        guard let shot = latest else {
            resetEditor()
            return
        }
        selectedShotID = shot.id
        if let source = store.markdownSource(for: shot) {
            text = source
            lastSavedText = source
        }
        saveTask?.cancel()
    }

    func updateText(_ newText: String) {
        let now = Date()
        if now.timeIntervalSince(lastPushTime) > 0.5 {
            lastPushTime = now
            undoStack.append(text)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        text = newText
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.persist(newText)
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(text)
        text = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(text)
        text = next
    }

    func persistNow() {
        saveTask?.cancel()
        persist(text)
    }

    // MARK: 导航

    func select(shotID: Int64) {
        guard let shot = shots.first(where: { $0.id == shotID }) else { return }
        selectedShotID = shot.id
        if let source = store.markdownSource(for: shot) {
            text = source
            lastSavedText = source
        }
        saveTask?.cancel()
    }

    func navigate(direction: Int) {
        guard !shots.isEmpty else { return }
        guard let currentIdx = shots.firstIndex(where: { $0.id == selectedShotID }) else {
            if let firstID = shots.first?.id {
                select(shotID: firstID)
            }
            return
        }
        let target = (currentIdx + direction + shots.count) % shots.count
        if let targetID = shots[target].id {
            select(shotID: targetID)
        }
    }

    func toggleSidebar() {
        sidebarCollapsed.toggle()
        UserDefaults.standard.set(sidebarCollapsed, forKey: Self.sidebarCollapsedKey)
    }

    private static let sidebarCollapsedKey = "quickNote.sidebarCollapsed"

    // MARK: 操作

    func newNote() {
        resetEditor()
        searchQuery = ""
    }

    func deleteShot(_ shotID: Int64) {
        store.delete(shotIDs: [shotID])
        if selectedShotID == shotID {
            resetEditor()
        }
        confirmDeleteID = nil
    }

    func togglePin(_ shot: Shot) {
        guard let id = shot.id else { return }
        store.togglePin(shotID: id)
        reloadPinned()
    }

    func isPinned(_ shot: Shot) -> Bool {
        shot.id.map { pinnedIDs.contains($0) } ?? false
    }

    func copyShot(_ shot: Shot) {
        guard let source = store.markdownSource(for: shot) else { return }
        Clipboard.copy(text: source)
    }

    @discardableResult
    func pasteClipboardIfEmpty() -> Bool {
        guard text.isEmpty, let clipText = Clipboard.readText(), !clipText.isEmpty else { return false }
        text = clipText
        return true
    }

    func insertSyntax(_ syntax: String) {
        var newText = text
        if !newText.isEmpty && !newText.hasSuffix("\n") {
            newText += "\n"
        }
        newText += syntax
        text = newText
    }

    func toggleTodo(at index: Int) {
        let todos = Self.parseTodos(text)
        guard index < todos.count else { return }
        let todo = todos[index]
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard todo.lineIndex < lines.count else { return }
        var line = lines[todo.lineIndex]
        if todo.done {
            line = line.replacingOccurrences(of: "- [x]", with: "- [ ]")
            line = line.replacingOccurrences(of: "- [X]", with: "- [ ]")
        } else {
            line = line.replacingOccurrences(of: "- [ ]", with: "- [x]")
        }
        lines[todo.lineIndex] = line
        text = lines.joined(separator: "\n")
    }

    // MARK: 持久化

    private func persist(_ newText: String) {
        guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard newText != lastSavedText else { return }
        do {
            if let shotID = selectedShotID {
                try store.saveContent(for: shotID, kind: .markdown, payload: .markdown(newText), updateKind: false)
                MarkdownPreviewCache.shared.update(newText, shotID: shotID)
            } else {
                let title = String(newText.prefix(30).replacingOccurrences(of: "\n", with: " "))
                let shot = try store.createMarkdownShot(title: title.isEmpty ? "便签" : title, source: newText)
                selectedShotID = shot.id
                MarkdownPreviewCache.shared.update(newText, shotID: shot.id)
            }
            lastSavedText = newText
        } catch {
            NSLog("[Index] 便签保存失败: \(error)")
        }
    }

    // MARK: 展示

    func shotTitle(for shot: Shot) -> String {
        if let source = store.markdownSource(for: shot), !source.isEmpty {
            let firstLine = source.split(separator: "\n").first.map(String.init) ?? ""
            let cleaned = firstLine.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { return String(cleaned.prefix(30)) }
        }
        return shot.windowTitle ?? "便签"
    }

    func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func groupByDay(_ shots: [Shot]) -> [(date: Date, shots: [Shot])] {
        var groups: [Date: [Shot]] = [:]
        for shot in shots {
            let day = Calendar.current.startOfDay(for: shot.capturedAt)
            groups[day, default: []].append(shot)
        }
        return groups.sorted { $0.key > $1.key }.map { (date: $0.key, shots: $0.value) }
    }

    static func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    static func parseTodos(_ source: String) -> [TodoItem] {
        var items: [TodoItem] = []
        for (i, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                items.append(TodoItem(lineIndex: i, text: String(trimmed.dropFirst(6)), done: true))
            } else if trimmed.hasPrefix("- [ ] ") {
                items.append(TodoItem(lineIndex: i, text: String(trimmed.dropFirst(6)), done: false))
            }
        }
        return items
    }
}

// MARK: - 待办项

struct TodoItem: Identifiable {
    let id = UUID()
    let lineIndex: Int
    let text: String
    let done: Bool
}
