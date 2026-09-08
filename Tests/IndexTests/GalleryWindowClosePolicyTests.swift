import XCTest
@testable import IndexApp

@MainActor
final class GalleryWindowClosePolicyTests: XCTestCase {

    func testEditingCloseIsAllowedAfterSaveSucceeds() {
        let relay = EditorSessionRelay()
        var attempts = 0
        relay.install(shotID: 42) {
            attempts += 1
            return true
        }

        XCTAssertTrue(GalleryWindowClosePolicy.shouldClose(
            mode: .editing(42),
            editorSessionRelay: relay
        ))
        XCTAssertEqual(attempts, 1)
    }

    func testEditingCloseIsRejectedWhenSaveFails() {
        let relay = EditorSessionRelay()
        var attempts = 0
        relay.install(shotID: 42) {
            attempts += 1
            return false
        }

        XCTAssertFalse(GalleryWindowClosePolicy.shouldClose(
            mode: .editing(42),
            editorSessionRelay: relay
        ))
        XCTAssertEqual(attempts, 1)
    }

    func testEditingCloseBeforeSessionInstallationIsAllowed() {
        XCTAssertTrue(GalleryWindowClosePolicy.shouldClose(
            mode: .editing(42),
            editorSessionRelay: EditorSessionRelay()
        ))
    }

    func testNonAnnotationModesDoNotAskEditorSessionToSave() {
        let relay = EditorSessionRelay()
        var attempts = 0
        relay.install(shotID: 42) {
            attempts += 1
            return false
        }

        for mode: GalleryWindowMode.Mode in [
            .library,
            .markdownEditing(42),
            .codeEditing(42),
            .settings,
        ] {
            XCTAssertTrue(GalleryWindowClosePolicy.shouldClose(
                mode: mode,
                editorSessionRelay: relay
            ))
        }
        XCTAssertEqual(attempts, 0)
    }
}
