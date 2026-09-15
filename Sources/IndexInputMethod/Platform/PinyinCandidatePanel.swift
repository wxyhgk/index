import AppKit
import IndexSearchCore

// MARK: - 拼音候选条
//
// 自绘 NSView 一次画完（参考 qingjian CandidateView），不再用 9 个 NSTextField 子视图。
// 顶部拼音行（音节分段着色 + 自绘光标）+ 横排候选 + 高亮 + 页码。

final class PinyinCandidatePanelController: NSWindowController {
    private static let initialWidth: CGFloat = 680
    private static let maximumWidth: CGFloat = 1_180
    private static let minimumWidth: CGFloat = 360

    private let candidateView = QingjianCandidateView()
    private var panel: NSPanel!
    var onSelect: ((Int) -> Void)?
    var onPreviousPage: (() -> Void)?
    var onNextPage: (() -> Void)?

    private let theme = QingjianTheme.systemDefault

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.initialWidth, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        self.panel = panel

        panel.contentView = candidateView
        super.init(window: panel)
        candidateView.theme = theme
        candidateView.onSelect = { [weak self] index in
            self?.onSelect?(index)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 显示

    func show(
        candidates: [String],
        pagination: CandidatePagination,
        caretFrame: NSRect,
        preedit: [(text: String, style: QingjianPreeditStyle)] = [],
        preeditCursor: Int = 0
    ) {
        guard !candidates.isEmpty else {
            hide()
            return
        }
        let visibleIndices = Array(pagination.visibleRange).filter { $0 < candidates.count }
        let rows: [QingjianCandidateRow] = visibleIndices.enumerated().map { localIndex, candidateIndex in
            QingjianCandidateRow(
                index: "\(localIndex + 1)",
                text: candidates[candidateIndex]
            )
        }
        let showsPaging = pagination.pageCount > 1
        let footer: String? = showsPaging ? "\(pagination.pageIndex + 1)/\(pagination.pageCount)" : nil

        let size = candidateView.setContent(
            rows: rows,
            highlighted: pagination.selectedIndex - pagination.visibleRange.lowerBound,
            footer: footer,
            preedit: preedit,
            preeditCursor: preeditCursor
        )

        // 宽度约束
        let visibleFrame = screenFrame(containing: caretFrame)
        let maxWidth = min(Self.maximumWidth, max(Self.minimumWidth, visibleFrame.width - 16))
        let panelWidth = min(maxWidth, max(Self.minimumWidth, size.width))
        let panelHeight = max(52, size.height)
        panel.setContentSize(NSSize(width: panelWidth, height: panelHeight))

        // 翻页按钮区域（如果有多页）
        // 自绘视图不画翻页按钮，翻页通过键盘操作
        position(near: caretFrame)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    /// 检索面板锚定在候选条下方。
    func searchAnchorFrame(fallback caret: NSRect) -> NSRect {
        guard panel.isVisible, panel.frame.maxY <= caret.minY + 1 else {
            return caret
        }
        return NSRect(x: caret.minX, y: panel.frame.minY, width: 1, height: 1)
    }

    // MARK: 定位

    private func position(near caret: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin = NSPoint(x: caret.minX, y: caret.minY - panel.frame.height - 6)
        if origin.y < visible.minY { origin.y = caret.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - panel.frame.width - 6)
        origin.y = min(max(origin.y, visible.minY + 6), visible.maxY - panel.frame.height - 6)
        panel.setFrameOrigin(origin)
    }

    private func screenFrame(containing caret: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: Self.initialWidth, height: 800)
    }
}
