import Foundation
import Security

protocol SelectionAIAPIKeyStoring: Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

enum SelectionAIKeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "无法访问 macOS 钥匙串：\(detail)"
        case .invalidEncoding:
            return "钥匙串中的 API Key 不是有效文本"
        }
    }
}

/// 选区 AI 密钥的持久化。
///
/// 用 UserDefaults 而不是 Keychain —— Keychain 每次读取都会弹
/// "Index 想要访问你的密钥"确认框，体验太诡异。
/// API key 是用户自己填的，不是系统凭证，存 UserDefaults 足够。
struct MacSelectionAIKeychain: SelectionAIAPIKeyStoring {
    static let shared = MacSelectionAIKeychain()

    private static let key = "selectionAI.apiKey"
    private let defaults = UserDefaults.standard

    func loadAPIKey() throws -> String? {
        guard let value = defaults.string(forKey: Self.key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey()
            return
        }
        defaults.set(trimmed, forKey: Self.key)
    }

    func deleteAPIKey() throws {
        defaults.removeObject(forKey: Self.key)
    }
}
