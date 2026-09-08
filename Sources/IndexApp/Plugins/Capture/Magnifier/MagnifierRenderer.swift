import AppKit
import CoreText

/// 光标处的放大镜 + 取色读数。
enum MagnifierRenderer {

    static let boxSize: CGFloat = 116
    private static let readoutHeight: CGFloat = 38
    private static let cursorGap: CGFloat = 18

    /// 放大镜会跟随鼠标高频重绘。字体只解析一次，并直接以 CTFont 交给 CoreText，
    /// 避免每一帧都让 NSString/AppKit 把 NSFont attributes 转成 CoreText attributes。
    /// 后者曾在系统字体解析的瞬时异常下向内部字典插入 nil，导致 NSException 直接终止进程。
    private static let hexFont = makeFont(
        uiType: .userFixedPitch,
        size: DS.font11,
        traits: .boldTrait
    )
    private static let coordinateFont = makeFont(uiType: .userFixedPitch, size: DS.font9)
    private static let hintFont = makeFont(uiType: .system, size: DS.font9)

    static var totalSize: CGSize {
        CGSize(width: boxSize, height: boxSize + readoutHeight)
    }

    /// - Parameter cursor: 视图局部坐标。
    static func draw(
        sample: PixelSample,
        at cursor: CGPoint,
        in bounds: CGRect,
        ctx: CGContext
    ) {
        let frame = placement(near: cursor, in: bounds)
        let imageBox = CGRect(
            x: frame.minX,
            y: frame.minY + readoutHeight,
            width: boxSize,
            height: boxSize
        )

        drawBackground(frame)
        drawZoom(sample, in: imageBox, ctx: ctx)
        drawReadout(
            sample,
            in: CGRect(x: frame.minX, y: frame.minY, width: boxSize, height: readoutHeight),
            ctx: ctx
        )
    }

    /// 默认放在光标右下；靠近屏幕边缘时翻到另一侧，永远不出界。
    private static func placement(near cursor: CGPoint, in bounds: CGRect) -> CGRect {
        let size = totalSize
        var x = cursor.x + cursorGap
        var y = cursor.y - cursorGap - size.height

        if x + size.width > bounds.maxX - 6 { x = cursor.x - cursorGap - size.width }
        if y < bounds.minY + 6 { y = cursor.y + cursorGap }

        x = min(max(bounds.minX + 6, x), bounds.maxX - size.width - 6)
        y = min(max(bounds.minY + 6, y), bounds.maxY - size.height - 6)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func drawBackground(_ frame: CGRect) {
        NSColor(calibratedWhite: 0.11, alpha: 0.95).setFill()
        let path = NSBezierPath(roundedRect: frame, xRadius: DS.radiusMedium, yRadius: DS.radiusMedium)
        path.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = DS.hairline
        path.stroke()
    }

    private static func drawZoom(_ sample: PixelSample, in box: CGRect, ctx: CGContext) {
        ctx.saveGState()
        NSBezierPath(roundedRect: box, xRadius: DS.radiusSmall, yRadius: DS.radiusSmall).addClip()

        // 关掉插值，才能看到一格一格的像素 —— 这正是放大镜的意义。
        ctx.interpolationQuality = .none
        ctx.draw(sample.patch, in: box)

        let cell = box.width / CGFloat(sample.patchSize)

        // 像素网格
        if cell >= 4 {
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let grid = NSBezierPath()
            for i in 1..<sample.patchSize {
                let offset = CGFloat(i) * cell
                grid.move(to: CGPoint(x: box.minX + offset, y: box.minY))
                grid.line(to: CGPoint(x: box.minX + offset, y: box.maxY))
                grid.move(to: CGPoint(x: box.minX, y: box.minY + offset))
                grid.line(to: CGPoint(x: box.maxX, y: box.minY + offset))
            }
            grid.lineWidth = 0.5
            grid.stroke()
        }

        // 正中心那一格 —— 取色器取的就是它
        let center = CGRect(
            x: box.midX - cell / 2,
            y: box.midY - cell / 2,
            width: cell,
            height: cell
        )
        NSColor.black.withAlphaComponent(0.9).setStroke()
        let outer = NSBezierPath(rect: center.insetBy(dx: -1, dy: -1))
        outer.lineWidth = DS.hairline
        outer.stroke()
        NSColor.white.setStroke()
        let inner = NSBezierPath(rect: center)
        inner.lineWidth = DS.hairline
        inner.stroke()

        ctx.restoreGState()
    }

    static func drawReadout(_ sample: PixelSample, in box: CGRect, ctx: CGContext) {
        let swatch = NSRect(x: box.minX + 9, y: box.midY - 7, width: 14, height: 14)
        sample.color.nsColor.setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let ring = NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3)
        ring.lineWidth = DS.hairline
        ring.stroke()

        drawText(
            sample.color.hexString,
            font: hexFont,
            color: CGColor(gray: 1, alpha: 1),
            at: CGPoint(x: swatch.maxX + 7, y: box.midY - 1),
            ctx: ctx
        )

        let coords = "\(Int(sample.pixelPoint.x)), \(Int(sample.pixelPoint.y))"
        drawText(
            coords,
            font: coordinateFont,
            color: CGColor(gray: 1, alpha: 0.55),
            at: CGPoint(x: swatch.maxX + 7, y: box.midY - 13),
            ctx: ctx
        )

        let hint = "C 复制色值"
        let hintLine = makeLine(hint, font: hintFont, color: CGColor(gray: 1, alpha: 0.4))
        let hintWidth = CGFloat(CTLineGetTypographicBounds(hintLine, nil, nil, nil))
        drawLine(
            hintLine,
            at: CGPoint(x: box.maxX - hintWidth - 9, y: box.midY - 5),
            ctx: ctx
        )
    }

    private static func makeFont(
        uiType: CTFontUIFontType,
        size: CGFloat,
        traits: CTFontSymbolicTraits = []
    ) -> CTFont {
        // CoreText 文档允许 UI font 查找失败；固定回退保证 attribute 永远有真实字体对象。
        let base = CTFontCreateUIFontForLanguage(uiType, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    private static func makeLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
    }

    private static func drawText(
        _ text: String,
        font: CTFont,
        color: CGColor,
        at point: CGPoint,
        ctx: CGContext
    ) {
        drawLine(makeLine(text, font: font, color: color), at: point, ctx: ctx)
    }

    private static func drawLine(_ line: CTLine, at point: CGPoint, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.textMatrix = .identity
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}
