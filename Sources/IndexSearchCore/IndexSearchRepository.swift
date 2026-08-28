import Foundation
import GRDB

/// 面向输入法的只读检索器。生产只打开现有 SQLite，不执行迁移、不写用户数据。
public final class IndexSearchRepository: @unchecked Sendable {
    public enum RepositoryError: LocalizedError {
        case databaseNotFound

        public var errorDescription: String? {
            switch self {
            case .databaseNotFound: return "找不到 Index 数据库，请先运行 Index。"
            }
        }
    }

    private struct Candidate {
        let id: Int64
        let kind: IndexSearchResult.Kind
        let title: String
        let subtitle: String
        let searchableText: String
        let assetURL: URL?
        let capturedAt: Date
        let namespace: String
    }

    private let database: any DatabaseReader
    private let dataRoot: URL

    public convenience init() throws {
        let location = try Self.defaultLocation()
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "IndexInputSearch"
        let queue = try DatabaseQueue(path: location.databaseURL.path, configuration: configuration)
        self.init(database: queue, dataRoot: location.dataRoot)
    }

    public init(database: any DatabaseReader, dataRoot: URL) {
        self.database = database
        self.dataRoot = dataRoot
    }

    public func search(_ rawQuery: String, limit: Int = 6) throws -> [IndexSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let tokens = Self.tokens(in: query)
        guard !tokens.isEmpty else { return [] }

        let candidates = try database.read { db in
            var values = try shotCandidates(db, query: query, tokens: tokens)
            values.append(contentsOf: try clipboardCandidates(db, query: query, tokens: tokens))
            return values
        }

        return candidates
            .map { candidate in
                let score = Self.score(candidate: candidate, query: query, tokens: tokens)
                return IndexSearchResult(
                    id: "\(candidate.namespace)-\(candidate.id)",
                    recordID: candidate.id,
                    kind: candidate.kind,
                    title: candidate.title,
                    subtitle: candidate.subtitle,
                    snippet: Self.snippet(in: candidate.searchableText, tokens: tokens),
                    assetURL: candidate.assetURL,
                    capturedAt: candidate.capturedAt,
                    score: score
                )
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.capturedAt > $1.capturedAt
            }
            .prefix(limit)
            .map { $0 }
    }

    private func shotCandidates(
        _ db: Database,
        query: String,
        tokens: [String]
    ) throws -> [Candidate] {
        guard try db.tableExists("shot") else { return [] }

        let hasFTS = try db.tableExists("shotFts") && db.tableExists("attributeFts")
        let hasStructuredContent = try db.tableExists("shotContent")
            && db.tableExists("contentMarkdown")
            && db.tableExists("contentCode")
        let indexedTokens = tokens.filter { $0.count >= 3 }
        var argumentValues: [String: (any DatabaseValueConvertible)?] = [:]
        var whereClause: String

        if hasFTS, !indexedTokens.isEmpty {
            argumentValues["pattern"] = indexedTokens.map(Self.quotedFTSToken).joined(separator: " OR ")
            whereClause = """
                shot.id IN (
                    SELECT shotFts.rowid FROM shotFts WHERE shotFts MATCH :pattern
                    UNION
                    SELECT shotAttribute.shotID FROM shotAttribute
                    JOIN attributeFts ON attributeFts.rowid = shotAttribute.id
                    WHERE attributeFts MATCH :pattern
                )
                """
        } else {
            argumentValues["like"] = "%\(Self.escapedLIKE(query))%"
            whereClause = """
                shot.customTitle LIKE :like ESCAPE '\\'
                OR shot.appName LIKE :like ESCAPE '\\'
                OR shot.windowTitle LIKE :like ESCAPE '\\'
                OR shot.sourceURL LIKE :like ESCAPE '\\'
                OR shot.ocrText LIKE :like ESCAPE '\\'
                """
        }

        if hasStructuredContent {
            argumentValues["structuredLike"] = "%\(Self.escapedLIKE(query))%"
            whereClause = """
                (\(whereClause))
                OR contentMarkdown.source LIKE :structuredLike ESCAPE '\\'
                OR contentCode.text LIKE :structuredLike ESCAPE '\\'
                """
        }

        let structuredJoins = hasStructuredContent ? """
            LEFT JOIN shotContent ON shotContent.shotID = shot.id
            LEFT JOIN contentMarkdown ON contentMarkdown.contentID = shotContent.id
            LEFT JOIN contentCode ON contentCode.contentID = shotContent.id
            """ : ""
        let markdownColumn = hasStructuredContent ? "contentMarkdown.source" : "NULL"
        let codeColumn = hasStructuredContent ? "contentCode.text" : "NULL"

        let rows = try Row.fetchAll(db, sql: """
            SELECT shot.id,
                   shot.sha256,
                   shot.capturedAt,
                   shot.customTitle,
                   shot.windowTitle,
                   shot.appName,
                   shot.sourceURL,
                   shot.ocrText,
                   shot.contentKind,
                   \(markdownColumn) AS markdownSource,
                   \(codeColumn) AS codeSource
            FROM shot
            \(structuredJoins)
            WHERE (\(whereClause))
            ORDER BY shot.capturedAt DESC, shot.id DESC
            LIMIT 80
            """, arguments: StatementArguments(argumentValues))

        return rows.compactMap { row in
            guard let id: Int64 = row["id"],
                  let sha: String = row["sha256"],
                  let capturedAt: Date = row["capturedAt"]
            else { return nil }
            let customTitle: String? = row["customTitle"]
            let windowTitle: String? = row["windowTitle"]
            let appName: String? = row["appName"]
            let sourceURL: String? = row["sourceURL"]
            let ocrText: String? = row["ocrText"]
            let markdown: String? = row["markdownSource"]
            let code: String? = row["codeSource"]
            let rawKind: String? = row["contentKind"]
            let kind: IndexSearchResult.Kind = switch rawKind {
            case "markdown": .markdown
            case "code": .code
            default: .screenshot
            }
            let title = Self.firstNonempty(customTitle, windowTitle, appName) ?? "未命名内容"
            let searchable = [customTitle, windowTitle, appName, sourceURL, ocrText, markdown, code]
                .compactMap { $0 }
                .joined(separator: "\n")
            return Candidate(
                id: id,
                kind: kind,
                title: title,
                subtitle: appName ?? kind.displayName,
                searchableText: searchable,
                assetURL: dataRoot.appendingPathComponent("thumbnails/\(sha).jpg"),
                capturedAt: capturedAt,
                namespace: "shot"
            )
        }
    }

