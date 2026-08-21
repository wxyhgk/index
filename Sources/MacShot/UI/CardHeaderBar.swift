import SwiftUI
import AppKit

// ============================================================
// MARK: - 卡片彩色标题栏（图库 / 剪贴板共用）
//
// 类型标签 + 相对时间 + 来源 App logo。
// 图库：截图=蓝 / 录屏=橙；剪贴板：文本=深灰 / 图片=蓝 / 文件=橙。
// ============================================================

struct CardHeaderBar: View {

    let label: String
    let time: Date
    let appIcon: NSImage?
    let barColor: Color
    var pinned: Bool = false

    var body: some View {
        HStack(spacing: DS.s1) {
            Text(label)
                .font(.system(size: DS.font10, weight: .semibold))
                .foregroundStyle(.white)
            Text(timeString)
                .font(.system(size: DS.font9))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: DS.font9))
                    .foregroundStyle(.white)
            }
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, DS.s2)
        .padding(.vertical, DS.s1)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(barColor)
    }

    private var timeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: time, relativeTo: Date())
    }
}

