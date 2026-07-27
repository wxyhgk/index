import AppKit
import CoreGraphics
import CoreImage
import CoreText

/// 美化层（backdrop）的背景预设。`Layer.text` 存 rawValue。
enum BackdropPreset: String, CaseIterable {
    case gradientBlue = "gradient-blue"
    case gradientSunset = "gradient-sunset"
    case gradientMono = "gradient-mono"
    case solid = "solid"

    static let `default`: BackdropPreset = .gradientBlue

    var displayName: String {
        switch self {
        case .gradientBlue: return "蓝紫渐变"
        case .gradientSunset: return "日落渐变"
        case .gradientMono: return "灰黑渐变"
        case .solid: return "纯色"
        }
    }

    /// 渐变两端的颜色；solid 返回 nil（用图层自身的 `color`）。
    var gradientColors: (CGColor, CGColor)? {
        switch self {
        case .gradientBlue:
            return (
                CGColor(srgbRed: 0.31, green: 0.46, blue: 0.98, alpha: 1),
                CGColor(srgbRed: 0.55, green: 0.29, blue: 0.94, alpha: 1)
            )
        case .gradientSunset:
            return (
                CGColor(srgbRed: 0.99, green: 0.56, blue: 0.30, alpha: 1),
                CGColor(srgbRed: 0.94, green: 0.31, blue: 0.60, alpha: 1)
            )
        case .gradientMono:
            return (
                CGColor(srgbRed: 0.24, green: 0.25, blue: 0.28, alpha: 1),
                CGColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1)
            )
        case .solid:
            return nil
        }
    }
}

/// 水印的摆放模式。`WatermarkSpec.mode` 存 rawValue。
enum WatermarkMode: String, Codable, CaseIterable, Identifiable {
    /// 右下角一行，边距 = 字号。
    case corner
    /// 居中斜排，字号 ×1.6。
    case center
    /// 斜向平铺，盖满全图。
    case tile

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .corner: return "右下角"
        case .center: return "居中"
        case .tile: return "平铺"
        }
    }
}

/// 水印层的参数。整体序列化成 JSON 存进 `Layer.text`：
/// `{"mode":"corner","text":"@user"}` —— 复用现有字段，不动 Codable。
struct WatermarkSpec: Codable, Equatable {
    var text: String
    var mode: WatermarkMode

    /// 存进 `Layer.text` 的 JSON。键排序固定，同参数编码结果一致（Layer 是 Equatable）。
    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode(_ json: String) -> WatermarkSpec? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WatermarkSpec.self, from: data)
    }

    /// 造一层**图像像素空间**的水印层：字号 = 图宽 3%（不小于 14px）、描边 1 像素、
    /// 白字（透明度 = `alpha`）。画布空间创建时由 `AnnotationState.toggleWatermark`
    /// 把 fontSize / lineWidth 反除 pixelScale 换到画布单位。
    static func makeLayer(
        text: String, mode: WatermarkMode, alpha: Double, imagePixelWidth: Double
    ) -> Layer {
        var layer = Layer(kind: .watermark, rect: LRect(x: 0, y: 0, w: 0, h: 0))
        layer.text = WatermarkSpec(text: text, mode: mode).encoded
        layer.color = LColor(r: 1, g: 1, b: 1, a: alpha)
        layer.fontSize = max(14, imagePixelWidth * 0.03)
        layer.lineWidth = 1
        return layer
    }
}

/// 外壳层（frame）的参数。`Layer.text` 存 JSON：
/// `{"style":"macos"|"browser","title":"…","url":"…"}`。
/// backdrop 只有一个预设名所以存 rawValue 字符串就够；壳有三个字段，用 JSON。
/// 字段全部可缺省，逐字段容错：解析失败退回 macos 空壳，老数据/坏数据都不至于炸。
struct FrameSpec: Codable, Equatable {
    enum Style: String, Codable, CaseIterable {
        case macos
        case browser

        var displayName: String {
            switch self {
            case .macos: return "macOS 窗口"
            case .browser: return "浏览器"
            }
        }
    }

