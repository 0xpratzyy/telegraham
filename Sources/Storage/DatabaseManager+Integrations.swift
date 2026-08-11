import Foundation
import GRDB

extension DatabaseManager {
    func loadSourceConversations(accountID: String) async -> [CanonicalConversation] {
        do {
            return try await read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM source_conversations WHERE account_id = ? ORDER BY updated_at DESC",
                    arguments: [accountID]
                ).compactMap { row in
                    guard let source = IntegrationSource(rawValue: row["source"]),
                          let kind = SourceConversationKind(rawValue: row["kind"]) else { return nil }
                    let updated: Double? = row["updated_at"]
                    return CanonicalConversation(
                        id: row["id"],
                        accountID: row["account_id"],
                        source: source,
                        externalID: row["external_id"],
                        kind: kind,
                        title: row["title"],
                        updatedAt: updated.map(Date.init(timeIntervalSince1970:)),
                        unreadCount: row["unread_count"] ?? 0
                    )
                }
            }
        } catch {
            return []
        }
    }

    func upsertSourceAccount(_ account: SourceAccount) async throws {
        try await write { db in
            try db.execute(
                sql: """
                    INSERT INTO source_accounts
                    (id, source, external_id, display_name, email, connected_at, last_synced_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name = excluded.display_name,
                        email = excluded.email,
                        last_synced_at = COALESCE(excluded.last_synced_at, last_synced_at)
                    """,
                arguments: [
                    account.id,
                    account.source.rawValue,
                    account.externalID,
                    account.displayName,
                    account.email,
                    account.connectedAt.timeIntervalSince1970,
                    account.lastSyncedAt?.timeIntervalSince1970
                ]
            )
        }
    }

    func loadSourceAccounts() async -> [SourceAccount] {
        do {
            return try await read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM source_accounts ORDER BY connected_at ASC"
                ).compactMap { row in
                    guard let source = IntegrationSource(rawValue: row["source"]) else { return nil }
                    let connected: Double = row["connected_at"]
                    let lastSynced: Double? = row["last_synced_at"]
                    return SourceAccount(
                        id: row["id"],
                        source: source,
                        externalID: row["external_id"],
                        displayName: row["display_name"],
                        email: row["email"],
                        connectedAt: Date(timeIntervalSince1970: connected),
                        lastSyncedAt: lastSynced.map(Date.init(timeIntervalSince1970:))
                    )
                }
            }
        } catch {
            return []
        }
    }

    func importCanonicalMessages(
        account: SourceAccount,
        conversation: CanonicalConversation,
        messages: [CanonicalMessage],
        conversationCursor: SyncCursor? = nil
    ) async throws {
        guard !messages.isEmpty else { return }
        let sourceID = SourceID(kind: conversation.source, account: account.externalID)
        let legacyChatID = CanonicalID.legacyInt64(sourceID.rawValue + "|" + conversation.externalID)
        let records = messages.map { message in
            MessageRecord(
                id: CanonicalID.legacyInt64(message.id),
                chatId: legacyChatID,
                senderUserId: message.senderExternalID.map {
                    CanonicalID.legacyInt64(sourceID.rawValue + "|user|" + $0)
                },
                senderName: message.senderName,
                date: message.date,
                textContent: {
                    let text = [message.subject, message.text]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                    return text.isEmpty ? nil : text
                }(),
                mediaTypeRaw: nil,
                isOutgoing: message.isOutgoing,
                source: sourceID,
                sourceAccountId: account.id,
                conversationId: conversation.id,
                externalId: message.externalID,
                threadRootId: message.threadRootID.map { CanonicalID.legacyInt64(sourceID.rawValue + "|thread|" + $0) }
            )
        }

        try await write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO id_map (int_id, source, native_id) VALUES (?, ?, ?)",
                arguments: [legacyChatID, sourceID.rawValue, conversation.externalID]
            )
            for (message, record) in zip(messages, records) {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO id_map (int_id, source, native_id) VALUES (?, ?, ?)",
                    arguments: [record.id, sourceID.rawValue, "msg:\(conversation.externalID):\(message.externalID)"]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO source_accounts
                    (id, source, external_id, display_name, email, connected_at, last_synced_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name = excluded.display_name,
                        email = excluded.email,
                        last_synced_at = excluded.last_synced_at
                    """,
                arguments: [
                    account.id, account.source.rawValue, account.externalID,
                    account.displayName, account.email,
                    account.connectedAt.timeIntervalSince1970, Date().timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO source_conversations
                    (id, account_id, source, external_id, kind, title, updated_at, unread_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        updated_at = COALESCE(excluded.updated_at, updated_at),
                        unread_count = excluded.unread_count
                    """,
                arguments: [
                    conversation.id, account.id, conversation.source.rawValue,
                    conversation.externalID, conversation.kind.rawValue,
                    conversation.title, conversation.updatedAt?.timeIntervalSince1970,
                    conversation.unreadCount
                ]
            )
            try Self.insertMessages(records, into: db)
            try db.execute(
                sql: """
                    INSERT INTO source_sync_state (account_id, conversation_cursor, last_synced_at, last_error)
                    VALUES (?, ?, ?, NULL)
                    ON CONFLICT(account_id) DO UPDATE SET
                        conversation_cursor = COALESCE(excluded.conversation_cursor, conversation_cursor),
                        last_synced_at = excluded.last_synced_at,
                        last_error = NULL
                    """,
                arguments: [account.id, conversationCursor?.rawValue, Date().timeIntervalSince1970]
            )
        }

        // Canonical adapters (Gmail/Slack imports) write through this path
        // rather than `upsertLiveMessages`. Keep reply-intent lifecycle
        // behavior identical: a newly observed sent message can close the
        // exact tracked reply loop, never the click that opened the source app.
        if ContextLayer.enabled, records.contains(where: \.isOutgoing) {
            let trackedClosed = await closeTrackedReplyIntents(chatId: legacyChatID)
            let structuralClosed = await closeAnsweredReplyLoops(chatId: legacyChatID)
            if trackedClosed + structuralClosed > 0 {
                await MainActor.run {
                    NotificationCenter.default.post(name: .contextFactsChanged, object: nil)
                }
            }
        }
    }
}
