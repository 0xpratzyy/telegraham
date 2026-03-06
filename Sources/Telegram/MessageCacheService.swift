import Foundation

/// Event-driven message cache. Kept fresh via TDLib real-time updates — no TTL/expiry.
/// Two-tier: in-memory dictionary + disk JSON files.
actor MessageCacheService {
    static let shared = MessageCacheService()

    private let cacheDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("TGSearch", isDirectory: true)
            .appendingPathComponent("message_cache", isDirectory: true)
    }()

    private var memoryCache: [Int64: CachedChatMessages] = [:]
    private var dirtyChats: Set<Int64> = []  // Chats with unsaved changes

    // Pipeline category cache (AI results)
    private let pipelineCacheDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("TGSearch", isDirectory: true)
            .appendingPathComponent("pipeline_cache", isDirectory: true)
    }()
    private var pipelineCache: [Int64: CachedPipelineCategory] = [:]

    // MARK: - Codable Models

    struct CachedPipelineCategory: Codable {
        let chatId: Int64
        let category: String          // "on_me", "on_them", "quiet"
        let suggestedAction: String
        let lastMessageId: Int64      // staleness key: compared against chat.lastMessage.id
        let analyzedAt: Date
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

        static func == (lhs: CachedMessage, rhs: CachedMessage) -> Bool {
            lhs.id == rhs.id
        }
    }

    // MARK: - Read

    func getMessages(chatId: Int64) -> [TGMessage]? {
        if let cached = memoryCache[chatId], !cached.messages.isEmpty {
            return cached.messages.map { $0.toTGMessage() }
        }
        if let diskCached = loadFromDisk(chatId: chatId), !diskCached.messages.isEmpty {
            memoryCache[chatId] = diskCached
            return diskCached.messages.map { $0.toTGMessage() }
        }
        return nil
    }

    func getOldestMessageId(chatId: Int64) -> Int64? {
        memoryCache[chatId]?.oldestMessageId
    }

    func messageCount(chatId: Int64) -> Int {
        memoryCache[chatId]?.messages.count ?? 0
    }

    // MARK: - Write

    func cacheMessages(chatId: Int64, messages: [TGMessage], append: Bool = false) {
        let newCached = messages.map { CachedMessage.from($0) }

        var allMessages: [CachedMessage]
        if append, let existing = memoryCache[chatId] {
            var byId: [Int64: CachedMessage] = [:]
            for m in existing.messages { byId[m.id] = m }
            for m in newCached { byId[m.id] = m }
            allMessages = Array(byId.values).sorted { $0.date > $1.date }
        } else {
            allMessages = newCached.sorted { $0.date > $1.date }
        }

        // Cap at max messages per chat
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
        saveToDisk(entry)  // write-through: persist batch writes immediately
    }

    /// Append a single message from a real-time update. Does not write to disk immediately.
    func appendMessage(chatId: Int64, message: TGMessage) {
        let cached = CachedMessage.from(message)

        if var existing = memoryCache[chatId] {
            // Remove old version if exists (message edit), then prepend (newest first)
            existing.messages.removeAll { $0.id == cached.id }
            existing.messages.insert(cached, at: 0)

            let maxMessages = AppConstants.Cache.maxCachedMessagesPerChat
            if existing.messages.count > maxMessages {
                existing.messages = Array(existing.messages.prefix(maxMessages))
            }
            existing.oldestMessageId = existing.messages.last?.id
            memoryCache[chatId] = existing
        } else {
            memoryCache[chatId] = CachedChatMessages(
                chatId: chatId,
                messages: [cached],
                oldestMessageId: cached.id
            )
        }
        dirtyChats.insert(chatId)
    }

    // MARK: - Pipeline Category Cache

    func getPipelineCategory(chatId: Int64) -> CachedPipelineCategory? {
        if let cached = pipelineCache[chatId] {
            return cached
        }
        if let diskCached = loadPipelineFromDisk(chatId: chatId) {
            pipelineCache[chatId] = diskCached
            return diskCached
        }
        return nil
    }

    func cachePipelineCategory(
        chatId: Int64,
        category: String,
        suggestedAction: String,
        lastMessageId: Int64
    ) {
        let cached = CachedPipelineCategory(
            chatId: chatId,
            category: category,
            suggestedAction: suggestedAction,
            lastMessageId: lastMessageId,
            analyzedAt: Date()
        )
        pipelineCache[chatId] = cached
        savePipelineToDisk(cached)  // write-through: persist immediately
    }

    func invalidatePipelineCategory(chatId: Int64) {
        pipelineCache.removeValue(forKey: chatId)
        deletePipelineFromDisk(chatId: chatId)
    }

    func invalidateAllPipelineCache() {
        pipelineCache.removeAll()
        try? FileManager.default.removeItem(at: pipelineCacheDir)
    }

    // MARK: - Invalidation

    func invalidate(chatId: Int64) {
        memoryCache.removeValue(forKey: chatId)
        dirtyChats.remove(chatId)
        deleteFromDisk(chatId: chatId)
    }

    func invalidateAll() {
        memoryCache.removeAll()
        dirtyChats.removeAll()
        try? FileManager.default.removeItem(at: cacheDir)
    }

    // MARK: - Flush (call on app quit or periodically)

    func flushToDisk() {
        // Flush incremental message updates (from appendMessage real-time path)
        for chatId in dirtyChats {
            if let cached = memoryCache[chatId] {
                saveToDisk(cached)
            }
        }
        dirtyChats.removeAll()
        // Pipeline categories are write-through (saved immediately on write), no flush needed.
    }

    // MARK: - Disk I/O

    private func saveToDisk(_ cached: CachedChatMessages) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent("\(cached.chatId).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(cached) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func loadFromDisk(chatId: Int64) -> CachedChatMessages? {
        let url = cacheDir.appendingPathComponent("\(chatId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(CachedChatMessages.self, from: data)
    }

    private func deleteFromDisk(chatId: Int64) {
        let url = cacheDir.appendingPathComponent("\(chatId).json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Pipeline Disk I/O

    private func savePipelineToDisk(_ cached: CachedPipelineCategory) {
        try? FileManager.default.createDirectory(at: pipelineCacheDir, withIntermediateDirectories: true)
        let url = pipelineCacheDir.appendingPathComponent("\(cached.chatId).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(cached) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func loadPipelineFromDisk(chatId: Int64) -> CachedPipelineCategory? {
        let url = pipelineCacheDir.appendingPathComponent("\(chatId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(CachedPipelineCategory.self, from: data)
    }

    private func deletePipelineFromDisk(chatId: Int64) {
        let url = pipelineCacheDir.appendingPathComponent("\(chatId).json")
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - CachedMessage ↔ TGMessage conversion

extension MessageCacheService.CachedMessage {
    static func from(_ msg: TGMessage) -> Self {
        let senderUserId: Int64?
        if case .user(let uid) = msg.senderId { senderUserId = uid } else { senderUserId = nil }
        return Self(
            id: msg.id,
            chatId: msg.chatId,
            senderUserId: senderUserId,
            senderName: msg.senderName,
            date: msg.date,
            textContent: msg.textContent,
            mediaTypeRaw: msg.mediaType?.rawValue
        )
    }

    func toTGMessage() -> TGMessage {
        let senderId: TGMessage.MessageSenderId
        if let uid = senderUserId {
            senderId = .user(uid)
        } else {
            senderId = .chat(chatId)
        }
        let mediaType = mediaTypeRaw.flatMap { TGMessage.MediaType(rawValue: $0) }
        return TGMessage(
            id: id,
            chatId: chatId,
            senderId: senderId,
            date: date,
            textContent: textContent,
            mediaType: mediaType,
            chatTitle: nil,
            senderName: senderName
        )
    }
}
