import AppKit
import CoreGraphics

/// 剪切板历史的“粘贴回原应用”平台实现。
///
/// `NSRunningApplication.activate` 是异步的，不能靠一个固定延迟猜它何时完成。
/// 这里等待目标进程真正成为前台应用，再发送 ⌘V；超时则把按键定向投递给目标 PID，
/// 绝不把内容误粘到碰巧仍在前台的窗口。
@MainActor
enum ClipboardPasteDispatcher {

    private static let activationPollNanoseconds: UInt64 = 10_000_000
    private static let focusSettleNanoseconds: UInt64 = 12_000_000
    /// nonactivatingPanel 关闭后，原应用仍然是 active，但 WindowServer 需要一段
    /// 时间把 key window / field editor 交还。早期实现是在 300ms 后发送按键；
    /// 完全拿不到 AX 窗口/控件时，给 WindowServer 一个很短的被动交接窗口。
    /// 正常应用都有 focused window，不会进入这条降级路径。
    private static let passiveFocusHandoffNanoseconds: UInt64 = 60_000_000
    private static let focusRestorePollNanoseconds: UInt64 = 12_000_000
    private static let maximumPollCount = 40

    static var hasEventPostingAccess: Bool {
        CGPreflightPostEventAccess()
    }

    /// 首次使用直接粘贴时由系统请求事件注入权限。返回 false 时系统可能已经
    /// 展示授权入口；这一次只保留剪贴板内容，不发送一个必然会被丢弃的 ⌘V。
    @discardableResult
    static func requestEventPostingAccessIfNeeded() -> Bool {
        if hasEventPostingAccess { return true }
        let granted = CGRequestPostEventAccess()
        NSLog(
            "[Index][ClipboardPaste] post-event authorization requested granted=%d",
            granted ? 1 : 0
        )
        return granted
    }

    /// 兼容只保存应用的旧调用方；剪贴板弹窗使用带窗口/控件快照的重载。
    static func paste(into application: NSRunningApplication) {
        paste(into: ClipboardPasteTarget.capture(application: application))
    }

    static func paste(into target: ClipboardPasteTarget) {
        guard requestEventPostingAccessIfNeeded() else {
            NSLog("[Index][ClipboardPaste] commandV skipped: post-event access unavailable")
            return
        }

        let application = target.application
        let targetPID = target.processIdentifier
        NSLog("[Index][ClipboardPaste] activate targetPID=%d", targetPID)
        application.activate(options: [])

        Task {
            if !target.hasRestorableFocusSnapshot {
                try? await Task.sleep(nanoseconds: passiveFocusHandoffNanoseconds)
                guard !Task.isCancelled else { return }
            }
            for attempt in 0..<maximumPollCount {
                guard !application.isTerminated else {
                    NSLog("[Index] 剪切板粘贴取消：原应用已经退出")
                    return
                }

                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if application.isActive || frontmostPID == targetPID {
                    for focusAttempt in 0..<ClipboardPasteFocusRestorationPolicy.maximumAttemptCount {
                        // 等一轮很短的 WindowServer 交接，再做一次同步 AX 恢复与验证。
                        // 验证成功后立即投递，不再额外等待并重复执行第二次 AX IPC。
                        try? await Task.sleep(nanoseconds: focusSettleNanoseconds)
                        guard !Task.isCancelled else { return }
                        let restored = target.restoreFocus()
                        if ClipboardPasteFocusRestorationPolicy.shouldPostCommandV(
                            hasFocusSnapshot: target.hasRestorableFocusSnapshot,
                            isFocusRestored: restored,
                            attempt: focusAttempt
                        ) {
                            NSLog(
                                "[Index][ClipboardPaste] post commandV targetPID=%d windowSnapshot=%d elementSnapshot=%d restored=%d attempt=%d",
                                targetPID,
                                target.hasFocusedWindowSnapshot ? 1 : 0,
                                target.hasFocusedElementSnapshot ? 1 : 0,
                                restored ? 1 : 0,
                                focusAttempt + 1
                            )
                            postCommandV()
                            return
                        }
                        try? await Task.sleep(nanoseconds: focusRestorePollNanoseconds)
                        guard !Task.isCancelled else { return }
                    }
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
            let restored = target.restoreFocus()
            NSLog("[Index][ClipboardPaste] post directed commandV targetPID=%d", targetPID)
            NSLog("[Index][ClipboardPaste] directed focus restored=%d", restored ? 1 : 0)
            postCommandV(to: targetPID)
        }
    }

    /// 面板原本就在 Index 内打开时，没有外部 PID 可恢复；给 key window 一轮布局时间。
    static func pasteIntoCurrentAppAfterFocusRestores() {
        guard requestEventPostingAccessIfNeeded() else { return }
        Task {
            try? await Task.sleep(nanoseconds: focusSettleNanoseconds)
            guard !Task.isCancelled else { return }
            postCommandV()
        }
    }

    private static func postCommandV(to targetPID: pid_t? = nil) {
        guard hasEventPostingAccess else {
            NSLog("[Index][ClipboardPaste] commandV cancelled: post-event access was revoked")
            return
        }
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
