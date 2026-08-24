import AppKit
import CoreGraphics

/// 剪切板历史的“粘贴回原应用”平台实现。
///
/// `NSRunningApplication.activate` 是异步的，不能靠一个固定延迟猜它何时完成。
/// 这里等待目标进程真正成为前台应用，再发送 ⌘V；超时则把按键定向投递给目标 PID，
/// 绝不把内容误粘到碰巧仍在前台的窗口。
@MainActor
enum ClipboardPasteDispatcher {

    private static let activationPollNanoseconds: UInt64 = 25_000_000
    private static let focusSettleNanoseconds: UInt64 = 50_000_000
    private static let maximumPollCount = 40

    static func paste(into application: NSRunningApplication) {
        let targetPID = application.processIdentifier
        application.activate(options: [])

        Task {
            for attempt in 0..<maximumPollCount {
                guard !application.isTerminated else {
                    NSLog("[Index] 剪切板粘贴取消：原应用已经退出")
                    return
                }

                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if application.isActive || frontmostPID == targetPID {
                    try? await Task.sleep(nanoseconds: focusSettleNanoseconds)
                    guard !Task.isCancelled else { return }
                    postCommandV()
                    return
                }

                // 某些应用第一次 activate 只取消隐藏而没有拿到前台，半程再请求一次。
                if attempt == maximumPollCount / 2 {
                    application.activate(options: [])
                }
                try? await Task.sleep(nanoseconds: activationPollNanoseconds)
                guard !Task.isCancelled else { return }
            }

            // 目标迟迟没有成为 frontmost 时定向发给它，避免全局事件落进错误应用。
            NSLog("[Index] 剪切板粘贴：等待原应用激活超时，改为定向投递")
            postCommandV(to: targetPID)
        }
    }

    /// 面板原本就在 Index 内打开时，没有外部 PID 可恢复；给 key window 一轮布局时间。
    static func pasteIntoCurrentAppAfterFocusRestores() {
        Task {
            try? await Task.sleep(nanoseconds: focusSettleNanoseconds)
            guard !Task.isCancelled else { return }
            postCommandV()
        }
    }

    private static func postCommandV(to targetPID: pid_t? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand

        if let targetPID {
            down?.postToPid(targetPID)
            up?.postToPid(targetPID)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}
