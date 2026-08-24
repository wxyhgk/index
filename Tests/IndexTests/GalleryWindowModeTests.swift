import XCTest
@testable import IndexApp

@MainActor
final class GalleryWindowModeTests: XCTestCase {

    func testMarkdownEditorUsesItsOwnInWindowMode() {
        let subject = GalleryWindowMode()

        subject.openMarkdownEditor(shotID: 42)

        XCTAssertEqual(subject.mode, .markdownEditing(42))
        XCTAssertEqual(subject.activeShotID, 42)
        XCTAssertEqual(subject.markdownEditingShotID, 42)
        XCTAssertNil(subject.editingShotID)
        XCTAssertTrue(subject.isEditing)
    }

    func testReturningFromMarkdownEditorRestoresLibraryMode() {
        let subject = GalleryWindowMode()
        subject.openMarkdownEditor(shotID: 42)

        subject.returnToGallery()

        XCTAssertEqual(subject.mode, .library)
        XCTAssertNil(subject.activeShotID)
        XCTAssertFalse(subject.isEditing)
    }

    func testNilMarkdownShotDoesNotLeaveLibrary() {
        let subject = GalleryWindowMode()

        subject.openMarkdownEditor(shotID: nil)

        XCTAssertEqual(subject.mode, .library)
    }
}
