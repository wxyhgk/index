import Carbon
import Foundation

enum IndexInputSourceRegistrar {
    private static let bundleIdentifier = "com.wxyhgk.index.inputmethod.contentshelf"
    private static let inputModeIdentifier = "com.wxyhgk.index.inputmethod.contentshelf.Search"

    static func install() -> Int32 {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard bundleURL.deletingLastPathComponent().lastPathComponent == "Input Methods" else {
            fputs("拒绝注册非安装路径：\(bundleURL.path)\n", stderr)
            fputs("请先复制到 ~/Library/Input Methods/。\n", stderr)
            return 2
        }

        let registrationStatus = TISRegisterInputSource(bundleURL as CFURL)
        guard registrationStatus == noErr else {
            fputs("TISRegisterInputSource 失败：\(registrationStatus)\n", stderr)
            return 3
        }

        // Text Input Source Services 会异步刷新目录。成熟输入法也会在注册和启用之间
        // 留出一个很短的窗口；不依赖退出登录来强制刷新。
        Thread.sleep(forTimeInterval: 0.5)

        guard !matchingSources().isEmpty else {
            fputs("注册请求已接受，但系统尚未枚举 Index 搜索输入源。\n", stderr)
            return 4
        }

        // McBopomofo 在 macOS 12+ 也会无条件重新请求启用 parent source。
        // 这一步不绕过用户确认：新系统会由系统设置弹出启用提示。
        let registeredSources = matchingSources()
        guard let parentSource = registeredSources.first(where: {
            stringProperty($0, key: kTISPropertyInputSourceID) == bundleIdentifier
        }) else {
            fputs("系统已枚举模式，但没有找到 Index 搜索输入法主体。\n", stderr)
            return 5
        }

        let enableStatus = TISEnableInputSource(parentSource)
        guard enableStatus == noErr else {
            fputs("TISEnableInputSource 失败：\(enableStatus)\n", stderr)
            return 6
        }

        print("已注册 Index 搜索并向 macOS 提交启用请求。")
        if matchingSources(includeAllInstalled: false).contains(where: {
            stringProperty($0, key: kTISPropertyInputSourceID) == inputModeIdentifier
        }) {
            print("注册进程已能枚举 Index 搜索。")
            print("这不代表系统设置或其他进程的输入源缓存已刷新。")
        } else {
            print("注册进程尚不能枚举该输入源。")
            print("如果系统设置没有弹出确认，请退出当前账户后重新登录一次。")
        }
        return 0
    }

    static func diagnose() -> Int32 {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let sources = matchingSources()
        print("bundle_path=\(bundleURL.path)")
        print("bundle_id=\(Bundle.main.bundleIdentifier ?? "<missing>")")
        let controllerClassName = Bundle.main.object(
            forInfoDictionaryKey: "InputMethodServerControllerClass"
        ) as? String
        print("controller_class=\(controllerClassName ?? "<missing>")")
        print("controller_class_found=\(controllerClassName.flatMap { NSClassFromString($0) } != nil)")
        print("matching_sources=\(sources.count)")
        let sessionSources = matchingSources(includeAllInstalled: false)
        let availableInCurrentSession = sessionSources.contains { source in
            stringProperty(source, key: kTISPropertyInputSourceID) == inputModeIdentifier
        }
        print("registrar_process_sources=\(sessionSources.count)")
        print("visible_to_registrar_process=\(availableInCurrentSession)")
        print("注意：这两个值不能代表系统设置的独立进程已刷新。")

        let legacySystemBundleURL = URL(
            fileURLWithPath: "/Library/Input Methods/IndexInputMethod.app",
            isDirectory: true
        )
        if let legacyBundle = Bundle(url: legacySystemBundleURL) {
            print("legacy_system_bundle=\(legacySystemBundleURL.path)")
            print("legacy_system_bundle_id=\(legacyBundle.bundleIdentifier ?? "<missing>")")
        }

        for source in sources {
            let sourceID = stringProperty(source, key: kTISPropertyInputSourceID) ?? "<missing>"
            let enabled = boolProperty(source, key: kTISPropertyInputSourceIsEnabled) ?? false
            let selectCapable = boolProperty(
                source,
                key: kTISPropertyInputSourceIsSelectCapable
            ) ?? false
            let localizedName = stringProperty(source, key: kTISPropertyLocalizedName) ?? "<missing>"
            print(
                "source_id=\(sourceID) name=\(localizedName) "
                    + "enabled=\(enabled) select_capable=\(selectCapable)"
            )
        }

        return sources.isEmpty ? 4 : 0
    }

    private static func matchingSources(includeAllInstalled: Bool = true) -> [TISInputSource] {
        let sources = TISCreateInputSourceList(
            nil,
            includeAllInstalled
        ).takeRetainedValue() as! [TISInputSource]
        return sources.filter { source in
            let sourceBundleID = stringProperty(source, key: kTISPropertyBundleID)
            let sourceID = stringProperty(source, key: kTISPropertyInputSourceID)
            return sourceBundleID == bundleIdentifier
                || sourceID == bundleIdentifier
                || sourceID == inputModeIdentifier
        }
    }

    private static func stringProperty(
        _ source: TISInputSource,
        key: CFString
    ) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        return value as? String
    }

    private static func boolProperty(
        _ source: TISInputSource,
        key: CFString
    ) -> Bool? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        return value as? Bool
    }
}
