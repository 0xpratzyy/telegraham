// DatabaseManager+Facts.swift
// Context layer (facts) — #48: fact store CRUD, loop lifecycle, fact queries, extraction cursors.

import Foundation
import GRDB

/// Thrown by the throwing fact-store writes when the database handle is
/// gone (closed mid-shutdown / reset) — callers must NOT advance cursors.
struct FactStoreUnavailableError: Error {}

extension DatabaseManager {
    // MARK: - Context layer (facts) — #48

    /// Provenance keys already seen at any point in fact history. Callers use
    /// the full history (not only live facts) so an upgrade backfill cannot
    /// reopen work the user already completed or dismissed.
    func existingFactSourceMessageIDs(chatId: Int64, messageIds: [Int64]) async -> Set<Int64> {
        guard !messageIds.isEmpty, let pool = await ensureDatabase() else { return [] }
        let placeholders = Array(repeating: "?", count: messageIds.count).joined(separator: ",")
        do {
            return try await pool.read { db in
                var arguments: StatementArguments = [chatId]
                for messageId in messageIds { arguments += [messageId] }
                return Set(try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT source_message_id
                        FROM facts
                        WHERE source_chat_id = ?
                          AND source_message_id IN (\(placeholders))
                        """,
                    arguments: arguments
                ))
            }
        } catch {
            print("[DatabaseManager] existingFactSourceMessageIDs failed: \(error)")
            return []
        }
    }

    /// Upsert facts. A LIVE fact is unique on `fingerprint` (partial index where
    /// invalid_at IS NULL): re-seeing the same loop refreshes its evidence; if
    /// only an INVALIDATED copy exists, a fresh live row is inserted (the loop
    /// re-opened). Fire-and-forget (backfills/tests) — the extraction pass
    /// itself commits through applyExtractionWindow instead.
    func upsertFacts(_ drafts: [FactDraft]) async {
        guard !drafts.isEmpty, let pool = await ensureDatabase() else { return }
        let now = Date().timeIntervalSince1970
        do {
            try await pool.write { db in
                for d in drafts {
                    try Self.executeFactUpsert(db, draft: d, now: now)
                }
                _ = try Self.executeFactProvenanceRepair(db, ts: now)
                _ = try Self.executeGmailTaskRepair(db, ts: now)
            }
        } catch {
            print("[DatabaseManager] upsertFacts failed: \(error)")
        }
    }

    /// Atomically commit ONE extraction window: loop closes, fact upserts,
    /// chase bumps, and the cursor advance land in a single transaction — or
    /// none of them do. THROWS on failure so the caller leaves the cursor
    /// where it was and retries the whole window next pass. The old
    /// fire-and-forget split (upsert swallowed its error, cursor advanced
    /// anyway) let one transient DB hiccup permanently skip a window.
    func applyExtractionWindow(
        chatId: Int64,
        closeFingerprints: [String],
        upserts: [FactDraft],
        chases: [ChasedLoopUpdate],
        advanceCursorTo throughMessageId: Int64
    ) async throws {
        guard let pool = await ensureDatabase() else { throw FactStoreUnavailableError() }
        let now = Date().timeIntervalSince1970
        try await pool.write { db in
            // Close BEFORE upserting — a re-ask in this window can carry the
            // same fingerprint as the loop being closed; invalidating first
            // lets the new draft insert as a fresh live row.
            for fp in closeFingerprints {
                try Self.executeFactInvalidate(db, fingerprint: fp, reason: .replied, ts: now)
            }
            for d in upserts {
                try Self.executeFactUpsert(db, draft: d, now: now)
            }
            _ = try Self.executeFactProvenanceRepair(db, ts: now)
            _ = try Self.executeGmailTaskRepair(db, ts: now)
            for u in chases {
                try Self.executeChaseRefresh(db, update: u, now: now)
            }
            try db.execute(
                sql: """
                    INSERT INTO fact_extraction_state (chat_id, extracted_through_message_id, last_extracted_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(chat_id) DO UPDATE SET
                        extracted_through_message_id = excluded.extracted_through_message_id,
                        last_extracted_at = excluded.last_extracted_at
                    """,
                arguments: [chatId, throughMessageId, now]
            )
        }
    }

    /// Chats whose LOCAL history is complete enough to extract: the coverage
    /// coordinator verified the window (`oldest_covered_at <= cutoff`) or the
    /// local messages already span back past the cutoff. Extraction must not
    /// run ahead of backfill — its cursor is a high-water mark, and messages
    /// backfilled BELOW an already-advanced cursor would never be read
    /// (fresh-install bug: half the history silently skipped).
    func syncReadyChatIdsForExtraction(chatIds: [Int64], cutoff: Date) async -> Set<Int64> {
        guard !chatIds.isEmpty, let pool = await ensureDatabase() else { return [] }
        let ts = cutoff.timeIntervalSince1970
        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ",")
        do {
            let ids = try await pool.read { db in
                try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT m.chat_id
                        FROM messages m
                        LEFT JOIN chat_coverage_state c ON c.chat_id = m.chat_id
                        WHERE m.chat_id IN (\(placeholders))
                        GROUP BY m.chat_id
                        HAVING MIN(m.date) <= ? OR COALESCE(MAX(c.oldest_covered_at), 9e18) <= ?
                        """,
                    arguments: StatementArguments(chatIds.map { $0 as DatabaseValueConvertible } + [ts, ts])
                )
            }
            return Set(ids)
        } catch {
            print("[DatabaseManager] syncReadyChatIdsForExtraction failed: \(error)")
            // Fail OPEN (all ready): a broken gate must degrade to the old
            // behavior, not silently freeze extraction.
            return Set(chatIds)
        }
    }

    private static func executeFactUpsert(_ db: Database, draft d: FactDraft, now: Double) throws {
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
                    source_chat_id = excluded.source_chat_id,
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

    private static func executeFactInvalidate(_ db: Database, fingerprint: String, reason: FactCloseReason, ts: Double) throws {
        try db.execute(
            sql: "UPDATE facts SET invalid_at = ?, closed_reason = ?, updated_at = ? WHERE fingerprint = ? AND invalid_at IS NULL",
            arguments: [ts, reason.rawValue, ts, fingerprint]
        )
    }

    /// Re-seeing one semantic loop in a newer conversation moves its evidence
    /// to the newer message. Older builds updated `source_message_id` but left
    /// `source_chat_id` behind, producing an impossible composite provenance
    /// pair: the task existed in `facts`, yet neither Tasks nor the benchmark
    /// could join it back to Gmail. Repair only when the message id identifies
    /// exactly one stored chat; Telegram message ids are chat-local and are
    /// deliberately left untouched when ambiguous.
    private static func executeFactProvenanceRepair(_ db: Database, ts: Double) throws -> Int {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT f.id AS fact_id, m.chat_id AS repaired_chat_id,
                       COALESCE(sc.title, f.source_chat_title) AS repaired_chat_title
                FROM facts f
                INNER JOIN messages m ON m.id = f.source_message_id
                LEFT JOIN source_conversations sc ON sc.id = m.conversation_id
                WHERE m.chat_id != f.source_chat_id
                  AND NOT EXISTS (
                      SELECT 1 FROM messages exact
                      WHERE exact.id = f.source_message_id
                        AND exact.chat_id = f.source_chat_id
                  )
                  AND (
                      SELECT COUNT(DISTINCT candidate.chat_id)
                      FROM messages candidate
                      WHERE candidate.id = f.source_message_id
                  ) = 1
                """
        )

        var repaired = 0
        for row in rows {
            let factID: Int64 = row["fact_id"]
            let chatID: Int64 = row["repaired_chat_id"]
            let chatTitle: String = row["repaired_chat_title"]
            try db.execute(
                sql: """
                    UPDATE facts
                    SET source_chat_id = ?, source_chat_title = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [chatID, chatTitle, ts, factID]
            )
            repaired += db.changesCount
        }
        return repaired
    }

