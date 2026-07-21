// DatabaseManager+Summaries.swift
// Entity summaries (rolling, bi-temporal): per-chat summary save/load/search.

import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Entity summaries (rolling, bi-temporal)

    /// The CURRENT rolling summary for a chat (superseded_at IS NULL), if any.
    func loadCurrentChatSummary(chatId: Int64) async -> EntitySummary? {
        guard let pool = await ensureDatabase() else { return nil }
        do {
            return try await pool.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM entity_summaries
                        WHERE entity_kind = 'chat' AND entity_id = ? AND superseded_at IS NULL
                        ORDER BY id DESC LIMIT 1
                        """,
                    arguments: [chatId]
                )
                return row.flatMap(Self.entitySummary(from:))
            }
        } catch {
            print("[DatabaseManager] loadCurrentChatSummary failed: \(error)")
            return nil
        }
    }

    /// Fold result: supersede the current summary row (kept as a dated
    /// snapshot) and insert the fresh one. One transaction.
    func saveChatSummary(chatId: Int64, title: String, summary: String, throughMessageId: Int64) async {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pool = await ensureDatabase() else { return }
        let now = Date().timeIntervalSince1970
        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                        UPDATE entity_summaries SET superseded_at = ?
                        WHERE entity_kind = 'chat' AND entity_id = ? AND superseded_at IS NULL
                        """,
                    arguments: [now, chatId]
                )
                try db.execute(
                    sql: """
                        INSERT INTO entity_summaries
                            (entity_kind, entity_id, entity_title, summary, through_message_id, valid_from, created_at)
                        VALUES ('chat', ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [chatId, title, trimmed, throughMessageId, now, now]
                )
            }
        } catch {
            print("[DatabaseManager] saveChatSummary failed: \(error)")
        }
    }

    /// Current summaries, freshest first — retrieval context for Ask Pidgy.
    /// Summaries whose entity TITLE matches any of the query's tokens — so
    /// asking about someone quiet ("whats up with vibhu") finds their summary
    /// even when it's far outside the newest-N recency window.
    func loadChatSummaries(matching tokens: [String], limit: Int = 6) async -> [EntitySummary] {
        let cleaned = tokens.map { $0.lowercased() }.filter { $0.count >= 3 }
        guard !cleaned.isEmpty, let pool = await ensureDatabase() else { return [] }
        let clauses = cleaned.map { _ in "lower(entity_title) LIKE ?" }.joined(separator: " OR ")
        var arguments = StatementArguments(cleaned.map { "%\($0)%" })
        arguments += [limit]
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM entity_summaries
                        WHERE entity_kind = 'chat' AND superseded_at IS NULL AND (\(clauses))
                        ORDER BY valid_from DESC LIMIT ?
                        """,
                    arguments: arguments
                )
                return rows.compactMap(Self.entitySummary(from:))
            }
        } catch {
            print("[DatabaseManager] loadChatSummaries(matching:) failed: \(error)")
            return []
        }
    }

    func loadRecentChatSummaries(limit: Int = 10) async -> [EntitySummary] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM entity_summaries
                        WHERE entity_kind = 'chat' AND superseded_at IS NULL
                        ORDER BY valid_from DESC LIMIT ?
                        """,
                    arguments: [limit]
                )
                return rows.compactMap(Self.entitySummary(from:))
            }
        } catch {
            print("[DatabaseManager] loadRecentChatSummaries failed: \(error)")
            return []
        }
    }

    private static func entitySummary(from row: Row) -> EntitySummary? {
        let superseded: Double? = row["superseded_at"]
        return EntitySummary(
            id: row["id"],
            entityKind: row["entity_kind"],
            entityId: row["entity_id"],
            entityTitle: row["entity_title"],
            summary: row["summary"],
            throughMessageId: row["through_message_id"],
            validFrom: Date(timeIntervalSince1970: row["valid_from"]),
            supersededAt: superseded.map(Date.init(timeIntervalSince1970:))
        )
    }
}
