import AppKit
import ImageIO
import SwiftUI

/// 一次后台解码的不可变结果。`CGImage` 可安全跨线程只读，NSImage 只在主线程创建。
struct DecodedThumbnail: @unchecked Sendable {
    let image: CGImage
    let cost: Int
}

protocol ThumbnailDecoding: Sendable {
    func decode(contentsOf url: URL) -> DecodedThumbnail?
}

/// 用 ImageIO 强制完成像素解码，避免 `NSImage(data:)` 把昂贵工作推迟到主线程绘制阶段。
struct ImageIOThumbnailDecoder: ThumbnailDecoding {
    let maximumPixelSize: Int

    init(maximumPixelSize: Int = 640) {
        self.maximumPixelSize = maximumPixelSize
    }

    func decode(contentsOf url: URL) -> DecodedThumbnail? {
        let sourceOptions = [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }

        let decodeOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions) else {
            return nil
        }
        return DecodedThumbnail(
            image: image,
            cost: ThumbnailCache.decodedCost(width: image.width, height: image.height)
        )
    }
}

/// 一个轻量异步信号量。排队中的请求响应 Task 取消，不会继续占用解码名额。
private actor ThumbnailDecodeLimiter {
    private let limit: Int
    private var activeCount = 0
    /// FIFO 顺序与 continuation 分开保存：取消按 UUID 从字典 O(1) 删除，队列里留下
    /// 一个廉价 tombstone，release 时顺手跳过。旧数组版每次取消都 firstIndex+remove，
    /// 快速滚动同时撤销几百张卡片时会退化成 O(n²)。
    private var waiterOrder: [UUID] = []
    private var waiterHead = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        let id = UUID()
        if Task.isCancelled { return false }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if activeCount < limit {
                    activeCount += 1
                    continuation.resume(returning: true)
                } else {
                    waiterOrder.append(id)
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        while waiterHead < waiterOrder.count {
            let id = waiterOrder[waiterHead]
            waiterHead += 1
            if let continuation = waiters.removeValue(forKey: id) {
                compactWaiterOrderIfNeeded()
                continuation.resume(returning: true)
                return
            }
        }
        activeCount = max(0, activeCount - 1)
        waiterOrder.removeAll(keepingCapacity: true)
        waiterHead = 0
    }

    private func cancelWaiter(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: false)
    }

    /// 防止长期滚动后 tombstone 顺序数组只增不减；摊销成本仍为 O(1)。
    private func compactWaiterOrderIfNeeded() {
        guard waiterHead >= 256, waiterHead * 2 >= waiterOrder.count else { return }
        waiterOrder.removeFirst(waiterHead)
        waiterHead = 0
    }
}

/// 后台加载管线：同一个缓存键只解码一次，并把全局并发限制在四个任务。
actor ThumbnailLoadPipeline {
    private final class InFlight: @unchecked Sendable {
        let task: Task<DecodedThumbnail?, Never>
        private let lock = NSLock()
        private var waiters: Set<UUID>

        init(task: Task<DecodedThumbnail?, Never>, waiterID: UUID) {
            self.task = task
            waiters = [waiterID]
        }

        func addWaiter(_ id: UUID) {
            _ = lock.withLock { waiters.insert(id) }
        }

        @discardableResult
        func removeWaiter(_ id: UUID) -> Bool {
            let becameEmpty = lock.withLock {
                waiters.remove(id)
                return waiters.isEmpty
            }
            if becameEmpty {
                // 必须在调用方 Task 的取消处理器内同步传播。若先异步跳回 actor，
                // 排队任务可能抢到刚释放的名额，并在取消到达前开始不可中断解码。
                task.cancel()
            }
            return becameEmpty
        }

        var isEmpty: Bool {
            lock.withLock { waiters.isEmpty }
        }
    }

    private let decoder: any ThumbnailDecoding
    private let limiter: ThumbnailDecodeLimiter
    private var inFlight: [String: InFlight] = [:]

    init(decoder: any ThumbnailDecoding = ImageIOThumbnailDecoder(), maximumConcurrentLoads: Int = 4) {
        self.decoder = decoder
        limiter = ThumbnailDecodeLimiter(limit: maximumConcurrentLoads)
    }

    func load(url: URL, key: String) async -> DecodedThumbnail? {
        guard !Task.isCancelled else { return nil }
        let waiterID = UUID()
        let request: InFlight
        if let existing = inFlight[key] {
            existing.addWaiter(waiterID)
            request = existing
        } else {
            let decoder = self.decoder
            let limiter = self.limiter
            let task = Task<DecodedThumbnail?, Never>.detached(priority: .userInitiated) {
                guard await limiter.acquire() else { return nil }
                guard !Task.isCancelled else {
                    await limiter.release()
                    return nil
                }
                let result = decoder.decode(contentsOf: url)
                await limiter.release()
                return Task.isCancelled ? nil : result
            }
            request = InFlight(task: task, waiterID: waiterID)
            inFlight[key] = request
        }

        return await withTaskCancellationHandler {
            let result = await request.task.value
            finishWaiter(waiterID, request: request, key: key)
            return Task.isCancelled ? nil : result
        } onCancel: {
            let becameEmpty = request.removeWaiter(waiterID)
            guard becameEmpty else { return }
            Task { await self.removeIfEmpty(request, key: key) }
        }
    }

    func cancelAll() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
    }

    private func finishWaiter(_ waiterID: UUID, request: InFlight, key: String) {
        request.removeWaiter(waiterID)
        removeIfEmpty(request, key: key)
    }

    private func removeIfEmpty(_ request: InFlight, key: String) {
        if inFlight[key] === request, request.isEmpty {
            inFlight.removeValue(forKey: key)
        }
    }
}

