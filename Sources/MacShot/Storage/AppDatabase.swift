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

        // ⚠️ 给 shot 加可搜索字段时必须**重建** shotFts：
        // `synchronize(withTable:)` 生成的触发器绑定的是建表那一刻的列集合，
        // 后续 ALTER TABLE 加的列不会被自动索引，加了也搜不到。
        // 正确做法是新写一个迁移，drop 掉 shotFts 再按新列集重建（会重新索引全表）。
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

        // 通用派生属性表。取代「一个派生属性 = 一个数据库列 + 一个 updateXXX 方法」，
        // 让新的后处理器（CLIP 向量、自动标签、分类结果）落地时不必改 schema。
        migrator.registerMigration("v3_attributes") { db in
            try db.create(table: "shotAttribute") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("shotID", .integer)
                    .notNull()
                    .indexed()
                    .references("shot", onDelete: .cascade)
                t.column("key", .text).notNull()
                /// 可搜索的文本表示。
                t.column("text", .text)
                /// 二进制载荷（向量之类）。
                t.column("payload", .blob)
                t.column("createdAt", .datetime).notNull()

                // 同一张图的同一个 key 只保留最新的一份。
                t.uniqueKey(["shotID", "key"])
            }

            // 属性单独一张 FTS 表，而不是往 shotFts 上加列 ——
            // synchronize 的触发器绑定建表时的列集合，加列不会被索引。
            try db.create(virtualTable: "attributeFts", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.synchronize(withTable: "shotAttribute")
                t.column("text")
            }
        }

        return migrator
    }
}
