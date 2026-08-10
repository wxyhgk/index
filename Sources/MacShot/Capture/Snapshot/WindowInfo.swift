import AppKit
import CoreGraphics

struct WindowInfo {
    let windowID: CGWindowID
    let pid: pid_t
    /// 窗口标题。需要「屏幕录制」权限才非空。
    let title: String?
    let ownerName: String?
    /// AppKit 全局坐标（左下原点）。
    let frame: CGRect
    let layer: Int
}

enum WindowLister {

    /// 屏幕上的普通窗口，front-to-back 顺序（CGWindowList 保证）。
    static func onScreenWindows(excludingPID excluded: pid_t) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return raw.compactMap { dict -> WindowInfo? in
            guard
                let layer = dict[kCGWindowLayer as String] as? Int,
                layer == 0,                                   // 只要正常层级窗口，滤掉菜单/Dock/浮层
                let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
                pid != excluded,
                let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                cgRect.width > 20, cgRect.height > 20
            else { return nil }

            return WindowInfo(
                windowID: (dict[kCGWindowNumber as String] as? CGWindowID) ?? 0,
                pid: pid,
                title: dict[kCGWindowName as String] as? String,
                ownerName: dict[kCGWindowOwnerName as String] as? String,
                frame: Geometry.coreGraphicsToAppKit(cgRect),
                layer: layer
            )
        }
    }

    /// 命中点下最靠前的窗口。
    static func frontmostWindow(at point: CGPoint, excludingPID excluded: pid_t) -> WindowInfo? {
        onScreenWindows(excludingPID: excluded).first { $0.frame.contains(point) }
    }

    /// 与选区重叠最多、且最靠前的窗口 —— 用来判断「这张图截的是哪个 App」。
    static func bestMatch(for region: CGRect, excludingPID excluded: pid_t) -> WindowInfo? {
        let windows = onScreenWindows(excludingPID: excluded)
        // front-to-back：第一个覆盖选区中心的即为可见来源。
        let center = CGPoint(x: region.midX, y: region.midY)
        if let hit = windows.first(where: { $0.frame.contains(center) }) {
            return hit
        }
        return windows.first { $0.frame.intersects(region) }
    }
}
