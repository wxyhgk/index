import SwiftUI

// ============================================================
// MARK: - 剪贴板历史卡片（浮动面板）
//
// 尺寸 200×220，适配横向滚动面板。
// 视觉部分全部走 ClipboardCardBody + ClipboardCardChrome。
// ============================================================

struct ClipboardHistoryCard: View {

    let item: ClipboardHistoryItem
    let thumbnail: NSImage?
    let appIcon: NSImage?
    let isSelected: Bool

    private let cardWidth: CGFloat = 200
    private let cardHeight: CGFloat = 220

    @State private var isHovering = false

    var body: some View {
        ClipboardCardBody(
            item: item,
            thumbnail: thumbnail,
            appIcon: appIcon,
            textLineLimit: 6
        )
        .frame(width: cardWidth, height: cardHeight)
        .modifier(ClipboardCardChrome(isSelected: isSelected, isHovering: isHovering))
        .onHover { isHovering = $0 }
    }
}
