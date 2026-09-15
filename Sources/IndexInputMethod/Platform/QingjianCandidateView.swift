import AppKit

// MARK: - 候选窗口内容视图
//
// 自绘顶部拼音行与若干候选，横排排成一行，一项高亮。
// 参考 qingjian apps/macos/src/candidates/view.rs。

final class QingjianCandidateView: NSView {

    var theme = QingjianTheme.systemDefault
    private var rows: [QingjianCandidateRow] = []
    private var highlighted: Int = 0
    private var footer: String?
    private var preedit: [(text: String, style: QingjianPreeditStyle)] = []
    private var preeditCursor: Int = 0

    // MARK: 常量

    private let caretWidth: CGFloat = 1.5
    private let indexGap: CGFloat = 3
    private let highlightInset: CGFloat = 5
    private let sentenceGap: CGFloat = 16

    // MARK: 状态

    var onSelect: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 横排候选行区域可点击
        let (items, rowHeight) = self.items(for: rows)
        let topY = theme.padding + topLineHeight()
        let bodyY = topY
        let bodyHeight = rowHeight
        if point.y >= bodyY, point.y <= bodyY + bodyHeight {
            var x = theme.padding + highlightInset
            for (i, item) in items.enumerated() {
                let itemWidth = item.indexWidth + indexGap + item.textWidth
                if point.x >= x, point.x <= x + itemWidth {
                    onSelect?(i)
                    return self
                }
                x += itemWidth + theme.columnGap
            }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds

        // 背景
        theme.background.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: theme.cornerRadius, yRadius: theme.cornerRadius)
        path.fill()

