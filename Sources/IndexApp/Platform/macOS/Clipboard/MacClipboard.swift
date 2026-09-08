import CoreGraphics

/// macOS 剪贴板的 PAL 门面；未来其他平台提供自己的实现。
@MainActor
final class MacClipboard: ClipboardWriting, ClipboardReading {
    func readText() -> String? { Clipboard.readText() }
    func copy(text: String) { Clipboard.copy(text: text) }
    func copy(_ image: CGImage) { Clipboard.copy(image) }
    func copy(_ images: [CGImage]) { Clipboard.copy(images) }

    static let shared = MacClipboard()
}
