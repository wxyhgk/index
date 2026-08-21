import AppKit

/// 自绘工具栏区域的静态 tooltip owner。
///
/// `NSView.addToolTip` 不负责延长 owner 的生命周期；不能把循环里的临时 String
/// 直接传进去。宿主按 tag 强持有本对象，并在移除 tooltip 时一并释放。
@MainActor
final class ToolbarToolTipOwner: NSObject, NSViewToolTipOwner {

    let label: String

    init(_ label: String) {
        self.label = label
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        label
    }
}
