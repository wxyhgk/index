import AppKit
import CoreImage

/// 内置动作。
///
/// 这个文件是「新增动作」的唯一登记处 —— 加一个动作就是在下面写一个 struct，
/// 再往 `registerAll` 里加一行。工具条、协调器、钉图窗口都不需要改。

struct PinAction: CaptureAction {
    let id = ActionID.pin
    let title = "钉图"
    let symbolName = "pin.fill"
    let scopes: Set<ActionScope> = [.capture]
    /// 钉图窗口要读的设置切片（回车语义 / 标注样式持久化）。
    private let capture: any CapturePreferences
    private let annotationStyle: any AnnotationStylePreferences

    init(capture: any CapturePreferences, annotationStyle: any AnnotationStylePreferences) {
        self.capture = capture
        self.annotationStyle = annotationStyle
    }

    func perform(_ context: CaptureContext) async throws {
        PinWindowController.pin(
            base: context.base,
            layers: context.layers,
            shot: context.shot,
            at: context.region ?? .zero,
            capture: capture,
            annotationStyle: annotationStyle
        )
    }
}

/// 所有活跃钉图紧凑排列：贪心行填充 + 每行水平居中 + 0.25s 动画。
/// 只在钉图工具条上出现（scope .pinned），≤1 张图时不触发。
struct CompactArrangeAction: CaptureAction {
    let id = ActionID.compactArrange
    let title = "紧凑排列"
    let symbolName = "rectangle.3.group"
    let scopes: Set<ActionScope> = [.pinned]

    func perform(_ context: CaptureContext) async throws {
        let windows = PinWindowRegistry.shared.activeWindows
        guard windows.count > 1 else { return }

        let mousePoint = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mousePoint) } ?? NSScreen.main!
        Self.arrange(windows: windows, on: screen)
    }

    @MainActor
    private static func arrange(windows: [NSWindow], on screen: NSScreen) {
        let visible = screen.visibleFrame
        let gap: CGFloat = 24
        let margin: CGFloat = 40
        let maxWidth = visible.width - 2 * margin

        // 按 y 坐标排序（macOS y 向上，midY 大的在上面 → 先排上面的）
        let sorted = windows.sorted { $0.frame.midY > $1.frame.midY }

        // 贪心行填充
        var rows: [[NSWindow]] = []
        var currentRow: [NSWindow] = []
        var currentRowWidth: CGFloat = 0

        for window in sorted {
            let w = window.frame.width
            if currentRow.isEmpty {
                currentRow.append(window)
                currentRowWidth = w
            } else if currentRowWidth + gap + w <= maxWidth {
                currentRow.append(window)
                currentRowWidth += gap + w
            } else {
                rows.append(currentRow)
                currentRow = [window]
                currentRowWidth = w
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        // 计算每行尺寸
        let rowHeights = rows.map { $0.map { $0.frame.height }.max() ?? 0 }
        let rowWidths = rows.map { row -> CGFloat in
            let ws = row.map { $0.frame.width }
            return ws.reduce(0, +) + gap * CGFloat(max(0, ws.count - 1))
        }
        let totalHeight = rowHeights.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1))

        // 整体垂直居中到屏幕
        let topY = visible.midY + totalHeight / 2

        // 动画移动：每行水平居中
        NSAnimationContext.runAnimationGroup { animContext in
            animContext.duration = 0.25
            animContext.timingFunction = CAMediaTimingFunction(name: .easeOut)

            var rowTopY = topY
            for (i, row) in rows.enumerated() {
                let rowHeight = rowHeights[i]
                let rowWidth = rowWidths[i]
                var xOffset = visible.midX - rowWidth / 2

                for window in row {
                    let targetY = rowTopY - rowHeight + (rowHeight - window.frame.height) / 2
                    window.animator().setFrame(
                        CGRect(x: xOffset, y: targetY,
                               width: window.frame.width,
                               height: window.frame.height),
                        display: true
                    )
                    xOffset += window.frame.width + gap
                }
                rowTopY -= rowHeight + gap
            }
        }
    }
}

