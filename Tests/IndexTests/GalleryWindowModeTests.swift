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

    func testCodeEditorUsesItsOwnInWindowMode() {
        let subject = GalleryWindowMode()

        subject.openCodeEditor(shotID: 84)

        XCTAssertEqual(subject.mode, .codeEditing(84))
        XCTAssertEqual(subject.activeShotID, 84)
        XCTAssertEqual(subject.codeEditingShotID, 84)
        XCTAssertNil(subject.editingShotID)
        XCTAssertNil(subject.markdownEditingShotID)
        XCTAssertTrue(subject.isEditing)
    }

    func testNilCodeShotDoesNotLeaveLibrary() {
        let subject = GalleryWindowMode()

        subject.openCodeEditor(shotID: nil)

        XCTAssertEqual(subject.mode, .library)
    }
}
