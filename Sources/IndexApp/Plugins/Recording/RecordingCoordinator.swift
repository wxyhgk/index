import AppKit
import AVFoundation

/// 串起一次完整录屏：
///
///   冻结屏幕(ImmediateScreenSource) → 框选(SelectionOverlayController, plain 模式)
///   → 录制(ScreenRecorder，可暂停/继续) → 结果弹窗（访达 / 转 GIF）
///
/// mp4 是外置的不可变资产；图库通过一个首帧封面 Shot 和 `shotAsset`
/// 关联它。这样录屏能进入统一时间线、筛选和选择体系，同时拖出/播放的仍是
/// 原始 mp4（见 `saveAnchorShot`）。
@MainActor
final class RecordingCoordinator {

    static let shared = RecordingCoordinator()

    private let overlay: SelectionOverlayController
    private let shotStore: any ShotWriting
    private let styleStore: any StyleStore
    /// 测试缝：生产环境为空时走真实首帧提取；测试只验证入库策略，不启动 AVFoundation。
    private let recordingAnchorSaver: (@MainActor (URL) async -> Void)?
    /// 测试缝：生产环境为空时走平台弹窗；生命周期测试可只记录错误而不展示 UI。
    private let runtimeFailurePresenter: (@MainActor (Error) -> Void)?
    private let recorder: ScreenRecorder
    private var borderPanel: NSPanel?
    private var controlPanel: RecordingControlPanel?
    private var recordingStartDate: Date?
    private var timer: Timer?
    private var lastHandledTerminationID: UUID?

    /// 本次录制的鼠标点击记录（净录制时间轴 + 全局位置），步骤指南切分与高亮用。
    private var clickTracker: MouseClickTracker?
    private var lastClicks: [ClickEvent] = []

    /// 暂停/继续切换进行中（stopCapture / startCapture 在途）。
    /// 期间丢弃新的暂停与停止请求，避免同一段被并发收尾。
    private var isTogglingPause = false

    /// 本次录制的选区与显示器，首帧入库时充当截图元数据。
    private var lastRegion: CGRect?
    private var lastDisplay: DisplayInfo?

    /// 录制开始/结束/暂停时通知（AppDelegate 用来刷新菜单栏图标和计时）。
    var onStateChanged: (() -> Void)?

    /// 正在框选录制区域。截图入口用它和 `ScreenRecorder.isRecording` 一起做互斥。
    var isSelecting: Bool { overlay.isActive }

    init(
        shotStore: (any ShotWriting)? = nil,
        styleStore: (any StyleStore)? = nil,
        recordingAnchorSaver: (@MainActor (URL) async -> Void)? = nil,
        runtimeFailurePresenter: (@MainActor (Error) -> Void)? = nil,
        recorder: ScreenRecorder? = nil
    ) {
        let resolvedStyleStore = styleStore ?? AppSettings.shared
        self.overlay = SelectionOverlayController(
            capture: resolvedStyleStore,
            annotationStyle: resolvedStyleStore
        )
        self.shotStore = shotStore ?? ShotStore.shared
        self.styleStore = resolvedStyleStore
        self.recordingAnchorSaver = recordingAnchorSaver
        self.runtimeFailurePresenter = runtimeFailurePresenter
        let resolvedRecorder = recorder ?? .shared
        self.recorder = resolvedRecorder
        resolvedRecorder.onTermination = { [weak self] event in
            self?.handleRecorderTermination(event)
        }
    }

    /// 预览可用 Fake
    static var preview: RecordingCoordinator {
        RecordingCoordinator(
            shotStore: FakeShotStore(),
            styleStore: FakeStyleStore(),
            recorder: ScreenRecorder()
        )
    }

    /// 菜单和快捷键的唯一入口：没在录 = 开始框选，录制中或暂停中 = 停止。
    func toggle() {
        if recorder.isRecording {
            Task { await stopAndPresent() }
            return
        }
        beginSelection()
    }

