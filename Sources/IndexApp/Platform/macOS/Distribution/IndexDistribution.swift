import Foundation

/// 构建产物的能力边界。商店打包脚本只修改旁路副本的 Info.plist，源码和
/// Developer ID 直装版保持完整能力；运行时不能依赖编译条件猜测签名渠道。
enum IndexDistribution {
    static var isAppStore: Bool {
        Bundle.main.object(forInfoDictionaryKey: "IndexDistributionChannel") as? String
            == "app-store"
    }

    /// App Sandbox 下不提供全局 AX 读文本或 CGEvent 注入。
    static var supportsGlobalAccessibilityFeatures: Bool { !isAppStore }
}
