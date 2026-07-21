// DatabaseManager+People.swift
// Person profiles and per-person message stats/backfills.

import Foundation
import GRDB

extension DatabaseManager {
    func loadPersonProfile(userId: Int64) async -> PersonProfileRecord? {
        guard let pool = await ensureDatabase() else { return nil }
        do {
            return try await pool.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT user_id, summary, version, message_count_at_extraction, last_extracted_at
                        FROM person_profiles
                        WHERE user_id = ?
                        """,
                    arguments: [userId]
                ) else { return nil }
                return Self.personProfileRecord(from: row)
            }
        } catch {
            print("[DatabaseManager] Failed to load person profile for \(userId): \(error)")
            return nil
        }
    }

    func upsertPersonProfile(
        userId: Int64,
        summary: String,
        messageCountAtExtraction: Int
    ) async {
        guard let pool = await ensureDatabase() else { return }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO person_profiles
                            (user_id, summary, version, message_count_at_extraction, last_extracted_at)
                        VALUES (?, ?, 1, ?, ?)
                        ON CONFLICT(user_id) DO UPDATE SET
                            summary = excluded.summary,
                            version = person_profiles.version + 1,
                            message_count_at_extraction = excluded.message_count_at_extraction,
                            last_extracted_at = excluded.last_extracted_at
                        """,
                    arguments: [
                        userId,
                        summary,
                        messageCountAtExtraction,
                        Date().timeIntervalSince1970
                    ]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to upsert person profile for \(userId): \(error)")
        }
    }

    /// Count of messages where this user is the sender (excludes outgoing
    /// messages from the current user). Used to decide whether a cached
    /// profile is stale enough to re-extract.
    func messageCountForSender(userId: Int64) async -> Int {
        guard let pool = await ensureDatabase() else { return 0 }
        do {
            return try await pool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE sender_user_id = ?",
                    arguments: [userId]
                ) ?? 0
            }
        } catch {
            return 0
        }
    }

    /// Count of the user's own outgoing text messages — the sample size for
    /// the voice profile, and the staleness signal for re-generating it.
    func outgoingMessageCount() async -> Int {
        guard let pool = await ensureDatabase() else { return 0 }
        do {
            return try await pool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE is_outgoing = 1 AND text_content IS NOT NULL AND length(trim(text_content)) >= 2",
                    arguments: []
                ) ?? 0
            }
        } catch {
            return 0
        }
    }

    /// The user's own most-recent outgoing text messages across all chats —
    /// source material for the voice profile (how they write).
    func loadRecentOutgoingMessages(limit: Int = 120) async -> [MessageRecord] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing
                        FROM messages
                        WHERE is_outgoing = 1
                          AND text_content IS NOT NULL
                          AND length(trim(text_content)) >= 2
                        ORDER BY date DESC, id DESC
                        LIMIT ?
                        """,
                    arguments: [limit]
                )
                return rows.map { Self.messageRecord(from: $0) }
            }
        } catch {
            print("[DatabaseManager] Failed to load outgoing messages: \(error)")
            return []
        }
    }

    /// Recent messages where this user appears as the sender, across all
    /// chats. Used as the source material for profile extraction.
    func loadRecentMessages(fromSender userId: Int64, limit: Int = 50) async -> [MessageRecord] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, chat_id, sender_user_id, sender_name, date, text_content, media_type, is_outgoing
                        FROM messages
                        WHERE sender_user_id = ?
                        ORDER BY date DESC, id DESC
                        LIMIT ?
                        """,
                    arguments: [userId, limit]
                )
                return rows.map { Self.messageRecord(from: $0) }
            }
        } catch {
            print("[DatabaseManager] Failed to load messages for sender \(userId): \(error)")
            return []
        }
    }

    /// One-shot idempotent backfill that creates a `nodes` row for every
    /// distinct non-outgoing sender already present in the `messages`
    /// table. Closes the gap between MajorChatCoverageCoordinator
    /// (which only fully covers recent + small + DM-style chats — ~80
    /// out of ~1,600 in a typical Telegram account) and the People
    /// page, which wants to surface every contact the user has ever
    /// conversed with.
    ///
    /// Cheap because it runs entirely on the local DB — no TDLib calls,
    /// no AI, no embeddings, no rate-limit risk. Uses INSERT OR IGNORE
    /// so existing (richer) nodes written by GraphBuilder aren't
    /// overwritten with thinner derived data.
    ///
    /// Returns the count of newly-inserted nodes so callers can log it.
    @discardableResult
    func backfillPersonNodesFromMessages() async -> Int {
        guard let pool = await ensureDatabase() else { return 0 }
        do {
            return try await pool.write { db -> Int in
                let before = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM nodes WHERE entity_type = 'user'"
                ) ?? 0

                try db.execute(sql: """
                    INSERT OR IGNORE INTO nodes
                        (entity_id, entity_type, display_name, username,
                         category, category_source, interaction_score,
                         last_interaction_at, first_seen_at, metadata)
                    SELECT
                        sender_user_id,
                        'user',
                        COALESCE(NULLIF(MAX(sender_name), ''), 'Contact'),
                        NULL,
                        '\(AppConstants.Graph.defaultCategory)',
                        '\(AppConstants.Graph.automaticCategorySource)',
                        CAST(COUNT(*) AS REAL),
                        MAX(date),
                        MIN(date),
                        NULL
                    FROM messages
                    WHERE sender_user_id IS NOT NULL
                      AND sender_user_id > 0
                      AND is_outgoing = 0
                    GROUP BY sender_user_id
                    """)

                let after = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM nodes WHERE entity_type = 'user'"
                ) ?? 0

                let inserted = after - before
                if inserted > 0 {
                    print("[DatabaseManager] Backfilled \(inserted) person nodes from message history (now \(after) total).")
                }
                return inserted
            }
        } catch {
            print("[DatabaseManager] Person-node backfill failed: \(error)")
            return 0
        }
    }

    private static func personProfileRecord(from row: Row) -> PersonProfileRecord {
        let timestamp: Double = row["last_extracted_at"] ?? 0
        return PersonProfileRecord(
            userId: row["user_id"],
            summary: row["summary"] ?? "",
            version: row["version"] ?? 1,
            messageCountAtExtraction: row["message_count_at_extraction"] ?? 0,
            lastExtractedAt: Date(timeIntervalSince1970: timestamp)
        )
    }
}
