import AppKit
import CoreGraphics

// ============================================================
// MARK: - 剪贴板监听
//
// macOS 没有原生的剪贴板变化通知，用 Timer 轮询
// `NSPasteboard.general.changeCount`（Paste 也是这个方案）。
// 0.4s 间隔是 CPU 开销和响应速度的平衡点。
//
// 平台副作用收口：NSPasteboard / NSWorkspace 只出现在这里。
// ============================================================

/// 一次剪贴板快照：提取到的内容 + 来源 App。
struct ClipboardSnapshot: Sendable {
    let text: String?
    let image: CGImage?
    let fileURLs: [URL]
    let sourceApp: String?
}

@MainActor
final class ClipboardWatcher {

    /// 轮询间隔（秒）。
    static let pollInterval: TimeInterval = 0.4

    /// 剪贴板变化时的回调（主线程）。
    var onChange: ((ClipboardSnapshot) -> Void)?

    private var timer: Timer?
    private var lastChangeCount: Int = 0

    nonisolated init() {}

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isRunning: Bool { timer != nil }

    private func poll() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        let snapshot = Self.extract()
        onChange?(snapshot)
    }

    /// 从剪贴板提取内容。优先级：图片 > 文件 > 文本。
    /// 同时存在时只取最高优先级的（避免浏览器复制图片时同时记录 URL 文本）。
    static func extract() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // 图片（PNG / TIFF / 文件 URL 中的图片）
        if let image = Clipboard.readImage() {
            return ClipboardSnapshot(text: nil, image: image, fileURLs: [], sourceApp: sourceApp)
        }

        // 文件 URL（非图片的文件）
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            return ClipboardSnapshot(text: nil, image: nil, fileURLs: urls, sourceApp: sourceApp)
        }

        // 文本
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return ClipboardSnapshot(text: text, image: nil, fileURLs: [], sourceApp: sourceApp)
        }

        return ClipboardSnapshot(text: nil, image: nil, fileURLs: [], sourceApp: sourceApp)
    }
}