    /// Enforce one live Task per Gmail source message. Fact fingerprints stay
    /// semantic for every other source; Gmail gets this additional provenance
    /// invariant because one email is one unit of work even when the model
    /// paraphrases its obligation across extraction passes.
    private static func executeGmailTaskRepair(_ db: Database, ts: Double) throws -> Int {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT f.*
                FROM facts f
                INNER JOIN messages m
                    ON m.chat_id = f.source_chat_id
                   AND m.id = f.source_message_id
                WHERE f.invalid_at IS NULL
                  AND f.predicate = 'i_owe'
                  AND COALESCE(f.loop_kind, 'action') != 'reply'
                  AND (m.source = 'gmail' OR m.source LIKE 'gmail:%')
                ORDER BY f.created_at ASC, f.id ASC
                """
        )
        let facts = rows.compactMap(Self.fact(from:))
        let grouped = Dictionary(grouping: facts) {
            GmailSourceKey(chatId: $0.sourceChatId, messageId: $0.sourceMessageId)
        }

        var repaired = 0
        for duplicates in grouped.values where duplicates.count > 1 {
            guard let canonical = GmailTaskCanonicalization.preferredFact(in: duplicates) else { continue }
            for duplicate in duplicates where duplicate.id != canonical.id {
                try db.execute(
                    sql: """
                        UPDATE facts
                        SET invalid_at = ?, closed_reason = ?, updated_at = ?
                        WHERE id = ? AND invalid_at IS NULL
                        """,
                    arguments: [ts, FactCloseReason.deduplicated.rawValue, ts, duplicate.id]
                )
                repaired += db.changesCount
            }
        }
        return repaired
    }

    /// Repairs rows written by older builds. Invalidated duplicates remain in
    /// the bi-temporal fact history; only the poorer live projection closes.
    func repairDuplicateOpenGmailTasks(at date: Date = Date()) async -> Int {
        guard let pool = await ensureDatabase() else { return 0 }
        do {
            return try await pool.write { db in
                let ts = date.timeIntervalSince1970
                let provenance = try Self.executeFactProvenanceRepair(db, ts: ts)
                let duplicates = try Self.executeGmailTaskRepair(db, ts: ts)
                return provenance + duplicates
            }
        } catch {
            print("[DatabaseManager] repairDuplicateOpenGmailTasks failed: \(error)")
            return 0
        }
    }

    private struct GmailSourceKey: Hashable {
        let chatId: Int64
        let messageId: Int64
    }

    private static func executeChaseRefresh(_ db: Database, update u: ChasedLoopUpdate, now: Double) throws {
        try db.execute(
            sql: """
                UPDATE facts
                SET valid_from = ?, source_message_id = ?, source_text = ?, updated_at = ?
                WHERE fingerprint = ? AND invalid_at IS NULL
                """,
            arguments: [u.date.timeIntervalSince1970, u.sourceMessageId, u.sourceText, now, u.fingerprint]
        )
    }

    /// Close open loops by fingerprint (bi-temporal: stamp invalid_at + WHY,
    /// keep the row). User-reason closes stay browsable in the Done tab.
    func invalidateFacts(fingerprints: [String], reason: FactCloseReason = .replied, at date: Date = Date()) async {
        guard !fingerprints.isEmpty, let pool = await ensureDatabase() else { return }
        let ts = date.timeIntervalSince1970
        do {
            try await pool.write { db in
                for fp in fingerprints {
                    try Self.executeFactInvalidate(db, fingerprint: fp, reason: reason, ts: ts)
                }
            }
        } catch {
            print("[DatabaseManager] invalidateFacts failed: \(error)")
        }
    }

    /// Fast close for a REPLY-kind loop after the user's first response. A
    /// deferral ("wait, let me check") deliberately does not count as an
    /// answer; later unrelated messages cannot close it because only the first
    /// outgoing response is considered. Action-kind loops are untouched.
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
                          SELECT 1
                          FROM messages m
                          WHERE m.id = (
                              SELECT first_reply.id
                              FROM messages first_reply
                              WHERE first_reply.chat_id = facts.source_chat_id
                                AND first_reply.is_outgoing = 1
                                AND (
                                    EXISTS (
                                        SELECT 1 FROM messages source
                                        WHERE source.chat_id = facts.source_chat_id
                                          AND source.id = facts.source_message_id
                                          AND (
                                              first_reply.date > source.date
                                              OR (first_reply.date = source.date AND first_reply.id > source.id)
                                          )
                                    )
                                    OR (
                                        NOT EXISTS (
                                            SELECT 1 FROM messages source
                                            WHERE source.chat_id = facts.source_chat_id
                                              AND source.id = facts.source_message_id
                                        )
                                        AND first_reply.id > facts.source_message_id
                                    )
                                )
                              ORDER BY first_reply.date ASC, first_reply.id ASC
                              LIMIT 1
                          )
                            AND LOWER(TRIM(COALESCE(m.text_content, ''))) NOT LIKE 'wait%'
                            AND LOWER(TRIM(COALESCE(m.text_content, ''))) NOT LIKE '%lemme check%'
                            AND LOWER(TRIM(COALESCE(m.text_content, ''))) NOT LIKE '%let me check%'
                            AND LOWER(TRIM(COALESCE(m.text_content, ''))) NOT LIKE 'i will check%'
                            AND LOWER(TRIM(COALESCE(m.text_content, ''))) NOT LIKE 'i''ll check%'
                            AND LOWER(TRIM(COALESCE(m.text_content, ''))) NOT LIKE 'will check%'
                            AND LOWER(TRIM(COALESCE(m.text_content, ''))) NOT LIKE 'checking%'
                            AND LOWER(TRIM(COALESCE(m.text_content, ''))) NOT LIKE '%get back%'
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

    /// Heal existing Slack facts created before the answerable-question lane
    /// correction. The source itself must be question-shaped and the model's
    /// action must explicitly be a check/confirmation; concrete work stays a
    /// Task. Returns the number moved into Reply queue.
    func repairSlackQuestionLoopKinds() async -> Int {
        guard let pool = await ensureDatabase() else { return 0 }
        let now = Date().timeIntervalSince1970
        do {
            return try await pool.write { db in
                try db.execute(
                    sql: """
                        UPDATE facts
                        SET loop_kind = 'reply', updated_at = ?
                        WHERE id IN (
                            SELECT f.id
                            FROM facts f
                            INNER JOIN messages m
                                ON m.chat_id = f.source_chat_id
                               AND m.id = f.source_message_id
                            WHERE f.invalid_at IS NULL
                              AND f.predicate = 'i_owe'
                              AND COALESCE(f.loop_kind, 'action') = 'action'
                              AND (m.source = 'slack' OR m.source LIKE 'slack:%')
                              AND (
                                  INSTR(LOWER(f.source_text), '?') > 0
                                  OR LOWER(f.source_text) LIKE '% kya%'
                              )
                              AND (
                                  LOWER(f.action) LIKE 'check if %'
                                  OR LOWER(f.action) LIKE 'check whether %'
                                  OR LOWER(f.action) LIKE 'confirm if %'
                                  OR LOWER(f.action) LIKE 'confirm whether %'
                              )
                        )
                        """,
                    arguments: [now]
                )
                return db.changesCount
            }
        } catch {
            print("[DatabaseManager] repairSlackQuestionLoopKinds failed: \(error)")
            return 0
        }
    }

    /// Standup participation/leadership asks are same-day work, not durable
    /// backlog. Close only a narrow set of Slack action titles after 48 hours;
    /// broader review, preparation, and deliverable tasks remain untouched.
    func closeExpiredEphemeralSlackTasks(referenceDate: Date = Date()) async -> Int {
        guard let pool = await ensureDatabase() else { return 0 }
        let now = referenceDate.timeIntervalSince1970
        let cutoff = referenceDate.addingTimeInterval(-48 * 60 * 60).timeIntervalSince1970
        do {
            return try await pool.write { db in
                try db.execute(
                    sql: """
                        UPDATE facts
                        SET invalid_at = ?, closed_reason = ?, updated_at = ?
                        WHERE id IN (
                            SELECT f.id
                            FROM facts f
                            INNER JOIN messages m
                                ON m.chat_id = f.source_chat_id
                               AND m.id = f.source_message_id
                            WHERE f.invalid_at IS NULL
                              AND f.predicate = 'i_owe'
                              AND COALESCE(f.loop_kind, 'action') = 'action'
                              AND f.valid_from < ?
                              AND (m.source = 'slack' OR m.source LIKE 'slack:%')
                              AND (
                                  LOWER(f.action) LIKE 'lead%standup%'
                                  OR LOWER(f.action) LIKE 'run%standup%'
                                  OR LOWER(f.action) LIKE 'host%standup%'
                                  OR LOWER(f.action) LIKE 'join%standup%'
                              )
                        )
                        """,
                    arguments: [now, FactCloseReason.expired.rawValue, now, cutoff]
                )
                return db.changesCount
            }
        } catch {
            print("[DatabaseManager] closeExpiredEphemeralSlackTasks failed: \(error)")
            return 0
        }
    }

    /// Close a Slack task when its own thread contains visible delivery from
    /// the user. This is deliberately narrower than generic "a later outgoing
    /// message exists": acknowledgements and promises do not complete work.
    /// Explicit completion language is enough for every task; requests to
    /// share/provide/send/upload something also close when the user supplies a
    /// substantive non-deferral reply in that thread.
    func closeCompletedSlackThreadTasks(chatId: Int64? = nil) async -> Int {
        guard let pool = await ensureDatabase() else { return 0 }
        let now = Date().timeIntervalSince1970
        do {
            return try await pool.write { db in
                var sql = """
                    UPDATE facts SET invalid_at = ?, closed_reason = 'replied', updated_at = ?
                    WHERE invalid_at IS NULL
                      AND predicate = 'i_owe'
                      AND COALESCE(loop_kind, 'action') = 'action'
                      AND EXISTS (
                          SELECT 1
                          FROM messages source
                          WHERE source.chat_id = facts.source_chat_id
                            AND source.id = facts.source_message_id
                            AND (source.source = 'slack' OR source.source LIKE 'slack:%')
                      )
                      AND EXISTS (
                          SELECT 1
                          FROM messages reply
                          WHERE reply.chat_id = facts.source_chat_id
                            AND reply.thread_root_id = facts.source_message_id
                            AND reply.is_outgoing = 1
                            AND (
                                LOWER(TRIM(COALESCE(reply.text_content, ''))) IN (
                                    'done', 'done.', 'already done', 'yes already done',
                                    'completed', 'completed.', 'shipped', 'shipped.',
                                    'pushed', 'pushed.', 'gg done'
                                )
                                OR LOWER(TRIM(COALESCE(reply.text_content, ''))) LIKE 'done %'
                                OR LOWER(TRIM(COALESCE(reply.text_content, ''))) LIKE '% deployed%'
                                OR (
                                    (
                                        LOWER(facts.action) LIKE 'share %'
                                        OR LOWER(facts.action) LIKE 'provide %'
                                        OR LOWER(facts.action) LIKE 'send %'
                                        OR LOWER(facts.action) LIKE 'upload %'
                                    )
                                    AND LENGTH(TRIM(COALESCE(reply.text_content, ''))) >= 8
                                    AND LOWER(TRIM(COALESCE(reply.text_content, ''))) NOT LIKE 'wait%'
                                    AND LOWER(TRIM(COALESCE(reply.text_content, ''))) NOT LIKE '%lemme%'
                                    AND LOWER(TRIM(COALESCE(reply.text_content, ''))) NOT LIKE '%let me%'
                                    AND LOWER(TRIM(COALESCE(reply.text_content, ''))) NOT LIKE 'will %'
                                )
                            )
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
            print("[DatabaseManager] closeCompletedSlackThreadTasks failed: \(error)")
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
                    try Self.executeChaseRefresh(db, update: u, now: now)
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
                // Bots are excluded from the directory outright: a fact's
                // subject must be a person. Found live — a loop's subject
                // ("the beta tester") first-name-matched the only directory
                // name starting with "The", which was a bot ("The Wolf Of
                // LEGION.CC street"), and a loop owned by the wrong subject
                // can never be closed by the person actually delivering.
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT m.sender_user_id AS id, m.sender_name AS name, COUNT(*) AS c
                        FROM messages m
                        LEFT JOIN nodes n ON n.entity_id = m.sender_user_id
                        WHERE m.sender_user_id IS NOT NULL AND m.sender_name IS NOT NULL AND m.sender_name <> ''
                          AND COALESCE(n.metadata, '') NOT LIKE '%"isBot":true%'
                        GROUP BY m.sender_user_id, m.sender_name
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

    /// Rewind a chronological extraction high-water mark when a provider
    /// backfills a genuinely-new message below it (Slack thread replies are the
    /// main case). Returns true only when a cursor actually moved. The next
    /// normal pass starts at the closest stored predecessor, giving the model
    /// enough local context to reconcile the open loop without resetting the
    /// whole chat.
    func rewindFactExtractionCursorIfNeeded(chatId: Int64, before date: Date) async -> Bool {
        guard let pool = await ensureDatabase() else { return false }
        do {
            return try await pool.write { db in
                guard let currentID = try Int64.fetchOne(
                    db,
                    sql: "SELECT extracted_through_message_id FROM fact_extraction_state WHERE chat_id = ?",
                    arguments: [chatId]
                ),
                let currentDate = try Double.fetchOne(
                    db,
                    sql: "SELECT date FROM messages WHERE chat_id = ? AND id = ?",
                    arguments: [chatId, currentID]
                ),
                currentDate >= date.timeIntervalSince1970 else { return false }

                let predecessor = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM messages
                        WHERE chat_id = ? AND date < ?
                        ORDER BY date DESC, id DESC
                        LIMIT 1
                        """,
                    arguments: [chatId, date.timeIntervalSince1970]
                ) ?? 0
                guard predecessor != currentID else { return false }
                try db.execute(
                    sql: """
                        UPDATE fact_extraction_state
                        SET extracted_through_message_id = ?, last_extracted_at = ?
                        WHERE chat_id = ?
                        """,
                    arguments: [predecessor, Date().timeIntervalSince1970, chatId]
                )
                return db.changesCount > 0
            }
        } catch {
            print("[DatabaseManager] rewindFactExtractionCursorIfNeeded failed: \(error)")
            return false
        }
    }

    /// Chats with an established chronological extraction cursor. Kept as one
    /// bulk read so a newly connected provider can be scheduled fairly without
    /// issuing one SQLite query per conversation.
    func factExtractionTrackedChatIds(chatIds: [Int64]) async -> Set<Int64> {
        guard !chatIds.isEmpty, let pool = await ensureDatabase() else { return [] }
        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ",")
        do {
            return try await pool.read { db in
                Set(try Int64.fetchAll(
                    db,
                    sql: "SELECT chat_id FROM fact_extraction_state WHERE chat_id IN (\(placeholders))",
                    arguments: StatementArguments(chatIds)
                ))
            }
        } catch {
            return []
        }
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
                            extracted_through_message_id = excluded.extracted_through_message_id,
                            last_extracted_at = excluded.last_extracted_at
                        """,
                    arguments: [chatId, throughMessageId, date.timeIntervalSince1970]
                )
            }
        } catch {
            print("[DatabaseManager] updateFactExtractionCursor failed: \(error)")
        }
    }

    /// Every chat the fact store holds rows for.
    ///
    /// Cleanup has to be driven from what was stored, not from what is
    /// currently eligible to extract: a chat that has gone quiet, been
    /// archived, or aged past the crawl window still has its old facts, and
    /// scanning only the eligible set would leave those behind forever.
    func factChatIds() async -> [Int64] {
        guard let pool = await ensureDatabase() else { return [] }
        do {
            return try await pool.read { db in
                try Int64.fetchAll(db, sql: "SELECT DISTINCT source_chat_id FROM facts")
            }
        } catch { return [] }
    }

    /// Remove every fact extracted from these chats, and forget how far
    /// extraction had read them.
    ///
    /// This is a hard delete rather than the store's usual bi-temporal
    /// invalidate, because these rows are not facts that stopped being true —
    /// they should never have been written. Invalidating them would file a
    /// bot's chatter under "resolved" and keep it in the history a user can
    /// browse. `facts_ad` keeps `facts_fts` in step.
    ///
    /// The cursor reset is the load-bearing half: without it a chat whose
    /// facts were purged is permanently stamped as read, so re-including it
    /// later (the bots toggle) would extract nothing. Clearing the cursor
    /// makes that toggle self-healing — the next pass re-reads the window.
    func purgeFacts(chatIds: [Int64]) async -> Int {
        guard !chatIds.isEmpty, let pool = await ensureDatabase() else { return 0 }
        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ",")
        do {
            return try await pool.write { db in
                let doomed = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM facts WHERE source_chat_id IN (\(placeholders))",
                    arguments: StatementArguments(chatIds)
                ) ?? 0
                guard doomed > 0 else { return 0 }
                try db.execute(
                    sql: "DELETE FROM facts WHERE source_chat_id IN (\(placeholders))",
                    arguments: StatementArguments(chatIds)
                )
                try db.execute(
                    sql: "DELETE FROM fact_extraction_state WHERE chat_id IN (\(placeholders))",
                    arguments: StatementArguments(chatIds)
                )
                return doomed
            }
        } catch {
            print("[DatabaseManager] purgeFacts failed: \(error)")
            return 0
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
