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
    /// 搜索时每条便签的匹配上下文（shotID → snippet）
    @Published var snippets: [Int64: String] = [:]

    // MARK: 私有

    private let store: any ShotReading & ShotWriting & ShotObserving & ShotNoteStore
    private var saveTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lastSavedText = ""
    private var undoStack: [String] = []
    private var redoStack: [String] = []
    private var lastPushTime = Date.distantPast
    private var cursorPositions: [Int64: Int] = [:]
    /// 上一次选中的 shotID，供 Panel 在 selectedShotID 变化后保存旧便签的光标。
    var pendingCursorShotID: Int64?

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

    /// 字数（中文按字符、英文按词）+ 行数。
    var wordCount: String {
        var count = 0
        var inWord = false
        for char in text {
            if char.isWhitespace {
                inWord = false
            } else if char.isCJK {
                count += 1
                inWord = false
            } else {
                if !inWord { count += 1; inWord = true }
            }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(count) 字 · \(lines) 行"
    }

    // MARK: 初始化

    init(store: any ShotReading & ShotWriting & ShotObserving & ShotNoteStore = ShotStore.shared) {
        self.store = store
        sidebarCollapsed = UserDefaults.standard.object(forKey: Self.sidebarCollapsedKey) as? Bool ?? true
    }

    // MARK: 生命周期

    func onAppear() {
        reload()
        reloadPinned()
    }

    /// 面板关闭前调用：保存未落盘的文本。
    func flushPendingSave() {
        commitCurrentText()
    }

    /// 将当前 text 落盘（如果与 lastSavedText 不同）。
    /// 用于切换便签、关闭面板等需要立即持久化的场景。
    private func commitCurrentText() {
        saveTask?.cancel()
        if text != lastSavedText {
            persist(text)
        }
    }

    // MARK: 列表

    func reload() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        shots = store.markdownShots(query: query.isEmpty ? nil : query, limit: 50)
        // 搜索时生成 snippet（匹配上下文）
        if !query.isEmpty {
            snippets = shots.reduce(into: [:]) { dict, shot in
                guard let id = shot.id else { return }
                if let source = store.markdownSource(for: shot) {
                    dict[id] = Self.makeSnippet(source, query: query)
                }
            }
        } else {
            snippets = [:]
        }
    }

    /// 从 markdown 源码中截取包含 query 的一行作为 snippet。
    static func makeSnippet(_ source: String, query: String) -> String {
        let lines = source.components(separatedBy: "\n")
        let lowerQuery = query.lowercased()
        // 找第一个包含 query 的行
        for (i, line) in lines.enumerated() {
            if line.lowercased().contains(lowerQuery) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // 如果行太长，截取 query 周围的上下文
                if trimmed.count > 60 {
                    if let range = trimmed.range(of: query, options: .caseInsensitive) {
                        let start = trimmed.index(range.lowerBound, offsetBy: max(0, 20 - trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)))
                        let end = trimmed.index(range.upperBound, offsetBy: min(30, trimmed.distance(from: range.upperBound, to: trimmed.endIndex)))
                        let snippet = String(trimmed[start..<end])
                        return (start > trimmed.startIndex ? "…" : "") + snippet + (end < trimmed.endIndex ? "…" : "")
                    }
                    return String(trimmed.prefix(60)) + "…"
                }
                return trimmed
            }
        }
        // 没找到匹配行，返回第一行
        let firstLine = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
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
        pendingCursorShotID = selectedShotID
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
        pendingCursorShotID = selectedShotID
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
        scheduleSave()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(text)
        text = next
        scheduleSave()
    }

    /// 仅启动防抖保存（不压 undo 栈），供 undo/redo 等内部 text 变更使用。
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.persist(self.text)
        }
    }

    func persistNow() {
        saveTask?.cancel()
        persist(text)
    }

    // MARK: 导航

    func select(shotID: Int64) {
        guard let shot = shots.first(where: { $0.id == shotID }) else { return }
        commitCurrentText()
        pendingCursorShotID = selectedShotID
        selectedShotID = shot.id
        if let source = store.markdownSource(for: shot) {
            text = source
            lastSavedText = source
        }
        undoStack.removeAll()
        redoStack.removeAll()
        lastPushTime = Date.distantPast
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

    // MARK: 光标位置

    func saveCursorPosition(_ location: Int, for shotID: Int64) {
        cursorPositions[shotID] = location
    }

    func cursorPosition(for shotID: Int64) -> Int? {
        cursorPositions[shotID]
    }

    // MARK: 导出

    func exportAsMarkdown() {
        guard let shot = selectedShot else { return }
        QuickNoteExporter.exportMarkdown(text, suggestedName: shot.primaryDisplayName)
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
    func pasteClipboardText() -> Bool {
        guard let clipText = Clipboard.readText(), !clipText.isEmpty else { return false }
        updateText(clipText)
        return true
    }

    func insertSyntax(_ syntax: String) {
        var newText = text
        if !newText.isEmpty && !newText.hasSuffix("\n") {
            newText += "\n"
        }
        newText += syntax
        updateText(newText)
    }

    func insertImage(name: String) {
        var newText = text
        if !newText.isEmpty && !newText.hasSuffix("\n") {
            newText += "\n"
        }
        newText += "![[\(name)]]\n"
        updateText(newText)
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
        updateText(lines.joined(separator: "\n"))
    }

    // MARK: 持久化

    private func persist(_ newText: String) {
        guard newText != lastSavedText else { return }
        // 新建便签时，空内容不创建 shot
        if selectedShotID == nil {
            guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        }
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
            reload()
            // 搜索态下新建便签可能不匹配搜索词，确保它在列表里
            if let id = selectedShotID, !shots.contains(where: { $0.id == id }) {
                if let shot = store.markdownShots(query: nil, limit: 1).first(where: { $0.id == id }) {
                    shots.insert(shot, at: 0)
                }
            }
        } catch {
            NSLog("[Index] 便签保存失败: \(error)")
        }
    }

    // MARK: 展示

    func shotTitle(for shot: Shot) -> String {
        if let source = store.markdownSource(for: shot), !source.isEmpty {
            let firstLine = source.split(separator: "\n").first.map(String.init) ?? ""
            // 只剥离行首连续的 #（markdown 标题标记）
            let cleaned = firstLine.replacingOccurrences(
                of: "^#+\\s*", with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty {
                // 识别 ![[name]] 图片引用
                if cleaned.hasPrefix("![[") {
                    if let end = cleaned.range(of: "]]")?.lowerBound {
                        let start = cleaned.index(cleaned.startIndex, offsetBy: 3)
                        return String(cleaned[start..<end].prefix(30))
                    }
                }
                return String(cleaned.prefix(30))
            }
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

// MARK: - Character 扩展

private extension Character {
    /// CJK 统一表意文字（含扩展 A/B + 兼容表意文字）
    var isCJK: Bool {
        for scalar in unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x20000...0x2A6DF).contains(v)
                || (0xF900...0xFAFF).contains(v) {
                return true
            }
        }
        return false
    }
}
