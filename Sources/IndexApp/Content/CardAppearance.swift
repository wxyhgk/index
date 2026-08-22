import SwiftUI
import AppKit

// MARK: - 卡片外观描述
//
// 每种内容类型（截图/录屏/便签/代码/表格...）提供自己的 header + caption 样式。
// ShotCard 只消费 CardAppearance，不判断类型。
// 新增类型 = 加一个 static func，不改 ShotCard。

struct CardAppearance: Equatable {

    // 顶部 bar
    var headerLabel: String
    var barColor: Color
    var headerIcon: NSImage?

    // 底部 caption
    var captionTitle: String
    var captionSubtitle: String

    // 特殊角标
    var showsRecordingBadge: Bool

    // MARK: - 录屏（正交维度，不属于任何 ContentMode）

    static func recording(shot: Shot, appIcon: NSImage?) -> CardAppearance {
        CardAppearance(
            headerLabel: "录屏",
            barColor: DS.clipboardFileBar,
            headerIcon: appIcon,
            captionTitle: shot.customTitle ?? (shot.windowTitle ?? "录屏"),
            captionSubtitle: shot.capturedAt.formatted(.dateTime.month().day().hour().minute()),
            showsRecordingBadge: true
        )
    }

    // MARK: - 分发

    /// 根据 shot 的实际类型返回对应外观。
    /// 录屏是正交维度（任何 contentKind 都可能是录屏），优先判断。
    /// 其余类型从 PluginRegistry 的 ContentMode 取（= Emacs major mode）。
    @MainActor
    static func forShot(_ shot: Shot, isRecording: Bool, appIcon: NSImage?) -> CardAppearance {
        if isRecording { return recording(shot: shot, appIcon: appIcon) }
        let mode = PluginRegistry.shared.mode(for: ContentKind(rawValue: shot.contentKind) ?? .image)
        let caption = mode.caption(shot)
        return CardAppearance(
            headerLabel: mode.label,
            barColor: mode.barColor,
            headerIcon: mode.icon ?? appIcon,
            captionTitle: caption.title,
            captionSubtitle: caption.subtitle,
            showsRecordingBadge: false
        )
    }

    // MARK: - 图标

    static let markdownIcon: NSImage = {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: "M", attributes: attrs)
        let textSize = text.size()
        text.draw(at: NSPoint(x: (14 - textSize.width) / 2, y: (14 - textSize.height) / 2))
        image.unlockFocus()
        return image
    }()
}
