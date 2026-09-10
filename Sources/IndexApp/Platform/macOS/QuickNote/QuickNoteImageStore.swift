import AppKit
import MarkdownEngine

// MARK: - 便签图片（统一走图库）
//
// 便签内嵌图片（![[sha256]]）统一存到图库 originals/ 目录。
// 粘贴/拖入时：算 sha256 → 查 shot 表 → 有就复用，没有就创建 shot。
// 引用 key = sha256（内容寻址，跨设备不变）。

@MainActor
enum QuickNoteImageStore {

    /// 导入剪贴板图片到图库，返回 sha256（内容寻址 key）。
    static func importClipboardImage() -> String? {
        guard let image = Clipboard.readImage() else { return nil }
        do {
            let shot = try ShotStore.shared.save(image: image, metadata: CaptureMetadata())
            return shot.sha256
        } catch {
            NSLog("[Index] 便签图片导入失败: \(error)")
            return nil
        }
    }

    /// EmbeddedImageProvider：按 sha256 从 originals/ 目录加载。
    /// 兼容旧数据：也查 quickNoteImages/（迁移前的 UUID 命名图片）。
    struct Provider: EmbeddedImageProvider {
        nonisolated func image(for reference: EmbeddedImageRequest) -> NSImage? {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Index", isDirectory: true)
            // 新路径：originals/<sha256>.<ext>
            let originals = base.appendingPathComponent("originals", isDirectory: true)
            for ext in ["png", "jpg", "jpeg", "webp", "svg"] {
                let url = originals.appendingPathComponent("\(reference.name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path),
                   let image = NSImage(contentsOf: url) {
                    return image
                }
            }
            // 兼容旧路径：quickNoteImages/<uuid>.png
            let legacy = base.appendingPathComponent("quickNoteImages", isDirectory: true)
            for ext in ["png", "jpg", "jpeg", "webp"] {
                let url = legacy.appendingPathComponent("\(reference.name).\(ext)")
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
