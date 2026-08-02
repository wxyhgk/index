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

        // 用户标签落地：同一张图要能有多行 key='tag'，v3 的表级
        // UNIQUE(shotID, key) 挡在前面，只能重建表去掉它。
        // 单值 key 的「同图同 key 只留一份」语义由 `ShotStore.writeAttribute`
        // 的先删后插保证（它本来就这么写的，约束只是兜底）；
        // 标签的幂等由 `addTag` 的 EXISTS 预查保证。
        //
        // 重建步骤有讲究：attributeFts 的同步触发器挂在 shotAttribute 上，
        // 直接改名会连触发器一起改写。这里走「建新表 → 拷数据（保留 id，
        // FTS 的 rowid 就是它）→ 删旧表（触发器随表自动删）→ 新表改名 →
        // 重建 attributeFts」——synchronize 建表时会执行 FTS5 的 'rebuild'，
        // 存量属性全部重新索引，搜索无缝衔接。
        migrator.registerMigration("v4_multivalue_attributes") { db in
            try db.create(table: "shotAttributeNew") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("shotID", .integer)
                    .notNull()
                    .references("shot", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("text", .text)
                t.column("payload", .blob)
                t.column("createdAt", .datetime).notNull()
            }
            try db.execute(sql: """
                INSERT INTO shotAttributeNew (id, shotID, key, text, payload, createdAt)
                SELECT id, shotID, key, text, payload, createdAt FROM shotAttribute
                """)
            try db.drop(table: "shotAttribute")
            try db.drop(table: "attributeFts")
            try db.rename(table: "shotAttributeNew", to: "shotAttribute")
            // 复合索引同时服务「按图查属性」和「按图 + key 查值」两类查询。
            try db.create(indexOn: "shotAttribute", columns: ["shotID", "key"])

            try db.create(virtualTable: "attributeFts", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.synchronize(withTable: "shotAttribute")
                t.column("text")
            }
        }

        // 导入本地图片：原始文件**原样保存**，所以要记住它的扩展名。
        //
        // 在此之前整条链写死 PNG（`originals/<sha>.png`）—— 截图自己产出的就是 PNG，
        // 无所谓；但导入一张 3MB 的 JPEG 若重新编码成 PNG 会膨胀到十几 MB，
        // 动图 GIF 更是直接丢掉动画。所以导入走「保留原字节」，
        // 文件名变成 `<sha>.<ext>`，这一列就是那个 ext。
        //
        // 可空，且**不回填**：nil 一律当 "png"（见 `Shot.originalFileName`）。
        // 老记录本来就都是 PNG，回填一遍只是把同一件事写两处。
        //
        // ⚠️ 刻意**不往 shotFts 加列**：那张虚表的同步触发器绑定建表时的列集合，
        // 加列要整表重建（ARCHITECTURE §5 第 6 条记着这个坑）。
        // 导入文件名走属性表（`AttributeKey.importName`），它经 attributeFts 一样可搜。
        migrator.registerMigration("v5_import_format") { db in
            try db.alter(table: "shot") { t in
                t.add(column: "fileExtension", .text)
            }
        }

        return migrator
    }
}
