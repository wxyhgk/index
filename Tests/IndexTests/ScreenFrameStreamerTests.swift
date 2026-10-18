import CoreGraphics
import CoreVideo
import XCTest
@testable import IndexApp

/// 常驻帧流的纯逻辑单测：FrameStore 线程安全缓存 + snapshotsFromFrames 尺寸校验 + SubscriptionStore 订阅。
/// SCK 相关实例方法（start/stop/rebuild/snapshots）依赖系统 API 与单例，靠集成测试与手动截图验证。
final class ScreenFrameStreamerTests: XCTestCase {

    private func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return buffer!
    }

    // MARK: - FrameStore

    func testFrameStoreUpdateAndLatest() {
        let store = FrameStore()
        XCTAssertNil(store.latest(1))
        store.update(1, makePixelBuffer(width: 100, height: 50))
        let fetched = store.latest(1)
        XCTAssertEqual(fetched.map(CVPixelBufferGetWidth), 100)
        XCTAssertEqual(fetched.map(CVPixelBufferGetHeight), 50)
        XCTAssertNil(store.latest(2))
    }

    func testFrameStoreReplaceOldFrame() {
        let store = FrameStore()
        store.update(1, makePixelBuffer(width: 100, height: 50))
        store.update(1, makePixelBuffer(width: 200, height: 100))
        let fetched = store.latest(1)
        XCTAssertEqual(fetched.map(CVPixelBufferGetWidth), 200)
        XCTAssertEqual(fetched.map(CVPixelBufferGetHeight), 100)
    }

    func testFrameStoreRemoveAll() {
        let store = FrameStore()
        store.update(1, makePixelBuffer(width: 100, height: 50))
        store.update(2, makePixelBuffer(width: 100, height: 50))
        XCTAssertEqual(store.all().count, 2)
        store.removeAll()
        XCTAssertTrue(store.all().isEmpty)
    }

    /// 像素缓冲 → CGImage 的转换只在取快照时发生；这里锁住尺寸与位深。
    func testMakeImageFromPixelBuffer() throws {
        let buffer = makePixelBuffer(width: 120, height: 80)
        let image = try XCTUnwrap(ScreenFrameStreamer.makeImage(from: buffer))
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 80)
    }

    // MARK: - snapshotsFromFrames（纯函数）

    func testSnapshotsFromFramesSuccess() {
        let display = DisplayInfo(id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 500, height: 300), scale: 2)
        let image = makeImage(width: 1000, height: 600)
        let result = ScreenFrameStreamer.snapshotsFromFrames([display], frames: [1: image])
        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.first?.image.width, 1000)
        XCTAssertEqual(result?.first?.image.height, 600)
        XCTAssertEqual(result?.first?.display.id, 1)
    }

    func testSnapshotsFromFramesMissingFrame() {
        let display = DisplayInfo(id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 500, height: 300), scale: 2)
        let result = ScreenFrameStreamer.snapshotsFromFrames([display], frames: [:])
        XCTAssertNil(result)
    }

    func testSnapshotsFromFramesWrongSize() {
        let display = DisplayInfo(id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 500, height: 300), scale: 2)
        // 期望 1000x600，实际 800x600（宽度超差）
        let image = makeImage(width: 800, height: 600)
        let result = ScreenFrameStreamer.snapshotsFromFrames([display], frames: [1: image])
        XCTAssertNil(result)
    }

    func testSnapshotsFromFramesToleratesOnePixelDrift() {
        let display = DisplayInfo(id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 500, height: 300), scale: 2)
        // 期望 1000x600，实际 1001x600（±1px 容忍）
        let image = makeImage(width: 1001, height: 600)
        let result = ScreenFrameStreamer.snapshotsFromFrames([display], frames: [1: image])
        XCTAssertEqual(result?.count, 1)
    }

    func testSnapshotsFromFramesEmptyDisplays() {
        let result = ScreenFrameStreamer.snapshotsFromFrames([], frames: [:])
        XCTAssertNil(result)
    }

    // MARK: - SubscriptionStore

    func testSubscriptionStoreAddRemove() {
        let store = SubscriptionStore()
        let token = UUID()
        store.add(1, token) { _ in }
        XCTAssertEqual(store.handlers(for: 1).count, 1)
        store.remove(1, token)
        XCTAssertEqual(store.handlers(for: 1).count, 0)
    }

    func testSubscriptionStoreMultipleSubscribers() {
        let store = SubscriptionStore()
        let token1 = UUID()
        let token2 = UUID()
        store.add(1, token1) { _ in }
        store.add(1, token2) { _ in }
        XCTAssertEqual(store.handlers(for: 1).count, 2)
        store.remove(1, token1)
        XCTAssertEqual(store.handlers(for: 1).count, 1)
        store.remove(1, token2)
        XCTAssertEqual(store.handlers(for: 1).count, 0)
    }
}
