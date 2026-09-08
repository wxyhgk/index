import XCTest
@testable import IndexApp

final class EditorInspectorOrderingTests: XCTestCase {
    func testVisibleLayersArePresentedTopmostFirstAndEffectsAreExcluded() {
        let bottom = Layer(kind: .rect, rect: LRect(x: 0, y: 0, w: 10, h: 10))
        let middleEffect = Layer(kind: .watermark, rect: LRect(x: 0, y: 0, w: 10, h: 10))
        let top = Layer(kind: .arrow, rect: LRect(x: 0, y: 0, w: 10, h: 10))

        let displayed = EditorInspectorOrdering.visibleLayersTopFirst([
            bottom, middleEffect, top
        ])

        XCTAssertEqual(displayed.map(\.id), [top.id, bottom.id])
    }

    func testRevisionIndicesArePresentedNewestFirst() {
        XCTAssertEqual(
            EditorInspectorOrdering.newestFirstIndices(count: 4),
            [3, 2, 1, 0]
        )
        XCTAssertEqual(EditorInspectorOrdering.newestFirstIndices(count: 0), [])
    }
}
