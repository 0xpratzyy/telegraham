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

struct GmailConnectedAccount: Identifiable, Equatable, Sendable {
    let email: String
    var id: String { email }
}

@MainActor
final class GmailConnectionManager: ObservableObject {
    nonisolated static let automaticRefreshInterval: TimeInterval = 5 * 60
    nonisolated static let incrementalSyncOverlap: TimeInterval = 60 * 60

    enum State: Equatable {
        case unavailable
        case disconnected
        case connecting
        case connected(String)
        case syncing(String)
        case failed(String)
    }

    enum AccountActivity: Equatable {
        case idle
        case syncing
    }

    static let shared = GmailConnectionManager()
    @Published private(set) var state: State
    @Published private(set) var accounts: [GmailConnectedAccount] = []
    @Published private(set) var accountActivity: [String: AccountActivity] = [:]
    @Published private(set) var accountStatus: [String: String] = [:]
    @Published private(set) var syncProgress: GmailSyncProgress?
    private var automaticRefreshTask: Task<Void, Never>?

    private init() {
        state = Self.resolveCredentials() == nil ? .unavailable : .disconnected
        syncProgress = nil
    }

    var configuredClientId: String? { Self.resolveClientId() }
    var canAddAccount: Bool { Self.resolveCredentials() != nil }
    var isConnecting: Bool { state == .connecting }

