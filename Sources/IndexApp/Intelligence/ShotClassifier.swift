import Foundation

/// 规则分类器：bundleID → 中文分类名。
///
/// 零成本、零延迟、可预测 —— 截图的来源 App 几乎决定了它的内容类型。
/// 规则不求全，兜底「其它」；真·语义分类（CLIP 向量）留给后续的处理器，
/// 它落的是另一个 key，不跟这里打架。
struct ShotClassifier {

    /// 单一事实来源：所有分类的枚举。
    /// rawValue 即落库 / 展示用的中文名，新增分类只需在此加一 case，
    /// 其余地方（规则表、颜色）一律用 case 关联，不再散落字符串字面量。
    enum Category: String, CaseIterable, Sendable, Hashable {
        case code = "代码"
        case browser = "浏览器"
        case chat = "聊天"
        case design = "设计"
        case terminal = "终端"
        case document = "文档"
        case note = "笔记"
        case media = "影音"
        case productivity = "效率"
        case other = "其它"
    }

    /// 兼容旧的字符串兜底常量。枚举兜底为 `.other`，字符串兜底为其 rawValue。
    static let fallback: String = Category.other.rawValue
    static let fallbackCategory: Category = .other

    /// 展示顺序固定的全部分类（枚举）。
    static let allCategories: [Category] = Category.allCases

    /// 字符串形态的全部分类（供旧的 String 场景 / 展示用）。
    static let allCategoryNames: [String] = allCategories.map(\.rawValue)

    /// 前缀 / 包含规则表。先查精确与前缀，再退化到包含匹配。
    /// 匹配一律用小写；category 关联到 `Category` 枚举而非硬编码字符串。
    private static let prefixRules: [(prefix: String, category: Category)] = [
        // 代码
        ("com.apple.dt.xcode", .code),
        ("com.microsoft.vscode", .code),
        ("com.vscodium", .code),
        ("com.jetbrains.", .code),
        ("com.sublimetext.", .code),
        ("com.todesktop.230313mzl4w4u92", .code),     // Cursor
        ("dev.zed.zed", .code),
        ("com.github.atom", .code),
        ("com.panic.nova", .code),
        ("com.github.githubclient", .code),           // GitHub Desktop
        ("com.fournova.tower", .code),
        ("co.gitup.mac", .code),
        ("com.sourcetreeapp.", .code),
        ("com.torusknot.sourcetreenotmas", .code),
        // 浏览器
        ("com.apple.safari", .browser),
        ("com.google.chrome", .browser),
        ("company.thebrowser.browser", .browser),      // Arc
        ("com.microsoft.edgemac", .browser),
        ("org.mozilla.firefox", .browser),
        ("com.brave.browser", .browser),
        ("com.operasoftware.opera", .browser),
        ("com.vivaldi.vivaldi", .browser),
        ("ru.keepcoder.telegram", .chat),
        // 聊天
        ("com.tencent.xinwechat", .chat),             // 微信
        ("com.tencent.wechat", .chat),
        ("com.tencent.qq", .chat),
        ("com.tdesktop.telegram", .chat),
        ("org.telegram.desktop", .chat),
        ("com.tinyspeck.slackmacgap", .chat),         // Slack
        ("com.electron.lark", .chat),                 // 飞书
        ("com.bytedance.lark", .chat),
        ("com.alibaba.dingtalkmac", .chat),           // 钉钉
        ("com.hnc.discord", .chat),
        ("com.discordapp.discord", .chat),
        ("net.whatsapp.whatsapp", .chat),
        ("com.apple.messages", .chat),
        ("com.apple.facetime", .chat),
        ("us.zoom.xos", .chat),
        ("com.microsoft.teams", .chat),
        // 设计
        ("com.figma.desktop", .design),
        ("com.bohemiancoding.sketch3", .design),
        ("com.adobe.photoshop", .design),
        ("com.adobe.illustrator", .design),
        ("com.adobe.", .design),
        ("com.pixelmatorteam.", .design),
        ("com.seriflabs.affinity", .design),
        ("org.blenderfoundation.blender", .design),
        ("com.canva.canvaeditor", .design),
        // 终端
        ("com.apple.terminal", .terminal),
        ("com.googlecode.iterm2", .terminal),
        ("dev.warp.warp", .terminal),
        ("net.kovidgoyal.kitty", .terminal),
        ("com.github.wez.wezterm", .terminal),
        ("org.alacritty", .terminal),
        ("com.mitchellh.ghostty", .terminal),
        // 文档
        ("com.microsoft.word", .document),
        ("com.microsoft.excel", .document),
        ("com.microsoft.powerpoint", .document),
        ("com.apple.iwork.pages", .document),
        ("com.apple.iwork.numbers", .document),
        ("com.apple.iwork.keynote", .document),
        ("com.apple.preview", .document),
        ("com.readdle.pdfexpert-mac", .document),
        ("com.kingsoft.wpsoffice.mac", .document),
        ("net.sourceforge.skim-app.skim", .document),
        // 笔记
        ("md.obsidian", .note),
        ("notion.id", .note),
        ("abnerworks.typora", .note),
        ("net.shinyfrog.bear", .note),
        ("com.apple.notes", .note),
        ("com.logseq.logseq", .note),
        ("com.evernote.evernote", .note),
        ("com.yinxiang.mac", .note),
        ("com.roamresearch.roam", .note),
        ("com.flomoapp.mac", .note),
        // 影音
        ("com.apple.music", .media),
        ("com.apple.tv", .media),
        ("com.apple.quicktimeplayerx", .media),
        ("com.spotify.client", .media),
        ("com.colliderli.iina", .media),
        ("org.videolan.vlc", .media),
        ("com.netease.163music", .media),
        ("com.tencent.qqmusicmac", .media),
        ("tv.danmaku.bili", .media),
        ("com.bilibili.", .media),
        ("com.apple.podcasts", .media),
        // 效率
        ("com.apple.mail", .productivity),
        ("com.apple.ical", .productivity),
        ("com.apple.reminders", .productivity),
        ("com.apple.finder", .productivity),
        ("com.culturedcode.thingsmac", .productivity),
        ("com.omnigroup.omnifocus", .productivity),
        ("com.todoist.mac.todoist", .productivity),
        ("com.ticktick.task.mac", .productivity),
        ("com.raycast.macos", .productivity),
        ("com.runningwithcrayons.alfred", .productivity),
        ("com.microsoft.outlook", .productivity),
        ("com.readdle.smartemail-macos", .productivity)       // Spark
    ]

