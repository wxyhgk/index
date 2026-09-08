import XCTest
@testable import IndexApp

final class EditorFilmstripLayoutTests: XCTestCase {
    func testVerticalMouseWheelMovesFilmstripHorizontally() {
        let destination = EditorFilmstripWheel.destinationX(
            originX: 100,
            documentWidth: 1_000,
            viewportWidth: 400,
            deltaY: -1,
            hasPreciseDeltas: false
        )

        XCTAssertEqual(destination, 118)
        XCTAssertTrue(EditorFilmstripWheel.shouldConvert(deltaX: 0, deltaY: -1))
    }

    func testHorizontalGestureIsLeftToNativeScrollView() {
        XCTAssertFalse(EditorFilmstripWheel.shouldConvert(deltaX: 12, deltaY: 2))
        XCTAssertFalse(EditorFilmstripWheel.shouldConvert(deltaX: 0, deltaY: 0))
    }

    func testWheelDestinationIsClampedToDocumentBounds() {
        XCTAssertEqual(
            EditorFilmstripWheel.destinationX(
                originX: 2,
                documentWidth: 1_000,
                viewportWidth: 400,
                deltaY: 20,
                hasPreciseDeltas: true
            ),
            0
        )
        XCTAssertEqual(
            EditorFilmstripWheel.destinationX(
                originX: 598,
                documentWidth: 1_000,
                viewportWidth: 400,
                deltaY: -20,
                hasPreciseDeltas: true
            ),
            600
        )
    }

    func testVerticalWheelRemainsFilmstripOwnedAtHorizontalBoundary() {
        XCTAssertTrue(EditorFilmstripWheel.shouldConvert(deltaX: 0, deltaY: 8))
        XCTAssertEqual(
            EditorFilmstripWheel.destinationX(
                originX: 0,
                documentWidth: 1_000,
                viewportWidth: 400,
                deltaY: 8,
                hasPreciseDeltas: true
            ),
            0
        )
        // Coordinator 在 destination 未变化时仍消费这类事件，防止泄漏到画布。
    }

    @MainActor
    func testSessionRelayFlushesCurrentSessionBeforeSwitch() {
        let relay = EditorSessionRelay()
        var flushed: [Int64] = []

        relay.install(shotID: 7) {
            flushed.append(7)
            return true
        }
        XCTAssertTrue(relay.flush(shotID: 7))

        XCTAssertEqual(flushed, [7])
    }

    @MainActor
    func testStaleSessionCannotClearNewFlushAction() {
        let relay = EditorSessionRelay()
        var flushed: [Int64] = []

        relay.install(shotID: 7) {
            flushed.append(7)
            return true
        }
        relay.install(shotID: 8) {
            flushed.append(8)
            return true
        }
        relay.remove(shotID: 7)
        XCTAssertTrue(relay.flush(shotID: 8))

        XCTAssertEqual(flushed, [8])
    }

    func testExtremelyWideImageStaysInsideFixedCell() {
        let fitted = EditorFilmstripLayout.fittedImageSize(
            pixelWidth: 1_040,
            pixelHeight: 51
        )

        XCTAssertEqual(fitted.width, EditorFilmstripLayout.cellSize.width, accuracy: 0.001)
        XCTAssertLessThan(fitted.height, EditorFilmstripLayout.cellSize.height)
    }

    func testExtremelyTallImageStaysInsideFixedCell() {
        let fitted = EditorFilmstripLayout.fittedImageSize(
            pixelWidth: 1_090,
            pixelHeight: 5_743
        )

        XCTAssertEqual(fitted.height, EditorFilmstripLayout.cellSize.height, accuracy: 0.001)
        XCTAssertGreaterThan(fitted.width, 0)
        XCTAssertLessThan(fitted.width, EditorFilmstripLayout.cellSize.width)
    }

    func testInvalidPixelSizeProducesNoImageGeometry() {
        XCTAssertEqual(
            EditorFilmstripLayout.fittedImageSize(pixelWidth: 0, pixelHeight: 100),
            .zero
        )
        XCTAssertEqual(
            EditorFilmstripLayout.fittedImageSize(pixelWidth: 100, pixelHeight: 0),
            .zero
        )
    }

    func testFilmstripAddsCurrentItemWhenItIsOutsideRecentPage() {
        let merged = EditorFilmstripItems.mergingCurrent(
            into: [3, 2, 1],
            current: 99,
            currentID: 99,
            id: { Int64($0) }
        )

        XCTAssertEqual(merged, [99, 3, 2, 1])
    }

    func testFilmstripDoesNotDuplicateCurrentItemAlreadyInRecentPage() {
        let merged = EditorFilmstripItems.mergingCurrent(
            into: [3, 2, 1],
            current: 2,
            currentID: 2,
            id: { Int64($0) }
        )

        XCTAssertEqual(merged, [3, 2, 1])
    }
}
