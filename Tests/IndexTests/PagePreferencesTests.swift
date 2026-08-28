import Foundation
import XCTest
@testable import IndexApp

@MainActor
final class PagePreferencesTests: XCTestCase {
    func testKeysKeepExistingUserDefaultsNames() {
        XCTAssertEqual(PagePreferences.galleryInspectorShown.key, "galleryInspectorShown")
        XCTAssertEqual(PagePreferences.galleryLayout.key, "galleryLayout")
        XCTAssertEqual(PagePreferences.galleryZoom.key, "galleryZoom")
        XCTAssertEqual(PagePreferences.galleryDestination.key, "galleryDestination")
        XCTAssertEqual(PagePreferences.appsOverviewSort.key, "appsOverviewSort")
        XCTAssertEqual(PagePreferences.editorFilmstripCollapsed.key, "editorFilmstripCollapsed")
        XCTAssertEqual(PagePreferences.clipboardPanelPositionSaved.key, "clipboardPanelPositionSaved")
        XCTAssertEqual(PagePreferences.clipboardPanelRelativeX.key, "clipboardPanelRelX")
        XCTAssertEqual(PagePreferences.clipboardPanelRelativeY.key, "clipboardPanelRelY")
    }

    func testSharedDefaultsMatchExistingPageBehavior() {
        XCTAssertTrue(PagePreferences.galleryInspectorShown.defaultValue)
        XCTAssertEqual(PagePreferences.galleryZoom.defaultValue, 200)
        XCTAssertEqual(PagePreferences.galleryDestination.defaultValue, LibraryDestination.destinationID)
        XCTAssertFalse(PagePreferences.editorFilmstripCollapsed.defaultValue)
        XCTAssertFalse(PagePreferences.clipboardPanelPositionSaved.defaultValue)

        XCTAssertEqual(
            PagePreferences.galleryLayout.enumDefault(as: GalleryLayoutKind.self).rawValue,
            GalleryLayoutKind.grid.rawValue
        )
        XCTAssertEqual(
            PagePreferences.appsOverviewSort.enumDefault(as: AppsOverviewSort.self).rawValue,
            AppsOverviewSort.captureCount.rawValue
        )
    }

    func testTypedUserDefaultsAccessPreservesLegacyStorage() throws {
        let suiteName = "PagePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(defaults.bool(for: PagePreferences.clipboardPanelPositionSaved))
        XCTAssertEqual(defaults.double(for: PagePreferences.clipboardPanelRelativeX), 0)

        defaults.set(true, for: PagePreferences.clipboardPanelPositionSaved)
        defaults.set(0.375, for: PagePreferences.clipboardPanelRelativeX)

        XCTAssertTrue(defaults.bool(forKey: "clipboardPanelPositionSaved"))
        XCTAssertEqual(defaults.double(forKey: "clipboardPanelRelX"), 0.375)
        XCTAssertTrue(defaults.bool(for: PagePreferences.clipboardPanelPositionSaved))
        XCTAssertEqual(defaults.double(for: PagePreferences.clipboardPanelRelativeX), 0.375)
    }
}
