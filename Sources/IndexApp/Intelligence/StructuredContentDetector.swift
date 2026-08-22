import CoreGraphics
import Vision
import AppKit

// MARK: - 结构化内容检测（屏幕剪贴板 demo）
//
// 输入框选后的 CGImage，输出"这段内容是什么结构"。
// 纯函数，不碰 NSPasteboard，可独立单测。
//
// 检测优先级（命中即返回）：
//   1. 颜色：小选区 + 颜色均匀 → 色值
//   2. URL：OCR 匹配 https?:// → 链接
//   3. 文本：OCR 有结果 → 纯文本
//   4. 图片：以上都不命中 → 纯图片（兜底）

enum StructuredContent: Equatable {
    /// 纯色块：hex 色值（如 "#FF5733"）。
    case color(hex: String)
    /// URL：完整链接。
    case url(String)
    /// 纯文本：OCR 识别结果。
    case text(String)
    /// 纯图片：无法提取结构，只给 PNG。
    case image
}

enum StructuredContentDetector {

    /// 检测框选区域的结构化内容。
    /// - Parameter image: 框选裁好的 CGImage（像素空间）
    /// - Returns: 检测到的结构类型
    static func detect(in image: CGImage) async -> StructuredContent {
        // 1. 颜色检测（同步，< 1ms）
        if let hex = detectColor(in: image) {
            return .color(hex: hex)
        }

        // 2. OCR（异步，100-500ms）
        let text = await ocrText(in: image)
        guard !text.isEmpty else { return .image }

        // 3. URL 检测
        if let url = detectURL(in: text) {
            return .url(url)
        }

        // 4. 纯文本
        return .text(text)
    }

    // MARK: 颜色检测
    //
    // 条件：选区足够小（≤ 200×200px）+ 颜色均匀（方差 < 阈值）。
    // 采样中心 5×5 区域，计算 RGB 方差。

    private static func detectColor(in image: CGImage) -> String? {
        let w = image.width
        let h = image.height
        // 大选区不太可能是"色块"
        guard w <= 200, h <= 200 else { return nil }

        // 用 NSBitmapImageRep 采样，不关心底层字节顺序（RGBA/BGRA/ARGB 都能正确读）
        let rep = NSBitmapImageRep(cgImage: image)

        // 采样中心 5×5
        let cx = w / 2
        let cy = h / 2
        let half = 2
        var rSum: Double = 0, gSum: Double = 0, bSum: Double = 0
        var rSq: Double = 0, gSq: Double = 0, bSq: Double = 0
        var count: Double = 0

        for dy in -half...half {
            for dx in -half...half {
                let px = cx + dx
                let py = cy + dy
                guard px >= 0, px < w, py >= 0, py < h else { continue }
                guard let color = rep.colorAt(x: px, y: py) else { continue }
                let r = Double(color.redComponent * 255)
                let g = Double(color.greenComponent * 255)
                let b = Double(color.blueComponent * 255)
                rSum += r; gSum += g; bSum += b
                rSq += r * r; gSq += g * g; bSq += b * b
                count += 1
            }
        }
        guard count > 0 else { return nil }

        let rMean = rSum / count, gMean = gSum / count, bMean = bSum / count
        let rVar = rSq / count - rMean * rMean
        let gVar = gSq / count - gMean * gMean
        let bVar = bSq / count - bMean * bMean
        let totalVar = rVar + gVar + bVar

        // 方差阈值：255² 是最大可能，50 表示非常均匀
        guard totalVar < 50 else { return nil }

        let r = Int(rMean.rounded())
        let g = Int(gMean.rounded())
        let b = Int(bMean.rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: URL 检测
    //
    // 正则匹配 https?:// 开头的完整 URL。
    // 取第一个匹配（OCR 可能把 URL 拆成多行，拼回后匹配）。

    private static func detectURL(in text: String) -> String? {
        // 拼回多行（OCR 可能把长 URL 拆成多行）
        let joined = text.replacingOccurrences(of: "\n", with: " ")
        guard let pattern = try? NSRegularExpression(
            pattern: "https?://[\\w\\-._~:/?#\\[\\]@!$&'()*+,;=%]+",
            options: []
        ) else { return nil }

        let range = NSRange(joined.startIndex..., in: joined)
        guard let match = pattern.firstMatch(in: joined, options: [], range: range),
              let matchRange = Range(match.range, in: joined) else { return nil }

        let url = String(joined[matchRange])
        // 去掉尾部标点（OCR 可能把句号/逗号粘到 URL 后面）
        let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)\"'"))
        guard trimmed.count >= 10 else { return nil } // 太短不太像 URL
        return trimmed
    }

    // MARK: OCR

    private static func ocrText(in image: CGImage) async -> String {
        let recognizer = VisionTextRecognition()
        let lines = await recognizer.recognize(in: image)
        return lines.map(\.text).joined(separator: "\n")
    }
}
