import GRDB
import XCTest
@testable import IndexApp

@MainActor
final class ClipboardPageSessionTests: XCTestCase {
    func testScopedPageResolvesSelectionWithoutReadingTabFilteredItems() throws {
        let store = try ClipboardHistoryStore(writer: DatabaseQueue())
        let viewModel = ClipboardHistoryViewModel(store: store)
        let tabItem = makeItem(id: 1, summary: "Tab item")
        let favoriteItem = makeItem(id: 2, summary: "Favorite item", isFavorite: true)
        viewModel.items = [tabItem]

        let selection = ClipboardSelection(selectedID: favoriteItem.id)
        let session = ClipboardPageSession(
            viewModel: viewModel,
            selection: selection,
            scopedItems: [favoriteItem]
        )

        XCTAssertEqual(viewModel.filteredItems.map(\.id), [tabItem.id])
        XCTAssertEqual(session.selectedItem, favoriteItem)
    }

    func testReplacingPageItemsClearsSelectionThatIsNoLongerVisible() throws {
        let store = try ClipboardHistoryStore(writer: DatabaseQueue())
        let selected = makeItem(id: 7, summary: "Selected")
        let replacement = makeItem(id: 8, summary: "Replacement")
        let selection = ClipboardSelection(selectedID: selected.id)
        let session = ClipboardPageSession(
            store: store,
            selection: selection,
            scopedItems: [selected]
        )

        session.setScopedItems([replacement])

        XCTAssertNil(selection.selectedID)
        XCTAssertNil(session.selectedItem)
        XCTAssertEqual(session.visibleItems, [replacement])
    }

    func testPageSessionsKeepSelectionIndependent() throws {
        let store = try ClipboardHistoryStore(writer: DatabaseQueue())
        let item = makeItem(id: 11, summary: "Independent")
        let first = ClipboardPageSession(store: store, scopedItems: [item])
        let second = ClipboardPageSession(store: store, scopedItems: [item])

        first.selection.select(item.id)

        XCTAssertEqual(first.selectedItem, item)
        XCTAssertNil(second.selection.selectedID)
        XCTAssertNil(second.selectedItem)
        XCTAssertFalse(first.viewModel === second.viewModel)
    }

    func testRemovingScopedItemAlsoClearsItsSelection() throws {
        let store = try ClipboardHistoryStore(writer: DatabaseQueue())
        let item = makeItem(id: 21, summary: "Deleted")
        let session = ClipboardPageSession(store: store, scopedItems: [item])
        session.selection.select(item.id)

        session.removeScopedItem(item)

        XCTAssertTrue(session.visibleItems.isEmpty)
        XCTAssertNil(session.selection.selectedID)
    }

    func testRemovingTabItemClearsSelectionWithoutCreatingScopedItems() throws {
        let store = try ClipboardHistoryStore(writer: DatabaseQueue())
        let item = makeItem(id: 22, summary: "Tab item")
        let session = ClipboardPageSession(store: store)
        session.viewModel.items = [item]
        session.selection.select(item.id)

        session.removeScopedItem(item)

        XCTAssertNil(session.scopedItems)
        XCTAssertNil(session.selection.selectedID)
    }

    private func makeItem(
        id: Int64,
        summary: String,
        isFavorite: Bool = false
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: id,
            kind: .text,
            contentHash: "hash-\(id)",
            text: summary,
            assetPath: nil,
            summary: summary,
            sourceApp: "Tests",
            pinned: false,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(id)),
            lastUsedAt: nil,
            title: nil,
            isFavorite: isFavorite
        )
    }
}