    var style: Style = .macos
    var title: String = ""
    var url: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? container.decode(Style.self, forKey: .style)) ?? .macos
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
    }

    /// 解析 `Layer.text`。任何失败（空串、坏 JSON、未知 style）都退回 macos 空壳。
    static func parse(_ json: String) -> FrameSpec {
        guard let data = json.data(using: .utf8),
              let spec = try? JSONDecoder().decode(FrameSpec.self, from: data)
        else { return FrameSpec() }
        return spec
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

/// 捕获信息层（captureInfo）的参数。`Layer.text` 存 JSON：
/// `{"fields":["app","url","date"],"app":"Safari 17.4","url":"https://…","date":"2026-07-27 14:30"}`。
/// `fields` 是用户勾选要显示的字段；具体值在**开启效果时烤入**（编辑器/钉图从
/// shot 取，覆盖层从 confirmedWindow 取、URL 留空）—— 和 frame 的元数据填充
/// 同一时机、同一来源。照 `FrameSpec` 的模式逐字段容错：解析失败退回全勾空值，
/// 老数据/坏数据都不至于炸；`fields` 里出现未来版本的未知字段名时逐个丢弃。
struct CaptureInfoSpec: Codable, Equatable {
    enum Field: String, Codable, CaseIterable {
        case app
        case url
        case date

        var displayName: String {
            switch self {
            case .app: return "App"
            case .url: return "网址"
            case .date: return "时间"
            }
        }
    }

    var fields: [Field] = Field.allCases
    var app: String = ""
    var url: String = ""
    var date: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // fields 按裸字符串解，未知字段名逐个丢弃而不是让整个数组失败。
        if let raw = try? container.decode([String].self, forKey: .fields) {
            fields = raw.compactMap(Field.init(rawValue:))
        }
        app = (try? container.decode(String.self, forKey: .app)) ?? ""
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        date = (try? container.decode(String.self, forKey: .date)) ?? ""
    }

    /// 解析 `Layer.text`。任何失败（空串、坏 JSON）都退回全勾空值的缺省参数。
    static func parse(_ json: String) -> CaptureInfoSpec {
        guard let data = json.data(using: .utf8),
              let spec = try? JSONDecoder().decode(CaptureInfoSpec.self, from: data)
        else { return CaptureInfoSpec() }
        return spec
    }

    /// 键排序固定，同参数编码结果一致（Layer 是 Equatable，style 撤销记录靠它判等）。
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    /// 「App 名 + 版本」的一行式描述（如 "Safari 17.4"）。三处注入点共用，
    /// 保证同一份元数据在哪儿开效果都排出同样的字。
    static func appDescription(name: String?, version: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        guard let version, !version.isEmpty else { return name }
        return "\(name) \(version)"
    }
}

/// 把「原图 + 图层数组」渲染成一张图。
/// 原图始终只读；这里产出的是临时结果，只在预览和导出时使用。
enum LayerRenderer {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 只接受图像像素空间的图层 —— 画布空间的图层必须先经 `Layers.projected` 换算。
    static func render(base: CGImage, layers: Layers<ImageSpace>) -> CGImage {
        let layers = layers.elements
        guard !layers.isEmpty else { return base }

        // 1. 先把马赛克作用到底图上（它是像素级操作，必须在绘制矢量图层之前）。
        let pixelated = layers.filter { $0.kind == .pixelate }
        var working = base
        if !pixelated.isEmpty {
            working = applyPixelate(to: base, regions: pixelated.map(\.rect.cg)) ?? base
        }

        let width = working.width
        let height = working.height

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }

        ctx.draw(working, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 翻转成左上原点，与图层存储的坐标系一致。
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        drawVectors(layers, in: ctx)

        guard var result = ctx.makeImage() else { return base }

        // 2. 裁剪永远最后应用，且只影响输出，不影响存储。
        if let crop = layers.last(where: { $0.kind == .crop }) {
            let r = crop.rect.cg.integral.intersection(
                CGRect(x: 0, y: 0, width: width, height: height)
            )
            if r.width >= 1, r.height >= 1, let cropped = result.cropping(to: r) {
                result = cropped
            }
        }

        // 3. 水印在裁剪之后、美化之前盖上：位置相对裁剪后的成品，
        //    且美化的留白/背景不带水印。预览也画（见 `AnnotationRenderer`）。
        if let watermark = layers.last(where: { $0.kind == .watermark }) {
            result = applyWatermark(to: result, layer: watermark) ?? result
        }

        // 4. 捕获信息在水印之后、带壳之前：成品底部接一条元数据信息栏。
        //    信息栏属于内容的一部分（在壳之内）—— 套壳时它和截图一起被
        //    标题栏 + 圆角包住，backdrop 再连壳一起垫底。它同样只存在于导出路径。
        if let info = layers.last(where: { $0.kind == .captureInfo }) {
            result = applyCaptureInfo(to: result, layer: info) ?? result
        }

        // 5. 带壳在捕获信息之后套上：内容上方接标题栏（浏览器壳再加地址栏）。
        //    壳属于内容的一部分，所以排在美化之前 —— 叠加时壳在内、背景在外，
        //    backdrop 连壳一起垫底。它同样只存在于导出路径。
        if let frame = layers.last(where: { $0.kind == .frame }) {
            result = applyFrame(to: result, layer: frame) ?? result
        }

        // 6. 美化最后套上：先裁出内容（可能已带壳），再把内容垫到背景上。
        //    它只存在于导出路径 —— 预览（AnnotationRenderer / LayerCanvas）跳过
        //    backdrop，编辑时画布尺寸不变。
        if let backdrop = layers.last(where: { $0.kind == .backdrop }) {
            result = applyBackdrop(to: result, layer: backdrop) ?? result
        }

        return result
    }

