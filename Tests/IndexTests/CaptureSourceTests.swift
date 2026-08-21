import CoreGraphics
import XCTest
@testable import IndexApp

@MainActor
final class CaptureSourceTests: XCTestCase {

    func testImmediateSourceCapturesAllDisplays() async {
        let capturer = RoutingScreenCapturer()
        let source = ImmediateScreenSource(capturer: capturer)

        do {
            _ = try await source.makeSnapshots()
            XCTFail("测试替身应从全显示器路径抛出预期错误")
        } catch RoutingScreenCapturer.ExpectedError.allDisplays {
            // 预期：证明普通截图重新走完整多屏冻结路径。
        } catch {
            XCTFail("收到非预期错误: \(error)")
        }

        XCTAssertEqual(capturer.allDisplayCalls, 1)
    }

    func testDisplayTopologyMatchesRegardlessOfEnumerationOrder() {
        let left = display(id: 11, name: "left", frame: CGRect(x: -1600, y: 0, width: 1600, height: 900))
        let main = display(id: 22, name: "main", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let portrait = display(id: 33, name: "portrait", frame: CGRect(x: 1920, y: -400, width: 720, height: 1280))

        XCTAssertTrue(DisplayTopology.matches(
            [left, main, portrait],
            [portrait, left, main]
        ))
    }

    func testDisplayTopologyRejectsAddedRemovedOrReconfiguredDisplay() {
        let left = display(id: 11, name: "left", frame: CGRect(x: -1600, y: 0, width: 1600, height: 900))
        let main = display(id: 22, name: "main", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let resizedMain = display(id: 22, name: "main", frame: CGRect(x: 0, y: 0, width: 1680, height: 945))

        XCTAssertFalse(DisplayTopology.matches([left, main], [main]))
        XCTAssertFalse(DisplayTopology.matches([main], [left, main]))
        XCTAssertFalse(DisplayTopology.matches([main], [resizedMain]))
    }

    func testDisplayCaptureFailureDoesNotClaimSystemScreenshotIsBroken() {
        let message = CaptureError.displayCaptureFailed(["LS27D80xU"]).localizedDescription

        XCTAssertTrue(message.contains("Index 的显示器捕获失败"))
        XCTAssertTrue(message.contains("LS27D80xU"))
        // 两个方向都不声称：macOS 15.3.1 实测系统 CLI 截图同样被代理到 replayd，
        // 「系统截图仍可用」与「系统截图已损坏」在故障会话里都没有依据。
        XCTAssertFalse(message.contains("macOS 系统截图可能仍可用"))
        XCTAssertFalse(message.contains("macOS 截图服务当前不可用"))
        XCTAssertFalse(message.contains("无法捕获显示器"))
    }

    func testTimeoutMessageDoesNotClaimNativeRequestWasCancelled() {
        let message = CaptureError.screenCaptureTimedOut("shareable-content").localizedDescription

        XCTAssertTrue(message.contains("已停止等待"))
        XCTAssertTrue(message.contains("系统请求可能仍在结束中"))
        XCTAssertFalse(message.contains("已停止本次请求"))
    }

    func testQuarantineMessageExplainsWhyNewRequestsArePaused() {
        let message = CaptureError
            .screenCaptureRequestQuarantined("shareable-content")
            .localizedDescription

        XCTAssertTrue(message.contains("上一条 ScreenCaptureKit 请求超时后仍未结束"))
        XCTAssertTrue(message.contains("暂停发送新的捕获请求"))
    }

    func testSnapshotKeepsTopologyScaleSeparateFromCapturedImageScale() throws {
        let topologyDisplay = DisplayInfo(
            id: 44,
            name: "Retina",
            frame: CGRect(x: -100, y: 50, width: 100, height: 50),
            scale: 2
        )
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 100,
            height: 50,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let snapshot = DisplaySnapshot(
            display: topologyDisplay,
            image: image,
            imageScale: 1
        )

        XCTAssertEqual(snapshot.display.scale, 2, "拓扑仍应保留 NSScreen 的 Retina scale")
        XCTAssertEqual(snapshot.scale, 1, "像素换算应使用 rect API 实际返回的 1× scale")
        XCTAssertEqual(
            snapshot.pixelRect(forGlobal: topologyDisplay.frame),
            CGRect(x: 0, y: 0, width: 100, height: 50)
        )
        XCTAssertTrue(DisplayTopology.matches([snapshot.display], [topologyDisplay]))
    }

    private func display(
        id: CGDirectDisplayID,
        name: String,
        frame: CGRect
    ) -> DisplayInfo {
        DisplayInfo(id: id, name: name, frame: frame, scale: 2)
    }
}

@MainActor
private final class RoutingScreenCapturer: ScreenCapturing {
    enum ExpectedError: Error {
        case allDisplays
    }

    var allDisplayCalls = 0
    var isPermissionGranted: Bool { true }

    func requestPermission() -> Bool { true }

    func captureDisplays() async throws -> [DisplaySnapshot] {
        allDisplayCalls += 1
        throw ExpectedError.allDisplays
    }

    func captureWindow(
        windowID: CGWindowID,
        scale: CGFloat,
        includeShadow: Bool
    ) async throws -> CGImage {
        fatalError("本测试不应触发窗口捕获")
    }
}
