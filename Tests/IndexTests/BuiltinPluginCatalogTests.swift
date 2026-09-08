import XCTest
@testable import IndexApp

@MainActor
final class BuiltinPluginCatalogTests: XCTestCase {
    func testCatalogUsesUniqueIDsAndContainsInputSearchPlugin() throws {
        PluginAssembly.registerBuiltins()
        let descriptors = BuiltinPluginCatalog.shared.all
        XCTAssertEqual(Set(descriptors.map(\.id)).count, descriptors.count)

        let inputSearch = try XCTUnwrap(
            descriptors.first { $0.id == InputSearchPlugin.pluginID }
        )
        XCTAssertEqual(inputSearch.displayName, "输入即检索")
        XCTAssertTrue(inputSearch.supportsLiveToggle)
        XCTAssertEqual(inputSearch.make().id, InputSearchPlugin.pluginID)
    }

    func testEmptyEnabledPluginListMeansAllPluginsAreOff() {
        XCTAssertFalse(BuiltinPluginHost.isEnabled("capture", in: []))
        XCTAssertFalse(BuiltinPluginHost.isEnabled(InputSearchPlugin.pluginID, in: []))
        XCTAssertTrue(BuiltinPluginHost.isEnabled("capture", in: ["capture"]))
    }

    func testLegacyEmptyPluginListMigratesToAllAvailablePluginsOnce() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([String](), forKey: PluginPreferenceMigration.enabledPluginIDsKey)

        let available = ["capture", "recording", "pin"]
        XCTAssertEqual(
            PluginPreferenceMigration.resolveEnabledPluginIDs(
                in: defaults,
                availablePluginIDs: available
            ),
            available
        )
        XCTAssertEqual(
            defaults.integer(forKey: PluginPreferenceMigration.versionKey),
            PluginPreferenceMigration.currentVersion
        )

        // 迁移完成后，用户主动关闭全部插件仍然保留“全关”语义。
        defaults.set([String](), forKey: PluginPreferenceMigration.enabledPluginIDsKey)
        XCTAssertEqual(
            PluginPreferenceMigration.resolveEnabledPluginIDs(
                in: defaults,
                availablePluginIDs: available
            ),
            []
        )
    }

    func testPluginMigrationPreservesAnExistingNonemptySelection() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["capture"], forKey: PluginPreferenceMigration.enabledPluginIDsKey)

        XCTAssertEqual(
            PluginPreferenceMigration.resolveEnabledPluginIDs(
                in: defaults,
                availablePluginIDs: ["capture", "recording"]
            ),
            ["capture"]
        )
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "BuiltinPluginCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
