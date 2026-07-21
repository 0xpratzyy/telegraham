// DatabaseManager+OCR.swift
// Photo OCR pipeline: pending photo lookups, OCR application, sender-name backfill.

import Foundation
import GRDB

extension DatabaseManager {
    /// Photo messages awaiting on-device OCR — newest first so fresh payment
    /// screenshots / tickets get their text before the next extraction pass.
    func pendingPhotoOCRMessages(limit: Int = 24, maxAge: TimeInterval = 30 * 86_400) async -> [(id: Int64, chatId: Int64)] {
        guard let pool = await ensureDatabase() else { return [] }
        let cutoff = Date().addingTimeInterval(-maxAge).timeIntervalSince1970
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, chat_id FROM messages
                        WHERE media_type = 'Photo' AND ocr_state = 0 AND date >= ?
                        ORDER BY id DESC LIMIT ?
                        """,
                    arguments: [cutoff, limit]
                )
                return rows.map { (id: $0["id"] as Int64, chatId: $0["chat_id"] as Int64) }
            }
        } catch {
            print("[DatabaseManager] pendingPhotoOCRMessages failed: \(error)")
            return []
        }
    }

    /// Record an OCR result: marks the message processed and, when text was
    /// recognized, appends it to text_content as "[photo text: …]" so every
    /// reader (extraction transcript, search FTS, evidence rows) sees it.
    func applyPhotoOCR(messageId: Int64, chatId: Int64, text: String?) async {
        guard let pool = await ensureDatabase() else { return }
        let cleaned = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00}", with: "")
        do {
            try await pool.write { db in
                if let cleaned, !cleaned.isEmpty {
                    let capped = String(cleaned.prefix(500))
                    let existing = try String.fetchOne(
                        db,
                        sql: "SELECT text_content FROM messages WHERE id = ? AND chat_id = ?",
                        arguments: [messageId, chatId]
                    ) ?? ""
                    let marker = "[photo text: \(capped)]"
                    let combined = existing.isEmpty ? marker : existing + "\n" + marker
                    try db.execute(
                        sql: "UPDATE messages SET text_content = ?, ocr_state = 1 WHERE id = ? AND chat_id = ?",
                        arguments: [combined, messageId, chatId]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE messages SET ocr_state = 1 WHERE id = ? AND chat_id = ?",
                        arguments: [messageId, chatId]
                    )
                }
            }
        } catch {
            print("[DatabaseManager] applyPhotoOCR failed: \(error)")
        }
    }

    /// Fill in sender names for cached messages stored before the sender's
    /// user record was fetched — resolved once at display time, persisted so
    /// every later read has the real name.
    func backfillSenderNames(_ namesByUserId: [Int64: String]) async {
        guard !namesByUserId.isEmpty, let pool = await ensureDatabase() else { return }
        do {
            try await pool.write { db in
                for (userId, name) in namesByUserId {
                    try db.execute(
                        sql: "UPDATE messages SET sender_name = ? WHERE sender_user_id = ? AND (sender_name IS NULL OR sender_name = '')",
                        arguments: [name, userId]
                    )
                }
            }
        } catch {
            print("[DatabaseManager] backfillSenderNames failed: \(error)")
        }
    }

    /// Marker appended by the on-device photo OCR. Re-syncs deliver the
    /// ORIGINAL Telegram text — comparing against the stripped base keeps a
    /// re-sync from reading as an "edit" and wiping the OCR text.
    static func strippedOCRBase(_ text: String?) -> String? {
        guard let text, let range = text.range(of: "[photo text:") else { return text }
        let base = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? nil : base
    }
}
