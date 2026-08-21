import SwiftUI

// ============================================================
// MARK: - 剪贴板历史卡片
//
// Paste 式卡片：彩色标题栏（类型+时间+来源 App 图标）、
// 内容区（文本/图片/文件）、底部信息栏。
// ============================================================

struct ClipboardHistoryCard: View {

    let item: ClipboardHistoryItem
    let thumbnail: NSImage?
    let appIcon: NSImage?
    let isSelected: Bool

    private let cardWidth: CGFloat = 200
    private let cardHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            contentArea
            footer
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard)
                .stroke(isSelected ? DS.clipboardSelectedRing : DS.borderDefault, lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(isSelected ? 0.15 : 0.08), radius: isSelected ? 12 : 6, y: isSelected ? 4 : 2)
    }

    // 彩色标题栏：类型标签 + 时间 + 来源 App 图标
    private var headerBar: some View {
        HStack(spacing: DS.s1) {
            Text(typeLabel)
                .font(.system(size: DS.font11, weight: .semibold))
                .foregroundStyle(.white)
            Text(timeString)
                .font(.system(size: DS.font9))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: DS.font9))
                    .foregroundStyle(.white)
            }
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, DS.s2)
        .padding(.vertical, DS.s1)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(barColor)
    }

    // 内容区
    @ViewBuilder
    private var contentArea: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? item.summary ?? "")
                .font(.system(size: DS.font12))
                .lineLimit(6)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(DS.s2)
        case .image:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                placeholderIcon("photo")
            }
        case .file:
            placeholderIcon("doc")
        }
    }

    // 底部：字符数 / 文件名
    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.system(size: DS.font9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, DS.s2)
        .padding(.vertical, DS.s1)
    }

    private func placeholderIcon(_ name: String) -> some View {
        VStack {
            Image(systemName: name)
                .font(.system(size: DS.font20))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var typeLabel: String {
        switch item.kind {
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    private var barColor: Color {
        switch item.kind {
        case .text: return DS.clipboardTextBar
        case .image: return DS.clipboardImageBar
        case .file: return DS.clipboardFileBar
        }
    }

    private var timeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: item.capturedAt, relativeTo: Date())
    }

    private var footerText: String {
        switch item.kind {
        case .text:
            let count = (item.text ?? "").count
            return "\(count) 个字符"
        case .image:
            return item.summary ?? "图片"
        case .file:
            return item.summary ?? "文件"
        }
    }
}
