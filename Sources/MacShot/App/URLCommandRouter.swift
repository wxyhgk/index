import AppKit

/// `macshot://` URL scheme 的解析与执行.
///
/// 这是对外的自动化接口 —— 快捷指令「打开 URL」、Raycast/Alfred、终端 `open` 都走它：
///
///   macshot://capture              立即截图
///   macshot://capture?delay=5      延时截图（本次覆盖设置里的秒数）
///   macshot://gallery              打开图库
///   macshot://gallery?query=xxx    打开图库并执行搜索
///   macshot://last/copy            复制最近一张截图（含标注，与图库右键「拷贝」同一渲染）
///   macshot://last/reveal          在访达中显示最近一张截图
///
/// 未知命令记日志忽略，不弹窗 —— 自动化调用方拿不到弹窗，弹了也没人看。
@MainActor
final class URLCommandRouter {

    private let shotStore: any ShotReading
    private let captureCoordinator: CaptureCoordinator

    /// `capture?delay=N` 的一次性延时覆盖.
    /// `DelayedScreenSource` 的秒数闭包由 AppDelegate 注入，注入处优先消费这里的值，
    /// 消费即清空 —— 只影响本次，不写回设置。
    private var oneShotDelay: Int?

    init(
        shotStore: (any ShotReading)? = nil,
        captureCoordinator: CaptureCoordinator? = nil
    ) {
        self.shotStore = shotStore ?? ShotStore.shared
        self.captureCoordinator = captureCoordinator ?? CaptureCoordinator.shared
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
        guard url.scheme?.lowercased() == "macshot" else { return }
        NSLog("[MacShot] URL 命令: \(url.absoluteString)")

        // macshot://capture → host = "capture"；macshot://last/copy → host = "last"，path = "/copy"
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
                shotStore.searchText = text
            }
            // show() 内部会 reload()，searchText 随之生效。
            GalleryWindowController.shared.show()

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

        default:
            NSLog("[MacShot] 未知的 URL 命令: \(url.absoluteString)")
        }
    }

    // MARK: - 私有

    /// 「最近一张」= `shots.first`（按捕获时间倒序）。
    /// 注意 `shots` 受图库搜索词/筛选影响 —— 这是已知局限，够用且行为可解释。
    private func withLastShot(_ body: (Shot, any ShotReading) -> Void) {
        guard let shot = shotStore.shots.first else {
            NSLog("[MacShot] URL 命令忽略：截图库为空")
            return
        }
        body(shot, shotStore)
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
