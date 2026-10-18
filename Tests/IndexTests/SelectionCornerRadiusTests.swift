import XCTest
import CoreGraphics
@testable import IndexApp

/// 圆角手柄的行为锁：单个手柄、固定在左上角内侧、拖拽用增量、夹紧半径。
@MainActor
final class SelectionCornerRadiusTests: XCTestCase {

    private func makeModel(frame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400)) -> SelectionModel {
        let display = DisplayInfo(id: 1, name: "Test", frame: frame, scale: 1)
        let ctx = CGContext(
            data: nil,
            width: Int(frame.width),
            height: Int(frame.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let snapshot = DisplaySnapshot(display: display, image: ctx.makeImage()!)
        return SelectionModel(snapshot: snapshot, windows: [])
    }

    private func confirmedModel(
        rect: CGRect = CGRect(x: 50, y: 50, width: 200, height: 100)
    ) -> SelectionModel {
        let model = makeModel()
        model.beginDrag(at: CGPoint(x: rect.minX, y: rect.minY))
        model.updateDrag(to: CGPoint(x: rect.maxX, y: rect.maxY))
        XCTAssertTrue(model.endDrag())
        return model
    }

    func testHandleSitsInsideTopLeft() {
        let model = confirmedModel()
        let rect = try! XCTUnwrap(model.confirmedRect)
        let point = model.cornerHandlePoint(in: rect)
        XCTAssertEqual(point.x, rect.minX + 22)
        XCTAssertEqual(point.y, rect.maxY - 22)
        XCTAssertTrue(rect.contains(point), "手柄必须在选区内，贴边时才能抓到")
    }

    func testOnlyOneHandleAndItIsHit() {
        let model = confirmedModel()
        let rect = try! XCTUnwrap(model.confirmedRect)
        let handle = model.cornerHandlePoint(in: rect)

        XCTAssertEqual(model.cornerControl(at: handle), .topLeft)
        // 四个角本身不再各有一个圆角控制点。
        XCTAssertNil(model.cornerControl(at: CGPoint(x: rect.minX, y: rect.maxY)))
        XCTAssertNil(model.cornerControl(at: CGPoint(x: rect.maxX, y: rect.maxY)))
        XCTAssertNil(model.cornerControl(at: CGPoint(x: rect.minX, y: rect.minY)))
        XCTAssertNil(model.cornerControl(at: CGPoint(x: rect.maxX, y: rect.minY)))
    }

    func testHandleWorksForFullScreenSelection() {
        let model = confirmedModel(rect: CGRect(x: 0, y: 0, width: 400, height: 400))
        let rect = try! XCTUnwrap(model.confirmedRect)
        let handle = model.cornerHandlePoint(in: rect)
        XCTAssertTrue(model.bounds.contains(handle))
        XCTAssertEqual(model.cornerControl(at: handle), .topLeft)
    }

    func testDragOutwardUsesDeltaAndIncreasesRadius() {
        let model = confirmedModel()
        let rect = try! XCTUnwrap(model.confirmedRect)
        let handle = model.cornerHandlePoint(in: rect)

        model.beginCornerAdjust(.topLeft, at: handle)
        // 向左上拖 20pt：投影到对角线 = 40 / sqrt(2)。
        XCTAssertTrue(model.updateCornerAdjust(to: CGPoint(x: handle.x - 20, y: handle.y + 20)))
        XCTAssertEqual(model.cornerRadius, 40 / CGFloat(2).squareRoot(), accuracy: 0.01)
        model.endCornerAdjust()
    }

    func testGrabDoesNotJumpRadius() {
        let model = confirmedModel()
        let rect = try! XCTUnwrap(model.confirmedRect)
        let handle = model.cornerHandlePoint(in: rect)
        XCTAssertTrue(model.setCornerRadius(18))

        model.beginCornerAdjust(.topLeft, at: handle)
        // 还没移动：半径必须保持 18，不能按「手柄到角距离」重算。
        XCTAssertEqual(model.cornerRadius, 18, accuracy: 0.001)
        model.endCornerAdjust()
    }

    func testDragInwardClampsToZero() {
        let model = confirmedModel()
        let rect = try! XCTUnwrap(model.confirmedRect)
        let handle = model.cornerHandlePoint(in: rect)
        XCTAssertTrue(model.setCornerRadius(20))

        model.beginCornerAdjust(.topLeft, at: handle)
        model.updateCornerAdjust(to: CGPoint(x: handle.x + 100, y: handle.y - 100))
        XCTAssertEqual(model.cornerRadius, 0, accuracy: 0.001)
    }

    func testRadiusClampsToHalfShortSide() {
        let model = confirmedModel(rect: CGRect(x: 50, y: 50, width: 200, height: 100))
        XCTAssertTrue(model.setCornerRadius(1000))
        XCTAssertEqual(model.cornerRadius, 49, accuracy: 0.001)
    }

    func testScrollStepAndReset() {
        let model = confirmedModel()
        XCTAssertTrue(model.adjustCornerRadius(by: 2))
        XCTAssertEqual(model.cornerRadius, 2, accuracy: 0.001)
        XCTAssertTrue(model.adjustCornerRadius(by: -5))
        XCTAssertEqual(model.cornerRadius, 0, accuracy: 0.001)
        XCTAssertFalse(model.adjustCornerRadius(by: -1), "已经 0 时不应继续变化")
    }
}
