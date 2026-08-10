import AppKit
import CoreText

/// IME 候选窗口跟随的纯几何 —— 不依赖 NSView / window，只算字符宽度与画布→视图的映射。
///
/// 两个宿主（截图覆盖层 / 钉图）共用同一套字符测量，与 `Layer.handleBounds` 同源
/// （semibold systemFont + CTLine typographicBounds），避免 NSString.size(withAttributes:)
/// 在字距/回退字体上的近似误差。坐标翻转与 Retina 缩放也在此收口，便于单测。
enum IMECaretGeometry {

    // MARK: - 字符测量

    /// prefix 在给定字号下的精确推进宽度（画布单位）。
    /// prefixLength 以 UTF16 计（与 NSRange.location 一致），超界时截断。
    static func prefixWidth(fullText: String, prefixLength: Int, fontSize: CGFloat) -> CGFloat {
        let len = (fullText as NSString).length
        let clamped = min(max(0, prefixLength), len)
        guard clamped > 0 else { return 0 }
        let prefix = (fullText as NSString).substring(to: clamped)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attr = NSAttributedString(string: prefix, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// 行高（ascent + descent），与 `Layer.handleBounds` 的空/非空分支一致。
    /// 空文字退回 fontSize，保证 input 空时候选窗口仍有高度。
    static func lineHeight(for text: String, fontSize: CGFloat) -> CGFloat {
        if text.isEmpty { return CGFloat(fontSize) }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let h = ascent + descent
        return h > 0 ? h : CGFloat(fontSize)
    }

    // MARK: - 画布 → 视图

    /// 覆盖层：画布 = 显示器局部点、左上原点、无缩放。
    static func overlayViewRect(layerRect: CGRect, fullText: String, fontSize: CGFloat, prefixLength: Int, boundsHeight: CGFloat) -> CGRect {
        let full = fullText
        let w = prefixWidth(fullText: full, prefixLength: prefixLength, fontSize: fontSize)
        let h = lineHeight(for: full, fontSize: fontSize)
        let viewY = boundsHeight - layerRect.origin.y - h
        return CGRect(x: layerRect.origin.x + w, y: viewY, width: 8, height: h + 6)
    }

    /// 钉图：画布 = 图片像素、左上原点，视图 = 等比缩放 + Y 翻转。
    static func pinViewRect(layerRect: CGRect, fullText: String, fontSize: CGFloat, prefixLength: Int, boundsHeight: CGFloat, displayScale: CGFloat) -> CGRect {
        let scale = max(displayScale, 0.0001)
        let full = fullText
        let w = prefixWidth(fullText: full, prefixLength: prefixLength, fontSize: fontSize)
        let h = lineHeight(for: full, fontSize: fontSize)
        let viewX = (layerRect.origin.x + w) * scale
        let viewY = boundsHeight - layerRect.origin.y * scale - h * scale
        return CGRect(x: viewX, y: viewY, width: 8 * scale, height: (h + 6) * scale)
    }
}
