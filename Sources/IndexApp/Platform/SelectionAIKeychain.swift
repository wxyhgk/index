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

/// Index API 密钥共用的 Generic Password 底座。
///
/// 由当前签名 App 创建的 generic-password 项可由同一 App 后续静默读取；不要通过
/// `kSecAttrAccess` 制造需要逐次确认的自定义 ACL。密钥不进入 UserDefaults、日志或备份。
private struct MacAPIKeychain: @unchecked Sendable {
    private static let service = "com.wxyhgk.index.credentials"
    let account: String

    func load() throws -> String? {
        // XCTest 的测试宿主没有生产 App 的 designated requirement。直接读取由
        // Developer ID App 创建的条目会触发 Keychain ACL 交互，并让无 UI 的测试挂起。
        guard !Self.isRunningUnderXCTest else { return nil }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SelectionAIKeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw SelectionAIKeychainError.invalidEncoding }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(_ rawValue: String) throws {
        guard !Self.isRunningUnderXCTest else { return }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            try delete()
            return
        }
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SelectionAIKeychainError.unexpectedStatus(updateStatus)
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SelectionAIKeychainError.unexpectedStatus(addStatus)
        }
    }

    func delete() throws {
        guard !Self.isRunningUnderXCTest else { return }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SelectionAIKeychainError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    fileprivate static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.processName == "xctest"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// 选区 AI 密钥的持久化，并负责从历史 UserDefaults 键做一次性迁移。
struct MacSelectionAIKeychain: SelectionAIAPIKeyStoring {
    static let shared = MacSelectionAIKeychain()

    private static let legacyDefaultsKey = "selectionAI.apiKey"
    private let keychain = MacAPIKeychain(account: "selection-ai-api-key")

    func loadAPIKey() throws -> String? {
        guard !MacAPIKeychain.isRunningUnderXCTest else { return nil }
        if let value = try keychain.load() { return value }
        return try migrateLegacyValueIfNeeded()
    }

    func saveAPIKey(_ apiKey: String) throws {
        try keychain.save(apiKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
    }

    func deleteAPIKey() throws {
        try keychain.delete()
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
    }

    private func migrateLegacyValueIfNeeded() throws -> String? {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: Self.legacyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacy.isEmpty
        else { return nil }
        try keychain.save(legacy)
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
        return legacy
    }
}

/// Agent API Key 的独立 Keychain account。AppSettings 只在内存中保留当前值。
struct MacAgentKeychain: SelectionAIAPIKeyStoring {
    static let shared = MacAgentKeychain()

    private static let legacyDefaultsKey = "agentAPIKey"
    private let keychain = MacAPIKeychain(account: "agent-api-key")

    func loadAPIKey() throws -> String? {
        guard !MacAPIKeychain.isRunningUnderXCTest else { return nil }
        if let value = try keychain.load() { return value }
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: Self.legacyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacy.isEmpty
        else { return nil }
        try keychain.save(legacy)
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
        return legacy
    }

    func saveAPIKey(_ apiKey: String) throws {
        try keychain.save(apiKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
    }

    func deleteAPIKey() throws {
        try keychain.delete()
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
    }
}