struct CopyAction: CaptureAction {
    let id = ActionID.copy
    let title = "复制"
    let symbolName = "doc.on.doc"
    let scopes: Set<ActionScope> = [.capture, .pinned]
    /// 自己就是复制，不需要全局自动复制再来一次。
    let suppressesAutoCopy = true

    func perform(_ context: CaptureContext) async throws {
        Clipboard.copy(context.rendered())
    }
}

struct SaveAction: CaptureAction {
    let id = ActionID.save
    let title = "保存"
    let symbolName = "square.and.arrow.down"
    let scopes: Set<ActionScope> = [.capture, .pinned]

    func perform(_ context: CaptureContext) async throws {
        // 走 sheet 那条路：面板落在刚才截图的那块屏上，而且不必激活整个 App ——
        // 后者会把图库那组 stage 一起拽到前台，把用户正在用的软件挤进侧边条。
        // 钉图窗口发起时 region 为 nil，退回 key 窗口 / 指针那块屏。
        try await ImageExporter.exportWithPanel(
            context.rendered(),
            suggestedName: ImageExporter.suggestedName(for: context.shot),
            over: context.region
        )
    }
}

struct CloseAction: CaptureAction {
    let id = ActionID.close
    let title = "关闭"
    let symbolName = "xmark"
    let scopes: Set<ActionScope> = [.capture, .pinned]

    func perform(_ context: CaptureContext) async throws {
        context.host?.dismiss()
    }
}

/// 自动马赛克：Vision OCR 检测选区内文字区域，批量添加马赛克图层。
/// perform 不走这里 —— emit 中 autoMosaic 直接调 OverlayView.performAutoMosaic()。
struct AutoMosaicAction: CaptureAction {
    let id = ActionID.autoMosaic
    let title = "自动马赛克"
    let symbolName = "textformat.abc.dottedcircle"
    let scopes: Set<ActionScope> = [.capture]
    let isPrimaryAction = false

    func perform(_ context: CaptureContext) async throws {}
}

/// 扫码：Core Image CIDetector 检测选区内二维码，内容复制到剪贴板。
struct QrScanAction: CaptureAction {
    let id = ActionID.qrScan
    let title = "扫码"
    let symbolName = "qrcode.viewfinder"
    let scopes: Set<ActionScope> = [.capture]
    let suppressesAutoCopy = true
    let isPrimaryAction = false

    func perform(_ context: CaptureContext) async throws {
        let ciImage = CIImage(cgImage: context.base)
        guard let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [:]) else { return }
        let features = detector.features(in: ciImage)
        guard let message = (features.first as? CIQRCodeFeature)?.messageString, !message.isEmpty else {
            NSLog("[Index] 扫码：未检测到二维码")
            return
        }
        Clipboard.copy(text: message)
    }
}

/// 水印：在截图右下角叠加半透明文字后复制到剪贴板。
/// 文字从 UserDefaults 读取（key: index.watermarkText），默认 "Index"。
struct WatermarkAction: CaptureAction {
    let id = ActionID.watermark
    let title = "水印"
    let symbolName = "textformat"
    let scopes: Set<ActionScope> = [.capture]
    let suppressesAutoCopy = true
    let isPrimaryAction = false

    private static let textKey = "index.watermarkText"

    func perform(_ context: CaptureContext) async throws {
        let text = UserDefaults.standard.string(forKey: Self.textKey) ?? "Index"
        guard !text.isEmpty else { return }
        let watermarked = Self.applyWatermark(to: context.rendered(), text: text)
        Clipboard.copy(watermarked)
    }

