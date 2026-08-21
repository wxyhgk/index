import CoreGraphics
import XCTest
@testable import IndexApp

@MainActor
final class SelectionAISessionTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 200, height: 120)

    func testActivationAndToggleClearTransientSelection() {
        let session = SelectionAISession()

        session.activate()
        XCTAssertEqual(session.snapshot, .init(phase: .armed, selectionRect: nil))

        session.toggle()
        XCTAssertEqual(session.snapshot, .init(phase: .inactive, selectionRect: nil))
    }

    func testReverseDragProducesStandardizedIntegralPixelRect() {
        let session = SelectionAISession(minimumSide: 4)
        session.activate()

        XCTAssertTrue(session.begin(at: CGPoint(x: 80.7, y: 60.4), within: bounds))
        XCTAssertTrue(session.update(to: CGPoint(x: 20.2, y: 10.1), within: bounds))
        let result = session.end(at: CGPoint(x: 20.2, y: 10.1), within: bounds)

        XCTAssertEqual(result, CGRect(x: 20, y: 10, width: 61, height: 51))
        XCTAssertEqual(session.snapshot.phase, .selected)
        XCTAssertEqual(session.snapshot.selectionRect, result)
    }

    func testDragPreviewAndFinalRectStayInsideImageBounds() {
        let session = SelectionAISession(minimumSide: 2)
        session.activate()
        XCTAssertTrue(session.begin(at: CGPoint(x: 190, y: 110), within: bounds))

        session.update(to: CGPoint(x: 400, y: 300), within: bounds)
        XCTAssertEqual(
            session.snapshot.selectionRect,
            CGRect(x: 190, y: 110, width: 10, height: 10)
        )
        XCTAssertEqual(
            session.end(at: CGPoint(x: 400, y: 300), within: bounds),
            CGRect(x: 190, y: 110, width: 10, height: 10)
        )
    }

    func testTooSmallSelectionReturnsToArmed() {
        let session = SelectionAISession(minimumSide: 8)
        session.activate()
        XCTAssertTrue(session.begin(at: CGPoint(x: 20, y: 20), within: bounds))

        XCTAssertNil(session.end(at: CGPoint(x: 23, y: 24), within: bounds))
        XCTAssertEqual(session.snapshot, .init(phase: .armed, selectionRect: nil))
    }

    func testBeginOutsideImageDoesNotStealHostGesture() {
        let session = SelectionAISession()
        session.activate()

        XCTAssertFalse(session.begin(at: CGPoint(x: -1, y: 30), within: bounds))
        XCTAssertEqual(session.snapshot.phase, .armed)
        XCTAssertNil(session.snapshot.selectionRect)
    }

    func testSelectedRegionCanBeReplacedByNewDrag() {
        let session = SelectionAISession(minimumSide: 4)
        session.activate()
        XCTAssertTrue(session.begin(at: CGPoint(x: 10, y: 10), within: bounds))
        XCTAssertNotNil(session.end(at: CGPoint(x: 30, y: 30), within: bounds))

        XCTAssertTrue(session.begin(at: CGPoint(x: 100, y: 50), within: bounds))
        XCTAssertEqual(session.snapshot.phase, .dragging)
        XCTAssertEqual(
            session.end(at: CGPoint(x: 130, y: 80), within: bounds),
            CGRect(x: 100, y: 50, width: 30, height: 30)
        )
    }

    func testStepBackClearsSelectionBeforeExitingTool() {
        let session = SelectionAISession(minimumSide: 4)
        session.activate()
        session.begin(at: CGPoint(x: 10, y: 10), within: bounds)
        session.end(at: CGPoint(x: 40, y: 40), within: bounds)

        XCTAssertTrue(session.stepBack())
        XCTAssertEqual(session.snapshot, .init(phase: .armed, selectionRect: nil))

        XCTAssertTrue(session.stepBack())
        XCTAssertEqual(session.snapshot, .init(phase: .inactive, selectionRect: nil))

        XCTAssertFalse(session.stepBack())
    }

    func testInvalidBoundsNeverStartOrFinalizeSelection() {
        let session = SelectionAISession()
        session.activate()
        let empty = CGRect.zero

        XCTAssertFalse(session.begin(at: .zero, within: empty))
        XCTAssertNil(SelectionAIGeometry.clamped(.zero, to: empty))
        XCTAssertNil(SelectionAIGeometry.finalizedRect(
            from: .zero,
            to: CGPoint(x: 20, y: 20),
            within: empty,
            minimumSide: 8
        ))
    }
}
