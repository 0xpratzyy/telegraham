import Foundation

/// Event-driven hot cache. Kept fresh via TDLib real-time updates — no TTL/expiry.
/// Two-tier: in-memory recent window + durable SQLite history read-through.
actor MessageCacheService {
    static let shared = MessageCacheService()
    static let pipelineCacheSchemaVersion = 5

    enum MessageLoadSource: String, Sendable, Codable {
        case memory
        case sqlite
        case empty
    }

    private var memoryCache: [Int64: CachedChatMessages] = [:]
    private var pipelineCache: [Int64: CachedPipelineCategory] = [:]

    // MARK: - Codable Models

    struct CachedPipelineCategory: Codable {
        let chatId: Int64
        let category: String          // "on_me", "on_them", "quiet"
        let suggestedAction: String
        let lastMessageId: Int64      // staleness key: compared against chat.lastMessage.id
        let analyzedAt: Date
        let schemaVersion: Int
    }

    struct CachedChatMessages: Codable {
        let chatId: Int64
        var messages: [CachedMessage]
        var oldestMessageId: Int64?
    }

    struct CachedMessage: Codable, Equatable {
        let id: Int64
        let chatId: Int64
        let senderUserId: Int64?
        let senderName: String?
        let date: Date
        let textContent: String?
        let mediaTypeRaw: String?
        let isOutgoing: Bool

        static func == (lhs: CachedMessage, rhs: CachedMessage) -> Bool {
            lhs.id == rhs.id
        }
    }

    // MARK: - Read

    func getMessages(chatId: Int64) async -> [TGMessage]? {
        if let cached = memoryCache[chatId], !cached.messages.isEmpty {
            return cached.messages.map { $0.toTGMessage() }
        }

        guard let cached = await loadCachedEntry(chatId: chatId), !cached.messages.isEmpty else {
            return nil
        }
        return cached.messages.map { $0.toTGMessage() }
    }

    func getMessagesWithSource(chatId: Int64) async -> (messages: [TGMessage], source: MessageLoadSource) {
        if let cached = memoryCache[chatId], !cached.messages.isEmpty {
            return (cached.messages.map { $0.toTGMessage() }, .memory)
        }

        let records = await DatabaseManager.shared.loadMessages(
            chatId: chatId,
            limit: AppConstants.Cache.maxCachedMessagesPerChat
        )
        guard !records.isEmpty else {
            return ([], .empty)
        }

        let cached = CachedChatMessages(
            chatId: chatId,
            messages: records.map { CachedMessage.from($0) },
            oldestMessageId: records.last?.id
        )
        memoryCache[chatId] = cached
        return (cached.messages.map { $0.toTGMessage() }, .sqlite)
    }

    func getOldestMessageId(chatId: Int64) async -> Int64? {
        let cached = await loadCachedEntry(chatId: chatId)
        return cached?.oldestMessageId
    }

    func messageCount(chatId: Int64) async -> Int {
        let cached = await loadCachedEntry(chatId: chatId)
        return cached?.messages.count ?? 0
    }

    // MARK: - Write

    func cacheMessages(chatId: Int64, messages: [TGMessage], append: Bool = false) async {
        let newCachedMessages = messages.map { CachedMessage.from($0) }

        var allMessages: [CachedMessage]
        if append, let existing = await loadCachedEntry(chatId: chatId) {
            var byId: [Int64: CachedMessage] = [:]
            for message in existing.messages {
                byId[message.id] = message
            }
            for message in newCachedMessages {
                byId[message.id] = message
            }
            allMessages = Array(byId.values).sorted(by: Self.sortMessagesDescending)
        } else {
            allMessages = newCachedMessages.sorted(by: Self.sortMessagesDescending)
        }

        let maxMessages = AppConstants.Cache.maxCachedMessagesPerChat
        if allMessages.count > maxMessages {
            allMessages = Array(allMessages.prefix(maxMessages))
        }

        let entry = CachedChatMessages(
            chatId: chatId,
            messages: allMessages,
            oldestMessageId: allMessages.last?.id
        )
        memoryCache[chatId] = entry

        let recordsToPersist = append ? newCachedMessages : entry.messages
        await DatabaseManager.shared.upsertLiveMessages(
            chatId: chatId,
            messages: recordsToPersist.map { $0.toDatabaseRecord() },
            updateRecentSyncState: !append
        )
    }

    /// Append a single message from a real-time update.
    func appendMessage(chatId: Int64, message: TGMessage) async {
        let cachedMessage = CachedMessage.from(message)

        if var existing = await loadCachedEntry(chatId: chatId) {
            existing.messages.removeAll { $0.id == cachedMessage.id }
            existing.messages.insert(cachedMessage, at: 0)

            let maxMessages = AppConstants.Cache.maxCachedMessagesPerChat
            if existing.messages.count > maxMessages {
                existing.messages = Array(existing.messages.prefix(maxMessages))
            }
            existing.oldestMessageId = existing.messages.last?.id
            memoryCache[chatId] = existing
        } else {
            memoryCache[chatId] = CachedChatMessages(
                chatId: chatId,
                messages: [cachedMessage],
                oldestMessageId: cachedMessage.id
            )
        }

        await DatabaseManager.shared.upsertLiveMessages(
            chatId: chatId,
            messages: [cachedMessage.toDatabaseRecord()]
        )
    }

    /// Applies a TDLib content-edit event to an already cached message.
    /// No-op if the chat/message isn't currently cached in memory or SQLite.
    func updateMessageContent(
        chatId: Int64,
        messageId: Int64,
        textContent: String?,
        mediaType: TGMessage.MediaType?
    ) async {
        if var existing = await loadCachedEntry(chatId: chatId),
           let index = existing.messages.firstIndex(where: { $0.id == messageId }) {
            let old = existing.messages[index]
            existing.messages[index] = CachedMessage(
                id: old.id,
                chatId: old.chatId,
                senderUserId: old.senderUserId,
                senderName: old.senderName,
                date: old.date,
                textContent: textContent,
                mediaTypeRaw: mediaType?.rawValue,
                isOutgoing: old.isOutgoing
            )
            memoryCache[chatId] = existing
        }

        await DatabaseManager.shared.updateMessageContent(
            chatId: chatId,
            messageId: messageId,
            textContent: textContent,
            mediaTypeRaw: mediaType?.rawValue
        )
    }

    /// Removes deleted messages from local cache.
    /// No-op if the chat isn't currently cached in memory or SQLite.
    func deleteMessages(chatId: Int64, messageIds: [Int64]) async {
        guard !messageIds.isEmpty else { return }
        let toDelete = Set(messageIds)
        if var existing = await loadCachedEntry(chatId: chatId) {
            existing.messages.removeAll { toDelete.contains($0.id) }

            if existing.messages.isEmpty {
                memoryCache.removeValue(forKey: chatId)
            } else {
                existing.oldestMessageId = existing.messages.last?.id
                memoryCache[chatId] = existing
            }
        }

        await DatabaseManager.shared.deleteMessages(chatId: chatId, messageIds: messageIds)

        if memoryCache[chatId] == nil {
            await reloadMemoryCacheFromDisk(chatId: chatId)
        }
    }

    // MARK: - Pipeline Category Cache

    func getPipelineCategory(chatId: Int64) async -> CachedPipelineCategory? {
        if let cached = pipelineCache[chatId] {
            return cached
        }

        guard let record = await DatabaseManager.shared.loadPipelineCache(chatId: chatId) else {
            return nil
        }

        let cached = CachedPipelineCategory(
            chatId: record.chatId,
            category: record.category,
            suggestedAction: record.suggestedAction,
            lastMessageId: record.lastMessageId,
            analyzedAt: record.analyzedAt,
            schemaVersion: record.schemaVersion
        )
        guard cached.schemaVersion == Self.pipelineCacheSchemaVersion else {
            await invalidatePipelineCategory(chatId: chatId)
            return nil
        }
        pipelineCache[chatId] = cached
        return cached
    }

    func cachePipelineCategory(
        chatId: Int64,
        category: String,
        suggestedAction: String,
        lastMessageId: Int64
    ) async {
        let cached = CachedPipelineCategory(
            chatId: chatId,
            category: category,
            suggestedAction: suggestedAction,
            lastMessageId: lastMessageId,
            analyzedAt: Date(),
            schemaVersion: Self.pipelineCacheSchemaVersion
        )
        pipelineCache[chatId] = cached

        await DatabaseManager.shared.savePipelineCache(
            DatabaseManager.PipelineCacheRecord(
                chatId: cached.chatId,
                category: cached.category,
                suggestedAction: cached.suggestedAction,
                lastMessageId: cached.lastMessageId,
                analyzedAt: cached.analyzedAt,
                schemaVersion: cached.schemaVersion
            )
        )
    }

    func invalidatePipelineCategory(chatId: Int64) async {
        pipelineCache.removeValue(forKey: chatId)
        await DatabaseManager.shared.deletePipelineCache(chatId: chatId)
    }

    func invalidateAllPipelineCache() async {
        pipelineCache.removeAll()
        await DatabaseManager.shared.clearPipelineCache()
    }

    func invalidateAllLocalData() async {
        memoryCache.removeAll()
        pipelineCache.removeAll()
        await DatabaseManager.shared.clearAllMessageAndPipelineData()
    }

    // MARK: - Invalidation

    func invalidate(chatId: Int64) async {
        memoryCache.removeValue(forKey: chatId)
    }

    func invalidateAll() async {
        memoryCache.removeAll()
    }

    // MARK: - Flush

    /// SQLite writes are immediate; compatibility no-op kept so older callsites remain safe.
    func flushToDisk() async {}

    // MARK: - Persistence Helpers

    private func loadCachedEntry(chatId: Int64) async -> CachedChatMessages? {
        if let cached = memoryCache[chatId] {
            return cached
        }

        let records = await DatabaseManager.shared.loadMessages(
            chatId: chatId,
            limit: AppConstants.Cache.maxCachedMessagesPerChat
        )
        guard !records.isEmpty else { return nil }

        let cached = CachedChatMessages(
            chatId: chatId,
            messages: records.map { CachedMessage.from($0) },
            oldestMessageId: records.last?.id
        )
        memoryCache[chatId] = cached
        return cached
    }

    private func reloadMemoryCacheFromDisk(chatId: Int64) async {
        let records = await DatabaseManager.shared.loadMessages(
            chatId: chatId,
            limit: AppConstants.Cache.maxCachedMessagesPerChat
        )

        guard !records.isEmpty else {
            memoryCache.removeValue(forKey: chatId)
            return
        }

        memoryCache[chatId] = CachedChatMessages(
            chatId: chatId,
            messages: records.map { CachedMessage.from($0) },
            oldestMessageId: records.last?.id
        )
    }

    private static func sortMessagesDescending(lhs: CachedMessage, rhs: CachedMessage) -> Bool {
        if lhs.date != rhs.date {
            return lhs.date > rhs.date
        }
        return lhs.id > rhs.id
    }
}

