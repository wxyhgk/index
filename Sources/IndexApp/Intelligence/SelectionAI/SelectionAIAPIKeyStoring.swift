import Foundation

/// AI API Key 持久化契约。
/// macOS Keychain、测试替身或其他平台实现均在领域层之外注入。
protocol SelectionAIAPIKeyStoring: Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}
