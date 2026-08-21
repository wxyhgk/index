import AppKit

/// 「延时截图」：等待若干秒再定格屏幕，等待期间在主屏右下角显示倒计时。
///
/// 延时秒数不直接读 AppSettings（避免采集层引用 App 配置），由注册方注入闭包。
/// 取消有三条路：外层 Task 被取消（快捷键再按 / ⎋，由协调器触发）、点击倒计时面板。
/// 三条路最终都表现为抛 `CancellationError`。
@MainActor
final class DelayedScreenSource: CaptureSource {

    let id = CaptureSourceID.delayed
    let title = "延时截图"
    let symbolName = "timer"
    var isCancellableWhilePreparing: Bool { true }

    private let base: CaptureSource
    private let delaySeconds: () -> Int

    init(wrapping base: CaptureSource, delaySeconds: @escaping () -> Int) {
        self.base = base
        self.delaySeconds = delaySeconds
    }

    func makeSnapshots() async throws -> [DisplaySnapshot] {
        let total = max(1, delaySeconds())
        let hud = CountdownHUD()
        hud.show(seconds: total)
        defer { hud.dismiss() }

        // 小步睡眠而不是整秒睡：点击面板取消要在 100ms 内生效，而不是等到下一个整秒。
        let deadline = Date(timeIntervalSinceNow: Double(total))
        while true {
            if hud.isCancelled { throw CancellationError() }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            hud.update(Int(remaining.rounded(.up)))
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // 数字归零后立刻收面板，避免它出现在截下来的画面里。
        hud.dismiss()
        return try await base.makeSnapshots()
    }
}

// MARK: - 倒计时面板

/// 主屏右下角的大数字倒计时。无边框、不抢焦点（用户延时就是为了去摆弄别的窗口），
/// 级别 .screenSaver 保证盖在一切之上。点击面板 = 取消。
@MainActor
private final class CountdownHUD {

    private(set) var isCancelled = false

    private var panel: NSPanel?
    private var numberLabel: NSTextField?

    func show(seconds: Int) {
        guard panel == nil, let screen = NSScreen.main else { return }

        let size = CGSize(width: 120, height: 120)
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.maxX - size.width - 24,
            y: visible.minY + 24
        )

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false

        let content = ClickToCancelView(frame: CGRect(origin: .zero, size: size))
        content.onClick = { [weak self] in self?.isCancelled = true }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        content.layer?.cornerRadius = 18

        let number = NSTextField(labelWithString: "\(seconds)")
        number.font = .monospacedDigitSystemFont(ofSize: 56, weight: .semibold)
        number.textColor = .white
        number.alignment = .center

        let hint = NSTextField(labelWithString: "⎋ 取消")
        hint.font = .systemFont(ofSize: DS.font11)
        hint.textColor = NSColor.white.withAlphaComponent(0.6)
        hint.alignment = .center

        let stack = NSStackView(views: [number, hint])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        panel.contentView = content
        panel.orderFrontRegardless()

        self.panel = panel
        self.numberLabel = number
    }

    func update(_ remaining: Int) {
        numberLabel?.stringValue = "\(remaining)"
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        numberLabel = nil
    }
}

private final class ClickToCancelView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}
