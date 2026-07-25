import AppKit

/// 串起一次完整截图：选区 → 捕获 → 采元数据 → 落盘入库 → 钉图/剪贴板 → 异步 OCR。
@MainActor
final class CaptureCoordinator {

    static let shared = CaptureCoordinator()

    private let overlay = SelectionOverlayController()

    private init() {}

    func begin() {
        guard !overlay.isActive else { return }

        guard CaptureEngine.hasPermission() else {
            requestPermissionThenPrompt()
            return
        }

        // 关键：覆盖层一旦拿到焦点，frontmostApplication 就变成我们自己了，必须提前记下来。
        let previousApp = NSWorkspace.shared.frontmostApplication

        overlay.begin { [weak self] result in
            guard let self, let result else { return }
            Task { await self.process(result, previousApp: previousApp) }
        }
    }

    private func process(_ result: SelectionResult, previousApp: NSRunningApplication?) async {
        do {
            // 单击窗口时走整窗捕获 —— 能拿到被遮挡的部分，结果比按屏幕区域截更干净。
            let image: CGImage
            if let target = result.window {
                image = try await CaptureEngine.captureWindow(
                    windowID: target.windowID,
                    scale: result.screen.backingScaleFactor
                )
            } else {
                image = try await CaptureEngine.capture(
                    globalRect: result.region,
                    on: result.screen
                )
            }

            let sourceWindow = result.window ?? WindowLister.bestMatch(
                for: result.region,
                excludingPID: ProcessInfo.processInfo.processIdentifier
            )

            let metadata = MetadataCollector.collect(
                region: result.region,
                screen: result.screen,
                window: sourceWindow,
                fallbackApp: previousApp
            )

            // 不管用户点了哪个按钮，都先入库 —— 自动保存是这个 App 的前提。
            let shot = try ShotStore.shared.save(image: image, metadata: metadata)

            if Settings.runOCR, let id = shot.id {
                ImageAnalysisQueue.enqueue(image: image, shotID: id)
            }
            if Settings.copyToClipboard {
                ImageCodec.copyToPasteboard(image)
            }

            switch result.action {
            case .pin:
                PinWindowController.pin(image: image, shot: shot, at: result.region)

            case .copy:
                ImageCodec.copyToPasteboard(image)

            case .annotate:
                EditorWindowController.open(shot: shot)

            case .save:
                exportToDisk(image: image, shot: shot)
            }
        } catch {
            NSLog("[MacShot] 截图失败: \(error)")
            presentError(error)
        }
    }

    private func exportToDisk(image: CGImage, shot: Shot) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName(for: shot)
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ImageCodec.pngData(from: image)?.write(to: url)
    }

    private func defaultFileName(for shot: Shot) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let app = shot.appName.map { "-\($0)" } ?? ""
        return "截图 \(formatter.string(from: shot.capturedAt))\(app).png"
    }

    // MARK: - 权限

    private func requestPermissionThenPrompt() {
        // 这一步会触发系统的授权弹窗（首次）。
        CaptureEngine.requestPermission()

        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = """
        请到「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 MacShot。
        授权后需要重新启动 MacShot 才能生效。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