    /// 兜底的包含关键词，处理换壳 / 变种 bundleID。
    private static let containsRules: [(keyword: String, category: Category)] = [
        ("jetbrains", .code),
        ("intellij", .code),
        ("pycharm", .code),
        ("webstorm", .code),
        ("goland", .code),
        ("clion", .code),
        ("rider", .code),
        ("vscode", .code),
        ("chrome", .browser),
        ("firefox", .browser),
        ("browser", .browser),
        ("telegram", .chat),
        ("wechat", .chat),
        ("slack", .chat),
        ("discord", .chat),
        ("figma", .design),
        ("sketch", .design),
        ("photoshop", .design),
        ("terminal", .terminal),
        ("iterm", .terminal),
        ("obsidian", .note),
        ("notion", .note),
        ("music", .media),
        ("video", .media),
        ("player", .media)
    ]

    /// 分类（枚举）。没有 bundleID 或没有命中任何规则时返回 `.other`。
    static func classify(bundleID: String?) -> Category {
        guard let bundleID, !bundleID.isEmpty else { return fallbackCategory }
        let lower = bundleID.lowercased()

        for rule in prefixRules where lower == rule.prefix || lower.hasPrefix(rule.prefix) {
            return rule.category
        }
        for rule in containsRules where lower.contains(rule.keyword) {
            return rule.category
        }
        return fallbackCategory
    }

    /// 字符串形态的分类（落库 / 旧接口兼容）。
    static func classifyName(bundleID: String?) -> String {
        classify(bundleID: bundleID).rawValue
    }
}

// MARK: - 向后兼容：旧代码调 `ShotClassifier.classify(bundleID:) -> String`
// 保留同名重载会与枚举版本冲突，故提供扩展形式的字符串入口；
// 若外部仍期望 String，可显式调 `classifyName`。
extension ShotClassifier {
    /// 已弃用：请使用 `classify(bundleID:) -> Category` 并取 `rawValue`，或直接用 `classifyName`。
    @available(*, deprecated, message: "Use classify(bundleID:) -> Category or classifyName(bundleID:) -> String")
    static func classifyString(bundleID: String?) -> String {
        classifyName(bundleID: bundleID)
    }
}
