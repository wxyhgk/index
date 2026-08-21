import SwiftUI
import AppKit

// MARK: - 详情面板的公用件
//
// 设计稿 §6 那块浮动卡片里出现的所有「零件」都收在这里：尺寸表、动作行的
// 主按钮 / 圆形图标位 / 圆形菜单位、元信息行、底部下钻行，以及真实 App 图标。
//
// 与 GalleryShell 的分工：那边是**窗口外壳**（面板容器、顶栏图标按钮、关闭按钮），
// 这边是**详情面板内部**的控件。两边共用 DS 的填充 / 动效 / 圆角 token。
//
// 为什么不复用 `ShellIconButtonStyle`：顶栏那一档是「圆角方 + 常态透明、
// 只在悬停时浮出底色」，而设计稿 §6.3 的动作位是「圆形 + 常态就有一层浅色圆底」。
// 两者不是同一个控件，硬套会让详情面板的动作行在静止时读不出「这里有按钮」。
//
// 材质纪律：这些件全部只用**纯色 / 半透明填充**，不上 Material ——
// 外层 `floatingPanel` 已经是不透明的面板底色（理由见 GalleryShell 文件注释），
// 面板内再叠玻璃只会互相采样出浑浊，且 `.quaternary` 落在 `.thin` 材质上
// 对比度不达标（规格 §7.2）。

// ============================================================
// MARK: - 尺寸
// ============================================================

/// 详情面板的尺寸表。数值来自设计稿 §6（370 宽的面板上量出来的）。
enum InspectorMetrics {

    /// 预览区高度（紧凑化：150，原 190）。
    static let previewHeight: CGFloat = 150

    /// 预览区圆角（设计稿：12）。
    ///
    /// DS 的圆角阶梯里没有这一档（10 / 14 之间），而这里**不能**按同心公式
    /// 从面板的 18 推：预览的上方是关闭按钮那条空巷，它并没有塞进面板的圆角里，
    /// 同心约束在这个方向上不成立。所以按设计稿取 12，并且只在详情面板内用。
    static let previewRadius: CGFloat = 12

    /// 动作行控件的边长 / 高度（设计稿：圆形图标 34、主按钮高 34）。
    static let actionSide: CGFloat = 34

    /// 主按钮的最小宽度（设计稿：约 100）。
    static let primaryWidth: CGFloat = 100

    /// 元信息行行高（紧凑化：28，原 38）。
    static let rowHeight: CGFloat = 28

    /// 元信息行图标位（压缩后 14pt，原 18pt）。
    static let rowIcon: CGFloat = 14

    /// 元信息 / 下钻行的文字字号（压缩后 12pt，原 13pt）。
    static let rowFontSize: CGFloat = 12

    /// 关闭按钮占住的那条巷子：`GalleryInspectorPanel` 在面板右上角画一个
    /// 直径 28 的 ✕、内缩 `DS.s2`(8)，所以它的下沿在 36。面板内容从 40 开始，
    /// 首屏就不会有任何东西被它盖住（滚上去之后压在它下面是可以接受的）。
    static let closeButtonLane: CGFloat = 40

    /// 浅色圆底 / 软按钮的填充。深色加白、浅色加黑，都是几个点的量 ——
    /// 和 `ShellIconButtonStyle` 同一套「亮度阶梯」，只是这里常态就有底。
    static func softFill(_ scheme: ColorScheme, hovering: Bool) -> Color {
        DS.softFill(scheme, hovering: hovering)
    }

    /// 整行可点控件（元信息行 / 下钻行）的悬停底。比上面那档更轻 ——
    /// 它是一整行的面积，同样的不透明度铺开会比小圆底重得多。
    static func rowHoverFill(_ scheme: ColorScheme) -> Color {
        DS.rowHoverFill(scheme)
    }
}

// ============================================================
// MARK: - 动作行：主按钮
// ============================================================

/// 动作行主按钮（设计稿 §6.3：强调蓝实心胶囊，约 100×34）。
///
/// accent 实心在这套设计里是「唯一的主动作」的记号（规格 §7.1：强调色只归
/// 选中 / 焦点 / 主动作），所以同屏只允许出现一个 —— 详情面板里就是「编辑」。
struct InspectorPillButtonStyle: ButtonStyle {

