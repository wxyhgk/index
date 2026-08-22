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

    private let overlay: SelectionOverlayController
    private let sources: CaptureSourceRegistry
    private let windowListing: WindowListing
    private let screenCapturer: ScreenCapturing
    private let shotStore: any ShotReading & ShotWriting
    private let styleStore: any StyleStore
    private let pipeline: CapturePipeline
    /// 选区后转直接录屏（由 AppDelegate 注入，断开 Capture → Recording 单例依赖）。
    var recordHandler: (@MainActor (CGRect, DisplayInfo) -> Void)?
    /// 选区后转长截图（由 AppDelegate 注入，断开 Capture → Scroll 单例依赖）。
    var scrollHandler: (@MainActor (CGRect, DisplayInfo) -> Void)?
    /// 互斥检查：录屏/框选录制区域是否进行中（由 AppDelegate 注入）。
    var isOtherCaptureActive: (@MainActor () -> Bool)?
    private var isPreparing = false
    /// 进行中的准备任务（冻结屏幕 / 延时等待）。取消它就打断整次捕获。
    private var prepareTask: Task<Void, Never>?
    /// 当前准备任务是否允许用户取消（延时等待可以，瞬时冻结不行）。
    private var pendingIsCancellable = false

    /// 倒计时期间临时监听 ⎋ 用的绑定名。
    private static let cancelHotKeyName = "cancel-pending-capture"

    /// 注册表可注入（测试用替身）；不传就用全局共享的那份。
    /// 默认值在方法体里取而不是写成默认参数 —— 默认参数在调用方上下文求值，拿不到主线程隔离。
    init(
        sources: CaptureSourceRegistry? = nil,
        windowListing: WindowListing? = nil,
        screenCapturer: ScreenCapturing? = nil,
        shotStore: (any ShotReading & ShotWriting)? = nil,
        styleStore: (any StyleStore)? = nil,
        pipeline: CapturePipeline? = nil,
        selectionAIExecutorFactory: (@MainActor () -> SelectionAIExecutor)? = nil
    ) {
        let resolvedStyleStore = styleStore ?? AppSettings.shared
        self.overlay = SelectionOverlayController(
            capture: resolvedStyleStore,
            annotationStyle: resolvedStyleStore,
            selectionAIExecutorFactory: selectionAIExecutorFactory ?? {
                SelectionAIAssembly.makeExecutor(intelligence: resolvedStyleStore)
            }
        )
        self.sources = sources ?? .shared
        self.windowListing = windowListing ?? MacWindowLister.shared
        self.screenCapturer = screenCapturer ?? MacScreenCapturer.shared
        self.shotStore = shotStore ?? ShotStore.shared
        self.styleStore = resolvedStyleStore
        self.pipeline = pipeline ?? CapturePipeline.shared
    }

    /// 预览/测试便利：直接注入具体假实现。
    static var preview: CaptureCoordinator {
        let store = FakeShotStore()
        return CaptureCoordinator(
            shotStore: store,
            styleStore: FakeStyleStore(),
            pipeline: CapturePipeline(writer: ShotStoreAttributeWriter(store: store))
        )
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
        guard !(isOtherCaptureActive?() ?? false) else {
            NSLog("[Index] 录屏进行中，截图请求被拒绝")
            return
        }

        guard let source = sources.source(id: sourceID) else {
            NSLog("[Index] 未注册的捕获方式: \(sourceID)")
            return
        }

        guard screenCapturer.isPermissionGranted else {
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
                // 不排除自身 PID：让用户能选中 Index 自己的窗口（图库等）截图。
                // overlay 窗口 layer != 0，不会出现在 layer == 0 的窗口列表里。
                let windowList = windowListing.onScreenWindows(
                    excludingPID: 0
                )

                let didBegin = overlay.begin(snapshots: snapshots, windowList: windowList) { [weak self] result in
                    guard let self, let result else { return }
                    self.handle(result, previousApp: previousApp)
                }
                guard didBegin else { throw CaptureError.displayTopologyChanged }
            } catch is CancellationError {
                // 用户主动取消延时，静默返回。
            } catch {
                NSLog("[Index] 捕获失败(\(sourceID)): \(error)")
                presentError(error)
            }
        }
    }

    private func handle(_ result: SelectionResult, previousApp: NSRunningApplication?) {
        // 工具条上直接转录屏/长截图：不产生一张截图，避免图库多一张无用记录。
        // 走注入的闭包而非直接调插件单例 —— Capture 不认识 Recording/Scroll 的具体类型。
        if result.actionID == ActionID.record {
            recordHandler?(result.region, result.display)
            return
        }
        if result.actionID == ActionID.scrollCapture {
            scrollHandler?(result.region, result.display)
            return
        }
        // ⌥+单击整窗：异步用 SCK 重拍不被遮挡的完整窗口（透明背景 + 可选系统阴影）。
        // 冻结画面的裁剪只在窗口已经消失（被关掉）时兜底。
        if let request = result.windowCaptureRequest {
            Task {
                var image = result.image
                do {
                    image = try await screenCapturer.captureWindow(
                        windowID: request.windowID,
                        scale: result.display.scale,
                        includeShadow: styleStore.windowCaptureShadow
                    )
                } catch {
                    NSLog("[Index] 整窗捕获失败，退回冻结画面裁剪: \(error)")
                }
                store(result, image: image, previousApp: previousApp)
            }
            return
        }
        store(result, image: result.image, previousApp: previousApp)
    }

    /// 入库 + 派生处理 + 执行动作。`image` 单独传 —— 整窗捕获路径会用 SCK
    /// 重拍的完整窗口替换掉 `result.image` 里的冻结裁剪。
    private func store(
        _ result: SelectionResult,
        image: CGImage,
        previousApp: NSRunningApplication?
    ) {
        let sourceWindow = result.window ?? windowListing.bestMatch(
            for: result.region,
            excludingPID: 0
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
            let shot = try shotStore.save(image: image, metadata: metadata)

            // 「导出自动加水印」只挂在截图路径这一处：设置开着、配了文案、
            // 截图时没手动开过水印（单例语义的查重），就追加一层 —— 造层走
            // 描述符 `EffectRegistry.watermark`，参数（设置里的文案/模式/透明度）
            // 和工具条/编辑器的手动开关是同一份。图层是图像像素空间
            // （pixelScale 保持 1），它和手画的标注一样进修订链，
            // 图库里能看到、能删。编辑器/钉图的手动开关不受这里影响。
            var layers = result.layers
            let settings: any StyleStore = styleStore
            if settings.autoWatermark,
               !settings.trimmedWatermarkText.isEmpty,
               !layers.elements.contains(where: { $0.kind == .watermark }),
               let watermark = EffectRegistry.descriptor(for: .watermark) {
                var context = EffectContext()
                context.imagePixelWidth = Double(image.width)
                context.imagePixelHeight = Double(image.height)
                context.watermarkText = settings.watermarkText
                context.watermarkMode = settings.watermarkMode
                context.watermarkAlpha = settings.watermarkAlpha
                layers.append(watermark.makeLayer(context))
            }

            // 「自动美化」：四周透明留白 + 内容圆角 + 柔和投影，贴进文档就有成品感。
            // 与水印同一套路 —— 走描述符造层（参数与手动开关同源）、单例语义查重、
            // 进修订链所以图库里能看到也能删。
            //
            // 整窗截图（⌥+单击）**同样适用**。曾经把它排除掉，理由是「系统窗口阴影
            // 会与这层叠成双重阴影」—— 实测不成立：`SCContentFilter(desktopIndependentWindow:)`
            // 返回的图恰好是窗口框本身（原图尺寸 == 选区 × 倍率，一个像素不多），
            // 阴影被裁在外面，`ignoreShadowsSingleWindow` 改的只是渲染而非产出尺寸。
            // 于是整窗截图反而是最需要这层留白的场景。
            //
            // 仍然排除带壳截图（frame 效果）：壳自带边框与投影，再套一层就真的重了。
            if settings.autoBackdrop,
               !layers.elements.contains(where: { $0.kind == .backdrop }),
               !layers.elements.contains(where: { $0.kind == .frame }),
               let backdrop = EffectRegistry.descriptor(for: .backdrop) {
                // 尺寸必须传：留白/圆角/阴影都是按短边百分比烤入的。
                var context = EffectContext()
                context.imagePixelWidth = Double(image.width)
                context.imagePixelHeight = Double(image.height)
                context.backdropPaddingRatio = settings.backdropPaddingRatio
                context.backdropCornerRatio = settings.backdropCornerRatio
                context.backdropShadowRatio = settings.backdropShadowRatio
                context.backdropShadowAlpha = settings.backdropShadowAlpha
                var layer = backdrop.makeLayer(context)
                // 描述符默认的是渐变底；自动美化要的是透明留白。
                // **只换 preset 一个字段** —— 阴影参数已经由描述符按短边比例算好，
                // 整条重造会把它覆盖掉（`setBackdropPreset` 踩过同一个坑）。
                var spec = BackdropSpec.parse(layer.text)
                spec.preset = BackdropPreset.transparent.rawValue
                layer.text = spec.json
                layers.append(layer)
            }

            if !layers.isEmpty {
                shotStore.appendRevision(
                    shot: shot,
                    layers: layers,
                    note: "截图时标注"
                )
            }

            if let id = shot.id {
                // 派生处理全部交给流水线。协调器不知道有几个处理器、各自做什么。
                // 新增能力不会改动这里 —— 这正是此前 OCR 和浏览器地址各写一份
                // 「detached → 算 → MainActor.run → updateXXX」拷贝的原因。
                pipeline.run(
                    shotID: id,
                    originalURL: shotStore.originalURL(for: shot),
                    appBundleID: metadata.appBundleID,
                    metadata: ShotMetadata(from: shot)
                )

                // Hook 事件（= Emacs after-save-hook）：插件挂 afterCapture 就能响应。
                let shotMeta = ShotMetadata(from: shot)
                Task {
                    await HookRegistry.shared.fire(
                        .afterCapture,
                        context: HookContext(
                            event: .afterCapture,
                            shotID: id,
                            image: image,
                            metadata: shotMeta,
                            writer: nil
                        )
                    )
                }
            }

            // 传底图 + 图层而非合成结果 —— 钉图窗口要靠它们继续非破坏性地画。
            // 用的是含自动水印的 layers：钉图/复制看到的和入库的是同一版。
            let context = CaptureContext(
                base: image,
                layers: layers,
                shot: shot,
                region: result.region,
                host: nil
            )
            // 自动副本排在动作之前：它只依赖「已入库」，用户点了哪个按钮、
            // 动作成功与否都不该影响副本落地。
            saveAutoCopy(of: context)
            run(actionID: result.actionID, context: context)

            // 暂存卡片：拖出去就是文件。钉图除外 —— 用户已经得到一个窗口了。
            if result.actionID != ActionID.pin, styleStore.showShelfCard {
                ShelfController.shared.present(image: context.rendered(), shot: shot)
            }
        } catch {
            NSLog("[Index] 保存失败: \(error)")
            presentError(error)
        }
    }

    /// 「自动保存副本」：入库成功后往用户指定目录写一份成品 PNG，
    /// 配合 Obsidian 等监听文件夹让截图直接进知识库。
    /// 尽力而为 —— 未开启、目录不存在都静默跳过，写失败只记日志不打扰。
    private func saveAutoCopy(of context: CaptureContext) {
        let settings: any StyleStore = styleStore
        guard settings.autoCopyEnabled else { return }

        let path = settings.autoCopyDirectory
        var isDirectory: ObjCBool = false
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return }

        // 合成与取名在主 actor 上完成（模板读设置），后台只做编码和写盘。
        let image = context.rendered()
        let name = ImageExporter.suggestedName(for: context.shot)
        let directory = URL(fileURLWithPath: path, isDirectory: true)

        Task.detached(priority: .utility) {
            guard let data = ImageCodec.pngData(from: image) else {
                NSLog("[Index] 自动副本：PNG 编码失败")
                return
            }
            do {
                try ImageExporter.writePNG(data, into: directory, preferredName: name)
            } catch {
                NSLog("[Index] 自动副本写入失败: \(error)")
            }
        }
    }

    /// 协调器不认识任何具体动作 —— 查注册表、决定要不要叠加自动复制、执行。
    /// 新增动作不会改动这个方法。
    private func run(actionID: String, context: CaptureContext) {
        guard let action = CaptureActionRegistry.shared.action(id: actionID) else {
            NSLog("[Index] 未注册的动作: \(actionID)")
            return
        }

        // 动作自己管剪贴板时不要再叠加一次。此前这里是个 switch 的 default 分支，
        // 新动作会默认吃到自动复制 —— 「上传图床」会顺手覆盖剪贴板。
        if styleStore.copyToClipboard && !action.suppressesAutoCopy {
            let image = context.rendered()
            // 先同步写 PNG（保证剪贴板立刻有图，不破坏现有体验）。
            Clipboard.copy(image)
            // 异步检测结构，升级剪贴板为多类型（文本/色值/URL + PNG）。
            // 100-500ms 内用户如果已经粘贴了，拿到的是纯图片（兜底）。
            Task { @MainActor in
                let content = await StructuredContentDetector.detect(in: image)
                switch content {
                case .color(let hex):
                    Clipboard.copy(colorHex: hex, image: image)
                case .url(let url):
                    Clipboard.copy(url: url, image: image)
                case .text(let text):
                    Clipboard.copy(image: image, text: text)
                case .image:
                    break
                }
            }
        }

        Task {
            do {
                try await action.perform(context)
            } catch {
                NSLog("[Index] 动作 \(actionID) 失败: \(error)")
                presentError(error)
            }
        }
    }

    // MARK: - 权限

    /// 滚动截图入口也复用这份引导，避免出现第二份权限弹窗实现。
    func requestPermissionThenPrompt() {
        // 这一步会触发系统的授权弹窗（首次）。
        _ = screenCapturer.requestPermission()

        let choice = AppAlert.confirm(
            "需要「屏幕录制」权限",
            message: """
            请到「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 Index。
            授权后需要重新启动 Index 才能生效。
            """,
            buttons: ["打开系统设置", "稍后"]
        )
        if choice == 0 {
            SystemNavigator.openScreenRecordingSettings()
        }
    }

    private func presentError(_ error: Error) {
        AppAlert.error("截图失败", error: error)
    }
}
