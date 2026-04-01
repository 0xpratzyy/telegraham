import Foundation
import Combine

actor IndexScheduler {
    static let shared = IndexScheduler()

    final class ProgressState: ObservableObject {
        @Published var indexed = 0
        @Published var total = 0
        @Published var currentChat: String?
        @Published var isPaused = false
    }

    nonisolated let progress = ProgressState()

    private var telegramService: TelegramService?
    private var processingTask: Task<Void, Never>?
    private var isPaused = false
    private var prioritizedChatIds: [Int64] = []

    func start(using telegramService: TelegramService) async {
        self.telegramService = telegramService
        if processingTask != nil {
            await refreshProgress()
            return
        }

        let task = Task {
            await self.runLoop()
        }
        processingTask = task
        await refreshProgress()
    }

    func stop() async {
        processingTask?.cancel()
        processingTask = nil
        telegramService = nil
        prioritizedChatIds.removeAll()
        isPaused = false
        await updateProgress(indexed: 0, total: 0, currentChat: nil, isPaused: false)
    }

    func pause() async {
        isPaused = true
        await MainActor.run {
            progress.isPaused = true
        }
    }

    func resume() async {
        isPaused = false
        await MainActor.run {
            progress.isPaused = false
        }
    }

    func prioritize(chatId: Int64) async {
        prioritizedChatIds.removeAll { $0 == chatId }
        prioritizedChatIds.insert(chatId, at: 0)
        if prioritizedChatIds.count > AppConstants.Indexing.maxPrioritizedChats {
            prioritizedChatIds = Array(prioritizedChatIds.prefix(AppConstants.Indexing.maxPrioritizedChats))
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard let telegramService else {
                try? await Task.sleep(for: .milliseconds(Int(AppConstants.Indexing.idlePollIntervalMilliseconds)))
                continue
            }

            if isPaused {
                let pausedSnapshot = await snapshot(using: telegramService)
                let readyChatIds = await DatabaseManager.shared.searchReadyChatIds(in: pausedSnapshot.chats.map(\.id))
                await updateProgress(
                    indexed: readyChatIds.count,
                    total: pausedSnapshot.chats.count,
                    currentChat: nil,
                    isPaused: true
                )
                try? await Task.sleep(for: .milliseconds(Int(AppConstants.Indexing.pausedPollIntervalMilliseconds)))
                continue
            }

            let snapshot = await snapshot(using: telegramService)
            guard !snapshot.chats.isEmpty else {
                await updateProgress(indexed: 0, total: 0, currentChat: nil, isPaused: isPaused)
                try? await Task.sleep(for: .milliseconds(Int(AppConstants.Indexing.idlePollIntervalMilliseconds)))
                continue
            }

            let orderedChats = orderedChats(from: snapshot.chats)
            let readyChatIds = await DatabaseManager.shared.searchReadyChatIds(in: orderedChats.map(\.id))
            let pendingChats = orderedChats.filter { !readyChatIds.contains($0.id) }

            guard let nextChat = pendingChats.first else {
                await updateProgress(
                    indexed: readyChatIds.count,
                    total: orderedChats.count,
                    currentChat: nil,
                    isPaused: isPaused
                )
                try? await Task.sleep(for: .milliseconds(Int(AppConstants.Indexing.idlePollIntervalMilliseconds)))
                continue
            }

            await updateProgress(
                indexed: readyChatIds.count,
                total: orderedChats.count,
                currentChat: nextChat.title,
                isPaused: isPaused
            )

            await index(chat: nextChat, currentUserId: snapshot.currentUserId, using: telegramService)
            _ = await backfillExistingEmbeddings(limit: AppConstants.Indexing.embeddingBackfillBatchSize)
            try? await Task.sleep(for: .milliseconds(Int(AppConstants.Indexing.interBatchDelayMilliseconds)))
        }
    }

    private func snapshot(using telegramService: TelegramService) async -> (currentUserId: Int64?, chats: [TGChat]) {
        await MainActor.run {
            let chats = telegramService.visibleChats.filter(Self.isIndexable)
            return (telegramService.currentUser?.id, chats)
        }
    }

    nonisolated private static func isIndexable(_ chat: TGChat) -> Bool {
        switch chat.chatType {
        case .privateChat:
            return true

        case .basicGroup:
            return true

        case .supergroup(_, let isChannel):
            guard !isChannel else { return false }
            guard let memberCount = chat.memberCount else { return false }
            return memberCount <= AppConstants.Indexing.maxIndexedGroupMembers

        case .secretChat:
            return false
        }
    }

    private func orderedChats(from chats: [TGChat]) -> [TGChat] {
        let priorityOrder = Dictionary(uniqueKeysWithValues: prioritizedChatIds.enumerated().map { ($1, $0) })
        return chats.sorted { lhs, rhs in
            let lhsPriority = priorityOrder[lhs.id] ?? Int.max
            let rhsPriority = priorityOrder[rhs.id] ?? Int.max
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            let lhsBucket = bucket(for: lhs)
            let rhsBucket = bucket(for: rhs)
            if lhsBucket != rhsBucket {
                return lhsBucket < rhsBucket
            }

            let lhsDate = lhs.lastActivityDate ?? .distantPast
            let rhsDate = rhs.lastActivityDate ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }

            if lhs.order != rhs.order {
                return lhs.order > rhs.order
            }

            return lhs.id < rhs.id
        }
    }

    private func bucket(for chat: TGChat) -> Int {
        if chat.chatType.isPrivate { return 1 }
        if chat.chatType.isGroup { return 2 }
        return 3
    }

    private func index(chat: TGChat, currentUserId: Int64?, using telegramService: TelegramService) async {
        let syncState = await DatabaseManager.shared.loadSyncState(chatId: chat.id)
        let cursor = syncState?.lastIndexedMessageId ?? 0

        do {
            let batch = try await telegramService.getChatHistory(
                chatId: chat.id,
                fromMessageId: cursor,
                limit: AppConstants.Indexing.batchSize,
                onlyLocal: false,
                priority: .background
            )

            let oldestBatchMessageId = batch.min { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date < rhs.date
                }
                return lhs.id < rhs.id
            }?.id

            let batchRecords = batch.map { message in
                DatabaseManager.MessageRecord(
                    id: message.id,
                    chatId: message.chatId,
                    senderUserId: message.senderUserId,
                    senderName: message.senderName,
                    date: message.date,
                    textContent: message.textContent,
                    mediaTypeRaw: message.mediaType?.rawValue,
                    isOutgoing: message.isOutgoing
                )
            }

            let didAdvanceCursor = oldestBatchMessageId.map { $0 != cursor } ?? false
            let reachedHistoryStart = batch.isEmpty
                || batch.count < AppConstants.Indexing.batchSize
                || (cursor != 0 && !didAdvanceCursor)
            if !batchRecords.isEmpty {
                await DatabaseManager.shared.upsertIndexedMessages(
                    chatId: chat.id,
                    messages: batchRecords,
                    preferredOldestMessageId: oldestBatchMessageId ?? syncState?.lastIndexedMessageId,
                    isSearchReady: reachedHistoryStart
                )

                await updateEmbeddings(for: batch)
                await ingestIntoGraph(messages: batch, chat: chat, currentUserId: currentUserId)
            } else if reachedHistoryStart {
                await DatabaseManager.shared.markChatSearchReady(
                    chatId: chat.id,
                    preferredOldestMessageId: syncState?.lastIndexedMessageId
                )
            }

            if reachedHistoryStart {
                prioritizedChatIds.removeAll { $0 == chat.id }
            }
        } catch {
            print("[IndexScheduler] Failed to index chat \(chat.id) (\(chat.title)): \(error)")
        }

        await refreshProgress()
    }

    private func ingestIntoGraph(messages: [TGMessage], chat: TGChat, currentUserId: Int64?) async {
        guard let currentUserId else { return }

        switch chat.chatType {
        case .privateChat(let otherUserId):
            await RelationGraph.shared.upsertNode(
                entityId: otherUserId,
                type: AppConstants.Graph.userEntityType,
                name: chat.title,
                username: nil
            )

            let source = min(currentUserId, otherUserId)
            let target = max(currentUserId, otherUserId)
            for _ in messages {
                await RelationGraph.shared.incrementEdge(
                    source: source,
                    target: target,
                    type: AppConstants.Graph.dmEdgeType,
                    contextChatId: nil
                )
            }

        case .basicGroup, .supergroup(_, false):
            for message in messages {
                guard let senderUserId = message.senderUserId, senderUserId != currentUserId else { continue }

                await RelationGraph.shared.upsertNode(
                    entityId: senderUserId,
                    type: AppConstants.Graph.userEntityType,
                    name: message.senderName,
                    username: nil
                )

                let source = min(currentUserId, senderUserId)
                let target = max(currentUserId, senderUserId)
                await RelationGraph.shared.incrementEdge(
                    source: source,
                    target: target,
                    type: AppConstants.Graph.sharedGroupEdgeType,
                    contextChatId: chat.id
                )
            }

        case .supergroup(_, true), .secretChat:
            break
        }
    }

    private func updateEmbeddings(for messages: [TGMessage]) async {
        let eligibleMessages = messages.compactMap { message -> (message: TGMessage, text: String)? in
            guard let text = message.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.count >= AppConstants.Indexing.minEmbeddingTextLength else {
                return nil
            }
            return (message, text)
        }

        guard !eligibleMessages.isEmpty else { return }

        let vectors = await EmbeddingService.shared.embedBatch(texts: eligibleMessages.map { $0.text })
        let records = zip(eligibleMessages, vectors).compactMap { entry -> VectorStore.EmbeddingRecord? in
            let (pair, vector) = entry
            guard let vector else { return nil }
            let preview = String(pair.text.prefix(AppConstants.Indexing.embeddingPreviewCharacterLimit))
            return VectorStore.EmbeddingRecord(
                messageId: pair.message.id,
                chatId: pair.message.chatId,
                vector: vector,
                textPreview: preview
            )
        }

        guard !records.isEmpty else { return }
        await VectorStore.shared.storeBatch(records)
    }

    private func backfillExistingEmbeddings(limit: Int) async -> Int {
        let messages = await DatabaseManager.shared.messagesMissingEmbeddings(limit: limit)
        guard !messages.isEmpty else { return 0 }

        let eligibleMessages = messages.compactMap { message -> (message: DatabaseManager.MessageRecord, text: String)? in
            guard let text = message.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.count >= AppConstants.Indexing.minEmbeddingTextLength else {
                return nil
            }
            return (message, text)
        }

        guard !eligibleMessages.isEmpty else { return 0 }

        let vectors = await EmbeddingService.shared.embedBatch(texts: eligibleMessages.map { $0.text })
        let records = zip(eligibleMessages, vectors).compactMap { entry -> VectorStore.EmbeddingRecord? in
            let (pair, vector) = entry
            guard let vector else { return nil }
            let preview = String(pair.text.prefix(AppConstants.Indexing.embeddingPreviewCharacterLimit))
            return VectorStore.EmbeddingRecord(
                messageId: pair.message.id,
                chatId: pair.message.chatId,
                vector: vector,
                textPreview: preview
            )
        }

        guard !records.isEmpty else { return 0 }
        await VectorStore.shared.storeBatch(records)
        return records.count
    }

    private func refreshProgress(currentChat: String? = nil) async {
        guard let telegramService else { return }

        let snapshot = await snapshot(using: telegramService)
        let readyChatIds = await DatabaseManager.shared.searchReadyChatIds(in: snapshot.chats.map(\.id))
        let progressChat: String?
        if let currentChat {
            progressChat = currentChat
        } else {
            progressChat = await MainActor.run { progress.currentChat }
        }
        await updateProgress(
            indexed: readyChatIds.count,
            total: snapshot.chats.count,
            currentChat: progressChat,
            isPaused: isPaused
        )
    }

    private func updateProgress(indexed: Int, total: Int, currentChat: String?, isPaused: Bool) async {
        await MainActor.run {
            progress.indexed = indexed
            progress.total = total
            progress.currentChat = currentChat
            progress.isPaused = isPaused
        }
    }
}
