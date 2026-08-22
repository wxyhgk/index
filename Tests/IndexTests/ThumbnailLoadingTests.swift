import AppKit
import Combine
import XCTest
@testable import IndexApp

final class ThumbnailLoadingTests: XCTestCase {
    func testDecodedCostUsesPixelMemoryInsteadOfCompressedByteCount() {
        XCTAssertEqual(ThumbnailCache.decodedCost(width: 640, height: 360), 921_600)
        XCTAssertEqual(ThumbnailCache.decodedCost(width: 0, height: 360), 0)
        XCTAssertEqual(ThumbnailCache.totalCostLimit, 128 * 1024 * 1024)
        XCTAssertEqual(ThumbnailCache.countLimit, 400)
    }

    @MainActor
    func testInvalidatingOneKeyOnlyPublishesThatKeysToken() {
        let cache = ThumbnailCache(observesMemoryPressure: false)
        let first = cache.token(forKey: "first")
        let second = cache.token(forKey: "second")
        var firstChanges = 0
        var secondChanges = 0
        let firstSubscription = first.objectWillChange.sink { firstChanges += 1 }
        let secondSubscription = second.objectWillChange.sink { secondChanges += 1 }

        cache.remove(forKey: "first")

        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 0)
        withExtendedLifetime([firstSubscription, secondSubscription]) {}
    }

    @MainActor
    func testOffscreenInvalidationTokenIsNotRetainedByCache() {
        let cache = ThumbnailCache(observesMemoryPressure: false)
        weak var releasedToken: ThumbnailInvalidationToken?

        autoreleasepool {
            let token = cache.token(forKey: "offscreen")
            releasedToken = token
            XCTAssertNotNil(releasedToken)
        }

        XCTAssertNil(releasedToken, "离屏 View 释放后，token 不能按浏览历史永久增长")
    }

    func testConcurrentRequestsForSameKeyDecodeOnce() async throws {
        let decoder = CountingDecoder(delay: 0.05)
        let pipeline = ThumbnailLoadPipeline(decoder: decoder, maximumConcurrentLoads: 4)
        let url = URL(fileURLWithPath: "/tmp/shared-thumbnail.png")

        async let first = pipeline.load(url: url, key: "same")
        async let second = pipeline.load(url: url, key: "same")
        let results = await [first, second]

        XCTAssertEqual(results.compactMap { $0 }.count, 2)
        XCTAssertEqual(decoder.snapshot().total, 1)
    }

    func testDecodeConcurrencyIsBounded() async {
        let decoder = CountingDecoder(delay: 0.04)
        let pipeline = ThumbnailLoadPipeline(decoder: decoder, maximumConcurrentLoads: 4)

        await withTaskGroup(of: DecodedThumbnail?.self) { group in
            for index in 0..<12 {
                group.addTask {
                    await pipeline.load(
                        url: URL(fileURLWithPath: "/tmp/thumbnail-\(index).png"),
                        key: "key-\(index)"
                    )
                }
            }
            for await _ in group {}
        }

        let snapshot = decoder.snapshot()
        XCTAssertEqual(snapshot.total, 12)
        XCTAssertLessThanOrEqual(snapshot.maximumConcurrent, 4)
        XCTAssertGreaterThan(snapshot.maximumConcurrent, 1)
    }

    @MainActor
    func testSuspendedLoaderDoesNotStartDecodeAndResumeRestoresOnDemandLoading() async {
        let decoder = CountingDecoder(delay: 0)
        let cache = ThumbnailCache(observesMemoryPressure: false)
        let pipeline = ThumbnailLoadPipeline(decoder: decoder, maximumConcurrentLoads: 1)
        let loader = ThumbnailLoader(cache: cache, pipeline: pipeline)
        let url = URL(fileURLWithPath: "/tmp/suspended-thumbnail.png")

        loader.suspendAndClear()
        let suspendedResult = await loader.load(url: url, key: "suspended")
        XCTAssertNil(suspendedResult)
        XCTAssertEqual(decoder.snapshot().total, 0)

        loader.resume()
        let resumedResult = await loader.load(url: url, key: "suspended")
        XCTAssertNotNil(resumedResult)
        XCTAssertEqual(decoder.snapshot().total, 1)
    }

    func testCancellingQueuedRequestPreventsItsDecode() async {
        let decoder = BlockingDecoder()
        let pipeline = ThumbnailLoadPipeline(decoder: decoder, maximumConcurrentLoads: 1)
        let first = Task {
            await pipeline.load(url: URL(fileURLWithPath: "/tmp/first.png"), key: "first")
        }
        XCTAssertEqual(decoder.started.wait(timeout: .now() + 1), .success)

        let queued = Task {
            await pipeline.load(url: URL(fileURLWithPath: "/tmp/queued.png"), key: "queued")
        }
        queued.cancel()
        decoder.proceed.signal()

        _ = await first.value
        let queuedResult = await queued.value
        XCTAssertNil(queuedResult)
        XCTAssertEqual(decoder.totalDecodes, 1)
    }

    func testCancellingManyQueuedRequestsDoesNotStartTheirDecodes() async {
        let decoder = BlockingDecoder()
        let pipeline = ThumbnailLoadPipeline(decoder: decoder, maximumConcurrentLoads: 1)
        let first = Task {
            await pipeline.load(url: URL(fileURLWithPath: "/tmp/active.png"), key: "active")
        }
        XCTAssertEqual(decoder.started.wait(timeout: .now() + 1), .success)

        let queued = (0..<300).map { index in
            Task {
                await pipeline.load(
                    url: URL(fileURLWithPath: "/tmp/queued-\(index).png"),
                    key: "queued-\(index)"
                )
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        queued.forEach { $0.cancel() }
        decoder.proceed.signal()

        _ = await first.value
        for task in queued {
            let result = await task.value
            XCTAssertNil(result)
        }
        XCTAssertEqual(decoder.totalDecodes, 1)
    }

    @MainActor
    func testInvalidationDoesNotLetOldInFlightDecodeRefillCache() async throws {
        let decoder = RevisionRaceDecoder()
        let cache = ThumbnailCache(observesMemoryPressure: false)
        let pipeline = ThumbnailLoadPipeline(decoder: decoder, maximumConcurrentLoads: 1)
        let loader = ThumbnailLoader(cache: cache, pipeline: pipeline)
        let url = URL(fileURLWithPath: "/tmp/revision-race.jpg")

        let oldRequest = Task { @MainActor in
            await loader.load(url: url, key: "same-shot").map { Int($0.size.width) }
        }
        await Task.yield()
        XCTAssertEqual(decoder.firstStarted.wait(timeout: .now() + 1), .success)

        loader.remove(forKey: "same-shot")
        let newRequest = Task { @MainActor in
            await loader.load(url: url, key: "same-shot").map { Int($0.size.width) }
        }
        await Task.yield()
        decoder.allowFirstToFinish.signal()

        let oldResult = await oldRequest.value
        let newResult = await newRequest.value
        XCTAssertNil(oldResult, "失效前启动的旧像素不得回填缓存")
        XCTAssertEqual(newResult, 3)
        XCTAssertEqual(loader.cachedImage(forKey: "same-shot")?.size.width, 3)
        XCTAssertEqual(decoder.totalDecodes, 2, "新一代请求不得加入旧一代 in-flight 解码")
    }
}

private final class BlockingDecoder: ThumbnailDecoding, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var total = 0

    var totalDecodes: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    func decode(contentsOf url: URL) -> DecodedThumbnail? {
        lock.lock()
        total += 1
        lock.unlock()
        started.signal()
        proceed.wait()
        guard let image = CountingDecoder.makeImage() else { return nil }
        return DecodedThumbnail(image: image, cost: 16)
    }
}

