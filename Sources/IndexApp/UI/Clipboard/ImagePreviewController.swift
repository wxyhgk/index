import AppKit

// MARK: - 图片 hover 大图预览
//
// 独立 NSWindow 浮出，可以超出面板边界。
// 鼠标悬停 400ms 后显示，离开即消失。

@MainActor
final class ImagePreviewController {
    static let shared = ImagePreviewController()

    private var window: NSWindow?
    private var imageView: NSImageView?
    private var showTask: Task<Void, Never>?

    func scheduleShow(image: NSImage, screenPoint: NSPoint) {
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.show(image: image, near: screenPoint)
        }
    }

    /// 立即显示（空格键触发，不走延迟）。
    func showNow(image: NSImage, screenPoint: NSPoint) {
        showTask?.cancel()
        showTask = nil
        show(image: image, near: screenPoint)
    }

    func cancel() {
        showTask?.cancel()
        showTask = nil
        window?.orderOut(nil)
    }

    private func show(image: NSImage, near point: NSPoint) {
        let maxDim: CGFloat = 420
        let scale = min(1, maxDim / max(image.size.width, image.size.height))
        let w = image.size.width * scale
        let h = image.size.height * scale

        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.level = .floating
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = true
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 10
            iv.layer?.masksToBounds = true
            iv.layer?.borderWidth = 1
            iv.layer?.borderColor = NSColor.separatorColor.cgColor
            win.contentView = iv
            window = win
            imageView = iv
        }

        window?.setContentSize(NSSize(width: w, height: h))
        imageView?.image = image

        // 位置：鼠标上方居中
        let x = point.x - w / 2
        let y = point.y + 8
        window?.setFrameOrigin(NSPoint(x: x, y: y))
        window?.orderFront(nil)
    }
}
