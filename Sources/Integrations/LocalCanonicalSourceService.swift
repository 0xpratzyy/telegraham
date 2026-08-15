import Foundation

/// Presents locally imported Gmail and WhatsApp records through the same
/// `MessageSource` contract as Telegram and Slack.
@MainActor
final class LocalCanonicalSourceService: ObservableObject, MessageSource {
    nonisolated let sourceID: SourceID
    let account: SourceAccount

    @Published private(set) var chats: [TGChat] = []
    @Published private(set) var isReady = false
    var visibleChats: [TGChat] { chats.filter(\.isInMainList) }
    var currentUser: TGUser?
    private var usersByID: [Int64: TGUser] = [:]

    init(account: SourceAccount) {
        self.account = account
        self.sourceID = SourceID(kind: account.source, account: account.externalID)
        // Match the sender ID minted during canonical message import so
        // source-neutral ownership checks keep working across providers.
        let id = CanonicalID.legacyInt64(sourceID.rawValue + "|user|" + account.externalID)
        self.currentUser = TGUser(
            id: id,
            firstName: account.displayName,
            lastName: "",
            username: account.email,
            phoneNumber: nil,
            isBot: false
        )
    }

    func refresh() async {
        let conversations = await DatabaseManager.shared.loadSourceConversations(accountID: account.id)
        usersByID = await DatabaseManager.shared.loadSourceUsers(sourceID: sourceID)
        if let ownIdentity = usersByID[currentUser?.id ?? 0] {
            currentUser = TGUser(
                id: ownIdentity.id,
                firstName: account.displayName,
                lastName: "",
                username: account.email,
                phoneNumber: ownIdentity.phoneNumber,
                isBot: false,
                avatarURL: ownIdentity.avatarURL
            )
        }
        let conversationChatIds = Dictionary(
            uniqueKeysWithValues: conversations.map { conversation in
                (
                    conversation.id,
                    CanonicalID.legacyInt64(sourceID.rawValue + "|" + conversation.externalID)
                )
            }
        )
        let latestByChat = await DatabaseManager.shared.loadLatestMessages(
            chatIds: Array(conversationChatIds.values)
        )
        let mapped = conversations.compactMap { conversation -> TGChat? in
            guard let chatID = conversationChatIds[conversation.id] else { return nil }
            let latest = latestByChat[chatID]
                .map(MessageCacheService.CachedMessage.from)
                .map { $0.toTGMessage() }
            return TGChat(
                id: chatID,
                title: conversation.title,
                chatType: Self.chatType(for: conversation.kind, id: chatID),
                unreadCount: conversation.unreadCount,
                lastMessage: latest,
                memberCount: nil,
                order: Int64((conversation.updatedAt ?? latest?.date ?? .distantPast).timeIntervalSince1970),
                isInMainList: true,
                smallPhotoFileId: nil,
                source: sourceID,
                avatarURL: conversation.avatarURL
            )
        }
        chats = mapped.sorted { ($0.lastActivityDate ?? .distantPast) > ($1.lastActivityDate ?? .distantPast) }
        isReady = true
    }

    func chatHistory(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [TGMessage] {
        let records = await DatabaseManager.shared.loadMessages(chatId: chatId, limit: max(1, limit * 2))
        let filtered = fromMessageId == 0 ? records : records.filter { $0.id != fromMessageId && $0.date < (records.first { $0.id == fromMessageId }?.date ?? .distantFuture) }
        return filtered.prefix(limit).map(MessageCacheService.CachedMessage.from).map { $0.toTGMessage() }
    }

    func user(id: Int64) async throws -> TGUser? {
        if currentUser?.id == id { return currentUser }
        return usersByID[id]
    }

    nonisolated func isLikelyBot(chat: TGChat) -> Bool { false }

    private static func chatType(for kind: SourceConversationKind, id: Int64) -> TGChat.ChatType {
        switch kind {
        case .direct: return .privateChat(userId: id)
        case .group, .importedChat: return .basicGroup(groupId: id)
        case .channel, .mailbox, .thread: return .supergroup(supergroupId: id, isChannel: false)
        }
    }
}
