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
    /// Embedding + chunk backfills run on their OWN loop. They were
    /// once-per-indexing-pass, but a pass is dominated by rate-limited
    /// TDLib history fetches (minutes for big chats) — local CPU work
    /// was being throttled by network pacing it doesn't share.
    private var embeddingTask: Task<Void, Never>?
    /// Pause is a LEASE, not a latch. Callers re-assert while genuinely
    /// active (the launcher fires pause() on every keystroke/focus
    /// change), and a forgotten resume self-heals: SwiftUI lifecycle
    /// proved unreliable for the release side — an NSPanel hidden via
    /// orderOut never fires .onDisappear, which left the scheduler
    /// paused for entire sessions (search-ready chats frozen while the
    /// launcher sat hidden; verified live 2026-06-11).
    private var pausedUntil: Date?

    static let pauseLeaseSeconds: TimeInterval = 30

    private var isPausedNow: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > Date()
    }
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
        embeddingTask = Task {
            await self.embeddingLoop()
        }
        await refreshProgress()
    }

    func stop() async {
        let task = processingTask
        task?.cancel()
        processingTask = nil
        embeddingTask?.cancel()
        embeddingTask = nil
        telegramService = nil
        prioritizedChatIds.removeAll()
        pausedUntil = nil
        sessionStartedAt = nil
        sessionIndexedMessages = 0
        sessionCompletedChats = 0
        lastIndexedChat = nil
        lastIndexedAt = nil
        lastBatchMessageCount = 0
        lastBackfillCount = 0
        activeWorkers = 0
        await task?.value
        await publishProgress(
            indexed: 0,
            total: 0,
            pendingChats: 0,
            currentChat: nil,
            isPaused: false
        )
    }

    func pause(leaseSeconds: TimeInterval = IndexScheduler.pauseLeaseSeconds) async {
        let candidate = Date().addingTimeInterval(leaseSeconds)
        if pausedUntil.map({ candidate > $0 }) ?? true {
            pausedUntil = candidate
        }
        await MainActor.run {
            progress.isPaused = true
        }
    }

    func resume() async {
        pausedUntil = nil
        await MainActor.run {
            progress.isPaused = false
        }
    }

    /// State probe for tests — the run loop isn't running there.
    var isPausedForTesting: Bool { isPausedNow }

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

            if isPausedNow {
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
                    isPaused: isPausedNow
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
                        isPaused: isPausedNow
                    )
                    continue
                }
                activeWorkers = 0
                await publishProgress(
                    indexed: readyChatIds.count,
                    total: orderedChats.count,
                    pendingChats: 0,
                    currentChat: nil,
                    isPaused: isPausedNow
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
                isPaused: isPausedNow
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
        let snapshot = await MainActor.run {
            (telegramService.currentUser?.id, telegramService.visibleChats)
        }
        let resolvedChats = await resolveMemberCountsIfNeeded(
            in: snapshot.1,
            using: telegramService
        )
        return (snapshot.0, resolvedChats.filter(Self.isIndexable))
    }

    private func resolveMemberCountsIfNeeded(
        in chats: [TGChat],
        using telegramService: TelegramService
    ) async -> [TGChat] {
        var resolvedChats: [TGChat] = []
        resolvedChats.reserveCapacity(chats.count)

        for chat in chats {
            guard Self.needsMemberCountResolution(chat),
                  let memberCount = await telegramService.resolvedMemberCount(for: chat) else {
                resolvedChats.append(chat)
                continue
            }
            resolvedChats.append(chat.updating(memberCount: memberCount))
        }

        return resolvedChats
    }

    nonisolated private static func needsMemberCountResolution(_ chat: TGChat) -> Bool {
        guard chat.memberCount == nil else { return false }
        if case .supergroup(_, let isChannel) = chat.chatType {
            return !isChannel
        }
        return false
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

            let didAdvanceCursor = oldestBatchMessageId.map { $0 != cursor } ?? false
            let candidateReachedHistoryStart = batch.isEmpty
                || batch.count < AppConstants.Indexing.batchSize
                || (cursor != 0 && !didAdvanceCursor)
            if !batchRecords.isEmpty {
                try await DatabaseManager.shared.upsertIndexedMessagesThrowing(
                    chatId: chat.id,
                    messages: batchRecords,
                    preferredOldestMessageId: oldestBatchMessageId ?? syncState?.lastIndexedMessageId,
                    isSearchReady: candidateReachedHistoryStart
                )

                try await updateEmbeddings(for: batch)
                await ingestIntoGraph(messages: batch, chat: chat, currentUserId: currentUserId)
                indexedMessageCount = batchRecords.count
                reachedHistoryStart = candidateReachedHistoryStart
            } else if candidateReachedHistoryStart {
                await DatabaseManager.shared.markChatSearchReady(
                    chatId: chat.id,
                    preferredOldestMessageId: syncState?.lastIndexedMessageId
                )
                reachedHistoryStart = true
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

    private static func updateEmbeddings(for messages: [TGMessage]) async throws {
        let eligibleMessages = messages.compactMap { message -> (message: TGMessage, text: String)? in
            guard let text = message.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.count >= AppConstants.Indexing.minEmbeddingTextLength else {
                return nil
            }
            return (message, text)
        }

        guard !eligibleMessages.isEmpty else { return }

        let modelVersion = await EmbeddingService.shared.activeModelVersion
        let vectors = await EmbeddingService.shared.embedBatch(texts: eligibleMessages.map { $0.text })
        let records = zip(eligibleMessages, vectors).compactMap { entry -> VectorStore.EmbeddingRecord? in
            let (pair, vector) = entry
            guard let vector else { return nil }
            let preview = String(pair.text.prefix(AppConstants.Indexing.embeddingPreviewCharacterLimit))
            return VectorStore.EmbeddingRecord(
                messageId: pair.message.id,
                chatId: pair.message.chatId,
                vector: vector,
                textPreview: preview,
                modelVersion: modelVersion
            )
        }

        guard !records.isEmpty else { return }
        try await VectorStore.shared.storeBatchThrowing(records)
    }

    private func backfillExistingEmbeddings(limit: Int) async -> Int {
        // "Missing" is version-aware: rows written by an older model
        // count as missing, so an embedding-model upgrade re-embeds the
        // corpus through this same path while old vectors keep serving
        // search until they're replaced.
        let activeVersion = await EmbeddingService.shared.activeModelVersion
        let messages = await DatabaseManager.shared.messagesMissingEmbeddings(
            limit: limit,
            modelVersion: activeVersion
        )
        guard !messages.isEmpty else { return 0 }

        // Map to (message, trimmed text). Don't re-apply a length gate here:
        // the discovery query already enforced the minimum, and SQLite's
        // char-count can disagree with Swift's grapheme count on unicode.
        // Anything the embedder still can't vectorize is marked skipped below.
        let candidates = messages.compactMap { message -> (message: DatabaseManager.MessageRecord, text: String)? in
            guard let text = message.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return nil
            }
            return (message, text)
        }

        guard !candidates.isEmpty else { return 0 }

        // Commit in small sub-batches: contextual embedding is slow on
        // long texts, and a single 128-message commit meant minutes of
        // CPU with zero durable progress (and all of it lost on quit).
        var stored = 0
        for slice in stride(from: 0, to: candidates.count, by: 16) {
            if Task.isCancelled { break }
            let sub = Array(candidates[slice..<min(slice + 16, candidates.count)])
            let vectors = await EmbeddingService.shared.embedBatch(texts: sub.map { $0.text })
            var records: [VectorStore.EmbeddingRecord] = []
            var unembeddable: [(id: Int64, chatId: Int64)] = []
            for (pair, vector) in zip(sub, vectors) {
                guard let vector else {
                    // No vector (e.g. a URL-only body that strips to empty).
                    // Mark it skipped so the discovery query stops returning it
                    // every pass — otherwise these pile up at the front of the
                    // scan and starve real messages behind them.
                    unembeddable.append((id: pair.message.id, chatId: pair.message.chatId))
                    continue
                }
                let preview = String(pair.text.prefix(AppConstants.Indexing.embeddingPreviewCharacterLimit))
                records.append(VectorStore.EmbeddingRecord(
                    messageId: pair.message.id,
                    chatId: pair.message.chatId,
                    vector: vector,
                    textPreview: preview,
                    modelVersion: activeVersion
                ))
            }
            await VectorStore.shared.storeBatch(records)
            if !unembeddable.isEmpty {
                await DatabaseManager.shared.markEmbeddingSkipped(unembeddable, modelVersion: activeVersion)
            }
            stored += records.count
        }
        return stored
    }

    /// Dedicated local-work loop: message re-embeds, conversation
    /// chunks, and the corpus stopword refresh. Independent of the
    /// chat-indexing loop (network-paced) and immune to the launcher
    /// pause — bounded batches of pure on-device CPU.
    private func embeddingLoop() async {
        var pass = 0
        while !Task.isCancelled {
            if pass % AppConstants.Indexing.corpusStopWordRefreshPasses == 0 {
                let tokens = await DatabaseManager.shared.corpusHighFrequencyTokens(
                    minDocShare: AppConstants.Indexing.corpusStopWordMinDocShare
                )
                if !tokens.isEmpty {
                    SearchStopWords.updateCorpusDerived(tokens)
                }
            }
            pass += 1

            // Message re-embeds first (cheap discovery query, fast
            // embeds); the chunk pass runs only when messages are
            // drained — its discovery is a GROUP BY over all messages
            // and shouldn't be paid every iteration. Profiling showed
            // the loop spending ~95% of its time in these discovery
            // queries, not in embedding.
            let embedded = await backfillExistingEmbeddings(limit: 512)
            var chunked = 0
            if embedded == 0 {
                chunked = await backfillConversationChunks()
            }

            // Brief breather between batches while there's work (keeps
            // the fans honest); longer idle poll once caught up.
            let didWork = embedded > 0 || chunked > 0
            try? await Task.sleep(for: .milliseconds(didWork ? 250 : 5_000))
        }
    }

    /// Build and embed conversation-window chunks for a few chats per
    /// pass. Like the message backfill this is pause-immune local work;
    /// per-chat watermarks make it incremental and idempotent — the
    /// partial tail window is rebuilt (and its stale rows replaced)
    /// as conversations grow.
    private func backfillConversationChunks() async -> Int {
        let modelVersion = await EmbeddingService.shared.activeModelVersion
        // Chunks exist to feed the contextual model; the legacy
        // sentence model stays message-level only.
        guard modelVersion != EmbeddingService.legacyModelVersion else { return 0 }

        let chatIds = await DatabaseManager.shared.chatsNeedingChunking(
            modelVersion: modelVersion,
            limit: AppConstants.Indexing.chunkBackfillChatsPerPass
        )
        guard !chatIds.isEmpty else { return 0 }

        var embeddedChunks = 0
        for chatId in chatIds {
            let state = await DatabaseManager.shared.chunkState(chatId: chatId, modelVersion: modelVersion)
            let messages = await DatabaseManager.shared.messagesForChunking(
                chatId: chatId,
                afterMessageId: state.coveredThrough,
                limit: AppConstants.Indexing.chunkBackfillMessagesPerChat
            )
            guard let newestId = messages.map(\.id).max() else { continue }

            let chunks = ConversationChunker.chunks(chatId: chatId, messages: messages)
            guard !chunks.isEmpty else {
                // Nothing embeddable in this slice (stickers, media) —
                // advance the watermark so the chat isn't rescanned
                // every pass.
                await DatabaseManager.shared.setChunkState(
                    chatId: chatId,
                    modelVersion: modelVersion,
                    coveredThrough: max(state.coveredThrough, newestId),
                    chunkedThrough: max(state.chunkedThrough, newestId)
                )
                continue
            }

            // Purge the stale tail once, then commit embedded chunks in
            // small sub-batches — chunk texts are long (up to 900 chars)
            // and the contextual model is slow on them; whole-slice
            // commits meant minutes of invisible, non-durable work.
            await VectorStore.shared.purgeChunkTail(
                chatId: chatId,
                modelVersion: modelVersion,
                fromMessageId: state.coveredThrough + 1
            )
            var pendingRecords: [VectorStore.ChunkRecord] = []
            var storedAny = false
            for chunk in chunks {
                if Task.isCancelled { break }
                guard let vector = await EmbeddingService.shared.embed(
                    text: chunk.text,
                    modelVersion: modelVersion
                ) else { continue }
                pendingRecords.append(VectorStore.ChunkRecord(
                    chatId: chunk.chatId,
                    fromMessageId: chunk.fromMessageId,
                    toMessageId: chunk.toMessageId,
                    anchorMessageId: chunk.anchorMessageId,
                    vector: vector,
                    textPreview: String(chunk.text.prefix(AppConstants.Indexing.embeddingPreviewCharacterLimit)),
                    modelVersion: modelVersion
                ))
                if pendingRecords.count >= 16 {
                    await VectorStore.shared.storeChunks(pendingRecords)
                    embeddedChunks += pendingRecords.count
                    storedAny = true
                    pendingRecords.removeAll(keepingCapacity: true)
                }
            }
            await VectorStore.shared.storeChunks(pendingRecords)
            embeddedChunks += pendingRecords.count
            storedAny = storedAny || !pendingRecords.isEmpty

            // Always advance the re-selection mark to the newest message
            // we examined — even when the trailing window was too short /
            // media-only to emit a chunk. Otherwise `chatsNeedingChunking`
            // (keyed off chunked_through) re-selects this chat every pass
            // for a tail it can never chunk, re-running the embedding
            // model on the same windows forever. coveredThrough still lags
            // (so the growing tail is rebuilt) but only refires when a
            // genuinely newer message lands. If nothing stored this pass,
            // hold coveredThrough so the tail is retried on next activity.
            let covered = storedAny
                ? (ConversationChunker.coveredThrough(chunks: chunks, messages: messages) ?? state.coveredThrough)
                : state.coveredThrough
            await DatabaseManager.shared.setChunkState(
                chatId: chatId,
                modelVersion: modelVersion,
                coveredThrough: max(state.coveredThrough, covered),
                chunkedThrough: ConversationChunker.scannedThrough(messages: messages, prior: state.chunkedThrough)
            )
        }

        if embeddedChunks > 0 {
            lastBackfillCount = embeddedChunks
            lastIndexedAt = Date()
            lastIndexedChat = "Chunk backfill"
        }
        return embeddedChunks
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
            isPaused: isPausedNow
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
            isPaused: isPausedNow,
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

#if DEBUG
    func indexableChatsForTesting(using telegramService: TelegramService) async -> [TGChat] {
        await snapshot(using: telegramService).chats
    }
#endif
}
