import Foundation
import GRDB

enum DatabaseManagerError: Error {
    case unavailable
}

actor DatabaseManager {
    static let shared = DatabaseManager()
    private static let manualDashboardTopicScore = 10_000.0

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
        let schemaVersion: Int
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

    struct DashboardTaskSyncStateRecord: Sendable, Equatable {
        let chatId: Int64
        let latestMessageId: Int64
        let lastSyncedAt: Date?
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

    func upsertLiveMessages(
        chatId: Int64,
        messages: [MessageRecord],
        updateRecentSyncState: Bool = true
    ) async {
        guard !messages.isEmpty else { return }
        guard let pool = await ensureDatabase() else { return }
        let latestMessageId = messages
            .sorted(by: Self.sortMessagesDescending)
            .first?
            .id ?? 0

        do {
            try await pool.write { db in
                try Self.insertMessages(messages, into: db)
                if updateRecentSyncState {
                    try Self.refreshRecentSyncState(
                        in: db,
                        chatId: chatId,
                        preferredLatestMessageId: latestMessageId,
                        syncedAt: Date()
                    )
                }
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
                let existing = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT text_content, media_type
                        FROM messages
                        WHERE chat_id = ? AND id = ?
                        """,
                    arguments: [chatId, messageId]
                )
                let existingText: String? = existing?["text_content"]
                let existingMediaType: String? = existing?["media_type"]
                let contentChanged = existing != nil
                    && (existingText != textContent || existingMediaType != mediaTypeRaw)

                try db.execute(
                    sql: """
                        UPDATE messages
                        SET text_content = ?, media_type = ?
                        WHERE chat_id = ? AND id = ?
                    """,
                    arguments: [textContent, mediaTypeRaw, chatId, messageId]
                )
                if contentChanged {
                    try Self.deleteEmbeddings(in: db, chatId: chatId, messageIds: [messageId])
                }
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
                try db.execute(
                    sql: "DELETE FROM chat_coverage_state WHERE chat_id = ?",
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

    func loadMessageCoverage(chatId: Int64, since minimumDate: Date? = nil) async -> MessageCoverageRecord? {
        guard let pool = await ensureDatabase() else { return nil }

        do {
            return try await pool.read { db in
                let count: Int
                if let minimumDate {
                    count = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM messages WHERE chat_id = ? AND date >= ?",
                        arguments: [chatId, minimumDate.timeIntervalSince1970]
                    ) ?? 0
                } else {
                    count = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM messages WHERE chat_id = ?",
                        arguments: [chatId]
                    ) ?? 0
                }

                guard count > 0 else {
                    return MessageCoverageRecord(
                        chatId: chatId,
                        messageCount: 0,
                        oldestMessageId: nil,
                        oldestMessageDate: nil,
                        latestMessageId: nil,
                        latestMessageDate: nil
                    )
                }

                let oldest: Row?
                let latest: Row?
                if let minimumDate {
                    oldest = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT id, date
                            FROM messages
                            WHERE chat_id = ? AND date >= ?
                            ORDER BY date ASC, id ASC
                            LIMIT 1
                            """,
                        arguments: [chatId, minimumDate.timeIntervalSince1970]
                    )
                    latest = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT id, date
                            FROM messages
                            WHERE chat_id = ? AND date >= ?
                            ORDER BY date DESC, id DESC
                            LIMIT 1
                            """,
                        arguments: [chatId, minimumDate.timeIntervalSince1970]
                    )
                } else {
                    oldest = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT id, date
                            FROM messages
                            WHERE chat_id = ?
                            ORDER BY date ASC, id ASC
                            LIMIT 1
                            """,
                        arguments: [chatId]
                    )
                    latest = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT id, date
                            FROM messages
                            WHERE chat_id = ?
                            ORDER BY date DESC, id DESC
                            LIMIT 1
                            """,
                        arguments: [chatId]
                    )
                }

                let oldestSeconds: Double? = oldest?["date"]
                let latestSeconds: Double? = latest?["date"]
                return MessageCoverageRecord(
                    chatId: chatId,
                    messageCount: count,
                    oldestMessageId: oldest?["id"],
                    oldestMessageDate: oldestSeconds.map(Date.init(timeIntervalSince1970:)),
                    latestMessageId: latest?["id"],
                    latestMessageDate: latestSeconds.map(Date.init(timeIntervalSince1970:))
                )
            }
        } catch {
            print("[DatabaseManager] Failed to load message coverage for chat \(chatId): \(error)")
            return nil
        }
    }

    func loadChatCoverageState(chatId: Int64) async -> ChatCoverageStateRecord? {
        guard let pool = await ensureDatabase() else { return nil }

        do {
            return try await pool.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT chat_id, oldest_covered_at, oldest_covered_message_id, latest_seen_message_id, last_checked_at, is_major, last_error, failure_count, next_retry_at, coverage_version
                        FROM chat_coverage_state
                        WHERE chat_id = ?
                        """,
                    arguments: [chatId]
                ) else {
                    return nil
                }

                let oldestSeconds: Double? = row["oldest_covered_at"]
                let checkedSeconds: Double? = row["last_checked_at"]
                let nextRetrySeconds: Double? = row["next_retry_at"]
                let failureCountValue: Int64 = row["failure_count"]
                let isMajorValue: Int64 = row["is_major"]
                return ChatCoverageStateRecord(
                    chatId: row["chat_id"],
                    oldestCoveredAt: oldestSeconds.map(Date.init(timeIntervalSince1970:)),
                    oldestCoveredMessageId: row["oldest_covered_message_id"],
                    latestSeenMessageId: row["latest_seen_message_id"],
                    lastCheckedAt: checkedSeconds.map(Date.init(timeIntervalSince1970:)),
                    isMajor: isMajorValue != 0,
                    lastError: row["last_error"],
                    failureCount: Int(failureCountValue),
                    nextRetryAt: nextRetrySeconds.map(Date.init(timeIntervalSince1970:)),
                    coverageVersion: row["coverage_version"]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to load chat coverage state for chat \(chatId): \(error)")
            return nil
        }
    }

    func loadMajorCoverageDebtChatIds(
        limit: Int,
        now: Date,
        cutoff: Date,
        coverageVersion: Int,
        minMessageCount _: Int
    ) async -> [Int64] {
        guard limit > 0, let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT s.chat_id
                        FROM chat_coverage_state s
                        LEFT JOIN nodes n ON n.entity_id = s.chat_id
                        WHERE s.is_major = 1
                          AND (s.next_retry_at IS NULL OR s.next_retry_at <= ?)
                          AND (
                              s.coverage_version < ?
                              OR s.oldest_covered_at IS NULL
                              OR s.oldest_covered_at > ?
                          )
                        ORDER BY
                            CASE
                                WHEN s.coverage_version >= ?
                                  AND (s.oldest_covered_at IS NULL OR s.oldest_covered_at > ?)
                                  THEN 0
                                WHEN s.coverage_version < ? THEN 1
                                ELSE 2
                            END ASC,
                            COALESCE(n.last_interaction_at, 0) DESC,
                            s.last_checked_at ASC,
                            s.chat_id ASC
                        LIMIT ?
                    """,
                    arguments: [
                        now.timeIntervalSince1970,
                        coverageVersion,
                        cutoff.timeIntervalSince1970,
                        coverageVersion,
                        cutoff.timeIntervalSince1970,
                        coverageVersion,
                        limit
                    ]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to load major coverage debt chat ids: \(error)")
            return []
        }
    }

    func saveChatCoverageState(_ record: ChatCoverageStateRecord) async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO chat_coverage_state
                        (chat_id, oldest_covered_at, oldest_covered_message_id, latest_seen_message_id, last_checked_at, is_major, last_error, failure_count, next_retry_at, coverage_version)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(chat_id) DO UPDATE SET
                            oldest_covered_at = excluded.oldest_covered_at,
                            oldest_covered_message_id = excluded.oldest_covered_message_id,
                            latest_seen_message_id = excluded.latest_seen_message_id,
                            last_checked_at = excluded.last_checked_at,
                            is_major = excluded.is_major,
                            last_error = excluded.last_error,
                            failure_count = excluded.failure_count,
                            next_retry_at = excluded.next_retry_at,
                            coverage_version = excluded.coverage_version
                        """,
                    arguments: [
                        record.chatId,
                        record.oldestCoveredAt?.timeIntervalSince1970,
                        record.oldestCoveredMessageId,
                        record.latestSeenMessageId,
                        record.lastCheckedAt?.timeIntervalSince1970 ?? 0,
                        record.isMajor ? 1 : 0,
                        record.lastError,
                        record.failureCount,
                        record.nextRetryAt?.timeIntervalSince1970,
                        record.coverageVersion
                    ]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to save chat coverage state for chat \(record.chatId): \(error)")
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
                        SELECT chat_id, category, suggested_action, last_message_id, analyzed_at, schema_version
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
                    analyzedAt: Date(timeIntervalSince1970: analyzedAt),
                    schemaVersion: row["schema_version"]
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
                        INSERT INTO pipeline_cache (chat_id, category, suggested_action, last_message_id, analyzed_at, schema_version)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(chat_id) DO UPDATE SET
                            category = excluded.category,
                            suggested_action = excluded.suggested_action,
                            last_message_id = excluded.last_message_id,
                            analyzed_at = excluded.analyzed_at,
                            schema_version = excluded.schema_version
                        """,
                    arguments: [
                        record.chatId,
                        record.category,
                        record.suggestedAction,
                        record.lastMessageId,
                        record.analyzedAt.timeIntervalSince1970,
                        record.schemaVersion
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
                try db.execute(sql: "DELETE FROM chat_coverage_state WHERE chat_id >= 0")
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
                try db.execute(sql: "DELETE FROM chat_coverage_state")
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

    /// Run a pre-built FTS5 MATCH expression directly (no normalization).
    /// Use this when the caller wants to control query shape — e.g. to
    /// run graduated variants like `NEAR("a" "b", 5)` / `"a" OR "b"` /
    /// `a* OR b*` and then fuse the results via RRF instead of relying
    /// on the default AND-of-quoted-tokens that `normalizedFTSQuery`
    /// produces. Returns an empty array if the expression is empty or
    /// the FTS engine rejects it (which it does for malformed queries).
    func localSearchFTSRaw(rawFTSQuery: String, chatIds: [Int64]? = nil, limit: Int = 50) async -> [ScoredMessageRecord] {
        let trimmed = rawFTSQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let chatIds, chatIds.isEmpty { return [] }
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                let rows: [Row]
                if let chatIds {
                    let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
                    var arguments = StatementArguments()
                    arguments += [trimmed]
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
                        arguments: [trimmed, limit]
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
            // Malformed FTS5 syntax raises an error — log once and return
            // empty so the caller's fallback variants still get to run.
            print("[DatabaseManager] Raw FTS query failed: \(rawFTSQuery) -> \(error)")
            return []
        }
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

    func loadSearchableMessages(
        chatIds: [Int64]? = nil,
        limit: Int = 10_000,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async -> [MessageRecord] {
        guard limit > 0 else { return [] }
        if let chatIds, chatIds.isEmpty { return [] }
        guard let pool = await ensureDatabase() else { return [] }
        let startTimestamp = startDate?.timeIntervalSince1970
        let endTimestamp = endDate?.timeIntervalSince1970

        do {
            return try await pool.read { db in
                let rows: [Row]
                if let chatIds {
                    let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
                    var arguments = StatementArguments()
                    for chatId in chatIds {
                        arguments += [chatId]
                    }
                    arguments += [startTimestamp, startTimestamp, endTimestamp, endTimestamp]
                    arguments += [limit]

                    rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing
                            FROM messages
                            WHERE text_content IS NOT NULL
                              AND length(trim(text_content)) > 0
                              AND chat_id IN (\(placeholders))
                              AND (? IS NULL OR date >= ?)
                              AND (? IS NULL OR date <= ?)
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
                              AND (? IS NULL OR date >= ?)
                              AND (? IS NULL OR date <= ?)
                            ORDER BY date DESC, id DESC
                            LIMIT ?
                            """,
                        arguments: [startTimestamp, startTimestamp, endTimestamp, endTimestamp, limit]
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

    func upsertDashboardTopics(_ discovered: [DashboardTopicDTO]) async -> [DashboardTopic] {
        let normalized = Self.normalizedDashboardTopicDTOs(discovered)
        guard !normalized.isEmpty else {
            return await loadDashboardTopics()
        }
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.write { db in
                let now = Date().timeIntervalSince1970
                let activeNames = normalized.map(\.name)
                let staleRankOffset = AppConstants.Dashboard.maxTopicCount + 1_000
                if !activeNames.isEmpty {
                    let placeholders = Array(repeating: "?", count: activeNames.count).joined(separator: ", ")
                    var staleArguments = StatementArguments()
                    staleArguments += [staleRankOffset]
                    for name in activeNames {
                        staleArguments += [name]
                    }
                    staleArguments += [staleRankOffset]
                    staleArguments += [Self.manualDashboardTopicScore]

                    try db.execute(
                        sql: """
                            UPDATE dashboard_topics
                            SET rank = ? + rank
                            WHERE name COLLATE NOCASE NOT IN (\(placeholders))
                              AND rank < ?
                              AND score < ?
                            """,
                        arguments: staleArguments
                    )
                }

                for (index, topic) in normalized.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO dashboard_topics (name, rationale, score, rank, created_at, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?)
                            ON CONFLICT(name) DO UPDATE SET
                                rationale = excluded.rationale,
                                score = excluded.score,
                                rank = excluded.rank,
                                updated_at = excluded.updated_at
                            """,
                        arguments: [
                            topic.name,
                            topic.rationale,
                            topic.score,
                            index,
                            now,
                            now
                        ]
                    )
                }

                return try Self.loadDashboardTopics(in: db, limit: AppConstants.Dashboard.maxTopicCount)
            }
        } catch {
            print("[DatabaseManager] Failed to upsert dashboard topics: \(error)")
            return []
        }
    }

    func loadDashboardTopics(limit: Int = AppConstants.Dashboard.maxTopicCount) async -> [DashboardTopic] {
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                try Self.loadDashboardTopics(in: db, limit: limit)
            }
        } catch {
            print("[DatabaseManager] Failed to load dashboard topics: \(error)")
            return []
        }
    }

    func addDashboardTopic(name rawName: String, rationale rawRationale: String = "Added manually.") async -> DashboardTopic? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.lowercased() != "uncategorized" else { return nil }
        guard let pool = await ensureDatabase() else { return nil }

        let rationale = rawRationale.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            return try await pool.write { db in
                let now = Date().timeIntervalSince1970
                let pinnedRank = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MIN(rank), 0) - 1 FROM dashboard_topics"
                ) ?? -1

                try db.execute(
                    sql: """
                        INSERT INTO dashboard_topics (name, rationale, score, rank, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(name) DO UPDATE SET
                            rationale = CASE
                                WHEN excluded.rationale != '' THEN excluded.rationale
                                ELSE dashboard_topics.rationale
                            END,
                            score = MAX(dashboard_topics.score, excluded.score),
                            rank = MIN(dashboard_topics.rank, excluded.rank),
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        name,
                        rationale,
                        Self.manualDashboardTopicScore,
                        pinnedRank,
                        now,
                        now
                    ]
                )

                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, name, rationale, score, rank, created_at, updated_at
                        FROM dashboard_topics
                        WHERE name = ? COLLATE NOCASE
                        """,
                    arguments: [name]
                ) else {
                    return nil
                }
                return Self.dashboardTopic(from: row)
            }
        } catch {
            print("[DatabaseManager] Failed to add dashboard topic \(name): \(error)")
            return nil
        }
    }

    /// Hard-deletes a dashboard topic. The Tasks page's per-task topic
    /// label survives because tasks store the topic name (not id), but
    /// the sidebar entry disappears and won't be re-discovered until the
    /// user explicitly runs topic discovery again.
    func deleteDashboardTopic(id: Int64) async {
        guard let pool = await ensureDatabase() else { return }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM dashboard_topics WHERE id = ?",
                    arguments: [id]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to delete dashboard topic \(id): \(error)")
        }
    }

    func upsertDashboardTasks(_ candidates: [DashboardTaskCandidate]) async -> [DashboardTask] {
        let normalized = candidates.filter {
            !$0.stableFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !normalized.isEmpty else { return [] }
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.write { db in
                var tasks: [DashboardTask] = []
                for candidate in normalized {
                    let topicId = try Self.ensureDashboardTopic(named: candidate.topicName, in: db)
                    let latestSourceDate = candidate.sourceMessages.map(\.date).max()
                    let existing = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT id, status, created_at, snoozed_until
                            FROM dashboard_tasks
                            WHERE stable_fingerprint = ?
                            """,
                        arguments: [candidate.stableFingerprint]
                    )
                    let taskId: Int64
                    let status = (existing?["status"] as String?)
                        .flatMap(DashboardTaskStatus.init(rawValue:))
                        ?? candidate.status
                    let createdAtSeconds: Double = existing?["created_at"] ?? candidate.createdAt.timeIntervalSince1970
                    let snoozedUntilSeconds: Double? = existing?["snoozed_until"]
                    let updatedAt = Date().timeIntervalSince1970

                    if let existingId: Int64 = existing?["id"] {
                        taskId = existingId
                        try db.execute(
                            sql: """
                                UPDATE dashboard_tasks
                                SET title = ?,
                                    summary = ?,
                                    suggested_action = ?,
                                    owner_name = ?,
                                    person_name = ?,
                                    chat_id = ?,
                                    chat_title = ?,
                                    topic_id = ?,
                                    topic_name = ?,
                                    priority = ?,
                                    status = ?,
                                    confidence = ?,
                                    updated_at = ?,
                                    due_at = ?,
                                    snoozed_until = ?,
                                    latest_source_date = ?
                                WHERE id = ?
                                """,
                            arguments: [
                                candidate.title,
                                candidate.summary,
                                candidate.suggestedAction,
                                candidate.ownerName,
                                candidate.personName,
                                candidate.chatId,
                                candidate.chatTitle,
                                topicId,
                                candidate.topicName,
                                candidate.priority.rawValue,
                                status.rawValue,
                                candidate.confidence,
                                updatedAt,
                                candidate.dueAt?.timeIntervalSince1970,
                                snoozedUntilSeconds,
                                latestSourceDate?.timeIntervalSince1970,
                                taskId
                            ]
                        )
                    } else {
                        try db.execute(
                            sql: """
                                INSERT INTO dashboard_tasks (
                                    stable_fingerprint, title, summary, suggested_action, owner_name, person_name,
                                    chat_id, chat_title, topic_id, topic_name, priority, status, confidence,
                                    created_at, updated_at, due_at, snoozed_until, latest_source_date
                                )
                                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                            arguments: [
                                candidate.stableFingerprint,
                                candidate.title,
                                candidate.summary,
                                candidate.suggestedAction,
                                candidate.ownerName,
                                candidate.personName,
                                candidate.chatId,
                                candidate.chatTitle,
                                topicId,
                                candidate.topicName,
                                candidate.priority.rawValue,
                                status.rawValue,
                                candidate.confidence,
                                createdAtSeconds,
                                updatedAt,
                                candidate.dueAt?.timeIntervalSince1970,
                                snoozedUntilSeconds,
                                latestSourceDate?.timeIntervalSince1970
                            ]
                        )
                        taskId = db.lastInsertedRowID
                    }

                    try db.execute(
                        sql: "DELETE FROM dashboard_task_sources WHERE task_id = ?",
                        arguments: [taskId]
                    )
                    for source in candidate.sourceMessages {
                        try db.execute(
                            sql: """
                                INSERT INTO dashboard_task_sources (task_id, chat_id, message_id, sender_name, text, date)
                                VALUES (?, ?, ?, ?, ?, ?)
                                ON CONFLICT(task_id, chat_id, message_id) DO UPDATE SET
                                    sender_name = excluded.sender_name,
                                    text = excluded.text,
                                    date = excluded.date
                                """,
                            arguments: [
                                taskId,
                                source.chatId,
                                source.messageId,
                                source.senderName,
                                source.text,
                                source.date.timeIntervalSince1970
                            ]
                        )
                    }

                    if let row = try Row.fetchOne(
                        db,
                        sql: Self.dashboardTaskSelectSQL + " WHERE id = ?",
                        arguments: [taskId]
                    ) {
                        tasks.append(Self.dashboardTask(from: row))
                    }
                }
                return tasks.sorted(by: Self.sortDashboardTasks)
            }
        } catch {
            print("[DatabaseManager] Failed to upsert dashboard tasks: \(error)")
            return []
        }
    }

    func loadDashboardTasks(
        status: DashboardTaskStatus? = nil,
        limit: Int = AppConstants.Dashboard.defaultTaskLimit
    ) async -> [DashboardTask] {
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                let rows: [Row]
                if let status {
                    rows = try Row.fetchAll(
                        db,
                        sql: Self.dashboardTaskSelectSQL + """
                            WHERE status = ?
                            ORDER BY
                                COALESCE(latest_source_date, updated_at) DESC,
                                id DESC
                            LIMIT ?
                            """,
                        arguments: [status.rawValue, limit]
                    )
                } else {
                    rows = try Row.fetchAll(
                        db,
                        sql: Self.dashboardTaskSelectSQL + """
                            ORDER BY
                                COALESCE(latest_source_date, updated_at) DESC,
                                id DESC
                            LIMIT ?
                            """,
                        arguments: [limit]
                    )
                }
                return rows.map(Self.dashboardTask(from:))
            }
        } catch {
            print("[DatabaseManager] Failed to load dashboard tasks: \(error)")
            return []
        }
    }

    func loadDashboardTaskEvidence(taskIds: [Int64]) async -> [Int64: [DashboardTaskSourceMessage]] {
        guard !taskIds.isEmpty else { return [:] }
        guard let pool = await ensureDatabase() else { return [:] }

        do {
            return try await pool.read { db in
                let placeholders = Array(repeating: "?", count: taskIds.count).joined(separator: ", ")
                var arguments = StatementArguments()
                for taskId in taskIds {
                    arguments += [taskId]
                }
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT
                            dts.task_id,
                            dts.chat_id,
                            dts.message_id,
                            COALESCE(m.sender_name, dts.sender_name) AS sender_name,
                            COALESCE(m.text_content, dts.text) AS text,
                            COALESCE(m.date, dts.date) AS date
                        FROM dashboard_task_sources dts
                        LEFT JOIN messages m
                            ON m.chat_id = dts.chat_id
                           AND m.id = dts.message_id
                        WHERE dts.task_id IN (\(placeholders))
                        ORDER BY COALESCE(m.date, dts.date) DESC, dts.message_id DESC
                        """,
                    arguments: arguments
                )
                return rows.reduce(into: [Int64: [DashboardTaskSourceMessage]]()) { grouped, row in
                    let taskId: Int64 = row["task_id"]
                    grouped[taskId, default: []].append(Self.dashboardTaskSource(from: row))
                }
            }
        } catch {
            print("[DatabaseManager] Failed to load dashboard task evidence: \(error)")
            return [:]
        }
    }

    func updateDashboardTaskStatus(
        taskId: Int64,
        status: DashboardTaskStatus,
        snoozedUntil: Date? = nil
    ) async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                        UPDATE dashboard_tasks
                        SET status = ?,
                            snoozed_until = ?,
                            updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        status.rawValue,
                        snoozedUntil?.timeIntervalSince1970,
                        Date().timeIntervalSince1970,
                        taskId
                    ]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to update dashboard task \(taskId) status: \(error)")
        }
    }

    func ignoreOpenDashboardTasks(
        chatId: Int64,
        matchingTaskIds taskIds: [Int64] = [],
        matchingSourceMessageIds messageIds: [Int64]
    ) async {
        let uniqueTaskIds = Array(Set(taskIds)).filter { $0 > 0 }
        let uniqueMessageIds = Array(Set(messageIds)).filter { $0 > 0 }
        guard !uniqueTaskIds.isEmpty || !uniqueMessageIds.isEmpty else { return }
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                var matchClauses: [String] = []
                var arguments = StatementArguments()
                arguments += [DashboardTaskStatus.ignored.rawValue]
                arguments += [Date().timeIntervalSince1970]
                arguments += [chatId]

                if !uniqueTaskIds.isEmpty {
                    let placeholders = Array(repeating: "?", count: uniqueTaskIds.count).joined(separator: ", ")
                    matchClauses.append("dashboard_tasks.id IN (\(placeholders))")
                    for taskId in uniqueTaskIds {
                        arguments += [taskId]
                    }
                }

                if !uniqueMessageIds.isEmpty {
                    let placeholders = Array(repeating: "?", count: uniqueMessageIds.count).joined(separator: ", ")
                    matchClauses.append(
                        """
                        EXISTS (
                            SELECT 1
                            FROM dashboard_task_sources
                            WHERE dashboard_task_sources.task_id = dashboard_tasks.id
                              AND dashboard_task_sources.chat_id = dashboard_tasks.chat_id
                              AND dashboard_task_sources.message_id IN (\(placeholders))
                        )
                        """
                    )
                    for messageId in uniqueMessageIds {
                        arguments += [messageId]
                    }
                }

                try db.execute(
                    sql: """
                        UPDATE dashboard_tasks
                        SET status = ?,
                            snoozed_until = NULL,
                            updated_at = ?
                        WHERE status = 'open'
                          AND chat_id = ?
                          AND (\(matchClauses.joined(separator: " OR ")))
                        """,
                    arguments: arguments
                )
            }
        } catch {
            print("[DatabaseManager] Failed to ignore stale dashboard tasks for chat \(chatId): \(error)")
        }
    }

    func completeOpenDashboardTasks(
        chatId: Int64,
        matchingTaskIds taskIds: [Int64],
        matchingSourceMessageIds messageIds: [Int64]
    ) async {
        let uniqueTaskIds = Array(Set(taskIds)).filter { $0 > 0 }
        let uniqueMessageIds = Array(Set(messageIds)).filter { $0 > 0 }
        guard !uniqueTaskIds.isEmpty || !uniqueMessageIds.isEmpty else { return }
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                var matchClauses: [String] = []
                var arguments = StatementArguments()
                arguments += [DashboardTaskStatus.done.rawValue]
                arguments += [Date().timeIntervalSince1970]
                arguments += [chatId]

                if !uniqueTaskIds.isEmpty {
                    let placeholders = Array(repeating: "?", count: uniqueTaskIds.count).joined(separator: ", ")
                    matchClauses.append("dashboard_tasks.id IN (\(placeholders))")
                    for taskId in uniqueTaskIds {
                        arguments += [taskId]
                    }
                }

                if !uniqueMessageIds.isEmpty {
                    let placeholders = Array(repeating: "?", count: uniqueMessageIds.count).joined(separator: ", ")
                    matchClauses.append(
                        """
                        EXISTS (
                            SELECT 1
                            FROM dashboard_task_sources
                            WHERE dashboard_task_sources.task_id = dashboard_tasks.id
                              AND dashboard_task_sources.chat_id = dashboard_tasks.chat_id
                              AND dashboard_task_sources.message_id IN (\(placeholders))
                        )
                        """
                    )
                    for messageId in uniqueMessageIds {
                        arguments += [messageId]
                    }
                }

                try db.execute(
                    sql: """
                        UPDATE dashboard_tasks
                        SET status = ?,
                            snoozed_until = NULL,
                            updated_at = ?
                        WHERE status IN ('open', 'snoozed')
                          AND chat_id = ?
                          AND (\(matchClauses.joined(separator: " OR ")))
                        """,
                    arguments: arguments
                )
            }
        } catch {
            print("[DatabaseManager] Failed to complete dashboard tasks for chat \(chatId): \(error)")
        }
    }

    func loadDashboardTaskSyncState(chatId: Int64) async -> DashboardTaskSyncStateRecord? {
        guard let pool = await ensureDatabase() else { return nil }

        do {
            return try await pool.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT chat_id, latest_message_id, last_synced_at
                        FROM dashboard_task_sync_state
                        WHERE chat_id = ?
                        """,
                    arguments: [chatId]
                ) else {
                    return nil
                }
                let lastSyncedAtSeconds: Double? = row["last_synced_at"]
                return DashboardTaskSyncStateRecord(
                    chatId: row["chat_id"],
                    latestMessageId: row["latest_message_id"],
                    lastSyncedAt: lastSyncedAtSeconds.map(Date.init(timeIntervalSince1970:))
                )
            }
        } catch {
            print("[DatabaseManager] Failed to load dashboard sync state for chat \(chatId): \(error)")
            return nil
        }
    }

    func updateDashboardTaskSyncState(chatId: Int64, latestMessageId: Int64, syncedAt: Date = Date()) async {
        guard let pool = await ensureDatabase() else { return }

        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO dashboard_task_sync_state (chat_id, latest_message_id, last_synced_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(chat_id) DO UPDATE SET
                            latest_message_id = MAX(dashboard_task_sync_state.latest_message_id, excluded.latest_message_id),
                            last_synced_at = excluded.last_synced_at
                        """,
                    arguments: [chatId, latestMessageId, syncedAt.timeIntervalSince1970]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to update dashboard sync state for chat \(chatId): \(error)")
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
                            INSERT INTO pipeline_cache (chat_id, category, suggested_action, last_message_id, analyzed_at, schema_version)
                            VALUES (?, ?, ?, ?, ?, ?)
                            ON CONFLICT(chat_id) DO UPDATE SET
                                category = excluded.category,
                                suggested_action = excluded.suggested_action,
                                last_message_id = excluded.last_message_id,
                                analyzed_at = excluded.analyzed_at,
                                schema_version = excluded.schema_version
                            """,
                        arguments: [
                            cached.chatId,
                            cached.category,
                            cached.suggestedAction,
                            cached.lastMessageId,
                            cached.analyzedAt.timeIntervalSince1970,
                            1
                        ]
                    )
                }
            }

            removeLegacyPipelineCacheDirectory()
        }
    }

    private static let dashboardTaskSelectSQL = """
        SELECT
            dt.id,
            dt.stable_fingerprint,
            dt.title,
            dt.summary,
            dt.suggested_action,
            dt.owner_name,
            dt.person_name,
            dt.chat_id,
            dt.chat_title,
            dt.topic_id,
            dt.topic_name,
            dt.priority,
            dt.status,
            dt.confidence,
            dt.created_at,
            dt.updated_at,
            dt.due_at,
            dt.snoozed_until,
            COALESCE(
                (
                    SELECT MAX(COALESCE(m.date, dts.date))
                    FROM dashboard_task_sources dts
                    LEFT JOIN messages m
                        ON m.chat_id = dts.chat_id
                       AND m.id = dts.message_id
                    WHERE dts.task_id = dt.id
                ),
                dt.latest_source_date
            ) AS latest_source_date
        FROM dashboard_tasks dt

        """

    private static func normalizedDashboardTopicDTOs(_ topics: [DashboardTopicDTO]) -> [DashboardTopicDTO] {
        var seen = Set<String>()
        return topics
            .map { topic in
                DashboardTopicDTO(
                    name: topic.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    rationale: topic.rationale.trimmingCharacters(in: .whitespacesAndNewlines),
                    score: topic.score
                )
            }
            .filter { !$0.name.isEmpty }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .filter { topic in
                let key = topic.name.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            .prefix(AppConstants.Dashboard.maxTopicCount)
            .map { $0 }
    }

    private static func loadDashboardTopics(in db: Database, limit: Int) throws -> [DashboardTopic] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, rationale, score, rank, created_at, updated_at
                FROM dashboard_topics
                ORDER BY rank ASC, score DESC, name COLLATE NOCASE ASC
                LIMIT ?
                """,
            arguments: [limit]
        )
        return rows.map(dashboardTopic(from:))
    }

    /// Looks up the topic id for a name passed in by an extracted task.
    /// Topics are now exclusively user-curated (via the sidebar "+" sheet)
    /// — task extraction can still TAG a task with whatever topic name
    /// the AI infers, but the row's `topic_id` foreign key only resolves
    /// when the user has explicitly created that topic. Previously this
    /// helper auto-inserted any name the AI mentioned, which is exactly
    /// what was silently re-adding "Akhil B" / "First Dollar" / etc.
    /// after the explicit topic-discovery pass was disabled.
    private static func ensureDashboardTopic(named rawName: String?, in db: Database) throws -> Int64? {
        guard let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              name.lowercased() != "uncategorized" else {
            return nil
        }
        return try Int64.fetchOne(
            db,
            sql: "SELECT id FROM dashboard_topics WHERE name = ? COLLATE NOCASE",
            arguments: [name]
        )
    }

    private static func dashboardTopic(from row: Row) -> DashboardTopic {
        let createdAtSeconds: Double = row["created_at"]
        let updatedAtSeconds: Double = row["updated_at"]
        return DashboardTopic(
            id: row["id"],
            name: row["name"],
            rationale: row["rationale"],
            score: row["score"],
            rank: row["rank"],
            createdAt: Date(timeIntervalSince1970: createdAtSeconds),
            updatedAt: Date(timeIntervalSince1970: updatedAtSeconds)
        )
    }

    private static func dashboardTask(from row: Row) -> DashboardTask {
        let createdAtSeconds: Double = row["created_at"]
        let updatedAtSeconds: Double = row["updated_at"]
        let dueAtSeconds: Double? = row["due_at"]
        let snoozedUntilSeconds: Double? = row["snoozed_until"]
        let latestSourceDateSeconds: Double? = row["latest_source_date"]
        let priority = DashboardTaskPriority(rawValue: (row["priority"] as String).lowercased()) ?? .medium
        let status = DashboardTaskStatus(rawValue: (row["status"] as String).lowercased()) ?? .open

        return DashboardTask(
            id: row["id"],
            stableFingerprint: row["stable_fingerprint"],
            title: row["title"],
            summary: row["summary"],
            suggestedAction: row["suggested_action"],
            ownerName: row["owner_name"],
            personName: row["person_name"],
            chatId: row["chat_id"],
            chatTitle: row["chat_title"],
            topicId: row["topic_id"],
            topicName: row["topic_name"],
            priority: priority,
            status: status,
            confidence: row["confidence"],
            createdAt: Date(timeIntervalSince1970: createdAtSeconds),
            updatedAt: Date(timeIntervalSince1970: updatedAtSeconds),
            dueAt: dueAtSeconds.map(Date.init(timeIntervalSince1970:)),
            snoozedUntil: snoozedUntilSeconds.map(Date.init(timeIntervalSince1970:)),
            latestSourceDate: latestSourceDateSeconds.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func dashboardTaskSource(from row: Row) -> DashboardTaskSourceMessage {
        let dateSeconds: Double = row["date"]
        return DashboardTaskSourceMessage(
            chatId: row["chat_id"],
            messageId: row["message_id"],
            senderName: row["sender_name"],
            text: row["text"],
            date: Date(timeIntervalSince1970: dateSeconds)
        )
    }

    private static func sortDashboardTasks(_ lhs: DashboardTask, _ rhs: DashboardTask) -> Bool {
        if lhs.status != rhs.status {
            let order: [DashboardTaskStatus] = [.open, .snoozed, .done, .ignored]
            return (order.firstIndex(of: lhs.status) ?? order.count) < (order.firstIndex(of: rhs.status) ?? order.count)
        }
        if lhs.priority != rhs.priority {
            return lhs.priority.sortRank < rhs.priority.sortRank
        }
        let leftDate = lhs.latestSourceDate ?? lhs.updatedAt
        let rightDate = rhs.latestSourceDate ?? rhs.updatedAt
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        return lhs.id > rhs.id
    }

    private static func insertMessages(_ records: [MessageRecord], into db: Database) throws {
        for record in records {
            let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT text_content, media_type
                    FROM messages
                    WHERE chat_id = ? AND id = ?
                    """,
                arguments: [record.chatId, record.id]
            )
            let existingText: String? = existing?["text_content"]
            let existingMediaType: String? = existing?["media_type"]
            let contentChanged = existing != nil
                && (existingText != record.textContent || existingMediaType != record.mediaTypeRaw)

            try db.execute(
                sql: """
                    INSERT INTO messages
                    (id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id, chat_id) DO UPDATE SET
                        sender_user_id = excluded.sender_user_id,
                        sender_name = excluded.sender_name,
                        date = excluded.date,
                        text_content = excluded.text_content,
                        media_type = excluded.media_type,
                        is_outgoing = excluded.is_outgoing
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
            }
        }
    }

    private static func insertMissingMessages(_ records: [MessageRecord], into db: Database) throws {
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
