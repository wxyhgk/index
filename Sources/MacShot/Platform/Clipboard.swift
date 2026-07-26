import AppKit

/// 剪贴板。
///
/// 此前实现在 `Storage/ImageCodec` 里 —— 一个编解码器写 `NSPasteboard`，
/// 是典型的层级倒置：剪贴板是 UI 副作用，不该住在最底层。
@MainActor
enum Clipboard {

    static func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func copy(_ image: CGImage) {
        guard let data = ImageCodec.pngData(from: image) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }
}