    /// 暂停 ⇄ 继续。切换在途时的重复触发直接丢弃。
    func pauseOrResume() {
        guard recorder.isRecording, !isTogglingPause else { return }
        isTogglingPause = true
        Task {
            defer { isTogglingPause = false }
            do {
                let willPause = !recorder.isPaused
                if recorder.isPaused {
                    try await recorder.resume()
                } else {
                    try await recorder.pause()
                }
                setBorderPaused(recorder.isPaused)
                // 控制条计时与菜单同步
                freezeTimer(paused: willPause)
                onStateChanged?()
            } catch {
                NSLog("[Index] 录屏暂停/继续失败: \(error)")
                // 运行期终止事件已经负责 UI 与错误提示，避免同一故障再弹一次。
                guard recorder.isRecording else { return }
                onStateChanged?()
                presentError("无法暂停或继续录制", error)
            }
        }
    }

    // MARK: - 框选

    private func beginSelection() {
        guard ScreenRecorder.isSupported else {
            presentInfo(
                "需要 macOS 15",
                "选区录屏基于系统的 SCRecordingOutput，仅在 macOS 15 及以上可用。"
            )
            return
        }
        guard case .idle = recorder.state, !overlay.isActive else { return }
        // 截图流程进行中不叠加录屏，反过来 CaptureCoordinator.begin 也会查我们。
        guard !CaptureCoordinator.shared.isBusy else { return }
        guard MacScreenCapturer.shared.isPermissionGranted else {
            _ = MacScreenCapturer.shared.requestPermission()
            presentInfo(
                "需要「屏幕录制」权限",
                "请到「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 Index，授权后重新启动。"
            )
            return
        }

        Task {
            do {
                // 冻结画面只用于框选预览，真正录的是实时屏幕。
                let snapshots = try await ImmediateScreenSource().makeSnapshots()
                let windowList = MacWindowLister.shared.onScreenWindows(
                    excludingPID: ProcessInfo.processInfo.processIdentifier
                )
                let didBegin = overlay.begin(snapshots: snapshots, windowList: windowList, mode: .plain) {
                    [weak self] result in
                    guard let self, let result else { return }
                    Task { await self.startRecording(region: result.region, display: result.display) }
                }
                guard didBegin else { throw CaptureError.displayTopologyChanged }
            } catch {
                NSLog("[Index] 录屏框选失败: \(error)")
                presentError("无法开始录屏", error)
            }
        }
    }

    // MARK: - 录制

    /// 供截图工具条直接复用已选区域：跳过二次框选，直接开录
    func startDirectly(region: CGRect, display: DisplayInfo) {
        guard !recorder.isRecording, !overlay.isActive else { return }
        Task { await startRecording(region: region, display: display) }
    }

    private func startRecording(region: CGRect, display: DisplayInfo) async {
        do {
            try await recorder.start(region: region, display: display)
            // 运行期失败可能恰好在 start() 返回与本任务恢复之间到达；终止事件已经收尾，
            // 此时不能再把红框、控制条和 timer 重新挂回来。
            guard recorder.isRecording else { return }
            lastRegion = region
            lastDisplay = display
            startClickTracking()
            showBorder(around: region)
            showControls(around: region, display: display)
            startTimer()
            onStateChanged?()
        } catch {
            NSLog("[Index] 录屏启动失败: \(error)")
            presentError("无法开始录屏", error)
        }
    }

    func stopAndPresent() async {
        // 暂停中按停止 = 正常收尾拼接；暂停/继续切换在途时丢弃（再按一次即可）。
        guard recorder.isRecording, !isTogglingPause else { return }
        teardownRecordingUI(clearMetadata: false)
        do {
            let url = try await recorder.stop()
            onStateChanged?()
            // 默认直接入库：首帧当封面，mp4 作为 recording 附件。用户明确
            // 关闭设置时才只保留文件，不能让一个看似有效的开关实际完全不生效。
            await indexRecordingIfEnabled(at: url)
            presentResult(url)
        } catch {
            onStateChanged?()
            NSLog("[Index] 录屏收尾失败: \(error)")
            presentError("录屏失败", error)
        }
    }

