import Foundation

/// 图库中一个来源 App 的稳定身份。能拿到 bundle identifier 时以它为准；
/// 网页 App、脚本或异常窗口拿不到时，才退回显示名称。
struct CapturedAppIdentity: Hashable, Sendable, Identifiable {
    let name: String
    let bundleID: String?

    init(name: String, bundleID: String?) {
        self.name = name
        let normalized = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleID = normalized?.isEmpty == false ? normalized : nil
    }

    var id: String {
        bundleID.map { "bundle:\($0)" } ?? "name:\(name)"
    }
}

/// “应用”首页需要的一次性聚合结果。预览固定为该 App 最新的三张截图；
/// UI 不再逐卡查询，也不会依赖当前分页只加载到的 `store.shots`。
struct CapturedAppSummary: Identifiable, Equatable {
    let identity: CapturedAppIdentity
    let captureCount: Int
    let lastCapturedAt: Date
    let previews: [Shot]

    var id: String { identity.id }
    var name: String { identity.name }
    var bundleID: String? { identity.bundleID }
}
