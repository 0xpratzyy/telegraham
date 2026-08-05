// DatabaseManager+Messages.swift
// Messages CRUD: live upserts, ranged/windowed loads, content updates, deletions.

import Foundation
import GRDB

extension DatabaseManager {
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

        // Structural close (#48): the user replying in this chat answers any
        // open reply-kind loop instantly — the Reply queue updates on send,
        // not on the next extraction pass.
        if ContextLayer.enabled, messages.contains(where: { $0.isOutgoing }) {
            let closed = await closeAnsweredReplyLoops(chatId: chatId)
            if closed > 0 {
                await MainActor.run {
                    NotificationCenter.default.post(name: .contextFactsChanged, object: nil)
                }
            }
        }
    }

    func loadMessages(chatId: Int64, limit: Int) async -> [MessageRecord] {
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing, source, thread_root_id
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

    /// Latest message per conversation in one SQLite read. Connected sources
    /// can expose hundreds of threads; loading them one-by-one delayed Gmail
    /// registration (and therefore extraction) behind a long actor queue.
    func loadLatestMessages(chatIds: [Int64]) async -> [Int64: MessageRecord] {
        guard !chatIds.isEmpty, let pool = await ensureDatabase() else { return [:] }
        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ",")
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, chat_id, sender_user_id, sender_name, date, text_content,
                               media_type, is_outgoing, source, thread_root_id
                        FROM (
                            SELECT id, chat_id, sender_user_id, sender_name, date, text_content,
                                   media_type, is_outgoing, source, thread_root_id,
                                   ROW_NUMBER() OVER (
                                       PARTITION BY chat_id
                                       ORDER BY date DESC, id DESC
                                   ) AS row_rank
                            FROM messages
                            WHERE chat_id IN (\(placeholders))
                        )
                        WHERE row_rank = 1
                        """,
                    arguments: StatementArguments(chatIds)
                )
                return Dictionary(
                    rows.map(Self.messageRecord(from:)).map { ($0.chatId, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        } catch {
            print("[DatabaseManager] Failed to load latest messages: \(error)")
            return [:]
        }
    }

    /// A local, newest-to-oldest page matching `MessageSource.chatHistory`.
    /// The cursor is resolved to its stored date first because synthetic source
    /// ids are stable identifiers, not a guarantee of chronological ordering.
    func loadMessageHistoryPage(chatId: Int64, beforeMessageId: Int64, limit: Int) async -> [MessageRecord] {
        guard limit > 0, let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                var arguments: StatementArguments = [chatId]
                var cursorClause = ""
                if beforeMessageId != 0 {
                    guard let anchor = try Row.fetchOne(
                        db,
                        sql: "SELECT date FROM messages WHERE chat_id = ? AND id = ?",
                        arguments: [chatId, beforeMessageId]
                    ), let anchorDate: Double = anchor["date"] else { return [] }
                    cursorClause = "AND (date < ? OR (date = ? AND id < ?))"
                    arguments += [anchorDate, anchorDate, beforeMessageId]
                }
                arguments += [limit]
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing, source, thread_root_id
                        FROM messages
                        WHERE chat_id = ?
                          \(cursorClause)
                        ORDER BY date DESC, id DESC
                        LIMIT ?
                        """,
                    arguments: arguments
                )
                return rows.map(Self.messageRecord(from:))
            }
        } catch {
            print("[DatabaseManager] Failed to load message history page for chat \(chatId): \(error)")
            return []
        }
    }

    /// Messages surrounding a source message (a few before and after) —
    /// the conversation around where a fact was extracted. Task Evidence uses
    /// this so it shows the RELEVANT lead-up, not the chat's latest unrelated
    /// chatter (the bug where an old task showed today's banter as "context").
    func loadMessagesAround(chatId: Int64, messageId: Int64, window: Int) async -> [MessageRecord] {
        guard let pool = await ensureDatabase() else { return [] }
        let cols = "id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing"
        do {
            return try await pool.read { db in
                guard let anchor = try Row.fetchOne(
                    db,
                    sql: "SELECT date FROM messages WHERE chat_id = ? AND id = ?",
                    arguments: [chatId, messageId]
                ),
                let anchorDate: Double = anchor["date"] else { return [] }
                // The source + `window` messages before it, and `window` after.
                let before = try Row.fetchAll(
                    db,
                    sql: "SELECT \(cols) FROM messages WHERE chat_id = ? AND (date < ? OR (date = ? AND id <= ?)) ORDER BY date DESC, id DESC LIMIT ?",
                    arguments: [chatId, anchorDate, anchorDate, messageId, window + 1]
                )
                let after = try Row.fetchAll(
                    db,
                    sql: "SELECT \(cols) FROM messages WHERE chat_id = ? AND (date > ? OR (date = ? AND id > ?)) ORDER BY date ASC, id ASC LIMIT ?",
                    arguments: [chatId, anchorDate, anchorDate, messageId, window]
                )
                return (before + after).map(Self.messageRecord(from:))
            }
        } catch {
            print("[DatabaseManager] loadMessagesAround failed for chat \(chatId): \(error)")
            return []
        }
    }

    /// Messages after the cursor and within the date window, oldest first. The
    /// cursor stores a stable message ID, but ordering follows its stored date:
    /// Gmail and other canonical providers use non-monotonic hashed IDs.
    func loadMessagesForward(chatId: Int64, afterMessageId: Int64, since: Date, limit: Int) async -> [MessageRecord] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                var cursorClause = ""
                var arguments: StatementArguments = [chatId]
                if afterMessageId != 0,
                   let anchor = try Row.fetchOne(
                       db,
                       sql: "SELECT date FROM messages WHERE chat_id = ? AND id = ?",
                       arguments: [chatId, afterMessageId]
                   ),
                   let anchorDate: Double = anchor["date"] {
                    // Canonical providers use stable hashed IDs (Gmail IDs are
                    // negative and deliberately non-monotonic). The cursor is
                    // still a message ID, but progression must follow the
                    // anchor's chronology rather than numeric ID ordering.
                    cursorClause = "AND (date > ? OR (date = ? AND id > ?))"
                    arguments += [anchorDate, anchorDate, afterMessageId]
                }
                arguments += [since.timeIntervalSince1970, limit]
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing, source, thread_root_id
                        FROM messages
                        WHERE chat_id = ?
                          \(cursorClause)
                          AND date >= ?
                        ORDER BY date ASC, id ASC
                        LIMIT ?
                        """,
                    arguments: arguments
                )
                return rows.map(Self.messageRecord(from:))
            }
        } catch {
            print("[DatabaseManager] loadMessagesForward failed for chat \(chatId): \(error)")
            return []
        }
    }

    /// The last `limit` already-processed messages at/before the extraction
    /// cursor — fed to extraction as read-only CONTEXT so a tiny new window
    /// (one terse ping) isn't judged blind. Returned chronologically.
    func loadMessagesBefore(chatId: Int64, throughMessageId: Int64, limit: Int) async -> [MessageRecord] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                var cursorClause = "AND id <= ?"
                var arguments: StatementArguments = [chatId, throughMessageId]
                if let anchor = try Row.fetchOne(
                    db,
                    sql: "SELECT date FROM messages WHERE chat_id = ? AND id = ?",
                    arguments: [chatId, throughMessageId]
                ),
                   let anchorDate: Double = anchor["date"] {
                    cursorClause = "AND (date < ? OR (date = ? AND id <= ?))"
                    arguments = [chatId, anchorDate, anchorDate, throughMessageId]
                }
                arguments += [limit]
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing, source, thread_root_id
                        FROM messages
                        WHERE chat_id = ?
                          \(cursorClause)
                        ORDER BY date DESC, id DESC
                        LIMIT ?
                        """,
                    arguments: arguments
                )
                return rows.map(Self.messageRecord(from:)).reversed()
            }
        } catch {
            print("[DatabaseManager] loadMessagesBefore failed for chat \(chatId): \(error)")
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
                        SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing, source, thread_root_id
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
                            SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing, source, thread_root_id
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
                            SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing, source, thread_root_id
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
                    // Old text must not linger in chunks or suppress re-embedding
                    // of the new text.
                    try Self.invalidateChunks(in: db, chatId: chatId, messageIds: [messageId])
                    try Self.deleteEmbeddingSkips(in: db, chatId: chatId, messageIds: [messageId])
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
                // Purge overlapping conversation chunks too (their text_preview
                // still holds the deleted text); embedding_skips clear via the
                // FK cascade when the message rows go.
                try Self.invalidateChunks(in: db, chatId: chatId, messageIds: messageIds)
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
                    sql: "DELETE FROM embedding_chunks WHERE chat_id = ?",
                    arguments: [chatId]
                )
                try db.execute(
                    sql: "DELETE FROM embedding_chunk_state WHERE chat_id = ?",
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
                            SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing, source, thread_root_id
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
}
