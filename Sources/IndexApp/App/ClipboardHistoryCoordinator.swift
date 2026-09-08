import AppKit
import CoreGraphics
import CryptoKit
import Foundation

// ============================================================
// MARK: - 剪贴板历史协调器
//
// 接线：ClipboardWatcher（Platform 监听）→ 去重哈希 → ClipboardHistoryStore（入库）
//      → ClipboardHistoryPanel（浮动面板展示）。
//
// 结构仿 CaptureCoordinator：单例 + 依赖注入 init（可注入 Fake store）。
// ============================================================

@MainActor
final class ClipboardHistoryCoordinator {

    static let shared = ClipboardHistoryCoordinator()

    private let watcher: ClipboardWatcher
    private let store: ClipboardHistoryStore
    private let recorder: ClipboardHistoryRecorder
    private var panel: ClipboardHistoryPanel?
    /// 面板打开前的应用、窗口与输入控件，粘贴时逐层恢复。
    private var previousPasteTarget: ClipboardPasteTarget?

    /// 面板显示状态的观察者（菜单栏/设置用）。
    var onPanelVisibilityChanged: ((Bool) -> Void)?

    init(watcher: ClipboardWatcher = ClipboardWatcher(),
         store: ClipboardHistoryStore = .shared) {
        self.watcher = watcher
        self.store = store
        self.recorder = ClipboardHistoryRecorder(store: store)
        watcher.onChange = { [recorder] snapshot in
            Task { await recorder.record(snapshot) }
        }
    }

    // MARK: 生命周期

    func start() {
        watcher.start()
    }

    func stop() {
        watcher.stop()
    }

    // MARK: 面板

    /// 显示/隐藏浮动面板（全局快捷键调这里）。
    func togglePanel() {
        if let panel, panel.isVisible {
            panel.close()
            onPanelVisibilityChanged?(false)
            return
        }
        showPanel()
    }

    func showPanel() {
        if panel == nil {
            panel = ClipboardHistoryPanel(store: store)
            panel?.onClose = { [weak self] in
                self?.onPanelVisibilityChanged?(false)
            }
            panel?.onPanelShown = { [weak self] in
                self?.onPanelVisibilityChanged?(true)
            }
        }
        // 记住打开面板前的前台应用（排除 Index 自身），粘贴时恢复焦点到它。
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousPasteTarget = frontmost.map(ClipboardPasteTarget.capture)
        }
        NSLog(
            "[Index][ClipboardPaste] panel show targetPID=%d targetBundle=%@",
            previousPasteTarget?.processIdentifier ?? 0,
            previousPasteTarget?.application.bundleIdentifier ?? "none"
        )
        panel?.show()
    }

    /// 面板钉住状态（点击外部不关闭）。
    var isPinned: Bool {
        get { panel?.isPinned ?? false }
        set { panel?.isPinned = newValue }
    }

    var supportsDirectPaste: Bool {
        IndexDistribution.supportsGlobalAccessibilityFeatures
    }

    /// 粘贴流程：关面板 → 恢复焦点到之前应用 → 确认激活后模拟 Cmd+V。
    /// 固定 150/300ms 延迟在较慢应用上会把 ⌘V 发给错误窗口；激活确认与
    /// CGEvent 注入统一收在 Platform 的 ClipboardPasteDispatcher。
    func performPaste() {
        // ViewModel 已同步把历史内容写回 NSPasteboard。先消费这次内部 changeCount，
        // 否则下一轮 ClipboardWatcher 会把“粘贴历史”误当成一次新的外部复制。
        watcher.suppressCurrentPasteboardChange()

        let target = previousPasteTarget
        previousPasteTarget = nil
        NSLog(
            "[Index][ClipboardPaste] dispatch direct=%d targetPID=%d panelVisible=%d",
            supportsDirectPaste ? 1 : 0,
            target?.processIdentifier ?? 0,
            panel?.isVisible == true ? 1 : 0
        )
        if let panel, panel.isVisible {
            panel.close()
        }

        // Mac App Store 版本启用 App Sandbox，不能承诺向其他进程注入键盘事件。
        // 内容已经在剪贴板中：只恢复目标应用，让用户按一次系统 Cmd+V。
        guard supportsDirectPaste else {
            if let target {
                target.application.activate(options: [])
            } else {
                AgentCoordinator.shared.refocus()
            }
            return
        }

        if let target {
            ClipboardPasteDispatcher.paste(into: target)
        } else {
            // 之前前台就是 Index 自身（Agent 面板打开时），让 Agent 面板重新成为 key window。
            AgentCoordinator.shared.refocus()
            ClipboardPasteDispatcher.pasteIntoCurrentAppAfterFocusRestores()
        }
    }

    // MARK: 工具

    nonisolated static func hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 文本摘要：取第一行，截断到 120 字符。
    nonisolated static func summary(for text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 120 { return trimmed }
        return String(trimmed.prefix(120)) + "…"
    }
}

/// 串行后台记录器：保持剪贴板事件顺序，同时把像素、哈希、文件和数据库工作移出主线程。
private actor ClipboardHistoryRecorder {
    let store: ClipboardHistoryStore

    init(store: ClipboardHistoryStore) {
        self.store = store
    }

    func record(_ snapshot: ClipboardSnapshot) {
        do {
            if let data = snapshot.imageData,
               let image = ImageCodec.load(from: data) {
                try recordImage(image, sourceApp: snapshot.sourceApp)
            } else if let url = snapshot.imageFileURL,
                      let image = ImageCodec.load(from: url) {
                try recordImage(image, sourceApp: snapshot.sourceApp)
            } else if !snapshot.fileURLs.isEmpty {
                try recordFiles(snapshot.fileURLs, sourceApp: snapshot.sourceApp)
            } else if let text = snapshot.text {
                try recordText(text, sourceApp: snapshot.sourceApp)
            }
        } catch {
            NSLog("[Index] 剪贴板历史记录失败: \(error)")
        }
    }

    private func recordText(_ text: String, sourceApp: String?) throws {
        let hash = ClipboardHistoryCoordinator.hash(Data(text.utf8))
        try store.record(
            kind: .text,
            contentHash: hash,
            text: text,
            assetPath: nil,
            summary: ClipboardHistoryCoordinator.summary(for: text),
            sourceApp: sourceApp
        )
    }

    private func recordImage(_ image: CGImage, sourceApp: String?) throws {
        guard let data = ImageCodec.pngData(from: image) else { return }
        let sha = ClipboardHistoryCoordinator.hash(data)
        let assetPath = try store.writeImageAsset(data, sha: sha)
        try store.record(
            kind: .image,
            contentHash: sha,
            text: nil,
            assetPath: assetPath,
            summary: "图片 \(image.width)×\(image.height)",
            sourceApp: sourceApp
        )
    }

    private func recordFiles(_ urls: [URL], sourceApp: String?) throws {
        let paths = urls.map(\.path).sorted()
        let hash = ClipboardHistoryCoordinator.hash(Data(paths.joined(separator: "\n").utf8))
        let fileName = "\(hash).json"
        try JSONEncoder().encode(urls.map(\.path)).write(
            to: store.assetDirectory.appendingPathComponent(fileName),
            options: .atomic
        )
        try store.record(
            kind: .file,
            contentHash: hash,
            text: nil,
            assetPath: fileName,
            summary: urls.first?.lastPathComponent ?? "文件",
            sourceApp: sourceApp
        )
    }
}