    /// 最小宽度。给多选面板的整行按钮用 0（由外部 `frame(maxWidth:)` 撑开）。
    var minWidth: CGFloat = InspectorMetrics.primaryWidth

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, minWidth: minWidth)
    }

    /// `@State` 不能写在 ButtonStyle 上（它不是 View，没有视图身份，悬停会串），
    /// 所以真正的实现是这个嵌套视图 —— 和 `ShellIconButtonStyle` 同一套写法。
    private struct Surface: View {

        let configuration: ButtonStyleConfiguration
        let minWidth: CGFloat

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: InspectorMetrics.rowFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, DS.s3)
                .frame(minWidth: minWidth)
                .frame(height: InspectorMetrics.actionSide)
                // 悬停用 brightness 而不是降不透明度：accent 掉透明度会去和面板底色
                // 混色，深色下读起来是「变脏」而不是「变亮」。
                .background {
                    Capsule().fill(DS.accent).brightness(hovering ? 0.06 : 0)
                }
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? DS.Lift.pressScale : 1)
                .onHover { hovering = $0 }
                .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
                .animation(DS.Motion.micro(reduced: reduceMotion), value: configuration.isPressed)
        }
    }
}

/// 次级胶囊按钮：浅色底、跟随语义色的字（多选面板的「导出 / 删除」）。
/// 和主按钮同高同形，只差填充 —— 一眼能读出「同一行里谁是主角」。
struct InspectorSoftButtonStyle: ButtonStyle {

    /// 文字与图标的颜色。破坏性动作传 `.red`，其余用默认。
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, tint: tint)
    }

    private struct Surface: View {

        let configuration: ButtonStyleConfiguration
        let tint: Color?

        @Environment(\.colorScheme) private var scheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: InspectorMetrics.rowFontSize, weight: .medium))
                .foregroundStyle(tint ?? Color.primary)
                .padding(.horizontal, DS.s3)
                .frame(height: InspectorMetrics.actionSide)
                .background(InspectorMetrics.softFill(scheme, hovering: hovering), in: Capsule())
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? DS.Lift.pressScale : 1)
                .onHover { hovering = $0 }
                .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
                .animation(DS.Motion.micro(reduced: reduceMotion), value: configuration.isPressed)
        }
    }
}

// ============================================================
// MARK: - 动作行：圆形图标位
// ============================================================

/// 动作行里的圆形图标位（设计稿 §6.3：约 34、浅色圆底）。
///
/// `tint` 非空时圆底转成该色的淡底、图标转该色 —— 收藏已开就是这么表达的
///（黄星 + 淡黄底），而不是去抢 accent：同屏只有主按钮配 accent。
struct InspectorCircleButtonStyle: ButtonStyle {

    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, tint: tint)
    }

    private struct Surface: View {

        let configuration: ButtonStyleConfiguration
        let tint: Color?

        @Environment(\.colorScheme) private var scheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var fill: Color {
            if let tint { return DS.tintFill(tint, hovering: hovering) }
            return InspectorMetrics.softFill(scheme, hovering: hovering)
        }

        var body: some View {
            configuration.label
                .font(.system(size: DS.font13, weight: .medium))
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: InspectorMetrics.actionSide, height: InspectorMetrics.actionSide)
                .background(fill, in: Circle())
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? DS.Lift.pressScale : 1)
                .onHover { hovering = $0 }
                .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
                .animation(DS.Motion.micro(reduced: reduceMotion), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == InspectorPillButtonStyle {
    /// 详情面板的主动作（accent 实心胶囊）。
    static var inspectorPill: InspectorPillButtonStyle { InspectorPillButtonStyle() }
    /// 整行铺开的主动作（多选面板）。
    static var inspectorPillWide: InspectorPillButtonStyle {
        InspectorPillButtonStyle(minWidth: 0)
    }
}

extension ButtonStyle where Self == InspectorSoftButtonStyle {
    static var inspectorSoft: InspectorSoftButtonStyle { InspectorSoftButtonStyle() }
    static func inspectorSoft(tint: Color?) -> InspectorSoftButtonStyle {
        InspectorSoftButtonStyle(tint: tint)
    }
}

extension ButtonStyle where Self == InspectorCircleButtonStyle {
    static var inspectorCircle: InspectorCircleButtonStyle { InspectorCircleButtonStyle() }
    static func inspectorCircle(tint: Color?) -> InspectorCircleButtonStyle {
        InspectorCircleButtonStyle(tint: tint)
    }
}

// ============================================================
// MARK: - 动作行：圆形菜单位
// ============================================================

/// 动作行里长得和圆形按钮一样、但点开是菜单的那两位（分享 / 更多）。
///
/// 为什么不是 `Menu` + `.buttonStyle(...)`：macOS 上 `MenuStyle` 会接管外观，
/// 自定义 `ButtonStyle` 不保证生效。所以这里反过来 —— 外观自己画，
/// `Menu` 退成 `borderlessButton` + 隐藏指示器，只负责弹出。
/// 标签视图撑满整个 34×34 并接 `contentShape(Circle())`，
/// 保证**整个圆**都是命中区（`fixedSize` 之后菜单的点击区域 = 标签的尺寸）。
struct InspectorCircleMenu<Content: View>: View {

    let systemImage: String
    /// 无障碍标签与 tooltip。菜单位没有可见文字，这一项必须给。
    let label: String
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: DS.font13, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: InspectorMetrics.actionSide, height: InspectorMetrics.actionSide)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // fixedSize 让菜单退到标签的理想尺寸（否则它会像文本菜单一样铺开），
        // 外面再钉一次 34×34：动作行的几何因此是确定的，
        // 不受 borderlessButton 自带内衬的影响 —— 四个圆位必须等大。
        .fixedSize()
        .frame(width: InspectorMetrics.actionSide, height: InspectorMetrics.actionSide)
        .background(InspectorMetrics.softFill(scheme, hovering: hovering), in: Circle())
        .onHover { hovering = $0 }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
        .accessibilityLabel(label)
        .help(label)
    }
}

