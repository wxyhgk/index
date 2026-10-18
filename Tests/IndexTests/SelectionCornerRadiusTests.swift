import XCTest
import CoreGraphics
@testable import IndexApp

/// 四角绿点的行为锁：位置在选区内、四个角都能命中、拖拽用增量、夹紧半径。
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

    private func outwardDirection(for corner: SelectionModel.Corner) -> (CGFloat, CGFloat) {
        switch corner {
        case .topLeft:     return (-1, 1)
        case .topRight:    return (1, 1)
        case .bottomLeft:  return (-1, -1)
        case .bottomRight: return (1, -1)
        }
    }

    func testFourDotsSitInsideSelection() {
        let model = confirmedModel()
        let rect = try! XCTUnwrap(model.confirmedRect)
        let expected: [SelectionModel.Corner: CGPoint] = [
            .topLeft: CGPoint(x: 62, y: 138),
            .topRight: CGPoint(x: 238, y: 138),
            .bottomLeft: CGPoint(x: 62, y: 62),
            .bottomRight: CGPoint(x: 238, y: 62)
        ]
        for corner in SelectionModel.Corner.allCases {
            let point = model.cornerHandlePoint(for: corner, in: rect)
            XCTAssertEqual(point, expected[corner], "\(corner) 应在角内侧 12pt")
            XCTAssertTrue(rect.contains(point), "绿点必须落在选区内")
            XCTAssertEqual(model.cornerControl(at: point), corner)
        }
    }

    func testDotsAreNotAtExactCorners() {
        let model = confirmedModel()
        let rect = try! XCTUnwrap(model.confirmedRect)
        // 角本身现在归缩放手柄；绿点内缩，避免两者重叠。
        XCTAssertNil(model.cornerControl(at: CGPoint(x: rect.minX, y: rect.maxY)))
        XCTAssertNil(model.cornerControl(at: CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    func testDotsWorkForFullScreenSelection() {
        let model = confirmedModel(rect: CGRect(x: 0, y: 0, width: 400, height: 400))
        let rect = try! XCTUnwrap(model.confirmedRect)
        for corner in SelectionModel.Corner.allCases {
            let point = model.cornerHandlePoint(for: corner, in: rect)
            XCTAssertTrue(model.bounds.contains(point))
            XCTAssertEqual(model.cornerControl(at: point), corner)
        }
    }

    func testDragInwardIncreasesRadiusFromEveryCorner() {
        for corner in SelectionModel.Corner.allCases {
            let model = confirmedModel()
            let rect = try! XCTUnwrap(model.confirmedRect)
            let handle = model.cornerHandlePoint(for: corner, in: rect)
            let (dx, dy) = outwardDirection(for: corner)

            model.beginCornerAdjust(corner, at: handle)
            // 向选区中心拖：即 outward 方向的反向。
            XCTAssertTrue(model.updateCornerAdjust(
                to: CGPoint(x: handle.x - dx * 20, y: handle.y - dy * 20)
            ))
            XCTAssertEqual(model.cornerRadius, 40 / CGFloat(2).squareRoot(), accuracy: 0.01, "\(corner)")
            model.endCornerAdjust()
        }
    }

    func testGrabDoesNotJumpRadius() {
        let model = confirmedModel()
        let rect = try! XCTUnwrap(model.confirmedRect)
        let handle = model.cornerHandlePoint(for: .topRight, in: rect)
        XCTAssertTrue(model.setCornerRadius(18))

        model.beginCornerAdjust(.topRight, at: handle)
        XCTAssertEqual(model.cornerRadius, 18, accuracy: 0.001)
        model.endCornerAdjust()
    }

    func testDragOutwardClampsToZero() {
        let model = confirmedModel()
        let rect = try! XCTUnwrap(model.confirmedRect)
        let handle = model.cornerHandlePoint(for: .bottomLeft, in: rect)
        let (dx, dy) = outwardDirection(for: .bottomLeft)
        XCTAssertTrue(model.setCornerRadius(20))

        model.beginCornerAdjust(.bottomLeft, at: handle)
        model.updateCornerAdjust(
            to: CGPoint(x: handle.x + dx * 100, y: handle.y + dy * 100)
        )
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
