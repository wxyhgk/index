import Combine
import XCTest
@testable import MacShot

@MainActor
final class GallerySelectionTests: XCTestCase {
    func testSelectionTransactionPublishesOnce() {
        let selection = GallerySelection()
        var changes = 0
        let subscription = selection.objectWillChange.sink { changes += 1 }

        selection.select(only: 42)

        XCTAssertEqual(selection.selectedIDs, [42])
        XCTAssertEqual(selection.anchorID, 42)
        XCTAssertEqual(selection.primaryID, 42)
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(subscription) {}
    }

    func testToggleAndSelectAllKeepExistingSemantics() {
        let selection = GallerySelection()
        selection.select(only: 2)
        selection.toggle(3)
        XCTAssertEqual(selection.selectedIDs, [2, 3])
        XCTAssertEqual(selection.primaryID, 3)
        XCTAssertEqual(selection.anchorID, 3)

        selection.selectAll([1, 2, 3, 4])
        XCTAssertEqual(selection.selectedIDs, [1, 2, 3, 4])
        XCTAssertEqual(selection.primaryID, 3, "仍在集合里的主选中不应跳动")
    }
}
