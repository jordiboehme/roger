import Foundation
import Security

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): "Keychain save failed: \(status)"
        case .deleteFailed(let status): "Keychain delete failed: \(status)"
        case .encodingFailed: "Failed to encode value for keychain"
        }
    }
}

enum KeychainManager {
    private static let service = "com.jordiboehme.roger"

    static func saveAPIKey(_ key: String, for provider: LLMProviderType) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try save(data: data, account: provider.rawValue)
    }

    static func loadAPIKey(for provider: LLMProviderType) -> String? {
        guard let data = load(account: provider.rawValue) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAPIKey(for provider: LLMProviderType) throws {
        try delete(account: provider.rawValue)
    }

    private static func save(data: Data, account: String) throws {
        try? delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}
