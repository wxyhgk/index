import AppKit

/// Option+Space 全局搜索面板的窗口壳。
///
/// 内容（`SearchPanelView` + ViewModel）由 UI 层的 coordinator 注入；
/// 这里只管窗口、定位、上屏与事件监听，不再 import SwiftUI。
@MainActor
final class SearchPanel: FloatingPanel {

    /// 面板关闭后通知 coordinator 释放引用。
    var onClose: (() -> Void)?
    /// 返回 nil 表示消费掉键盘事件。
    var onKeyDown: ((NSEvent) -> NSEvent?)?
    /// 点击面板外。
    var onClickOutside: (() -> Void)?

    private let monitors = PanelEventMonitors()

    func show() {
        // Spotlight 风格：屏幕正中间。
        if let screen = NSScreen.main {
            let size = frame.size
            setFrameOrigin(NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2
            ))
        }
        presentWithoutActivating()

        monitors.installLocalKey { [weak self] event in
            guard let self else { return event }
            return self.onKeyDown?(event) ?? event
        }
        monitors.installGlobalClick { [weak self] in
            guard let self, self.isVisible else { return }
            // 鼠标在面板内就不关：NSApp 激活是异步的，点击可能先被路由给别的 App。
            guard !self.frame.contains(NSEvent.mouseLocation) else { return }
            self.onClickOutside?()
        }
    }

    override func close() {
        monitors.removeAll()
        orderOut(nil)
        onClose?()
    }
}
