// DatabaseManager+Search.swift
// Local FTS search over the message corpus and search-support queries.

import Foundation
import GRDB

extension DatabaseManager {
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

    /// Tokens appearing in at least `minDocShare` of all messages —
    /// the corpus's own function words, in whatever languages the user
    /// chats in. Computed from the FTS5 vocabulary (cheap, indexed).
    /// The fts5vocab temp table is per-connection, so create + query
    /// happen inside one read closure.
    func corpusHighFrequencyTokens(minDocShare: Double) async -> Set<String> {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS temp.messages_fts_vocab
                    USING fts5vocab(main, 'messages_fts', 'row')
                    """)
                let totalDocs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts") ?? 0
                guard totalDocs > 0 else { return [] }
                let minDocs = max(1, Int(Double(totalDocs) * minDocShare))
                let terms = try String.fetchAll(
                    db,
                    sql: "SELECT term FROM temp.messages_fts_vocab WHERE doc >= ?",
                    arguments: [minDocs]
                )
                return Set(terms)
            }
        } catch {
            print("[DatabaseManager] Failed to compute corpus stopwords: \(error)")
            return []
        }
    }
}
