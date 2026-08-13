import AppKit
import Combine
import XCTest
@testable import MacShot

final class ThumbnailLoadingTests: XCTestCase {
    func testDecodedCostUsesPixelMemoryInsteadOfCompressedByteCount() {
        XCTAssertEqual(ThumbnailCache.decodedCost(width: 640, height: 360), 921_600)
        XCTAssertEqual(ThumbnailCache.decodedCost(width: 0, height: 360), 0)
        XCTAssertEqual(ThumbnailCache.totalCostLimit, 96 * 1024 * 1024)
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
