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

    struct BrowserSource: Equatable, Sendable {
        let fileName: String
        let pageURL: String?
        let pageTitle: String?
        let imageURL: String?
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
        await importRequests(urls.map { ImportRequest(url: $0, source: .local) })
    }

    /// 浏览器连接器已经把字节安全落进专用收件箱；这里仍走和本地图片相同的解码、
    /// 内容寻址和缩略图链，只额外补齐网页来源信息。
    func importBrowserImage(at url: URL, source: BrowserSource) async -> Report {
        await importRequests([ImportRequest(url: url, source: .browser(source))])
    }

    private func importRequests(_ requests: [ImportRequest]) async -> Report {
        guard !isImporting else {
            return Report(importedCount: 0, failedFileNames: [])
        }
        isImporting = true
        defer { isImporting = false }

        let decoded = await Task.detached(priority: .utility) {
            requests.map(Self.decode)
        }.value

        var importedCount = 0
        var failedFileNames: [String] = []
        for item in decoded {
            switch item {
            case .failure(let fileName):
                failedFileNames.append(fileName)
            case .success(let image, let request):
                var metadata = CaptureMetadata()
                metadata.scale = 1
                metadata.globalRegion = CGRect(
                    x: 0,
                    y: 0,
                    width: image.width,
                    height: image.height
                )
                // 暂不扩 schema；利用现有可搜索标题保存原文件名。
                switch request.source {
                case .local:
                    metadata.windowTitle = request.url.lastPathComponent
                case .browser(let source):
                    metadata.appName = "Microsoft Edge"
                    metadata.appBundleID = "com.microsoft.edgemac"
                    metadata.windowTitle = source.fileName
                    metadata.sourceURL = Self.safeWebURL(source.pageURL)
                }
                do {
                    _ = try store.save(image: image, metadata: metadata)
                    importedCount += 1
                } catch {
                    failedFileNames.append(request.url.lastPathComponent)
                }
            }
        }
        return Report(importedCount: importedCount, failedFileNames: failedFileNames)
    }

    private nonisolated static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff",
    ]

    private nonisolated static func decode(_ request: ImportRequest) -> DecodedImage {
        let url = request.url
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
        return .success(image, request)
    }

    private nonisolated static func safeWebURL(_ rawValue: String?) -> String? {
        guard let rawValue,
              let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return components.url?.absoluteString
    }

    private struct ImportRequest: Sendable {
        enum Source: Sendable {
            case local
            case browser(BrowserSource)
        }

        let url: URL
        let source: Source
    }

    /// CGImage 是不可变 Core Foundation 值；解码完成后只跨 actor 转移所有权。
    private enum DecodedImage: @unchecked Sendable {
        case success(CGImage, ImportRequest)
        case failure(String)
    }
}
