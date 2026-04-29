import Foundation
import Security

/// Credential storage for Pidgy.
///
/// Debug and test builds stay file-backed by default so local ad-hoc builds
/// avoid unexpected keychain prompts or writes into a user's production
/// keychain items. Production builds store AI API keys in the native macOS
/// Keychain while leaving non-secret config on disk.
enum KeychainManager {
    enum Key: String {
        case apiId = "com.pidgy.apiId"
        case apiHash = "com.pidgy.apiHash"
        case aiProviderType = "com.pidgy.aiProviderType"
        case aiApiKeyOpenAI = "com.pidgy.aiApiKey.openai"
        case aiApiKeyClaude = "com.pidgy.aiApiKey.claude"
        case aiModelOpenAI = "com.pidgy.aiModel.openai"
        case aiModelClaude = "com.pidgy.aiModel.claude"
        case aiApiKey = "com.pidgy.aiApiKey"
        case aiModel = "com.pidgy.aiModel"
    }

    enum KeychainError: Error, LocalizedError {
        case saveFailed(OSStatus)
        case readFailed(OSStatus)
        case deleteFailed(OSStatus)
        case unexpectedData

        var errorDescription: String? {
            switch self {
            case .saveFailed: return "Failed to save credential"
            case .readFailed: return "Failed to read credential"
            case .deleteFailed: return "Failed to delete credential"
            case .unexpectedData: return "Unexpected data format"
            }
        }
    }

    private static let defaultStorageDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Pidgy", isDirectory: true).appendingPathComponent("credentials", isDirectory: true)
    }()

    private enum StorageBackend {
        case file
        case nativeKeychain
    }

    private static let defaultKeychainService = "com.pidgy.credentials"
    private static let productionNativeKeychainKeys: Set<Key> = [
        .apiHash,
        .aiApiKey,
        .aiApiKeyOpenAI,
        .aiApiKeyClaude
    ]

    private static var storageDirOverride: URL?
    private static var keychainServiceOverride: String?
    private static var nativeKeyOverride: Set<Key>?

    private static var storageDir: URL {
        storageDirOverride ?? defaultStorageDir
    }

    private static var keychainService: String {
        keychainServiceOverride ?? defaultKeychainService
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        // Set directory to user-only access
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDir.path)
    }

    private static func fileURL(for key: Key) -> URL {
        storageDir.appendingPathComponent(key.rawValue)
    }

    static func save(_ value: String, for key: Key) throws {
        switch storageBackend(for: key) {
        case .file:
            try saveFileValue(value, for: key)
        case .nativeKeychain:
            try saveKeychainValue(value, for: key)
        }
    }

    static func retrieve(for key: Key) throws -> String? {
        switch storageBackend(for: key) {
        case .file:
            return try retrieveFileValue(for: key)
        case .nativeKeychain:
            if let nativeValue = try retrieveKeychainValue(for: key) {
                return nativeValue
            }

            let legacyValue = try retrieveFileValue(for: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let legacyValue, !legacyValue.isEmpty else {
                return nil
            }

            try saveKeychainValue(legacyValue, for: key)
            try deleteFileValue(for: key)
            return legacyValue
        }
    }

    static func delete(for key: Key) throws {
        switch storageBackend(for: key) {
        case .file:
            try deleteFileValue(for: key)
        case .nativeKeychain:
            try deleteKeychainValue(for: key)
            try deleteFileValue(for: key)
        }
    }

    static func hasCredentials() -> Bool {
        let apiId = try? retrieve(for: .apiId)
        let apiHash = try? retrieve(for: .apiHash)
        return apiId != nil && apiHash != nil
    }

    #if DEBUG
    static func configureForTesting(
        storageDirectoryOverride: URL?,
        keychainServiceOverride: String? = nil,
        nativeKeyOverride: Set<Key>? = nil
    ) {
        self.storageDirOverride = storageDirectoryOverride
        self.keychainServiceOverride = keychainServiceOverride
        self.nativeKeyOverride = nativeKeyOverride
    }

    static func usesNativeKeychainInProductionForTesting(_ key: Key) -> Bool {
        productionNativeKeychainKeys.contains(key)
    }
    #endif

    private static func storageBackend(for key: Key) -> StorageBackend {
        #if DEBUG
        if let nativeKeyOverride {
            return nativeKeyOverride.contains(key) ? .nativeKeychain : .file
        }
        return .file
        #else
        return productionNativeKeychainKeys.contains(key) ? .nativeKeychain : .file
        #endif
    }

    private static func saveFileValue(_ value: String, for key: Key) throws {
        try ensureDirectory()
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        let url = fileURL(for: key)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func retrieveFileValue(for key: Key) throws -> String? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8)
    }

    private static func deleteFileValue(for key: Key) throws {
        let url = fileURL(for: key)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func saveKeychainValue(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        let query = baseKeychainQuery(for: key)
        let addQuery = query.merging(
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
            ],
            uniquingKeysWith: { _, new in new }
        )

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
                ] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.saveFailed(updateStatus)
            }
            return
        }

        guard addStatus == errSecSuccess else {
            throw KeychainError.saveFailed(addStatus)
        }
    }

    private static func retrieveKeychainValue(for key: Key) throws -> String? {
        var query = baseKeychainQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.readFailed(status)
        }
    }

    private static func deleteKeychainValue(for key: Key) throws {
        let status = SecItemDelete(baseKeychainQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    private static func baseKeychainQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
