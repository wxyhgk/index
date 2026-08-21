import AppKit
import ServiceManagement

/// 开机自启的薄封装：`SMAppService.mainApp` 的 register / unregister / status。
///
/// 注意：SMAppService 只对**以 .app 包形式运行**的进程有效 ——
/// `swift run` 的裸可执行文件注册会抛错，设置页把错误如实显示出来，
/// 开关随即恢复原状（见 `SettingsView` 的 LaunchAtLoginRow）。
@MainActor
enum LaunchAtLogin {

    enum Status {
        case enabled
        /// 已注册，但被用户在「系统设置 › 登录项」里拦下，等待放行。
        case requiresApproval
        case disabled
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        default:                return .disabled
        }
    }

    /// 注册 / 注销登录项。失败原样抛出，调用方负责恢复开关并提示。
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// 打开「系统设置 › 通用 › 登录项」—— requiresApproval 时引导用户放行。
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
