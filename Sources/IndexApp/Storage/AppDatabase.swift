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
        // 单值 key 的「同图同 key 只留一份」语义由 `ShotAttributeRepository`
        // 的先删后插保证（约束只是兜底）；标签幂等由同仓库的 EXISTS 预查保证。
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

        // 录像和分子来源不是“派生属性”，而是 Shot 封面所代表的原始资产。
        // v6 把这两类载荷迁入有明确用途和格式版本的附件表；旧 key 仅在
        // 本迁移中读取，运行期业务统一走 ShotReading / ShotWriting 的附件接口。
        migrator.registerMigration("v6_shot_assets") { db in
            try db.create(table: "shotAsset") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("shotID", .integer)
                    .notNull()
                    .references("shot", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("path", .text)
                t.column("payload", .blob)
                t.column("schemaVersion", .integer).notNull().defaults(to: 1)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["shotID", "kind"])
            }
            try db.create(indexOn: "shotAsset", columns: ["kind", "shotID"])

            // v4 允许同 key 多行；迁移时以最大 id 作为最后写入值，恢复单值语义。
            try db.execute(sql: """
                INSERT INTO shotAsset (
                    shotID, kind, path, schemaVersion, createdAt, updatedAt
                )
                SELECT a.shotID, ?, CAST(a.payload AS TEXT),
                       1, a.createdAt, a.createdAt
                FROM shotAttribute a
                WHERE a.key = ? AND a.payload IS NOT NULL
                  AND a.id = (
                      SELECT MAX(newest.id) FROM shotAttribute newest
                      WHERE newest.shotID = a.shotID AND newest.key = a.key
                  )
                """, arguments: [
                    ShotAssetKind.recording,
                    LegacyAttributeKey.recordingPath,
                ])

            try db.execute(sql: """
                INSERT INTO shotAsset (
                    shotID, kind, payload, schemaVersion, createdAt, updatedAt
                )
                SELECT a.shotID, ?, a.payload,
                       1, a.createdAt, a.createdAt
                FROM shotAttribute a
                WHERE a.key = ? AND a.payload IS NOT NULL
                  AND a.id = (
                      SELECT MAX(newest.id) FROM shotAttribute newest
                      WHERE newest.shotID = a.shotID AND newest.key = a.key
                  )
                """, arguments: [
                    ShotAssetKind.moleculeXYZ,
                    LegacyAttributeKey.moleculeXYZSource,
                ])

            // 新表成为唯一真相；同步 FTS 触发器会同时移除旧属性索引行。
            try db.execute(
                sql: "DELETE FROM shotAttribute WHERE key IN (?, ?)",
                arguments: [LegacyAttributeKey.recordingPath, LegacyAttributeKey.moleculeXYZSource]
            )

            // 现有 (shotID, key) 适合“查某张图的属性”，反向按 key 聚合需要另一顺序。
            try db.create(indexOn: "shotAttribute", columns: ["key", "shotID"])
            // 专题封面预览按 collectionID 过滤、再按用户顺序和加入时间排序。
            try db.create(
                indexOn: "shotCollectionItem",
                columns: ["collectionID", "sortOrder", "addedAt"]
            )
        }

        // 用户给截图起的名称只是一等元数据，不触碰内容寻址的原图文件。新增可搜索
        // shot 列后必须重建同步 FTS；旧触发器只认识建表当时的列集合。
        migrator.registerMigration("v7_custom_title") { db in
            // FTS 同步触发器挂在内容表 shot 上，不属于 shotFts 虚表；只 drop 虚表
            // 不会带走它们，随后重建会因同名触发器而失败。
            for suffix in ["ai", "ad", "au"] {
                try db.execute(sql: "DROP TRIGGER IF EXISTS __shotFts_\(suffix)")
            }
            try db.drop(table: "shotFts")
            try db.alter(table: "shot") { t in
                t.add(column: "customTitle", .text)
            }
            try db.create(virtualTable: "shotFts", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.synchronize(withTable: "shot")
                t.column("customTitle")
                t.column("appName")
                t.column("windowTitle")
                t.column("sourceURL")
                t.column("ocrText")
            }
        }

        // 原图扩展名：导入的 SVG 保留矢量文件（<sha>.svg），截图仍是 <sha>.png。
        // 不进 FTS（不是搜索字段），不需要重建虚表。
        migrator.registerMigration("v8_original_extension") { db in
            try db.execute(sql: "ALTER TABLE shot ADD COLUMN originalExtension TEXT DEFAULT 'png'")
        }

        // 剪贴板历史：独立于 shot（文本/链接/颜色条目没有对应截图行）。
        // contentHash 唯一索引做去重——同一内容再次复制只更新时间，不新增行。
        // 图片条目复用 sha256 内容寻址，与图库天然互通。
        migrator.registerMigration("v9_clipboard_history") { db in
            try db.create(table: "clipboardHistory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()          // text / image / file
                t.column("contentHash", .text).notNull().unique()
                t.column("text", .text)                    // kind=text 时的内容
                t.column("assetPath", .text)               // kind=image/file 时的落盘路径（相对）
                t.column("summary", .text)                 // 列表展示用摘要（文本截断/文件名）
                t.column("sourceApp", .text)               // 复制来源 App 名
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("capturedAt", .datetime).notNull().indexed()
                t.column("lastUsedAt", .datetime)
            }
        }

        // 剪贴板条目手动命名 + 收藏：title 是用户起的名字（覆盖 summary 展示），
        // isFavorite 让条目出现在收藏 tab 的剪贴板 section，且豁免保留期清理。
        migrator.registerMigration("v10_clipboard_title_favorite") { db in
            try db.execute(sql: "ALTER TABLE clipboardHistory ADD COLUMN title TEXT")
            try db.execute(sql: "ALTER TABLE clipboardHistory ADD COLUMN isFavorite BOOLEAN NOT NULL DEFAULT 0")
        }

        // 剪贴板条目加入专题收藏集：独立关联表（shotCollectionItem 的 shotID 有外键指向 shot，
        // 不能复用）。删除剪贴板条目或专题集都级联清理。
        migrator.registerMigration("v11_clipboard_collection_item") { db in
            try db.create(table: "clipboardCollectionItem") { t in
                t.column("collectionID", .integer)
                    .notNull()
                    .references("shotCollection", onDelete: .cascade)
                t.column("clipboardID", .integer)
                    .notNull()
                    .references("clipboardHistory", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["collectionID", "clipboardID"])
            }
            try db.create(indexOn: "clipboardCollectionItem", columns: ["clipboardID"])
        }

        // 结构化内容：shot 表加 contentKind 列（卡片渲染分发用，O(1) 读取），
        // 通用内容记录表 shotContent（1:1 关联 shot，不是所有 shot 都有记录），
        // 以及第一个类型专属扩展表 contentCode。
        migrator.registerMigration("v12_shot_content") { db in
            try db.execute(sql: "ALTER TABLE shot ADD COLUMN contentKind TEXT NOT NULL DEFAULT 'image'")
            try db.create(indexOn: "shot", columns: ["contentKind"])

            try db.create(table: "shotContent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("shotID", .integer)
                    .notNull()
                    .unique()
                    .references("shot", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 1.0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "shotContent", columns: ["kind"])

            try db.create(table: "contentCode") { t in
                t.column("contentID", .integer)
                    .notNull()
                    .references("shotContent", onDelete: .cascade)
                t.column("language", .text)
                t.column("text", .text).notNull()
                t.primaryKey(["contentID"])
            }
        }

        // Markdown 类型专属扩展表。
        // Markdown 是一等公民：截图自动生成 + 手动新建，
        // source 是 Markdown 原文，卡片中间区域排版渲染。
        migrator.registerMigration("v13_content_markdown") { db in
            try db.create(table: "contentMarkdown") { t in
                t.column("contentID", .integer)
                    .notNull()
                    .references("shotContent", onDelete: .cascade)
                t.column("source", .text).notNull()
                t.primaryKey(["contentID"])
            }
        }

        // Agent 对话记录：conversation 是会话（命名 20260822-a3f2），
        // message 是单条消息（user/assistant，工具调用过程存 JSON）。
        migrator.registerMigration("v14_agent_conversation") { db in
            try db.create(table: "agentConversation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "agentMessage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationID", .integer)
                    .notNull()
                    .indexed()
                    .references("agentConversation", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("text", .text).notNull().defaults(to: "")
                t.column("toolCallsJSON", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
