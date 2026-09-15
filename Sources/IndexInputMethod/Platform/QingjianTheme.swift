import AppKit

// MARK: - 候选窗口主题
//
// 字体、颜色、间距集中管理，方便后续从配置读或适配深色模式。
// 视觉层级（产品决定）：候选词最深，译文稍浅，词性最浅，序号弱化。
// 参考 qingjian apps/macos/src/candidates/theme.rs。

struct QingjianTheme {
    /// 候选词字体。
    var textFont: NSFont
    /// 译文与词性字体。
    var annotationFont: NSFont
    /// 序号字体。
    var indexFont: NSFont
    /// 候选词颜色。
    var textColor: NSColor
    /// 译文颜色。
    var glossColor: NSColor
    /// 词性颜色，比译文更浅。
    var posColor: NSColor
    /// 生词译文颜色：比普通译文醒目。
    var freshColor: NSColor
    /// 序号颜色。
    var indexColor: NSColor
    /// 云联想的云朵与文字颜色。
    var cloudColor: NSColor
    /// 窗口背景。
    var background: NSColor
    /// 当前候选的高亮底色。
    var highlight: NSColor
    /// 窗口内边距。
    var padding: CGFloat
    /// 行内上下留白。
    var rowPadding: CGFloat
    /// 序号与候选词、候选词与译文之间的间距。
    var columnGap: CGFloat
    /// 窗口与高亮条的圆角。
    var cornerRadius: CGFloat
    /// 最多显示几行（横排为几项）。
    var maxRows: Int

    /// 系统默认外观。
    static let systemDefault = QingjianTheme(
        textFont: .systemFont(ofSize: 16),
        annotationFont: .systemFont(ofSize: 12),
        indexFont: .systemFont(ofSize: 11),
        textColor: .labelColor,
        glossColor: .secondaryLabelColor,
        posColor: .tertiaryLabelColor,
        freshColor: .systemOrange,
        indexColor: .tertiaryLabelColor,
        cloudColor: .systemTeal,
        background: .windowBackgroundColor,
        highlight: NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 0.16),
        padding: 8,
        rowPadding: 4,
        columnGap: 8,
        cornerRadius: 8,
        maxRows: 9
    )
}

// MARK: - 拼音行片段样式

/// preedit（顶部拼音行）片段的画法。
enum QingjianPreeditStyle {
    /// 敲的拼音：正常深浅。
    case typed
    /// 光标后剩下的拼音：淡一点。
    case rest
    /// 被纠错改掉的字母：淡且带删除线。
    case struck
}

// MARK: - 候选行

/// 候选窗口的一行：序号、候选词、annotation 片段。
struct QingjianCandidateRow {
    let index: String
    let text: String
    /// 右侧 annotation，按顺序绘制；没有译文时为空。
    let annotation: [(text: String, tone: QingjianAnnotationTone)]
    /// 来自云联想：词前画一个小云朵。
    let cloud: Bool

    init(index: String, text: String, annotation: [(text: String, tone: QingjianAnnotationTone)] = [], cloud: Bool = false) {
        self.index = index
        self.text = text
        self.annotation = annotation
        self.cloud = cloud
    }
}

/// annotation 片段的深浅。
enum QingjianAnnotationTone {
    case gloss
    case fresh
    case faint
}
