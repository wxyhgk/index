import AppKit
import MarkdownEngine

// MARK: - 便签图片存储
//
// 便签内嵌图片（![[filename]]）的文件系统存储。
// 图片存到 ~/Library/Application Support/Index/quickNoteImages/，
// 文件名 = UUID.png。EmbeddedImageProvider 按文件名加载。

@MainActor
enum QuickNoteImageStore {

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Index", isDirectory: true)
        let dir = base.appendingPathComponent("quickNoteImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 保存剪贴板图片，返回文件名（不含扩展名）。
    static func saveClipboardImage() -> String? {
        guard let image = Clipboard.readImage() else { return nil }
        let name = UUID().uuidString
        let url = directory.appendingPathComponent("\(name).png")
        let nsImage = NSImage(cgImage: image, size: .zero)
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return nil }
        do {
            try png.write(to: url)
            return name
        } catch {
            NSLog("[Index] 便签图片保存失败: \(error)")
            return nil
        }
    }

    /// EmbeddedImageProvider：按文件名从 quickNoteImages 目录加载。
    struct Provider: EmbeddedImageProvider {
        nonisolated func image(for reference: EmbeddedImageRequest) -> NSImage? {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Index/quickNoteImages", isDirectory: true)
            for ext in ["png", "jpg", "jpeg", "webp"] {
                let url = base.appendingPathComponent("\(reference.name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path),
                   let image = NSImage(contentsOf: url) {
                    return image
                }
            }
            return nil
        }

        nonisolated func fingerprint() -> AnyHashable { 0 }
    }
}
