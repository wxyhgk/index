import AppKit

struct OverlaySelectionAITaskSlot: Equatable {
    let kind: SelectionAITaskKind
    let frame: CGRect
    let showsTitle: Bool
}

/// 框选完成后贴在局部选区附近的四任务条。布局、绘制与命中共用同一份 slots。
enum OverlaySelectionAITaskPalette {
    private static let height: CGFloat = 34
    private static let gap: CGFloat = 7
    private static let horizontalPadding: CGFloat = 4

    static func task(for kind: SelectionAITaskKind) -> SelectionAITask {
        switch kind {
        case .explain: .explain
        case .translate: .translate(targetLanguage: "zh-Hans")
        case .formulaToLaTeX: .formulaToLaTeX
        case .extractTable: .extractTable
        }
    }

    static func title(for kind: SelectionAITaskKind) -> String {
        switch kind {
        case .explain: "解释"
        case .translate: "翻译"
        case .formulaToLaTeX: "公式"
        case .extractTable: "表格"
        }
    }

    static func slots(near selection: CGRect, in bounds: CGRect) -> [OverlaySelectionAITaskSlot] {
        guard bounds.width >= 40, bounds.height >= height else { return [] }
        let kinds = SelectionAITaskKind.allCases
        let usableWidth = max(0, bounds.width - 8 - horizontalPadding * 2)
        let naturalButtonWidth: CGFloat = 62
        let buttonWidth = min(naturalButtonWidth, floor(usableWidth / CGFloat(kinds.count)))
        guard buttonWidth >= 24 else { return [] }
        let panelWidth = buttonWidth * CGFloat(kinds.count) + horizontalPadding * 2

        var panel = CGRect(
            x: selection.midX - panelWidth / 2,
            y: selection.minY - height - gap,
            width: panelWidth,
            height: height
        )
        if panel.minY < bounds.minY + 4 {
            panel.origin.y = selection.maxY + gap
        }
        panel.origin.y = min(max(bounds.minY + 4, panel.minY), bounds.maxY - height - 4)
        panel.origin.x = min(max(bounds.minX + 4, panel.minX), bounds.maxX - panelWidth - 4)

        return kinds.enumerated().map { index, kind in
            OverlaySelectionAITaskSlot(
                kind: kind,
                frame: CGRect(
                    x: panel.minX + horizontalPadding + CGFloat(index) * buttonWidth,
                    y: panel.minY,
                    width: buttonWidth,
                    height: height
                ),
                showsTitle: buttonWidth >= 50
            )
        }
    }

    static func draw(
        slots: [OverlaySelectionAITaskSlot],
        hovered: SelectionAITaskKind?,
        pressed: SelectionAITaskKind?,
        status: OverlaySelectionAIExecutionStatus
    ) {
        guard let panel = slots.map(\.frame).reduce(nil, { partial, frame in
            partial.map { $0.union(frame) } ?? frame
        }) else { return }

        DS.toolbarBackground.setFill()
        let background = NSBezierPath(roundedRect: panel, xRadius: DS.radiusMedium, yRadius: DS.radiusMedium)
        background.fill()
        DS.toolbarStroke.setStroke()
        background.lineWidth = DS.hairline
        background.stroke()

        for slot in slots {
            let active = pressed == slot.kind || hovered == slot.kind
            if active {
                DS.toolbarHover.setFill()
                NSBezierPath(
                    roundedRect: slot.frame.insetBy(dx: 2, dy: 3),
                    xRadius: 5,
                    yRadius: 5
                ).fill()
            }
            drawContent(slot)
        }

        if let message = statusMessage(status) {
            drawStatus(message.text, isError: message.isError, below: panel)
        }
    }

    private static func drawContent(_ slot: OverlaySelectionAITaskSlot) {
        let title = title(for: slot.kind)
        if slot.showsTitle {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: DS.font11, weight: .medium),
                .foregroundColor: DS.toolbarForeground
            ]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(
                at: CGPoint(x: slot.frame.midX - size.width / 2, y: slot.frame.midY - size.height / 2),
                withAttributes: attrs
            )
        } else {
            ToolbarStyle.drawCenteredSymbol(symbol(for: slot.kind), in: slot.frame, pointSize: 13)
        }
    }

    private static func symbol(for kind: SelectionAITaskKind) -> String {
        switch kind {
        case .explain: "text.bubble"
        case .translate: "character.book.closed"
        case .formulaToLaTeX: "function"
        case .extractTable: "tablecells"
        }
    }

    private static func statusMessage(
        _ status: OverlaySelectionAIExecutionStatus
    ) -> (text: String, isError: Bool)? {
        switch status {
        case .idle: nil
        case let .running(kind): ("正在\(title(for: kind))…", false)
        case let .failed(message): (message, true)
        case .completed: nil
        }
    }

    private static func drawStatus(_ text: String, isError: Bool, below panel: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: DS.font11, weight: .medium),
            .foregroundColor: isError ? NSColor.systemRed : DS.toolbarForeground
        ]
        let maxWidth: CGFloat = 320
        let size = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: 40),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs
        ).size
        let box = CGRect(
            x: panel.midX - min(maxWidth, size.width + 14) / 2,
            y: panel.minY - size.height - 12,
            width: min(maxWidth, size.width + 14),
            height: size.height + 8
        )
        DS.toolbarBackground.setFill()
        NSBezierPath(roundedRect: box, xRadius: DS.radiusSmall, yRadius: DS.radiusSmall).fill()
        (text as NSString).draw(
            in: box.insetBy(dx: 7, dy: 4),
            withAttributes: attrs
        )
    }
}