    // MARK: - 水印

    /// 同尺寸重绘一遍，把水印盖在最上层。
    private static func applyWatermark(to image: CGImage, layer: Layer) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // 翻成左上原点，与 drawWatermark 的假设一致。
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        drawWatermark(layer, in: ctx, canvas: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// 画水印文字。上下文必须**已经**是「左上原点、Y 向下」；`canvas` 是成品在
    /// 当前空间里的范围 —— 导出时是整张（裁剪后的）图，覆盖层预览时是选区。
    ///
    /// 白填充 + 细黑描边（`.fillStroke`），深浅底上都可见；透明度取 `layer.color.a`。
    /// 导出和实时预览共用这一份代码（`AnnotationRenderer` 直接调它），所见即所得。
    static func drawWatermark(_ layer: Layer, in ctx: CGContext, canvas: CGRect) {
        guard canvas.width >= 1, canvas.height >= 1,
              let spec = WatermarkSpec.decode(layer.text),
              !spec.text.isEmpty else { return }

        // 居中模式醒目一档：字号 ×1.6。
        let fontSize = max(1, layer.fontSize * (spec.mode == .center ? 1.6 : 1))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributed = NSAttributedString(string: spec.text, attributes: [
            .font: font,
            // 填充/描边色从上下文取，CTLine 才能画出 fillStroke 双色文字。
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: canvas)
        ctx.setTextDrawingMode(.fillStroke)
        ctx.setFillColor(layer.color.cg)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: layer.color.a))
        ctx.setLineWidth(max(0.5, layer.lineWidth))
        // 上下文当前是翻转的（左上原点），文字需要再翻一次才不会上下颠倒。
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        switch spec.mode {
        case .corner:
            // 右下角，边距 = 字号。
            let margin = layer.fontSize
            ctx.textPosition = CGPoint(
                x: canvas.maxX - margin - textWidth,
                y: canvas.maxY - margin - descent
            )
            CTLineDraw(line, ctx)

        case .center:
            // 居中斜排。Y 向下的空间里 -30° 视觉上是左低右高的经典水印角度。
            ctx.translateBy(x: canvas.midX, y: canvas.midY)
            ctx.rotate(by: -.pi / 6)
            ctx.textPosition = CGPoint(x: -textWidth / 2, y: (ascent - descent) / 2)
            CTLineDraw(line, ctx)

        case .tile:
            // 斜向平铺：绕中心旋转 -30°，按网格重复；覆盖半径取对角线，
            // 保证旋转后四角也铺满。隔行错开半个周期，视觉上更均匀。
            ctx.translateBy(x: canvas.midX, y: canvas.midY)
            ctx.rotate(by: -.pi / 6)
            let step = max(textWidth, fontSize) * 1.6
            let radius = hypot(canvas.width, canvas.height) / 2 + step
            var y = -radius
            var row = 0
            while y <= radius {
                var x = -radius + (row % 2 == 0 ? 0 : step / 2)
                while x <= radius {
                    ctx.textPosition = CGPoint(
                        x: x - textWidth / 2,
                        y: y + (ascent - descent) / 2
                    )
                    CTLineDraw(line, ctx)
                    x += step
                }
                y += step
                row += 1
            }
        }
    }

    // MARK: - 美化（背景垫底 / 圆角 / 阴影）

