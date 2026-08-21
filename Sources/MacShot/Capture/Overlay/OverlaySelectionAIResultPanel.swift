import AppKit

enum OverlaySelectionAIResultAction: Equatable {
    case copy(SelectionAIExportFormat)
    case close
}

struct OverlaySelectionAIResultActionSlot: Equatable {
    let action: OverlaySelectionAIResultAction
    let frame: CGRect
}

struct OverlaySelectionAIResultLayout: Equatable {
    let frame: CGRect
    let titleFrame: CGRect
    let bodyFrame: CGRect
    let actionSlots: [OverlaySelectionAIResultActionSlot]
}

struct OverlaySelectionAIResultRenderState {
    let document: SelectionAIResultDocument
    let layout: OverlaySelectionAIResultLayout
    let hovered: OverlaySelectionAIResultAction?
    let pressed: OverlaySelectionAIResultAction?
    let copied: SelectionAIExportFormat?
}

/// Capture Overlay 内嵌的结果卡片。它只计算布局、绘制和命中，不创建 NSPanel，
/// 因而不会改变截图窗口层级或引入新的平台弹窗副作用。
enum OverlaySelectionAIResultPanel {
    private static let preferredSize = CGSize(width: 420, height: 250)
    private static let margin: CGFloat = 10
    private static let padding: CGFloat = 14
    private static let titleHeight: CGFloat = 24
    private static let actionHeight: CGFloat = 30

    static func layout(
        document: SelectionAIResultDocument,
        near selection: CGRect,
        in bounds: CGRect
    ) -> OverlaySelectionAIResultLayout? {
        guard bounds.width >= 180, bounds.height >= 140 else { return nil }
        let size = CGSize(
            width: min(preferredSize.width, bounds.width - margin * 2),
            height: min(preferredSize.height, bounds.height - margin * 2)
        )

        var x = selection.maxX + margin
        if x + size.width > bounds.maxX - margin {
            x = selection.minX - margin - size.width
        }
        if x < bounds.minX + margin {
            x = selection.midX - size.width / 2
        }
        x = min(max(bounds.minX + margin, x), bounds.maxX - margin - size.width)
        let y = min(
            max(bounds.minY + margin, selection.midY - size.height / 2),
            bounds.maxY - margin - size.height
        )
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)

        let actionSlots = actionSlots(for: document, in: frame)
        let actionTop = actionSlots.map(\.frame.maxY).max() ?? (frame.minY + padding)
        return OverlaySelectionAIResultLayout(
            frame: frame,
            titleFrame: CGRect(
                x: frame.minX + padding,
                y: frame.maxY - padding - titleHeight,
                width: frame.width - padding * 2,
                height: titleHeight
            ),
            bodyFrame: CGRect(
                x: frame.minX + padding,
                y: actionTop + 10,
                width: frame.width - padding * 2,
                height: max(0, frame.maxY - padding - titleHeight - actionTop - 18)
            ),
            actionSlots: actionSlots
        )
    }

    static func draw(
        document: SelectionAIResultDocument,
        layout: OverlaySelectionAIResultLayout,
        hovered: OverlaySelectionAIResultAction?,
        pressed: OverlaySelectionAIResultAction?,
        copied: SelectionAIExportFormat?
    ) {
        DS.toolbarBackground.setFill()
        let panel = NSBezierPath(roundedRect: layout.frame, xRadius: DS.radiusLarge, yRadius: DS.radiusLarge)
        panel.fill()
        DS.toolbarStroke.setStroke()
        panel.lineWidth = DS.hairline
        panel.stroke()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: DS.font14, weight: .semibold),
            .foregroundColor: DS.toolbarForeground
        ]
        (title(for: document.kind) as NSString).draw(
            in: layout.titleFrame,
            withAttributes: titleAttributes
        )

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: document.kind == .formulaToLaTeX
                ? NSFont.monospacedSystemFont(ofSize: DS.font12, weight: .regular)
                : NSFont.systemFont(ofSize: DS.font12),
            .foregroundColor: DS.toolbarForeground
        ]
        (document.preview as NSString).draw(
            with: layout.bodyFrame,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: bodyAttributes
        )

        for slot in layout.actionSlots {
            let active = hovered == slot.action || pressed == slot.action
            (active ? DS.toolbarHover : DS.toolbarStroke).setFill()
            NSBezierPath(roundedRect: slot.frame, xRadius: DS.radiusSmall, yRadius: DS.radiusSmall).fill()

            let label: String
            switch slot.action {
            case let .copy(format):
                label = copied == format ? "已复制" : copyLabel(for: format)
            case .close:
                label = "关闭"
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: DS.toolbarForeground
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(
                at: CGPoint(
                    x: slot.frame.midX - size.width / 2,
                    y: slot.frame.midY - size.height / 2
                ),
                withAttributes: attrs
            )
        }
    }

    static func export(
        for action: OverlaySelectionAIResultAction,
        in document: SelectionAIResultDocument
    ) -> SelectionAIResultExport? {
        guard case let .copy(format) = action else { return nil }
        return document.exports.first { $0.format == format }
    }

    private static func actionSlots(
        for document: SelectionAIResultDocument,
        in panel: CGRect
    ) -> [OverlaySelectionAIResultActionSlot] {
        let actions = document.exports.map { OverlaySelectionAIResultAction.copy($0.format) } + [.close]
        let available = panel.width - padding * 2
        let spacing: CGFloat = 8
        let width = min(110, (available - spacing * CGFloat(actions.count - 1)) / CGFloat(actions.count))
        let total = width * CGFloat(actions.count) + spacing * CGFloat(actions.count - 1)
        return actions.enumerated().map { index, action in
            OverlaySelectionAIResultActionSlot(
                action: action,
                frame: CGRect(
                    x: panel.maxX - padding - total + CGFloat(index) * (width + spacing),
                    y: panel.minY + padding,
                    width: width,
                    height: actionHeight
                )
            )
        }
    }

    private static func title(for kind: SelectionAITaskKind) -> String {
        switch kind {
        case .explain: "AI 解释"
        case .translate: "翻译结果"
        case .formulaToLaTeX: "LaTeX 公式"
        case .extractTable: "表格提取"
        }
    }

    private static func copyLabel(for format: SelectionAIExportFormat) -> String {
        switch format {
        case .markdown: "复制 Markdown"
        case .plainText: "复制文本"
        case .latex: "复制 LaTeX"
        case .csv: "复制 CSV"
        }
    }
}