    /// ScreenRecorder 的 stream/output 失败事件最终都走这里。按会话 ID 去重，确保两个
    /// delegate 回调或迟到事件不会重复关窗、重复通知、重复弹错。
    func handleRecorderTermination(_ event: RecordingTerminationEvent) {
        guard lastHandledTerminationID != event.id else { return }
        lastHandledTerminationID = event.id
        teardownRecordingUI(clearMetadata: true)
        onStateChanged?()
        NSLog("[Index] 录屏运行期终止: \(event.error)")
        if let runtimeFailurePresenter {
            runtimeFailurePresenter(event.error)
        } else {
            presentError("录屏意外终止", event.error)
        }
    }

    private func teardownRecordingUI(clearMetadata: Bool) {
        isTogglingPause = false
        hideBorder()
        hideControls()
        stopTimer()
        // 正常停止时取回点击记录（步骤指南用）；运行期终止时只拆 monitor。
        lastClicks = stopClickTracking()
        if clearMetadata {
            lastRegion = nil
            lastDisplay = nil
            lastClicks = []
        }
    }

    // MARK: - 首帧入库（锚点）

    /// 录屏完成后的图库策略边界。单独收口后，默认开启与用户明确关闭两条路径
    /// 都能在不启动真实录屏的条件下验证。
    func indexRecordingIfEnabled(at url: URL) async {
        guard styleStore.recordingSaveToLibrary else { return }
        if let recordingAnchorSaver {
            await recordingAnchorSaver(url)
        } else {
            await saveAnchorShot(for: url)
        }
    }

