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

    // MARK: 结构化复制（屏幕剪贴板）
    //
    // 一个 NSPasteboardItem 上同时写多种格式，目标应用各取所需：
    //   · PNG（兜底，所有应用都能粘贴）
    //   · 纯文本（备忘录/微信/终端）
    //   · com.apple.color（Figma/设计工具，色值）
    //   · public.url（浏览器直接打开）

    /// 图片 + 文本（OCR 结果）。文本粘贴到备忘录，图片粘贴到设计工具。
    static func copy(image: CGImage, text: String?) {
        guard let pngData = ImageCodec.pngData(from: image) else { return }
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        if let text, !text.isEmpty {
            item.setString(text, forType: .string)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// 色块：com.apple.color + 纯文本色值 + PNG。
    static func copy(colorHex: String, image: CGImage) {
        guard let pngData = ImageCodec.pngData(from: image) else { return }
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        item.setString(colorHex, forType: .string)
        // com.apple.color：RGBA 4 字节
        if let color = NSColor(hexString: colorHex),
           let srgb = color.usingColorSpace(.sRGB) {
            var rgba: [UInt8] = [
                UInt8(srgb.redComponent * 255),
                UInt8(srgb.greenComponent * 255),
                UInt8(srgb.blueComponent * 255),
                UInt8(srgb.alphaComponent * 255)
            ]
            item.setData(Data(rgba), forType: NSPasteboard.PasteboardType("com.apple.color"))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// URL：public.url + 纯文本 + PNG。
    static func copy(url: String, image: CGImage) {
        guard let pngData = ImageCodec.pngData(from: image) else { return }
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        item.setString(url, forType: .string)
        if let urlObj = URL(string: url),
           let urlData = urlObj.absoluteString.data(using: .utf8) {
            item.setData(urlData, forType: NSPasteboard.PasteboardType("public.url"))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}

// MARK: - NSColor hex 解析

extension NSColor {
    /// 解析 "#RRGGBB" 格式色值。
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
