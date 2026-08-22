import CoreGraphics
import XCTest
@testable import IndexApp

@MainActor
final class GalleryBatchActivityTests: XCTestCase {
    private final class ClipboardSpy: ClipboardWriting {
        private(set) var images: [CGImage] = []

        func copy(text: String) {}
        func copy(_ image: CGImage) { images = [image] }
        func copy(_ images: [CGImage]) { self.images = images }
    }

    private func makeImage(gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try XCTUnwrap(context.makeImage())
    }

    func testSingleFlightProgressAndTokenIsolation() throws {
        let activity = GalleryBatchActivity()
        let token = try XCTUnwrap(activity.begin(kind: .copy, total: 10))

        XCTAssertNil(activity.begin(kind: .export, total: 20), "忙碌时必须拒绝第二份像素重活")
        XCTAssertEqual(activity.state?.processed, 0)

        activity.update(token: token, processed: 4)
        XCTAssertEqual(activity.state?.processed, 4)
        XCTAssertEqual(activity.state?.progress ?? 0, 0.4, accuracy: 0.001)

        activity.update(token: UUID(), processed: 9)
        activity.update(token: token, processed: 2)
        XCTAssertEqual(activity.state?.processed, 4, "迟到 token 和倒退进度都不能污染当前状态")

        activity.finish(token: UUID())
        XCTAssertTrue(activity.isBusy)
        activity.finish(token: token)
        XCTAssertFalse(activity.isBusy)
    }

    func testCancellationWorksBeforeAndAfterWorkerAttachment() throws {
        let activity = GalleryBatchActivity()
        let first = try XCTUnwrap(activity.begin(kind: .export, total: 5))
        var attachedCancellationCount = 0
        activity.attachCancellation(token: first) { attachedCancellationCount += 1 }
        activity.cancel()
        activity.cancel()
        XCTAssertEqual(attachedCancellationCount, 1)
        XCTAssertEqual(activity.state?.isCancelling, true)
        activity.finish(token: first)

        let second = try XCTUnwrap(activity.begin(kind: .copy, total: 3))
        activity.cancel()
        var lateCancellationCount = 0
        activity.attachCancellation(token: second) { lateCancellationCount += 1 }
        XCTAssertEqual(lateCancellationCount, 1, "数据库准备期间取消，worker 迟到挂接时也要立即停止")
        activity.finish(token: second)
    }

    func testEmptyOperationNeverOccupiesGate() {
        let activity = GalleryBatchActivity()
        XCTAssertNil(activity.begin(kind: .copy, total: 0))
        XCTAssertFalse(activity.isBusy)
    }

    func testAsyncCopyDeduplicatesIDsAndReleasesGlobalGate() async throws {
        let activity = GalleryBatchActivity()
        if let token = activity.state?.token { activity.finish(token: token) }
        defer {
            if let token = activity.state?.token { activity.finish(token: token) }
        }

        let store = FakeShotStore()
        let first = try store.save(image: makeImage(gray: 0.2), metadata: CaptureMetadata())
        let second = try store.save(image: makeImage(gray: 0.8), metadata: CaptureMetadata())
        let clipboard = ClipboardSpy()

        let copied = await GalleryBatch.copyImages(
            ids: [try XCTUnwrap(second.id), try XCTUnwrap(first.id), try XCTUnwrap(second.id), 99_999],
            reader: store,
            clipboard: clipboard
        )

        XCTAssertEqual(copied, 2)
        XCTAssertEqual(clipboard.images.count, 2)
        XCTAssertFalse(activity.isBusy)
    }
}
