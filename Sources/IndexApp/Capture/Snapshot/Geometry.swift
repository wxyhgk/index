import AppKit
import CoreGraphics

/// macOS 上同时存在两套坐标系，混用是这类项目最常见的 bug 源，这里显式隔离。
///
/// - AppKit 全局坐标：原点在主屏左下角，Y 向上。NSScreen.frame / NSEvent 用这个。
/// - CoreGraphics 全局坐标：原点在主屏左上角，Y 向下。CGWindowListCopyWindowInfo 用这个。
/// - 显示器局部坐标：原点在该显示器左上角，Y 向下。ScreenCaptureKit 的 sourceRect 用这个。
enum Geometry {

    /// 主屏（带菜单栏的那块）在 AppKit 坐标里的顶边 Y 值。
    static var primaryTopY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func appKitToCoreGraphics(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryTopY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func coreGraphicsToAppKit(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryTopY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// AppKit 全局矩形 → 指定显示器的局部左上原点矩形（点，非像素）。
    static func displayLocalRect(globalAppKit rect: CGRect, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(
            x: rect.origin.x - f.origin.x,
            y: f.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}
