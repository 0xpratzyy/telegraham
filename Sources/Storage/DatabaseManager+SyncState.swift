// DatabaseManager+SyncState.swift
// Sync/coverage state: recent-sync + indexed-sync records, chat coverage, search readiness.

import Foundation
import GRDB

extension DatabaseManager {
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

    /// Clears the retry guard on chat_coverage_state rows so the
    /// coordinator picks them up on its next sweep.
    /// **Preserves `failure_count`** so the adaptive batch/timeout
    /// scaling (smaller pages + longer wait per retry) actually kicks
    /// in — that's the whole point of resetting.
    ///
    /// - `forceAllPending`: when true, clears every row with an error
    ///   regardless of its backoff timer (intended for app launch so
    ///   the user gets a fresh retry attempt against any chat that
    ///   stalled previously). When false, only clears rows whose
    ///   retry was scheduled longer than `cutoffAge` seconds ago,
    ///   which preserves any legitimate in-flight backoff.
    ///
    /// Returns the count of rows reset so we can log it.
    @discardableResult
    func resetStuckCoverageRetries(
        forceAllPending: Bool = false,
        cutoffAge: TimeInterval = 30 * 60
    ) async -> Int {
        guard let pool = await ensureDatabase() else { return 0 }
        let cutoff = Date().timeIntervalSince1970 - cutoffAge
        do {
            return try await pool.write { db -> Int in
                if forceAllPending {
                    try db.execute(sql: """
                        UPDATE chat_coverage_state
                        SET last_error = NULL,
                            next_retry_at = NULL
                        WHERE last_error IS NOT NULL
                          AND last_error != ''
                        """)
                } else {
                    try db.execute(
                        sql: """
                            UPDATE chat_coverage_state
                            SET last_error = NULL,
                                next_retry_at = NULL
                            WHERE last_error IS NOT NULL
                              AND last_error != ''
                              AND (next_retry_at IS NULL OR next_retry_at < ?)
                            """,
                        arguments: [cutoff]
                    )
                }
                let reset = db.changesCount
                if reset > 0 {
                    print("[DatabaseManager] Cleared retry guard on \(reset) stuck coverage rows (failure_count preserved so adaptive params apply).")
                }
                return reset
            }
        } catch {
            print("[DatabaseManager] Reset coverage retry state failed: \(error)")
            return 0
        }
    }
}