/// 每个缓存键一枚独立失效令牌。一张图重画只通知正在显示这一张的视图。
@MainActor
final class ThumbnailInvalidationToken: ObservableObject {
    @Published fileprivate(set) var version = 0

    fileprivate func invalidate() {
        version &+= 1
    }
}

/// 缩略图内存缓存。成本按解码后的像素计算，而不是 JPEG 文件的压缩字节数。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// 约容纳两屏 Retina 缩略图。可见卡片自己还会短暂持有 NSImage，缓存预算不能
    /// 再按整页 300 张估算，否则图库窗口与 SwiftUI 图层会同时放大峰值。
    nonisolated static let totalCostLimit = 128 * 1024 * 1024
    nonisolated static let countLimit = 400

    private let cache = NSCache<NSString, NSImage>()
    /// View 自己强持有正在显示的 token；缓存只弱引用。离屏后 token 可释放，浏览过
    /// 十万张图片也不会在这里永久留下十万个 ObservableObject。
    private let tokens = NSMapTable<NSString, ThumbnailInvalidationToken>(
        keyOptions: .strongMemory,
        valueOptions: .weakMemory
    )
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(observesMemoryPressure: Bool = true) {
        cache.countLimit = Self.countLimit
        cache.totalCostLimit = Self.totalCostLimit
        guard observesMemoryPressure else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // 内存压力下只释放共享缓存；不要立即通知可见卡片重读同一批图片。
            MainActor.assumeIsolated { self?.purgeMemory() }
        }
        source.resume()
        memoryPressureSource = source
    }

    nonisolated static func decodedCost(width: Int, height: Int) -> Int {
        let (pixels, pixelOverflow) = max(0, width).multipliedReportingOverflow(by: max(0, height))
        guard !pixelOverflow else { return Int.max }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return byteOverflow ? Int.max : bytes
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: NSImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func token(forKey key: String) -> ThumbnailInvalidationToken {
        if let token = tokens.object(forKey: key as NSString) { return token }
        let token = ThumbnailInvalidationToken()
        tokens.setObject(token, forKey: key as NSString)
        return token
    }

    func remove(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
        tokens.object(forKey: key as NSString)?.invalidate()
    }

    func removeAll() {
        cache.removeAllObjects()
        let enumerator = tokens.objectEnumerator()
        while let token = enumerator?.nextObject() as? ThumbnailInvalidationToken {
            token.invalidate()
        }
    }

    func purgeMemory() {
        cache.removeAllObjects()
    }
}

/// UI 使用的统一缩略图入口。缓存和 AppKit 对象留在主线程，像素解码留在 actor 管线。
@MainActor
protocol ThumbnailLoading: AnyObject {
    func cachedImage(forKey key: String) -> NSImage?
    func invalidationToken(forKey key: String) -> ThumbnailInvalidationToken
    func load(url: URL, key: String) async -> NSImage?
    func remove(forKey key: String)
    func removeAll()
}

