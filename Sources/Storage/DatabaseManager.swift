import Foundation
import GRDB

enum DatabaseManagerError: Error {
    case unavailable
}

actor DatabaseManager {
    static let shared = DatabaseManager()

    struct MessageRecord: Sendable, Equatable {
        let id: Int64
        let chatId: Int64
        let senderUserId: Int64?
        let senderName: String?
        let date: Date
        let textContent: String?
        let mediaTypeRaw: String?
        let isOutgoing: Bool
    }

    struct ScoredMessageRecord: Sendable, Equatable {
        let message: MessageRecord
        let score: Double
    }

    struct MessageLookupKey: Sendable, Hashable {
        let messageId: Int64
        let chatId: Int64
    }

    struct PipelineCacheRecord: Sendable, Equatable {
        let chatId: Int64
        let category: String
        let suggestedAction: String
        let lastMessageId: Int64
        let analyzedAt: Date
    }

    struct SyncStateRecord: Sendable, Equatable {
        let chatId: Int64
        let lastIndexedMessageId: Int64
        let lastIndexedAt: Date?
        let totalMessagesIndexed: Int
        let isSearchReady: Bool
    }

    struct RecentSyncStateRecord: Sendable, Equatable {
        let chatId: Int64
        let latestSyncedMessageId: Int64
        let lastRecentSyncAt: Date?
    }

    private struct LegacyCachedChatMessages: Decodable {
        let chatId: Int64
        let messages: [LegacyCachedMessage]
        let oldestMessageId: Int64?
    }

    private struct LegacyCachedMessage: Decodable {
        let id: Int64
        let chatId: Int64
        let senderUserId: Int64?
        let senderName: String?
        let date: Date
        let textContent: String?
        let mediaTypeRaw: String?
        let isOutgoing: Bool?
    }

    private struct LegacyPipelineCacheRecord: Decodable {
        let chatId: Int64
        let category: String
        let suggestedAction: String
        let lastMessageId: Int64
        let analyzedAt: Date
    }

    private let fileManager = FileManager.default
    private var databasePool: DatabasePool?
    private var hasInitialized = false
    private var databaseURLOverride: URL?

    private var appSupportDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(AppConstants.Storage.appSupportFolderName, isDirectory: true)
    }

    private var databaseURL: URL {
        databaseURLOverride ?? appSupportDirectory.appendingPathComponent(
            AppConstants.Storage.databaseFileName,
            isDirectory: false
        )
    }

    private var legacyMessageCacheDirectory: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.Storage.messageCacheDirectoryName, isDirectory: true)
    }

    private var legacyPipelineCacheDirectory: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.Storage.pipelineCacheDirectoryName, isDirectory: true)
    }

    func initialize() async {
        guard !hasInitialized else { return }

        do {
            try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }

            let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
            try PidgyMigrations.makeMigrator().migrate(pool)
            databasePool = pool
            hasInitialized = true

            try await importLegacyCachesIfNeeded(using: pool)
        } catch {
            print("[DatabaseManager] Failed to initialize database: \(error)")
        }
    }

    func close() async {
        databasePool = nil
        hasInitialized = false
    }

    func configureForTesting(databaseURLOverride: URL?) async {
        databasePool = nil
        hasInitialized = false
        self.databaseURLOverride = databaseURLOverride
    }

    func upsertLiveMessages(chatId: Int64, messages: [MessageRecord]) async {
        guard !messages.isEmpty else { return }
        guard let pool = await ensureDatabase() else { return }
        let latestMessageId = messages
            .sorted(by: Self.sortMessagesDescending)
            .first?
            .id ?? 0

        do {
            try await pool.write { db in
                try Self.insertMessages(messages, into: db)
                try Self.refreshRecentSyncState(
                    in: db,
                    chatId: chatId,
                    preferredLatestMessageId: latestMessageId,
                    syncedAt: Date()
                )
            }
        } catch {
            print("[DatabaseManager] Failed to upsert live messages for chat \(chatId): \(error)")
        }
    }

    func loadMessages(chatId: Int64, limit: Int) async -> [MessageRecord] {
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing
                        FROM messages
                        WHERE chat_id = ?
                        ORDER BY date DESC, id DESC
                        LIMIT ?
                        """,
                    arguments: [chatId, limit]
                )
                return rows.map(Self.messageRecord(from:))
            }
        } catch {
            print("[DatabaseManager] Failed to load messages for chat \(chatId): \(error)")
            return []
        }
    }

    func loadMessages(
        chatId: Int64,
        startDate: Date?,
        endDate: Date?,
        limit: Int
    ) async -> [MessageRecord] {
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing
                        FROM messages
                        WHERE chat_id = ?
                          AND (? IS NULL OR date >= ?)
                          AND (? IS NULL OR date <= ?)
                        ORDER BY date DESC, id DESC
                        LIMIT ?
                        """,
                    arguments: [
                        chatId,
                        startDate?.timeIntervalSince1970,
                        startDate?.timeIntervalSince1970,
                        endDate?.timeIntervalSince1970,
                        endDate?.timeIntervalSince1970,
                        limit
                    ]
                )
                return rows.map(Self.messageRecord(from:))
            }
        } catch {
            print("[DatabaseManager] Failed to load ranged messages for chat \(chatId): \(error)")
            return []
        }
    }

    func loadMessagesMatchingSenderTerms(
        chatIds: [Int64]? = nil,
        senderTerms: [String],
        startDate: Date?,
        endDate: Date?,
        limit: Int
    ) async -> [MessageRecord] {
        let normalizedTerms = senderTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalizedTerms.isEmpty, limit > 0 else { return [] }
        if let chatIds, chatIds.isEmpty { return [] }
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                let senderClauses = Array(repeating: "lower(coalesce(sender_name, '')) LIKE ?", count: normalizedTerms.count)
                    .joined(separator: " OR ")
                var arguments = StatementArguments()
                for term in normalizedTerms {
                    arguments += ["%\(term)%"]
                }
                arguments += [startDate?.timeIntervalSince1970]
                arguments += [startDate?.timeIntervalSince1970]
                arguments += [endDate?.timeIntervalSince1970]
                arguments += [endDate?.timeIntervalSince1970]

                let rows: [Row]
                if let chatIds {
                    let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
                    for chatId in chatIds {
                        arguments += [chatId]
                    }
                    arguments += [limit]
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing
                            FROM messages
                            WHERE (\(senderClauses))
                              AND (? IS NULL OR date >= ?)
                              AND (? IS NULL OR date <= ?)
                              AND chat_id IN (\(placeholders))
                            ORDER BY date DESC, id DESC
                            LIMIT ?
                            """,
                        arguments: arguments
                    )
                } else {
                    arguments += [limit]
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing
                            FROM messages
                            WHERE (\(senderClauses))
                              AND (? IS NULL OR date >= ?)
                              AND (? IS NULL OR date <= ?)
                            ORDER BY date DESC, id DESC
                            LIMIT ?
                            """,
                        arguments: arguments
                    )
                }

                return rows.map(Self.messageRecord(from:))
            }
        } catch {
            print("[DatabaseManager] Failed to load sender-matched messages: \(error)")
            return []
        }
    }

    func updateMessageContent(
        chatId: Int64,
        messageId: Int64,
        textContent: String?,
        mediaTypeRaw: String?
    ) async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                        UPDATE messages
                        SET text_content = ?, media_type = ?
                        WHERE chat_id = ? AND id = ?
                        """,
                    arguments: [textContent, mediaTypeRaw, chatId, messageId]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to update message \(messageId) in chat \(chatId): \(error)")
        }
    }

    func deleteMessages(chatId: Int64, messageIds: [Int64]) async {
        guard !messageIds.isEmpty else { return }
        guard let pool = await ensureDatabase() else { return }

        let placeholders = Array(repeating: "?", count: messageIds.count).joined(separator: ", ")
        var statementArguments = StatementArguments()
        statementArguments += [chatId]
        for messageId in messageIds {
            statementArguments += [messageId]
        }
        let deleteArguments = statementArguments

        do {
            try await pool.write { db in
                let existingState = try Self.syncStateRecord(in: db, chatId: chatId)
                let existingRecentSyncState = try Self.recentSyncStateRecord(in: db, chatId: chatId)
                try Self.deleteEmbeddings(in: db, chatId: chatId, messageIds: messageIds)
                try db.execute(
                    sql: "DELETE FROM messages WHERE chat_id = ? AND id IN (\(placeholders))",
                    arguments: deleteArguments
                )
                if let existingState {
                    try Self.refreshSyncState(
                        in: db,
                        chatId: chatId,
                        preferredOldestMessageId: existingState.lastIndexedMessageId,
                        isSearchReady: existingState.isSearchReady
                    )
                }
                try Self.refreshRecentSyncState(
                    in: db,
                    chatId: chatId,
                    syncedAt: existingRecentSyncState?.lastRecentSyncAt
                )
            }
        } catch {
            print("[DatabaseManager] Failed to delete messages for chat \(chatId): \(error)")
        }
    }

    func deleteMessages(for chatId: Int64) async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM embeddings WHERE chat_id = ?",
                    arguments: [chatId]
                )
                try db.execute(
                    sql: "DELETE FROM messages WHERE chat_id = ?",
                    arguments: [chatId]
                )
                try db.execute(
                    sql: "DELETE FROM sync_state WHERE chat_id = ?",
                    arguments: [chatId]
                )
                try db.execute(
                    sql: "DELETE FROM recent_sync_state WHERE chat_id = ?",
                    arguments: [chatId]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to delete cached messages for chat \(chatId): \(error)")
        }
    }

    func loadRecentSyncState(chatId: Int64) async -> RecentSyncStateRecord? {
        guard let pool = await ensureDatabase() else { return nil }

        do {
            return try await pool.read { db in
                try Self.recentSyncStateRecord(in: db, chatId: chatId)
            }
        } catch {
            print("[DatabaseManager] Failed to load recent sync state for chat \(chatId): \(error)")
            return nil
        }
    }

    func loadRecentSyncStates(in chatIds: [Int64]) async -> [Int64: RecentSyncStateRecord] {
        guard !chatIds.isEmpty else { return [:] }
        guard let pool = await ensureDatabase() else { return [:] }

        do {
            return try await pool.read { db in
                let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
                var arguments = StatementArguments()
                for chatId in chatIds {
                    arguments += [chatId]
                }

                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT chat_id, latest_synced_message_id, last_recent_sync_at
                        FROM recent_sync_state
                        WHERE chat_id IN (\(placeholders))
                        """,
                    arguments: arguments
                )

                return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                    let syncedAtSeconds: Double? = row["last_recent_sync_at"]
                    let record = RecentSyncStateRecord(
                        chatId: row["chat_id"],
                        latestSyncedMessageId: row["latest_synced_message_id"],
                        lastRecentSyncAt: syncedAtSeconds.map(Date.init(timeIntervalSince1970:))
                    )
                    return (record.chatId, record)
                })
            }
        } catch {
            print("[DatabaseManager] Failed to load recent sync states: \(error)")
            return [:]
        }
    }

    func saveRecentSyncState(
        chatId: Int64,
        latestSyncedMessageId: Int64,
        syncedAt: Date
    ) async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try Self.saveRecentSyncState(
                    in: db,
                    chatId: chatId,
                    latestSyncedMessageId: latestSyncedMessageId,
                    syncedAt: syncedAt
                )
            }
        } catch {
            print("[DatabaseManager] Failed to save recent sync state for chat \(chatId): \(error)")
        }
    }

    func loadPipelineCache(chatId: Int64) async -> PipelineCacheRecord? {
        guard let pool = await ensureDatabase() else { return nil }

        do {
            return try await pool.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT chat_id, category, suggested_action, last_message_id, analyzed_at
                        FROM pipeline_cache
                        WHERE chat_id = ?
                        """,
                    arguments: [chatId]
                ) else {
                    return nil
                }

                let analyzedAt: Double = row["analyzed_at"]
                return PipelineCacheRecord(
                    chatId: row["chat_id"],
                    category: row["category"],
                    suggestedAction: row["suggested_action"],
                    lastMessageId: row["last_message_id"],
                    analyzedAt: Date(timeIntervalSince1970: analyzedAt)
                )
            }
        } catch {
            print("[DatabaseManager] Failed to load pipeline cache for chat \(chatId): \(error)")
            return nil
        }
    }

    func savePipelineCache(_ record: PipelineCacheRecord) async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO pipeline_cache (chat_id, category, suggested_action, last_message_id, analyzed_at)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(chat_id) DO UPDATE SET
                            category = excluded.category,
                            suggested_action = excluded.suggested_action,
                            last_message_id = excluded.last_message_id,
                            analyzed_at = excluded.analyzed_at
                        """,
                    arguments: [
                        record.chatId,
                        record.category,
                        record.suggestedAction,
                        record.lastMessageId,
                        record.analyzedAt.timeIntervalSince1970
                    ]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to save pipeline cache for chat \(record.chatId): \(error)")
        }
    }

    func deletePipelineCache(chatId: Int64) async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM pipeline_cache WHERE chat_id = ?",
                    arguments: [chatId]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to delete pipeline cache for chat \(chatId): \(error)")
        }
    }

    func clearPipelineCache() async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try db.execute(sql: "DELETE FROM pipeline_cache")
            }
            removeLegacyPipelineCacheDirectory()
        } catch {
            print("[DatabaseManager] Failed to clear pipeline cache: \(error)")
        }
    }

    func clearMessageCache() async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try db.execute(sql: "DELETE FROM embeddings")
                try db.execute(sql: "DELETE FROM messages")
                try db.execute(sql: "DELETE FROM sync_state WHERE chat_id >= 0")
                try db.execute(sql: "DELETE FROM recent_sync_state WHERE chat_id >= 0")
            }
            removeLegacyMessageCacheDirectory()
        } catch {
            print("[DatabaseManager] Failed to clear message cache: \(error)")
        }
    }

    func clearAllMessageAndPipelineData() async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try db.execute(sql: "DELETE FROM embeddings")
                try db.execute(sql: "DELETE FROM messages")
                try db.execute(sql: "DELETE FROM pipeline_cache")
                try db.execute(sql: "DELETE FROM sync_state")
                try db.execute(sql: "DELETE FROM recent_sync_state")
            }
            removeLegacyMessageCacheDirectory()
            removeLegacyPipelineCacheDirectory()
        } catch {
            print("[DatabaseManager] Failed to clear cache tables: \(error)")
        }
    }

    func localSearch(query: String, chatIds: [Int64]? = nil, limit: Int = 50) async -> [MessageRecord] {
        let scored = await localSearchScored(query: query, chatIds: chatIds, limit: limit)
        return scored.map(\.message)
    }

    func localSearchScored(query: String, chatIds: [Int64]? = nil, limit: Int = 50) async -> [ScoredMessageRecord] {
        let ftsQuery = Self.normalizedFTSQuery(from: query)
        guard !ftsQuery.isEmpty else { return [] }
        if let chatIds, chatIds.isEmpty { return [] }
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                let rows: [Row]
                if let chatIds {
                    let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
                    var arguments = StatementArguments()
                    arguments += [ftsQuery]
                    for chatId in chatIds {
                        arguments += [chatId]
                    }
                    arguments += [limit]

                    rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT m.id, m.chat_id, m.sender_user_id, m.sender_name, m.date, m.text_content, m.media_type, m.is_outgoing,
                                   (-bm25(messages_fts)) AS semantic_score
                            FROM messages_fts
                            JOIN messages AS m ON m.rowid = messages_fts.rowid
                            WHERE messages_fts MATCH ?
                              AND m.chat_id IN (\(placeholders))
                            ORDER BY semantic_score DESC, m.date DESC, m.id DESC
                            LIMIT ?
                            """,
                        arguments: arguments
                    )
                } else {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT m.id, m.chat_id, m.sender_user_id, m.sender_name, m.date, m.text_content, m.media_type, m.is_outgoing,
                                   (-bm25(messages_fts)) AS semantic_score
                            FROM messages_fts
                            JOIN messages AS m ON m.rowid = messages_fts.rowid
                            WHERE messages_fts MATCH ?
                            ORDER BY semantic_score DESC, m.date DESC, m.id DESC
                            LIMIT ?
                            """,
                        arguments: [ftsQuery, limit]
                    )
                }

                return rows.map { row in
                    let rawScore: Double = row["semantic_score"] ?? 0
                    return ScoredMessageRecord(
                        message: Self.messageRecord(from: row),
                        score: max(0, rawScore)
                    )
                }
            }
        } catch {
            print("[DatabaseManager] Local FTS search failed for query '\(query)': \(error)")
            return []
        }
    }

    func loadSearchableMessages(chatIds: [Int64]? = nil, limit: Int = 10_000) async -> [MessageRecord] {
        guard limit > 0 else { return [] }
        if let chatIds, chatIds.isEmpty { return [] }
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                let rows: [Row]
                if let chatIds {
                    let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
                    var arguments = StatementArguments()
                    for chatId in chatIds {
                        arguments += [chatId]
                    }
                    arguments += [limit]

                    rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing
                            FROM messages
                            WHERE text_content IS NOT NULL
                              AND length(trim(text_content)) > 0
                              AND chat_id IN (\(placeholders))
                            ORDER BY date DESC, id DESC
                            LIMIT ?
                            """,
                        arguments: arguments
                    )
                } else {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing
                            FROM messages
                            WHERE text_content IS NOT NULL
                              AND length(trim(text_content)) > 0
                            ORDER BY date DESC, id DESC
                            LIMIT ?
                            """,
                        arguments: [limit]
                    )
                }

                return rows.map(Self.messageRecord(from:))
            }
        } catch {
            print("[DatabaseManager] Failed to load searchable messages: \(error)")
            return []
        }
    }

    func loadMessages(keys: [MessageLookupKey]) async -> [MessageRecord] {
        guard !keys.isEmpty else { return [] }
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                var records: [MessageRecord] = []
                records.reserveCapacity(keys.count)

                for key in keys {
                    guard let row = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing
                            FROM messages
                            WHERE id = ? AND chat_id = ?
                            LIMIT 1
                            """,
                        arguments: [key.messageId, key.chatId]
                    ) else {
                        continue
                    }
                    records.append(Self.messageRecord(from: row))
                }

                return records
            }
        } catch {
            print("[DatabaseManager] Failed to load messages by key: \(error)")
            return []
        }
    }

    func messagesMissingEmbeddings(limit: Int) async -> [MessageRecord] {
        guard limit > 0 else { return [] }
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT m.id, m.chat_id, m.sender_user_id, m.sender_name, m.date, m.text_content, m.media_type, m.is_outgoing
                        FROM messages AS m
                        LEFT JOIN embeddings AS e
                          ON e.message_id = m.id
                         AND e.chat_id = m.chat_id
                        WHERE e.message_id IS NULL
                          AND m.text_content IS NOT NULL
                          AND length(trim(m.text_content)) >= ?
                        ORDER BY m.date DESC, m.id DESC
                        LIMIT ?
                        """,
                    arguments: [AppConstants.Indexing.minEmbeddingTextLength, limit]
                )

                return rows.map(Self.messageRecord(from:))
            }
        } catch {
            print("[DatabaseManager] Failed to load messages missing embeddings: \(error)")
            return []
        }
    }

    func loadSyncState(chatId: Int64) async -> SyncStateRecord? {
        guard let pool = await ensureDatabase() else { return nil }

        do {
            return try await pool.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT chat_id, last_indexed_message_id, last_indexed_at, total_messages_indexed, is_search_ready
                        FROM sync_state
                        WHERE chat_id = ?
                        """,
                    arguments: [chatId]
                ) else {
                    return nil
                }

                let lastIndexedAtSeconds: Double? = row["last_indexed_at"]
                let isSearchReadyValue: Int64 = row["is_search_ready"]
                return SyncStateRecord(
                    chatId: row["chat_id"],
                    lastIndexedMessageId: row["last_indexed_message_id"],
                    lastIndexedAt: lastIndexedAtSeconds.map(Date.init(timeIntervalSince1970:)),
                    totalMessagesIndexed: row["total_messages_indexed"],
                    isSearchReady: isSearchReadyValue != 0
                )
            }
        } catch {
            print("[DatabaseManager] Failed to load sync state for chat \(chatId): \(error)")
            return nil
        }
    }

    func searchReadyChatIds(in chatIds: [Int64]) async -> Set<Int64> {
        guard !chatIds.isEmpty else { return [] }
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
                var arguments = StatementArguments()
                for chatId in chatIds {
                    arguments += [chatId]
                }

                return try Set(
                    Int64.fetchAll(
                        db,
                        sql: """
                            SELECT chat_id
                            FROM sync_state
                            WHERE chat_id IN (\(placeholders))
                              AND is_search_ready = 1
                            """,
                        arguments: arguments
                    )
                )
            }
        } catch {
            print("[DatabaseManager] Failed to load search-ready chats: \(error)")
            return []
        }
    }

    func unindexedChatIds(in chatIds: [Int64]) async -> Set<Int64> {
        guard !chatIds.isEmpty else { return [] }
        let searchReadyIds = await searchReadyChatIds(in: chatIds)
        return Set(chatIds).subtracting(searchReadyIds)
    }

    func upsertIndexedMessages(
        chatId: Int64,
        messages: [MessageRecord],
        preferredOldestMessageId: Int64?,
        isSearchReady: Bool
    ) async {
        do {
            try await upsertIndexedMessagesThrowing(
                chatId: chatId,
                messages: messages,
                preferredOldestMessageId: preferredOldestMessageId,
                isSearchReady: isSearchReady
            )
        } catch {
            print("[DatabaseManager] Failed to upsert indexed messages for chat \(chatId): \(error)")
        }
    }

    func upsertIndexedMessagesThrowing(
        chatId: Int64,
        messages: [MessageRecord],
        preferredOldestMessageId: Int64?,
        isSearchReady: Bool
    ) async throws {
        guard let pool = await ensureDatabase() else {
            throw DatabaseManagerError.unavailable
        }

        try await pool.write { db in
            if !messages.isEmpty {
                try Self.insertMessages(messages, into: db)
            }

            let existingState = try Self.syncStateRecord(in: db, chatId: chatId)
            try Self.refreshSyncState(
                in: db,
                chatId: chatId,
                preferredOldestMessageId: preferredOldestMessageId ?? existingState?.lastIndexedMessageId,
                isSearchReady: isSearchReady || (existingState?.isSearchReady ?? false)
            )
        }
    }

    func markChatSearchReady(chatId: Int64, preferredOldestMessageId: Int64? = nil) async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                let existingState = try Self.syncStateRecord(in: db, chatId: chatId)
                let lastIndexedMessageId = preferredOldestMessageId
                    ?? existingState?.lastIndexedMessageId
                    ?? 0
                let totalMessagesIndexed = existingState?.totalMessagesIndexed ?? 0

                try db.execute(
                    sql: """
                        INSERT INTO sync_state (chat_id, last_indexed_message_id, last_indexed_at, total_messages_indexed, is_search_ready)
                        VALUES (?, ?, ?, ?, 1)
                        ON CONFLICT(chat_id) DO UPDATE SET
                            last_indexed_message_id = excluded.last_indexed_message_id,
                            last_indexed_at = excluded.last_indexed_at,
                            total_messages_indexed = MAX(sync_state.total_messages_indexed, excluded.total_messages_indexed),
                            is_search_ready = 1
                        """,
                    arguments: [
                        chatId,
                        lastIndexedMessageId,
                        Date().timeIntervalSince1970,
                        totalMessagesIndexed
                    ]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to mark chat \(chatId) search-ready: \(error)")
        }
    }

    func read<T: Sendable>(_ operation: @escaping @Sendable (Database) throws -> T) async throws -> T {
        guard let pool = await ensureDatabase() else {
            throw DatabaseManagerError.unavailable
        }

        return try await pool.read(operation)
    }

    func write<T: Sendable>(_ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        guard let pool = await ensureDatabase() else {
            throw DatabaseManagerError.unavailable
        }

        return try await pool.write(updates)
    }

    private func ensureDatabase() async -> DatabasePool? {
        if databasePool == nil {
            await initialize()
        }
        return databasePool
    }

    private func importLegacyCachesIfNeeded(using pool: DatabasePool) async throws {
        let hasLegacyMessageCache = fileManager.fileExists(atPath: legacyMessageCacheDirectory.path)
        let hasLegacyPipelineCache = fileManager.fileExists(atPath: legacyPipelineCacheDirectory.path)
        guard hasLegacyMessageCache || hasLegacyPipelineCache else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        if hasLegacyMessageCache {
            let messageFiles = try fileManager.contentsOfDirectory(
                at: legacyMessageCacheDirectory,
                includingPropertiesForKeys: nil
            )
            print("[DatabaseManager] Migrating \(messageFiles.count) legacy message cache files")

            try await pool.write { db in
                for fileURL in messageFiles where fileURL.pathExtension == "json" {
                    let data = try Data(contentsOf: fileURL)
                    let cached = try decoder.decode(LegacyCachedChatMessages.self, from: data)
                    let records = cached.messages.map { legacy in
                        MessageRecord(
                            id: legacy.id,
                            chatId: legacy.chatId,
                            senderUserId: legacy.senderUserId,
                            senderName: legacy.senderName,
                            date: legacy.date,
                            textContent: legacy.textContent,
                            mediaTypeRaw: legacy.mediaTypeRaw,
                            isOutgoing: legacy.isOutgoing ?? false
                        )
                    }

                    try db.execute(
                        sql: "DELETE FROM messages WHERE chat_id = ?",
                        arguments: [cached.chatId]
                    )
                    try Self.insertMessages(records, into: db)
                    try Self.refreshSyncState(
                        in: db,
                        chatId: cached.chatId,
                        preferredOldestMessageId: cached.oldestMessageId
                    )
                }
            }

            removeLegacyMessageCacheDirectory()
        }

        if hasLegacyPipelineCache {
            let pipelineFiles = try fileManager.contentsOfDirectory(
                at: legacyPipelineCacheDirectory,
                includingPropertiesForKeys: nil
            )
            print("[DatabaseManager] Migrating \(pipelineFiles.count) legacy pipeline cache files")

            try await pool.write { db in
                for fileURL in pipelineFiles where fileURL.pathExtension == "json" {
                    let data = try Data(contentsOf: fileURL)
                    let cached = try decoder.decode(LegacyPipelineCacheRecord.self, from: data)
                    try db.execute(
                        sql: """
                            INSERT INTO pipeline_cache (chat_id, category, suggested_action, last_message_id, analyzed_at)
                            VALUES (?, ?, ?, ?, ?)
                            ON CONFLICT(chat_id) DO UPDATE SET
                                category = excluded.category,
                                suggested_action = excluded.suggested_action,
                                last_message_id = excluded.last_message_id,
                                analyzed_at = excluded.analyzed_at
                            """,
                        arguments: [
                            cached.chatId,
                            cached.category,
                            cached.suggestedAction,
                            cached.lastMessageId,
                            cached.analyzedAt.timeIntervalSince1970
                        ]
                    )
                }
            }

            removeLegacyPipelineCacheDirectory()
        }
    }

    private static func insertMessages(_ records: [MessageRecord], into db: Database) throws {
        for record in records {
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO messages
                    (id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id,
                    record.chatId,
                    record.senderUserId,
                    record.senderName,
                    record.date.timeIntervalSince1970,
                    record.textContent,
                    record.mediaTypeRaw,
                    record.isOutgoing ? 1 : 0
                ]
            )
        }
    }

    private static func deleteEmbeddings(
        in db: Database,
        chatId: Int64,
        messageIds: [Int64]
    ) throws {
        guard !messageIds.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: messageIds.count).joined(separator: ", ")
        var arguments = StatementArguments()
        arguments += [chatId]
        for messageId in messageIds {
            arguments += [messageId]
        }

        try db.execute(
            sql: "DELETE FROM embeddings WHERE chat_id = ? AND message_id IN (\(placeholders))",
            arguments: arguments
        )
    }

    private static func refreshSyncState(
        in db: Database,
        chatId: Int64,
        preferredOldestMessageId: Int64? = nil,
        isSearchReady: Bool = false
    ) throws {
        let totalMessages = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM messages WHERE chat_id = ?",
            arguments: [chatId]
        ) ?? 0

        guard totalMessages > 0 else {
            try db.execute(
                sql: "DELETE FROM sync_state WHERE chat_id = ?",
                arguments: [chatId]
            )
            return
        }

        let oldestMessageId: Int64
        if let preferredOldestMessageId {
            oldestMessageId = preferredOldestMessageId
        } else {
            oldestMessageId = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM messages
                    WHERE chat_id = ?
                    ORDER BY date ASC, id ASC
                    LIMIT 1
                    """,
                arguments: [chatId]
            ) ?? 0
        }

        try db.execute(
            sql: """
                INSERT INTO sync_state (chat_id, last_indexed_message_id, last_indexed_at, total_messages_indexed, is_search_ready)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(chat_id) DO UPDATE SET
                    last_indexed_message_id = excluded.last_indexed_message_id,
                    last_indexed_at = excluded.last_indexed_at,
                    total_messages_indexed = excluded.total_messages_indexed,
                    is_search_ready = excluded.is_search_ready
                """,
            arguments: [
                chatId,
                oldestMessageId,
                Date().timeIntervalSince1970,
                totalMessages,
                isSearchReady ? 1 : 0
            ]
        )
    }

    private static func saveRecentSyncState(
        in db: Database,
        chatId: Int64,
        latestSyncedMessageId: Int64,
        syncedAt: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO recent_sync_state (chat_id, latest_synced_message_id, last_recent_sync_at)
                VALUES (?, ?, ?)
                ON CONFLICT(chat_id) DO UPDATE SET
                    latest_synced_message_id = excluded.latest_synced_message_id,
                    last_recent_sync_at = excluded.last_recent_sync_at
                """,
            arguments: [
                chatId,
                latestSyncedMessageId,
                syncedAt.timeIntervalSince1970
            ]
        )
    }

    private static func refreshRecentSyncState(
        in db: Database,
        chatId: Int64,
        preferredLatestMessageId: Int64? = nil,
        syncedAt: Date? = nil
    ) throws {
        let latestMessageId: Int64? = if let preferredLatestMessageId {
            preferredLatestMessageId
        } else {
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM messages
                    WHERE chat_id = ?
                    ORDER BY date DESC, id DESC
                    LIMIT 1
                    """,
                arguments: [chatId]
            )
        }

        guard let latestMessageId else {
            try db.execute(
                sql: "DELETE FROM recent_sync_state WHERE chat_id = ?",
                arguments: [chatId]
            )
            return
        }

        try saveRecentSyncState(
            in: db,
            chatId: chatId,
            latestSyncedMessageId: latestMessageId,
            syncedAt: syncedAt ?? Date()
        )
    }

    private static func syncStateRecord(in db: Database, chatId: Int64) throws -> SyncStateRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT chat_id, last_indexed_message_id, last_indexed_at, total_messages_indexed, is_search_ready
                FROM sync_state
                WHERE chat_id = ?
                """,
            arguments: [chatId]
        ) else {
            return nil
        }

        let lastIndexedAtSeconds: Double? = row["last_indexed_at"]
        let isSearchReadyValue: Int64 = row["is_search_ready"]
        return SyncStateRecord(
            chatId: row["chat_id"],
            lastIndexedMessageId: row["last_indexed_message_id"],
            lastIndexedAt: lastIndexedAtSeconds.map(Date.init(timeIntervalSince1970:)),
            totalMessagesIndexed: row["total_messages_indexed"],
            isSearchReady: isSearchReadyValue != 0
        )
    }

    private static func recentSyncStateRecord(
        in db: Database,
        chatId: Int64
    ) throws -> RecentSyncStateRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT chat_id, latest_synced_message_id, last_recent_sync_at
                FROM recent_sync_state
                WHERE chat_id = ?
                """,
            arguments: [chatId]
        ) else {
            return nil
        }

        let lastRecentSyncAtSeconds: Double? = row["last_recent_sync_at"]
        return RecentSyncStateRecord(
            chatId: row["chat_id"],
            latestSyncedMessageId: row["latest_synced_message_id"],
            lastRecentSyncAt: lastRecentSyncAtSeconds.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func removeLegacyMessageCacheDirectory() {
        try? fileManager.removeItem(at: legacyMessageCacheDirectory)
    }

    private func removeLegacyPipelineCacheDirectory() {
        try? fileManager.removeItem(at: legacyPipelineCacheDirectory)
    }

    private static func sortMessagesDescending(lhs: MessageRecord, rhs: MessageRecord) -> Bool {
        if lhs.date != rhs.date {
            return lhs.date > rhs.date
        }
        return lhs.id > rhs.id
    }

    private static func messageRecord(from row: Row) -> MessageRecord {
        let timestamp: Double = row["date"]
        let isOutgoingValue: Int64 = row["is_outgoing"]

        return MessageRecord(
            id: row["id"],
            chatId: row["chat_id"],
            senderUserId: row["sender_user_id"],
            senderName: row["sender_name"],
            date: Date(timeIntervalSince1970: timestamp),
            textContent: row["text_content"],
            mediaTypeRaw: row["media_type"],
            isOutgoing: isOutgoingValue != 0
        )
    }

    private static func normalizedFTSQuery(from query: String) -> String {
        let sanitized = query.replacingOccurrences(of: "\"", with: " ")
        let tokens = sanitized
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }

        return tokens
            .map { "\"\($0)\"" }
            .joined(separator: " ")
    }
}
