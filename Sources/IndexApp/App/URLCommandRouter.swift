import AppKit

/// `index://` URL scheme 的解析与执行；同时兼容既有 `macshot://` 自动化。
///
/// 这是对外的自动化接口 —— 快捷指令「打开 URL」、Raycast/Alfred、终端 `open` 都走它：
///
///   index://capture              立即截图
///   index://capture?delay=5      延时截图（本次覆盖设置里的秒数）
///   index://gallery              打开图库
///   index://gallery?query=xxx    打开图库并执行搜索
///   index://last/copy            复制最近一张截图（含标注，与图库右键「拷贝」同一渲染）
///   index://last/reveal          在访达中显示最近一张截图
///   index://import/browser?id=…  消费 Edge Native Messaging 专用收件箱中的图片
///
/// 未知命令记日志忽略，不弹窗 —— 自动化调用方拿不到弹窗，弹了也没人看。
@MainActor
final class URLCommandRouter {

    private let shotStore: any ShotReading
    private let galleryViewModel: GalleryViewModel?
    private let captureCoordinator: CaptureCoordinator
    private let imageImporter: ImageImportCoordinator
    private let browserInboxRoot: URL?
    private let showGallery: @MainActor () -> Void
    private var browserImportTask: Task<Void, Never>?

    /// `capture?delay=N` 的一次性延时覆盖.
    /// `DelayedScreenSource` 的秒数闭包由 AppDelegate 注入，注入处优先消费这里的值，
    /// 消费即清空 —— 只影响本次，不写回设置。
    private var oneShotDelay: Int?

    init(
        shotStore: (any ShotReading)? = nil,
        galleryViewModel: GalleryViewModel? = nil,
        captureCoordinator: CaptureCoordinator? = nil,
        imageImporter: ImageImportCoordinator? = nil,
        browserInboxRoot: URL? = nil,
        showGallery: @escaping @MainActor () -> Void = { GalleryWindowController.shared.show() }
    ) {
        let resolvedStore = shotStore ?? ShotStore.shared
        self.shotStore = resolvedStore
        self.galleryViewModel = galleryViewModel ?? Self.resolveViewModel(for: resolvedStore)
        self.captureCoordinator = captureCoordinator ?? .shared
        self.imageImporter = imageImporter ?? Self.resolveImporter(for: resolvedStore)
        self.browserInboxRoot = browserInboxRoot
        self.showGallery = showGallery
    }

    /// shared store 返回共享 ViewModel，非 shared（Fake 等）返回 nil。
    private static func resolveViewModel(for store: any ShotReading) -> GalleryViewModel? {
        guard let concrete = store as? ShotStore, concrete === ShotStore.shared else { return nil }
        return .shared
    }

    private static func resolveImporter(for store: any ShotReading) -> ImageImportCoordinator {
        guard let concrete = store as? ShotStore else { return .shared }
        return .resolve(for: concrete)
    }

    /// 预览可用 Fake
    static var preview: URLCommandRouter {
        URLCommandRouter(shotStore: FakeShotStore(), captureCoordinator: .preview)
    }

    /// 供 AppDelegate 注入延时源时调用：有覆盖值就取走，没有返回 nil。
    func consumeDelayOverride() -> Int? {
        defer { oneShotDelay = nil }
        return oneShotDelay
    }

    func handle(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["index", "macshot"].contains(scheme) else {
            return
        }
        NSLog("[Index] URL 命令: \(url.absoluteString)")

        // index://capture → host = "capture"；index://last/copy → host = "last"，path = "/copy"
        let host = url.host?.lowercased() ?? ""
        let subpath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let query = queryItems(of: url)

        switch (host, subpath) {
        case ("capture", ""):
            if let delay = query["delay"].flatMap(Int.init), delay > 0 {
                oneShotDelay = delay
                captureCoordinator.begin(sourceID: CaptureSourceID.delayed)
            } else {
                captureCoordinator.begin()
            }

        case ("gallery", ""):
            if let text = query["query"], !text.isEmpty {
                galleryViewModel?.clearSemanticResults()
                galleryViewModel?.semanticMode = false
                galleryViewModel?.searchText = text
            }
            // show() 内部按 GalleryViewModel 当前查询刷新。
            showGallery()

        case ("last", "copy"):
            withLastShot { shot, store in
                guard let base = store.originalImage(for: shot) else { return }
                let layers = store.latestRevision(for: shot)?.imageLayers ?? Layers()
                Clipboard.copy(LayerRenderer.render(base: base, layers: layers))
            }

        case ("last", "reveal"):
            withLastShot { shot, store in
                SystemNavigator.revealInFinder(store.originalURL(for: shot))
            }

        case ("import", "browser"):
            guard let id = query["id"], !id.isEmpty else {
                NSLog("[Index] 浏览器导入忽略：缺少 id")
                return
            }
            importBrowserItem(id: id)

        default:
            NSLog("[Index] 未知的 URL 命令: \(url.absoluteString)")
        }
    }

    // MARK: - 私有

    /// 「最近一张」= `shots.first`（按捕获时间倒序）。
    /// 注意 `shots` 受图库搜索词/筛选影响 —— 这是已知局限，够用且行为可解释。
    private func withLastShot(_ body: (Shot, any ShotReading) -> Void) {
        guard let shot = shotStore.shots.first else {
            NSLog("[Index] URL 命令忽略：截图库为空")
            return
        }
        body(shot, shotStore)
    }

    func waitForPendingBrowserImport() async {
        await browserImportTask?.value
    }

    private func importBrowserItem(id: String) {
        let item: BrowserImportInbox.Item
        do {
            item = try BrowserImportInbox.item(id: id, rootDirectory: browserInboxRoot)
        } catch {
            NSLog("[Index] 浏览器导入收件箱无效: \(error.localizedDescription)")
            if let itemID = UUID(uuidString: id) {
                BrowserImportInbox.writeCompletion(
                    .init(ok: false, fileName: nil, error: error.localizedDescription),
                    id: itemID,
                    rootDirectory: browserInboxRoot
                )
                BrowserImportInbox.remove(id: itemID, rootDirectory: browserInboxRoot)
            }
            return
        }

        let previousImport = browserImportTask
        browserImportTask = Task { [imageImporter, browserInboxRoot] in
            // 用户连续右键多张图片时按到达顺序串行消费；ImageImportCoordinator 是单飞的，
            // 取消上一张会让下一张撞上 busy 并把两张都误判失败。
            await previousImport?.value
            defer { BrowserImportInbox.remove(id: item.id, rootDirectory: browserInboxRoot) }
            let source = ImageImportCoordinator.BrowserSource(
                fileName: item.metadata.fileName,
                pageURL: item.metadata.pageURL,
                pageTitle: item.metadata.pageTitle,
                imageURL: item.metadata.imageURL
            )
            let report = await imageImporter.importBrowserImage(at: item.imageURL, source: source)
            let succeeded = !Task.isCancelled && report.importedCount == 1
            BrowserImportInbox.writeCompletion(
                .init(
                    ok: succeeded,
                    fileName: succeeded ? item.metadata.fileName : nil,
                    error: succeeded ? nil : "Index 无法导入这张图片。"
                ),
                id: item.id,
                rootDirectory: browserInboxRoot
            )
            guard succeeded else {
                NSLog("[Index] Edge 图片导入失败: \(item.metadata.fileName)")
                return
            }
        }
    }

    private func queryItems(of url: URL) -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        return items.reduce(into: [:]) { result, item in
            result[item.name.lowercased()] = item.value
        }
    }
}
