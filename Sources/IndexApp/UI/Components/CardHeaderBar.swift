import SwiftUI
import AppKit

// ============================================================
// MARK: - 卡片彩色标题栏（图库 / 剪贴板共用）
//
// 类型标签 + 相对时间 + 来源 App logo。
// 图库：截图=蓝 / 录屏=橙；剪贴板：文本=深灰 / 图片=蓝 / 文件=橙。
// ============================================================

struct CardHeaderBar: View {

    /// Formatter 构造会初始化 ICU 数据。卡片高速进出懒网格时每张现造一份，
    /// 会把本可复用的工作放到主线程滚动路径；所有访问都来自 SwiftUI 主线程。
    @MainActor private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

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
        Self.relativeTimeFormatter.localizedString(for: time, relativeTo: Date())
    }
}