    private static func applyWatermark(to image: CGImage, text: String) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }

        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let fontSize = max(12.0, Double(height) * 0.04)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(white: 1, alpha: 0.35).cgColor
        ])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))

        let margin: CGFloat = 12
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(
            x: CGFloat(width) - textWidth - margin,
            y: margin + ascent
        )
        CTLineDraw(ctLine, ctx)

        return ctx.makeImage() ?? image
    }
}

/// GIF 录制：框选 → 3 秒自动录制 → 转 GIF → 展示。
struct GifCaptureAction: CaptureAction {
    let id = ActionID.gifCapture
    let title = "GIF"
    let symbolName = "photo.stack"
    let scopes: Set<ActionScope> = [.capture]
    let suppressesAutoCopy = true
    let isPrimaryAction = true

    func perform(_ context: CaptureContext) async throws {
        await MainActor.run {
            // 截图工具条上直接复用已选区域，不再二次框选
            if let region = context.region {
                let center = CGPoint(x: region.midX, y: region.midY)
                let display = NSScreen.screens
                    .compactMap { DisplayInfo(screen: $0) }
                    .first { $0.frame.contains(center) }
                if let display {
                    RecordingCoordinator.shared.startGifDirectly(region: region, display: display)
                    return
                }
            }
            RecordingCoordinator.shared.beginGifCapture()
        }
    }
}

/// 只完成，不做别的。没有按钮，由回车在「完成（不复制）」设置下触发。
struct FinishAction: CaptureAction {
    let id = ActionID.finish
    let title = "完成"
    let symbolName = "checkmark"
    let scopes: Set<ActionScope> = []
    /// 用户明确选择了不碰剪贴板，必须压过全局自动复制开关。
    let suppressesAutoCopy = true

    func perform(_ context: CaptureContext) async throws {
        // 截图已经在协调器里入库了，这里确实什么都不用做。
    }
}

struct RecordAction: CaptureAction {
    let id = ActionID.record
    let title = "录屏"
    let symbolName = "video"
    let scopes: Set<ActionScope> = [.capture]
    let suppressesAutoCopy = true
    let isPrimaryAction = true

    func perform(_ context: CaptureContext) async throws {
        // 截图工具条上直接进录屏：不入库当前选区，避免多一张无用截图
        // 真正的选区由 RecordingCoordinator 的 plain 覆盖层重新框选
        await MainActor.run { RecordingCoordinator.shared.toggle() }
    }
}

struct ScrollCaptureAction: CaptureAction {
    let id = ActionID.scrollCapture
    let title = "长截图"
    let symbolName = "arrow.down.doc"
    let scopes: Set<ActionScope> = [.capture]
    let suppressesAutoCopy = true
    let isPrimaryAction = true

    func perform(_ context: CaptureContext) async throws {
        await MainActor.run { ScrollCaptureController.shared.begin() }
    }
}

extension CaptureActionRegistry {
    /// 在这里登记。顺序即工具条上的显示顺序。
    /// 注入式：装配根（AppDelegate）传全量设置，预览/测试传 `FakeStyleStore`。
    static func registerBuiltins(
        into registry: CaptureActionRegistry,
        styleStore: any StyleStore,
        includePluginActions: Bool = true
    ) {
        // App 启动时由插件分别登记；独立预览/单测没有 PluginHost，默认补齐动作，
        // 保持这条装配 API 能构造一套完整工具条。
        if includePluginActions {
            registry.register(PinAction(capture: styleStore, annotationStyle: styleStore))
            registry.register(RecordAction())
            registry.register(ScrollCaptureAction())
        }
        registry.register(CopyAction())
        registry.register(SaveAction())
        registry.register(CopyTextAction())
        registry.register(AutoMosaicAction())
        registry.register(QrScanAction())
        registry.register(WatermarkAction())
        registry.register(GifCaptureAction())
        registry.register(BugReportAction())
        registry.register(UploadAction(upload: styleStore))
        registry.register(CloseAction())
        registry.register(FinishAction())
    }
}
