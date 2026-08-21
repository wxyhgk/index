import AppKit

/// 剪贴板。
///
/// 此前实现在 `Storage/ImageCodec` 里 —— 一个编解码器写 `NSPasteboard`，
/// 是典型的层级倒置：剪贴板是 UI 副作用，不该住在最底层。
@MainActor
enum Clipboard {

    static func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// 读取剪贴板中的图片（PNG / TIFF / 文件 URL）。
    /// 网页复制的图片通常是 TIFF 或 PNG；从访达复制文件则是 file URL。
    static func readImage() -> CGImage? {
        let pasteboard = NSPasteboard.general
        // 优先 PNG（Index 自己复制的、多数网页截图）
        if let data = pasteboard.data(forType: .png),
           let image = ImageCodec.load(from: data) {
            return image
        }
        // TIFF（从预览、Pages、Keynote 等复制的）
        if let data = pasteboard.data(forType: .tiff),
           let image = ImageCodec.load(from: data) {
            return image
        }
        // 文件 URL（从访达复制图片文件）
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first(where: { ImageImportCoordinator.supports($0) }),
           let image = ImageCodec.load(from: url) {
            return image
        }
        return nil
    }

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

    /// 多张图片。每张写成一个独立的剪贴板条目（`NSPasteboardItem`）——
    /// 多数接收方只读第一条，但访达、邮件、Keynote 这类支持多条的会全部收下。
    /// 单张时行为与 `copy(_:)` 完全一致。
    static func copy(_ images: [CGImage]) {
        let items: [NSPasteboardItem] = images.compactMap { image in
            guard let data = ImageCodec.pngData(from: image) else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            return item
        }
        guard !items.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
