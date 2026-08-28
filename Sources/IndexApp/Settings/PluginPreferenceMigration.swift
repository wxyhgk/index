import Foundation

/// 将插件列表从“旧版本的空默认值”迁移为当前目录中的全部内置插件。
///
/// 旧版本曾把空数组写进偏好；插件宿主后来把空数组定义为“全部关闭”，导致升级后的
/// 用户连截图插件也不会启动。迁移只执行一次：之后用户主动关闭全部插件时，空数组会
/// 保持其明确语义，不会在每次启动时被重新打开。
enum PluginPreferenceMigration {
    static let enabledPluginIDsKey = "enabledPluginIDs"
    static let versionKey = "pluginPreferenceMigrationVersion"
    static let currentVersion = 1

    static func resolveEnabledPluginIDs(
        in defaults: UserDefaults,
        availablePluginIDs: [String]
    ) -> [String] {
        let stored = defaults.stringArray(forKey: enabledPluginIDsKey)
        guard defaults.integer(forKey: versionKey) < currentVersion else {
            return stored ?? availablePluginIDs
        }

        let resolved: [String]
        if let stored, !stored.isEmpty {
            resolved = stored
        } else {
            resolved = availablePluginIDs
        }
        defaults.set(resolved, forKey: enabledPluginIDsKey)
        defaults.set(currentVersion, forKey: versionKey)
        return resolved
    }
}
