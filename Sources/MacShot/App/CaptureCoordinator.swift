import AppKit

/// 串起一次完整截图。只做编排，具体工作都委托出去：
///
///   捕获(CaptureSource) → 选区(SelectionOverlayController)
///   → 采元数据(MetadataCollector) → 入库(ShotStore) → 执行动作(CaptureAction)
///
/// 捕获方式从注册表按 id 取 —— 协调器不认识任何具体实现，
/// 新增捕获方式（延时、单窗口、滚动）不会改动这里。
@MainActor
final class CaptureCoordinator {

    static let shared = CaptureCoordinator()

    private let overlay = SelectionOverlayController()
    private let sources: CaptureSourceRegistry
    private var isPreparing = false
    /// 进行中的准备任务（冻结屏幕 / 延时等待）。取消它就打断整次捕获。
    private var prepareTask: Task<Void, Never>?
    /// 当前准备任务是否允许用户取消（延时等待可以，瞬时冻结不行）。
    private var pendingIsCancellable = false

    /// 倒计时期间临时监听 ⎋ 用的绑定名。
    private static let cancelHotKeyName = "cancel-pending-capture"

    /// 注册表可注入（测试用替身）；不传就用全局共享的那份。
    /// 默认值在方法体里取而不是写成默认参数 —— 默认参数在调用方上下文求值，拿不到主线程隔离。
    init(sources: CaptureSourceRegistry? = nil) {
        self.sources = sources ?? .shared
    }

    /// 截图流程是否进行中（准备或框选）。录屏入口用它做互斥。
    var isBusy: Bool { isPreparing || overlay.isActive }

    func begin(sourceID: String = CaptureSourceID.immediate) {
        // 延时等待期间再按快捷键 = 取消，而不是叠加第二次捕获。
        if isPreparing {
            if pendingIsCancellable { prepareTask?.cancel() }
            return
        }
        guard !overlay.isActive else { return }

        // 录屏进行中（或正在框选录制区域）不开截图 —— 两套覆盖层会互相打架。
        guard !ScreenRecorder.shared.isRecording, !RecordingCoordinator.shared.isSelecting else {
            NSLog("[MacShot] 录屏进行中，截图请求被拒绝")
            return
        }

        guard let source = sources.source(id: sourceID) else {
            NSLog("[MacShot] 未注册的捕获方式: \(sourceID)")
            return
        }

        guard ScreenRecordingPermission.isGranted else {
            requestPermissionThenPrompt()
            return
        }

        isPreparing = true
        pendingIsCancellable = source.isCancellableWhilePreparing
        if pendingIsCancellable {
            // 倒计时期间 ⎋ 全局可取消。裸键绑定只在这个窗口期存在，结束立即注销。
            GlobalHotKeyCenter.shared.bindTransient(
                Self.cancelHotKeyName,
                to: KeyboardShortcut(keyCode: 53, modifiers: 0)   // ⎋
            ) { [weak self] in
                self?.prepareTask?.cancel()
            }
        }

        prepareTask = Task {
            defer {
                isPreparing = false
                prepareTask = nil
                if pendingIsCancellable {
                    GlobalHotKeyCenter.shared.unbind(Self.cancelHotKeyName)
                    pendingIsCancellable = false
                }
            }
            do {
                let snapshots = try await source.makeSnapshots()

                // 关键：覆盖层一旦拿到焦点，frontmostApplication 就变成我们自己了，
                // 必须在覆盖层出现前记下来。放在捕获之后记 —— 延时等待期间用户可能切换了 App，
                // 定格瞬间的前台应用才是截图的真实来源。
                let previousApp = SystemNavigator.frontmostApplication
                let windowList = WindowLister.onScreenWindows(
                    excludingPID: ProcessInfo.processInfo.processIdentifier
                )

                overlay.begin(snapshots: snapshots, windowList: windowList) { [weak self] result in
                    guard let self, let result else { return }
                    self.handle(result, previousApp: previousApp)
                }
            } catch is CancellationError {
                // 用户主动取消延时，静默返回。
            } catch {
                NSLog("[MacShot] 捕获失败(\(sourceID)): \(error)")
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
            Clipboard.copy(context.rendered())
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
            SystemNavigator.openScreenRecordingSettings()
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
