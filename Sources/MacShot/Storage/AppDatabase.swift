import Foundation
import GRDB

/// SQLite schema + 迁移。数据访问全部走这里，方便将来替换实现。
enum AppDatabase {

    /// 打开数据库并迁移到最新。
    ///
    /// 用 `DatabasePool` + WAL，而不是 `DatabaseQueue` + 默认的回滚日志：
    ///   · `DatabaseQueue` 是**串行**的 —— 所有读和写排在同一条队列上，
    ///     一次写入会把所有读堵住；
    ///   · 回滚日志模式下每次写都要 fsync 整个数据库文件，而 WAL 只追加日志，
    ///     写入代价低一个量级，**并且读不会被写阻塞**（读的是写入前的快照）。
    ///
    /// 这是「数据库读写移出主线程」的地基：只有多个读连接同时可用，
    /// 把重查询挪到后台才有意义 —— 否则后台读一样会排在主线程那次写后面。
    static func makeWriter(at url: URL) throws -> DatabasePool {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // 读连接数。截图库的并发读来自：网格列表、侧边栏计数、详情栏、缩略图、
        // 后台回填 —— 4 个足够，再多只是白占文件描述符。
        config.maximumReaderCount = 4

        let pool = try DatabasePool(path: url.path, configuration: config)
        try migrator.migrate(pool)
        return pool
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

        // 用户专题收藏集。成员表只保存 Shot 引用，不复制原图；同一张图可以属于
        // 多个专题集。删除专题集只级联删除成员关系，删除截图则自动清理所有关系。
        migrator.registerMigration("v5_shot_collections") { db in
            try db.create(table: "shotCollection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("coverShotID", .integer)
                    .references("shot", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            // 名称是用户辨认专题集的主标识，大小写不同不应制造两个看似同名的集合。
            try db.execute(sql: """
                CREATE UNIQUE INDEX shotCollection_name_nocase
                ON shotCollection(name COLLATE NOCASE)
                """)

            try db.create(table: "shotCollectionItem") { t in
                t.column("collectionID", .integer)
                    .notNull()
                    .references("shotCollection", onDelete: .cascade)
                t.column("shotID", .integer)
                    .notNull()
                    .references("shot", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.primaryKey(["collectionID", "shotID"])
            }
            try db.create(indexOn: "shotCollectionItem", columns: ["shotID"])
        }

        return migrator
    }
}