    func restore() async {
        // Cached Gmail remains useful even if OAuth configuration is absent.
        // Register every locally imported mailbox before resolving whether a
        // fresh remote sync is possible in this particular build.
        await IntegrationConnectionStore.shared.load()
        do {
            setAccounts(try GmailCredentialVault.loadMigratingLegacy())
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        refreshIdleState()
        if !accounts.isEmpty {
            FactExtractionCoordinator.shared.triggerPass()
            startAutomaticRefresh(immediate: true)
        }
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

    /// Always opens Google's account chooser. Connecting an address already
    /// in the vault refreshes that account; choosing another adds a new one.
    func connect() async {
        guard let credentials = Self.resolveCredentials() else { state = .unavailable; return }
        state = .connecting
        syncProgress = nil
        var connectedEmail: String?
        do {
            let token = try await GmailOAuth.connect(
                clientId: credentials.clientId,
                clientSecret: credentials.clientSecret
            )
            let adapter = try GmailSourceAdapter(accessToken: token.accessToken)
            let external = try await adapter.currentAccount()
            let email = external.externalID.lowercased()
            connectedEmail = email
            let existingRefresh = try GmailCredentialVault.credential(for: email)?.refreshToken
            try save(token, email: email, preservingRefresh: existingRefresh)
            setAccounts(try GmailCredentialVault.load())
            accountActivity[email] = .syncing
            let result = try await runSync(adapter: adapter, email: email)
            await IntegrationConnectionStore.shared.load()
            FactExtractionCoordinator.shared.triggerPass(bypassProviderCooldown: true)
            accountStatus[email] = "Read \(result.messages) messages"
            accountActivity[email] = .idle
            syncProgress = nil
            refreshIdleState()
            startAutomaticRefresh(immediate: false)
        } catch {
            syncProgress = nil
            if let connectedEmail, accounts.contains(where: { $0.email == connectedEmail }) {
                accountActivity[connectedEmail] = .idle
                accountStatus[connectedEmail] = error.localizedDescription
                refreshIdleState()
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func sync(email: String) async {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard accountActivity[normalizedEmail] != .syncing else { return }
        accountActivity[normalizedEmail] = .syncing
        accountStatus[normalizedEmail] = nil
        do {
            let token = try await validAccessToken(for: normalizedEmail)
            let lastSyncedAt = await DatabaseManager.shared.loadSourceAccounts()
                .first {
                    $0.source == .gmail &&
                    $0.externalID.caseInsensitiveCompare(normalizedEmail) == .orderedSame
                }?
                .lastSyncedAt
            let result = try await runSync(
                adapter: GmailSourceAdapter(
                    accessToken: token,
                    since: Self.incrementalStart(lastSyncedAt: lastSyncedAt)
                ),
                email: normalizedEmail
            )
            await IntegrationConnectionStore.shared.load()
            FactExtractionCoordinator.shared.triggerPass(bypassProviderCooldown: true)
            accountStatus[normalizedEmail] = "Read \(result.messages) messages"
        } catch {
            accountStatus[normalizedEmail] = error.localizedDescription
        }
        accountActivity[normalizedEmail] = .idle
        syncProgress = nil
        refreshIdleState()
    }

    /// Compatibility convenience for existing call sites: sync every mailbox,
    /// one at a time, so progress and rate limits stay understandable.
    func sync() async {
        for account in accounts { await sync(email: account.email) }
    }

    /// Removes only this mailbox's authorization. Imported local records stay
    /// available until the user chooses the separate "Delete all local data"
    /// action, matching Pidgy's existing disconnect semantics.
    func disconnect(email: String) {
        do {
            setAccounts(try GmailCredentialVault.remove(email: email))
            accountActivity.removeValue(forKey: email.lowercased())
            accountStatus.removeValue(forKey: email.lowercased())
            refreshIdleState()
            if accounts.isEmpty {
                automaticRefreshTask?.cancel()
                automaticRefreshTask = nil
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        do {
            try GmailCredentialVault.deleteAll()
            setAccounts([])
            accountActivity = [:]
            accountStatus = [:]
            automaticRefreshTask?.cancel()
            automaticRefreshTask = nil
            refreshIdleState()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func runSync(adapter: GmailSourceAdapter, email: String) async throws -> SourceSyncCoordinator.Result {
        state = .syncing("Preparing \(email)…")
        return try await SourceSyncCoordinator.shared.sync(
            adapter: adapter,
            maxConversations: 200,
            progress: { progress in
                await MainActor.run {
                    GmailConnectionManager.shared.apply(progress, email: email)
                }
            }
        )
    }

    private func apply(_ progress: SourceSyncCoordinator.Progress, email: String) {
        let title: String
        switch progress.phase {
        case .discovering:
            title = "Finding recent mail"
        case .reading:
            title = progress.total > 0
                ? "Reading \(progress.completed) of \(progress.total) threads"
                : "Reading Gmail"
        case .saving:
            title = progress.total > 0
                ? "Preparing \(progress.completed) of \(progress.total) threads"
                : "Preparing Gmail"
        }
        syncProgress = GmailSyncProgress(title: title, completed: progress.completed, total: progress.total)
        accountStatus[email] = title
        state = .syncing(title)
    }

    private func validAccessToken(for email: String) async throws -> String {
        guard var stored = try GmailCredentialVault.credential(for: email) else {
            throw SourceAdapterError.invalidCredential
        }
        if Date().timeIntervalSince1970 < stored.expiresAt - 60, !stored.accessToken.isEmpty {
            return stored.accessToken
        }
        guard let credentials = Self.resolveCredentials(),
              let refresh = stored.refreshToken, !refresh.isEmpty else {
            throw SourceAdapterError.invalidCredential
        }
        let token = try await GmailOAuth.refresh(
            clientId: credentials.clientId,
            clientSecret: credentials.clientSecret,
            refreshToken: refresh
        )
        stored.accessToken = token.accessToken
        stored.refreshToken = token.refreshToken ?? refresh
        stored.expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn)).timeIntervalSince1970
        try GmailCredentialVault.upsert(stored)
        return token.accessToken
    }

    private func save(
        _ token: GmailOAuthToken,
        email: String,
        preservingRefresh existingRefresh: String? = nil
    ) throws {
        try GmailCredentialVault.upsert(
            GmailStoredAccountCredential(
                email: email,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken ?? existingRefresh,
                expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)).timeIntervalSince1970
            )
        )
    }

    private func setAccounts(_ stored: [GmailStoredAccountCredential]) {
        accounts = stored.map { GmailConnectedAccount(email: $0.email) }
    }

    nonisolated static func incrementalStart(lastSyncedAt: Date?) -> Date? {
        lastSyncedAt?.addingTimeInterval(-incrementalSyncOverlap)
    }

    private func startAutomaticRefresh(immediate: Bool) {
        automaticRefreshTask?.cancel()
        guard !accounts.isEmpty else {
            automaticRefreshTask = nil
            return
        }

        automaticRefreshTask = Task { [weak self] in
            if immediate { await self?.syncIdleAccounts() }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.automaticRefreshInterval * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.syncIdleAccounts()
            }
        }
    }

    private func syncIdleAccounts() async {
        let emails = accounts.map(\.email)
        for email in emails where accountActivity[email] != .syncing {
            await sync(email: email)
        }
    }

    private func refreshIdleState() {
        if Self.resolveCredentials() == nil {
            state = .unavailable
        } else if accounts.isEmpty {
            state = .disconnected
        } else {
            let label = accounts.count == 1 ? "1 account" : "\(accounts.count) accounts"
            state = .connected(label)
        }
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
