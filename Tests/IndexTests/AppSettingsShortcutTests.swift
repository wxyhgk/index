import Carbon.HIToolbox
import XCTest
@testable import IndexApp

@MainActor
final class AppSettingsShortcutTests: XCTestCase {

    func testWorkspaceShortcutsPersistAcrossSettingsInstances() throws {
        let suiteName = "AppSettingsShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let search = KeyboardShortcut(
            keyCode: 31,
            modifiers: UInt32(controlKey) | UInt32(optionKey)
        )
        let quickNote = KeyboardShortcut(
            keyCode: 45,
            modifiers: UInt32(shiftKey) | UInt32(optionKey)
        )

        let settings = AppSettings(defaults: defaults)
        settings.shortcuts.searchPanelShortcut = search
        settings.shortcuts.quickNoteShortcut = quickNote

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.shortcuts.searchPanelShortcut, search)
        XCTAssertEqual(reloaded.shortcuts.quickNoteShortcut, quickNote)
    }
}
