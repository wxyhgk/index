import XCTest
@testable import IndexApp

final class ContentLibrarySessionTests: XCTestCase {

    func testTabRawValuesRemainStableForPersistence() {
        XCTAssertEqual(
            ContentLibraryTab.allCases.map(\.rawValue),
            ["shots", "recordings", "clipboard", "ai"]
        )
    }

    @MainActor
    func testEachTabMapsToItsExactDestinationChrome() {
        XCTAssertEqual(ContentLibraryTab.shots.destinationChrome, .library)
        XCTAssertEqual(ContentLibraryTab.recordings.destinationChrome, .recordings)
        XCTAssertEqual(ContentLibraryTab.clipboard.destinationChrome, .clipboard)
        XCTAssertEqual(ContentLibraryTab.ai.destinationChrome, .conversation)

        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ai", forKey: ContentLibrarySession.defaultsKey)
        let destination = LibraryDestination(session: ContentLibrarySession(defaults: defaults))
        XCTAssertEqual(destination.defaultChrome, .conversation)
    }

    @MainActor
    func testSessionRestoresValidTabAndFallsBackForUnknownValue() {
        let (validDefaults, validSuite) = makeDefaults()
        defer { validDefaults.removePersistentDomain(forName: validSuite) }
        validDefaults.set("clipboard", forKey: ContentLibrarySession.defaultsKey)
        XCTAssertEqual(ContentLibrarySession(defaults: validDefaults).tab, .clipboard)

        let (invalidDefaults, invalidSuite) = makeDefaults()
        defer { invalidDefaults.removePersistentDomain(forName: invalidSuite) }
        invalidDefaults.set("removed-tab", forKey: ContentLibrarySession.defaultsKey)
        XCTAssertEqual(ContentLibrarySession(defaults: invalidDefaults).tab, .shots)
    }

    @MainActor
    func testSelectionPublishesImmediatelyAndOnlyPersistsLatestDebouncedTab() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ContentLibrarySession(defaults: defaults)

        session.select(.recordings)
        XCTAssertEqual(session.tab, .recordings)
        XCTAssertNil(defaults.string(forKey: ContentLibrarySession.defaultsKey))

        session.select(.clipboard)
        XCTAssertEqual(session.tab, .clipboard)

        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(defaults.string(forKey: ContentLibrarySession.defaultsKey), "clipboard")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "ContentLibrarySessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
