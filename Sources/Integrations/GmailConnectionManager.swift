import Foundation

struct GmailSyncProgress: Equatable, Sendable {
    let title: String
    let completed: Int
    let total: Int

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

@MainActor
final class GmailConnectionManager: ObservableObject {
    enum State: Equatable {
        case unavailable
        case disconnected
        case connecting
        case connected(String)
        case syncing(String)
        case failed(String)
    }

    static let shared = GmailConnectionManager()
    @Published private(set) var state: State
    @Published private(set) var syncProgress: GmailSyncProgress?

    private init() {
        state = Self.resolveCredentials() == nil ? .unavailable : .disconnected
        syncProgress = nil
    }

    var configuredClientId: String? {
        Self.resolveClientId()
    }

    func restore() async {
        // Cached Gmail is useful even when this particular build no longer has
        // OAuth credentials (or the refresh token was removed). Register the
        // local read-only source first; connection state only controls future
        // remote syncs.
        await IntegrationConnectionStore.shared.load()
        guard Self.resolveCredentials() != nil else { state = .unavailable; return }
        guard (try? KeychainManager.retrieve(for: .gmailRefreshToken)) != nil,
              let email = try? KeychainManager.retrieve(for: .gmailAccountEmail) else {
            state = .disconnected
            return
        }
        state = .connected(email)
        FactExtractionCoordinator.shared.triggerPass()
    }

    func configureAndConnect(clientId rawClientId: String) async {
        let clientId = rawClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientId.hasSuffix(".apps.googleusercontent.com") else {
            state = .failed("Enter a Google OAuth Desktop client ID ending in .apps.googleusercontent.com")
            return
        }
        do {
            try KeychainManager.save(clientId, for: .gmailClientId)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        await connect()
    }

    func connect() async {
        guard let credentials = Self.resolveCredentials() else { state = .unavailable; return }
        state = .connecting
        syncProgress = nil
        do {
            let token = try await GmailOAuth.connect(
                clientId: credentials.clientId,
                clientSecret: credentials.clientSecret
            )
            try save(token)
            let adapter = try GmailSourceAdapter(accessToken: token.accessToken)
            let external = try await adapter.currentAccount()
            try KeychainManager.save(external.externalID, for: .gmailAccountEmail)
            let result = try await runSync(adapter: adapter)
            await IntegrationConnectionStore.shared.load()
            FactExtractionCoordinator.shared.triggerPass(bypassProviderCooldown: true)
            state = .connected("\(external.displayName) · \(result.messages) messages")
            syncProgress = nil
        } catch {
            syncProgress = nil
            state = .failed(error.localizedDescription)
        }
    }

    func sync() async {
        do {
            let token = try await validAccessToken()
            let result = try await runSync(adapter: GmailSourceAdapter(accessToken: token))
            await IntegrationConnectionStore.shared.load()
            FactExtractionCoordinator.shared.triggerPass(bypassProviderCooldown: true)
            let email = (try? KeychainManager.retrieve(for: .gmailAccountEmail)) ?? "Gmail"
            state = .connected("\(email) · \(result.messages) messages")
            syncProgress = nil
        } catch {
            syncProgress = nil
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        for key: KeychainManager.Key in [.gmailAccessToken, .gmailRefreshToken, .gmailTokenExpiry, .gmailAccountEmail] {
            try? KeychainManager.delete(for: key)
        }
        state = .disconnected
        syncProgress = nil
    }

    private func runSync(adapter: GmailSourceAdapter) async throws -> SourceSyncCoordinator.Result {
        state = .syncing("Preparing your inbox…")
        return try await SourceSyncCoordinator.shared.sync(
            adapter: adapter,
            maxConversations: 200,
            progress: { progress in
                await MainActor.run {
                    GmailConnectionManager.shared.apply(progress)
                }
            }
        )
    }

    private func apply(_ progress: SourceSyncCoordinator.Progress) {
        let title: String
        switch progress.phase {
        case .discovering:
            title = "Finding recent inbox threads"
        case .reading:
            title = progress.total > 0
                ? "Reading \(progress.completed) of \(progress.total) threads"
                : "Reading Gmail"
        case .saving:
            title = progress.total > 0
                ? "Preparing \(progress.completed) of \(progress.total) threads"
                : "Preparing your inbox"
        }
        syncProgress = GmailSyncProgress(title: title, completed: progress.completed, total: progress.total)
        state = .syncing(title)
    }

    private func validAccessToken() async throws -> String {
        if let raw = try? KeychainManager.retrieve(for: .gmailTokenExpiry),
           let expiry = Double(raw), Date().timeIntervalSince1970 < expiry - 60,
           let access = try? KeychainManager.retrieve(for: .gmailAccessToken) {
            return access
        }
        guard let credentials = Self.resolveCredentials(),
              let refresh = try? KeychainManager.retrieve(for: .gmailRefreshToken) else {
            throw SourceAdapterError.invalidCredential
        }
        let token = try await GmailOAuth.refresh(
            clientId: credentials.clientId,
            clientSecret: credentials.clientSecret,
            refreshToken: refresh
        )
        try save(token, preservingRefresh: refresh)
        return token.accessToken
    }

    private func save(_ token: GmailOAuthToken, preservingRefresh existingRefresh: String? = nil) throws {
        try KeychainManager.save(token.accessToken, for: .gmailAccessToken)
        if let refresh = token.refreshToken ?? existingRefresh {
            try KeychainManager.save(refresh, for: .gmailRefreshToken)
        }
        try KeychainManager.save(
            String(Date().addingTimeInterval(TimeInterval(token.expiresIn)).timeIntervalSince1970),
            for: .gmailTokenExpiry
        )
    }

    private static func resolveClientId() -> String? {
        if let bundled = BundledSecrets.googleClientId { return bundled }
        guard let stored = try? KeychainManager.retrieve(for: .gmailClientId) else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolveCredentials() -> (clientId: String, clientSecret: String)? {
        guard let clientId = resolveClientId(),
              let clientSecret = BundledSecrets.googleClientSecret else { return nil }
        return (clientId, clientSecret)
    }
}
