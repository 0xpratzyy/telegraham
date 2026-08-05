import Foundation

@MainActor
final class IntegrationConnectionStore: ObservableObject {
    static let shared = IntegrationConnectionStore()

    enum Activity: Equatable {
        case idle
        case connecting
        case syncing
    }

    @Published private(set) var accounts: [SourceAccount] = []
    @Published private(set) var activity: [IntegrationSource: Activity] = [:]
    @Published private(set) var statusMessage: [IntegrationSource: String] = [:]
    private var localServices: [String: LocalCanonicalSourceService] = [:]

    private init() {}

    var connectedSources: Set<IntegrationSource> {
        Set(accounts.map(\.source))
    }

    func load() async {
        accounts = await DatabaseManager.shared.loadSourceAccounts()
        for account in accounts where account.source == .gmail || account.source == .whatsapp {
            let service = localServices[account.id] ?? LocalCanonicalSourceService(account: account)
            if localServices[account.id] == nil {
                localServices[account.id] = service
                SourceRegistry.shared.register(service)
            }
            await service.refresh()
        }
    }

    func hasCredential(for source: IntegrationSource) -> Bool {
        guard let key = source.credentialKey else { return source == .whatsapp }
        guard let value = try? KeychainManager.retrieve(for: key) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func connect(source: IntegrationSource, credential: String) async {
        guard let key = source.credentialKey else { return }
        activity[source] = .connecting
        statusMessage[source] = nil
        do {
            let adapter = try adapter(source: source, credential: credential)
            let external = try await adapter.currentAccount()
            try KeychainManager.save(credential.trimmingCharacters(in: .whitespacesAndNewlines), for: key)
            let account = SourceAccount(
                id: CanonicalID.account(source: source, externalID: external.externalID),
                source: source,
                externalID: external.externalID,
                displayName: external.displayName,
                email: external.email,
                connectedAt: Date(),
                lastSyncedAt: nil
            )
            try await DatabaseManager.shared.upsertSourceAccount(account)
            await load()
            statusMessage[source] = "Connected as \(external.displayName)"
        } catch {
            statusMessage[source] = error.localizedDescription
        }
        activity[source] = .idle
    }

    func sync(source: IntegrationSource) async {
        guard let key = source.credentialKey,
              let credential = try? KeychainManager.retrieve(for: key),
              !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage[source] = "Connect this source before syncing."
            return
        }
        activity[source] = .syncing
        statusMessage[source] = nil
        do {
            let result = try await SourceSyncCoordinator.shared.sync(
                adapter: try adapter(source: source, credential: credential)
            )
            await load()
            statusMessage[source] = "Read \(result.messages) messages from \(result.conversations) conversations"
        } catch {
            statusMessage[source] = error.localizedDescription
        }
        activity[source] = .idle
    }

    func disconnect(source: IntegrationSource) {
        guard let key = source.credentialKey else { return }
        try? KeychainManager.delete(for: key)
        statusMessage[source] = "Credential removed. Imported local data is unchanged."
    }

    func importWhatsApp(url: URL, ownerName: String?) async {
        activity[.whatsapp] = .syncing
        statusMessage[.whatsapp] = nil
        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try WhatsAppExportParser.parse(
                text,
                fileName: url.lastPathComponent,
                ownerName: ownerName
            )
            let result = try await SourceSyncCoordinator.shared.importWhatsApp(parsed)
            await load()
            statusMessage[.whatsapp] = "Imported \(result.messages) messages"
        } catch {
            statusMessage[.whatsapp] = error.localizedDescription
        }
        activity[.whatsapp] = .idle
    }

    private func adapter(source: IntegrationSource, credential: String) throws -> any SourceAdapter {
        switch source {
        case .gmail:
            return try GmailSourceAdapter(accessToken: credential)
        case .slack:
            throw SourceAdapterError.unsupported("Slack uses its dedicated OAuth connection.")
        case .telegram:
            throw SourceAdapterError.unsupported("Telegram is managed by the existing TDLib connection.")
        case .whatsapp:
            throw SourceAdapterError.unsupported("Personal WhatsApp supports user-initiated export import only.")
        }
    }
}

private extension IntegrationSource {
    var credentialKey: KeychainManager.Key? {
        switch self {
        case .gmail: return .gmailAccessToken
        case .telegram, .slack, .whatsapp: return nil
        }
    }
}
