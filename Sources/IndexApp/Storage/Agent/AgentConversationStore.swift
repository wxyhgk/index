import Foundation
import GRDB

// MARK: - Agent 对话记录
//
// conversation 是会话（命名 20260822-a3f2），message 是单条消息。
// 每次 ⌘⇧A 打开面板 = 新 conversation；消息实时写入，关闭后不丢。

// MARK: - 模型

struct AgentConversationRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "agentConversation"

    var id: Int64?
    var name: String
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AgentMessageRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "agentMessage"

    var id: Int64?
    var conversationID: Int64
    var role: String
    var text: String
    var toolCallsJSON: String?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - 仓库

/// Agent 对话的读写。非 MainActor：写入走 DatabasePool，不阻塞主线程。
final class AgentConversationStore: @unchecked Sendable {

    static let shared: AgentConversationStore = {
        do {
            return try AgentConversationStore()
        } catch {
            fatalError("无法打开 Agent 对话存储: \(error)")
        }
    }()

    private let writer: any DatabaseWriter

    init(writer: (any DatabaseWriter)? = nil) throws {
        if let writer {
            self.writer = writer
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Index", isDirectory: true)
            self.writer = try AppDatabase.makeWriter(at: base.appendingPathComponent("index.sqlite"))
        }
    }

    // MARK: - 命名

    /// 生成会话名：20260822-a3f2（日期 + 4 位随机 hex）。
    /// 同一秒内多次创建时追加序号保证唯一。
    func makeName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let date = formatter.string(from: Date())
        let hex = String(format: "%04x", Int.random(in: 0...0xFFFF))
        return "\(date)-\(hex)"
    }

    // MARK: - 会话

    /// 创建新会话，返回 id。
    @discardableResult
    func createConversation(name: String) throws -> Int64 {
        let now = Date()
        var record = AgentConversationRecord(id: nil, name: name, createdAt: now, updatedAt: now)
        try writer.write { db in
            try record.insert(db)
        }
        return record.id!
    }

    /// 列出所有会话（按更新时间倒序）。
    func listConversations(limit: Int = 50) throws -> [AgentConversationRecord] {
        try writer.read { db in
            try AgentConversationRecord
                .order(Column("updatedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// 删除会话（级联删除消息）。
    func deleteConversation(id: Int64) throws {
        try writer.write { db in
            _ = try AgentConversationRecord
                .filter(Column("id") == id)
                .deleteAll(db)
        }
    }

    // MARK: - 消息

    /// 追加一条消息，更新会话 updatedAt。
    func appendMessage(conversationID: Int64, role: String, text: String, toolCallsJSON: String?) throws {
        let now = Date()
        try writer.write { db in
            var record = AgentMessageRecord(
                id: nil,
                conversationID: conversationID,
                role: role,
                text: text,
                toolCallsJSON: toolCallsJSON,
                createdAt: now
            )
            try record.insert(db)
            var conv = try AgentConversationRecord
                .filter(Column("id") == conversationID)
                .fetchOne(db)
            if var conv {
                conv.updatedAt = now
                try conv.update(db)
            }
        }
    }

    /// 读取会话的所有消息（按创建时间正序）。
    func messages(for conversationID: Int64) throws -> [AgentMessageRecord] {
        try writer.read { db in
            try AgentMessageRecord
                .filter(Column("conversationID") == conversationID)
                .order(Column("id").asc)
                .fetchAll(db)
        }
    }
}
