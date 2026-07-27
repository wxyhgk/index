import SwiftUI
import AppKit

/// 编辑器画布的滚动 / 平移状态桥。
/// SwiftUI 的 ScrollView 做不了程序化偏移，抓手平移和锚点缩放都需要
/// 直接摸 NSClipView 的 bounds origin —— 本类持一根弱引用把命令递过去。
/// 坐标一律用「内容左上原点、Y 向下」表述（与 SwiftUI / 图层坐标一致），
/// 是否翻转由 `CanvasScrollNSView` 的存取器按 documentView.isFlipped 换算。
@MainActor
final class CanvasPanBox {

    fileprivate(set) weak var scrollView: CanvasScrollNSView?

    /// 缩放后的期望滚动原点（左上系）。由 EditorView 的锚点缩放写入，
    /// 滚动容器在内容尺寸更新后的下一次 update 消费并钳到合法范围。
    var pendingOrigin: CGPoint?

    var viewportSize: CGSize { scrollView?.contentView.bounds.size ?? .zero }

    /// 当前滚动原点（左上系）。
    var scrollOrigin: CGPoint { scrollView?.topLeftOrigin ?? .zero }

    /// 抓手平移：按增量挪滚动原点，越界自动钳制。
    func scrollBy(dx: CGFloat, dy: CGFloat) {
        guard let scrollView else { return }
        var origin = scrollView.topLeftOrigin
        origin.x += dx
        origin.y += dy
        scrollView.scroll(toTopLeftOrigin: origin)
    }
}

/// 编辑器画布的滚动容器（NSScrollView）。替代 SwiftUI ScrollView 的理由：
/// 抓手平移和锚点缩放都要程序化改 clipView 的 bounds origin，
/// ⌃滚轮 / 捏合要在事件层拦截且拿到光标位置做锚点 —— 两者 SwiftUI 都给不了。
/// 缩放本身**不用** NSScrollView 的 magnification（allowsMagnification = false）：
/// 倍率仍由 zoomLevel 状态驱动画布布局尺寸，fittedRect/imagePoint 的
/// 坐标公式不变量原样保留（`.offset` 不动布局 frame，两态同一条落点公式）。
struct EditorCanvasScrollView<Content: View>: NSViewRepresentable {

    /// 滚动内容的布局尺寸（缩放态 = 画布 + 留白且不小于视口；适应态 = 视口）。
    let contentSize: CGSize
    let panBox: CanvasPanBox
    /// ⌃滚轮 / 捏合：(倍率因子, 光标在内容坐标, 光标在视口坐标)。
    let onZoom: (Double, CGPoint, CGPoint) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> CanvasScrollNSView {
        let scroll = CanvasScrollNSView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = false
        let host = NSHostingView(rootView: content())
        // 尺寸完全由 contentSize 驱动（内容已显式 .frame），不让 SwiftUI 反向撑。
        host.sizingOptions = []
        scroll.documentView = host
        return scroll
    }

    func updateNSView(_ scroll: CanvasScrollNSView, context: Context) {
        panBox.scrollView = scroll
        scroll.onZoom = onZoom
        if let host = scroll.documentView as? NSHostingView<Content> {
            host.rootView = content()
        }
        if let doc = scroll.documentView, doc.frame.size != contentSize {
            doc.setFrameSize(contentSize)
        }
        if let origin = panBox.pendingOrigin {
            panBox.pendingOrigin = nil
            scroll.scroll(toTopLeftOrigin: origin)
        }
    }
}

/// 拦 ⌃滚轮和捏合做缩放（回调出去，由 EditorView 改 zoomLevel 状态），
/// 其余滚轮走原生滚动（平移）。滚轮 / 捏合事件天然只派发给光标下的视图 ——
/// 「图库窗口是 key + 在编辑模式 + 光标在画布区」由 AppKit 路由免费保证；
/// 图库网格（非编辑态）没有本视图，⌃滚轮不受任何影响。
final class CanvasScrollNSView: NSScrollView {

    var onZoom: ((Double, CGPoint, CGPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.scrollWheel(with: event)
            return
        }
        // 鼠标滚轮的行级 delta 比触控板的精确 delta 小一个量级，放大些。
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 5
        sendZoom(factor: 1 + delta * 0.01, event: event)
    }

