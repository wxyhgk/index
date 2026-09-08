import XCTest
@testable import IndexApp

@MainActor
final class GalleryDestinationChromeTests: XCTestCase {
    func testLibraryPresetOwnsEveryScreenshotPageCapability() {
        XCTAssertEqual(
            .library,
            GalleryDestinationChrome(
                showsImportControl: true,
                showsMarkdownControl: true,
                showsCaptureControl: true,
                showsSearch: true,
                showsLayoutControls: true,
                showsInspector: true,
                inspectorRequiresSelection: true,
                showsThumbnailSizePicker: true
            )
        )
    }

    func testSpecializedContentPresetsDoNotExposeUnrelatedControls() {
        XCTAssertFalse(GalleryDestinationChrome.recordings.showsImportControl)
        XCTAssertFalse(GalleryDestinationChrome.recordings.showsMarkdownControl)
        XCTAssertTrue(GalleryDestinationChrome.recordings.showsCaptureControl)
        XCTAssertTrue(GalleryDestinationChrome.recordings.showsInspector)
        XCTAssertTrue(GalleryDestinationChrome.recordings.inspectorRequiresSelection)

        XCTAssertEqual(
            .clipboard,
            GalleryDestinationChrome(
                showsSearch: false,
                showsLayoutControls: false,
                showsInspector: true,
                inspectorRequiresSelection: false
            )
        )
        XCTAssertFalse(GalleryDestinationChrome.clipboard.inspectorRequiresSelection)
        XCTAssertTrue(GalleryDestinationChrome.clipboard.canPresentInspector(hasSelection: false))

        XCTAssertEqual(
            .conversation,
            GalleryDestinationChrome(
                showsSearch: false,
                showsLayoutControls: false,
                showsInspector: false
            )
        )
    }

    func testScreenshotInspectorOnlyPresentsAfterSelection() {
        XCTAssertFalse(GalleryDestinationChrome.library.canPresentInspector(hasSelection: false))
        XCTAssertTrue(GalleryDestinationChrome.library.canPresentInspector(hasSelection: true))
        XCTAssertFalse(GalleryDestinationChrome.conversation.canPresentInspector(hasSelection: true))
    }

    func testOverviewAndDrillChangeTheWholePageCapabilitySnapshot() {
        XCTAssertTrue(GalleryDestinationChrome.overview.showsCaptureControl)
        XCTAssertTrue(GalleryDestinationChrome.overview.showsSearch)
        XCTAssertFalse(GalleryDestinationChrome.overview.showsLayoutControls)
        XCTAssertFalse(GalleryDestinationChrome.overview.showsInspector)

        XCTAssertTrue(GalleryDestinationChrome.drilledGrid.showsCaptureControl)
        XCTAssertTrue(GalleryDestinationChrome.drilledGrid.showsLayoutControls)
        XCTAssertTrue(GalleryDestinationChrome.drilledGrid.showsInspector)
        XCTAssertTrue(GalleryDestinationChrome.drilledGrid.showsThumbnailSizePicker)
    }

    func testDestinationOverrideDoesNotLeakIntoAnotherPage() {
        let state = GalleryDestinationChromeState()

        state.set(.drilledGrid, for: AppsDestination.destinationID)

        XCTAssertEqual(
            state.resolve(for: AppsDestination.destinationID, fallback: .overview),
            .drilledGrid
        )
        XCTAssertEqual(
            state.resolve(for: CollectionsDestination.destinationID, fallback: .overview),
            .overview
        )
    }

    func testClearingOverrideRestoresDestinationDefault() {
        let state = GalleryDestinationChromeState()
        state.set(.drilledGrid, for: CollectionsDestination.destinationID)

        state.clear(for: CollectionsDestination.destinationID)

        XCTAssertEqual(
            state.resolve(for: CollectionsDestination.destinationID, fallback: .overview),
            .overview
        )
    }

    func testCollectionsImageRoutesPublishDrilledGridChrome() {
        let navigation = CollectionsNavigationState()
        XCTAssertEqual(navigation.chrome, .overview)

        navigation.route = .favorites
        XCTAssertEqual(navigation.chrome, .drilledGrid)

        navigation.route = .collection(42)
        XCTAssertEqual(navigation.chrome, .drilledGrid)
    }

    func testClipboardFavoritesPublishesInspectorOnlyChrome() {
        let navigation = CollectionsNavigationState(route: .clipboardFavorites)

        XCTAssertEqual(navigation.chrome, CollectionsDestination.clipboardFavoritesChrome)
        XCTAssertFalse(navigation.chrome.showsSearch)
        XCTAssertFalse(navigation.chrome.showsLayoutControls)
        XCTAssertTrue(navigation.chrome.showsInspector)
        XCTAssertFalse(navigation.chrome.showsThumbnailSizePicker)
        XCTAssertFalse(navigation.chrome.showsCaptureControl)
    }
}