    private func clipboardCandidates(
        _ db: Database,
        query: String,
        tokens: [String]
    ) throws -> [Candidate] {
        guard try db.tableExists("clipboardHistory") else { return [] }
        let predicates = tokens.indices.map { index -> String in
            """
            (title LIKE :clip\(index) ESCAPE '\\'
             OR summary LIKE :clip\(index) ESCAPE '\\'
             OR text LIKE :clip\(index) ESCAPE '\\')
            """
        }
        var argumentValues: [String: (any DatabaseValueConvertible)?] = [:]
        for (index, token) in tokens.enumerated() {
            argumentValues["clip\(index)"] = "%\(Self.escapedLIKE(token))%"
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, kind, title, summary, text, assetPath, sourceApp, capturedAt
            FROM clipboardHistory
            WHERE \(predicates.joined(separator: " OR "))
            ORDER BY pinned DESC, isFavorite DESC, capturedAt DESC
            LIMIT 60
            """, arguments: StatementArguments(argumentValues))

        return rows.compactMap { row in
            guard let id: Int64 = row["id"],
                  let rawKind: String = row["kind"],
                  let capturedAt: Date = row["capturedAt"]
            else { return nil }
            let title: String? = row["title"]
            let summary: String? = row["summary"]
            let text: String? = row["text"]
            let sourceApp: String? = row["sourceApp"]
            let assetPath: String? = row["assetPath"]
            let kind: IndexSearchResult.Kind
            switch rawKind {
            case "image": kind = .clipboardImage
            case "file": kind = .clipboardFile
            default: kind = .clipboardText
            }
            let displayTitle = Self.firstNonempty(title, summary, text) ?? kind.displayName
            let assetURL = assetPath.map {
                dataRoot.appendingPathComponent("clipboard/\($0)")
            }
            return Candidate(
                id: id,
                kind: kind,
                title: String(displayTitle.prefix(80)),
                subtitle: sourceApp ?? kind.displayName,
                searchableText: [title, summary, text].compactMap { $0 }.joined(separator: "\n"),
                assetURL: assetURL,
                capturedAt: capturedAt,
                namespace: "clipboard"
            )
        }
    }

    private static func score(candidate: Candidate, query: String, tokens: [String]) -> Int {
        let haystack = candidate.searchableText.lowercased()
        let title = candidate.title.lowercased()
        let normalizedQuery = query.lowercased()
        var value = haystack.contains(normalizedQuery) ? 120 : 0
        for token in tokens where haystack.contains(token) {
            value += 30
            if title.contains(token) { value += 18 }
        }
        switch candidate.kind {
        case .clipboardText, .markdown, .code: value += 5
        default: break
        }
        return value
    }

    private static func snippet(in text: String, tokens: [String]) -> String {
        let compact = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "无文字摘要" }
        let lowercased = compact.lowercased()
        let firstRange = tokens.compactMap { lowercased.range(of: $0) }.min { lhs, rhs in
            lhs.lowerBound < rhs.lowerBound
        }
        guard let firstRange else { return String(compact.prefix(120)) }
        let hit = lowercased.distance(from: lowercased.startIndex, to: firstRange.lowerBound)
        let startOffset = max(0, hit - 28)
        let start = compact.index(compact.startIndex, offsetBy: min(startOffset, compact.count))
        let suffix = compact[start...]
        return (startOffset > 0 ? "…" : "") + String(suffix.prefix(120))
    }

    private static func tokens(in query: String) -> [String] {
        let raw = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        return Array(raw.suffix(6))
    }

    private static func quotedFTSToken(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func escapedLIKE(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func firstNonempty(_ values: String?...) -> String? {
        values.lazy.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private static func defaultLocation() throws -> (databaseURL: URL, dataRoot: URL) {
        let fileManager = FileManager.default
        var roots: [URL] = []
        if let override = ProcessInfo.processInfo.environment["INDEX_DATA_ROOT"], !override.isEmpty {
            roots.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            roots.append(applicationSupport.appendingPathComponent("Index", isDirectory: true))
        }
        roots.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Index", isDirectory: true)
        )
        roots.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Containers/com.wxyhgk.index/Data/Library/Application Support/Index",
                    isDirectory: true
                )
        )

        var seen = Set<String>()
        for root in roots where seen.insert(root.standardizedFileURL.path).inserted {
            let databaseURL = root.appendingPathComponent("index.sqlite")
            if fileManager.isReadableFile(atPath: databaseURL.path) {
                return (databaseURL, root)
            }
        }
        throw RepositoryError.databaseNotFound
    }
}
