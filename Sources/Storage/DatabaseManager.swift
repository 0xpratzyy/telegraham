import Foundation
import GRDB

enum DatabaseManagerError: Error {
    case unavailable
}

actor DatabaseManager {
    static let shared = DatabaseManager()

    /// SQL bridge to `URLStripper.strip(_:)`. Registered on every DB
    /// connection so FTS triggers can call it transparently from SQL —
    /// see the `messages_fts` triggers updated in v13.
    fileprivate static let stripURLsFunction = DatabaseFunction(
        "pidgy_strip_urls",
        argumentCount: 1,
        pure: true
    ) { dbValues in
        guard let raw = String.fromDatabaseValue(dbValues[0]) else { return nil }
        return URLStripper.strip(raw)
    }

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

    struct MessageCoverageRecord: Sendable, Equatable {
        let chatId: Int64
        let messageCount: Int
        let oldestMessageId: Int64?
        let oldestMessageDate: Date?
        let latestMessageId: Int64?
        let latestMessageDate: Date?
    }

    struct ChatCoverageStateRecord: Sendable, Equatable {
        let chatId: Int64
        let oldestCoveredAt: Date?
        let oldestCoveredMessageId: Int64
        let latestSeenMessageId: Int64
        let lastCheckedAt: Date?
        let isMajor: Bool
        let lastError: String?
        let failureCount: Int
        let nextRetryAt: Date?
        let coverageVersion: Int

        init(
            chatId: Int64,
            oldestCoveredAt: Date?,
            oldestCoveredMessageId: Int64 = 0,
            latestSeenMessageId: Int64,
            lastCheckedAt: Date?,
            isMajor: Bool,
            lastError: String?,
            failureCount: Int,
            nextRetryAt: Date?,
            coverageVersion: Int
        ) {
            self.chatId = chatId
            self.oldestCoveredAt = oldestCoveredAt
            self.oldestCoveredMessageId = oldestCoveredMessageId
            self.latestSeenMessageId = latestSeenMessageId
            self.lastCheckedAt = lastCheckedAt
            self.isMajor = isMajor
            self.lastError = lastError
            self.failureCount = failureCount
            self.nextRetryAt = nextRetryAt
            self.coverageVersion = coverageVersion
        }
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

    private let fileManager = FileManager.default

    private var databasePool: DatabasePool?

    private var hasInitialized = false

    private var databaseURLOverride: URL?

    private var appSupportDirectoryOverride: URL?

    private var appSupportDirectory: URL {
        if let appSupportDirectoryOverride {
            return appSupportDirectoryOverride
        }
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
                // Make Swift's URL stripper callable from SQL — the FTS
                // sync triggers use it to skip URL substrings (which
                // otherwise pollute multi-word search via `/status/`,
                // `/update`, etc. paths inside shared tweets).
                db.add(function: Self.stripURLsFunction)
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

    func configureForTesting(
        databaseURLOverride: URL?,
        appSupportDirectoryOverride: URL? = nil
    ) async {
        databasePool = nil
        hasInitialized = false
        self.databaseURLOverride = databaseURLOverride
        self.appSupportDirectoryOverride = appSupportDirectoryOverride
    }

    func clearAllMessageAndPipelineData() async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try db.execute(sql: "DELETE FROM embeddings")
                try db.execute(sql: "DELETE FROM embedding_chunks")
                try db.execute(sql: "DELETE FROM embedding_chunk_state")
                try db.execute(sql: "DELETE FROM embedding_skips")
                try db.execute(sql: "DELETE FROM messages")
                try db.execute(sql: "DELETE FROM sync_state")
                try db.execute(sql: "DELETE FROM recent_sync_state")
                try db.execute(sql: "DELETE FROM chat_coverage_state")
            }
            removeLegacyMessageCacheDirectory()
            removeLegacyPipelineCacheDirectory()
        } catch {
            print("[DatabaseManager] Failed to clear cache tables: \(error)")
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

    // MARK: - Person profiles

    /// Cached compiled-truth profile for a Telegram user. Filled by
    /// `PersonProfileService` on first view; refreshed when the
    /// per-person message count has grown enough since the last extract.
    struct PersonProfileRecord: Sendable, Equatable {
        let userId: Int64
        let summary: String
        let version: Int
        let messageCountAtExtraction: Int
        let lastExtractedAt: Date
    }

    func ensureDatabase() async -> DatabasePool? {
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

                    let existingSyncState = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT last_indexed_message_id, is_search_ready
                            FROM sync_state
                            WHERE chat_id = ?
                            """,
                        arguments: [cached.chatId]
                    )
                    let preferredOldestMessageId: Int64? =
                        existingSyncState?["last_indexed_message_id"] ?? cached.oldestMessageId
                    let isSearchReady = (existingSyncState?["is_search_ready"] as Int?) == 1

                    try Self.insertMissingMessages(records, into: db)
                    try Self.refreshSyncState(
                        in: db,
                        chatId: cached.chatId,
                        preferredOldestMessageId: preferredOldestMessageId,
                        isSearchReady: isSearchReady
                    )
                }
            }

            removeLegacyMessageCacheDirectory()
        }

        // The legacy on-disk pipeline cache fed the retired pre-#48 reply
        // pipeline — nothing reads it anymore, so just clean up the directory.
        if hasLegacyPipelineCache {
            removeLegacyPipelineCacheDirectory()
        }
    }

    static func insertMessages(_ records: [MessageRecord], into db: Database) throws {
        for record in records {
            let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT text_content, media_type, sender_user_id, sender_name, is_outgoing
                    FROM messages
                    WHERE chat_id = ? AND id = ?
                    """,
                arguments: [record.chatId, record.id]
            )
            let existingText: String? = existing?["text_content"]
            let existingMediaType: String? = existing?["media_type"]
            let contentChanged = existing != nil
                && (strippedOCRBase(existingText) != record.textContent
                    || existingMediaType != record.mediaTypeRaw)

            // Recent-sync re-delivers the newest rows of every chat over and
            // over — an unchanged row must not run the UPDATE (each one fired
            // the FTS delete+reinsert trigger for identical text).
            if let existing, !contentChanged {
                let sameSender = (existing["sender_user_id"] as Int64?) == record.senderUserId
                    && ((record.senderName == nil) || (existing["sender_name"] as String?) == record.senderName)
                let sameDirection = (((existing["is_outgoing"] as Int64?) ?? 0) == 1) == record.isOutgoing
                if sameSender && sameDirection { continue }
            }

            // COALESCE keeps display-time enrichments (resolved sender names,
            // OCR text) from being wiped by a re-sync whose payload simply
            // lacks them; a genuine text edit resets ocr_state so the photo
            // is re-read.
            try db.execute(
                sql: """
                    INSERT INTO messages
                    (id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id, chat_id) DO UPDATE SET
                        sender_user_id = excluded.sender_user_id,
                        sender_name = COALESCE(excluded.sender_name, sender_name),
                        date = excluded.date,
                        text_content = excluded.text_content,
                        media_type = excluded.media_type,
                        is_outgoing = excluded.is_outgoing,
                        ocr_state = CASE WHEN excluded.text_content IS NOT text_content THEN 0 ELSE ocr_state END
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
            if contentChanged {
                try deleteEmbeddings(in: db, chatId: record.chatId, messageIds: [record.id])
                try invalidateChunks(in: db, chatId: record.chatId, messageIds: [record.id])
                try deleteEmbeddingSkips(in: db, chatId: record.chatId, messageIds: [record.id])
            }
        }
    }

    static func insertMissingMessages(_ records: [MessageRecord], into db: Database) throws {
        for record in records {
            try db.execute(
                sql: """
                    INSERT INTO messages
                    (id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id, chat_id) DO NOTHING
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

    static func deleteEmbeddings(
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

    static func deleteEmbeddingSkips(
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
            sql: "DELETE FROM embedding_skips WHERE chat_id = ? AND message_id IN (\(placeholders))",
            arguments: arguments
        )
    }

    /// Drop conversation chunks whose window overlaps any of the given messages
    /// — their `text_preview` still holds the now-deleted/edited text and would
    /// keep surfacing in search — then rewind the chunk watermark so the span is
    /// rebuilt from current message data (otherwise it's skipped as already
    /// chunked). Call on message delete or content edit.
    static func invalidateChunks(
        in db: Database,
        chatId: Int64,
        messageIds: [Int64]
    ) throws {
        guard let minId = messageIds.min(), let maxId = messageIds.max() else { return }

        // A chunk [from, to] overlaps the touched range iff from <= maxId and
        // to >= minId. Find the earliest start among overlapping chunks so we
        // rewind far enough to cover the whole purged span, not just from the
        // first touched message.
        guard let earliestFrom = try Int64.fetchOne(
            db,
            sql: """
                SELECT MIN(from_message_id) FROM embedding_chunks
                WHERE chat_id = ? AND from_message_id <= ? AND to_message_id >= ?
                """,
            arguments: [chatId, maxId, minId]
        ) else { return } // no overlapping chunks (NULL MIN → fetchOne nil)

        try db.execute(
            sql: """
                DELETE FROM embedding_chunks
                WHERE chat_id = ? AND from_message_id <= ? AND to_message_id >= ?
                """,
            arguments: [chatId, maxId, minId]
        )

        // Only ever lowers the watermark (SQLite scalar MIN), so re-chunking
        // covers the purged window without disturbing later progress.
        let rewindTo = earliestFrom - 1
        try db.execute(
            sql: """
                UPDATE embedding_chunk_state
                SET covered_through_message_id = MIN(covered_through_message_id, ?),
                    chunked_through_message_id = MIN(chunked_through_message_id, ?)
                WHERE chat_id = ?
                """,
            arguments: [rewindTo, rewindTo, chatId]
        )
    }

    static func refreshSyncState(
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

    static func saveRecentSyncState(
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

    static func refreshRecentSyncState(
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

    static func syncStateRecord(in db: Database, chatId: Int64) throws -> SyncStateRecord? {
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

    static func recentSyncStateRecord(
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

    static func sortMessagesDescending(lhs: MessageRecord, rhs: MessageRecord) -> Bool {
        if lhs.date != rhs.date {
            return lhs.date > rhs.date
        }
        return lhs.id > rhs.id
    }

    static func messageRecord(from row: Row) -> MessageRecord {
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
}
