import Foundation

/// One read-only Google authorization, keyed by the mailbox address returned
/// from Gmail's profile endpoint. The database was already account-scoped;
/// this vault is the missing multi-account credential layer.
struct GmailStoredAccountCredential: Codable, Equatable, Sendable, Identifiable {
    let email: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: TimeInterval

    var id: String { email }

    init(
        email: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: TimeInterval
    ) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.accessToken = accessToken
        self.refreshToken = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.expiresAt = expiresAt
    }
}

enum GmailCredentialVault {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Loads the current vault and performs the single-account → multi-account
    /// migration once. The new value is committed before legacy keys are
    /// removed, so an interrupted migration cannot disconnect the user.
    static func loadMigratingLegacy() throws -> [GmailStoredAccountCredential] {
        let stored = try load()
        if !stored.isEmpty { return stored }

        guard let rawEmail = try KeychainManager.retrieve(for: .gmailAccountEmail),
              !rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let accessToken = try KeychainManager.retrieve(for: .gmailAccessToken) ?? ""
        let refreshToken = try KeychainManager.retrieve(for: .gmailRefreshToken)
        guard !accessToken.isEmpty || refreshToken?.isEmpty == false else { return [] }
        let expiry = (try KeychainManager.retrieve(for: .gmailTokenExpiry)).flatMap(Double.init) ?? 0
        let migrated = GmailStoredAccountCredential(
            email: rawEmail,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiry
        )
        try save([migrated])
        for key: KeychainManager.Key in [
            .gmailAccessToken,
            .gmailRefreshToken,
            .gmailTokenExpiry,
            .gmailAccountEmail
        ] {
            try? KeychainManager.delete(for: key)
        }
        return [migrated]
    }

    static func load() throws -> [GmailStoredAccountCredential] {
        guard let raw = try KeychainManager.retrieve(for: .gmailAccounts),
              let data = raw.data(using: .utf8),
              !data.isEmpty else { return [] }
        return try decoder.decode([GmailStoredAccountCredential].self, from: data)
            .sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
    }

    static func credential(for email: String) throws -> GmailStoredAccountCredential? {
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try loadMigratingLegacy().first { $0.email == key }
    }

    @discardableResult
    static func upsert(_ credential: GmailStoredAccountCredential) throws -> [GmailStoredAccountCredential] {
        var accounts = try loadMigratingLegacy()
        if let index = accounts.firstIndex(where: { $0.email == credential.email }) {
            accounts[index] = credential
        } else {
            accounts.append(credential)
        }
        try save(accounts)
        return accounts.sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
    }

    @discardableResult
    static func remove(email: String) throws -> [GmailStoredAccountCredential] {
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let accounts = try loadMigratingLegacy().filter { $0.email != key }
        try save(accounts)
        return accounts
    }

    static func deleteAll() throws {
        try KeychainManager.delete(for: .gmailAccounts)
    }

    private static func save(_ accounts: [GmailStoredAccountCredential]) throws {
        let deduplicated = Dictionary(
            accounts.map { ($0.email, $0) },
            uniquingKeysWith: { _, newest in newest }
        ).values.sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
        let data = try encoder.encode(deduplicated)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw KeychainManager.KeychainError.unexpectedData
        }
        try KeychainManager.save(raw, for: .gmailAccounts)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
