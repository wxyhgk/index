import CoreGraphics
import Combine
import Foundation

/// 本地图片进入现有图库的最小编排层。
///
/// 第一版不新增图片实体或来源表：解码后直接复用 `ShotStore.save`，因此收藏、专题、
/// 标注、复制和导出无需新增分支。文件读取与 ImageIO 解码在后台执行，主 actor 只负责
/// 现有 Store 的入库事务。
@MainActor
final class ImageImportCoordinator: ObservableObject {

    struct Report: Equatable {
        let importedCount: Int
        let failedFileNames: [String]
    }

    static let shared = ImageImportCoordinator(store: .shared)

    @Published private(set) var isImporting = false

    private let store: ShotStore

    init(store: ShotStore) {
        self.store = store
    }

    nonisolated static func supports(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// UI 的 fire-and-forget 入口。失败只汇总一次，不为每个坏文件连续弹窗。
    func enqueue(_ urls: [URL]) {
        guard !isImporting else { return }
        Task {
            let report = await importImages(at: urls)
            guard !report.failedFileNames.isEmpty else { return }
            let names = report.failedFileNames.prefix(5).joined(separator: "、")
            let suffix = report.failedFileNames.count > 5
                ? " 等 \(report.failedFileNames.count) 个文件"
                : ""
            AppAlert.info(
                report.importedCount == 0 ? "没有导入图片" : "部分图片未导入",
                message: "无法读取：\(names)\(suffix)"
            )
        }
    }

    /// 可测试的导入核心。输入里的非支持格式与无法解码文件都计入失败。
    func importImages(at urls: [URL]) async -> Report {
        guard !isImporting else {
            return Report(importedCount: 0, failedFileNames: [])
        }
        isImporting = true
        defer { isImporting = false }

        let decoded = await Task.detached(priority: .utility) {
            urls.map(Self.decode)
        }.value

        var importedCount = 0
        var failedFileNames: [String] = []
        for item in decoded {
            switch item {
            case .failure(let fileName):
                failedFileNames.append(fileName)
            case .success(let image, let url):
                var metadata = CaptureMetadata()
                metadata.scale = 1
                metadata.globalRegion = CGRect(
                    x: 0,
                    y: 0,
                    width: image.width,
                    height: image.height
                )
                // 暂不扩 schema；利用现有可搜索标题保存原文件名。
                metadata.windowTitle = url.lastPathComponent
                do {
                    _ = try store.save(image: image, metadata: metadata)
                    importedCount += 1
                } catch {
                    failedFileNames.append(url.lastPathComponent)
                }
            }
        }
        return Report(importedCount: importedCount, failedFileNames: failedFileNames)
    }

    private nonisolated static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tif", "tiff",
    ]

    private nonisolated static func decode(_ url: URL) -> DecodedImage {
        guard supports(url) else { return .failure(url.lastPathComponent) }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url),
              let image = ImageCodec.load(from: data)
        else {
            return .failure(url.lastPathComponent)
        }
        return .success(image, url)
    }

    /// CGImage 是不可变 Core Foundation 值；解码完成后只跨 actor 转移所有权。
    private enum DecodedImage: @unchecked Sendable {
        case success(CGImage, URL)
        case failure(String)
    }
}
