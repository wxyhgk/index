import AppKit

// MARK: - Bug 报告模板

/// 把一张截图的来源元数据整理成可以直接贴进 issue 的 Markdown。
///
/// 工具条的「报告」动作和图库详情栏的「复制 Bug 报告」共用这一份模板 ——
/// 字段增删只改这里。所有字段尽力而为：shot 缺失（临时预览）时能写多少写多少。
enum BugReport {

    /// 芯片架构，如 "arm64" / "x86_64"。
    static var machineArchitecture: String {
        var uts = utsname()
        uname(&uts)
        return withUnsafeBytes(of: &uts.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// 生成报告文本。图片尺寸单独传入：动作侧来自 `context.base`，
    /// 详情栏侧来自 `Shot` 记录 —— 两边都有，且 shot 为 nil 时也不缺这一项。
    static func markdown(shot: Shot?, pixelWidth: Int, pixelHeight: Int) -> String {
        var environment: [String] = []
        if let shot {
            if let appName = shot.appName {
                let version = shot.appVersion.map { v in
                    shot.appBuild.map { "\(v) (\($0))" } ?? v
                }
                environment.append("- App：" + (version.map { "\(appName) \($0)" } ?? appName))
            }
            if let bundleID = shot.appBundleID {
                environment.append("- Bundle ID：\(bundleID)")
            }
        }
        environment.append("- macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        environment.append("- 芯片：\(machineArchitecture)")

        var screenshot: [String] = []
        if let shot {
            if let title = shot.windowTitle, !title.isEmpty {
                screenshot.append("- 窗口标题：\(title)")
            }
            if let url = shot.sourceURL {
                screenshot.append("- 网址：\(url)")
            }
            screenshot.append(
                "- 截图时间：\(shot.capturedAt.formatted(date: .abbreviated, time: .standard))"
            )
        }
        screenshot.append("- 图片尺寸：\(pixelWidth) × \(pixelHeight) px")
        screenshot.append("- 截图已存于 Index 图库")

        return """
        ### 环境

        \(environment.joined(separator: "\n"))

        ### 截图信息

        \(screenshot.joined(separator: "\n"))

        ### 复现步骤

        1.
        """
    }
}

// MARK: - 工具条动作

/// 一键生成 Bug 报告：把 Markdown 模板放进剪贴板，直接贴进 issue / 群聊。
///
/// 剪贴板放不下「图片 + 文本」两样都要的场景 —— 这里明确选文本，
/// 模板里写明截图已存于图库，需要图时再从图库复制。
struct BugReportAction: CaptureAction {
    let id = ActionID.bugReport
    let title = "报告"
    let symbolName = "ladybug"
    let scopes: Set<ActionScope> = [.capture, .pinned]
    /// 用户要的是报告文本，别让全局自动复制用图片把它盖掉。
    let suppressesAutoCopy = true
    /// 低频动作，收进截图工具条的「更多」菜单（钉图不折叠）。
    let isPrimaryAction = false

    func perform(_ context: CaptureContext) async throws {
        Clipboard.copy(text: BugReport.markdown(
            shot: context.shot,
            pixelWidth: context.base.width,
            pixelHeight: context.base.height
        ))
    }
}