// ============================================================
// MARK: - 元信息行
// ============================================================

/// 元信息行的图标位。第一行要放**真实 App 图标**（NSImage），其余行是 SF Symbol，
/// 两者尺寸一致。做成枚举而不是泛型参数：调用处只写一个 `.symbol("calendar")`，
/// 不必在每个调用点重复一遍字号 / 颜色 / 尺寸的修饰链。
enum InspectorRowIcon {
    case symbol(String)
    case appIcon(bundleID: String?)
}

/// 元信息一行（设计稿 §6.4：18pt 图标 + 13pt 文字，行高 38）。
///
/// `action` 非空时整行可点（悬停出底 + 右端一个小箭头）。
/// **没有值的行不要构造它** —— 空行会在列表里留一道读不出含义的缝，
/// 判空由调用处做（那里才知道「什么算没有值」）。
struct InspectorMetaRow: View {

    let icon: InspectorRowIcon
    let text: String
    /// tooltip：行内文字是单行截断的，完整值（长网址 / bundleID）挂在这里。
    var help: String?
    var action: (() -> Void)?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .help(help ?? text)
        } else {
            row.help(help ?? text)
        }
    }

    private var row: some View {
        HStack(spacing: DS.s2) {
            iconView
                .frame(width: InspectorMetrics.rowIcon, height: InspectorMetrics.rowIcon)
            Text(text)
                .font(.system(size: InspectorMetrics.rowFontSize))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 右侧：action 箭头 + 复制按钮，hover 时显形。
            HStack(spacing: DS.s1) {
                if action != nil {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: DS.font10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Button {
                    Clipboard.copy(text: text)
                    copied = true
                    Task {
                        try? await Task.sleep(for: DS.copyFeedbackDelay)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: DS.font10, weight: .medium))
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(copied ? "已复制" : "复制")
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, DS.s2)
        .frame(height: InspectorMetrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                .fill(hovering ? InspectorMetrics.rowHoverFill(scheme) : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
        .animation(DS.Motion.micro(reduced: reduceMotion), value: copied)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: DS.font14))
                .foregroundStyle(.secondary)
        case .appIcon(let bundleID):
            InspectorAppIcon(bundleID: bundleID, side: InspectorMetrics.rowIcon)
        }
    }
}

// ============================================================
// MARK: - 长值复制行
// ============================================================

/// 长值行：label + 截断摘要 + 复制按钮。
///
/// 用于路径 / sha256 / URL 等「完整值太长、不需要常看、但排查时必须能拿到」的字段。
/// 旧实现是 `textSelection(.enabled)` + `lineLimit(3)` —— 用户得手动拖选才能复制，
/// 而且长路径把卡片撑高。现在改成单行截断 + 一键复制，复制后图标变 checkmark 1.5s。
struct CopyValueRow: View {

    let label: String
    let value: String
    /// 摘要显示用的截断文本。默认取 value 本身（middle 截断）。
    var summary: String?

    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(summary ?? value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Clipboard.copy(text: value)
                copied = true
                Task {
                    try? await Task.sleep(for: DS.copyFeedbackDelay)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: DS.font11, weight: .medium))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(copied ? "已复制" : "复制\(label)")
            .accessibilityLabel(copied ? "已复制" : "复制\(label)")
        }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: copied)
    }
}

// ============================================================
// MARK: - 底部下钻行
// ============================================================

/// 面板底部的下钻行（设计稿 §6.6：分隔后一行「查看全部信息 ›」，整行可点）。
struct InspectorDrillRow: View {

