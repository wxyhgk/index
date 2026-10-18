import Foundation

// ============================================================
// MARK: - 剪贴板文本结构化分析
//
// 纯函数，不碰 NSPasteboard / 数据库，可独立单测。
// 在文本入库时调用，提取 URL 和代码块，生成 tags 写入数据库。
//
// 检测规则（本地、离线、零延迟）：
//   · URL：正则提取所有 https?:// 匹配（归一化去重）
//   · 代码：Markdown 围栏 + 语言关键词启发式
//   · 分类：根据提取结果判断 plain / url / code / mixed
// ============================================================

struct CodeBlock: Equatable, Codable, Sendable {
    var language: String?
    var content: String
}

enum ClipboardTextCategory: String, Codable, Sendable {
    case plain
    case url
    case code
    case mixed
}

struct ClipboardTextAnalysis: Equatable, Sendable {
    var urls: [String]
    var codeBlocks: [CodeBlock]
    var category: ClipboardTextCategory

    /// 生成 tags 数组（存入数据库 tags 列的 JSON）。
    var tags: [String] {
        var result = Set<String>()
        if !urls.isEmpty { result.insert("url") }
        for block in codeBlocks {
            if let lang = block.language {
                result.insert("code:\(lang)")
            } else {
                result.insert("code")
            }
        }
        return Array(result).sorted()
    }
}

enum ClipboardTextAnalyzer {

    /// 分析剪贴板文本，提取 URL 和代码块。
    static func analyze(_ text: String) -> ClipboardTextAnalysis {
        let urls = extractURLs(from: text)
        let codeBlocks = detectCodeBlocks(in: text)
        let category = categorize(urls: urls, codeBlocks: codeBlocks, text: text)
        return .init(urls: urls, codeBlocks: codeBlocks, category: category)
    }

    // MARK: URL 提取

    /// 提取文本中所有 URL（归一化去重，保留原始形式）。
    static func extractURLs(from text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(
            pattern: #"https?://[\w\-._~:/?#\[\]@!$&'()*+,;=%]+"#,
            options: []
        ) else { return [] }

        let nsRange = NSRange(text.startIndex..., in: text)
        var urls: [String] = []
        var seen = Set<String>()

        for match in pattern.matches(in: text, options: [], range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let raw = String(text[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)\"'"))
            guard raw.count > 12 else { continue }
            let normalized = normalizeURL(raw)
            if !seen.contains(normalized) {
                seen.insert(normalized)
                urls.append(raw)
            }
        }
        return urls
    }

    /// URL 归一化：去追踪参数 + 去尾斜杠。用于去重判断。
    static func normalizeURL(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        let tracking: Set<String> = [
            "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
            "fbclid", "gclid", "ref", "spm"
        ]
        if let items = components.queryItems, !items.isEmpty {
            let filtered = items.filter { !tracking.contains($0.name.lowercased()) }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        var result = components.string ?? url
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    // MARK: 代码块检测

    /// 检测文本中的代码块。优先 Markdown 围栏，否则用 CodeLanguageDetector 整体判断。
    static func detectCodeBlocks(in text: String) -> [CodeBlock] {
        let fenced = detectFencedBlocks(in: text)
        if !fenced.isEmpty { return fenced }
        if let lang = CodeLanguageDetector.detect(text) {
            return [CodeBlock(language: lang, content: text)]
        }
        return []
    }

    /// 检测 Markdown 围栏代码块（```lang ... ```）。
    private static func detectFencedBlocks(in text: String) -> [CodeBlock] {
        var blocks: [CodeBlock] = []
        var inBlock = false
        var lang: String?
        var lines: [String] = []

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !inBlock {
                    inBlock = true
                    let suffix = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    lang = suffix.isEmpty ? nil : suffix
                    lines = []
                } else {
                    inBlock = false
                    let content = lines.joined(separator: "\n")
                    if !content.isEmpty {
                        blocks.append(.init(language: lang, content: content))
                    }
                }
            } else if inBlock {
                lines.append(line)
            }
        }
        // 未闭合的围栏仍然提取
        if inBlock, !lines.isEmpty {
            blocks.append(.init(language: lang, content: lines.joined(separator: "\n")))
        }
        return blocks
    }

    // MARK: 分类

    private static func categorize(
        urls: [String],
        codeBlocks: [CodeBlock],
        text: String
    ) -> ClipboardTextCategory {
        let hasURL = !urls.isEmpty
        let hasCode = !codeBlocks.isEmpty
        if hasURL && hasCode { return .mixed }
        if hasURL {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPureURL = urls.count == 1
                && trimmed == urls[0].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)\"'"))
            return isPureURL ? .url : .mixed
        }
        if hasCode { return .code }
        return .plain
    }
}
