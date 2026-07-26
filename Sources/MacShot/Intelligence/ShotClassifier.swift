import Foundation

/// 规则分类器：bundleID → 中文分类名。
///
/// 零成本、零延迟、可预测 —— 截图的来源 App 几乎决定了它的内容类型。
/// 规则不求全，兜底「其它」；真·语义分类（CLIP 向量）留给后续的处理器，
/// 它落的是另一个 key，不跟这里打架。
struct ShotClassifier {

    static let fallback = "其它"

    /// 展示顺序固定的全部分类。
    static let allCategories = [
        "代码", "浏览器", "聊天", "设计", "终端", "文档", "笔记", "影音", "效率", fallback
    ]

    /// 前缀 / 包含规则表。先查精确与前缀，再退化到包含匹配。
    /// 匹配一律用小写。
    private static let prefixRules: [(prefix: String, category: String)] = [
        // 代码
        ("com.apple.dt.xcode", "代码"),
        ("com.microsoft.vscode", "代码"),
        ("com.vscodium", "代码"),
        ("com.jetbrains.", "代码"),
        ("com.sublimetext.", "代码"),
        ("com.todesktop.230313mzl4w4u92", "代码"),     // Cursor
        ("dev.zed.zed", "代码"),
        ("com.github.atom", "代码"),
        ("com.panic.nova", "代码"),
        ("com.github.githubclient", "代码"),           // GitHub Desktop
        ("com.fournova.tower", "代码"),
        ("co.gitup.mac", "代码"),
        ("com.sourcetreeapp.", "代码"),
        ("com.torusknot.sourcetreenotmas", "代码"),
        // 浏览器
        ("com.apple.safari", "浏览器"),
        ("com.google.chrome", "浏览器"),
        ("company.thebrowser.browser", "浏览器"),      // Arc
        ("com.microsoft.edgemac", "浏览器"),
        ("org.mozilla.firefox", "浏览器"),
        ("com.brave.browser", "浏览器"),
        ("com.operasoftware.opera", "浏览器"),
        ("com.vivaldi.vivaldi", "浏览器"),
        ("ru.keepcoder.telegram", "聊天"),
        // 聊天
        ("com.tencent.xinwechat", "聊天"),             // 微信
        ("com.tencent.wechat", "聊天"),
        ("com.tencent.qq", "聊天"),
        ("com.tdesktop.telegram", "聊天"),
        ("org.telegram.desktop", "聊天"),
        ("com.tinyspeck.slackmacgap", "聊天"),         // Slack
        ("com.electron.lark", "聊天"),                 // 飞书
        ("com.bytedance.lark", "聊天"),
        ("com.alibaba.dingtalkmac", "聊天"),           // 钉钉
        ("com.hnc.discord", "聊天"),
        ("com.discordapp.discord", "聊天"),
        ("net.whatsapp.whatsapp", "聊天"),
        ("com.apple.messages", "聊天"),
        ("com.apple.facetime", "聊天"),
        ("us.zoom.xos", "聊天"),
        ("com.microsoft.teams", "聊天"),
        // 设计
        ("com.figma.desktop", "设计"),
        ("com.bohemiancoding.sketch3", "设计"),
        ("com.adobe.photoshop", "设计"),
        ("com.adobe.illustrator", "设计"),
        ("com.adobe.", "设计"),
        ("com.pixelmatorteam.", "设计"),
        ("com.seriflabs.affinity", "设计"),
        ("org.blenderfoundation.blender", "设计"),
        ("com.canva.canvaeditor", "设计"),
        // 终端
        ("com.apple.terminal", "终端"),
        ("com.googlecode.iterm2", "终端"),
        ("dev.warp.warp", "终端"),
        ("net.kovidgoyal.kitty", "终端"),
        ("com.github.wez.wezterm", "终端"),
        ("org.alacritty", "终端"),
        ("com.mitchellh.ghostty", "终端"),
        // 文档
        ("com.microsoft.word", "文档"),
        ("com.microsoft.excel", "文档"),
        ("com.microsoft.powerpoint", "文档"),
        ("com.apple.iwork.pages", "文档"),
        ("com.apple.iwork.numbers", "文档"),
        ("com.apple.iwork.keynote", "文档"),
        ("com.apple.preview", "文档"),
        ("com.readdle.pdfexpert-mac", "文档"),
        ("com.kingsoft.wpsoffice.mac", "文档"),
        ("net.sourceforge.skim-app.skim", "文档"),
        // 笔记
        ("md.obsidian", "笔记"),
        ("notion.id", "笔记"),
        ("abnerworks.typora", "笔记"),
        ("net.shinyfrog.bear", "笔记"),
        ("com.apple.notes", "笔记"),
        ("com.logseq.logseq", "笔记"),
        ("com.evernote.evernote", "笔记"),
        ("com.yinxiang.mac", "笔记"),
        ("com.roamresearch.roam", "笔记"),
        ("com.flomoapp.mac", "笔记"),
        // 影音
        ("com.apple.music", "影音"),
        ("com.apple.tv", "影音"),
        ("com.apple.quicktimeplayerx", "影音"),
        ("com.spotify.client", "影音"),
        ("com.colliderli.iina", "影音"),
        ("org.videolan.vlc", "影音"),
        ("com.netease.163music", "影音"),
        ("com.tencent.qqmusicmac", "影音"),
        ("tv.danmaku.bili", "影音"),
        ("com.bilibili.", "影音"),
        ("com.apple.podcasts", "影音"),
        // 效率
        ("com.apple.mail", "效率"),
        ("com.apple.ical", "效率"),
        ("com.apple.reminders", "效率"),
        ("com.apple.finder", "效率"),
        ("com.culturedcode.thingsmac", "效率"),
        ("com.omnigroup.omnifocus", "效率"),
        ("com.todoist.mac.todoist", "效率"),
        ("com.ticktick.task.mac", "效率"),
        ("com.raycast.macos", "效率"),
        ("com.runningwithcrayons.alfred", "效率"),
        ("com.microsoft.outlook", "效率"),
        ("com.readdle.smartemail-macos", "效率")       // Spark
    ]

    /// 兜底的包含关键词，处理换壳 / 变种 bundleID。
    private static let containsRules: [(keyword: String, category: String)] = [
        ("jetbrains", "代码"),
        ("intellij", "代码"),
        ("pycharm", "代码"),
        ("webstorm", "代码"),
        ("goland", "代码"),
        ("clion", "代码"),
        ("rider", "代码"),
        ("vscode", "代码"),
        ("chrome", "浏览器"),
        ("firefox", "浏览器"),
        ("browser", "浏览器"),
        ("telegram", "聊天"),
        ("wechat", "聊天"),
        ("slack", "聊天"),
        ("discord", "聊天"),
        ("figma", "设计"),
        ("sketch", "设计"),
        ("photoshop", "设计"),
        ("terminal", "终端"),
        ("iterm", "终端"),
        ("obsidian", "笔记"),
        ("notion", "笔记"),
        ("music", "影音"),
        ("video", "影音"),
        ("player", "影音")
    ]

    /// 分类。没有 bundleID 或没有命中任何规则时返回「其它」。
    static func classify(bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return fallback }
        let lower = bundleID.lowercased()

        for rule in prefixRules where lower == rule.prefix || lower.hasPrefix(rule.prefix) {
            return rule.category
        }
        for rule in containsRules where lower.contains(rule.keyword) {
            return rule.category
        }
        return fallback
    }
}
