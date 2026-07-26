import AppKit
import ScreenCaptureKit

/// 滚动截图编排：框选滚动区域 → 用户在目标窗口里手动滚动，
/// 我们每 300ms 采集该屏幕区域并交给 `ScrollStitcher` 自动拼接 →
/// 完成后作为一张普通截图入库并打开编辑器（长图上标注比钉图实用）。
///
/// 产物是「一张不绑定显示器的长图」，不走选区工具条 / CaptureAction 管线：
/// 框选用覆盖层的简单模式（松手即返回选区），之后的采集、拼接、入库都在这里。
@MainActor
final class ScrollCaptureController {

    static let shared = ScrollCaptureController()

    /// 与普通截图各用各的覆盖层实例，互不干扰。
    private let overlay = SelectionOverlayController()
    private var session: ScrollCaptureSession?

    /// 采集期间临时监听 ⎋ 用的绑定名（参考延时截图的 bindTransient 用法）。
    private static let cancelHotKeyName = "cancel-scroll-capture"

    private init() {}

    /// 菜单 / 快捷键入口。采集进行中再按一次快捷键 = 完成（⎋ = 取消）。
    func begin() {
        if let session {
            session.finish()
            return
        }
        guard !overlay.isActive else { return }

        guard ScreenRecordingPermission.isGranted else {
            CaptureCoordinator.shared.requestPermissionThenPrompt()
            return
        }
        guard let source = CaptureSourceRegistry.shared.source(id: CaptureSourceID.immediate) else {
            return
        }

        Task {
            do {
                // 复用现有冻结选区：先定格全部屏幕，再让用户框选滚动区域。
                let snapshots = try await source.makeSnapshots()

                // 覆盖层拿到焦点前记下前台 App —— 之后 frontmostApplication 就是我们自己了。
                let previousApp = SystemNavigator.frontmostApplication
                let windowList = WindowLister.onScreenWindows(
                    excludingPID: ProcessInfo.processInfo.processIdentifier
                )

                // finishOnConfirm：松手即返回选区，不出工具条。这里只要 region + display。
                overlay.begin(
                    snapshots: snapshots,
                    windowList: windowList,
                    finishOnConfirm: true
                ) { [weak self] result in
                    guard let self, let result else { return }
                    self.startSession(with: result, previousApp: previousApp)
                }
            } catch {
                NSLog("[MacShot] 滚动截图准备失败: \(error)")
            }
        }
    }

    // MARK: - 采集会话

    private func startSession(with result: SelectionResult, previousApp: NSRunningApplication?) {
        let session = ScrollCaptureSession(region: result.region, display: result.display)
        self.session = session

        session.onFinished = { [weak self] image in
            guard let self else { return }
            GlobalHotKeyCenter.shared.unbind(Self.cancelHotKeyName)
            self.session = nil
            guard let image else { return }   // 取消，或一帧都没采到
            self.deliver(image: image, result: result, previousApp: previousApp)
        }

        // ⎋ 全程可取消。裸键绑定只在采集窗口期存在，会话一结束立即注销。
        GlobalHotKeyCenter.shared.bindTransient(
            Self.cancelHotKeyName,
            to: KeyboardShortcut(keyCode: 53, modifiers: 0)   // ⎋
        ) { [weak session] in
            session?.cancel()
        }

        session.start()
    }

    /// 拼接结果走既有入库路径：save + 派生流水线，region 记初始选区。
    private func deliver(image: CGImage, result: SelectionResult, previousApp: NSRunningApplication?) {
        let metadata = MetadataCollector.collect(
            region: result.region,
            display: result.display,
            window: result.window,
            fallbackApp: previousApp
        )

        do {
            let shot = try ShotStore.shared.save(image: image, metadata: metadata)

            if let id = shot.id {
                CapturePipeline.shared.run(PostProcessInput(
                    shotID: id,
                    image: image,
                    appBundleID: metadata.appBundleID
                ))
            }

            // 长图直接开编辑器 —— 入库 + 标注比钉一整条长图实用。
            GalleryWindowController.shared.show(selecting: shot)
            GallerySelection.shared.editing = shot
        } catch {
            NSLog("[MacShot] 滚动截图保存失败: \(error)")
        }
    }
}

// MARK: - 会话：定时采集 + 拼接 + 控制条

/// 一次滚动采集的生命周期：屏幕上留一个选区边框和一个小控制条，
/// 300ms 采一帧交给拼接器，直到用户点「完成」/ 再按快捷键 / ⎋ / 触顶 30000px。
@MainActor
private final class ScrollCaptureSession {

    /// 完成回调。nil = 取消（或一帧都没采到），丢弃。
    var onFinished: ((CGImage?) -> Void)?

    private let region: CGRect
    private let display: DisplayInfo

    private var stitcher = ScrollStitcher()
    private var loop: Task<Void, Never>?
    private let panel = ScrollControlPanel()
    private let border = RegionBorderPanel()
    private var finished = false

    private static let captureInterval: UInt64 = 300_000_000   // 300ms

    init(region: CGRect, display: DisplayInfo) {
        self.region = region
        self.display = display
    }

