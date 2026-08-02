import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 把本地图片收进图库。
///
/// 与 `CaptureCoordinator` 并列：一个管「自己截的」，一个管「从外面收的」。
/// 两条路径入库之后**完全一样** —— 同一张表、同一条修订链、同一套派生流水线
/// （OCR / 分类 / 场景标签 / 相似指纹 / 语义向量对导入的图一样有效），
/// 所以搜索、标注、导出、钉图这些能力导入的图全都自动具备。
///
/// 唯一的差别是**来源元数据为空**：来源 App、窗口标题、网址是「截图那一刻」
/// 才存在的东西，事后导入的文件不可能有。这也是 `Shot.isImported` 的判据。
@MainActor
enum ImportCoordinator {

    /// 能收的图片类型。以 `UTType.image` 为准，让系统去判断 ——
    /// 手写扩展名白名单迟早漏掉某种格式（HEIC / WebP / AVIF 都是后来才有的）。
    static func canImport(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .image)
    }

    /// 从一批 URL 里挑出图片并导入。返回成功导入的张数。
    ///
    /// 目录会**递归展开**：拖一个文件夹进来就是「把里面的图都收了」，
    /// 这是文件管理器的通用预期。
    @discardableResult
    static func importItems(at urls: [URL]) -> Int {
        let files = urls.flatMap { expand($0) }.filter(canImport)
        guard !files.isEmpty else { return 0 }

        let store = ShotStore.shared
        var imported: [Shot] = []
        for file in files {
            if let shot = store.importImage(at: file) { imported.append(shot) }
        }

        // 派生处理交给流水线，与截图路径同一条。协调器不知道有几个处理器、各自做什么。
        for shot in imported {
            guard let id = shot.id,
                  let image = store.originalImage(for: shot) else { continue }
            CapturePipeline.shared.run(PostProcessInput(
                shotID: id,
                image: image,
                appBundleID: nil
            ))
        }
        return imported.count
    }

    /// 走系统面板选文件。
    static func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "导入"
        panel.message = "选择要收进图库的图片（可以选文件夹）"

        guard panel.runModal() == .OK else { return }
        let count = importItems(at: panel.urls)
        if count == 0 {
            AppAlert.info(
                "没有可导入的图片",
                message: "所选内容里没有能识别的图片格式。",
                host: GalleryWindowController.shared.window
            )
        }
    }

    /// 目录展开成里面的文件（递归）。不是目录就返回它自己。
    private static func expand(_ url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return [url]
        }
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return (enumerator?.allObjects as? [URL]) ?? []
    }
}
