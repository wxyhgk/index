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

    /// 下一次 update 时把视口滚到内容中心（钳制后）。适应窗口态的内容是
    /// 3× 视口、图片居中 —— 进入该态（首次加载 / ⌘0 回到适应）时置位，
    /// 让图片落在视口正中而不是内容左上角。
    /// 初始 true：编辑器首次打开就是适应态，首次 update 即居中。
    var centerOnNextUpdate = true

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

    /// 点（窗口坐标）是否落在滚动视图可视区内。
    /// 中键平移用它判断「这次中键按下是否在画布上」—— 画布外的中键
    /// （右侧检查器、工具栏）不触发平移，事件照常放行。
    func containsWindowPoint(_ windowPoint: CGPoint) -> Bool {
        guard let scrollView else { return false }
        // convert(from: nil) 得到的是视图**自身**坐标，必须和 bounds 比；
        // frame 是 superview 坐标，混用会在视图有偏移时判错。
        return scrollView.bounds.contains(scrollView.convert(windowPoint, from: nil))
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
        if panBox.centerOnNextUpdate {
            panBox.centerOnNextUpdate = false
            // 滚到内容中心：适应态内容 3× 视口、图片在内容正中，
            // 这样图片落在视口正中，且四周各有一个视口的平移余量。
            // 延迟到当前布局 pass 之后，并用**执行时刻**的实时文档 frame /
            // clip bounds 计算 —— 首次 update 时窗口还在创建，捕获的
            // contentSize 与 clip bounds 都还不是最终尺寸（非翻转文档的
            // y 换算依赖 clip 高度，用旧值算出的原点会偏半个视口）。
            DispatchQueue.main.async {
                guard let doc = scroll.documentView, doc.frame.width > 0 else { return }
                let clip = scroll.contentView.bounds.size
                scroll.scroll(toTopLeftOrigin: CGPoint(
                    x: (doc.frame.width - clip.width) / 2,
                    y: (doc.frame.height - clip.height) / 2
                ))
            }
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
/// NSEvent local monitor（keyDown/keyUp，keyCode 49）。让位判定与
/// GalleryKeyboard **共用** `GalleryKeyContext`：图库窗口不是 key /
/// 有 sheet 或模态 / 文本输入焦点（含右侧文字框）/ 不在编辑模式一概放行。
@MainActor
final class EditorSpaceHandMonitor: ObservableObject {

    /// 空格当前是否按住。抓手是否真正生效由 EditorView 再叠加
    /// 「缩放态才有可平移空间」的条件。
    @Published private(set) var spaceHeld = false

    private var monitor: Any?
    /// 窗口失去 key 的观察者：⌘Tab 切走时 keyUp 会发给别的 App，
    /// 只靠 keyUp 复位会让 spaceHeld 卡在按住态。
    private var resignKeyObserver: NSObjectProtocol?

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
        // 按住空格时 ⌘Tab 切走（或任何原因失去 key）：keyUp 收不到，主动复位。
        // EditorView 订阅着 spaceHeld，复位会顺带清掉平移中的抓手状态与光标。
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.spaceHeld,
                      GalleryKeyContext.current() != .editor else { return }
                self.spaceHeld = false
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        resignKeyObserver = nil
        spaceHeld = false
    }

    private func handle(
        keyCode: UInt16, isDown: Bool, isRepeat: Bool, flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard keyCode == KeyCode.space else { return false }

        guard GalleryKeyContext.current() == .editor else {
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

/// 中键拖拽平移画布（Photoshop / Figma / 浏览器惯例）。
///
/// 中键事件会被 NSHostingView 吞掉、SwiftUI 手势默认不响应中键，
/// 所以走 NSEvent local monitor：中键按下且落在画布区 → 进入平移，
/// 拖动按窗口坐标增量挪滚动原点（与空格抓手同一套坐标公式），
/// 松开结束。画布外的中键（右侧检查器、工具栏）不触发，事件放行。
@MainActor
final class EditorMiddlePanMonitor: ObservableObject {

    /// 平移命令：按增量挪滚动原点。由 EditorView 注入 `model.panBox.scrollBy`。
    var scrollBy: ((CGFloat, CGFloat) -> Void)?
    /// 点（窗口坐标）是否在画布可视区。由 EditorView 注入 `model.panBox.containsWindowPoint`。
    var isOverCanvas: ((CGPoint) -> Bool)?

    private var monitor: Any?
    private var lastWindowLocation: CGPoint?
    /// 窗口失去 key 的观察者：⌘Tab 切走时中键松开事件会发给别的 App，
    /// 只靠 mouseUp 复位会让平移状态卡住。
    private var resignKeyObserver: NSObjectProtocol?

    /// 由 EditorView 在 onAppear 装、onDisappear 拆。重复调用无害。
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            // 只把值类型带进 assumeIsolated，避免非 Sendable 的 NSEvent 跨隔离告警。
            let type = event.type
            let location = event.locationInWindow
            let handled = MainActor.assumeIsolated {
                self.handle(type: type, location: location)
            }
            return handled ? nil : event
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lastWindowLocation != nil,
                      GalleryKeyContext.current() != .editor else { return }
                self.lastWindowLocation = nil
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        resignKeyObserver = nil
        lastWindowLocation = nil
    }

    /// 返回 true = 已接管（监视器吞掉事件），false = 放行。
    private func handle(type: NSEvent.EventType, location: CGPoint) -> Bool {
        switch type {
        case .otherMouseDown:
            // 只在编辑模式 + 画布上 + 无修饰键时接管中键按下。
            guard GalleryKeyContext.current() == .editor,
                  isOverCanvas?(location) == true,
                  lastWindowLocation == nil else { return false }
            lastWindowLocation = location
            NSCursor.openHand.set()
            return true
        case .otherMouseDragged:
            guard let last = lastWindowLocation else { return false }
            // 平移时内容在光标下滑动，窗口坐标是唯一稳定参照。
            // 注意：NSEvent.locationInWindow 是 AppKit 窗口坐标（y 向上），
            // 与空格抓手用的 SwiftUI DragGesture 全局坐标（y 向下）方向相反 ——
            // x 分量公式相同，y 分量必须反过来，否则垂直方向平移是反的。
            scrollBy?(last.x - location.x, location.y - last.y)
            lastWindowLocation = location
            NSCursor.closedHand.set()
            return true
        case .otherMouseUp:
            guard lastWindowLocation != nil else { return false }
            lastWindowLocation = nil
            NSCursor.arrow.set()
            return true
        default:
            return false
        }
    }
}
