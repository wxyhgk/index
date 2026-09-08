import Foundation
import GRDB

enum ClipboardCapsuleSeparator: String, Codable, CaseIterable, Sendable {
    case newline
    case space
    case comma
    case none

    var value: String {
        switch self {
        case .newline: return "\n"
        case .space: return " "
        case .comma: return ", "
        case .none: return ""
        }
    }
}

struct ClipboardCapsule: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "clipboardCapsule"

    var id: Int64?
    var name: String
    var separator: ClipboardCapsuleSeparator
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct ClipboardCapsuleItem: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "clipboardCapsuleItem"

    var capsuleID: Int64
    var clipboardID: Int64
    var sortOrder: Int
    var addedAt: Date
}

struct ClipboardCapsuleSnapshot: Identifiable, Equatable, Sendable {
    var capsule: ClipboardCapsule
    var items: [ClipboardHistoryItem]

    var id: Int64 { capsule.id ?? -1 }
}

extension ClipboardHistoryStore {
    func capsuleSnapshots() throws -> [ClipboardCapsuleSnapshot] {
        try writer.read { db in
            let capsules = try ClipboardCapsule
                .order(Column("isPinned").desc, Column("updatedAt").desc)
                .fetchAll(db)
            return try capsules.map { capsule in
                guard let capsuleID = capsule.id else {
                    return ClipboardCapsuleSnapshot(capsule: capsule, items: [])
                }
                let items = try ClipboardHistoryItem.fetchAll(db, sql: """
                    SELECT h.* FROM clipboardHistory h
                    JOIN clipboardCapsuleItem i ON i.clipboardID = h.id
                    WHERE i.capsuleID = ?
                    ORDER BY i.sortOrder ASC, i.addedAt ASC
                    """, arguments: [capsuleID])
                return ClipboardCapsuleSnapshot(capsule: capsule, items: items)
            }
        }
    }

    @discardableResult
    func createCapsule(
        name: String,
        items: [ClipboardHistoryItem],
        separator: ClipboardCapsuleSeparator = .newline
    ) throws -> ClipboardCapsule {
        let ids = items.compactMap(\.id)
        guard !ids.isEmpty else { throw ClipboardCapsuleStoreError.emptyCapsule }
        let normalizedName = Self.normalizedCapsuleName(name, items: items)
        return try writer.write { db in
            let now = Date()
            var capsule = ClipboardCapsule(
                id: nil,
                name: normalizedName,
                separator: separator,
                isPinned: false,
                createdAt: now,
                updatedAt: now,
                lastUsedAt: nil
            )
            try capsule.insert(db)
            guard let capsuleID = capsule.id else {
                throw ClipboardCapsuleStoreError.missingIdentifier
            }
            for (order, clipboardID) in ids.enumerated() {
                try ClipboardCapsuleItem(
                    capsuleID: capsuleID,
                    clipboardID: clipboardID,
                    sortOrder: order,
                    addedAt: now
                ).insert(db)
            }
            return capsule
        }
    }

    func renameCapsule(_ name: String, capsuleID: Int64) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try? writer.write { db in
            try db.execute(
                sql: "UPDATE clipboardCapsule SET name = ?, updatedAt = ? WHERE id = ?",
                arguments: [normalized, Date(), capsuleID]
            )
        }
    }

    func setCapsulePinned(_ pinned: Bool, capsuleID: Int64) {
        try? writer.write { db in
            try db.execute(
                sql: "UPDATE clipboardCapsule SET isPinned = ?, updatedAt = ? WHERE id = ?",
                arguments: [pinned, Date(), capsuleID]
            )
        }
    }

    func deleteCapsule(_ capsuleID: Int64) {
        try? writer.write { db in
            try db.execute(sql: "DELETE FROM clipboardCapsule WHERE id = ?", arguments: [capsuleID])
        }
    }

    func replaceCapsuleItems(
        capsuleID: Int64,
        items: [ClipboardHistoryItem]
    ) throws {
        let ids = items.compactMap(\.id)
        guard !ids.isEmpty else { throw ClipboardCapsuleStoreError.emptyCapsule }
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM clipboardCapsuleItem WHERE capsuleID = ?",
                arguments: [capsuleID]
            )
            let now = Date()
            for (order, clipboardID) in ids.enumerated() {
                try ClipboardCapsuleItem(
                    capsuleID: capsuleID,
                    clipboardID: clipboardID,
                    sortOrder: order,
                    addedAt: now
                ).insert(db)
            }
            try db.execute(
                sql: "UPDATE clipboardCapsule SET updatedAt = ? WHERE id = ?",
                arguments: [now, capsuleID]
            )
        }
    }

    func markCapsuleUsed(_ capsuleID: Int64) {
        try? writer.write { db in
            let now = Date()
            try db.execute(
                sql: "UPDATE clipboardCapsule SET lastUsedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, capsuleID]
            )
        }
    }

    private static func normalizedCapsuleName(
        _ proposedName: String,
        items: [ClipboardHistoryItem]
    ) -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(48)) }
        let first = items[0].displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = first.isEmpty ? "新胶囊" : String(first.prefix(24))
        return items.count == 1 ? base : "\(base) 等 \(items.count) 项"
    }
}

enum ClipboardCapsuleStoreError: Error, Equatable {
    case emptyCapsule
    case missingIdentifier
}
