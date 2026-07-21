// DatabaseManager+Facts.swift
// Context layer (facts) — #48: fact store CRUD, loop lifecycle, fact queries, extraction cursors.

import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Context layer (facts) — #48

    /// Upsert facts. A LIVE fact is unique on `fingerprint` (partial index where
    /// invalid_at IS NULL): re-seeing the same loop refreshes its evidence; if
    /// only an INVALIDATED copy exists, a fresh live row is inserted (the loop
    /// re-opened). Fire-and-forget from the extraction pass.
    func upsertFacts(_ drafts: [FactDraft]) async {
        guard !drafts.isEmpty, let pool = await ensureDatabase() else { return }
        let now = Date().timeIntervalSince1970
        do {
            try await pool.write { db in
                for d in drafts {
                    try db.execute(
                        sql: """
                            INSERT INTO facts
                                (subject_entity, subject_person_id, predicate, object_text, action, loop_kind, object_entity,
                                 confidence, valid_from, invalid_at, source_chat_id, source_chat_title,
                                 source_message_id, source_text, sender_name, fingerprint,
                                 created_at, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(fingerprint) WHERE invalid_at IS NULL DO UPDATE SET
                                subject_entity = excluded.subject_entity,
                                subject_person_id = excluded.subject_person_id,
                                action = excluded.action,
                                loop_kind = COALESCE(excluded.loop_kind, facts.loop_kind),
                                source_chat_title = excluded.source_chat_title,
                                source_message_id = excluded.source_message_id,
                                source_text = excluded.source_text,
                                confidence = MAX(facts.confidence, excluded.confidence),
                                updated_at = excluded.updated_at
                            """,
                        arguments: [
                            d.subjectEntity, d.subjectPersonId, d.predicate.rawValue, d.objectText, d.action, d.loopKind?.rawValue, d.objectEntity,
                            d.confidence, d.validFrom.timeIntervalSince1970, d.sourceChatId, d.sourceChatTitle,
                            d.sourceMessageId, d.sourceText, d.senderName, d.fingerprint,
                            now, now
                        ]
                    )
                }
            }
        } catch {
            print("[DatabaseManager] upsertFacts failed: \(error)")
        }
    }

    /// Close open loops by fingerprint (bi-temporal: stamp invalid_at + WHY,
    /// keep the row). User-reason closes stay browsable in the Done tab.
    func invalidateFacts(fingerprints: [String], reason: FactCloseReason = .replied, at date: Date = Date()) async {
        guard !fingerprints.isEmpty, let pool = await ensureDatabase() else { return }
        let ts = date.timeIntervalSince1970
        let reasonRaw = reason.rawValue
        do {
            try await pool.write { db in
                for fp in fingerprints {
                    try db.execute(
                        sql: "UPDATE facts SET invalid_at = ?, closed_reason = ?, updated_at = ? WHERE fingerprint = ? AND invalid_at IS NULL",
                        arguments: [ts, reasonRaw, ts, fp]
                    )
                }
            }
        } catch {
            print("[DatabaseManager] invalidateFacts failed: \(error)")
        }
    }

    /// Structural close (#48): a REPLY-kind loop is an unanswered ping — ANY
    /// outgoing message in that chat after the loop's source message answers
    /// it. Deterministic (message ids + is_outgoing, never content), so
    /// crafted text can't forge a closure. Action-kind loops are untouched:
    /// saying "will do" doesn't complete the work. Chase-safe: a re-ask bumps
    /// source_message_id forward, so the reply clock resets with it.
    /// Returns how many loops were closed.
    func closeAnsweredReplyLoops(chatId: Int64? = nil) async -> Int {
        guard let pool = await ensureDatabase() else { return 0 }
        let now = Date().timeIntervalSince1970
        do {
            return try await pool.write { db in
                var sql = """
                    UPDATE facts SET invalid_at = ?, closed_reason = 'replied', updated_at = ?
                    WHERE invalid_at IS NULL AND predicate = 'i_owe' AND loop_kind = 'reply'
                      AND EXISTS (
                          SELECT 1 FROM messages m
                          WHERE m.chat_id = facts.source_chat_id
                            AND m.id > facts.source_message_id
                            AND m.is_outgoing = 1
                      )
                    """
                var arguments: [DatabaseValueConvertible] = [now, now]
                if let chatId {
                    sql += " AND source_chat_id = ?"
                    arguments.append(chatId)
                }
                try db.execute(sql: sql, arguments: StatementArguments(arguments))
                return db.changesCount
            }
        } catch {
            print("[DatabaseManager] closeAnsweredReplyLoops failed: \(error)")
            return 0
        }
    }

    /// A follow-up ping re-anchors an open loop onto the chase message — its
    /// rank date (valid_from), evidence text, and deep link all move to the
    /// latest ping, so a chased item surfaces instead of staying buried under
    /// its original ask date.
    func refreshChasedLoops(_ updates: [ChasedLoopUpdate]) async {
        guard !updates.isEmpty, let pool = await ensureDatabase() else { return }
        let now = Date().timeIntervalSince1970
        do {
            try await pool.write { db in
                for u in updates {
                    try db.execute(
                        sql: """
                            UPDATE facts
                            SET valid_from = ?, source_message_id = ?, source_text = ?, updated_at = ?
                            WHERE fingerprint = ? AND invalid_at IS NULL
                            """,
                        arguments: [u.date.timeIntervalSince1970, u.sourceMessageId, u.sourceText, now, u.fingerprint]
                    )
                }
            }
        } catch {
            print("[DatabaseManager] refreshChasedLoops failed: \(error)")
        }
    }

    /// Undo a user close: re-open the NEWEST invalidated fact for this
    /// fingerprint — but never when a live row with the same fingerprint already
    /// exists (the partial unique index on open facts would be violated, and the
    /// live loop already represents the task).
    func reopenFact(fingerprint: String) async {
        guard let pool = await ensureDatabase() else { return }
        let ts = Date().timeIntervalSince1970
        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                        UPDATE facts SET invalid_at = NULL, closed_reason = NULL, updated_at = ?
                        WHERE id = (
                            SELECT MAX(id) FROM facts f
                            WHERE f.fingerprint = ? AND f.invalid_at IS NOT NULL
                              AND NOT EXISTS (
                                  SELECT 1 FROM facts live
                                  WHERE live.fingerprint = f.fingerprint AND live.invalid_at IS NULL
                              )
                        )
                        """,
                    arguments: [ts, fingerprint]
                )
            }
        } catch {
            print("[DatabaseManager] reopenFact failed: \(error)")
        }
    }

    /// Loops the USER closed (done/ignored), newest first — the Tasks page's
    /// Done tab, so completed work has history and an accidental close is
    /// recoverable. Auto reply-closes are deliberately excluded (chat noise).
    func loadUserClosedFacts(limit: Int = 200) async -> [Fact] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM facts
                        WHERE invalid_at IS NOT NULL AND closed_reason IN ('user_done', 'user_ignored')
                        ORDER BY invalid_at DESC
                        LIMIT ?
                        """,
                    arguments: [limit]
                )
                return rows.compactMap(Self.fact(from:))
            }
        } catch {
            print("[DatabaseManager] loadUserClosedFacts failed: \(error)")
            return []
        }
    }

    /// Open i_owe loops not yet tagged reply/action — for the one-time backfill
    /// that populates the Reply queue / Tasks split on pre-existing facts.
    func loadUnclassifiedIOweLoops(limit: Int = 100) async -> [Fact] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM facts
                        WHERE invalid_at IS NULL AND predicate = 'i_owe' AND loop_kind IS NULL
                        ORDER BY valid_from DESC
                        LIMIT ?
                        """,
                    arguments: [limit]
                )
                return rows.compactMap(Self.fact(from:))
            }
        } catch {
            print("[DatabaseManager] loadUnclassifiedIOweLoops failed: \(error)")
            return []
        }
    }

    /// Apply backfilled loop_kind tags by fact id (only while still unclassified).
    func updateLoopKinds(_ kinds: [Int64: LoopKind]) async {
        guard !kinds.isEmpty, let pool = await ensureDatabase() else { return }
        let now = Date().timeIntervalSince1970
        do {
            try await pool.write { db in
                for (id, kind) in kinds {
                    try db.execute(
                        sql: "UPDATE facts SET loop_kind = ?, updated_at = ? WHERE id = ? AND loop_kind IS NULL",
                        arguments: [kind.rawValue, now, id]
                    )
                }
            }
        } catch {
            print("[DatabaseManager] updateLoopKinds failed: \(error)")
        }
    }

    /// Live facts with the given predicates (default: the open-loop ones that
    /// power tasks + reply queue), newest first. Predicate values are a fixed
    /// enum vocabulary, so they're inlined safely (no user input).
    func loadOpenFacts(predicates: [FactPredicate] = FactPredicate.openLoops, limit: Int = 500) async -> [Fact] {
        guard let pool = await ensureDatabase() else { return [] }
        let inList = predicates.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM facts
                        WHERE invalid_at IS NULL AND predicate IN (\(inList))
                        ORDER BY valid_from DESC
                        LIMIT ?
                        """,
                    arguments: [limit]
                )
                return rows.compactMap(Self.fact(from:))
            }
        } catch {
            print("[DatabaseManager] loadOpenFacts failed: \(error)")
            return []
        }
    }

    /// Open facts for one chat — passed to extraction as the current state so the
    /// model can resolve (close) loops a later message already answered.
    func loadOpenFacts(chatId: Int64) async -> [Fact] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM facts WHERE source_chat_id = ? AND invalid_at IS NULL ORDER BY valid_from DESC",
                    arguments: [chatId]
                )
                return rows.compactMap(Self.fact(from:))
            }
        } catch {
            print("[DatabaseManager] loadOpenFacts(chatId:) failed: \(error)")
            return []
        }
    }

    /// All facts (live + invalidated), newest-touched first — for the inspector.
    func loadRecentFacts(limit: Int = 400) async -> [Fact] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM facts ORDER BY updated_at DESC LIMIT ?",
                    arguments: [limit]
                )
                return rows.compactMap(Self.fact(from:))
            }
        } catch {
            print("[DatabaseManager] loadRecentFacts failed: \(error)")
            return []
        }
    }

    /// Counts for the inspector header: (total, open loops, resolved, chats touched).
    func factStoreStats() async -> (total: Int, openLoops: Int, resolved: Int, chats: Int) {
        guard let pool = await ensureDatabase() else { return (0, 0, 0, 0) }
        do {
            return try await pool.read { db in
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facts") ?? 0
                let open = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facts WHERE invalid_at IS NULL AND predicate IN ('i_owe','owes_me')") ?? 0
                let resolved = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facts WHERE invalid_at IS NOT NULL") ?? 0
                let chats = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT source_chat_id) FROM facts") ?? 0
                return (total, open, resolved, chats)
            }
        } catch {
            return (0, 0, 0, 0)
        }
    }

    /// Global name → id directory source: every (sender id, name) ever seen in
    /// any chat, with frequency, for the context layer's entity resolver.
    func loadContactDirectory() async -> [(id: Int64, name: String, count: Int)] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT sender_user_id AS id, sender_name AS name, COUNT(*) AS c
                        FROM messages
                        WHERE sender_user_id IS NOT NULL AND sender_name IS NOT NULL AND sender_name <> ''
                        GROUP BY sender_user_id, sender_name
                        """
                )
                return rows.map { row in
                    (id: row["id"] as Int64, name: row["name"] as String, count: row["c"] as Int)
                }
            }
        } catch {
            print("[DatabaseManager] loadContactDirectory failed: \(error)")
            return []
        }
    }

    /// Full-text search over LIVE facts (open loops + durable facts), BM25-ranked.
    /// Powers the "Facts" section in search — "what do I owe Akhil", "Saperly".
    /// Two-tier facts search. Tier 1 anchors on WHO the query names: the same
    /// OR-match, but only against identity columns (subject_entity +
    /// source_chat_title) — "akhil ke saath kya chal rha" returns ONLY Akhil's
    /// facts instead of every fact whose raw source_text contains a filler
    /// token (kya/chal/rha). Tier 2 (no identity hit → the query is about
    /// CONTENT, e.g. "hetzner invoice") keeps the recall-over-precision
    /// full-text OR-match, re-ranked so identity/object columns outweigh raw
    /// message text. `identityTerms` lets the AI query planner refine tier 1
    /// with parsed people (multilingual — it transliterates scripts the FTS
    /// tokenizer can't).
    /// `identityOnly` skips the tier-2 content fallback entirely — the
    /// launcher's FACTS section uses it so facts appear only when the query
    /// actually NAMES a person/chat ("whats up with vibhu" must not surface
    /// every "Follow up with…" action via the up/with tokens).
    func searchFacts(query: String, identityTerms: [String] = [], identityOnly: Bool = false, limit: Int = 20) async -> [Fact] {
        guard let pool = await ensureDatabase() else { return [] }
        let tokenize: (String) -> [String] = { text in
            text.split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 2 }
        }
        let queryTerms = tokenize(query)
        let identity = identityTerms.flatMap(tokenize)
        let tier1Terms = identity.isEmpty ? queryTerms : identity
        guard !queryTerms.isEmpty || !tier1Terms.isEmpty else { return [] }
        // facts_fts column order: subject_entity, object_text, action,
        // source_text, source_chat_title. Weights sink raw-message matches.
        let weightedRank = "bm25(facts_fts, 10.0, 4.0, 4.0, 1.0, 8.0)"

        func run(_ match: String) async -> [Fact] {
            do {
                return try await pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT f.* FROM facts_fts
                            JOIN facts f ON f.id = facts_fts.rowid
                            WHERE facts_fts MATCH ? AND f.invalid_at IS NULL
                            ORDER BY \(weightedRank), f.valid_from DESC
                            LIMIT ?
                            """,
                        arguments: [match, limit]
                    )
                    return rows.compactMap(Self.fact(from:))
                }
            } catch {
                print("[DatabaseManager] searchFacts failed: \(error)")
                return []
            }
        }

        if !tier1Terms.isEmpty {
            let identityMatch = "{subject_entity source_chat_title} : ("
                + tier1Terms.map { "\"\($0)\"" }.joined(separator: " OR ") + ")"
            let hits = await run(identityMatch)
            if !hits.isEmpty { return hits }
        }
        guard !identityOnly, !queryTerms.isEmpty else { return [] }
        return await run(queryTerms.map { "\"\($0)\"" }.joined(separator: " OR "))
    }

    /// Live durable (non-open-loop) facts about resolved people — background
    /// context for the answer engine. Newest first.
    func loadDurableFacts(limit: Int = 50) async -> [Fact] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM facts
                        WHERE invalid_at IS NULL
                          AND predicate NOT IN ('i_owe','owes_me')
                          AND subject_person_id IS NOT NULL
                        ORDER BY valid_from DESC
                        LIMIT ?
                        """,
                    arguments: [limit]
                )
                return rows.compactMap(Self.fact(from:))
            }
        } catch {
            print("[DatabaseManager] loadDurableFacts failed: \(error)")
            return []
        }
    }

    /// Live facts about a specific person (by resolved Telegram id) — for the
    /// People page. Open loops first, then durable facts, newest-first.
    func loadFactsForPerson(personId: Int64, limit: Int = 50) async -> [Fact] {
        guard personId != 0, let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM facts
                        WHERE subject_person_id = ? AND invalid_at IS NULL
                        ORDER BY (predicate IN ('i_owe','owes_me')) DESC, valid_from DESC
                        LIMIT ?
                        """,
                    arguments: [personId, limit]
                )
                return rows.compactMap(Self.fact(from:))
            }
        } catch {
            print("[DatabaseManager] loadFactsForPerson failed: \(error)")
            return []
        }
    }

    func factExtractionCursor(chatId: Int64) async -> Int64 {
        guard let pool = await ensureDatabase() else { return 0 }
        do {
            return try await pool.read { db in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT extracted_through_message_id FROM fact_extraction_state WHERE chat_id = ?",
                    arguments: [chatId]
                ) ?? 0
            }
        } catch { return 0 }
    }

    func updateFactExtractionCursor(chatId: Int64, throughMessageId: Int64, at date: Date = Date()) async {
        guard let pool = await ensureDatabase() else { return }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO fact_extraction_state (chat_id, extracted_through_message_id, last_extracted_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(chat_id) DO UPDATE SET
                            extracted_through_message_id = MAX(fact_extraction_state.extracted_through_message_id, excluded.extracted_through_message_id),
                            last_extracted_at = excluded.last_extracted_at
                        """,
                    arguments: [chatId, throughMessageId, date.timeIntervalSince1970]
                )
            }
        } catch {
            print("[DatabaseManager] updateFactExtractionCursor failed: \(error)")
        }
    }

    static func fact(from row: Row) -> Fact? {
        guard let predicate = FactPredicate(rawValue: row["predicate"]) else { return nil }
        let invalidAt: Double? = row["invalid_at"]
        return Fact(
            id: row["id"],
            subjectEntity: row["subject_entity"],
            subjectPersonId: row["subject_person_id"],
            predicate: predicate,
            objectText: row["object_text"],
            action: row["action"],
            loopKind: (row["loop_kind"] as String?).flatMap(LoopKind.init(rawValue:)),
            objectEntity: row["object_entity"],
            confidence: row["confidence"],
            validFrom: Date(timeIntervalSince1970: row["valid_from"]),
            invalidAt: invalidAt.map(Date.init(timeIntervalSince1970:)),
            closeReason: (row["closed_reason"] as String?).flatMap(FactCloseReason.init(rawValue:)),
            sourceChatId: row["source_chat_id"],
            sourceChatTitle: row["source_chat_title"],
            sourceMessageId: row["source_message_id"],
            sourceText: row["source_text"],
            senderName: row["sender_name"],
            fingerprint: row["fingerprint"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }
}
