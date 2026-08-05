// DatabaseManager+Embeddings.swift
// Conversation chunking + embedding pipeline state (chunk cursors, missing/skipped embeddings).

import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Conversation chunking

    /// Ordered message slice for the chunk builder — oldest first,
    /// strictly after `afterMessageId` (TDLib ids are monotonic within
    /// a chat).
    func messagesForChunking(
        chatId: Int64,
        afterMessageId: Int64,
        limit: Int
    ) async -> [ConversationChunker.Message] {
        guard limit > 0 else { return [] }
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, sender_name, text_content
                        FROM messages
                        WHERE chat_id = ? AND id > ?
                        ORDER BY id ASC
                        LIMIT ?
                        """,
                    arguments: [chatId, afterMessageId, limit]
                ).map { row in
                    ConversationChunker.Message(
                        id: row["id"],
                        senderName: row["sender_name"],
                        text: row["text_content"]
                    )
                }
            }
        } catch {
            print("[DatabaseManager] Failed to load messages for chunking: \(error)")
            return []
        }
    }

    /// Chats with messages newer than their chunked-through watermark
    /// for this model version, most recently active first.
    func chatsNeedingChunking(modelVersion: String, limit: Int) async -> [Int64] {
        guard limit > 0 else { return [] }
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT m.chat_id
                        FROM messages AS m
                        LEFT JOIN embedding_chunk_state AS s
                          ON s.chat_id = m.chat_id
                         AND s.model_version = ?
                        GROUP BY m.chat_id
                        HAVING MAX(m.id) > MAX(COALESCE(s.chunked_through_message_id, 0))
                        ORDER BY MAX(m.date) DESC
                        LIMIT ?
                        """,
                    arguments: [modelVersion, limit]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to find chats needing chunking: \(error)")
            return []
        }
    }

    func chunkState(chatId: Int64, modelVersion: String) async -> (coveredThrough: Int64, chunkedThrough: Int64) {
        guard let pool = await ensureDatabase() else { return (0, 0) }
        do {
            return try await pool.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT covered_through_message_id, chunked_through_message_id
                        FROM embedding_chunk_state
                        WHERE chat_id = ? AND model_version = ?
                        """,
                    arguments: [chatId, modelVersion]
                ) else { return (0, 0) }
                return (row["covered_through_message_id"], row["chunked_through_message_id"])
            }
        } catch {
            return (0, 0)
        }
    }

    func setChunkState(
        chatId: Int64,
        modelVersion: String,
        coveredThrough: Int64,
        chunkedThrough: Int64
    ) async {
        guard let pool = await ensureDatabase() else { return }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO embedding_chunk_state
                            (chat_id, model_version, covered_through_message_id, chunked_through_message_id, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(chat_id, model_version) DO UPDATE SET
                            covered_through_message_id = excluded.covered_through_message_id,
                            chunked_through_message_id = excluded.chunked_through_message_id,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [chatId, modelVersion, coveredThrough, chunkedThrough, Date().timeIntervalSince1970]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to set chunk state: \(error)")
        }
    }

    /// Messages without an embedding row for the given model version —
    /// a message embedded only by an OLDER model counts as missing, so
    /// model upgrades naturally re-embed the corpus through the normal
    /// backfill path.
    func messagesMissingEmbeddings(limit: Int, modelVersion: String) async -> [MessageRecord] {
        guard limit > 0 else { return [] }
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT m.id, m.chat_id, m.sender_user_id, m.sender_name, m.date, m.text_content, m.media_type, m.is_outgoing, m.source, m.thread_root_id
                        FROM messages AS m
                        LEFT JOIN embeddings AS e
                          ON e.message_id = m.id
                         AND e.chat_id = m.chat_id
                         AND e.model_version = ?
                        WHERE e.message_id IS NULL
                          AND m.text_content IS NOT NULL
                          AND length(trim(m.text_content)) >= ?
                          AND NOT EXISTS (
                              SELECT 1 FROM embedding_skips s
                              WHERE s.message_id = m.id
                                AND s.chat_id = m.chat_id
                                AND s.model_version = ?
                          )
                        LIMIT ?
                        """,
                    arguments: [modelVersion, AppConstants.Indexing.minEmbeddingTextLength, modelVersion, limit]
                )

                return rows.map(Self.messageRecord(from:))
            }
        } catch {
            print("[DatabaseManager] Failed to load messages missing embeddings: \(error)")
            return []
        }
    }

    /// Record messages the embedder couldn't vectorize (e.g. URL-only bodies
    /// that strip to empty) so `messagesMissingEmbeddings` stops re-selecting
    /// them every backfill pass. Cleared on message delete (FK cascade) or on
    /// a content edit (see updateMessageContent / insertMessages).
    func markEmbeddingSkipped(_ messages: [(id: Int64, chatId: Int64)], modelVersion: String) async {
        guard !messages.isEmpty else { return }
        guard let pool = await ensureDatabase() else { return }

        do {
            let now = Date().timeIntervalSince1970
            try await pool.write { db in
                for message in messages {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO embedding_skips
                                (chat_id, message_id, model_version, created_at)
                            VALUES (?, ?, ?, ?)
                            """,
                        arguments: [message.chatId, message.id, modelVersion, now]
                    )
                }
            }
        } catch {
            print("[DatabaseManager] Failed to mark embedding skips: \(error)")
        }
    }
}
