import AppKit
import SwiftUI

// MARK: - 可缩放图片视图（AppKit）
//
// 滚轮缩放（以鼠标位置为中心，0.2x–8x）+ 拖拽平移 + 双击重置。
// 切换图片时自动重置缩放和偏移。

final class ZoomableImageView: NSView {
    var image: NSImage? {
        didSet { resetZoom() }
    }

    private var scale: CGFloat = 1.0
    private var offset: NSPoint = .zero
    private var isPanning = false
    private var lastPanPoint: NSPoint = .zero

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSColor.clear.set()
        dirtyRect.fill()

        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }

        let fitScale = min(bounds.width / imgSize.width, bounds.height / imgSize.height, 1.0)
        let drawSize = NSSize(width: imgSize.width * fitScale, height: imgSize.height * fitScale)
        let drawOrigin = NSPoint(
            x: (bounds.width - drawSize.width) / 2 + offset.x,
            y: (bounds.height - drawSize.height) / 2 + offset.y
        )

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.midX, y: -bounds.midY)
        image.draw(in: NSRect(origin: drawOrigin, size: drawSize))
        ctx.restoreGState()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let factor: CGFloat = delta > 0 ? 1.08 : 1.0 / 1.08
        let newScale = min(max(scale * factor, 0.2), 8.0)
        guard newScale != scale else { return }

        let mousePoint = convert(event.locationInWindow, from: nil)
        let cx = bounds.midX
        let cy = bounds.midY
        let ratio = newScale / scale
        offset.x = (mousePoint.x - cx) - (mousePoint.x - cx - offset.x) * ratio
        offset.y = (mousePoint.y - cy) - (mousePoint.y - cy - offset.y) * ratio

        scale = newScale
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetZoom()
            return
        }
        guard scale > 1.01 else { return }
        isPanning = true
        lastPanPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning else { return }
        let current = convert(event.locationInWindow, from: nil)
        offset.x += current.x - lastPanPoint.x
        offset.y += current.y - lastPanPoint.y
        lastPanPoint = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isPanning = false
    }

    func resetZoom() {
        scale = 1.0
        offset = .zero
        needsDisplay = true
    }
}

// MARK: - 图片放大弹窗
//
// 独立无边框窗口，显示原图，支持滚轮缩放 + 拖拽平移 + 双击重置 + Esc 关闭。
// 窗口大小 = 屏幕 80%，居中。

@MainActor
final class SearchImagePreviewWindow {
    static let shared = SearchImagePreviewWindow()

    private var window: NSWindow?
    private var zoomView: ZoomableImageView?
    private var localMonitor: Any?

    func show(image: NSImage, originalURL: URL?) {
        // 如果有原图 URL，加载原图（更清晰）
        let displayImage: NSImage
        if let url = originalURL, let original = NSImage(contentsOf: url) {
            displayImage = original
        } else {
            displayImage = image
        }

        if window == nil {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let size = NSSize(width: screen.width * 0.8, height: screen.height * 0.8)
            let origin = NSPoint(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2
            )
            let win = NSWindow(
                contentRect: NSRect(origin: origin, size: size),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "图片预览"
            win.isReleasedWhenClosed = false
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.backgroundColor = .windowBackgroundColor

            let zv = ZoomableImageView(frame: NSRect(origin: .zero, size: size))
            zv.wantsLayer = true
            zv.image = displayImage
            win.contentView = zv
            win.contentMinSize = NSSize(width: 400, height: 300)

            window = win
            zoomView = zv
        }

        zoomView?.image = displayImage
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMonitor()
    }

    func close() {
        removeMonitor()
        window?.orderOut(nil)
    }

    private func installMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.close()
                return nil
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        localMonitor = nil
    }
}
