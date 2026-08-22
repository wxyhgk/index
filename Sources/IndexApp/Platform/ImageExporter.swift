import AppKit
import UniformTypeIdentifiers

/// 存盘面板。此前 CaptureActionPerformer / EditorView / GalleryView 各写了一遍，
/// 且行为已经不一致 —— 只有一份带默认目录和 NSApp.activate。
@MainActor
enum ImageExporter {

    enum ExportError: LocalizedError {
        case encodingFailed
        var errorDescription: String? { "无法编码为 PNG" }
    }

    /// 文件名模板提供者。装配层（AppDelegate）启动时注入，
    /// Platform 层不直接引用 AppSettings。
    static var nameTemplateProvider: () -> String = { "{dateCompact}-{timeCompact}" }

    /// 弹面板让用户选位置。用户取消不算错误，返回 false。
    ///
    /// 两种呈现，取决于**当下有没有一个能挂的窗口**（与 `AppAlert` 同一形状）：
    /// 这里是应用模态版，给图库 / 编辑器 / 详情页用 —— 那些场合窗口就在眼前、
    /// 也是 key 窗口，模态面板会正确地落在它那块屏上。
    ///
    /// 截图流程**不要**用这个，用 `exportWithPanel(_:suggestedName:over:)` ——
    /// 原因写在那个方法上。
    @discardableResult
    static func exportWithPanel(_ image: CGImage, suggestedName: String) throws -> Bool {
        let panel = makePanel(suggestedName: suggestedName)

        NSApp.activate(ignoringOtherApps: true)
        PanelPlacement.apply(to: panel, anchor: nil)
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        try write(image, to: url)
        return true
    }

    /// 截图流程专用：把面板挂成 sheet，宿主是一块铺在**截图那个屏**上的透明窗口。
    ///
    /// 为什么不能沿用上面那条同步路径 —— 一串实测串起来的结论：
    ///
    /// 1. 动作执行时选区覆盖层已经收掉，Index 一个窗口都没有。想让面板拿到键盘
    ///    焦点（不然文件名都输不进去），就得 `NSApp.activate(ignoringOtherApps:)`。
    /// 2. 而那是「顺带把 App 的所有窗口都拉到前台」的旧语义。台前调度开着时，
    ///    图库那组 stage 会被一起拽出来：用户正在用的 App 被缩进左侧窗口条，
    ///    面板还跟着图库跑到图库那块屏上去。
    /// 3. 替代写法逐个试过，只有这一条同时成立：宿主用 `.nonactivatingPanel`
    ///    再挂 sheet —— 面板照样是 key 窗口，而**不需要**那句 activate。
    ///
    /// 落点也顺带解决了：sheet 天然跟着宿主走，宿主铺在哪块屏上，面板就在哪块屏上，
    /// 不再需要「等上屏之后再 setFrameOrigin」那套补救。
    ///
    /// - Parameter region: 截图选区（AppKit 全局坐标）。nil 时退回 key 窗口 / 指针那块屏。
    @discardableResult
    static func exportWithPanel(
        _ image: CGImage,
        suggestedName: String,
        over region: CGRect?
    ) async throws -> Bool {
        let panel = makePanel(suggestedName: suggestedName)
        let host = PanelPlacement.makeSheetHost(anchor: region)
        defer { host.orderOut(nil) }

        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: host) { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return false }

        try write(image, to: url)
        return true
    }

    /// 两条路径共用同一份面板配置 —— 「三份存盘面板行为不一致」是这个文件存在的原因。
    private static func makePanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
        return panel
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let data = ImageCodec.pngData(from: image) else {
            throw ExportError.encodingFailed
        }
        try data.write(to: url)
    }

    /// 按用户模板渲染的建议文件名（含 .png 后缀）。
    /// 存盘面板、图库导出、自动副本全走这一个入口 —— 改模板处处生效。
    static func suggestedName(for shot: Shot?) -> String {
        suggestedName(for: shot, template: nameTemplateProvider())
    }

    /// 可注入版本：便于单测与预览无需触碰 UserDefaults。
    static func suggestedName(for shot: Shot?, template: String) -> String {
        renderName(
            template: template,
            date: shot?.capturedAt ?? Date(),
            appName: shot?.appName,
            windowTitle: shot?.windowTitle,
            customName: shot?.customTitle
        ) + ".png"
    }

    /// 模板渲染（不含扩展名）。变量：
    ///   {dateCompact}  yyyyMMdd
    ///   {timeCompact}  HHmmss
    ///   {date}         yyyy-MM-dd
    ///   {time}         HH.mm.ss
    ///   {app}          带前导连字符的来源 App 名，没有则为空
    ///   {title}        窗口标题，截到 40 字符
    ///   {name}         用户设置的图库显示名称
    /// 替换完成后整体清洗一遍文件名非法字符 —— App 名和标题都可能带 `/`。
    /// 设置页的实时预览也调这里，渲染规则只有一份。
    nonisolated static func renderName(
        template: String,
        date: Date,
        appName: String?,
        windowTitle: String?,
        customName: String? = nil
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.calendar = Calendar(identifier: .gregorian)
        timeFormatter.dateFormat = "HH.mm.ss"
        let compactDateFormatter = DateFormatter()
        compactDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        compactDateFormatter.calendar = Calendar(identifier: .gregorian)
        compactDateFormatter.dateFormat = "yyyyMMdd"
        let compactTimeFormatter = DateFormatter()
        compactTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
        compactTimeFormatter.calendar = Calendar(identifier: .gregorian)
        compactTimeFormatter.dateFormat = "HHmmss"

        let title = String((windowTitle ?? "").prefix(40))
        let rendered = template
            .replacingOccurrences(
                of: "{dateCompact}",
                with: compactDateFormatter.string(from: date)
            )
            .replacingOccurrences(
                of: "{timeCompact}",
                with: compactTimeFormatter.string(from: date)
            )
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))
            .replacingOccurrences(of: "{app}", with: appName.map { "-\($0)" } ?? "")
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{name}", with: customName ?? "")

        let cleaned = sanitizedFileName(rendered)
        // 模板被清成空串（比如只写了个 "/"）也得有名字可用。
        return cleaned.isEmpty ? "截图" : cleaned
    }

    /// 去掉文件名非法字符：`/` 是路径分隔符、`:` 在访达里显示为 `/`，都换成连字符；
    /// 控制字符直接丢弃；开头的 `.` 会变成隐藏文件，一并去掉。
    nonisolated private static func sanitizedFileName(_ raw: String) -> String {
        var cleaned = ""
        cleaned.unicodeScalars.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                cleaned.unicodeScalars.append("-")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned
    }

    /// 无人值守地把已编码的 PNG 写进目录，重名自动加 -2 / -3 … 后缀。
    /// 「自动保存副本」在后台线程用，所以是 nonisolated。返回实际写入的位置。
    @discardableResult
    nonisolated static func writePNG(
        _ data: Data,
        into directory: URL,
        preferredName: String
    ) throws -> URL {
        let base = (preferredName as NSString).deletingPathExtension
        var ext = (preferredName as NSString).pathExtension
        if ext.isEmpty { ext = "png" }

        var candidate = directory.appendingPathComponent(preferredName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        // withoutOverwriting：探测和写入之间若有并发写入者抢先，报错而不是覆盖。
        try data.write(to: candidate, options: .withoutOverwriting)
        return candidate
    }
}
