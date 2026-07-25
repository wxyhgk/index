import Foundation

/// 取浏览器当前标签页地址。
///
/// 这件事**永远不能挡在截图路径上**：Apple Event 是同步 IPC，对方 App 卡住、或者系统正在弹
/// 「自动化」授权框时，调用方会一直等（默认超时是分钟级的）。之前直接在主线程跑 NSAppleScript，
/// 结果就是截图完点任何按钮整个 App 假死。
///
/// 现在改成：走子进程 + 硬超时，在后台线程执行，拿到结果再异步回填数据库。
/// 用 osascript 子进程而不是 NSAppleScript，是因为**子进程可以被杀掉**，被阻塞的线程不行。
enum BrowserURLResolver {

    /// 已知支持 AppleScript 取地址的浏览器。Firefox 不支持（需退回 Accessibility），暂不处理。
    private static let chromium: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi"
    ]
    private static let safari: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview"
    ]

    static func supports(_ bundleID: String) -> Bool {
        chromium.contains(bundleID) || safari.contains(bundleID)
    }

    private static let timeout: TimeInterval = 3

    /// 阻塞调用，只应该在后台线程使用。
    static func resolve(bundleID: String) -> String? {
        guard supports(bundleID) else { return nil }

        let source: String
        if safari.contains(bundleID) {
            source = """
            tell application id "\(bundleID)"
                if (count of documents) is 0 then return ""
                return URL of front document
            end tell
            """
        } else {
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of active tab of front window
            end tell
            """
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("[MacShot] 无法启动 osascript: \(error)")
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }

        if process.isRunning {
            process.terminate()
            NSLog("[MacShot] 取浏览器地址超时，已放弃: \(bundleID)")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }
}

enum BrowserURLQueue {

    /// 后台解析并回填。失败或超时都只是没有地址，不影响任何其它环节。
    static func enqueue(bundleID: String, shotID: Int64) {
        guard BrowserURLResolver.supports(bundleID) else { return }
        Task.detached(priority: .utility) {
            guard let url = BrowserURLResolver.resolve(bundleID: bundleID) else { return }
            await MainActor.run {
                ShotStore.shared.updateSourceURL(shotID: shotID, url: url)
            }
        }
    }
}
