import AppKit
import CoreMedia
import ScreenCaptureKit

/// 滚动截图编排：框选滚动区域 → 用户在目标窗口里手动滚动，
/// 我们用 SCStream 连续采集该屏幕区域（30fps 上限，静止时 SCK 不发帧）
/// 并交给 `ScrollStitcher` 自动拼接 →
/// 完成后作为一张普通截图入库并打开编辑器（长图上标注比钉图实用）。
///
/// 产物是「一张不绑定显示器的长图」，不走选区工具条 / CaptureAction 管线：
/// 框选用覆盖层的简单模式（松手即返回选区），之后的采集、拼接、入库都在这里。
@MainActor
final class ScrollCaptureController {

    static let shared = ScrollCaptureController()

    /// 与普通截图各用各的覆盖层实例，互不干扰。
    private let overlay: SelectionOverlayController
    private let shotStore: any ShotReading & ShotWriting
    private let pipeline: CapturePipeline
    private let galleryPresenter: any GalleryPresenting
    private var session: ScrollCaptureSession?

    /// 采集期间临时监听 ⎋ 用的绑定名（参考延时截图的 bindTransient 用法）。
    private static let cancelHotKeyName = "cancel-scroll-capture"

    init(
        styleStore: (any StyleStore)? = nil,
        shotStore: (any ShotReading & ShotWriting)? = nil,
        pipeline: CapturePipeline? = nil,
        galleryPresenter: (any GalleryPresenting)? = nil
    ) {
        let resolvedStyleStore = styleStore ?? AppSettings.shared
        self.overlay = SelectionOverlayController(
            capture: resolvedStyleStore,
            annotationStyle: resolvedStyleStore
        )
        self.shotStore = shotStore ?? ShotStore.shared
        self.pipeline = pipeline ?? CapturePipeline.shared
        self.galleryPresenter = galleryPresenter ?? GalleryWindowController.shared
    }

    /// 预览可用 Fake
    static var preview: ScrollCaptureController {
        let store = FakeShotStore()
        return ScrollCaptureController(
            shotStore: store,
            pipeline: CapturePipeline(writer: ShotStoreAttributeWriter(store: store))
        )
    }

    /// 供截图工具条复用已选区域：直接以该区域启动滚动采集
    func begin(with region: CGRect, display: DisplayInfo) {
        guard session == nil, !overlay.isActive else { return }
        let previousApp = SystemNavigator.frontmostApplication
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        guard let dummy = ctx.makeImage() else { return }
        let result = SelectionResult(
            region: region,
            display: display,
            window: nil,
            actionID: ActionID.scrollCapture,
            image: dummy,
            layers: Layers<ImageSpace>(),
            windowCaptureRequest: nil
        )
        startSession(with: result, previousApp: previousApp)
    }

    /// 菜单 / 快捷键入口。采集进行中再按一次快捷键 = 完成（⎋ = 取消）。
    func begin() {
        if let session {
            session.finish()
            return
        }
        guard !overlay.isActive else { return }

        guard MacScreenCapturer.shared.isPermissionGranted else {
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
                let windowList = MacWindowLister.shared.onScreenWindows(
                    excludingPID: ProcessInfo.processInfo.processIdentifier
                )

                // finishOnConfirm：松手即返回选区，不出工具条。这里只要 region + display。
                let didBegin = overlay.begin(
                    snapshots: snapshots,
                    windowList: windowList,
                    finishOnConfirm: true
                ) { [weak self] result in
                    guard let self, let result else { return }
                    self.startSession(with: result, previousApp: previousApp)
                }
                guard didBegin else { throw CaptureError.displayTopologyChanged }
            } catch {
                NSLog("[Index] 滚动截图准备失败: \(error)")
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
            let shot = try shotStore.save(image: image, metadata: metadata)

            if let id = shot.id {
                pipeline.run(
                    shotID: id,
                    originalURL: shotStore.originalURL(for: shot),
                    appBundleID: metadata.appBundleID,
                    metadata: ShotMetadata(from: shot)
                )
            }

            // 长图直接开编辑器 —— 入库 + 标注比钉一整条长图实用。
            // 编辑器活在图库窗口内（单窗口双模式）：弹图库并直接进编辑模式。
            galleryPresenter.showEditor(for: shot)
        } catch {
            NSLog("[Index] 滚动截图保存失败: \(error)")
        }
    }
}