// MARK: - CachedMessage ↔ TGMessage / DB conversion

extension MessageCacheService.CachedMessage {
    static func from(_ msg: TGMessage) -> Self {
        let senderUserId: Int64?
        if case .user(let userId) = msg.senderId {
            senderUserId = userId
        } else {
            senderUserId = nil
        }

        return Self(
            id: msg.id,
            chatId: msg.chatId,
            senderUserId: senderUserId,
            senderName: msg.senderName,
            date: msg.date,
            textContent: msg.textContent,
            mediaTypeRaw: msg.mediaType?.rawValue,
            isOutgoing: msg.isOutgoing
        )
    }

    static func from(_ record: DatabaseManager.MessageRecord) -> Self {
        Self(
            id: record.id,
            chatId: record.chatId,
            senderUserId: record.senderUserId,
            senderName: record.senderName,
            date: record.date,
            textContent: record.textContent,
            mediaTypeRaw: record.mediaTypeRaw,
            isOutgoing: record.isOutgoing
        )
    }

    func toTGMessage() -> TGMessage {
        let senderId: TGMessage.MessageSenderId
        if let userId = senderUserId {
            senderId = .user(userId)
        } else {
            senderId = .chat(chatId)
        }

        return TGMessage(
            id: id,
            chatId: chatId,
            senderId: senderId,
            date: date,
            textContent: textContent,
            mediaType: mediaTypeRaw.flatMap { TGMessage.MediaType(rawValue: $0) },
            isOutgoing: isOutgoing,
            chatTitle: nil,
            senderName: senderName
        )
    }

    func toDatabaseRecord() -> DatabaseManager.MessageRecord {
        DatabaseManager.MessageRecord(
            id: id,
            chatId: chatId,
            senderUserId: senderUserId,
            senderName: senderName,
            date: date,
            textContent: textContent,
            mediaTypeRaw: mediaTypeRaw,
            isOutgoing: isOutgoing
        )
    }
}
