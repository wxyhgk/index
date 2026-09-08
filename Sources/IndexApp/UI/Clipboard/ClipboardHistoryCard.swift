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
    var isHovering = false
    var store: ClipboardHistoryStore = .shared
    var isRenaming = false
    var renameText = ""
    var onRenameTextChange: ((String) -> Void)?
    var onBeginRename: (() -> Void)?
    var onCommitRename: ((String) -> Void)?
    var onCancelRename: (() -> Void)?

    static func == (lhs: ClipboardHistoryCard, rhs: ClipboardHistoryCard) -> Bool {
        lhs.item == rhs.item
            && lhs.isSelected == rhs.isSelected
            && lhs.selectionOrdinal == rhs.selectionOrdinal
            && lhs.isHovering == rhs.isHovering
            && lhs.store === rhs.store
            && lhs.isRenaming == rhs.isRenaming
            && lhs.renameText == rhs.renameText
    }

    var body: some View {
        ClipboardCardBody(
            item: item,
            textLineLimit: 6,
            store: store,
            showsRenameAction: isHovering,
            isRenaming: isRenaming,
            renameText: renameText,
            onRenameTextChange: onRenameTextChange,
            onBeginRename: onBeginRename,
            onCommitRename: onCommitRename,
            onCancelRename: onCancelRename
        )
        .equatable()
        .frame(
            width: ClipboardCardMetrics.popupWidth,
            height: ClipboardCardMetrics.popupHeight
        )
        .modifier(ClipboardCardChrome(
            isSelected: isSelected,
            isHovering: isHovering,
            selectionOrdinal: selectionOrdinal
        ))
    }
}
