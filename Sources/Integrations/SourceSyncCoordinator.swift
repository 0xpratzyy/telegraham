import Foundation

actor SourceSyncCoordinator {
    static let shared = SourceSyncCoordinator()

    private struct ConversationFetch: Sendable {
        let index: Int
        let conversation: CanonicalConversation
        let page: MessagePage?
        let error: String?
    }

    struct Result: Sendable, Equatable {
        let conversations: Int
        let messages: Int
    }

    func sync(
        adapter: any SourceAdapter,
        conversationLimit: Int = 100,
        messageLimit: Int = 100,
        maxConversations: Int = 120,
        fetchConcurrency: Int = 8
    ) async throws -> Result {
        let external = try await adapter.currentAccount()
        let now = Date()
        let account = SourceAccount(
            id: CanonicalID.account(source: adapter.source, externalID: external.externalID),
            source: adapter.source,
            externalID: external.externalID,
            displayName: external.displayName,
            email: external.email,
            connectedAt: now,
            lastSyncedAt: nil
        )
        try await DatabaseManager.shared.upsertSourceAccount(account)

        var conversationCursor: SyncCursor?
        var conversations: [CanonicalConversation] = []
        repeat {
            let remaining = max(0, maxConversations - conversations.count)
            guard remaining > 0 else { break }
            let page = try await adapter.listConversations(
                cursor: conversationCursor,
                limit: min(conversationLimit, remaining)
            )
            conversations.append(contentsOf: page.conversations.prefix(remaining))
            conversationCursor = conversations.count >= maxConversations ? nil : page.nextCursor
        } while conversationCursor != nil

        // Thread detail requests are independent. Fetching them serially made
        // a first Gmail connect feel frozen; a small bounded fan-out keeps the
        // UI responsive without dumping 100 simultaneous requests on Google.
        let fetched = await withTaskGroup(of: ConversationFetch.self, returning: [ConversationFetch].self) { group in
            var nextIndex = 0
            let workerCount = min(max(1, fetchConcurrency), conversations.count)

            func enqueue(_ index: Int) {
                let conversation = conversations[index]
                group.addTask {
                    do {
                        let page = try await adapter.fetchMessages(
                            conversation: conversation,
                            cursor: nil,
                            limit: messageLimit
                        )
                        return ConversationFetch(index: index, conversation: conversation, page: page, error: nil)
                    } catch {
                        return ConversationFetch(
                            index: index,
                            conversation: conversation,
                            page: nil,
                            error: error.localizedDescription
                        )
                    }
                }
            }

            for _ in 0..<workerCount {
                enqueue(nextIndex)
                nextIndex += 1
            }

            var results: [ConversationFetch] = []
            while let result = await group.next() {
                results.append(result)
                if nextIndex < conversations.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }
            return results.sorted { $0.index < $1.index }
        }

        var importedMessages = 0
        for fetch in fetched {
            guard let messagePage = fetch.page else { continue }
            let conversation = fetch.conversation
            guard !messagePage.messages.isEmpty else { continue }
            let title = messagePage.messages
                .compactMap(\.subject)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ?? conversation.title
            let resolvedConversation = CanonicalConversation(
                id: conversation.id,
                accountID: conversation.accountID,
                source: conversation.source,
                externalID: conversation.externalID,
                kind: conversation.kind,
                title: title,
                updatedAt: messagePage.messages.map(\.date).max(),
                unreadCount: messagePage.messages.filter(\.isUnread).count
            )
            try await DatabaseManager.shared.importCanonicalMessages(
                account: account,
                conversation: resolvedConversation,
                messages: messagePage.messages,
                conversationCursor: conversationCursor
            )
            importedMessages += messagePage.messages.count
        }

        if !conversations.isEmpty, importedMessages == 0,
           let failure = fetched.compactMap(\.error).first {
            throw SourceAdapterError.api(source: adapter.source, message: failure)
        }

        let importedMessageCount = importedMessages
        await MainActor.run {
            NotificationCenter.default.post(
                name: .pidgyMessagesUpdatedLocally,
                object: nil,
                userInfo: [
                    "messageCount": importedMessageCount,
                    "source": adapter.source.rawValue
                ]
            )
        }
        return Result(conversations: conversations.count, messages: importedMessages)
    }

    func importWhatsApp(_ importResult: WhatsAppImport) async throws -> Result {
        let now = Date()
        let account = SourceAccount(
            id: importResult.conversation.accountID,
            source: .whatsapp,
            externalID: "manual-import",
            displayName: "WhatsApp exports",
            email: nil,
            connectedAt: now,
            lastSyncedAt: now
        )
        try await DatabaseManager.shared.importCanonicalMessages(
            account: account,
            conversation: importResult.conversation,
            messages: importResult.messages
        )
        await MainActor.run {
            NotificationCenter.default.post(
                name: .pidgyMessagesUpdatedLocally,
                object: nil,
                userInfo: [
                    "messageCount": importResult.messages.count,
                    "source": IntegrationSource.whatsapp.rawValue
                ]
            )
        }
        return Result(conversations: 1, messages: importResult.messages.count)
    }
}
