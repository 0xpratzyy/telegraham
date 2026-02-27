import Foundation
import Security

enum KeychainManager {
    enum Key: String {
        case apiId = "com.tgsearch.apiId"
        case apiHash = "com.tgsearch.apiHash"
    }

    enum KeychainError: Error, LocalizedError {
        case saveFailed(OSStatus)
        case readFailed(OSStatus)
        case deleteFailed(OSStatus)
        case unexpectedData

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status): return "Keychain save failed: \(status)"
            case .readFailed(let status): return "Keychain read failed: \(status)"
            case .deleteFailed(let status): return "Keychain delete failed: \(status)"
            case .unexpectedData: return "Unexpected keychain data format"
            }
        }
    }

    static func save(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else { return }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tgsearch.app",
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tgsearch.app",
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func retrieve(for key: Key) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tgsearch.app",
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.readFailed(status)
        }

        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }

        return string
    }

    static func delete(for key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tgsearch.app",
            kSecAttrAccount as String: key.rawValue,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    static func hasCredentials() -> Bool {
        let apiId = try? retrieve(for: .apiId)
        let apiHash = try? retrieve(for: .apiHash)
        return apiId != nil && apiHash != nil
    }
}