@MainActor
final class ThumbnailLoader: ThumbnailLoading {
    static let shared = ThumbnailLoader(cache: .shared, pipeline: ThumbnailLoadPipeline())

    private let cache: ThumbnailCache
    private let pipeline: ThumbnailLoadPipeline
    private var hasReportedFirstDecode = false
    private var isLoadingEnabled = true
    private var pendingSuspension: Task<Void, Never>?

    init(cache: ThumbnailCache, pipeline: ThumbnailLoadPipeline) {
        self.cache = cache
        self.pipeline = pipeline
    }

    func cachedImage(forKey key: String) -> NSImage? {
        cache.image(forKey: key)
    }

    func invalidationToken(forKey key: String) -> ThumbnailInvalidationToken {
        cache.token(forKey: key)
    }

    func load(url: URL, key: String) async -> NSImage? {
        if let hit = cache.image(forKey: key) { return hit }
        guard isLoadingEnabled else { return nil }
        if let pendingSuspension {
            await pendingSuspension.value
            self.pendingSuspension = nil
            guard isLoadingEnabled else { return nil }
        }
        // 强持有 token 直到解码结束。重画会递增 version；新请求因此使用不同的
        // pipeline key，不会加入旧文件内容的 in-flight 任务，旧结果也过不了回填门。
        let invalidation = cache.token(forKey: key)
        let generation = invalidation.version
        let requestKey = "\(key)|generation:\(generation)"
        guard let decoded = await pipeline.load(url: url, key: requestKey),
              !Task.isCancelled else {
            return nil
        }
        guard isLoadingEnabled, invalidation.version == generation else { return nil }
        if let hit = cache.image(forKey: key) { return hit }

        let image = NSImage(
            cgImage: decoded.image,
            size: NSSize(width: decoded.image.width, height: decoded.image.height)
        )
        cache.insert(image, forKey: key, cost: decoded.cost)
        if !hasReportedFirstDecode {
            hasReportedFirstDecode = true
            GalleryPerformance.firstThumbnailDecoded()
        }
        return image
    }

    func remove(forKey key: String) {
        cache.remove(forKey: key)
    }

    func removeAll() {
        cache.removeAll()
        hasReportedFirstDecode = false
    }

    /// 隐藏图库时释放缓存和视图持有的图片，并停止还没完成的后台读取。
    func suspendAndClear() {
        isLoadingEnabled = false
        pendingSuspension?.cancel()
        pendingSuspension = Task { await pipeline.cancelAll() }
        removeAll()
    }

    /// 重新打开图库时触发当前卡片按需加载，而不是一次性回填全部缓存。
    func resume() {
        guard !isLoadingEnabled else { return }
        isLoadingEnabled = true
        cache.removeAll()
    }
}

/// 异步加载 + 缓存的图片视图。命中缓存时同步返回，避免选中态切换时闪空白。
struct CachedImage: View {
    let url: URL
    let key: String

    @State private var image: NSImage?
    @ObservedObject private var invalidation: ThumbnailInvalidationToken
    @Environment(\.colorScheme) private var colorScheme
    private let loader: ThumbnailLoader

    @MainActor
    init(url: URL, key: String) {
        self.init(url: url, key: key, loader: .shared)
    }

    @MainActor
    init(url: URL, key: String, loader: ThumbnailLoader) {
        self.url = url
        self.key = key
        self.loader = loader
        _invalidation = ObservedObject(wrappedValue: loader.invalidationToken(forKey: key))
    }

    var body: some View {
        Group {
            if let image = image ?? loader.cachedImage(forKey: key) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                Rectangle().fill(DS.thumbnailBacking(colorScheme))
            }
        }
        .task(id: "\(key)#\(invalidation.version)") { await load() }
    }

    /// 快速滚动时批量图同时完成加载，跳过动画避免一批并行淡入事务叠加在滚动帧里。
    private static var lastLoadFinishTime: TimeInterval = 0

    private func load() async {
        if let hit = loader.cachedImage(forKey: key) {
            image = hit
            return
        }
        image = nil
        guard let decoded = await loader.load(url: url, key: key), !Task.isCancelled else { return }
        let now = Date.timeIntervalSinceReferenceDate
        let isBurst = now - Self.lastLoadFinishTime < 0.1
        Self.lastLoadFinishTime = now
        if isBurst {
            image = decoded
        } else {
            withAnimation(.easeOut(duration: 0.15)) { image = decoded }
        }
    }
}
