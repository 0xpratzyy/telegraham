import Foundation

actor RecentSyncCoordinator {
    static let shared = RecentSyncCoordinator()

    private struct RecentSyncOutcome: Sendable {
        let chatId: Int64
        let chatTitle: String
        let refreshed: Bool
        let completedSync: Bool
        let messageCount: Int
    }

    private struct SyncSelection {
        let primaryCandidates: [TGChat]
        let primaryChats: [TGChat]
        let retryCandidates: [TGChat]
        let retryChats: [TGChat]

        var selectedCount: Int {
            primaryChats.count + retryChats.count
        }
    }

    private struct ProgressSnapshot {
        let totalVisibleChats: Int
        let staleVisibleChats: Int
        let activeRefreshes: Int
        let prioritizedChats: Int
        let isRefreshQueued: Bool
        let sessionStartedAt: Date?
        let sessionRefreshedChats: Int
        let sessionRefreshedMessages: Int
        let lastSyncedChat: String?
        let lastSyncAt: Date?
        let lastBatchRefreshedChats: Int
        let lastBatchMessageCount: Int
    }

    private struct BackfillFetchPolicy: Sendable, Equatable {
        let pageSize: Int
        let timeoutSeconds: TimeInterval
    }

    final class ProgressState: ObservableObject {
        @Published var totalVisibleChats = 0
        @Published var staleVisibleChats = 0
        @Published var activeRefreshes = 0
        @Published var prioritizedChats = 0
        @Published var isRefreshQueued = false
        @Published var sessionStartedAt: Date?
        @Published var sessionRefreshedChats = 0
        @Published var sessionRefreshedMessages = 0
        @Published var lastSyncedChat: String?
        @Published var lastSyncAt: Date?
        @Published var lastBatchRefreshedChats = 0
        @Published var lastBatchMessageCount = 0
    }

    nonisolated let progress = ProgressState()

    private var telegramService: TelegramService?
    private var processingTask: Task<Void, Never>?
    private var prioritizedChatIds: [Int64] = []
    private var recoveryChatIds: Set<Int64> = []
    private var pendingImmediateRefresh = true
    private var lastRecoveryRefreshAt: Date?
    private var sessionStartedAt: Date?
    private var sessionRefreshedChats = 0
    private var sessionRefreshedMessages = 0
    private var lastSyncedChat: String?
    private var lastSyncAt: Date?
    private var lastBatchRefreshedChats = 0
    private var lastBatchMessageCount = 0
    private var activeRefreshes = 0

    func start(using telegramService: TelegramService) async {
        self.telegramService = telegramService
        pendingImmediateRefresh = true
        recoveryChatIds.removeAll()
        lastRecoveryRefreshAt = nil

        guard processingTask == nil else { return }

        sessionStartedAt = Date()
        sessionRefreshedChats = 0
        sessionRefreshedMessages = 0
        lastSyncedChat = nil
        lastSyncAt = nil
        lastBatchRefreshedChats = 0
        lastBatchMessageCount = 0
        activeRefreshes = 0

        processingTask = Task {
            await runLoop()
        }
    }

    func stop() async {
        let task = processingTask
        task?.cancel()
        processingTask = nil
        telegramService = nil
        prioritizedChatIds.removeAll()
        recoveryChatIds.removeAll()
        pendingImmediateRefresh = false
        lastRecoveryRefreshAt = nil
        sessionStartedAt = nil
        sessionRefreshedChats = 0
        sessionRefreshedMessages = 0
        lastSyncedChat = nil
        lastSyncAt = nil
        lastBatchRefreshedChats = 0
        lastBatchMessageCount = 0
        activeRefreshes = 0
        await task?.value
        await publishProgress(totalVisibleChats: 0, staleVisibleChats: 0)
    }

    func prioritize(chatId: Int64) async {
        prependPrioritized(chatIds: [chatId])
        pendingImmediateRefresh = true
    }

    func refreshNow() async {
        pendingImmediateRefresh = true
    }

    func recoverNow() async {
        guard let telegramService else {
            pendingImmediateRefresh = true
            return
        }
        let visibleChats = await snapshot(using: telegramService)
        scheduleRecoveryRefresh(from: visibleChats)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard let telegramService else {
                try? await Task.sleep(for: .milliseconds(Int(AppConstants.RecentSync.idlePollIntervalMilliseconds)))
                continue
            }

            let snapshot = await snapshot(using: telegramService)
            guard !snapshot.isEmpty else {
                activeRefreshes = 0
                await publishProgress(totalVisibleChats: 0, staleVisibleChats: 0)
                try? await Task.sleep(for: .milliseconds(Int(AppConstants.RecentSync.idlePollIntervalMilliseconds)))
                continue
            }

            recoveryChatIds.formIntersection(Set(snapshot.map(\.id)))
            let orderedChats = orderedChats(from: snapshot)
            let recentSyncStates = await DatabaseManager.shared.loadRecentSyncStates(in: orderedChats.map(\.id))
            let backfillStates = await DatabaseManager.shared.loadRecentBackfillStates(in: orderedChats.map(\.id))
            let selection = selectSyncChats(
                from: orderedChats,
                recentSyncStates: recentSyncStates,
                backfillStates: backfillStates,
                now: Date()
            )

            guard selection.selectedCount > 0 else {
                activeRefreshes = 0
                pendingImmediateRefresh = false
                await publishProgress(totalVisibleChats: snapshot.count, staleVisibleChats: 0)
                try? await Task.sleep(for: .milliseconds(Int(AppConstants.RecentSync.idlePollIntervalMilliseconds)))
                continue
            }

            activeRefreshes = selection.selectedCount
            await publishProgress(
                totalVisibleChats: snapshot.count,
                staleVisibleChats: selection.primaryCandidates.count + selection.retryCandidates.count
            )
            let refreshedChatIds = await sync(
                primaryChats: selection.primaryChats,
                retryChats: selection.retryChats,
                using: telegramService
            )
            if !refreshedChatIds.isEmpty {
                prioritizedChatIds.removeAll { refreshedChatIds.contains($0) }
                recoveryChatIds.subtract(refreshedChatIds)
            }

            activeRefreshes = 0
            let sleepMs = pendingImmediateRefresh
                ? AppConstants.RecentSync.activePollIntervalMilliseconds
                : AppConstants.RecentSync.idlePollIntervalMilliseconds
            pendingImmediateRefresh = false
            await publishProgress(
                totalVisibleChats: snapshot.count,
                staleVisibleChats: max(selection.primaryCandidates.count + selection.retryCandidates.count - refreshedChatIds.count, 0)
            )
            try? await Task.sleep(for: .milliseconds(Int(sleepMs)))
        }
    }

    private func snapshot(using telegramService: TelegramService) async -> [TGChat] {
        let visibleChats = await MainActor.run {
            telegramService.visibleChats
        }
        let resolvedChats = await resolveMemberCountsIfNeeded(
            in: visibleChats,
            using: telegramService
        )
        return resolvedChats.filter(Self.isIndexable)
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

            let lhsBucket = Self.bucket(for: lhs)
            let rhsBucket = Self.bucket(for: rhs)
            if lhsBucket != rhsBucket {
                return lhsBucket < rhsBucket
            }

            if lhs.order != rhs.order {
                return lhs.order > rhs.order
            }

            return lhs.id < rhs.id
        }
    }

    private func shouldRefresh(chat: TGChat, state: DatabaseManager.RecentSyncStateRecord?) -> Bool {
        let latestChatMessageId = chat.lastMessage?.id ?? 0
        guard latestChatMessageId != 0 else { return false }

        if recoveryChatIds.contains(chat.id) {
            return true
        }

        guard let state else { return true }
        if latestChatMessageId != state.latestSyncedMessageId {
            return true
        }

        guard let lastRecentSyncAt = state.lastRecentSyncAt else { return true }
        return Date().timeIntervalSince(lastRecentSyncAt) >= AppConstants.RecentSync.staleRefreshAgeSeconds
    }

    private func selectSyncChats(
        from orderedChats: [TGChat],
        recentSyncStates: [Int64: DatabaseManager.RecentSyncStateRecord],
        backfillStates: [Int64: DatabaseManager.RecentBackfillStateRecord],
        now: Date
    ) -> SyncSelection {
        let primaryCandidates = orderedChats.filter {
            shouldRefreshPrimary(
                chat: $0,
                state: recentSyncStates[$0.id],
                backfillState: backfillStates[$0.id]
            )
        }
        let primaryChats = Array(primaryCandidates.prefix(AppConstants.RecentSync.maxChatsPerPass))
        let primaryIds = Set(primaryChats.map(\.id))
        let retryCandidates = orderedChats.filter {
            !primaryIds.contains($0.id) && shouldRetryBackfill(
                chat: $0,
                state: recentSyncStates[$0.id],
                backfillState: backfillStates[$0.id],
                now: now
            )
        }
        let retryChats = Array(retryCandidates.prefix(AppConstants.RecentSync.maxRetryBackfillChatsPerPass))
        return SyncSelection(
            primaryCandidates: primaryCandidates,
            primaryChats: primaryChats,
            retryCandidates: retryCandidates,
            retryChats: retryChats
        )
    }

    private func shouldRefreshPrimary(
        chat: TGChat,
        state: DatabaseManager.RecentSyncStateRecord?,
        backfillState: DatabaseManager.RecentBackfillStateRecord?
    ) -> Bool {
        let latestChatMessageId = chat.lastMessage?.id ?? 0
        guard latestChatMessageId != 0 else { return false }

        let isManual = recoveryChatIds.contains(chat.id) || prioritizedChatIds.contains(chat.id)
        if isManual {
            return shouldRefresh(chat: chat, state: state)
        }

        guard let state else { return true }
        if latestChatMessageId != state.latestSyncedMessageId {
            if let backfillState,
               Self.isMatchingBackfill(backfillState, targetMessageId: latestChatMessageId, stopMessageId: state.latestSyncedMessageId),
               backfillState.status == "failed" {
                return false
            }
            return true
        }

        guard let lastRecentSyncAt = state.lastRecentSyncAt else { return true }
        return Date().timeIntervalSince(lastRecentSyncAt) >= AppConstants.RecentSync.staleRefreshAgeSeconds
    }

    private func shouldRetryBackfill(
        chat: TGChat,
        state: DatabaseManager.RecentSyncStateRecord?,
        backfillState: DatabaseManager.RecentBackfillStateRecord?,
        now: Date
    ) -> Bool {
        guard let latestMessageId = chat.lastMessage?.id, latestMessageId != 0,
              let state,
              state.latestSyncedMessageId != latestMessageId,
              let backfillState,
              backfillState.status == "failed",
              Self.isMatchingBackfill(
                  backfillState,
                  targetMessageId: latestMessageId,
                  stopMessageId: state.latestSyncedMessageId
              ) else {
            return false
        }

        if recoveryChatIds.contains(chat.id) || prioritizedChatIds.contains(chat.id) {
            return true
        }

        guard let nextRetryAt = backfillState.nextRetryAt else { return true }
        let isDue = nextRetryAt <= now
        if !isDue {
        }
        return isDue
    }

    private func scheduleRecoveryRefresh(from chats: [TGChat], ignoreCooldown: Bool = false) {
        let now = Date()
        if !ignoreCooldown,
           let lastRecoveryRefreshAt,
           now.timeIntervalSince(lastRecoveryRefreshAt) < AppConstants.RecentSync.recoveryRefreshCooldownSeconds {
            pendingImmediateRefresh = true
            return
        }

        let recoveryTargets = orderedChats(from: chats)
            .prefix(AppConstants.RecentSync.recoveryRefreshChatLimit)
            .map(\.id)
        guard !recoveryTargets.isEmpty else {
            pendingImmediateRefresh = true
            return
        }

        recoveryChatIds.formUnion(recoveryTargets)
        prependPrioritized(chatIds: recoveryTargets)
        pendingImmediateRefresh = true
        lastRecoveryRefreshAt = now
    }

    private func prependPrioritized(chatIds: [Int64]) {
        for chatId in chatIds.reversed() {
            prioritizedChatIds.removeAll { $0 == chatId }
            prioritizedChatIds.insert(chatId, at: 0)
        }
        if prioritizedChatIds.count > AppConstants.Indexing.maxPrioritizedChats {
            prioritizedChatIds = Array(prioritizedChatIds.prefix(AppConstants.Indexing.maxPrioritizedChats))
        }
    }

    private func sync(
        primaryChats: [TGChat],
        retryChats: [TGChat],
        using telegramService: TelegramService
    ) async -> Set<Int64> {
        var catchUpProcessed = 0
        var latestWindowChats: [TGChat] = []
        var refreshedChatIds: Set<Int64> = []

        for chat in primaryChats {
            guard !Task.isCancelled else { break }
            let state = await DatabaseManager.shared.loadRecentSyncState(chatId: chat.id)
            if Self.needsBackfill(chat: chat, state: state) {
                guard catchUpProcessed < AppConstants.RecentSync.maxBackfillChatsPerPass else {
                    continue
                }

                catchUpProcessed += 1
                let outcome = await Self.syncRecentBackfill(
                    for: chat,
                    state: state,
                    using: telegramService,
                    maxPagesPerPass: AppConstants.RecentSync.maxBackfillPagesPerPass,
                    lane: "primary"
                )
                recordOutcome(outcome)
                if outcome.completedSync {
                    refreshedChatIds.insert(outcome.chatId)
                }
            } else {
                latestWindowChats.append(chat)
            }
        }

        let batches = batchChats(latestWindowChats, size: AppConstants.RecentSync.maxConcurrentChatFetches)
        for batch in batches {
            let batchOutcomes = await withTaskGroup(of: RecentSyncOutcome.self) { group in
                for chat in batch {
                    group.addTask {
                        await Self.syncRecentWindow(for: chat, using: telegramService)
                    }
                }

                var outcomes: [RecentSyncOutcome] = []
                for await outcome in group {
                    outcomes.append(outcome)
                }
                return outcomes
            }

            batchOutcomes.forEach(recordOutcome)

            for outcome in batchOutcomes where outcome.completedSync {
                refreshedChatIds.insert(outcome.chatId)
            }
        }

        for chat in retryChats {
            guard !Task.isCancelled else { break }
            let state = await DatabaseManager.shared.loadRecentSyncState(chatId: chat.id)
            guard Self.needsBackfill(chat: chat, state: state) else { continue }
            let backfillState = await DatabaseManager.shared.loadRecentBackfillState(chatId: chat.id)
            let outcome = await Self.syncRecentBackfill(
                for: chat,
                state: state,
                using: telegramService,
                maxPagesPerPass: AppConstants.RecentSync.maxRetryBackfillPagesPerPass,
                lane: "retry"
            )
            recordOutcome(outcome)
            if outcome.completedSync {
                refreshedChatIds.insert(outcome.chatId)
            }
        }

        return refreshedChatIds
    }

    private func recordOutcome(_ outcome: RecentSyncOutcome) {
        guard outcome.refreshed else { return }
        sessionRefreshedChats += outcome.completedSync ? 1 : 0
        sessionRefreshedMessages += outcome.messageCount
        lastBatchRefreshedChats = outcome.completedSync ? 1 : 0
        lastBatchMessageCount = outcome.messageCount
        lastSyncAt = Date()
        lastSyncedChat = outcome.chatTitle
    }

    private nonisolated static func needsBackfill(
        chat: TGChat,
        state: DatabaseManager.RecentSyncStateRecord?
    ) -> Bool {
        guard let latestChatMessageId = chat.lastMessage?.id, latestChatMessageId != 0 else { return false }
        guard let state else { return false }
        return state.latestSyncedMessageId != latestChatMessageId
    }

    private nonisolated static func isMatchingBackfill(
        _ backfillState: DatabaseManager.RecentBackfillStateRecord,
        targetMessageId: Int64,
        stopMessageId: Int64
    ) -> Bool {
        backfillState.targetMessageId == targetMessageId && backfillState.stopMessageId == stopMessageId
    }

    private static func syncRecentWindow(
        for chat: TGChat,
        using telegramService: TelegramService
    ) async -> RecentSyncOutcome {
        do {
            let messages = try await telegramService.getChatHistory(
                chatId: chat.id,
                limit: AppConstants.RecentSync.latestWindowPerChat,
                onlyLocal: false,
                priority: .background,
                timeoutSeconds: AppConstants.RecentSync.historyFetchTimeoutSeconds
            )

            if !messages.isEmpty {
                await MessageCacheService.shared.cacheMessages(chatId: chat.id, messages: messages, append: false)
            } else if let latestMessageId = chat.lastMessage?.id {
                await DatabaseManager.shared.saveRecentSyncState(
                    chatId: chat.id,
                    latestSyncedMessageId: latestMessageId,
                    syncedAt: Date()
                )
            }

            return RecentSyncOutcome(
                chatId: chat.id,
                chatTitle: chat.title,
                refreshed: true,
                completedSync: true,
                messageCount: messages.count
            )
        } catch {
            return RecentSyncOutcome(
                chatId: chat.id,
                chatTitle: chat.title,
                refreshed: false,
                completedSync: false,
                messageCount: 0
            )
        }
    }

    private static func syncRecentBackfill(
        for chat: TGChat,
        state: DatabaseManager.RecentSyncStateRecord?,
        using telegramService: TelegramService,
        maxPagesPerPass: Int,
        lane: String
    ) async -> RecentSyncOutcome {
        guard let targetMessageId = chat.lastMessage?.id, targetMessageId != 0, let state else {
            return RecentSyncOutcome(
                chatId: chat.id,
                chatTitle: chat.title,
                refreshed: false,
                completedSync: false,
                messageCount: 0
            )
        }

        let stopMessageId = state.latestSyncedMessageId
        let now = Date()

        if targetMessageId < stopMessageId {
            await DatabaseManager.shared.saveRecentSyncState(
                chatId: chat.id,
                latestSyncedMessageId: targetMessageId,
                syncedAt: now
            )
            await DatabaseManager.shared.deleteRecentBackfillState(chatId: chat.id)
            return RecentSyncOutcome(
                chatId: chat.id,
                chatTitle: chat.title,
                refreshed: true,
                completedSync: true,
                messageCount: 0
            )
        }

        let existing = await DatabaseManager.shared.loadRecentBackfillState(chatId: chat.id)
        let shouldResume = existing?.targetMessageId == targetMessageId
            && existing?.stopMessageId == stopMessageId
        let startedAt = shouldResume ? (existing?.startedAt ?? now) : now
        var cursor = shouldResume ? (existing?.cursorMessageId ?? 0) : 0
        var pagesFetched = shouldResume ? (existing?.pagesFetched ?? 0) : 0
        var messagesFetched = shouldResume ? (existing?.messagesFetched ?? 0) : 0
        var passMessagesFetched = 0
        let fetchPolicy = backfillFetchPolicy(
            lane: lane,
            failureCount: shouldResume ? (existing?.failureCount ?? 0) : 0
        )

        do {
            for _ in 0..<maxPagesPerPass {
                try Task.checkCancellation()
                let requestCursor = cursor
                let messages = try await telegramService.getChatHistory(
                    chatId: chat.id,
                    fromMessageId: requestCursor,
                    limit: fetchPolicy.pageSize,
                    onlyLocal: false,
                    priority: .background,
                    timeoutSeconds: fetchPolicy.timeoutSeconds
                )

                guard !messages.isEmpty else {
                    await saveFailedBackfillState(
                        existing: existing,
                        chatId: chat.id,
                        targetMessageId: targetMessageId,
                        stopMessageId: stopMessageId,
                        cursorMessageId: cursor,
                        startedAt: startedAt,
                        pagesFetched: pagesFetched,
                        messagesFetched: messagesFetched,
                        lastError: "empty page before stop marker"
                    )
                    return RecentSyncOutcome(
                        chatId: chat.id,
                        chatTitle: chat.title,
                        refreshed: passMessagesFetched > 0,
                        completedSync: false,
                        messageCount: passMessagesFetched
                    )
                }

                await DatabaseManager.shared.upsertLiveMessages(
                    chatId: chat.id,
                    messages: messages.map(Self.messageRecord(from:)),
                    updateRecentSyncState: false
                )
                pagesFetched += 1
                messagesFetched += messages.count
                passMessagesFetched += messages.count

                if messages.contains(where: { $0.id == stopMessageId }) {
                    await DatabaseManager.shared.saveRecentSyncState(
                        chatId: chat.id,
                        latestSyncedMessageId: targetMessageId,
                        syncedAt: Date()
                    )
                    await DatabaseManager.shared.deleteRecentBackfillState(chatId: chat.id)
                    return RecentSyncOutcome(
                        chatId: chat.id,
                        chatTitle: chat.title,
                        refreshed: true,
                        completedSync: true,
                        messageCount: passMessagesFetched
                    )
                }

                guard let minimumFetchedMessageId = minimumMessageId(in: messages), minimumFetchedMessageId != cursor else {
                    await saveFailedBackfillState(
                        existing: existing,
                        chatId: chat.id,
                        targetMessageId: targetMessageId,
                        stopMessageId: stopMessageId,
                        cursorMessageId: cursor,
                        startedAt: startedAt,
                        pagesFetched: pagesFetched,
                        messagesFetched: messagesFetched,
                        lastError: "cursor did not advance"
                    )
                    return RecentSyncOutcome(
                        chatId: chat.id,
                        chatTitle: chat.title,
                        refreshed: passMessagesFetched > 0,
                        completedSync: false,
                        messageCount: passMessagesFetched
                    )
                }

                if minimumFetchedMessageId < stopMessageId {
                    await DatabaseManager.shared.saveRecentSyncState(
                        chatId: chat.id,
                        latestSyncedMessageId: targetMessageId,
                        syncedAt: Date()
                    )
                    await DatabaseManager.shared.deleteRecentBackfillState(chatId: chat.id)
                    return RecentSyncOutcome(
                        chatId: chat.id,
                        chatTitle: chat.title,
                        refreshed: true,
                        completedSync: true,
                        messageCount: passMessagesFetched
                    )
                }

                cursor = minimumFetchedMessageId
            }

            await saveBackfillState(
                chatId: chat.id,
                targetMessageId: targetMessageId,
                stopMessageId: stopMessageId,
                cursorMessageId: cursor,
                startedAt: startedAt,
                pagesFetched: pagesFetched,
                messagesFetched: messagesFetched,
                status: "active",
                lastError: nil,
                failureCount: 0,
                lastAttemptAt: now,
                nextRetryAt: nil
            )
            return RecentSyncOutcome(
                chatId: chat.id,
                chatTitle: chat.title,
                refreshed: passMessagesFetched > 0,
                completedSync: false,
                messageCount: passMessagesFetched
            )
        } catch {
            await saveFailedBackfillState(
                existing: existing,
                chatId: chat.id,
                targetMessageId: targetMessageId,
                stopMessageId: stopMessageId,
                cursorMessageId: cursor,
                startedAt: startedAt,
                pagesFetched: pagesFetched,
                messagesFetched: messagesFetched,
                lastError: error.localizedDescription
            )
            return RecentSyncOutcome(
                chatId: chat.id,
                chatTitle: chat.title,
                refreshed: passMessagesFetched > 0,
                completedSync: false,
                messageCount: passMessagesFetched
            )
        }
    }

    private static func saveBackfillState(
        chatId: Int64,
        targetMessageId: Int64,
        stopMessageId: Int64,
        cursorMessageId: Int64,
        startedAt: Date,
        pagesFetched: Int,
        messagesFetched: Int,
        status: String,
        lastError: String?,
        failureCount: Int,
        lastAttemptAt: Date?,
        nextRetryAt: Date?
    ) async {
        await DatabaseManager.shared.saveRecentBackfillState(
            DatabaseManager.RecentBackfillStateRecord(
                chatId: chatId,
                targetMessageId: targetMessageId,
                stopMessageId: stopMessageId,
                cursorMessageId: cursorMessageId,
                startedAt: startedAt,
                updatedAt: Date(),
                pagesFetched: pagesFetched,
                messagesFetched: messagesFetched,
                status: status,
                lastError: lastError,
                failureCount: failureCount,
                lastAttemptAt: lastAttemptAt,
                nextRetryAt: nextRetryAt
            )
        )
    }

    @discardableResult
    private static func saveFailedBackfillState(
        existing: DatabaseManager.RecentBackfillStateRecord?,
        chatId: Int64,
        targetMessageId: Int64,
        stopMessageId: Int64,
        cursorMessageId: Int64,
        startedAt: Date,
        pagesFetched: Int,
        messagesFetched: Int,
        lastError: String
    ) async -> DatabaseManager.RecentBackfillStateRecord {
        let now = Date()
        let failureCount = Self.isMatchingBackfill(
            existing,
            targetMessageId: targetMessageId,
            stopMessageId: stopMessageId
        )
            ? (existing?.failureCount ?? 0) + 1
            : 1
        let record = DatabaseManager.RecentBackfillStateRecord(
            chatId: chatId,
            targetMessageId: targetMessageId,
            stopMessageId: stopMessageId,
            cursorMessageId: cursorMessageId,
            startedAt: startedAt,
            updatedAt: now,
            pagesFetched: pagesFetched,
            messagesFetched: messagesFetched,
            status: "failed",
            lastError: lastError,
            failureCount: failureCount,
            lastAttemptAt: now,
            nextRetryAt: now.addingTimeInterval(retryBackoffDelay(failureCount: failureCount))
        )
        await DatabaseManager.shared.saveRecentBackfillState(record)
        return record
    }

    private nonisolated static func isMatchingBackfill(
        _ backfillState: DatabaseManager.RecentBackfillStateRecord?,
        targetMessageId: Int64,
        stopMessageId: Int64
    ) -> Bool {
        guard let backfillState else { return false }
        return isMatchingBackfill(backfillState, targetMessageId: targetMessageId, stopMessageId: stopMessageId)
    }

    private nonisolated static func retryBackoffDelay(failureCount: Int) -> TimeInterval {
        let backoffs = AppConstants.RecentSync.retryBackoffSeconds
        guard !backoffs.isEmpty else { return 0 }
        let index = min(max(1, failureCount) - 1, backoffs.count - 1)
        return backoffs[index]
    }

    private static func minimumMessageId(in messages: [TGMessage]) -> Int64? {
        messages.map(\.id).min()
    }

    private nonisolated static func backfillFetchPolicy(
        lane: String,
        failureCount: Int
    ) -> BackfillFetchPolicy {
        guard lane == "retry" else {
            return BackfillFetchPolicy(
                pageSize: AppConstants.RecentSync.backfillPageSize,
                timeoutSeconds: AppConstants.RecentSync.historyFetchTimeoutSeconds
            )
        }

        switch max(0, failureCount) {
        case 0...1:
            return BackfillFetchPolicy(pageSize: 100, timeoutSeconds: 45)
        case 2...3:
            return BackfillFetchPolicy(pageSize: 50, timeoutSeconds: 90)
        default:
            return BackfillFetchPolicy(pageSize: 25, timeoutSeconds: 180)
        }
    }

    private nonisolated static func messageRecord(from message: TGMessage) -> DatabaseManager.MessageRecord {
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

    nonisolated private static func bucket(for chat: TGChat) -> Int {
        if chat.chatType.isPrivate { return 1 }
        if chat.chatType.isGroup { return 2 }
        return 3
    }

    private func publishProgress(totalVisibleChats: Int, staleVisibleChats: Int) async {
        let snapshot = ProgressSnapshot(
            totalVisibleChats: totalVisibleChats,
            staleVisibleChats: staleVisibleChats,
            activeRefreshes: activeRefreshes,
            prioritizedChats: prioritizedChatIds.count,
            isRefreshQueued: pendingImmediateRefresh,
            sessionStartedAt: sessionStartedAt,
            sessionRefreshedChats: sessionRefreshedChats,
            sessionRefreshedMessages: sessionRefreshedMessages,
            lastSyncedChat: lastSyncedChat,
            lastSyncAt: lastSyncAt,
            lastBatchRefreshedChats: lastBatchRefreshedChats,
            lastBatchMessageCount: lastBatchMessageCount
        )

        await MainActor.run {
            progress.totalVisibleChats = snapshot.totalVisibleChats
            progress.staleVisibleChats = snapshot.staleVisibleChats
            progress.activeRefreshes = snapshot.activeRefreshes
            progress.prioritizedChats = snapshot.prioritizedChats
            progress.isRefreshQueued = snapshot.isRefreshQueued
            progress.sessionStartedAt = snapshot.sessionStartedAt
            progress.sessionRefreshedChats = snapshot.sessionRefreshedChats
            progress.sessionRefreshedMessages = snapshot.sessionRefreshedMessages
            progress.lastSyncedChat = snapshot.lastSyncedChat
            progress.lastSyncAt = snapshot.lastSyncAt
            progress.lastBatchRefreshedChats = snapshot.lastBatchRefreshedChats
            progress.lastBatchMessageCount = snapshot.lastBatchMessageCount
        }
    }

#if DEBUG
    func scheduleRecoveryRefreshForTesting(chats: [TGChat], ignoreCooldown: Bool = true) async {
        scheduleRecoveryRefresh(from: chats, ignoreCooldown: ignoreCooldown)
    }

    func shouldRefreshForTesting(
        chat: TGChat,
        state: DatabaseManager.RecentSyncStateRecord?
    ) async -> Bool {
        shouldRefresh(chat: chat, state: state)
    }

    func recoveryChatIdsForTesting() async -> Set<Int64> {
        recoveryChatIds
    }

    func indexableChatsForTesting(using telegramService: TelegramService) async -> [TGChat] {
        await snapshot(using: telegramService)
    }

    func syncChatsForTesting(chats: [TGChat], using telegramService: TelegramService) async -> Set<Int64> {
        await sync(primaryChats: chats, retryChats: [], using: telegramService)
    }

    func syncSelectedChatsForTesting(
        primaryChats: [TGChat],
        retryChats: [TGChat],
        using telegramService: TelegramService
    ) async -> Set<Int64> {
        await sync(primaryChats: primaryChats, retryChats: retryChats, using: telegramService)
    }

    func selectedSyncChatIdsForTesting(chats: [TGChat], now: Date = Date()) async -> ([Int64], [Int64]) {
        let orderedChats = orderedChats(from: chats)
        let recentSyncStates = await DatabaseManager.shared.loadRecentSyncStates(in: orderedChats.map(\.id))
        let backfillStates = await DatabaseManager.shared.loadRecentBackfillStates(in: orderedChats.map(\.id))
        let selection = selectSyncChats(
            from: orderedChats,
            recentSyncStates: recentSyncStates,
            backfillStates: backfillStates,
            now: now
        )
        return (selection.primaryChats.map(\.id), selection.retryChats.map(\.id))
    }

    nonisolated static func backfillFetchPolicyForTesting(
        lane: String,
        failureCount: Int
    ) -> (pageSize: Int, timeoutSeconds: TimeInterval) {
        let policy = backfillFetchPolicy(lane: lane, failureCount: failureCount)
        return (policy.pageSize, policy.timeoutSeconds)
    }
#endif
}

private func batchChats<T>(_ items: [T], size: Int) -> [[T]] {
    guard size > 0 else { return [items] }

    var chunks: [[T]] = []
    chunks.reserveCapacity((items.count / size) + 1)

    var index = 0
    while index < items.count {
        let nextIndex = min(items.count, index + size)
        chunks.append(Array(items[index..<nextIndex]))
        index = nextIndex
    }

    return chunks
}