    /// 图库仍用**首帧截图**充当可标注封面：windowTitle 写「录屏 mm:ss」，
    /// 视频绝对路径作为 kind=recording 的 `shotAsset` 关联到封面。
    /// 失败只记日志 —— 录像文件本身已经保住了。
    private func saveAnchorShot(for url: URL) async {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let (frame, _) = try await generator.image(at: .zero)

            var meta = CaptureMetadata()
            let seconds = max(0, Int(duration.seconds.rounded()))
            meta.windowTitle = String(format: "录屏 %02d:%02d", seconds / 60, seconds % 60)
            if let region = lastRegion { meta.globalRegion = region }
            if let display = lastDisplay {
                meta.scale = Double(display.scale)
                meta.displayID = display.id
                meta.displayName = display.name
            }

            let shot = try shotStore.save(image: frame, metadata: meta)
            try shotStore.attachRecording(at: url, to: shot)
        } catch {
            NSLog("[Index] 录屏首帧入库失败: \(error)")
        }
    }

    // MARK: - 录制中的红框提示

    private func showBorder(around region: CGRect) {
        // 边框画在选区**外侧**。`sharingType = .none` 让 ScreenCaptureKit 直接
        // 不捕获这个窗口 —— 不依赖「自身进程被 SCContentFilter 排除」：本进程是
        // .accessory 应用，框选 overlay 关掉后枚举时可能没有可见窗口、不在
        // applications 列表里，排除会落空（大选区时红框就被录进去了）。
        let panel = NSPanel(
            contentRect: region.insetBy(dx: -4, dy: -4),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = RecordingBorderView()
        panel.orderFrontRegardless()
        borderPanel = panel
    }

    private func hideBorder() {
        borderPanel?.orderOut(nil)
        borderPanel = nil
    }

    /// 暂停中把红框虚线化，一眼看出「框还在、没在录」。
    private func setBorderPaused(_ paused: Bool) {
        (borderPanel?.contentView as? RecordingBorderView)?.paused = paused
        controlPanel?.isPaused = paused
    }

    // MARK: - 底部控制条

    private func showControls(around region: CGRect, display: DisplayInfo) {
        let panel = RecordingControlPanel()
        panel.onPauseResume = { [weak self] in self?.pauseOrResume() }
        panel.onStop = { [weak self] in Task { await self?.stopAndPresent() } }
        panel.show(near: region, on: display)
        controlPanel = panel
    }

    private func hideControls() {
        controlPanel?.dismiss()
        controlPanel = nil
    }

    private func startTimer() {
        stopTimer()
        recordingStartDate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartDate else { return }
            let elapsed = max(0, Int(Date().timeIntervalSince(start)))
            self.controlPanel?.updateTime(elapsed: elapsed)
        }
        RunLoop.main.add(timer!, forMode: .common)
        controlPanel?.updateTime(elapsed: 0)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        recordingStartDate = nil
    }

    // 暂停期间计时不走：把已用时长冻结，继续时从该时长接着计时
    private func freezeTimer(paused: Bool) {
        if paused {
            timer?.invalidate()
            timer = nil
        } else {
            // 重建：用已显示的 elapsed 反推 startDate
            let current = controlPanel?.currentElapsed ?? 0
            recordingStartDate = Date().addingTimeInterval(TimeInterval(-current))
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let start = self.recordingStartDate else { return }
                let elapsed = max(0, Int(Date().timeIntervalSince(start)))
                self.controlPanel?.updateTime(elapsed: elapsed)
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    // MARK: - 鼠标点击记录（步骤指南切分用）

    /// 点击时刻直接取 `recorder.elapsed`（净录制时长，暂停不走字），
    /// 与分段拼接后的成品 mp4 时间轴天然对齐。
    private func startClickTracking() {
        let tracker = MouseClickTracker { [weak self] in self?.recorder.elapsed ?? 0 }
        tracker.start()
        clickTracker = tracker
    }

    /// 停止并取回点击记录。重复调用幂等。
    private func stopClickTracking() -> [ClickEvent] {
        defer { clickTracker = nil }
        return clickTracker?.stop() ?? []
    }

    // MARK: - 结果

    private func presentResult(_ url: URL) {
        switch AppAlert.confirm(
            "录屏完成",
            message: url.lastPathComponent,
            buttons: ["在访达中显示", "转为 GIF", "生成步骤指南", "关闭"]
        ) {
        case 0:
            SystemNavigator.revealInFinder(url)
        case 1:
            convertToGIF(url)
        case 2:
            generateStepGuide(url)
        default:
            break
        }
    }

    private func generateStepGuide(_ url: URL) {
        let clicks = lastClicks
        let region = lastRegion
        let scale = lastDisplay?.scale ?? 1
        Task {
            do {
                let guide = try await StepGuideGenerator.generate(
                    videoURL: url,
                    clicks: clicks,
                    region: region,
                    scale: scale
                )
                NSLog("[Index] 步骤指南已生成（\(guide.stepCount) 步）: \(guide.directory.path)")
                SystemNavigator.revealInFinder(guide.directory)
            } catch {
                NSLog("[Index] 步骤指南生成失败: \(error)")
                presentError("步骤指南生成失败", error)
            }
        }
    }

    private func convertToGIF(_ url: URL) {
        Task {
            do {
                let gif = try await GIFExporter.export(videoURL: url)
                SystemNavigator.revealInFinder(gif)
            } catch {
                NSLog("[Index] GIF 转换失败: \(error)")
                presentError("GIF 转换失败", error)
            }
        }
    }

    // MARK: - 弹窗

    private func presentInfo(_ title: String, _ message: String) {
        AppAlert.info(title, message: message)
    }

    private func presentError(_ title: String, _ error: Error) {
        AppAlert.error(title, error: error)
    }
}

// MARK: - 录制底部控制条（暂停/继续/停止）

@MainActor
private final class RecordingControlPanel: NSObject {

    var onPauseResume: (() -> Void)?
    var onStop: (() -> Void)?

    private var panel: NSPanel?
    private var timeLabel: NSTextField?
    private var pauseButton: NSButton?
    private var stopButton: NSButton?

    private var elapsed: Int = 0
    var currentElapsed: Int { elapsed }
    var isPaused: Bool = false {
        didSet {
            let name = isPaused ? "play.fill" : "pause.fill"
            pauseButton?.image = NSImage(
                systemSymbolName: name,
                accessibilityDescription: isPaused ? "继续" : "暂停"
            )
            pauseButton?.toolTip = isPaused ? "继续" : "暂停"
        }
    }

    func show(near region: CGRect, on display: DisplayInfo) {
        guard panel == nil else { return }

        let size = CGSize(width: 320, height: 64)
        let screen = display.frame

        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 16)
        if origin.y < screen.minY + 8 {
            origin.y = region.maxY + 12
            if origin.y + size.height > screen.maxY - 8 {
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
        panel.level = .statusBar
        // 控制条在选区内时（大选区/整屏）不能被录进去：SCK 直接不捕获。
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false

        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        content.layer?.cornerRadius = 10

        let time = NSTextField(labelWithString: "00:00")
        time.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        time.textColor = .white
        time.alignment = .center

        let pause = NSButton(title: "", target: self, action: #selector(pauseTapped))
        pause.bezelStyle = .circular
        pause.controlSize = .regular
        pause.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "暂停")
        pause.imagePosition = .imageOnly
        pause.toolTip = "暂停"

        let stop = NSButton(title: "", target: self, action: #selector(stopTapped))
        stop.bezelStyle = .circular
        stop.controlSize = .regular
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止")
        stop.imagePosition = .imageOnly
        stop.toolTip = "停止"
        stop.keyEquivalent = "\r"

        let buttons = NSStackView(views: [pause, stop])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [time, buttons])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14)
        ])

        panel.contentView = content
        panel.orderFrontRegardless()

        self.panel = panel
        self.timeLabel = time
        self.pauseButton = pause
        self.stopButton = stop
        self.elapsed = 0
    }

    func updateTime(elapsed: Int) {
        self.elapsed = elapsed
        timeLabel?.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        timeLabel = nil
        pauseButton = nil
        stopButton = nil
    }

    @objc private func pauseTapped() { onPauseResume?() }
    @objc private func stopTapped() { onStop?() }
}

