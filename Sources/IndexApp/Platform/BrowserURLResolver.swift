import Foundation

/// 取浏览器当前标签页地址。
///
/// 这件事**永远不能挡在截图路径上**：Apple Event 是同步 IPC，对方 App 卡住、或者系统正在弹
/// 「自动化」授权框时，调用方会一直等（默认超时是分钟级的）。之前直接在主线程跑 NSAppleScript，
/// 结果就是截图完点任何按钮整个 App 假死。
///
/// 用 osascript 子进程而不是 NSAppleScript，是因为**子进程可以被杀掉**，被阻塞的线程不行。
///
/// 它只负责「问出地址」，问到之后往哪儿放由 `BrowserURLProcessor` 决定。
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

    /// - Note: 此前是 `while process.isRunning { usleep(50_000) }` 忙等，
    ///   最长会把一条协作线程池的线程堵住 3 秒。改成 terminationHandler + 续体，
    ///   等待期间不占线程；超时用一个看门狗任务把子进程杀掉，杀掉同样会触发 handler。
    static func resolve(bundleID: String) async -> String? {
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

        // 超时看门狗：到点就杀掉子进程。子进程能被杀，被阻塞的线程不能 ——
        // 这也是这里用 osascript 子进程而不是 NSAppleScript 的原因。
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }

        // terminationHandler 必须在 run() 之前装好，否则子进程秒退时会错过回调。
        let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            process.terminationHandler = { _ in continuation.resume(returning: true) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                NSLog("[Index] 无法启动 osascript: \(error)")
                continuation.resume(returning: false)
            }
        }
        watchdog.cancel()

        guard started else { return nil }
        guard process.terminationStatus == 0 else {
            NSLog("[Index] 取浏览器地址失败或超时: \(bundleID)")
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }
}
