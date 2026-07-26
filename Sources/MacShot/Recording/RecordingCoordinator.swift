import AppKit

/// 串起一次完整录屏：
///
///   冻结屏幕(ImmediateScreenSource) → 框选(SelectionOverlayController, plain 模式)
///   → 录制(ScreenRecorder) → 结果弹窗（访达 / 转 GIF）
///
/// 录制产物是 mp4 文件，**不入 shot 图库** —— 图库目前是截图库，视频资产类型是将来的事。
@MainActor
final class RecordingCoordinator {

    static let shared = RecordingCoordinator()

    private let overlay = SelectionOverlayController()
    private var borderPanel: NSPanel?

    /// 录制开始/结束时通知（AppDelegate 用来刷新菜单栏图标和计时）。
    var onStateChanged: (() -> Void)?

    /// 正在框选录制区域。截图入口用它和 `ScreenRecorder.isRecording` 一起做互斥。
    var isSelecting: Bool { overlay.isActive }

    private init() {}

    /// 菜单和快捷键的唯一入口：没在录 = 开始框选，录制中 = 停止。
    func toggle() {
        if ScreenRecorder.shared.isRecording {
            Task { await stopAndPresent() }
            return
        }
        beginSelection()
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
            showBorder(around: region)
            onStateChanged?()
        } catch {
            NSLog("[MacShot] 录屏启动失败: \(error)")
            presentError("无法开始录屏", error)
        }
    }

    func stopAndPresent() async {
        guard ScreenRecorder.shared.isRecording else { return }
        hideBorder()
        do {
            let url = try await ScreenRecorder.shared.stop()
            onStateChanged?()
            presentResult(url)
        } catch {
            onStateChanged?()
            NSLog("[MacShot] 录屏收尾失败: \(error)")
            presentError("录屏失败", error)
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
private final class RecordingBorderView: NSView {

    override func draw(_ dirtyRect: NSRect) {
        let line: CGFloat = 1.5
        let rect = bounds.insetBy(dx: line, dy: line)

        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = line
        border.stroke()

        let arm: CGFloat = 14
        let corners = NSBezierPath()
        corners.lineWidth = 3
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
