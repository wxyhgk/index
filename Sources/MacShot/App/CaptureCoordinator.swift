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
                // 派生处理全部交给流水线。协调器不知道有几个处理器、各自做什么。
                // 新增能力不会改动这里 —— 这正是此前 OCR 和浏览器地址各写一份
                // 「detached → 算 → MainActor.run → updateXXX」拷贝的原因。
                CapturePipeline.shared.run(PostProcessInput(
                    shotID: id,
                    image: result.image,   // 跑原图，标注可能盖住文字
                    appBundleID: metadata.appBundleID
                ))
            }

            // 传底图 + 图层而非合成结果 —— 钉图窗口要靠它们继续非破坏性地画。
            let context = CaptureContext(
                base: result.image,
                layers: result.layers,
                shot: shot,
                region: result.region,
                host: nil
            )
            run(actionID: result.actionID, context: context)
        } catch {
            NSLog("[MacShot] 保存失败: \(error)")
            presentError(error)
        }
    }

    /// 协调器不认识任何具体动作 —— 查注册表、决定要不要叠加自动复制、执行。
    /// 新增动作不会改动这个方法。
    private func run(actionID: String, context: CaptureContext) {
        guard let action = CaptureActionRegistry.shared.action(id: actionID) else {
            NSLog("[MacShot] 未注册的动作: \(actionID)")
            return
        }

        // 动作自己管剪贴板时不要再叠加一次。此前这里是个 switch 的 default 分支，
        // 新动作会默认吃到自动复制 —— 「上传图床」会顺手覆盖剪贴板。
        if AppSettings.shared.copyToClipboard && !action.suppressesAutoCopy {
            ImageCodec.copyToPasteboard(context.rendered())
        }

        Task {
            do {
                try await action.perform(context)
            } catch {
                NSLog("[MacShot] 动作 \(actionID) 失败: \(error)")
                presentError(error)
            }
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