private final class CountingDecoder: ThumbnailDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var total = 0
    private var active = 0
    private var maximumConcurrent = 0

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func decode(contentsOf url: URL) -> DecodedThumbnail? {
        lock.lock()
        total += 1
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        lock.unlock()

        Thread.sleep(forTimeInterval: delay)
        let image = Self.makeImage()

        lock.lock()
        active -= 1
        lock.unlock()
        return image.map {
            DecodedThumbnail(image: $0, cost: ThumbnailCache.decodedCost(width: $0.width, height: $0.height))
        }
    }

    func snapshot() -> (total: Int, maximumConcurrent: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (total, maximumConcurrent)
    }

    fileprivate static func makeImage() -> CGImage? {
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }
}

private final class RevisionRaceDecoder: ThumbnailDecoding, @unchecked Sendable {
    let firstStarted = DispatchSemaphore(value: 0)
    let allowFirstToFinish = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var total = 0

    var totalDecodes: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    func decode(contentsOf url: URL) -> DecodedThumbnail? {
        lock.lock()
        total += 1
        let invocation = total
        lock.unlock()

        if invocation == 1 {
            firstStarted.signal()
            allowFirstToFinish.wait()
        }
        let size = invocation == 1 ? 2 : 3
        guard let image = Self.makeImage(size: size) else { return nil }
        return DecodedThumbnail(
            image: image,
            cost: ThumbnailCache.decodedCost(width: size, height: size)
        )
    }

    private static func makeImage(size: Int) -> CGImage? {
        CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
}