// MARK: - 会话：连续流采集 + 拼接 + 控制条

/// 一次滚动采集的生命周期：屏幕上留一个选区边框和一个小控制条，
/// SCStream 连续送帧（画面没变不送），有变化的帧交给拼接器，
/// 直到用户点「完成」/ 再按快捷键 / ⎋ / 触顶 30000px。
///
/// 帧率与刷新解耦：帧以最高 30fps 进拼接器，控制条的高度数字
/// 节流到 5Hz 刷新 —— 主线程别跟着采集帧率跑。
@MainActor
private final class ScrollCaptureSession {

    /// 完成回调。nil = 取消（或一帧都没采到），丢弃。
    var onFinished: ((CGImage?) -> Void)?

    private let region: CGRect
    private let display: DisplayInfo

    private var stitcher = ScrollStitcher()
    private var grabber: ScrollFrameStream?
    private var startTask: Task<Void, Never>?
    private let panel = ScrollControlPanel()
    private let border = RegionBorderPanel()
    private var finished = false

    /// 控制条高度数字的刷新节流（秒）。
    private static let heightRefreshInterval: CFTimeInterval = 0.2
    /// 连续多少帧对不上才闪「滚慢一点」—— 连续流下偶发一两帧失配很正常
    /// （页面动画、半透明浮层），只有持续接不上（真正跳页）才值得打扰用户。
    private static let noOverlapHintThreshold = 3

    /// 滚动提示节流间隔（秒）。
    private let hintThrottle: TimeInterval = 1.5

    private var lastHeightRefreshAt: CFTimeInterval = 0
    private var heightRefreshPending = false
    private var noOverlapStreak = 0
    private var lastHintAt: CFTimeInterval = 0

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

        startTask = Task { [weak self] in
            guard let self else { return }
            let grabber = ScrollFrameStream(
                region: self.region,
                display: self.display,
                stitcherConfig: self.stitcher.config
            )
            grabber.onFrame = { [weak self] frame, signatures in
                self?.ingest(frame, signatures: signatures)
            }
            grabber.onStopped = { [weak self] error in
                guard let self, !self.finished else { return }
                NSLog("[Index] 滚动采集流中断: \(error)")
                self.cancel()
            }
            do {
                try await grabber.start()
                if self.finished {
                    // 启动期间用户已取消/完成，把刚起来的流收掉。
                    await grabber.stop()
                    return
                }
                self.grabber = grabber
            } catch {
                NSLog("[Index] 滚动采集启动失败: \(error)")
                self.cancel()
            }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        stopStream()
        stitcher.finalize()
        let image = stitcher.makeImage()
        dismissUI()
        onFinished?(image)
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        stopStream()
        dismissUI()
        onFinished?(nil)
    }

    /// `stopCapture` 是异步的，放后台收尾 —— 完成/取消的 UI 反馈不等它。
    private func stopStream() {
        let grabber = self.grabber
        self.grabber = nil
        Task { await grabber?.stop() }
    }

    private func ingest(_ frame: ScrollFrame, signatures: [[Float]]) {
        guard !finished else { return }
        switch stitcher.append(frame, signatures: signatures) {
        case .seeded, .appended:
            noOverlapStreak = 0
            refreshHeight()
        case .unchanged:
            noOverlapStreak = 0
        case .noOverlap:
            noOverlapStreak += 1
            let now = CACurrentMediaTime()
            if noOverlapStreak >= Self.noOverlapHintThreshold, now - lastHintAt >= hintThrottle {
                lastHintAt = now
                panel.flash("滚慢一点，等画面接上再继续")
            }
        case .limitReached:
            finish()
        }
    }

    /// 高度数字节流到 ~5Hz：间隔内的更新合并成一次尾随刷新，最终值不丢。
    private func refreshHeight() {
        guard !heightRefreshPending else { return }
        let now = CACurrentMediaTime()
        if now - lastHeightRefreshAt >= Self.heightRefreshInterval {
            lastHeightRefreshAt = now
            panel.update(height: stitcher.height)
        } else {
            heightRefreshPending = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !self.finished else { return }
                self.heightRefreshPending = false
                self.lastHeightRefreshAt = CACurrentMediaTime()
                self.panel.update(height: self.stitcher.height)
            }
        }
    }

    private func dismissUI() {
        panel.dismiss()
        border.dismiss()
    }
}

