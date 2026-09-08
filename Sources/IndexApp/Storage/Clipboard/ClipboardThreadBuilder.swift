import Foundation

/// 自动发现的临时工作片段。线程不落库；只有用户确认后才转为胶囊。
struct ClipboardThread: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let items: [ClipboardHistoryItem]
    let startedAt: Date
    let endedAt: Date
    let sourceApps: [String]
}

enum ClipboardThreadBuilder {
    static let maximumGap: TimeInterval = 10 * 60

    static func build(from items: [ClipboardHistoryItem]) -> [ClipboardThread] {
        let chronological = items
            .filter { $0.id != nil }
            .sorted {
                if $0.capturedAt == $1.capturedAt { return ($0.id ?? 0) < ($1.id ?? 0) }
                return $0.capturedAt < $1.capturedAt
            }
        guard !chronological.isEmpty else { return [] }

        var groups: [[ClipboardHistoryItem]] = []
        var current: [ClipboardHistoryItem] = [chronological[0]]
        for item in chronological.dropFirst() {
            if let previous = current.last, belongs(item, after: previous) {
                current.append(item)
            } else {
                if current.count >= 2 { groups.append(current) }
                current = [item]
            }
        }
        if current.count >= 2 { groups.append(current) }

        return groups.reversed().map(makeThread)
    }

    private static func belongs(
        _ item: ClipboardHistoryItem,
        after previous: ClipboardHistoryItem
    ) -> Bool {
        let gap = item.capturedAt.timeIntervalSince(previous.capturedAt)
        guard gap >= 0, gap <= maximumGap else { return false }

        var score = 0
        if gap <= 45 { score += 2 }
        else if gap <= 3 * 60 { score += 1 }

        if let source = normalizedSource(item.sourceApp),
           source == normalizedSource(previous.sourceApp) {
            score += 2
        }
        if !tokens(for: item).isDisjoint(with: tokens(for: previous)) {
            score += 3
        }
        if item.kind == previous.kind { score += 1 }

        // 单纯“复制得很快”不再构成线程。还要结合来源、类型和关键词中的
        // 足够证据，避免一阵快速操作被串成一个巨大杂项线程。
        return score >= 4
    }

    private static func makeThread(_ items: [ClipboardHistoryItem]) -> ClipboardThread {
        let sources = Array(Set(items.compactMap(\.sourceApp))).sorted()
        let shared = sharedTokens(in: items).filter(isUsefulTitleToken)
        let title: String
        if let token = shared.sorted(by: { lhs, rhs in
            if lhs.count == rhs.count { return lhs < rhs }
            return lhs.count > rhs.count
        }).first {
            title = token
        } else if sources.count == 1, let source = sources.first {
            title = source
        } else {
            title = String(items.last?.displayName.prefix(28) ?? "剪贴板线程")
        }
        let first = items[0]
        let last = items[items.count - 1]
        return ClipboardThread(
            id: "thread:\(first.id ?? 0):\(last.id ?? 0)",
            title: title,
            items: items.reversed(),
            startedAt: first.capturedAt,
            endedAt: last.capturedAt,
            sourceApps: sources
        )
    }

    private static func sharedTokens(in items: [ClipboardHistoryItem]) -> Set<String> {
        guard let first = items.first else { return [] }
        return items.dropFirst().reduce(tokens(for: first)) { partial, item in
            partial.intersection(tokens(for: item))
        }
    }

    private static func normalizedSource(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value?.isEmpty == false ? value : nil
    }

    private static func isUsefulTitleToken(_ token: String) -> Bool {
        guard token.count >= 3 else { return false }
        return !["http", "https", "www", "com", "text", "file", "png", "jpg", "mp3"]
            .contains(token)
    }

    private static func tokens(for item: ClipboardHistoryItem) -> Set<String> {
        let source = [item.title, item.summary, item.text]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        // 线程只是交互提示，不应扫描整篇文档。限制前缀使 10 万级历史分页
        // 中每一页的分析成本与条目数量线性相关，而不是与剪贴板全文大小相关。
        let boundedSource = String(source.prefix(768))
        let parts = boundedSource.split { !$0.isLetter && !$0.isNumber }
        var result = Set(parts.filter { $0.count >= 2 }.map(String.init))
        for part in parts where part.count >= 4 {
            let characters = Array(part)
            for index in 0..<(characters.count - 1) {
                result.insert(String(characters[index...index + 1]))
            }
        }
        return result
    }
}
