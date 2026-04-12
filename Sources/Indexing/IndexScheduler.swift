import Foundation
import Combine

actor IndexScheduler {
    static let shared = IndexScheduler()

    private struct IndexOutcome: Sendable {
        let chatId: Int64
        let chatTitle: String
        let indexedMessageCount: Int
        let reachedHistoryStart: Bool
    }

    private struct ProgressSnapshot {
        let indexed: Int
        let total: Int
        let pendingChats: Int
        let currentChat: String?
        let activeWorkers: Int
        let isPaused: Bool
        let sessionStartedAt: Date?
        let sessionIndexedMessages: Int
        let sessionCompletedChats: Int
        let lastIndexedChat: String?
        let lastIndexedAt: Date?
        let lastBatchMessageCount: Int
        let lastBackfillCount: Int
    }

    private struct GroupBatchParticipant {
        var count: Int
        var lastActiveAt: Date?
        var latestSenderName: String?
    }

    final class ProgressState: ObservableObject {
        @Published var indexed = 0
        @Published var total = 0
        @Published var pendingChats = 0
        @Published var currentChat: String?
        @Published var activeWorkers = 0
        @Published var isPaused = false
        @Published var sessionStartedAt: Date?
        @Published var sessionIndexedMessages = 0
        @Published var sessionCompletedChats = 0
        @Published var lastIndexedChat: String?
        @Published var lastIndexedAt: Date?
        @Published var lastBatchMessageCount = 0
        @Published var lastBackfillCount = 0
    }

    nonisolated let progress = ProgressState()

    private var telegramService: TelegramService?
    private var processingTask: Task<Void, Never>?
    private var isPaused = false
    private var prioritizedChatIds: [Int64] = []
    private var sessionStartedAt: Date?
    private var sessionIndexedMessages = 0
    private var sessionCompletedChats = 0
    private var lastIndexedChat: String?
    private var lastIndexedAt: Date?
    private var lastBatchMessageCount = 0
    private var lastBackfillCount = 0
    private var activeWorkers = 0

    func start(using telegramService: TelegramService) async {
        self.telegramService = telegramService
        if processingTask != nil {
            await refreshProgress()
            return
        }

        sessionStartedAt = Date()
        sessionIndexedMessages = 0
        sessionCompletedChats = 0
        lastIndexedChat = nil
        lastIndexedAt = nil
        lastBatchMessageCount = 0
        lastBackfillCount = 0
        activeWorkers = 0

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
        sessionStartedAt = nil
        sessionIndexedMessages = 0
        sessionCompletedChats = 0
        lastIndexedChat = nil
        lastIndexedAt = nil
        lastBatchMessageCount = 0
        lastBackfillCount = 0
        activeWorkers = 0
        await publishProgress(
            indexed: 0,
            total: 0,
            pendingChats: 0,
            currentChat: nil,
            isPaused: false
        )
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
                activeWorkers = 0
                await publishProgress(
                    indexed: readyChatIds.count,
                    total: pausedSnapshot.chats.count,
                    pendingChats: max(pausedSnapshot.chats.count - readyChatIds.count, 0),
                    currentChat: nil,
                    isPaused: true
                )
                try? await Task.sleep(for: .milliseconds(Int(AppConstants.Indexing.pausedPollIntervalMilliseconds)))
                continue
            }

            let snapshot = await snapshot(using: telegramService)
            guard !snapshot.chats.isEmpty else {
                activeWorkers = 0
                await publishProgress(
                    indexed: 0,
                    total: 0,
                    pendingChats: 0,
                    currentChat: nil,
                    isPaused: isPaused
                )
                try? await Task.sleep(for: .milliseconds(Int(AppConstants.Indexing.idlePollIntervalMilliseconds)))
                continue
            }

            let orderedChats = orderedChats(from: snapshot.chats)
            let readyChatIds = await DatabaseManager.shared.searchReadyChatIds(in: orderedChats.map(\.id))
            let pendingChats = orderedChats.filter { !readyChatIds.contains($0.id) }

            guard !pendingChats.isEmpty else {
                let backfilled = await backfillExistingEmbeddings(limit: AppConstants.Indexing.embeddingBackfillBatchSize)
                if backfilled > 0 {
                    lastBackfillCount = backfilled
                    lastIndexedAt = Date()
                    lastIndexedChat = "Embedding backfill"
                    activeWorkers = 0
                    await publishProgress(
                        indexed: readyChatIds.count,
                        total: orderedChats.count,
                        pendingChats: 0,
                        currentChat: nil,
                        isPaused: isPaused
                    )
                    continue
                }
                activeWorkers = 0
                await publishProgress(
                    indexed: readyChatIds.count,
                    total: orderedChats.count,
                    pendingChats: 0,
                    currentChat: nil,
                    isPaused: isPaused
                )
                try? await Task.sleep(for: .milliseconds(Int(AppConstants.Indexing.idlePollIntervalMilliseconds)))
                continue
            }

            let nextChats = Array(pendingChats.prefix(AppConstants.Indexing.maxConcurrentChatWorkers))
            let progressLabel: String?
            if nextChats.count <= 1 {
                progressLabel = nextChats.first?.title
            } else if let firstChat = nextChats.first {
                progressLabel = "\(firstChat.title) +\(nextChats.count - 1) more"
            } else {
                progressLabel = nil
            }

            activeWorkers = nextChats.count
            await publishProgress(
                indexed: readyChatIds.count,
                total: orderedChats.count,
                pendingChats: pendingChats.count,
                currentChat: progressLabel,
                isPaused: isPaused
            )

            let outcomes = await withTaskGroup(of: IndexOutcome.self) { group in
                for chat in nextChats {
                    group.addTask {
                        await Self.indexChat(
                            chat: chat,
                            currentUserId: snapshot.currentUserId,
                            using: telegramService
                        )
                    }
                }

                var completed: [IndexOutcome] = []
                for await outcome in group {
                    completed.append(outcome)
                }
                return completed
            }

            let completedChatIds = outcomes
                .filter(\.reachedHistoryStart)
                .map(\.chatId)
            if !completedChatIds.isEmpty {
                prioritizedChatIds.removeAll { completedChatIds.contains($0) }
            }

            let indexedMessageCount = outcomes.reduce(0) { $0 + $1.indexedMessageCount }
            if indexedMessageCount > 0 {
                sessionIndexedMessages += indexedMessageCount
                lastIndexedAt = Date()
                lastBatchMessageCount = indexedMessageCount
                lastBackfillCount = 0
                if outcomes.count == 1, let outcome = outcomes.first {
                    lastIndexedChat = outcome.chatTitle
                } else if let progressLabel, !progressLabel.isEmpty {
                    lastIndexedChat = progressLabel
                }
            }

            let completedChatCount = outcomes.filter(\.reachedHistoryStart).count
            if completedChatCount > 0 {
                sessionCompletedChats += completedChatCount
            }

            activeWorkers = 0

            await refreshProgress(currentChat: progressLabel)
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

            let lhsDate = lhs.lastActivityDate ?? .distantPast
            let rhsDate = rhs.lastActivityDate ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }

            let lhsBucket = bucket(for: lhs)
            let rhsBucket = bucket(for: rhs)
            if lhsBucket != rhsBucket {
                return lhsBucket < rhsBucket
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

    private static func indexChat(
        chat: TGChat,
        currentUserId: Int64?,
        using telegramService: TelegramService
    ) async -> IndexOutcome {
        let syncState = await DatabaseManager.shared.loadSyncState(chatId: chat.id)
        let cursor = syncState?.lastIndexedMessageId ?? 0
        var reachedHistoryStart = false
        var indexedMessageCount = 0

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
            indexedMessageCount = batchRecords.count

            let didAdvanceCursor = oldestBatchMessageId.map { $0 != cursor } ?? false
            reachedHistoryStart = batch.isEmpty
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
        } catch {
            print("[IndexScheduler] Failed to index chat \(chat.id) (\(chat.title)): \(error)")
        }

        return IndexOutcome(
            chatId: chat.id,
            chatTitle: chat.title,
            indexedMessageCount: indexedMessageCount,
            reachedHistoryStart: reachedHistoryStart
        )
    }

    private static func ingestIntoGraph(messages: [TGMessage], chat: TGChat, currentUserId: Int64?) async {
        guard let currentUserId else { return }

        switch chat.chatType {
        case .privateChat(let otherUserId):
            guard !messages.isEmpty else { return }
            await RelationGraph.shared.upsertNode(
                entityId: otherUserId,
                type: AppConstants.Graph.userEntityType,
                name: chat.title,
                username: nil
            )

            let source = min(currentUserId, otherUserId)
            let target = max(currentUserId, otherUserId)
            let lastActiveAt = messages.map(\.date).max()
            await RelationGraph.shared.incrementEdges([
                RelationGraph.EdgeIncrement(
                    source: source,
                    target: target,
                    type: AppConstants.Graph.dmEdgeType,
                    contextChatId: nil,
                    weightDelta: Double(messages.count),
                    messageCountDelta: messages.count,
                    lastActiveAt: lastActiveAt
                )
            ])

        case .basicGroup, .supergroup(_, false):
            var participantsByUserId: [Int64: GroupBatchParticipant] = [:]

            for message in messages {
                guard let senderUserId = message.senderUserId, senderUserId != currentUserId else { continue }

                var participant = participantsByUserId[senderUserId] ?? GroupBatchParticipant(
                    count: 0,
                    lastActiveAt: nil,
                    latestSenderName: nil
                )
                participant.count += 1
                if let existingDate = participant.lastActiveAt {
                    if message.date >= existingDate {
                        participant.lastActiveAt = message.date
                        participant.latestSenderName = message.senderName ?? participant.latestSenderName
                    }
                } else {
                    participant.lastActiveAt = message.date
                    participant.latestSenderName = message.senderName
                }
                participantsByUserId[senderUserId] = participant
            }

            guard !participantsByUserId.isEmpty else { return }

            for (senderUserId, participant) in participantsByUserId {
                await RelationGraph.shared.upsertNode(
                    entityId: senderUserId,
                    type: AppConstants.Graph.userEntityType,
                    name: participant.latestSenderName,
                    username: nil
                )
            }

            let updates = participantsByUserId.map { senderUserId, participant in
                let source = min(currentUserId, senderUserId)
                let target = max(currentUserId, senderUserId)
                return RelationGraph.EdgeIncrement(
                    source: source,
                    target: target,
                    type: AppConstants.Graph.sharedGroupEdgeType,
                    contextChatId: chat.id,
                    weightDelta: Double(participant.count),
                    messageCountDelta: participant.count,
                    lastActiveAt: participant.lastActiveAt
                )
            }

            await RelationGraph.shared.incrementEdges(updates)

        case .supergroup(_, true), .secretChat:
            break
        }
    }

    private static func updateEmbeddings(for messages: [TGMessage]) async {
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
        await publishProgress(
            indexed: readyChatIds.count,
            total: snapshot.chats.count,
            pendingChats: max(snapshot.chats.count - readyChatIds.count, 0),
            currentChat: progressChat,
            isPaused: isPaused
        )
    }

    private func publishProgress(
        indexed: Int,
        total: Int,
        pendingChats: Int,
        currentChat: String?,
        isPaused: Bool
    ) async {
        let snapshot = ProgressSnapshot(
            indexed: indexed,
            total: total,
            pendingChats: pendingChats,
            currentChat: currentChat,
            activeWorkers: activeWorkers,
            isPaused: isPaused,
            sessionStartedAt: sessionStartedAt,
            sessionIndexedMessages: sessionIndexedMessages,
            sessionCompletedChats: sessionCompletedChats,
            lastIndexedChat: lastIndexedChat,
            lastIndexedAt: lastIndexedAt,
            lastBatchMessageCount: lastBatchMessageCount,
            lastBackfillCount: lastBackfillCount
        )

        await MainActor.run {
            progress.indexed = snapshot.indexed
            progress.total = snapshot.total
            progress.pendingChats = snapshot.pendingChats
            progress.currentChat = snapshot.currentChat
            progress.activeWorkers = snapshot.activeWorkers
            progress.isPaused = snapshot.isPaused
            progress.sessionStartedAt = snapshot.sessionStartedAt
            progress.sessionIndexedMessages = snapshot.sessionIndexedMessages
            progress.sessionCompletedChats = snapshot.sessionCompletedChats
            progress.lastIndexedChat = snapshot.lastIndexedChat
            progress.lastIndexedAt = snapshot.lastIndexedAt
            progress.lastBatchMessageCount = snapshot.lastBatchMessageCount
            progress.lastBackfillCount = snapshot.lastBackfillCount
        }
    }
}
