import XCTest
import AppKit
import CoreGraphics
@testable import IndexApp

/// B 的呈现 + A 的坐标模型：每屏一个 overlay，但选区是全局虚拟坐标。
@MainActor
final class CrossDisplaySelectionTests: XCTestCase {

    private let left = DisplayInfo(
        id: 1, name: "Left", frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1
    )
    private let right = DisplayInfo(
        id: 2, name: "Right", frame: CGRect(x: 100, y: 0, width: 100, height: 100), scale: 1
    )

    private func snapshot(_ display: DisplayInfo) -> DisplaySnapshot {
        let ctx = CGContext(
            data: nil,
            width: Int(display.frame.width),
            height: Int(display.frame.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return DisplaySnapshot(display: display, image: ctx.makeImage()!)
    }

    func testSelectionCanCrossDisplayBoundary() {
        let union = left.frame.union(right.frame)
        let model = SelectionModel(
            snapshot: snapshot(left),
            windows: [],
            selectionBounds: union
        )

        model.beginDrag(at: CGPoint(x: 50, y: 20))
        model.updateDrag(to: CGPoint(x: 150, y: 80))
        XCTAssertTrue(model.endDrag())

        let rect = try! XCTUnwrap(model.confirmedRect)
        XCTAssertEqual(rect.minX, 50, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 150, accuracy: 0.001, "选区应越过第一块屏的右边界")
        XCTAssertEqual(rect.width, 100, accuracy: 0.001)
    }

    func testSelectionStillClampedToVirtualBounds() {
        let union = left.frame.union(right.frame)
        let model = SelectionModel(
            snapshot: snapshot(left),
            windows: [],
            selectionBounds: union
        )
        model.beginDrag(at: CGPoint(x: 90, y: 10))
        model.updateDrag(to: CGPoint(x: 400, y: 300))
        XCTAssertTrue(model.endDrag())
        let rect = try! XCTUnwrap(model.confirmedRect)
        XCTAssertEqual(rect.maxX, union.maxX, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, union.maxY, accuracy: 0.001)
    }

    func testAdoptCopiesGlobalSelectionToInactiveModel() {
        let union = left.frame.union(right.frame)
        let active = SelectionModel(
            snapshot: snapshot(left), windows: [], selectionBounds: union
        )
        let inactive = SelectionModel(
            snapshot: snapshot(right), windows: [], selectionBounds: union
        )

        active.beginDrag(at: CGPoint(x: 50, y: 20))
        active.updateDrag(to: CGPoint(x: 150, y: 80))
        XCTAssertTrue(active.endDrag())

        XCTAssertTrue(inactive.adoptSelection(from: active))
        XCTAssertEqual(inactive.phase, .confirmed)
        XCTAssertEqual(inactive.confirmedRect, active.confirmedRect)
        XCTAssertEqual(inactive.cornerRadius, active.cornerRadius)
        XCTAssertEqual(inactive.activeRect, active.activeRect)
    }

    func testInactiveNoLongerResetsSelection() {
        let union = left.frame.union(right.frame)
        let model = SelectionModel(
            snapshot: snapshot(left), windows: [], selectionBounds: union
        )
        model.beginDrag(at: CGPoint(x: 10, y: 10))
        model.updateDrag(to: CGPoint(x: 80, y: 80))
        _ = model.endDrag()
        let before = model.confirmedRect

        XCTAssertTrue(model.setInactive(true))
        XCTAssertEqual(model.confirmedRect, before, "切到别的屏不能丢掉全局选区")
    }

    func testNudgeCanMoveAcrossBoundary() {
        let union = left.frame.union(right.frame)
        let model = SelectionModel(
            snapshot: snapshot(left), windows: [], selectionBounds: union
        )
        model.beginDrag(at: CGPoint(x: 20, y: 20))
        model.updateDrag(to: CGPoint(x: 80, y: 80))
        _ = model.endDrag()

        XCTAssertTrue(model.nudge(dx: 40, dy: 0, resizing: false))
        let moved = try! XCTUnwrap(model.confirmedRect)
        XCTAssertEqual(moved.maxX, 120, accuracy: 0.001)
    }
}

/// 拼接器的输出尺寸、位置与像素来源。
@MainActor
final class MultiDisplayComposerTests: XCTestCase {

    private func solidImage(width: Int, height: Int, color: NSColor) -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func snapshot(
        frame: CGRect, scale: CGFloat, color: NSColor
    ) -> DisplaySnapshot {
        let display = DisplayInfo(id: 1, name: "Test", frame: frame, scale: scale)
        let image = solidImage(
            width: Int(frame.width * scale),
            height: Int(frame.height * scale),
            color: color
        )
        return DisplaySnapshot(display: display, image: image)
    }

    private func color(of image: CGImage, x: Int, y: Int) -> NSColor? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    func testStitchesTwoScreensAtUnifiedScale() throws {
        let a = snapshot(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 2,
            color: .red
        )
        let b = snapshot(
            frame: CGRect(x: 100, y: 0, width: 100, height: 100),
            scale: 1,
            color: .blue
        )
        let region = CGRect(x: 50, y: 0, width: 100, height: 100)

        let image = try XCTUnwrap(
            MultiDisplayComposer.stitch(region: region, snapshots: [a, b], outputScale: 2)
        )
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 200)

        // 左半（A 屏在 x=50..100）红，右半（B 屏 x=100..150）蓝。
        let left = try XCTUnwrap(color(of: image, x: 20, y: 100))
        let right = try XCTUnwrap(color(of: image, x: 180, y: 100))
        XCTAssertGreaterThan(left.redComponent, 0.8)
        XCTAssertLessThan(left.blueComponent, 0.2)
        XCTAssertGreaterThan(right.blueComponent, 0.8)
        XCTAssertLessThan(right.redComponent, 0.2)
    }

    func testGapBetweenScreensStaysTransparent() throws {
        let a = snapshot(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 1,
            color: .red
        )
        // 与 A 之间留 20pt 空档。
        let b = snapshot(
            frame: CGRect(x: 120, y: 0, width: 100, height: 100),
            scale: 1,
            color: .blue
        )
        let region = CGRect(x: 80, y: 0, width: 60, height: 100)
        let image = try XCTUnwrap(
            MultiDisplayComposer.stitch(region: region, snapshots: [a, b], outputScale: 1)
        )
        XCTAssertEqual(image.width, 60)
        let gap = try XCTUnwrap(color(of: image, x: 30, y: 50))
        XCTAssertEqual(gap.alphaComponent, 0, accuracy: 0.01)
    }

    func testLayerOffsetMovesRectAndStroke() {
        var layer = Layer(
            kind: .pencil,
            rect: LRect(x: 10, y: 20, w: 30, h: 40),
            color: .red,
            lineWidth: 2
        )
        layer.strokePoints = [CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 60)]
        layer.magnifierDisplayOrigin = CGPoint(x: 5, y: 6)

        let moved = layer.offsetBy(dx: 100, dy: 200)
        XCTAssertEqual(moved.rect.x, 110)
        XCTAssertEqual(moved.rect.y, 220)
        XCTAssertEqual(moved.strokePoints?.first, CGPoint(x: 110, y: 220))
        XCTAssertEqual(moved.magnifierDisplayOrigin, CGPoint(x: 105, y: 206))
    }
}
