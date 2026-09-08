import AppKit
import ApplicationServices
import IndexSearchCore

/// 与当前中文输入法共存的“输入即检索”。
///
/// 它不监听或吞掉键盘事件，只通过辅助功能读取当前光标前最多 128 个已提交字符。
/// 密码框、Index 自身窗口以及无法提供文本范围的控件都会被跳过。
@MainActor
final class FocusedTextSearchController {
    private enum Constant {
        static let enabledKey = "index.context-search.enabled"
        static let pollInterval: TimeInterval = 0.30
        static let permissionPollInterval: TimeInterval = 1.0
        static let textWindowLength = 128
    }

    private let panel = ContextSearchPanelController()
    private let focusedTextReader = FocusedTextSnapshotReader()
    private let searchExecutor = IndexSearchExecutor()
    private var pollTimer: Timer?
    private var permissionTimer: Timer?
    private var focusedTextTask: Task<Void, Never>?
    private var focusedTextTaskID: UUID?
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    private var lastQuery: String?
    private var didLogRepositoryError = false

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Constant.enabledKey)
    }

    func restoreIfEnabled() {
        guard isEnabled else { return }
        ensureStarted(promptIfNeeded: false)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Constant.enabledKey)
        if enabled {
            ensureStarted(promptIfNeeded: true)
        } else {
            stop()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        generation += 1
        focusedTextTask?.cancel()
        focusedTextTask = nil
        focusedTextTaskID = nil
        searchTask?.cancel()
        searchTask = nil
        lastQuery = nil
        panel.hide()
    }

    private func ensureStarted(promptIfNeeded: Bool) {
        guard isEnabled else { return }
        guard AXIsProcessTrusted() else {
            if promptIfNeeded {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                    as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            startPermissionPolling()
            return
        }

        permissionTimer?.invalidate()
        permissionTimer = nil
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Constant.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollFocusedText() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollFocusedText()
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: Constant.permissionPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ensureStarted(promptIfNeeded: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func pollFocusedText() {
        guard isEnabled, AXIsProcessTrusted() else {
            stopSearchAndHide()
            return
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            stopSearchAndHide()
            return
        }
        // AX 调用是同步 IPC，目标应用卡顿时可能几十到数百毫秒才返回。每次只允许
        // 一个后台读取，慢响应不会堆积，也不会占住主线程影响打字和窗口拖动。
        guard focusedTextTask == nil else { return }
        let activeGeneration = generation
        let fallbackPoint = NSEvent.mouseLocation
        let taskID = UUID()
        focusedTextTaskID = taskID
        focusedTextTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await focusedTextReader.snapshot()
            guard focusedTextTaskID == taskID else { return }
            focusedTextTask = nil
            focusedTextTaskID = nil
            guard !Task.isCancelled, activeGeneration == generation else { return }
            guard let snapshot else {
                stopSearchAndHide()
                return
            }
            guard snapshot.query != lastQuery else { return }
            lastQuery = snapshot.query
            let caretFrame = snapshot.coreGraphicsCaretBounds.map(Geometry.coreGraphicsToAppKit)
                ?? NSRect(origin: fallbackPoint, size: NSSize(width: 1, height: 20))
            scheduleSearch(query: snapshot.query, caretFrame: caretFrame)
        }
    }

    private func scheduleSearch(query: String, caretFrame: NSRect) {
        generation += 1
        let activeGeneration = generation
        searchTask?.cancel()

        searchTask = Task { @MainActor [weak self] in
            do {
                let results = try await self?.searchExecutor.search(query: query, limit: 5) ?? []
                guard let self,
                      !Task.isCancelled,
                      activeGeneration == self.generation,
                      self.lastQuery == query
                else { return }
                if results.isEmpty {
                    self.panel.hide()
                } else {
                    self.panel.show(results: results, query: query, caretFrame: caretFrame)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.panel.hide()
                if !self.didLogRepositoryError {
                    self.didLogRepositoryError = true
                    NSLog("[IndexContextSearch] \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopSearchAndHide() {
        guard lastQuery != nil || searchTask != nil else { return }
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        lastQuery = nil
        panel.hide()
    }

}

private struct FocusedTextSnapshot: Sendable {
    let query: String
    let coreGraphicsCaretBounds: CGRect?
}

/// AXUIElement 永远不跨隔离域；所有同步辅助功能 IPC 都在这个串行 actor 内完成。
private actor FocusedTextSnapshotReader {
    private let textWindowLength = 128

    func snapshot() -> FocusedTextSnapshot? {
        guard !Task.isCancelled else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        guard let element = elementAttribute(systemWide, kAXFocusedUIElementAttribute),
              !isSecureTextElement(element),
              let selectedRange = rangeAttribute(element, kAXSelectedTextRangeAttribute),
              selectedRange.location >= 0,
              let text = textBeforeCaret(in: element, caretLocation: selectedRange.location),
              let query = ContextQueryExtractor.query(fromTextBeforeCaret: text)
        else { return nil }
        return FocusedTextSnapshot(
            query: query,
            coreGraphicsCaretBounds: caretBounds(in: element, location: selectedRange.location)
        )
    }

    private func isSecureTextElement(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String
    }

    private func textBeforeCaret(in element: AXUIElement, caretLocation: Int) -> String? {
        let start = max(0, caretLocation - textWindowLength)
        var range = CFRange(location: start, length: caretLocation - start)
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            var rawText: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &rawText
            )
            if status == .success, let text = rawText as? String { return text }
        }

        guard stringAttribute(element, kAXRoleAttribute) == kAXTextFieldRole as String,
              let fullText = stringAttribute(element, kAXValueAttribute)
        else { return nil }
        let nsText = fullText as NSString
        let safeCaret = min(max(0, caretLocation), nsText.length)
        let safeStart = max(0, safeCaret - textWindowLength)
        return nsText.substring(with: NSRange(location: safeStart, length: safeCaret - safeStart))
    }

    private func caretBounds(in element: AXUIElement, location: Int) -> CGRect? {
        var range = CFRange(location: location, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var rawBounds: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rawBounds
        )
        guard status == .success,
              let rawBounds,
              CFGetTypeID(rawBounds) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(rawBounds as! AXValue, .cgRect, &rect),
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              !rect.isEmpty
        else { return nil }
        return rect
    }

    private func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func rangeAttribute(_ element: AXUIElement, _ key: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}

/// 数据库搜索同样串行化；取消的旧请求会在进入同步 GRDB 查询前退出，避免快速输入时
/// 产生一串无法取消的 detached 查询。
private actor IndexSearchExecutor {
    private var repository: IndexSearchRepository?

    func search(query: String, limit: Int) throws -> [IndexSearchResult] {
        try Task.checkCancellation()
        let repository: IndexSearchRepository
        if let existing = self.repository {
            repository = existing
        } else {
            let created = try IndexSearchRepository()
            self.repository = created
            repository = created
        }
        try Task.checkCancellation()
        return try repository.search(query, limit: limit)
    }
}
