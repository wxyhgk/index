import SwiftUI

// ============================================================
// MARK: - 剪贴板历史卡片（浮动面板）
//
// 纯内容方卡，适配横向滚动面板。
// 视觉部分全部走 ClipboardCardBody + ClipboardCardChrome。
// ============================================================

struct ClipboardHistoryCard: View, Equatable {

    let item: ClipboardHistoryItem
    let isSelected: Bool
    let selectionOrdinal: Int?
    var store: ClipboardHistoryStore = .shared

    private let cardSize: CGFloat = 190

    @State private var isHovering = false

    static func == (lhs: ClipboardHistoryCard, rhs: ClipboardHistoryCard) -> Bool {
        lhs.item == rhs.item
            && lhs.isSelected == rhs.isSelected
            && lhs.selectionOrdinal == rhs.selectionOrdinal
            && lhs.store === rhs.store
    }

    var body: some View {
        ClipboardCardBody(
            item: item,
            textLineLimit: 6,
            store: store
        )
        .equatable()
        .frame(width: cardSize, height: cardSize)
        .modifier(ClipboardCardChrome(
            isSelected: isSelected,
            isHovering: isHovering,
            selectionOrdinal: selectionOrdinal
        ))
        .onHover { isHovering = $0 }
    }
}