    override func magnify(with event: NSEvent) {
        sendZoom(factor: 1 + event.magnification, event: event)
    }

    private func sendZoom(factor: CGFloat, event: NSEvent) {
        guard let doc = documentView else { return }
        // 单次事件的因子钳一下：猛滚一格不至于直接翻倍，更不会变成负数。
        let clamped = min(max(factor, 0.5), 2)
        guard clamped != 1 else { return }
        var point = doc.convert(event.locationInWindow, from: nil)
        if !doc.isFlipped { point.y = doc.bounds.height - point.y }
        let origin = topLeftOrigin
        onZoom?(
            Double(clamped),
            point,
            CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        )
    }

    /// 滚动原点，统一为「内容左上系」；documentView 未翻转时换算。
    var topLeftOrigin: CGPoint {
        guard let doc = documentView else { return .zero }
        let o = contentView.bounds.origin
        if doc.isFlipped { return o }
        return CGPoint(
            x: o.x,
            y: doc.frame.height - contentView.bounds.height - o.y
        )
    }

    /// 滚到指定左上系原点，自动钳到内容范围内。
    func scroll(toTopLeftOrigin origin: CGPoint) {
        guard let doc = documentView else { return }
        let clip = contentView
        let x = min(max(origin.x, 0), max(0, doc.frame.width - clip.bounds.width))
        let y = min(max(origin.y, 0), max(0, doc.frame.height - clip.bounds.height))
        let native = doc.isFlipped
            ? CGPoint(x: x, y: y)
            : CGPoint(x: x, y: doc.frame.height - clip.bounds.height - y)
        clip.setBoundsOrigin(native)
        reflectScrolledClipView(clip)
    }
}

/// 按住空格临时抓手（Photoshop / Figma 惯例）的按键监视器。
/// SwiftUI 的 keyboardShortcut 只有「按下」没有「松开」，按住语义只能走
/// NSEvent local monitor（keyDown/keyUp，keyCode 49）。让位逻辑对齐
/// GalleryKeyboard：图库窗口不是 key / 有 sheet / 不在编辑模式一概放行；
/// 文本输入中（NSTextView 是首响应者，含右侧文字框）一个键都不抢。
@MainActor
final class EditorSpaceHandMonitor: ObservableObject {

    /// 空格当前是否按住。抓手是否真正生效由 EditorView 再叠加
    /// 「缩放态才有可平移空间」的条件。
    @Published private(set) var spaceHeld = false

    private var monitor: Any?

    /// 由 EditorView 在 onAppear 装、onDisappear 拆（换图重建视图时
    /// 新旧实例各管各的 monitor，互不干扰）。重复调用无害。
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak self] event in
            guard let self else { return event }
            // 只把值类型带进 assumeIsolated，避免非 Sendable 的 NSEvent 跨隔离告警。
            let keyCode = event.keyCode
            let isDown = event.type == .keyDown
            let isRepeat = isDown && event.isARepeat
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let handled = MainActor.assumeIsolated {
                self.handle(keyCode: keyCode, isDown: isDown, isRepeat: isRepeat, flags: flags)
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        spaceHeld = false
    }

    private func handle(
        keyCode: UInt16, isDown: Bool, isRepeat: Bool, flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard keyCode == KeyCode.space else { return false }

        guard let window = GalleryWindowController.shared.window,
              NSApp.keyWindow === window,
              window.attachedSheet == nil,
              GallerySelection.shared.editingShot != nil,
              !(window.firstResponder is NSTextView)
        else {
            // 按住途中条件变了（焦点进了文字框 / 弹了 sheet）：松手复位，
            // 但事件本身放行，别把别处的空格吞了。
            if !isDown, spaceHeld { spaceHeld = false }
            return false
        }

        if isDown {
            guard flags.isEmpty else { return false }
            if !isRepeat { spaceHeld = true }
            // 重复按键也吞掉，空格不该在编辑模式下触发任何滚动。
            return true
        }
        guard spaceHeld else { return false }
        spaceHeld = false
        return true
    }
}