/// 录制中的选区描边：细红框 + 四角加粗，一眼看出正在录哪块。
/// 暂停中整套描边虚线化。
private final class RecordingBorderView: NSView {

    var paused = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let line: CGFloat = 1.5
        let rect = bounds.insetBy(dx: line, dy: line)
        let dash: [CGFloat] = [6, 4]

        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = line
        if paused {
            border.setLineDash(dash, count: dash.count, phase: 0)
        }
        border.stroke()

        let arm: CGFloat = 14
        let corners = NSBezierPath()
        corners.lineWidth = 3
        if paused {
            corners.setLineDash(dash, count: dash.count, phase: 0)
        }
        // 左下
        corners.move(to: NSPoint(x: rect.minX, y: rect.minY + arm))
        corners.line(to: NSPoint(x: rect.minX, y: rect.minY))
        corners.line(to: NSPoint(x: rect.minX + arm, y: rect.minY))
        // 右下
        corners.move(to: NSPoint(x: rect.maxX - arm, y: rect.minY))
        corners.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        corners.line(to: NSPoint(x: rect.maxX, y: rect.minY + arm))
        // 右上
        corners.move(to: NSPoint(x: rect.maxX, y: rect.maxY - arm))
        corners.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        corners.line(to: NSPoint(x: rect.maxX - arm, y: rect.maxY))
        // 左上
        corners.move(to: NSPoint(x: rect.minX + arm, y: rect.maxY))
        corners.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        corners.line(to: NSPoint(x: rect.minX, y: rect.maxY - arm))
        corners.stroke()
    }
}