        var y = theme.padding
        y += drawTopLine(y: y, bounds: bounds)
        drawHorizontal(y: y, bounds: bounds)
    }

    // MARK: 顶部拼音行

    private func topLineHeight() -> CGFloat {
        if preedit.isEmpty { return 0 }
        let lineH = measure("x", font: theme.annotationFont).height
        return lineH + theme.rowPadding * 2
    }

    private func drawTopLine(y: CGFloat, bounds: NSRect) -> CGFloat {
        if preedit.isEmpty { return 0 }
        let lineH = measure("x", font: theme.annotationFont).height
        let top = y + theme.rowPadding
        var x = theme.padding

        // 各段按样式画
        var cursorX = x
        for segment in preedit {
            let color: NSColor
            let strike: Bool
            switch segment.style {
            case .typed:
                color = theme.glossColor
                strike = false
            case .rest:
                color = theme.posColor
                strike = false
            case .struck:
                color = theme.posColor
                strike = true
            }
            let size = drawText(segment.text, font: theme.annotationFont, color: color, y: top, x: x, strike: strike)
            cursorX += measure(segment.text, font: theme.annotationFont).width
            x += size
        }

        // 自绘光标
        let beforeCursor = preedit.prefix { _ in true }
            .reduce(0) { $0 + $1.text.count }
        let cursorOffset = min(preeditCursor, beforeCursor)
        var beforeWidth: CGFloat = 0
        var remaining = cursorOffset
        for segment in preedit {
            let segLen = segment.text.count
            if remaining >= segLen {
                beforeWidth += measure(segment.text, font: theme.annotationFont).width
                remaining -= segLen
            } else {
                let prefix = String(segment.text.prefix(remaining))
                beforeWidth += measure(prefix, font: theme.annotationFont).width
                break
            }
        }
        let caretX = theme.padding + beforeWidth
        theme.textColor.setFill()
        NSBezierPath.fill(NSRect(x: caretX, y: top, width: caretWidth, height: lineH))

        return lineH + theme.rowPadding * 2
    }

    // MARK: 横排候选

    private struct Item {
        let indexWidth: CGFloat
        let textWidth: CGFloat
    }

    private func items(for rows: [QingjianCandidateRow]) -> (items: [Item], rowHeight: CGFloat) {
        var rowHeight: CGFloat = 0
        let items = rows.map { row -> Item in
            let indexWidth = measure(row.index, font: theme.indexFont).width
            let textWidth = measure(row.text, font: theme.textFont).width
            rowHeight = max(rowHeight, measure(row.text, font: theme.textFont).height + theme.rowPadding * 2)
            return Item(indexWidth: indexWidth, textWidth: textWidth)
        }
        return (items, rowHeight)
    }

    private func drawHorizontal(y: CGFloat, bounds: NSRect) {
        guard !rows.isEmpty else { return }
        let (items, rowHeight) = items(for: rows)
        let baseline = y + theme.rowPadding
        var x = theme.padding + highlightInset

        for ((i, row), item) in zip(rows.enumerated(), items) {
            let itemWidth = item.indexWidth + indexGap + item.textWidth

            // 高亮
            if i == highlighted {
                let rect = NSRect(x: x - highlightInset, y: y, width: itemWidth + highlightInset * 2, height: rowHeight)
                theme.highlight.setFill()
                NSBezierPath(roundedRect: rect, xRadius: theme.cornerRadius / 2, yRadius: theme.cornerRadius / 2).fill()
            }

            let textSize = measure(row.text, font: theme.textFont)
            // 序号
            drawText(row.index, font: theme.indexFont, color: theme.indexColor, y: baseline + smallOffset(textSize.height), x: x)
            // 候选词
            drawText(row.text, font: theme.textFont, color: theme.textColor, y: baseline, x: x + item.indexWidth + indexGap)

            x += itemWidth + theme.columnGap
        }

        // 页码
        if let footer {
            let size = measure(footer, font: theme.indexFont)
            let textHeight = measure("x", font: theme.textFont).height
            drawText(footer, font: theme.indexFont, color: theme.indexColor, y: baseline + smallOffset(textHeight), x: bounds.size.width - theme.padding - size.width)
        }

        // 高亮候选的 annotation（译文行）
        if let row = rows.indices.contains(highlighted) ? rows[highlighted] : nil {
            guard !row.annotation.isEmpty else { return }
            var annX = theme.padding + highlightInset
            let annTop = y + rowHeight + theme.rowPadding / 2
            for (segment, tone) in row.annotation {
                let color = toneColor(tone)
                annX += drawText(segment, font: theme.annotationFont, color: color, y: annTop, x: annX)
            }
        }
    }

    // MARK: 工具

    private func toneColor(_ tone: QingjianAnnotationTone) -> NSColor {
        switch tone {
        case .gloss: return theme.glossColor
        case .fresh: return theme.freshColor
        case .faint: return theme.posColor
        }
    }

    private func smallOffset(_ textHeight: CGFloat) -> CGFloat {
        let smallH = measure("x", font: theme.annotationFont).height
        return max(0, textHeight - smallH)
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, y: CGFloat, x: CGFloat, strike: Bool = false) -> CGFloat {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        if strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        let attributed = NSAttributedString(string: text, attributes: attrs)
        attributed.draw(at: NSPoint(x: x, y: y))
        return attributed.size().width
    }

    private func measure(_ text: String, font: NSFont) -> NSSize {
        NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: theme.textColor]
        ).size()
    }

    // MARK: 内容更新

    /// 更新内容并返回需要的窗口尺寸。
    func setContent(
        rows: [QingjianCandidateRow],
        highlighted: Int,
        footer: String?,
        preedit: [(text: String, style: QingjianPreeditStyle)],
        preeditCursor: Int
    ) -> NSSize {
        self.rows = rows
        self.highlighted = highlighted
        self.footer = footer
        self.preedit = preedit
        self.preeditCursor = preeditCursor
        needsDisplay = true
        return preferredSize()
    }

    private func preferredSize() -> NSSize {
        let topH = topLineHeight()
        guard !rows.isEmpty else {
            return NSSize(width: 0, height: 0)
        }
        let (items, rowHeight) = items(for: rows)
        var width: CGFloat = items
            .reduce(0) { $0 + $1.indexWidth + indexGap + $1.textWidth }
            + theme.columnGap * CGFloat(max(0, items.count - 1))
            + highlightInset * 2
        if let footer {
            width += theme.columnGap + measure(footer, font: theme.indexFont).width
        }
        var height = rowHeight
        // annotation 行
        if let row = rows.indices.contains(highlighted) ? rows[highlighted] : nil, !row.annotation.isEmpty {
            let annWidth: CGFloat = row.annotation.reduce(0) { $0 + measure($1.text, font: theme.annotationFont).width }
            width = max(width, annWidth)
            height += measure("x", font: theme.annotationFont).height + theme.rowPadding
        }
        // 顶部拼音行
        if !preedit.isEmpty {
            let preeditWidth: CGFloat = preedit.reduce(0) { $0 + measure($1.text, font: theme.annotationFont).width } + caretWidth
            width = max(width, preeditWidth)
            height += topH
        }
        width += theme.padding * 2
        height += theme.padding * 2
        return NSSize(width: width, height: height)
    }
}
