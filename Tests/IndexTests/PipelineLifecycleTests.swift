import CoreGraphics
import XCTest
@testable import IndexApp

@MainActor
final class PipelineLifecycleTests: XCTestCase {
    func testCaptureSessionsQueueDiskRequestsWithoutDroppingAnyShot() async throws {
        let probe = ProcessorProbe(blocksUntilReleased: true)
        let pipeline = CapturePipeline(
            writer: NullAttributeWriter(),
            maxConcurrentSessions: 1
        )
        pipeline.register(ProbeProcessor(id: "bounded", probe: probe))

        let store = FakeShotStore()
        for _ in 1...4 {
            let shot = try store.save(image: makeImage(), metadata: CaptureMetadata())
            pipeline.run(
                shotID: try XCTUnwrap(shot.id),
                originalURL: store.originalURL(for: shot),
                appBundleID: nil,
                metadata: ShotMetadata(from: shot)
            )
        }

        XCTAssertEqual(
            pipeline.lifecycleSnapshot,
            BoundedPostProcessScheduler.Snapshot(
                activeSessions: 1,
                pendingSessions: 3
            )
        )

        await probe.releaseAll()
        await pipeline.waitUntilIdle()
        let result = await probe.snapshot()
        XCTAssertEqual(result.startedShotIDs, [1, 2, 3, 4])
        XCTAssertEqual(result.maxActive, 1, "截图会话之间必须服从并发上限")
    }

    func testProcessorsWithinOneCaptureSessionRemainConcurrent() async throws {
        let probe = ProcessorProbe(blocksUntilReleased: true)
        let pipeline = CapturePipeline(
            writer: NullAttributeWriter(),
            maxConcurrentSessions: 1
        )
        pipeline.register(ProbeProcessor(id: "first", probe: probe))
        pipeline.register(ProbeProcessor(id: "second", probe: probe))
        let store = FakeShotStore()
        let shot = try store.save(image: makeImage(), metadata: CaptureMetadata())
        pipeline.run(
            shotID: try XCTUnwrap(shot.id),
            originalURL: store.originalURL(for: shot),
            appBundleID: nil,
            metadata: ShotMetadata(from: shot)
        )

        let bothProcessorsStarted = await waitUntil { await probe.startedCount() == 2 }
        XCTAssertTrue(bothProcessorsStarted)
        let running = await probe.snapshot()
        XCTAssertEqual(running.maxActive, 2, "同一截图的处理器仍应彼此隔离、并发执行")

        await probe.releaseAll()
        await pipeline.waitUntilIdle()
    }

    func testBackfillIsSingleFlightAndCoalescesRetrigger() async throws {
        let store = FakeShotStore()
        for _ in 0..<5 {
            _ = try store.save(image: makeImage(), metadata: CaptureMetadata())
        }

        let key = "test.backfill.singleflight"
        let probe = ProcessorProbe(delayNanoseconds: 5_000_000)
        let processor = ProbeProcessor(id: "backfill", probe: probe, attributeKey: key)
        let coordinator = SingleFlightTaskCoordinator()

        XCTAssertTrue(AttributeBackfill.runIfNeeded(
            styleStore: FakeStyleStore(),
            store: store,
            coordinator: coordinator,
            jobsOverride: [.init(key: key, processor: processor)],
            batchSize: 2
        ))
        XCTAssertFalse(AttributeBackfill.runIfNeeded(
            styleStore: FakeStyleStore(),
            store: store,
            coordinator: coordinator,
            jobsOverride: [.init(key: key, processor: processor)],
            batchSize: 2
        ))

        await coordinator.waitUntilIdle()
        let result = await probe.snapshot()
        XCTAssertEqual(result.startedShotIDs.sorted(), [1, 2, 3, 4, 5])
        XCTAssertEqual(result.maxActive, 1, "回填即使分批也必须逐图串行")
        XCTAssertTrue(store.shotsMissingAttribute(key: key).isEmpty)
    }

    func testBackfillCancellationCanBeRetriggeredWithoutOverlap() async throws {
        let store = FakeShotStore()
        for _ in 0..<6 {
            _ = try store.save(image: makeImage(), metadata: CaptureMetadata())
        }

        let key = "test.backfill.cancellable"
        let probe = ProcessorProbe(delayNanoseconds: 50_000_000)
        let processor = ProbeProcessor(id: "cancellable", probe: probe, attributeKey: key)
        let coordinator = SingleFlightTaskCoordinator()

        AttributeBackfill.runIfNeeded(
            styleStore: FakeStyleStore(),
            store: store,
            coordinator: coordinator,
            jobsOverride: [.init(key: key, processor: processor)],
            batchSize: 2
        )
        let backfillStarted = await waitUntil { await probe.startedCount() > 0 }
        XCTAssertTrue(backfillStarted)
        coordinator.cancel()
        AttributeBackfill.runIfNeeded(
            styleStore: FakeStyleStore(),
            store: store,
            coordinator: coordinator,
            jobsOverride: [.init(key: key, processor: processor)],
            batchSize: 2
        )

        await coordinator.waitUntilIdle()
        let result = await probe.snapshot()
        XCTAssertLessThanOrEqual(result.maxActive, 1)
        XCTAssertTrue(store.shotsMissingAttribute(key: key).isEmpty)
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }
}

private struct NullAttributeWriter: ShotAttributeWriter {
    func write(shotID: Int64, key: String, value: AttributeValue) async {}
    func saveContent(shotID: Int64, kind: ContentKind, payload: ContentPayload) async {}
}

private struct ProbeProcessor: CapturePostProcessor {
    let id: String
    let probe: ProcessorProbe
    var attributeKey: String?

    init(id: String, probe: ProcessorProbe, attributeKey: String? = nil) {
        self.id = id
        self.probe = probe
        self.attributeKey = attributeKey
    }

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        guard await probe.run(shotID: input.shotID) else { return }
        if let attributeKey {
            await writer.write(
                shotID: input.shotID,
                key: attributeKey,
                value: .text("done")
            )
        }
    }
}

private actor ProcessorProbe {
    struct Snapshot {
        let startedShotIDs: [Int64]
        let maxActive: Int
    }

    private let blocksUntilReleased: Bool
    private let delayNanoseconds: UInt64
    private var isReleased = false
    private var active = 0
    private var maxActive = 0
    private var startedShotIDs: [Int64] = []

    init(blocksUntilReleased: Bool = false, delayNanoseconds: UInt64 = 0) {
        self.blocksUntilReleased = blocksUntilReleased
        self.delayNanoseconds = delayNanoseconds
    }

    func run(shotID: Int64) async -> Bool {
        active += 1
        maxActive = max(maxActive, active)
        startedShotIDs.append(shotID)
        defer { active -= 1 }

        if blocksUntilReleased {
            while !isReleased {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000)
                } catch {
                    return false
                }
            }
        } else if delayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    func releaseAll() {
        isReleased = true
    }

    func startedCount() -> Int {
        startedShotIDs.count
    }

    func snapshot() -> Snapshot {
        Snapshot(startedShotIDs: startedShotIDs, maxActive: maxActive)
    }
}
