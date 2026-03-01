import Foundation

/// File-based credential storage in ~/Library/Application Support/TGSearch/
/// Uses POSIX 0600 permissions (user-only read/write). Avoids macOS Keychain
/// password prompts that occur with ad-hoc signed development builds.
enum KeychainManager {
    enum Key: String {
        case apiId = "com.tgsearch.apiId"
        case apiHash = "com.tgsearch.apiHash"
        case aiProviderType = "com.tgsearch.aiProviderType"
        case aiApiKey = "com.tgsearch.aiApiKey"
        case aiModel = "com.tgsearch.aiModel"
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

    private static let storageDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TGSearch", isDirectory: true).appendingPathComponent("credentials", isDirectory: true)
    }()

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        // Set directory to user-only access
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDir.path)
    }

    private static func fileURL(for key: Key) -> URL {
        storageDir.appendingPathComponent(key.rawValue)
    }

    static func save(_ value: String, for key: Key) throws {
        try ensureDirectory()
        guard let data = value.data(using: .utf8) else { return }
        let url = fileURL(for: key)
        try data.write(to: url, options: [.atomic])
        // Set file to user-only read/write
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func retrieve(for key: Key) throws -> String? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8)
    }

    static func delete(for key: Key) throws {
        let url = fileURL(for: key)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func hasCredentials() -> Bool {
        let apiId = try? retrieve(for: .apiId)
        let apiHash = try? retrieve(for: .apiHash)
        return apiId != nil && apiHash != nil
    }
}
