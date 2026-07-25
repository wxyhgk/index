import AppKit

/// 串起一次完整截图。只做编排，具体工作都委托出去：
///
///   冻结屏幕(ScreenFreezing) → 选区(SelectionOverlayController)
///   → 采元数据(MetadataCollector) → 入库(ShotStore) → 执行动作(CaptureActionPerformer)
///
/// 注意捕获发生在**最前面**：按下快捷键就把屏幕定格。之后用户在选区上停留多久都无所谓，
/// 存下来的永远是他框选时看到的那一帧。
@MainActor
final class CaptureCoordinator {

    static let shared = CaptureCoordinator()

    private let overlay = SelectionOverlayController()
    private let freezer: ScreenFreezing
    private var isPreparing = false

    init(freezer: ScreenFreezing = ScreenCaptureKitFreezer()) {
        self.freezer = freezer
    }

    func begin() {
        guard !overlay.isActive, !isPreparing else { return }

        guard ScreenRecordingPermission.isGranted else {
            requestPermissionThenPrompt()
            return
        }

        // 关键：覆盖层一旦拿到焦点，frontmostApplication 就变成我们自己了，必须提前记下来。
        let previousApp = NSWorkspace.shared.frontmostApplication

        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let snapshots = try await freezer.freezeAllDisplays()
                let windowList = WindowLister.onScreenWindows(
                    excludingPID: ProcessInfo.processInfo.processIdentifier
                )

                overlay.begin(snapshots: snapshots, windowList: windowList) { [weak self] result in
                    guard let self, let result else { return }
                    self.handle(result, previousApp: previousApp)
                }
            } catch {
                NSLog("[MacShot] 冻结屏幕失败: \(error)")
                presentError(error)
            }
        }
    }

    private func handle(_ result: SelectionResult, previousApp: NSRunningApplication?) {
        let sourceWindow = result.window ?? WindowLister.bestMatch(
            for: result.region,
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )

        let metadata = MetadataCollector.collect(
            region: result.region,
            display: result.display,
            window: sourceWindow,
            fallbackApp: previousApp
        )

        do {
            // 不管用户点了哪个按钮，都先入库 —— 自动保存是这个 App 的前提。
            // 注意存进去的是**未标注**的原始像素：截图时画的标注和后期编辑一样，
            // 只是一条 revision，原图永远保持干净、可回溯。
            let shot = try ShotStore.shared.save(image: result.image, metadata: metadata)

            if !result.layers.isEmpty {
                ShotStore.shared.appendRevision(
                    shot: shot,
                    layers: result.layers,
                    note: "截图时标注"
                )
            }

            if let id = shot.id {
                if AppSettings.shared.runOCR {
                    // OCR 跑原图，标注可能会盖住文字。
                    ImageAnalysisQueue.enqueue(image: result.image, shotID: id)
                }
                if let bundleID = metadata.appBundleID {
                    BrowserURLQueue.enqueue(bundleID: bundleID, shotID: id)
                }
            }

            if shouldAutoCopy(for: result.action) {
                ImageCodec.copyToPasteboard(
                    result.layers.isEmpty
                        ? result.image
                        : LayerRenderer.render(base: result.image, layers: result.layers)
                )
            }

            // 传底图 + 图层而非合成结果 —— 钉图窗口要靠它们继续非破坏性地画。
            CaptureActionPerformer.perform(
                result.action,
                base: result.image,
                layers: result.layers,
                shot: shot,
                region: result.region
            )
        } catch {
            NSLog("[MacShot] 保存失败: \(error)")
            presentError(error)
        }
    }

    /// `.done` 是用户明确选择的「完成但不复制」，必须压过全局的自动复制开关，
    /// 否则设置成「完成不复制」也还是会覆盖剪贴板。
    /// `.copy` 由动作本身负责，不用在这里重复一次。
    private func shouldAutoCopy(for action: ToolbarAction) -> Bool {
        switch action {
        case .done, .copy: return false
        default: return AppSettings.shared.copyToClipboard
        }
    }

    // MARK: - 权限

    private func requestPermissionThenPrompt() {
        // 这一步会触发系统的授权弹窗（首次）。
        ScreenRecordingPermission.request()

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
