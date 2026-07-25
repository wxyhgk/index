import Foundation
import GRDB

/// SQLite schema + 迁移。数据访问全部走这里，方便将来替换实现。
enum AppDatabase {

    static func makeWriter(at url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_shots") { db in
            try db.create(table: "shot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sha256", .text).notNull().indexed()
                t.column("capturedAt", .datetime).notNull().indexed()

                t.column("pixelWidth", .integer).notNull()
                t.column("pixelHeight", .integer).notNull()
                t.column("scale", .double).notNull().defaults(to: 2.0)

                t.column("appName", .text)
                t.column("appBundleID", .text).indexed()
                t.column("appVersion", .text)
                t.column("appBuild", .text)
                t.column("windowTitle", .text)
                t.column("sourceURL", .text)
                t.column("displayID", .integer)
                t.column("displayName", .text)

                t.column("regionX", .double).notNull().defaults(to: 0)
                t.column("regionY", .double).notNull().defaults(to: 0)
                t.column("regionW", .double).notNull().defaults(to: 0)
                t.column("regionH", .double).notNull().defaults(to: 0)

                t.column("ocrText", .text)
            }

            try db.create(table: "revision") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("shotID", .integer)
                    .notNull()
                    .indexed()
                    .references("shot", onDelete: .cascade)
                t.column("parentID", .integer).references("revision", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
                t.column("note", .text)
                t.column("layersJSON", .text).notNull().defaults(to: "[]")
            }
        }

        migrator.registerMigration("v2_fts") { db in
            // trigram 分词器：对中文子串搜索友好（unicode61 不切分 CJK）。
            try db.create(virtualTable: "shotFts", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.synchronize(withTable: "shot")
                t.column("appName")
                t.column("windowTitle")
                t.column("sourceURL")
                t.column("ocrText")
            }
        }

        return migrator
    }
}
