import AppKit
import CoreText

/// 矩形的 8 个调整控制点，外加「内部」用于整体拖动。
///
/// 选区调整（`SelectionModel`）和标注图层缩放（`AnnotationState`）共用同一套几何：
/// `point(in:)` 给出控制点位置，`apply(delta:to:)` 把拖拽位移换算成新矩形，
/// 拖过对边时自动翻转。几何只认 min/max —— Y 向上（AppKit 全局）和
/// Y 向下（标注画布）都成立：命中与绘制用同一份 `point(in:)`，视觉语义自洽。
enum ResizeHandle {
    case topLeft, top, topRight, right
    case bottomRight, bottom, bottomLeft, left
    case inside

    /// 只有这 8 个参与命中测试和绘制，`inside` 是兜底。
    static let resizeHandles: [ResizeHandle] = [
        .topLeft, .top, .topRight, .right,
        .bottomRight, .bottom, .bottomLeft, .left
    ]

    /// `top` 对应 maxY（AppKit 坐标里是上方；Y 向下的画布里是视觉下方）。
    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.maxY)
        case .top:         return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .inside:      return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    /// 把位移应用到矩形上。拖过对边时自动翻转，不会出现负尺寸。
    func apply(delta: CGPoint, to rect: CGRect) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY

        switch self {
        case .topLeft:     minX += delta.x; maxY += delta.y
        case .top:                          maxY += delta.y
        case .topRight:    maxX += delta.x; maxY += delta.y
        case .right:       maxX += delta.x
        case .bottomRight: maxX += delta.x; minY += delta.y
        case .bottom:                       minY += delta.y
        case .bottomLeft:  minX += delta.x; minY += delta.y
        case .left:        minX += delta.x
        case .inside:      return rect.offsetBy(dx: delta.x, dy: delta.y)
        }

        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }

    var isMove: Bool { self == .inside }
}

// MARK: - 标注图层的缩放语义

extension ResizeHandle {

    /// 各 kind 参与缩放的控制点，由工具描述符自己声明
    /// （线段类只有两端，其余矩形类 8 个全上 —— 见 `AnnotationToolDescriptor`）。
    ///
    /// 效果层（`kind.isEffect`）没有画布上的形体，注册表里查不到描述符，
    /// 自然就是空 —— 此前手维护的列表漏了 captureInfo，选中它会在原点
    /// 冒出 8 个控制点、拖拽还会污染撤销栈。
    static func handles(for kind: Layer.Kind) -> [ResizeHandle] {
        guard !kind.isEffect else { return [] }
        return ToolRegistry.descriptor(for: kind)?.resizeHandles ?? resizeHandles
    }

    /// 控制点在图层上的位置（图层自己的坐标空间）。取法由工具描述符决定
    /// （线段类按 start/end 取端点，其余按外接框）。
    func location(of layer: Layer) -> CGPoint {
        ToolRegistry.descriptor(for: layer.kind)?.handleLocation(self, on: layer)
            ?? point(in: layer.handleBounds)
    }

    /// AppKit 没有公开的斜向缩放光标，四角自绘对角双箭头：
    /// 左上/右下是 ↖↘，右上/左下是 ↗↙ —— 方向和控制点对应，一眼知道往哪拉。
    /// 黑箭头条白边（压暗画面上清晰）。实例建一次缓存在类属性里。
    private static let nwseCursor: NSCursor = makeDiagonalCursor(nwse: true)
    private static let neswCursor: NSCursor = makeDiagonalCursor(nwse: false)

    var cursor: NSCursor {
        switch self {
        case .left, .right:      return .resizeLeftRight
        case .top, .bottom:      return .resizeUpDown
        case .inside:            return .openHand
        case .topLeft, .bottomRight: return Self.nwseCursor
        case .topRight, .bottomLeft: return Self.neswCursor
        }
    }

    private static func makeDiagonalCursor(nwse: Bool) -> NSCursor {
        // SF Symbol 单色渲染做不了双色描边，这里自绘 45° 对角双箭头：
        // 先粗白线（4.5pt）做边，再细黑线（2.5pt）做芯 —— 黑箭头条白边，
        // 压暗画面上清晰，也和系统 resizeLeftRight 的风格一致。
        let size: CGFloat = 28
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        // NSImage y 向上：屏幕左上 = 低 x 高 y，右下 = 高 x 低 y。
        let inset: CGFloat = 6
        let a = nwse ? NSPoint(x: inset, y: size - inset) : NSPoint(x: inset, y: inset)
        let b = nwse ? NSPoint(x: size - inset, y: inset) : NSPoint(x: size - inset, y: size - inset)

        func unit(_ v: CGVector) -> CGVector {
            let length = max(hypot(v.dx, v.dy), 0.001)
            return CGVector(dx: v.dx / length, dy: v.dy / length)
        }

        var strokes: [NSBezierPath] = []
        let line = NSBezierPath()
        line.move(to: a)
        line.line(to: b)
        strokes.append(line)
        for (tip, outward) in [(a, unit(CGVector(dx: a.x - b.x, dy: a.y - b.y))),
                               (b, unit(CGVector(dx: b.x - a.x, dy: b.y - a.y)))] {
            let base = CGPoint(x: tip.x - outward.dx * 7, y: tip.y - outward.dy * 7)
            let perp = CGVector(dx: -outward.dy, dy: outward.dx)
            let head = NSBezierPath()
            head.move(to: CGPoint(x: base.x + perp.dx * 4.5, y: base.y + perp.dy * 4.5))
            head.line(to: tip)
            head.line(to: CGPoint(x: base.x - perp.dx * 4.5, y: base.y - perp.dy * 4.5))
            strokes.append(head)
        }

        for (color, width) in [
            (NSColor.white, 4.5),
            (NSColor.black, 2.5)
        ] {
            color.setStroke()
            for path in strokes {
                path.lineWidth = width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
        }

        image.isTemplate = false
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }
}

extension Layer {

    /// 控制点与选中框依据的形体范围。
    ///
    /// text 的 `rect` 只存锚点（w/h 恒为 0，见 `AnnotationState.beginDraw`），
    /// 实际范围按当前字号把文字量出来 —— 字体参数必须与 `LayerRenderer.drawText`
    /// 一致（system semibold、顶端在 rect.y），否则控制点会飘在文字外。
    /// 其余 kind 就是 `rect` 本身（standardized）。
    var handleBounds: CGRect {
        guard kind == .text else { return rect.cg }

        let height: CGFloat
        let width: CGFloat
        if text.isEmpty {
            width = 0
            height = fontSize
        } else {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font])
            )
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            height = ascent + descent
        }
        return CGRect(x: rect.x, y: rect.y, width: width, height: height)
    }
}
