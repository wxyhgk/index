import AppKit
import CoreGraphics

@MainActor
final class MacWindowLister: WindowListing {

    static let shared = MacWindowLister()

    func onScreenWindows(excludingPID pid: pid_t) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap { dict -> WindowInfo? in
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                  let wPid = dict[kCGWindowOwnerPID as String] as? pid_t, wPid != pid,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  cgRect.width > 20, cgRect.height > 20 else { return nil }
            return WindowInfo(windowID: (dict[kCGWindowNumber as String] as? CGWindowID) ?? 0, pid: wPid, title: dict[kCGWindowName as String] as? String, ownerName: dict[kCGWindowOwnerName as String] as? String, frame: Geometry.coreGraphicsToAppKit(cgRect), layer: layer)
        }
    }

    func frontmostWindow(at point: CGPoint, excludingPID pid: pid_t) -> WindowInfo? {
        onScreenWindows(excludingPID: pid).first { $0.frame.contains(point) }
    }

    func bestMatch(for region: CGRect, excludingPID pid: pid_t) -> WindowInfo? {
        let windows = onScreenWindows(excludingPID: pid)
        let center = CGPoint(x: region.midX, y: region.midY)
        if let hit = windows.first(where: { $0.frame.contains(center) }) { return hit }
        return windows.first { $0.frame.intersects(region) }
    }
}
