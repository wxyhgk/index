import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 一个步骤的图文材料：代表帧 + 一行配文。
struct StepGuideStep: Equatable, Sendable {
    let image: CGImage
    let caption: String
}

/// 导出结果：文件夹位置与步骤数。
struct StepGuide: Equatable, Sendable {
    let directory: URL
    let markdownURL: URL
    let stepCount: Int
}

enum StepGuideError: Error, LocalizedError {
    case noSteps
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noSteps:
            return "没有检测到操作步骤"
        case .writeFailed:
            return "步骤指南写入失败"
        }
    }
}

/// 步骤序列 → `步骤指南-<时间戳>/` 文件夹：
///
/// ```text
/// 步骤指南-20260820-123456/
/// ├── 步骤指南.md     每步一张截图 + 一行文字
/// ├── step-01.png
/// └── step-02.png
/// ```
///
/// 纯函数式，不碰 UI —— 调用方决定何时导出、导出后做什么。
enum StepGuideExporter {

    /// 导出到 `destination`（视频所在目录），返回文件夹信息。
    static func export(
        steps: [StepGuideStep],
        sourceName: String?,
        destination: URL
    ) throws -> StepGuide {
        guard !steps.isEmpty else { throw StepGuideError.noSteps }

        let folder = destination.appendingPathComponent(folderName(for: Date()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var succeeded = false
        defer {
            // 中途失败不留半成品文件夹。
            if !succeeded { try? FileManager.default.removeItem(at: folder) }
        }

        for (index, step) in steps.enumerated() {
            let pngName = String(format: "step-%02d.png", index + 1)
            let pngURL = folder.appendingPathComponent(pngName)
            guard let data = pngData(step.image) else { throw StepGuideError.writeFailed }
            try data.write(to: pngURL)
        }

        let markdown = renderMarkdown(steps: steps, sourceName: sourceName)
        let markdownURL = folder.appendingPathComponent("步骤指南.md")
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        succeeded = true

        return StepGuide(directory: folder, markdownURL: markdownURL, stepCount: steps.count)
    }

    /// `步骤指南-YYYYMMDD-HHMMSS`
    static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "步骤指南-\(formatter.string(from: date))"
    }

    static func renderMarkdown(steps: [StepGuideStep], sourceName: String?) -> String {
        var lines: [String] = ["# 步骤指南", ""]
        if let sourceName {
            lines.append("> 来源：\(sourceName) · 共 \(steps.count) 步")
            lines.append("")
        }
        for (index, step) in steps.enumerated() {
            let number = index + 1
            lines.append(contentsOf: [
                "## 步骤 \(number)",
                "",
                "![步骤 \(number)](step-\(String(format: "%02d", number)).png)",
                "",
                step.caption,
                "",
            ])
        }
        return lines.joined(separator: "\n")
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
