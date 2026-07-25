import SwiftUI
import AppKit

/// 缩略图内存缓存。
/// 没有它的话，SwiftUI 每次重建 body 都会把每张缩略图重新从磁盘解码一遍 —— 点选一次就卡一次。
@MainActor
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: NSImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// 异步加载 + 缓存的图片视图。命中缓存时**同步**返回，避免选中态切换时闪一下空白。
struct CachedImage: View {

    let url: URL
    /// 缓存键，用截图的 sha256 —— 内容寻址，内容不变键就不变。
    let key: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? ThumbnailCache.shared.image(forKey: key) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .task(id: key) { await load() }
    }

    private func load() async {
        if ThumbnailCache.shared.image(forKey: key) != nil { return }

        let target = url
        // 解码放到后台，主线程只做赋值。
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: target)
        }.value

        guard let data, let decoded = NSImage(data: data) else { return }
        ThumbnailCache.shared.insert(decoded, forKey: key, cost: data.count)
        image = decoded
    }
}
