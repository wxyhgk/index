import AppKit
import ApplicationServices

/// 剪贴板弹窗出现前的粘贴目标快照。
///
/// `NSRunningApplication.activate` 只能恢复应用，不能保证回到原窗口里的原输入框。
/// 因此在 non-activating panel 抢走 key window 之前，同时保留 AX focused window 与
/// focused UI element；粘贴前按“应用 → 窗口 → 控件”的顺序恢复。
@MainActor
final class ClipboardPasteTarget {
    let application: NSRunningApplication

    private let applicationElement: AXUIElement
    private let focusedWindow: AXUIElement?
    private let focusedElement: AXUIElement?

    var processIdentifier: pid_t { application.processIdentifier }
    var hasFocusedWindowSnapshot: Bool { focusedWindow != nil }
    var hasFocusedElementSnapshot: Bool { focusedElement != nil }
    var hasRestorableFocusSnapshot: Bool {
        focusedWindow != nil || focusedElement != nil
    }

    private init(
        application: NSRunningApplication,
        applicationElement: AXUIElement,
        focusedWindow: AXUIElement?,
        focusedElement: AXUIElement?
    ) {
        self.application = application
        self.applicationElement = applicationElement
        self.focusedWindow = focusedWindow
        self.focusedElement = focusedElement
    }

    static func capture(application: NSRunningApplication) -> ClipboardPasteTarget {
        let pid = application.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let window = elementAttribute(appElement, kAXFocusedWindowAttribute)
        let systemFocusedElement = elementAttribute(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute
        )
        let element = systemFocusedElement.flatMap { candidate -> AXUIElement? in
            var candidatePID: pid_t = 0
            guard AXUIElementGetPid(candidate, &candidatePID) == .success,
                  candidatePID == pid
            else { return nil }
            return candidate
        }
        NSLog(
            "[Index][ClipboardPaste] focus capture trusted=%d postEvent=%d window=%d element=%d",
            AXIsProcessTrusted() ? 1 : 0,
            CGPreflightPostEventAccess() ? 1 : 0,
            window == nil ? 0 : 1,
            element == nil ? 0 : 1
        )
        return ClipboardPasteTarget(
            application: application,
            applicationElement: appElement,
            focusedWindow: window,
            focusedElement: element
        )
    }

    /// 返回能够取得的最精确焦点是否已经恢复：有控件就核对控件，只有窗口
    /// 就核对窗口。QQ / XTerminal 等应用可能不公开 focused UI element，但仍
    /// 可以可靠恢复 focused window，不能因此退回固定数百毫秒等待。
    func restoreFocus() -> Bool {
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        var didRestoreWindow = focusedWindow == nil
        if let focusedWindow {
            _ = AXUIElementSetAttributeValue(
                applicationElement,
                kAXFocusedWindowAttribute as CFString,
                focusedWindow
            )
            _ = AXUIElementSetAttributeValue(
                focusedWindow,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            if let currentWindow = Self.elementAttribute(
                applicationElement,
                kAXFocusedWindowAttribute
            ) {
                didRestoreWindow = CFEqual(currentWindow, focusedWindow)
            }
        }
        guard let focusedElement else { return didRestoreWindow }
        _ = AXUIElementSetAttributeValue(
            focusedElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard let current = Self.elementAttribute(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute
        ) else { return false }
        return CFEqual(current, focusedElement)
    }

    private static func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}

enum ClipboardPasteFocusRestorationPolicy {
    static let maximumAttemptCount = 12

    static func shouldPostCommandV(
        hasFocusSnapshot: Bool,
        isFocusRestored: Bool,
        attempt: Int
    ) -> Bool {
        !hasFocusSnapshot
            || isFocusRestored
            || attempt >= maximumAttemptCount - 1
    }
}
