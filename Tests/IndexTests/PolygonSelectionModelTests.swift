import XCTest
import CoreGraphics
@testable import IndexApp

/// 多边形选区状态机测试：enter → add → confirm/cancel → vertex adjust。
@MainActor
final class PolygonSelectionModelTests: XCTestCase {

    private func makeModel(
        frame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 300),
        scale: CGFloat = 1
    ) -> SelectionModel {
        let display = DisplayInfo(
            id: 1, name: "Test", frame: frame, scale: scale
        )
        let ctx = CGContext(
            data: nil,
            width: Int(frame.width * scale),
            height: Int(frame.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let snapshot = DisplaySnapshot(display: display, image: ctx.makeImage()!)
        return SelectionModel(snapshot: snapshot, windows: [])
    }

    // MARK: - 进入/退出

    func testEnterPolygonMode() {
        let model = makeModel()
        model.enterPolygonMode()
        XCTAssertTrue(model.isPolygonMode)
    }

    func testEnterPolygonModeRequiresIdle() {
        let model = makeModel()
        model.beginDrag(at: CGPoint(x: 50, y: 50))
        model.updateDrag(to: CGPoint(x: 100, y: 100))
        _ = model.endDrag()
        XCTAssertEqual(model.phase, .confirmed)
        model.enterPolygonMode()
        XCTAssertFalse(model.isPolygonMode)
    }

    /// 连按两次 P（键盘上「进入多边形」）不该清空已落的顶点。
    func testEnterPolygonModeIsIdempotent() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 50))
        model.enterPolygonMode()
        XCTAssertEqual(model.polygon?.points.count, 2)
        XCTAssertTrue(model.isPolygonMode)
    }

    /// 画多边形途中按 R（复用上次区域）必须被拒绝：
    /// 多边形模式下 phase 仍是 idle，不单独拦就会塞进矩形选区留下混合状态。
    func testRestoreSelectionRejectedWhileDrawingPolygon() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        XCTAssertFalse(model.restoreSelection(CGRect(x: 10, y: 10, width: 80, height: 80)))
        XCTAssertNil(model.confirmedRect)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.isPolygonMode)
    }

    func testCancelPolygon() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        model.addPolygonPoint(CGPoint(x: 150, y: 50))
        model.cancelPolygon()
        XCTAssertFalse(model.isPolygonMode)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.confirmedPolygon)
    }

    // MARK: - 放点

    func testAddPolygonPoint() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        model.addPolygonPoint(CGPoint(x: 150, y: 50))
        XCTAssertEqual(model.polygon?.points.count, 3)
        XCTAssertEqual(model.polygon?.points[0], CGPoint(x: 50, y: 50))
    }

    func testAddPolygonPointClampsToBounds() {
        let model = makeModel(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 250, y: 350))
        let point = model.polygon?.points.first
        XCTAssertNotNil(point)
        XCTAssertEqual(point?.x, 200)
        XCTAssertEqual(point?.y, 300)
    }

    func testAddPolygonPointClampsNegative() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: -50, y: -100))
        let point = model.polygon?.points.first
        XCTAssertEqual(point?.x, 0)
        XCTAssertEqual(point?.y, 0)
    }

    // MARK: - 预览

    func testUpdatePolygonPreview() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.updatePolygonPreview(CGPoint(x: 80, y: 80))
        XCTAssertEqual(model.polygon?.previewPoint, CGPoint(x: 80, y: 80))
        XCTAssertFalse(model.polygon?.snapToFirst == true)
    }

    func testPreviewSnapToFirst() {
        let model = makeModel()
        model.enterPolygonMode()
        let first = CGPoint(x: 50, y: 50)
        model.addPolygonPoint(first)
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        model.addPolygonPoint(CGPoint(x: 150, y: 50))
        model.updatePolygonPreview(CGPoint(x: 53, y: 53))
        XCTAssertTrue(model.polygon?.snapToFirst == true)
        XCTAssertEqual(model.polygon?.previewPoint, first)
    }

    func testPreviewNoSnapWhenFewerThan3Points() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        model.updatePolygonPreview(CGPoint(x: 53, y: 53))
        XCTAssertFalse(model.polygon?.snapToFirst == true)
    }

    func testPreviewStartIsLastPoint() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        XCTAssertEqual(model.polygonPreviewStart, CGPoint(x: 100, y: 100))
    }

    // MARK: - 闭合

    func testConfirmPolygon() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        model.addPolygonPoint(CGPoint(x: 150, y: 50))
        let ok = model.confirmPolygon()
        XCTAssertTrue(ok)
        XCTAssertFalse(model.isPolygonMode)
        XCTAssertEqual(model.phase, .confirmed)
        XCTAssertEqual(model.confirmedPolygon?.count, 3)
        XCTAssertNotNil(model.confirmedRect)
    }

    func testConfirmPolygonTooFewPoints() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        let ok = model.confirmPolygon()
        XCTAssertFalse(ok)
        XCTAssertTrue(model.isPolygonMode)
    }

    func testConfirmPolygonTooSmall() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 52, y: 50))
        model.addPolygonPoint(CGPoint(x: 50, y: 52))
        let ok = model.confirmPolygon()
        XCTAssertFalse(ok)
    }

    func testConfirmPolygonClearsPolygonState() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        model.addPolygonPoint(CGPoint(x: 150, y: 50))
        _ = model.confirmPolygon()
        XCTAssertNil(model.polygon)
        XCTAssertNil(model.confirmedWindow)
        XCTAssertTrue(model.guides.isEmpty)
    }

    // MARK: - 顶点调整

    func testPolygonVertexHit() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        model.addPolygonPoint(CGPoint(x: 150, y: 50))
        _ = model.confirmPolygon()
        let index = model.polygonVertex(at: CGPoint(x: 52, y: 52))
        XCTAssertEqual(index, 0)
    }

    func testPolygonVertexMiss() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        model.addPolygonPoint(CGPoint(x: 150, y: 50))
        _ = model.confirmPolygon()
        let index = model.polygonVertex(at: CGPoint(x: 75, y: 75))
        XCTAssertNil(index)
    }

    func testPolygonVertexOnlyInConfirmedPhase() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        model.addPolygonPoint(CGPoint(x: 150, y: 50))
        // 未 confirm，showsPolygonVertices 为 false
        let index = model.polygonVertex(at: CGPoint(x: 50, y: 50))
        XCTAssertNil(index)
    }

    func testVertexAdjust() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        model.addPolygonPoint(CGPoint(x: 150, y: 50))
        _ = model.confirmPolygon()

        model.beginPolygonVertexAdjust(0, at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(model.adjustingPolygonVertex, 0)
        XCTAssertEqual(model.phase, .adjusting)

        model.updatePolygonVertex(to: CGPoint(x: 60, y: 60))
        XCTAssertEqual(model.confirmedPolygon?[0], CGPoint(x: 60, y: 60))

        model.endPolygonVertexAdjust()
        XCTAssertNil(model.adjustingPolygonVertex)
        XCTAssertEqual(model.phase, .confirmed)
    }

    func testVertexAdjustRecalculatesBBox() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.addPolygonPoint(CGPoint(x: 100, y: 100))
        model.addPolygonPoint(CGPoint(x: 150, y: 50))
        _ = model.confirmPolygon()
        let originalRect = model.confirmedRect

        model.beginPolygonVertexAdjust(2, at: CGPoint(x: 150, y: 50))
        model.updatePolygonVertex(to: CGPoint(x: 180, y: 80))
        let newRect = model.confirmedRect
        XCTAssertNotNil(newRect)
        XCTAssertNotEqual(newRect?.maxX, originalRect?.maxX)
        model.endPolygonVertexAdjust()
    }

    // MARK: - reset

    func testResetClearsPolygon() {
        let model = makeModel()
        model.enterPolygonMode()
        model.addPolygonPoint(CGPoint(x: 50, y: 50))
        model.reset()
        XCTAssertFalse(model.isPolygonMode)
        XCTAssertNil(model.confirmedPolygon)
        XCTAssertNil(model.adjustingPolygonVertex)
    }
}
