import AppKit

/// macOS 应用身份图标的唯一入口。
///
/// Release 从完整 `.app` 的 `Index.icns` 读取；SwiftPM 裸 Debug 没有 App Bundle，
/// 因而回退到随 target 编译的同源 SVG。这样 Dock / Cmd-Tab 与发布包使用同一品牌，
/// 菜单栏则使用为模板渲染简化过的单色版本。
@MainActor
enum IndexApplicationBranding {

    private final class ResourceAnchor: NSObject {}

    static func installApplicationIcon(on application: NSApplication) {
        guard let image = applicationIcon() else {
            NSLog("[Index] 无法加载应用品牌图标")
            return
        }
        application.applicationIconImage = image
        installDockTile(image: image, on: application)
    }

    static func applicationIcon() -> NSImage? {
        if let icnsURL = Bundle.main.url(forResource: "Index", withExtension: "icns"),
           let image = NSImage(contentsOf: icnsURL) {
            return image
        }
        guard let svgURL = brandResourceURL(named: "index-app-icon") else { return nil }
        return NSImage(contentsOf: svgURL)
    }

    static func menuBarIcon() -> NSImage? {
        guard let svgURL = brandResourceURL(named: "index-menu-icon"),
              let image = NSImage(contentsOf: svgURL)
        else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    /// 裸 SwiftPM 可执行文件没有 Bundle ID，Dock 会坚持使用通用 `exec` 图标，
    /// 即使 `applicationIconImage` 已经设置。自定义 Dock Tile 才是对这种进程的
    /// 明确覆盖；完整 `.app` 也走同一路径，确保 Debug / Release 视觉一致。
    private static func installDockTile(image: NSImage, on application: NSApplication) {
        let tileView = dockTileContentView(image: image)
        application.dockTile.contentView = tileView
        application.dockTile.display()
    }

    static func dockTileContentView(image: NSImage) -> NSImageView {
        let tileView = NSImageView(
            frame: NSRect(origin: .zero, size: NSSize(width: 128, height: 128))
        )
        tileView.image = image
        tileView.imageScaling = .scaleProportionallyUpOrDown
        tileView.imageAlignment = .alignCenter
        return tileView
    }

    /// SwiftPM 裸可执行文件把资源 bundle 放在二进制旁；组装后的 `.app`
    /// 则把它放进 `Contents/Resources`。测试 bundle 又多嵌套三层，所以沿可执行
    /// 路径向上寻找有限层级，避免使用 SwiftPM 生成的开发机绝对路径回退。
    private static func brandResourceURL(named name: String) -> URL? {
        let hostBundles = [Bundle.main, Bundle(for: ResourceAnchor.self)]
        for host in hostBundles {
            if let direct = host.url(forResource: name, withExtension: "svg") {
                return direct
            }
            if let resources = host.resourceURL,
               let bundle = Bundle(url: resources.appendingPathComponent("Index_IndexApp.bundle")),
               let url = bundle.url(forResource: name, withExtension: "svg") {
                return url
            }
        }

        let roots = hostBundles.flatMap { host in
            [host.bundleURL, host.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        }
        for root in roots {
            var directory: URL? = root
            for _ in 0..<6 {
                guard let candidateDirectory = directory else { break }
                if let bundle = Bundle(url: candidateDirectory.appendingPathComponent("Index_IndexApp.bundle")),
                   let url = bundle.url(forResource: name, withExtension: "svg") {
                    return url
                }
                directory = candidateDirectory.deletingLastPathComponent()
            }
        }
        return nil
    }
}