// MARK: - 帧采集（SCStream 连续流）

/// 用 SCStream 连续采集屏幕上的一个固定区域（30fps 上限）。
/// 画面静止时 ScreenCaptureKit 不投递新帧 —— 空转零成本；
/// SCContentFilter 排除自身进程 —— 我们的边框和控制条即使压在选区上也不会被拍进去。
///
/// 帧回调在私有串行队列上完成重活：CMSampleBuffer → 紧凑 RGBA `ScrollFrame`
/// （vImage 通道重排，见 `ScrollFrame.init(pixelBuffer:)`）→ 算行签名 →
/// 与上一帧签名全等（用户没滚）直接丢弃，有变化才连签名一起回投主线程。
/// 主线程只做拼接和 UI，采集端的解码/去重压力完全不上主线程。
private final class ScrollFrameStream: NSObject, SCStreamOutput, SCStreamDelegate {

    /// 主线程回调：一帧新画面 + 已算好的行签名（直接传给
    /// `ScrollStitcher.append(_:signatures:)`，不重复计算）。
    var onFrame: (@MainActor (ScrollFrame, [[Float]]) -> Void)?
    /// 主线程回调：流意外停止（权限被收回、显示器拔掉）。主动 `stop()` 不触发。
    var onStopped: (@MainActor (Error) -> Void)?

    private let region: CGRect
    private let display: DisplayInfo
    private let stitcherConfig: ScrollStitcher.Config
    private let sampleQueue = DispatchQueue(label: "com.index.scroll-capture.frames")
    private var stream: SCStream?
    /// 只在 sampleQueue 上访问：上一帧的行签名，「画面没变就丢弃」的节流状态。
    private var lastSignatures: [[Float]]?

    init(region: CGRect, display: DisplayInfo, stitcherConfig: ScrollStitcher.Config) {
        self.region = region
        self.display = display
        self.stitcherConfig = stitcherConfig
    }

    func start() async throws {
        let broker = MacScreenCaptureBroker.shared
        let captureSession = try broker.beginSession()
        defer { broker.finishSession(captureSession) }

        let content = try await broker.shareableContent(
            in: captureSession,
            operationName: "scroll:shareable-content"
        )
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw CaptureError.noDisplays
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(
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
        // SCStream 原生只出 BGRA/YUV，选 BGRA，vImage 一步转成拼接器要的 RGBA。
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await broker.startCapture(
            stream,
            in: captureSession,
            operationName: "scroll:start-stream"
        )
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            NSLog("[Index] 滚动采集流停止失败: \(error)")
        }
    }

    // MARK: SCStreamOutput（sampleQueue 上回调）

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        // 只收完整帧：.idle / .blank / 空 sampleBuffer 一律跳过。
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = ScrollFrame(pixelBuffer: pixelBuffer)
        else { return }

        let signatures = ScrollStitcher.signatures(of: frame, config: stitcherConfig)
        // 画面与上一帧相同（滚动停住等）→ 丢弃，别拿 30fps 打扰主线程。
        guard !ScrollStitcher.isDuplicate(signatures, of: lastSignatures) else { return }
        lastSignatures = signatures

        guard let onFrame else { return }
        Task { @MainActor in onFrame(frame, signatures) }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let onStopped else { return }
        Task { @MainActor in onStopped(error) }
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

    private static let defaultHint = "在目标窗口里向下滚动 · ⎋ 取消"

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
        content.layer?.cornerRadius = DS.radiusLarge

        let height = NSTextField(labelWithString: "已拼接 0 px")
        height.font = .monospacedDigitSystemFont(ofSize: DS.font14, weight: .semibold)
        height.textColor = .white
        height.alignment = .center

        let hint = NSTextField(labelWithString: Self.defaultHint)
        hint.font = .systemFont(ofSize: DS.font11)
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
            path.lineWidth = DS.strokeEmphasis
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }
}
