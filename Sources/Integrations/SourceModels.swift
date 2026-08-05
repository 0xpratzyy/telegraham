import Foundation

/// A stable, source-neutral discriminator used from persistence through UI.
/// Keep raw values API-friendly: they are stored in SQLite and deep links.
typealias IntegrationSource = MessageSourceKind

struct SourceCapabilities: Sendable, Equatable {
    let canReadHistory: Bool
    let canReceiveLiveUpdates: Bool
    let canSend: Bool

    static let readOnly = SourceCapabilities(
        canReadHistory: true,
        canReceiveLiveUpdates: false,
        canSend: false
    )
}

struct ExternalSourceAccount: Sendable, Equatable {
    let externalID: String
    let displayName: String
    let email: String?
}

struct SourceAccount: Identifiable, Sendable, Equatable {
    let id: String
    let source: IntegrationSource
    let externalID: String
    let displayName: String
    let email: String?
    let connectedAt: Date
    let lastSyncedAt: Date?
}

enum SourceConversationKind: String, Codable, Sendable {
    case direct
    case group
    case channel
    case thread
    case mailbox
    case importedChat
}

struct CanonicalConversation: Identifiable, Sendable, Equatable {
    let id: String
    let accountID: String
    let source: IntegrationSource
    let externalID: String
    let kind: SourceConversationKind
    let title: String
    let updatedAt: Date?
    let unreadCount: Int

    init(
        id: String,
        accountID: String,
        source: IntegrationSource,
        externalID: String,
        kind: SourceConversationKind,
        title: String,
        updatedAt: Date?,
        unreadCount: Int = 0
    ) {
        self.id = id
        self.accountID = accountID
        self.source = source
        self.externalID = externalID
        self.kind = kind
        self.title = title
        self.updatedAt = updatedAt
        self.unreadCount = max(0, unreadCount)
    }
}

struct CanonicalMessage: Identifiable, Sendable, Equatable {
    let id: String
    let conversationID: String
    let source: IntegrationSource
    let externalID: String
    let threadRootID: String?
    let senderExternalID: String?
    let senderName: String?
    let subject: String?
    let date: Date
    let text: String?
    let isOutgoing: Bool
    let isUnread: Bool

    init(
        id: String,
        conversationID: String,
        source: IntegrationSource,
        externalID: String,
        threadRootID: String?,
        senderExternalID: String?,
        senderName: String?,
        subject: String?,
        date: Date,
        text: String?,
        isOutgoing: Bool,
        isUnread: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.source = source
        self.externalID = externalID
        self.threadRootID = threadRootID
        self.senderExternalID = senderExternalID
        self.senderName = senderName
        self.subject = subject
        self.date = date
        self.text = text
        self.isOutgoing = isOutgoing
        self.isUnread = isUnread
    }
}

struct SyncCursor: RawRepresentable, Codable, Sendable, Equatable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct ConversationPage: Sendable, Equatable {
    let conversations: [CanonicalConversation]
    let nextCursor: SyncCursor?
}

struct MessagePage: Sendable, Equatable {
    let messages: [CanonicalMessage]
    let nextCursor: SyncCursor?
}

protocol SourceAdapter: Sendable {
    var source: IntegrationSource { get }
    var capabilities: SourceCapabilities { get }

    func currentAccount() async throws -> ExternalSourceAccount
    func listConversations(cursor: SyncCursor?, limit: Int) async throws -> ConversationPage
    func fetchMessages(
        conversation: CanonicalConversation,
        cursor: SyncCursor?,
        limit: Int
    ) async throws -> MessagePage
}

enum SourceAdapterError: LocalizedError, Sendable {
    case invalidCredential
    case invalidResponse
    case api(source: IntegrationSource, message: String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "The credential is empty or no longer valid."
        case .invalidResponse:
            return "The service returned a response Pidgy could not read."
        case .api(let source, let message):
            return "\(source.displayName): \(message)"
        case .unsupported(let message):
            return message
        }
    }
}

enum CanonicalID {
    static func account(source: IntegrationSource, externalID: String) -> String {
        "\(source.rawValue):account:\(externalID)"
    }

    static func conversation(source: IntegrationSource, accountID: String, externalID: String) -> String {
        "\(source.rawValue):conversation:\(stableHex("\(accountID)|\(externalID)"))"
    }

    static func message(source: IntegrationSource, conversationID: String, externalID: String) -> String {
        "\(source.rawValue):message:\(stableHex("\(conversationID)|\(externalID)"))"
    }

    /// Deterministic IDs let non-Telegram records flow through the existing
    /// integer-keyed search/context pipeline during the compatibility phase.
    static func legacyInt64(_ value: String) -> Int64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int64(bitPattern: hash | (1 << 63))
    }

    private static func stableHex(_ value: String) -> String {
        String(UInt64(bitPattern: legacyInt64(value)), radix: 16)
    }
}