    /// 输出画布扩大为 原尺寸 + 2×padding：先铺渐变/纯色背景，
    /// 再把内容按圆角裁剪画在中央，底下带一层投影。
    private static func applyBackdrop(to image: CGImage, layer: Layer) -> CGImage? {
        let padding = max(0, layer.lineWidth)
        let width = image.width + Int(padding.rounded()) * 2
        let height = image.height + Int(padding.rounded()) * 2

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let preset = BackdropPreset(rawValue: layer.text) ?? .default
        drawBackdropBackground(preset, solidColor: layer.color.cg, in: ctx, rect: canvas)

        let contentRect = CGRect(
            x: padding,
            y: padding,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        let radius = min(
            max(0, layer.fontSize),
            min(contentRect.width, contentRect.height) / 2
        )
        let path = CGPath(
            roundedRect: contentRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        // 投影：先用带阴影的实心圆角矩形打底（阴影由它投出），再在其上画内容。
        // 上下文是 CG 默认的左下原点，offset y 取负让阴影在视觉上落向下方。
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -padding / 8),
            blur: max(4, padding / 3),
            color: CGColor(gray: 0, alpha: 0.3)
        )
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // 内容按圆角裁剪画在中央。
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: contentRect)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private static func drawBackdropBackground(
        _ preset: BackdropPreset,
        solidColor: CGColor,
        in ctx: CGContext,
        rect: CGRect
    ) {
        if preset == .solid {
            ctx.setFillColor(solidColor)
            ctx.fill(rect)
            return
        }
        guard let (from, to) = preset.gradientColors,
              let gradient = CGGradient(
                  colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                  colors: [from, to] as CFArray,
                  locations: [0, 1]
              )
        else {
            ctx.setFillColor(solidColor)
            ctx.fill(rect)
            return
        }
        // 对角线方向：左上 → 右下（视觉上；上下文是左下原点，所以取 maxY → minY）。
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // MARK: - 捕获信息（底部元数据信息栏）

    /// 成品底部接一条信息栏：深色半透明底、白字 caption 排版 ——
    /// 左侧 App 名+版本、中间网址（有则显示、中间截断）、右侧日期时间。
    /// 只勾了部分字段（或值为空，如覆盖层的 URL 还没回填）就只排那些，均匀分布：
    /// 一项居中、两项靠两端、三项左/中/右。输出画布宽度不变，高度 = 内容 + 信息栏。
    ///
    /// 结构尺寸（栏高 28、字号 11、边距 12）全部乘 `layer.lineWidth` ——
    /// 创建时烤进去的像素倍率（见 `AnnotationState.toggleCaptureInfo`），
    /// 语义同 frame，2x 图上的信息栏和 1x 图视觉大小一致。
    private static func applyCaptureInfo(to image: CGImage, layer: Layer) -> CGImage? {
        let scale = layer.lineWidth > 0 ? layer.lineWidth : 1
        let spec = CaptureInfoSpec.parse(layer.text)

        // 勾选了且烤入值非空才排；URL 中间截断（首尾都有信息量），其余尾部省略。
        let items: [(text: String, truncation: CTLineTruncationType)] = spec.fields
            .compactMap { field in
                let value: String
                switch field {
                case .app: value = spec.app
                case .url: value = spec.url
                case .date: value = spec.date
                }
                guard !value.isEmpty else { return nil }
                return (value, field == .url ? .middle : .end)
            }
        guard !items.isEmpty else { return image }

        let barHeight = (28 * scale).rounded()
        let width = image.width
        let height = image.height + Int(barHeight)

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 上下文是 CG 默认的左下原点：内容在上、信息栏贴底。
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(
            x: 0, y: barHeight, width: CGFloat(width), height: CGFloat(image.height)
        ))

        let bar = CGRect(x: 0, y: 0, width: CGFloat(width), height: barHeight)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.75))
        ctx.fill(bar)

        let font = NSFont.systemFont(ofSize: 11 * scale, weight: .medium)
        let margin = 12 * scale
        let usable = bar.width - margin * 2
        guard usable > font.pointSize else { return ctx.makeImage() }

        // 均匀分布：锚点按 0…1 等分排开，首项左对齐、末项右对齐、其余居中；
        // 单独一项时锚在正中。每项最多占一个等分槽位，超长按各自策略截断。
        let slotWidth = usable / CGFloat(items.count) - (items.count > 1 ? 8 * scale : 0)
        for (index, item) in items.enumerated() {
            let anchorX: CGFloat
            let alignment: CaptureInfoAlignment
            if items.count == 1 {
                anchorX = bar.midX
                alignment = .center
            } else {
                anchorX = margin + usable * CGFloat(index) / CGFloat(items.count - 1)
                alignment = index == 0 ? .leading
                    : (index == items.count - 1 ? .trailing : .center)
            }
            drawCaptureInfoItem(
                item.text,
                font: font,
                truncation: item.truncation,
                maxWidth: slotWidth,
                anchorX: anchorX,
                alignment: alignment,
                midY: bar.midY,
                in: ctx
            )
        }

        return ctx.makeImage()
    }

    private enum CaptureInfoAlignment { case leading, center, trailing }

    /// 信息栏里的一段白字：先按 maxWidth 截断，再按对齐方式相对锚点排。
    /// 和 `drawFrameText` 同一套 CT 画法，多一个「右对齐」——
    /// 截断后的实际宽度才是排右侧那项要减去的宽度，所以不能直接复用。
    /// 上下文是左下原点（信息栏的画布没有翻转），CT 按 identity 直接画。
    private static func drawCaptureInfoItem(
        _ text: String,
        font: NSFont,
        truncation: CTLineTruncationType,
        maxWidth: CGFloat,
        anchorX: CGFloat,
        alignment: CaptureInfoAlignment,
        midY: CGFloat,
        in ctx: CGContext
    ) {
        guard maxWidth > font.pointSize, !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        var line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth {
            let token = CTLineCreateWithAttributedString(
                NSAttributedString(string: "…", attributes: attributes)
            )
            line = CTLineCreateTruncatedLine(line, Double(maxWidth), truncation, token) ?? line
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        let x: CGFloat
        switch alignment {
        case .leading: x = anchorX
        case .center: x = anchorX - width / 2
        case .trailing: x = anchorX - width
        }

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: midY - (ascent - descent) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - 带壳（macOS 窗口壳 / 浏览器壳）

    /// 把内容套进窗口壳：上方接一条标题栏（红绿灯 + 居中标题），浏览器壳在
    /// 标题栏下再加一条地址栏（胶囊 + 锁 + URL），整体圆角裁剪。
    /// 输出画布宽度不变，高度 = 内容 + 壳。
    ///
    /// 壳的所有结构尺寸乘 `layer.lineWidth` —— 创建时烤进去的像素倍率
    /// （见 `AnnotationState.toggleFrame`），2x 图上的壳和 1x 图视觉大小一致，
    /// 线条落在整像素上，Retina 下不发虚。纯矢量绘制，零素材文件；只做浅色外观。
    private static func applyFrame(to image: CGImage, layer: Layer) -> CGImage? {
        let scale = layer.lineWidth > 0 ? layer.lineWidth : 1
        let spec = FrameSpec.parse(layer.text)

        let titleBarHeight = 28 * scale
        let urlBarHeight = spec.style == .browser ? 32 * scale : 0
        let chromeHeight = (titleBarHeight + urlBarHeight).rounded()

        let width = image.width
        let height = image.height + Int(chromeHeight)

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 整体圆角裁剪。上下文是 CG 默认的左下原点：内容在下、壳在上。
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let radius = min(10 * scale, canvas.width / 2, canvas.height / 2)
        ctx.addPath(CGPath(
            roundedRect: canvas, cornerWidth: radius, cornerHeight: radius, transform: nil
        ))
        ctx.clip()

        // 内容铺在底部。
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(
            x: 0, y: 0, width: CGFloat(width), height: CGFloat(image.height)
        ))

        // 标题栏：浅灰垂直渐变（上亮下暗）+ 底边发丝分隔线。
        let titleBar = CGRect(
            x: 0, y: canvas.maxY - titleBarHeight,
            width: canvas.width, height: titleBarHeight
        )
        drawFrameBar(in: ctx, rect: titleBar, topGray: 0.96, bottomGray: 0.90, hairline: scale)

        // 左侧红黄绿三个圆点（macOS 原生配色）。
        let diameter = 12 * scale
        let gap = 8 * scale
        var lightX = 12 * scale + diameter / 2
        for color in [
            CGColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
            CGColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
            CGColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)
        ] {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(
                x: lightX - diameter / 2,
                y: titleBar.midY - diameter / 2,
                width: diameter,
                height: diameter
            ))
            lightX += diameter + gap
        }

        // 标题居中（有 title 才画）。左右都躲开红绿灯的宽度，超长尾部省略。
        if !spec.title.isEmpty {
            let inset = 12 * scale + (diameter + gap) * 3 + 8 * scale
            drawFrameText(
                spec.title,
                font: NSFont.systemFont(ofSize: 13 * scale, weight: .semibold),
                gray: 0.30,
                truncation: .end,
                maxWidth: titleBar.width - inset * 2,
                centerX: titleBar.midX,
                leftX: 0,
                midY: titleBar.midY,
                in: ctx
            )
        }

        // 浏览器壳：标题栏下一条地址栏 —— 圆角胶囊底 + 小锁 + URL。
        // 无 URL 时画空胶囊（覆盖层开壳时 URL 还没异步回填回来是常态）。
        if spec.style == .browser {
            let urlBar = CGRect(
                x: 0, y: titleBar.minY - urlBarHeight,
                width: canvas.width, height: urlBarHeight
            )
            drawFrameBar(in: ctx, rect: urlBar, topGray: 0.93, bottomGray: 0.93, hairline: scale)

            let capsule = urlBar.insetBy(dx: 12 * scale, dy: 5 * scale)
            let capsulePath = CGPath(
                roundedRect: capsule,
                cornerWidth: capsule.height / 2,
                cornerHeight: capsule.height / 2,
                transform: nil
            )
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(capsulePath)
            ctx.fillPath()
            ctx.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
            ctx.setLineWidth(scale)
            ctx.addPath(capsulePath)
            ctx.strokePath()

            if !spec.url.isEmpty {
                let lockSize = 10 * scale
                let lockX = capsule.minX + 10 * scale
                drawLock(in: ctx, leftX: lockX, midY: capsule.midY, size: lockSize, scale: scale)
                let textLeft = lockX + lockSize + 6 * scale
                drawFrameText(
                    spec.url,
                    font: NSFont.systemFont(ofSize: 12 * scale, weight: .regular),
                    gray: 0.35,
                    truncation: .middle,
                    maxWidth: capsule.maxX - 10 * scale - textLeft,
                    centerX: nil,
                    leftX: textLeft,
                    midY: capsule.midY,
                    in: ctx
                )
            }
        }

        return ctx.makeImage()
    }

    /// 壳的一条横栏：浅灰垂直渐变（同灰则纯色）+ 压在底边的发丝分隔线。
    private static func drawFrameBar(
        in ctx: CGContext,
        rect: CGRect,
        topGray: CGFloat,
        bottomGray: CGFloat,
        hairline: CGFloat
    ) {
        ctx.saveGState()
        if topGray == bottomGray {
            ctx.setFillColor(CGColor(gray: topGray, alpha: 1))
            ctx.fill(rect)
        } else if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(gray: topGray, alpha: 1),
                CGColor(gray: bottomGray, alpha: 1)
            ] as CFArray,
            locations: [0, 1]
        ) {
            ctx.clip(to: rect)
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY),
                options: []
            )
        }
        ctx.restoreGState()

        ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: hairline))
    }

    /// 壳里的一行灰字：先按 maxWidth 截断（标题尾部省略、URL 中间省略），
    /// `centerX` 非 nil 时居中排，否则从 `leftX` 起排。
    /// 上下文是左下原点（壳的画布**没有**翻转），CT 按 identity 直接画。
    private static func drawFrameText(
        _ text: String,
        font: NSFont,
        gray: CGFloat,
        truncation: CTLineTruncationType,
        maxWidth: CGFloat,
        centerX: CGFloat?,
        leftX: CGFloat,
        midY: CGFloat,
        in ctx: CGContext
    ) {
        guard maxWidth > font.pointSize, !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: gray, alpha: 1)
        ]
        var line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth {
            let token = CTLineCreateWithAttributedString(
                NSAttributedString(string: "…", attributes: attributes)
            )
            line = CTLineCreateTruncatedLine(line, Double(maxWidth), truncation, token) ?? line
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(
            x: centerX.map { $0 - width / 2 } ?? leftX,
            y: midY - (ascent - descent) / 2
        )
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 简笔小锁：下半是圆角方块锁体，上半是半圆锁梁。纯矢量，不描 SF Symbol。
    /// `leftX` 是锁体左缘、`midY` 是整个字形的垂直中心、`size` 是总高。
    private static func drawLock(
        in ctx: CGContext,
        leftX: CGFloat,
        midY: CGFloat,
        size: CGFloat,
        scale: CGFloat
    ) {
        let gray = CGColor(gray: 0.45, alpha: 1)
        let bodyWidth = size * 0.95
        let bodyHeight = size * 0.58
        let body = CGRect(x: leftX, y: midY - size / 2, width: bodyWidth, height: bodyHeight)

        ctx.saveGState()
        ctx.setFillColor(gray)
        ctx.addPath(CGPath(
            roundedRect: body, cornerWidth: 1.5 * scale, cornerHeight: 1.5 * scale, transform: nil
        ))
        ctx.fillPath()

        // 锁梁：从锁体顶边伸出的半圆（左下原点，逆时针 0→π 经过顶部）。
        ctx.setStrokeColor(gray)
        ctx.setLineWidth(1.2 * scale)
        ctx.addArc(
            center: CGPoint(x: body.midX, y: body.maxY),
            radius: bodyWidth * 0.32,
            startAngle: 0,
            endAngle: .pi,
            clockwise: false
        )
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 在**已经是左上原点、Y 向下**的上下文里绘制矢量图层。
    ///
    /// 离屏导出和截图覆盖层的实时预览共用这一份代码 —— 所见即所得靠的就是这个，
    /// 而不是两套各自维护的绘制逻辑。
    static func drawVectors(_ layers: [Layer], in ctx: CGContext) {
        // 聚光灯画在其余矢量层**之下**：所有聚光灯层合并成一次遮罩绘制，
        // 多个聚光灯 = 多个亮区，标注本身不被压暗。
        let spotlights = layers.filter { $0.kind == .spotlight }
        if !spotlights.isEmpty {
            drawSpotlightMask(spotlights, in: ctx)
        }
        for layer in layers where layer.kind != .pixelate && layer.kind != .crop
            && layer.kind != .spotlight && layer.kind != .backdrop
            && layer.kind != .watermark && layer.kind != .frame
            && layer.kind != .captureInfo {
            draw(layer, in: ctx)
        }
    }

    /// 把整张小图马赛克化。覆盖层用它给每个马赛克图层预先算好贴片。
    static func pixelated(_ image: CGImage) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let blockSize = max(6, min(width, height) / 12)

        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(blockSize, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: width / 2, y: height / 2), forKey: kCIInputCenterKey)

        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(
            output,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }

    // MARK: - 单个图层

    private static func draw(_ layer: Layer, in ctx: CGContext) {
        let rect = layer.rect.cg

        switch layer.kind {
        case .rect:
            ctx.setStrokeColor(layer.color.cg)
            ctx.setLineWidth(layer.lineWidth)
            ctx.stroke(rect)

        case .ellipse:
            ctx.setStrokeColor(layer.color.cg)
            ctx.setLineWidth(layer.lineWidth)
            ctx.strokeEllipse(in: rect)

        case .highlight:
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(layer.color.cg)
            ctx.fill(rect)
            ctx.restoreGState()

        case .line:
            ctx.setStrokeColor(layer.color.cg)
            ctx.setLineWidth(layer.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: layer.rect.start)
            ctx.addLine(to: layer.rect.end)
            ctx.strokePath()

        case .arrow:
            drawArrow(from: layer.rect.start, to: layer.rect.end, layer: layer, in: ctx)

        case .text:
            drawText(layer, in: ctx)

        case .counter:
            drawCounter(layer, in: ctx)

        case .dimension:
            drawDimension(layer, in: ctx)

        case .pixelate, .crop, .spotlight, .backdrop, .watermark, .frame, .captureInfo:
            break   // 已在别处处理
        }
    }

    /// 测量标注。两种形态，由 `AnnotationState.prepareDimension` 在生成时定下：
    ///   · 矩形：细边框 + 四边中点向外的短刻度线，中央挂 `W × H px` 胶囊标签
    ///   · 单维（薄轴已被吸附成 0）：双箭头线段，标签只有长度，横线标签在上、竖线在右
    /// 数值用 `layer.text`（生成时按画布→像素倍率烤好）；空则退回矩形自身尺寸 ——
    /// 图像像素空间里两者本就相等。
    private static func drawDimension(_ layer: Layer, in ctx: CGContext) {
        let rect = layer.rect.cg.standardized
        guard rect.width >= 1 || rect.height >= 1 else { return }

        // 「细」相对当前空间：lineWidth 随投影缩放，边框在屏幕上始终约 1pt。
        let hairline = max(1, layer.lineWidth / 4)
        let singleAxis = min(rect.width, rect.height) < 1

        ctx.saveGState()
        ctx.setStrokeColor(layer.color.cg)
        ctx.setLineWidth(hairline)

        if singleAxis {
            let horizontal = rect.width >= rect.height
            drawDoubleArrow(
                from: horizontal
                    ? CGPoint(x: rect.minX, y: rect.midY)
                    : CGPoint(x: rect.midX, y: rect.minY),
                to: horizontal
                    ? CGPoint(x: rect.maxX, y: rect.midY)
                    : CGPoint(x: rect.midX, y: rect.maxY),
                lineWidth: hairline,
                in: ctx
            )
        } else {
            ctx.stroke(rect)
            let tick = 4 * hairline
            for (a, b) in [
                (CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY - tick)),
                (CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY + tick)),
                (CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.minX - tick, y: rect.midY)),
                (CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX + tick, y: rect.midY))
            ] {
                ctx.move(to: a)
                ctx.addLine(to: b)
            }
            ctx.strokePath()
        }
        ctx.restoreGState()

        var text = layer.text
        if text.isEmpty {
            let w = Int(rect.width.rounded())
            let h = Int(rect.height.rounded())
            text = singleAxis ? "\(max(w, h)) px" : "\(w) × \(h) px"
        }
        drawDimensionLabel(
            text,
            layer: layer,
            rect: rect,
            singleAxis: singleAxis,
            gap: 3 * hairline,
            in: ctx
        )
    }

    /// 双箭头线段：主干 + 两端向内张开的 V 形箭头。
    private static func drawDoubleArrow(
        from a: CGPoint, to b: CGPoint, lineWidth: CGFloat, in ctx: CGContext
    ) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 1 else { return }
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = min(length / 3, max(5, lineWidth * 5))
        let spread = CGFloat.pi / 6

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.move(to: a)
        ctx.addLine(to: b)
        // back 指向线段内侧：箭头的两翼从端点往里张开。
        for (tip, back) in [(a, angle), (b, angle + .pi)] {
            for side in [-spread, spread] {
                ctx.move(to: tip)
                ctx.addLine(to: CGPoint(
                    x: tip.x + cos(back + side) * head,
                    y: tip.y + sin(back + side) * head
                ))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 尺寸标签：白字黑底胶囊。矩形模式挂在中央；横线在线上方、竖线在线右侧。
    private static func drawDimensionLabel(
        _ text: String,
        layer: Layer,
        rect: CGRect,
        singleAxis: Bool,
        gap: CGFloat,
        in ctx: CGContext
    ) {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: layer.fontSize * 0.6, weight: .semibold
        )
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let padX = font.pointSize * 0.5
        let padY = font.pointSize * 0.25
        let size = CGSize(
            width: textWidth + padX * 2,
            height: ascent + descent + padY * 2
        )

        let center: CGPoint
        if !singleAxis {
            center = CGPoint(x: rect.midX, y: rect.midY)
        } else if rect.width >= rect.height {
            center = CGPoint(x: rect.midX, y: rect.midY - size.height / 2 - gap)
        } else {
            center = CGPoint(x: rect.midX + size.width / 2 + gap, y: rect.midY)
        }
        let box = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.72))
        ctx.addPath(CGPath(
            roundedRect: box,
            cornerWidth: size.height / 2,
            cornerHeight: size.height / 2,
            transform: nil
        ))
        ctx.fillPath()
        // 上下文当前是翻转的（左上原点），文字需要再翻一次才不会上下颠倒。
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(
            x: box.minX + padX,
            y: center.y + (ascent - descent) / 2
        )
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 聚光灯遮罩：整个可绘制区域铺一层半透明黑，再把每个聚光灯矩形挖亮。
    /// 用透明图层 + destinationOut 挖洞，而不是 even-odd —— 两个聚光灯重叠时
    /// even-odd 会把交集重新填黑，挖洞则不管怎么叠都是亮的。
    private static func drawSpotlightMask(_ spotlights: [Layer], in ctx: CGContext) {
        // 上下文此刻已是图层坐标系；裁剪盒就是「当前可见的画布范围」：
        // 离屏导出时是整张图，覆盖层预览时是选区。
        let canvas = ctx.boundingBoxOfClipPath
        guard !canvas.isEmpty else { return }

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(canvas)
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for layer in spotlights {
            let r = layer.rect.cg
            if r.width >= 1, r.height >= 1 {
                ctx.fill(r)
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// 序号徽章：实心圆 + 白色粗体数字居中。`rect` 是圆的外接矩形（左上原点），
    /// 字号从圆径推导，两位数也放得下。
    private static func drawCounter(_ layer: Layer, in ctx: CGContext) {
        let rect = layer.rect.cg
        guard rect.width >= 1, rect.height >= 1 else { return }

        ctx.setFillColor(layer.color.cg)
        ctx.fillEllipse(in: rect)

        guard !layer.text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: rect.height * 0.52, weight: .bold)
        let attributed = NSAttributedString(string: layer.text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        ctx.saveGState()
        // 上下文当前是翻转的（左上原点），文字需要再翻一次才不会上下颠倒。
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(
            x: rect.midX - width / 2,
            y: rect.midY + (ascent - descent) / 2
        )
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawArrow(from a: CGPoint, to b: CGPoint, layer: Layer, in ctx: CGContext) {
        let width: CGFloat = CGFloat(layer.lineWidth)
        let headLength: CGFloat = max(12, width * 4)
        let angle: CGFloat = atan2(b.y - a.y, b.x - a.x)
        let distance: CGFloat = hypot(b.x - a.x, b.y - a.y)
        guard distance > 1 else { return }

        // 主干缩短一个箭头长度，避免线头戳出箭尖。
        let shaftEnd = CGPoint(
            x: b.x - cos(angle) * headLength * 0.75,
            y: b.y - sin(angle) * headLength * 0.75
        )

        ctx.setStrokeColor(layer.color.cg)
        ctx.setFillColor(layer.color.cg)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.move(to: a)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        let spread = CGFloat.pi / 7
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(
            x: b.x - cos(angle - spread) * headLength,
            y: b.y - sin(angle - spread) * headLength
        ))
        ctx.addLine(to: CGPoint(
            x: b.x - cos(angle + spread) * headLength,
            y: b.y - sin(angle + spread) * headLength
        ))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawText(_ layer: Layer, in ctx: CGContext) {
        guard !layer.text.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: layer.fontSize, weight: .semibold)
        let attributed = NSAttributedString(string: layer.text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: layer.color.cg) ?? .systemRed
        ])
        let line = CTLineCreateWithAttributedString(attributed)

        ctx.saveGState()
        // 上下文当前是翻转的（左上原点），文字需要再翻一次才不会上下颠倒。
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        ctx.textPosition = CGPoint(x: layer.rect.x, y: layer.rect.y + ascent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - 马赛克

    private static func applyPixelate(to image: CGImage, regions: [CGRect]) -> CGImage? {
        let extentHeight = CGFloat(image.height)
        var current = CIImage(cgImage: image)

        for region in regions {
            let r = region.integral
            guard r.width >= 2, r.height >= 2 else { continue }

            // CIImage 是左下原点，图层坐标是左上原点，这里翻过来。
            let ciRect = CGRect(
                x: r.origin.x,
                y: extentHeight - r.maxY,
                width: r.width,
                height: r.height
            )

            let scale = max(6, min(r.width, r.height) / 12)
            guard let filter = CIFilter(name: "CIPixellate") else { continue }
            filter.setValue(current, forKey: kCIInputImageKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            filter.setValue(CIVector(x: ciRect.midX, y: ciRect.midY), forKey: kCIInputCenterKey)
            guard let output = filter.outputImage else { continue }

            // 只把马赛克结果贴回选定区域。
            current = output.cropped(to: ciRect).composited(over: current)
        }

        return ciContext.createCGImage(
            current,
            from: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
    }
}