    let title: String
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.s2) {
                Text(title)
                    .font(.system(size: InspectorMetrics.rowFontSize, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.font11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.s2)
            .frame(height: InspectorMetrics.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                    .fill(hovering ? InspectorMetrics.rowHoverFill(scheme) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
    }
}

// ============================================================
// MARK: - 真实 App 图标
// ============================================================

/// 真实 App 图标。按 bundleID 解析一次后缓存；解析不到（App 已卸载 / 没记录
/// bundleID）时退到一个虚线占位符，**不留空**。
///
/// 侧边栏里有一份同样的实现（`GallerySidebar` 里私有的 `AppIconCache`）。
/// 那个文件这一轮不许改，所以这里先自带一份；两份应当合并成这一份，
/// 见交付报告里的「需要外壳提供的 API」。
struct InspectorAppIcon: View {

    let bundleID: String?
    var side: CGFloat = InspectorMetrics.rowIcon

    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: side, height: side)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: side * 0.78))
                    .foregroundStyle(.secondary)
                    .frame(width: side, height: side)
            }
        }
        .task(id: bundleID) {
            // 命中缓存这条路径**没有 await**：同一次 runloop 里就赋上值，
            // 切换选中时已解析过的图标不会先闪一下占位符再变出来。
            if let hit = AppIconProvider.shared.cached(bundleID) {
                icon = hit
                return
            }
            icon = await AppIconProvider.shared.icon(for: bundleID)
        }
    }
}

/// NSImage 不是 Sendable。这里的实例是 detached task 里现造的，造完就交出去、
/// 自己不再持有也不再改 —— 是一次所有权转移而不是共享。用盒子把这件事讲明白，
/// 而不是在调用处埋一个静默的 @unchecked。
private struct AppIconTransfer: @unchecked Sendable {
    let image: NSImage?
}

/// bundleID → App 图标。
///
/// `NSWorkspace.icon(forFile:)` 要去 App bundle 里读 .icns，是一次同步磁盘 IO，
/// **绝不能在主线程上按行串行跑**（装的应用一多首屏就顿一下）。所以解析在
/// detached task 里做，主线程只剩一次赋值。缓存用 `NSCache`：它有条数上限，
/// 系统内存吃紧时会自己放手，不像字典那样只涨不落。
@MainActor
final class AppIconProvider {

    static let shared = AppIconProvider()

    private let cache = NSCache<NSString, NSImage>()
    /// 同一个 bundleID 的并发解析只跑一次 —— 列表刷新时几十行会同时发起。
    private var inflight: [String: Task<AppIconTransfer, Never>] = [:]

    private init() {
        cache.countLimit = 128
    }

    /// 同步取缓存。只命中，不解析 —— 给视图做「无闪烁」快路径用。
    func cached(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        return cache.object(forKey: bundleID as NSString)
    }

    /// 解析并缓存。
    ///
    /// 取舍：`NSWorkspace` 的这两个查询走 LaunchServices，实践上可以离开主线程；
    /// Apple 没有白纸黑字的保证，但代价（首屏卡顿）是确定的。
    /// 另外**不改 `icon.size`** —— 显示尺寸由 `.resizable().frame()` 决定，
    /// 而 `icon(forFile:)` 返回的实例有可能是 AppKit 内部共享的，
    /// 在后台线程上改它的属性是没必要冒的险。
    func icon(for bundleID: String?) async -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = cache.object(forKey: bundleID as NSString) { return hit }

        let task: Task<AppIconTransfer, Never>
        if let running = inflight[bundleID] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) {
                guard let url = NSWorkspace.shared
                    .urlForApplication(withBundleIdentifier: bundleID) else {
                    return AppIconTransfer(image: nil)
                }
                return AppIconTransfer(image: NSWorkspace.shared.icon(forFile: url.path))
            }
            inflight[bundleID] = task
        }

        let image = await task.value.image
        inflight[bundleID] = nil
        if let image {
            cache.setObject(image, forKey: bundleID as NSString)
        }
        return image
    }

    /// 按 App **名称**解析图标（剪贴板条目只存了 localizedName，没有 bundleID）。
    /// 动态查找：正在运行的进程 → 常见安装目录 → 回退。结果进同一个 NSCache。
    func icon(forName name: String?) async -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        let key = "name:\(name)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let task: Task<AppIconTransfer, Never>
        if let running = inflight[key as String] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) {
                let path = Self.appPath(forName: name)
                return AppIconTransfer(image: NSWorkspace.shared.icon(forFile: path))
            }
            inflight[key as String] = task
        }

        let image = await task.value.image
        inflight[key as String] = nil
        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    /// 名称 → App 路径。运行中进程最可靠（bundleURL 是真实路径），
    /// 其次按名称扫常见安装目录，最后回退成 `.app` 让 icon(forFile:) 给通用图标。
    nonisolated private static func appPath(forName name: String) -> String {
        let workspace = NSWorkspace.shared
        if let running = workspace.runningApplications.first(where: { $0.localizedName == name }),
           let url = running.bundleURL {
            return url.path
        }
        let fm = FileManager.default
        let dirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        for dir in dirs {
            let candidate = "\(dir)/\(name).app"
            if fm.fileExists(atPath: candidate) { return candidate }
        }
        return "\(name).app"
    }
}
