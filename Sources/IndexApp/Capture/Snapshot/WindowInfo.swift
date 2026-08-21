import CoreGraphics

struct WindowInfo {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String?
    let ownerName: String?
    let frame: CGRect
    let layer: Int
}

enum WindowLister {
    @MainActor
    static func onScreenWindows(excludingPID excluded: pid_t) -> [WindowInfo] {
        MacWindowLister.shared.onScreenWindows(excludingPID: excluded)
    }
    @MainActor
    static func frontmostWindow(at point: CGPoint, excludingPID excluded: pid_t) -> WindowInfo? {
        MacWindowLister.shared.frontmostWindow(at: point, excludingPID: excluded)
    }
    @MainActor
    static func bestMatch(for region: CGRect, excludingPID excluded: pid_t) -> WindowInfo? {
        MacWindowLister.shared.bestMatch(for: region, excludingPID: excluded)
    }
}