    func start() {
        border.show(around: region)
        panel.onFinish = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.show(near: region, on: display)
        panel.update(height: 0)

        loop = Task { [weak self] in
            guard let self else { return }
            do {
                let grabber = try await ScrollFrameGrabber(
                    region: self.region,
                    display: self.display
                )
                while !Task.isCancelled {
                    let image = try await grabber.grab()
                    guard !Task.isCancelled, !self.finished else { break }
                    self.ingest(image)
                    try await Task.sleep(nanoseconds: Self.captureInterval)
                }
            } catch is CancellationError {
                // finish / cancel 主动打断，静默。
            } catch {
                NSLog("[MacShot] 滚动采集失败: \(error)")
                self.cancel()
            }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        loop?.cancel()
        stitcher.finalize()
        let image = stitcher.makeImage()
        dismissUI()
        onFinished?(image)
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        loop?.cancel()
        dismissUI()
        onFinished?(nil)
    }

    private func ingest(_ image: CGImage) {
        guard let frame = ScrollFrame(cgImage: image) else { return }
        switch stitcher.append(frame) {
        case .seeded, .appended:
            panel.update(height: stitcher.height)
        case .unchanged:
            break
        case .noOverlap:
            panel.flash("滚慢一点，等画面接上再继续")
        case .limitReached:
            panel.update(height: stitcher.height)
            finish()
        }
    }

    private func dismissUI() {
        panel.dismiss()
        border.dismiss()
    }
}

// MARK: - 帧采集

/// 用 ScreenCaptureKit 反复截取屏幕上的一个固定区域。
/// SCShareableContent 只查一次；SCContentFilter 排除自身进程 ——
/// 我们的边框和控制条即使压在选区上也不会被拍进去。
@MainActor
private final class ScrollFrameGrabber {

    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration

    init(region: CGRect, display: DisplayInfo) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw CaptureError.noDisplays
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        filter = SCContentFilter(
            display: scDisplay,
            excludingApplications: content.applications.filter { $0.processID == ownPID },
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        // sourceRect 用显示器局部坐标（点，左上原点）；region 是 AppKit 全局（左下原点）。
        config.sourceRect = CGRect(
            x: region.minX - display.frame.minX,
            y: display.frame.maxY - region.maxY,
            width: region.width,
            height: region.height
        )
        config.width = Int((region.width * display.scale).rounded())
        config.height = Int((region.height * display.scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsDisplay = true
        config.colorSpaceName = CGColorSpace.sRGB
        configuration = config
    }

    func grab() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}

// MARK: - 控制条

/// 选区外侧的小控制条：已拼接高度 + 完成 / 取消，外加一行会自动复原的提示。
/// .nonactivatingPanel —— 点按钮不抢走目标窗口的焦点，用户随时能继续滚动。
@MainActor
private final class ScrollControlPanel: NSObject {

    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private var heightLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var hintResetTask: Task<Void, Never>?

    private static let defaultHint = "在目标窗口里向下慢慢滚动 · ⎋ 取消"

    func show(near region: CGRect, on display: DisplayInfo) {
        guard panel == nil else { return }

        let size = CGSize(width: 280, height: 96)
        let screen = display.frame

        // 优先放选区正下方；放不下改上方；再不行贴着选区顶部内侧。
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 12)
        if origin.y < screen.minY {
            origin.y = region.maxY + 12
            if origin.y + size.height > screen.maxY {
                origin.y = region.maxY - size.height - 12
            }
        }
        origin.x = min(max(screen.minX + 8, origin.x), screen.maxX - size.width - 8)

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
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        content.layer?.cornerRadius = 12

        let height = NSTextField(labelWithString: "已拼接 0 px")
        height.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        height.textColor = .white
        height.alignment = .center

        let hint = NSTextField(labelWithString: Self.defaultHint)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.65)
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail

        let finishButton = NSButton(title: "完成", target: self, action: #selector(finishTapped))
        finishButton.bezelStyle = .rounded
        finishButton.controlSize = .regular

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular

        let buttons = NSStackView(views: [finishButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [height, hint, buttons])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10)
        ])

        panel.contentView = content
        panel.orderFrontRegardless()

        self.panel = panel
        self.heightLabel = height
        self.hintLabel = hint
    }

    func update(height: Int) {
        heightLabel?.stringValue = "已拼接 \(height) px"
    }

    /// 短暂显示一条提示（如「滚慢一点」），1.5 秒后自动复原。
    func flash(_ text: String) {
        hintLabel?.stringValue = text
        hintResetTask?.cancel()
        hintResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.hintLabel?.stringValue = Self.defaultHint
        }
    }

    func dismiss() {
        hintResetTask?.cancel()
        hintResetTask = nil
        panel?.orderOut(nil)
        panel = nil
        heightLabel = nil
        hintLabel = nil
    }

    @objc private func finishTapped() { onFinish?() }
    @objc private func cancelTapped() { onCancel?() }
}

// MARK: - 选区边框

/// 采集期间标出滚动区域的细边框。不接受任何鼠标事件 —— 滚动要落到下面的目标窗口。
/// 自身进程被 SCContentFilter 排除，所以边框不会出现在采集到的帧里。
@MainActor
private final class RegionBorderPanel {

    private var panel: NSPanel?

    func show(around region: CGRect) {
        guard panel == nil else { return }

        let frame = region.insetBy(dx: -3, dy: -3)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = BorderView(frame: CGRect(origin: .zero, size: frame.size))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }
}
