import Foundation

/// 选区 AI 的唯一生产装配点。Capture/Toolbar 不认识具体服务，Platform Provider
/// 也不反向读取 AppSettings；每次打开截图覆盖层时在这里冻结当前普通配置。
@MainActor
enum SelectionAIAssembly {
    static func makeExecutor(intelligence: any IntelligencePreferences) -> SelectionAIExecutor {
        let provider = OpenAICompatibleSelectionAIProvider(
            configuration: OpenAICompatibleSelectionAIConfiguration(
                baseURL: intelligence.selectionAIBaseURL,
                model: intelligence.selectionAIModel
            ),
            credentialStore: MacSelectionAIKeychain.shared
        )
        return SelectionAIExecutor(provider: provider)
    }
}
