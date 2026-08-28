import AppKit
import InputMethodKit

if CommandLine.arguments.contains("--install") {
    exit(IndexInputSourceRegistrar.install())
}

if CommandLine.arguments.contains("--diagnose") {
    exit(IndexInputSourceRegistrar.diagnose())
}

guard let bundleIdentifier = Bundle.main.bundleIdentifier,
      let connectionName = Bundle.main.object(
          forInfoDictionaryKey: "InputMethodConnectionName"
      ) as? String,
      let inputMethodServer = IMKServer(
          name: connectionName,
          bundleIdentifier: bundleIdentifier
      )
else {
    NSLog("[IndexInputMethod] 无法初始化 InputMethodKit server")
    exit(EXIT_FAILURE)
}

// 顶层常量在 NSApplication run loop 的整个生命周期内强持有 server。
withExtendedLifetime(inputMethodServer) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApplication.shared.run()
}
