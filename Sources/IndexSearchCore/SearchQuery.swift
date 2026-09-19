import Foundation

// MARK: - 统一搜索查询
//
// 所有搜索路径（图库/便签/剪贴板/输入法/搜索面板）共用的 query 预处理 + 表达式生成。
// 纯值类型，无 AppKit 依赖，可被 IndexSearchCore 和 IndexApp 共同消费。

public struct SearchQuery: Sendable, Equatable {
    public let raw: String
    public let trimmed: String
    public let tokens: [String]
    public var isEmpty: Bool { trimmed.isEmpty }

    public init(_ raw: String) {
        self.raw = raw
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trimmed = trimmed
        self.tokens = trimmed
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: FTS5 表达式

    public var ftsExpression: String? {
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    public var ftsExpressionSQL: String? {
        guard let expr = ftsExpression else { return nil }
        return expr.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: LIKE pattern

    public var likePattern: String? {
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    public var tokenLikePatterns: [String] {
        tokens.map { token in
            let escaped = token
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            return "%\(escaped)%"
        }
    }

    public var hasFTSTokens: Bool {
        tokens.contains { $0.count >= 3 }
    }

    public var ftsTokens: [String] {
        tokens.filter { $0.count >= 3 }
    }

    public var likeTokens: [String] {
        tokens.filter { $0.count < 3 }
    }
}

// MARK: - Snippet 生成

public extension SearchQuery {
    static func snippet(
        _ text: String,
        query: String,
        maxChars: Int = 60,
        context: Int = 20
    ) -> String {
        guard !text.isEmpty else { return "" }
        let lowerText = text.lowercased()
        let tokens = SearchQuery(query).tokens

        var hitRange: Range<String.Index>?
        for token in tokens {
            if let range = lowerText.range(of: token) {
                hitRange = range
                break
            }
        }

        guard let hitRange else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > maxChars
                ? String(trimmed.prefix(maxChars)) + "…"
                : trimmed
        }

        let beforeLen = lowerText.distance(from: lowerText.startIndex, to: hitRange.lowerBound)
        let afterLen = lowerText.distance(from: hitRange.upperBound, to: lowerText.endIndex)
        let hitLen = lowerText.distance(from: hitRange.lowerBound, to: hitRange.upperBound)
        let start = lowerText.index(hitRange.lowerBound, offsetBy: -min(context, beforeLen))
        let end = lowerText.index(hitRange.upperBound, offsetBy: min(context + hitLen, afterLen))
        let snippet = String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let prefix = start > lowerText.startIndex ? "…" : ""
        let suffix = end < lowerText.endIndex ? "…" : ""
        return prefix + snippet + suffix
    }
}

// MARK: - 打分

public extension SearchQuery {
    static func score(
        title: String?,
        text: String?,
        query: String
    ) -> Int {
        var score = 0
        let lowerTitle = title?.lowercased() ?? ""
        let lowerText = text?.lowercased() ?? ""
        let lowerQuery = query.lowercased()

        if !lowerQuery.isEmpty {
            if lowerTitle.contains(lowerQuery) { score += 120 }
            if lowerText.contains(lowerQuery) { score += 120 }
        }

        for token in SearchQuery(query).tokens {
            if lowerTitle.contains(token) { score += 30 }
            if lowerText.contains(token) { score += 30 }
            if lowerTitle.contains(token) { score += 18 }
        }

        return score
    }
}
