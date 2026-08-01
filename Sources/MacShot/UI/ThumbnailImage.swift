import SwiftUI
import AppKit

/// 缩略图内存缓存。
/// 没有它的话，SwiftUI 每次重建 body 都会把每张缩略图重新从磁盘解码一遍 —— 点选一次就卡一次。
@MainActor
final class ThumbnailCache: ObservableObject {

    static let shared = ThumbnailCache()

    /// 每个键各自的作废版本号。`CachedImage` 把**自己那一个**编进 `.task` 的 id，
    /// 于是只有被作废的那张会重新读盘，别人一动不动。
    ///
    /// 起初这里是一个全局世代号（任何作废都 +1）。那样每保存一次修订，
    /// 编辑器胶片条上**所有**可见缩略图都会各跑一次 `load()` ——
    /// 虽然除被作废的那张之外都在第一行命中缓存返回，但几十个 `.task`
    /// 的重建本身也是活儿，而这活儿每隔一秒多就来一遍。
    @Published private(set) var versions: [String: Int] = [:]

    func version(forKey key: String) -> Int { versions[key] ?? 0 }

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

    /// 作废一张。缩略图文件被覆盖（编辑后重画）时必须调 ——
    /// 缓存键是 sha256，而 sha 只认原图字节，加标注不会让它变，
    /// 不主动作废就会一直命中旧图。
    func remove(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
        versions[key, default: 0] &+= 1
    }

    /// 全部作废（清理任务等）。这一下确实要惊动所有人，逐键 +1。
    func removeAll() {
        cache.removeAllObjects()
        for key in versions.keys { versions[key]! &+= 1 }
    }
}

/// 异步加载 + 缓存的图片视图。命中缓存时**同步**返回，避免选中态切换时闪一下空白。
struct CachedImage: View {

    let url: URL
    /// 缓存键，用截图的 sha256 —— 内容寻址，内容不变键就不变。
    let key: String

    @State private var image: NSImage?
    @Environment(\.colorScheme) private var colorScheme
    /// 只为拿到作废世代 —— 缓存被清掉时本视图要重新读盘（见 `ThumbnailCache.generation`）。
    @ObservedObject private var cacheState = ThumbnailCache.shared

    var body: some View {
        Group {
            if let image = image ?? ThumbnailCache.shared.image(forKey: key) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                // 加载中的占位。与卡片衬底同色 —— 图片出现前后底色不该跳一下。
                Rectangle().fill(DS.thumbnailBacking(colorScheme))
            }
        }
        // id 里编进**本键自己的**版本号：换图（key 变）和「这一张被重画」都要重新加载，
        // 而别人被重画时本视图纹丝不动。
        .task(id: "\(key)#\(cacheState.version(forKey: key))") { await load() }
    }

    private func load() async {
        if let hit = ThumbnailCache.shared.image(forKey: key) {
            // 命中即返回，不读盘 —— 世代变化会让所有可见卡片都跑一次这里，
            // 除被作废的那张之外全在这一行结束。
            image = hit
            return
        }
        // 缓存里没有了：先把 @State 里那份旧图丢掉，否则重画后的一瞬间
        // 屏幕上仍是旧内容（body 是 `image ?? 缓存`）。
        image = nil

        let target = url
        // 解码放到后台，主线程只做赋值。
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: target)
        }.value

        guard let data, let decoded = NSImage(data: data) else { return }
        ThumbnailCache.shared.insert(decoded, forKey: key, cost: data.count)
        // 首次从磁盘解码的图淡入 0.15s；命中缓存的同步路径不经过这里，不闪不抖。
        withAnimation(.easeOut(duration: 0.15)) { image = decoded }
    }
}
