import AppKit

/// 浮动面板基类：把 `PanelSpec` 应用到窗口，并提供统一的上屏方式。
///
/// 只负责窗口本身；内容、键盘语义、定位仍由各面板决定。这样平台副作用
/// （窗口创建、层级、Space 行为）有了唯一入口，而业务逻辑不必搬进 Platform。
@MainActor
class FloatingPanel: NSPanel {

    let spec: PanelSpec

    init(spec: PanelSpec, contentViewController: NSViewController) {
        self.spec = spec
        super.init(
            contentRect: NSRect(origin: .zero, size: spec.initialSize),
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        apply(spec)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { spec.canBecomeKey }
    override var canBecomeMain: Bool { spec.canBecomeMain }

    /// 不激活整个 App（避免台前调度把图库等窗口一起带出来），
    /// 但拿键盘焦点。四个面板的 `show()` 此前各写一遍这两行。
    func presentWithoutActivating() {
        orderFrontRegardless()
        makeKey()
    }

    private func apply(_ spec: PanelSpec) {
        isFloatingPanel = spec.isFloatingPanel
        level = spec.level
        collectionBehavior = spec.collectionBehavior
        isOpaque = spec.isOpaque
        if let color = spec.backgroundColor {
            backgroundColor = color
        }
        hasShadow = spec.hasShadow
        isMovable = spec.isMovable
        isMovableByWindowBackground = spec.isMovableByWindowBackground
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = spec.becomesKeyOnlyIfNeeded

        if let title = spec.title {
            self.title = title
        }
        titlebarAppearsTransparent = spec.titlebarAppearsTransparent
        titleVisibility = spec.titleVisibility
        if spec.hidesStandardButtons {
            standardWindowButton(.closeButton)?.isHidden = true
            standardWindowButton(.miniaturizeButton)?.isHidden = true
            standardWindowButton(.zoomButton)?.isHidden = true
        }
        if spec.detachesFromAppStage {
            PanelPlacement.detachFromAppStage(self)
        }
        if let radius = spec.contentCornerRadius, let content = contentView {
            content.wantsLayer = true
            content.layer?.cornerRadius = radius
            content.layer?.masksToBounds = true
        }
    }
}
