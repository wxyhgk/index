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
    /// Pasteboard 原始图片字节；解码、PNG 规范化与哈希全部交给后台 recorder。
    let imageData: Data?
    /// Finder 复制图片文件时只在主线程取得 URL，文件读取同样留给后台。
    let imageFileURL: URL?
    let fileURLs: [URL]
    let sourceApp: String?
}

/// `NSPasteboard.changeCount` 的消费门。
///
/// 监听器只关心“尚未消费”的代数。Index 从历史记录写回剪贴板准备粘贴时，
/// 会把该代数直接标记为已消费，避免自己的写入再次进入历史记录。
struct ClipboardChangeGate {
    private(set) var consumedChangeCount: Int = 0

    mutating func synchronize(to changeCount: Int) {
        consumedChangeCount = changeCount
    }

    mutating func consumeIfChanged(_ changeCount: Int) -> Bool {
        guard changeCount != consumedChangeCount else { return false }
        consumedChangeCount = changeCount
        return true
    }
}

@MainActor
final class ClipboardWatcher {

    /// 轮询间隔（秒）。
    static let pollInterval: TimeInterval = 0.4

    /// 剪贴板变化时的回调（主线程）。
    var onChange: ((ClipboardSnapshot) -> Void)?

    private var timer: Timer?
    private var changeGate = ClipboardChangeGate()

    nonisolated init() {}

    func start() {
        guard timer == nil else { return }
        changeGate.synchronize(to: NSPasteboard.general.changeCount)
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

    /// 消费当前剪贴板代数，但不触发 `onChange`。
    /// 仅供“从历史记录写回并粘贴”使用；普通复制仍会被正常记录。
    func suppressCurrentPasteboardChange() {
        changeGate.synchronize(to: NSPasteboard.general.changeCount)
    }

    private func poll() {
        let current = NSPasteboard.general.changeCount
        guard changeGate.consumeIfChanged(current) else { return }

        let snapshot = Self.extract()
        onChange?(snapshot)
    }

    /// 从剪贴板提取内容。优先级：图片 > 文件 > 文本。
    /// 同时存在时只取最高优先级的（避免浏览器复制图片时同时记录 URL 文本）。
    static func extract() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // 主线程只从 NSPasteboard 复制原始表示，不在轮询回调里解码像素。
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return ClipboardSnapshot(
                text: nil,
                imageData: data,
                imageFileURL: nil,
                fileURLs: [],
                sourceApp: sourceApp
            )
        }

        // 文件 URL：图片文件延后解码，普通文件仍按路径记录。
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            if let imageURL = urls.first(where: { ImageImportCoordinator.supports($0) }) {
                return ClipboardSnapshot(
                    text: nil,
                    imageData: nil,
                    imageFileURL: imageURL,
                    fileURLs: [],
                    sourceApp: sourceApp
                )
            }
            return ClipboardSnapshot(
                text: nil,
                imageData: nil,
                imageFileURL: nil,
                fileURLs: urls,
                sourceApp: sourceApp
            )
        }

        // 文本
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return ClipboardSnapshot(
                text: text,
                imageData: nil,
                imageFileURL: nil,
                fileURLs: [],
                sourceApp: sourceApp
            )
        }

        return ClipboardSnapshot(
            text: nil,
            imageData: nil,
            imageFileURL: nil,
            fileURLs: [],
            sourceApp: sourceApp
        )
    }
}
