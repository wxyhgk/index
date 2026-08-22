import Foundation

// MARK: - Markdown 生成器
//
// 截图后自动生成一份 Markdown 源码。
// 纯函数，不碰文件系统，可独立单测。
//
// 生成格式：
//   # 标题（windowTitle > appName > "截图"）
//   ![screenshot](sha256.png)
//   元信息（来源/时间/尺寸）
//   OCR 文字（如果有）

enum MarkdownGenerator {

    /// 从截图元数据生成 Markdown 源码。
    /// - Parameters:
    ///   - title: 标题（windowTitle ?? appName ?? "截图"）
    ///   - sha256: 原图文件名（不含扩展名）
    ///   - appName: 来源应用名
    ///   - capturedAt: 截图时间
    ///   - pixelWidth: 像素宽
    ///   - pixelHeight: 像素高
    ///   - ocrText: OCR 识别的文字（可选）
    static func generate(
        title: String,
        sha256: String,
        appName: String?,
        capturedAt: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        ocrText: String?
    ) -> String {
        var lines: [String] = []

        // 标题
        lines.append("# \(title)")
        lines.append("")

        // 图片引用
        lines.append("![screenshot](\(sha256).png)")
        lines.append("")

        // 元信息
        lines.append("- **来源**: \(appName ?? "未知")")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("- **时间**: \(formatter.string(from: capturedAt))")
        lines.append("- **尺寸**: \(pixelWidth) × \(pixelHeight)")
        lines.append("")

        // OCR 文字
        if let ocrText, !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## 识别文字")
            lines.append("")
            lines.append(ocrText)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// 从 Shot 模型直接生成（便利方法）。
    static func generate(for shot: Shot) -> String {
        let title = shot.customTitle
            ?? shot.windowTitle
            ?? shot.appName
            ?? "截图"
        return generate(
            title: title,
            sha256: shot.sha256,
            appName: shot.appName,
            capturedAt: shot.capturedAt,
            pixelWidth: shot.pixelWidth,
            pixelHeight: shot.pixelHeight,
            ocrText: shot.ocrText
        )
    }
}
