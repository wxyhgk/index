import AppKit
import AVFoundation

/// 串起一次完整录屏：
///
///   冻结屏幕(ImmediateScreenSource) → 框选(SelectionOverlayController, plain 模式)
///   → 录制(ScreenRecorder，可暂停/继续) → 结果弹窗（访达 / 转 GIF）
///
/// 录制产物是 mp4 文件，**不入 shot 图库** —— 图库目前是截图库，视频资产类型
/// 是将来的事。开了「录屏完成后保存到图库」时，把**首帧截图**入库当锚点，
/// 视频路径挂在 `recording.path` 属性上（见 `saveAnchorShot`）。
@MainActor
final class RecordingCoordinator {

    static let shared = RecordingCoordinator()

    private let overlay = SelectionOverlayController()
    private var borderPanel: NSPanel?

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

    private init() {}

    /// 菜单和快捷键的唯一入口：没在录 = 开始框选，录制中或暂停中 = 停止。
    func toggle() {
        if ScreenRecorder.shared.isRecording {
            Task { await stopAndPresent() }
            return
        }
        beginSelection()
    }

    /// 暂停 ⇄ 继续。切换在途时的重复触发直接丢弃。
    func pauseOrResume() {
        guard ScreenRecorder.shared.isRecording, !isTogglingPause else { return }
        isTogglingPause = true
        Task {
            defer { isTogglingPause = false }
            do {
                if ScreenRecorder.shared.isPaused {
                    try await ScreenRecorder.shared.resume()
                } else {
                    try await ScreenRecorder.shared.pause()
                }
                setBorderPaused(ScreenRecorder.shared.isPaused)
                onStateChanged?()
            } catch {
                NSLog("[MacShot] 录屏暂停/继续失败: \(error)")
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
        guard case .idle = ScreenRecorder.shared.state, !overlay.isActive else { return }
        // 截图流程进行中不叠加录屏，反过来 CaptureCoordinator.begin 也会查我们。
        guard !CaptureCoordinator.shared.isBusy else { return }
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.request()
            presentInfo(
                "需要「屏幕录制」权限",
                "请到「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 MacShot，授权后重新启动。"
            )
            return
        }

        Task {
            do {
                // 冻结画面只用于框选预览，真正录的是实时屏幕。
                let snapshots = try await ImmediateScreenSource().makeSnapshots()
                let windowList = WindowLister.onScreenWindows(
                    excludingPID: ProcessInfo.processInfo.processIdentifier
                )
                overlay.begin(snapshots: snapshots, windowList: windowList, mode: .plain) {
                    [weak self] result in
                    guard let self, let result else { return }
                    Task { await self.startRecording(region: result.region, display: result.display) }
                }
            } catch {
                NSLog("[MacShot] 录屏框选失败: \(error)")
                presentError("无法开始录屏", error)
            }
        }
    }

    // MARK: - 录制

    private func startRecording(region: CGRect, display: DisplayInfo) async {
        do {
            try await ScreenRecorder.shared.start(region: region, display: display)
            lastRegion = region
            lastDisplay = display
            showBorder(around: region)
            onStateChanged?()
        } catch {
            NSLog("[MacShot] 录屏启动失败: \(error)")
            presentError("无法开始录屏", error)
        }
    }

    func stopAndPresent() async {
        // 暂停中按停止 = 正常收尾拼接；暂停/继续切换在途时丢弃（再按一次即可）。
        guard ScreenRecorder.shared.isRecording, !isTogglingPause else { return }
        hideBorder()
        do {
            let url = try await ScreenRecorder.shared.stop()
            onStateChanged?()
            if AppSettings.shared.recordingSaveToLibrary {
                await saveAnchorShot(for: url)
            }
            presentResult(url)
        } catch {
            onStateChanged?()
            NSLog("[MacShot] 录屏收尾失败: \(error)")
            presentError("录屏失败", error)
        }
    }

    // MARK: - 首帧入库（锚点）

    /// mp4 不是图库资产（shot 是图片），入库的是**首帧截图**当锚点：
    /// windowTitle 写「录屏 mm:ss」，视频绝对路径挂在 `recording.path` 属性的
    /// payload 上（attributeFts 同步索引整个 text 列，路径进 text 就进了
    /// 搜索索引，所以只能走 payload）。详情栏据此显示「打开录像」。
    /// 完整的视频资产类型仍留待将来。失败只记日志 —— 录像本身已经保住了。
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

            let shot = try ShotStore.shared.save(image: frame, metadata: meta)
            if let shotID = shot.id {
                ShotStore.shared.writeAttribute(
                    shotID: shotID,
                    key: AttributeKey.recordingPath,
                    value: .data(Data(url.path.utf8), searchableText: nil)
                )
            }
        } catch {
            NSLog("[MacShot] 录屏首帧入库失败: \(error)")
        }
    }

    // MARK: - 录制中的红框提示

    private func showBorder(around region: CGRect) {
        // 边框画在选区**外侧**；而且自身进程已被捕获过滤器排除，绝不会进画面。
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
    }

    // MARK: - 结果

    private func presentResult(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "录屏完成"
        alert.informativeText = url.lastPathComponent
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: "转为 GIF")
        alert.addButton(withTitle: "关闭")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            SystemNavigator.revealInFinder(url)
        case .alertSecondButtonReturn:
            convertToGIF(url)
        default:
            break
        }
    }

    private func convertToGIF(_ url: URL) {
        Task {
            do {
                let gif = try await GIFExporter.export(videoURL: url)
                SystemNavigator.revealInFinder(gif)
            } catch {
                NSLog("[MacShot] GIF 转换失败: \(error)")
                presentError("GIF 转换失败", error)
            }
        }
    }

    // MARK: - 弹窗

    private func presentInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
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
