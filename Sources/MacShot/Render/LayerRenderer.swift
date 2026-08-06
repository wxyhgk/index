import AppKit
import CoreGraphics
import CoreImage
import CoreText

// 效果层的参数模型（BackdropPreset / WatermarkSpec / FrameSpec / CaptureInfoSpec）
// 在 `Annotation/EffectSpecs.swift` —— 它们是 `Layer.text` 的序列化格式，
// 和 Layer 同层；这里只留绘制。

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
            working = applyPixelate(to: base, layers: pixelated) ?? base
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

        // 3. 效果层在裁剪之后按注册表次序套上（水印 → 捕获信息 → 外壳 → 美化）：
        //    水印位置相对裁剪后的成品、且美化的留白不带水印；信息栏和壳属于
        //    内容的一部分（在壳/背景之内）；美化最后连壳一起垫底。
        //    次序的唯一定义在 `EffectRegistry.ordered`。每种效果和
        //    `AnnotationState.toggleEffect` 一样只认最后一层（单例语义）。
        for descriptor in EffectRegistry.ordered {
            if let layer = layers.last(where: { $0.kind == descriptor.kind }) {
                result = applyEffect(descriptor.kind, to: result, layer: layer) ?? result
            }
        }

        return result
    }

    /// 效果层的绘制分发。除水印外只存在于导出路径 —— 预览
    /// （`AnnotationRenderer` / LayerCanvas）按描述符的 `previewDraw` 决定画不画，
    /// 编辑时画布尺寸不变。
    private static func applyEffect(
        _ kind: Layer.Kind, to image: CGImage, layer: Layer
    ) -> CGImage? {
        switch kind {
        case .watermark: return applyWatermark(to: image, layer: layer)
        case .captureInfo: return applyCaptureInfo(to: image, layer: layer)
        case .frame: return applyFrame(to: image, layer: layer)
        case .backdrop: return applyBackdrop(to: image, layer: layer)
        default: return nil
        }
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
        let spec = BackdropSpec.parse(layer.text)
        let preset = spec.backdropPreset
        // 透明档什么都不填：位图初始就是全透明，留白处最终只剩投影。
        if preset.fillsBackground {
            drawBackdropBackground(preset, solidColor: layer.color.cg, in: ctx, rect: canvas)
        }

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
        //
        // 三个参数都可由设置调节（`BackdropSpec`）；旧图层没有这些字段，
        // 退回从前按 padding 推导的那套，观感不变。
        let shadowBlur = spec.shadowRadius ?? max(4, padding / 3)
        let shadowAlpha = spec.shadowAlpha ?? 0.3
        let shadowColor = spec.shadowColor.map { color -> CGColor in
            CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: shadowAlpha)
        } ?? CGColor(gray: 0, alpha: shadowAlpha)

        ctx.saveGState()
        ctx.setShadow(
            // 位移跟着模糊量走，而不是跟着 padding —— 留白很大而阴影很淡时，
            // 按 padding 推位移会把阴影推出内容之外，看着像图片没对齐。
            offset: CGSize(width: 0, height: -shadowBlur / 3),
            blur: shadowBlur,
            color: shadowColor
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
    /// 创建时烤进去的像素倍率（见 `EffectRegistry.captureInfo`），
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
    /// （见 `EffectRegistry.frame`），2x 图上的壳和 1x 图视觉大小一致，
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
    /// 矢量层的绘制编排。**这里不认识任何一种具体图层** ——
    /// 画什么由工具描述符自己说了算（`AnnotationToolDescriptor.draw`）。
    static func drawVectors(_ layers: [Layer], in ctx: CGContext) {
        // 先画声明了「合并绘制」的那些，它们在其余矢量层**之下**
        // （聚光灯：多个亮区合成一张遮罩，标注本身不被压暗）。
        for descriptor in ToolRegistry.descriptors where descriptor.drawsMerged {
            let group = layers.filter { $0.kind == descriptor.tool.layerKind }
            if !group.isEmpty {
                descriptor.drawMerged(group, in: ctx)
            }
        }
        // 逐层绘制。效果层（kind.isEffect）没有画布形体，在注册表里也查不到描述符 ——
        // 它们在 `render` 的效果编排里按 `EffectRegistry` 的次序套用。
        // 马赛克与裁剪的描述符不实现 draw（管线的一、二两步才是它们的归宿）。
        for layer in layers where !layer.kind.isEffect {
            ToolRegistry.descriptor(for: layer.kind)?.draw(layer, in: ctx)
        }
    }

    /// 把整张小图马赛克化。覆盖层用它给每个马赛克图层预先算好贴片。
    static func pixelated(_ image: CGImage, blockScale: Double = 1) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let blockSize = max(6, min(width, height) / 12 * blockScale)

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

    // 逐层绘制已经全部搬进各工具的描述符（`Annotation/Tools/`）——
    // 这里从前是一个 `switch layer.kind` 加七个私有绘制函数，
    // 每加一种标注就要回来改一次。
    // MARK: - 马赛克

    private static func applyPixelate(to image: CGImage, layers: [Layer]) -> CGImage? {
        let extentHeight = CGFloat(image.height)
        var current = CIImage(cgImage: image)

        for layer in layers {
            let r = layer.rect.cg.integral
            guard r.width >= 2, r.height >= 2 else { continue }

            // CIImage 是左下原点，图层坐标是左上原点，这里翻过来。
            let ciRect = CGRect(
                x: r.origin.x,
                y: extentHeight - r.maxY,
                width: r.width,
                height: r.height
            )

            // blockScale 是相对默认颗粒的倍率；旧图层没有这个字段（nil）→ 1.0 → 与从前一致。
            let scale = max(6, min(r.width, r.height) / 12 * (layer.blockScale ?? 1))
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
