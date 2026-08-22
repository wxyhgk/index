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
    private var panel: ClipboardHistoryPanel?
    /// 面板打开前的前台应用，粘贴时恢复焦点到它。
    private var previousFrontmostApp: NSRunningApplication?

    /// 面板显示状态的观察者（菜单栏/设置用）。
    var onPanelVisibilityChanged: ((Bool) -> Void)?

    init(watcher: ClipboardWatcher = ClipboardWatcher(),
         store: ClipboardHistoryStore = .shared) {
        self.watcher = watcher
        self.store = store
        watcher.onChange = { [weak self] snapshot in
            self?.handle(snapshot)
        }
    }

    // MARK: 生命周期

    func start() {
        watcher.start()
    }

    func stop() {
        watcher.stop()
    }

    // MARK: 剪贴板变化处理

    private func handle(_ snapshot: ClipboardSnapshot) {
        do {
            if let image = snapshot.image {
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
        let hash = Self.hash(text.data(using: .utf8) ?? Data())
        let summary = Self.summary(for: text)
        try store.record(
            kind: .text,
            contentHash: hash,
            text: text,
            assetPath: nil,
            summary: summary,
            sourceApp: sourceApp
        )
    }

    private func recordImage(_ image: CGImage, sourceApp: String?) throws {
        guard let data = ImageCodec.pngData(from: image) else { return }
        let sha = Self.hash(data)
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
        // 多个文件合并为一条记录（hash 覆盖全部路径），摘要用第一个文件名。
        let paths = urls.map(\.path).sorted()
        let hash = Self.hash(paths.joined(separator: "\n").data(using: .utf8) ?? Data())
        let summary = urls.first?.lastPathComponent ?? "文件"
        // 文件条目不复制内容，只记路径（文件本身在用户磁盘上）。
        // assetPath 存 JSON 数组（多文件）。
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
            summary: summary,
            sourceApp: sourceApp
        )
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
            previousFrontmostApp = frontmost
        }
        panel?.show()
    }

    /// 粘贴前把焦点还给之前正在使用的应用。
    func restoreFrontmostApp() {
        if let app = previousFrontmostApp {
            app.activate(options: [])
            previousFrontmostApp = nil
        } else {
            // 之前前台就是 Index 自身（Agent 面板打开时），让 Agent 面板重新成为 key window
            AgentCoordinator.shared.refocus()
        }
    }

    /// 面板钉住状态（点击外部不关闭）。
    var isPinned: Bool {
        get { panel?.isPinned ?? false }
        set { panel?.isPinned = newValue }
    }

    /// 粘贴流程：关面板 → 恢复焦点到之前应用 → 模拟 Cmd+V。
    /// 窗口生命周期和 CGEvent 注入收口在这里，ViewModel 只负责复制内容。
    func performPaste() {
        togglePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.restoreFrontmostApp()
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
