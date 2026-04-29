import Foundation

actor RecentSyncCoordinator {
    static let shared = RecentSyncCoordinator()

    private struct RecentSyncOutcome: Sendable {
        let chatId: Int64
        let chatTitle: String
        let refreshed: Bool
        let messageCount: Int
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
            let staleChats = orderedChats.filter { shouldRefresh(chat: $0, state: recentSyncStates[$0.id]) }
            let nextChats = Array(staleChats.prefix(AppConstants.RecentSync.maxChatsPerPass))

            guard !nextChats.isEmpty else {
                activeRefreshes = 0
                pendingImmediateRefresh = false
                await publishProgress(totalVisibleChats: snapshot.count, staleVisibleChats: 0)
                try? await Task.sleep(for: .milliseconds(Int(AppConstants.RecentSync.idlePollIntervalMilliseconds)))
                continue
            }

            activeRefreshes = nextChats.count
            await publishProgress(totalVisibleChats: snapshot.count, staleVisibleChats: staleChats.count)
            let refreshedChatIds = await sync(chats: nextChats, using: telegramService)
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
                staleVisibleChats: max(staleChats.count - refreshedChatIds.count, 0)
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

    private func sync(chats: [TGChat], using telegramService: TelegramService) async -> Set<Int64> {
        let batches = batchChats(chats, size: AppConstants.RecentSync.maxConcurrentChatFetches)
        var refreshedChatIds: Set<Int64> = []

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

            let refreshedOutcomes = batchOutcomes.filter(\.refreshed)
            if !refreshedOutcomes.isEmpty {
                sessionRefreshedChats += refreshedOutcomes.count
                let refreshedMessageCount = refreshedOutcomes.reduce(0) { $0 + $1.messageCount }
                sessionRefreshedMessages += refreshedMessageCount
                lastBatchRefreshedChats = refreshedOutcomes.count
                lastBatchMessageCount = refreshedMessageCount
                lastSyncAt = Date()
                if let mostRecent = refreshedOutcomes.max(by: { $0.messageCount < $1.messageCount }) {
                    lastSyncedChat = mostRecent.chatTitle
                }
            }

            for outcome in batchOutcomes where outcome.refreshed {
                refreshedChatIds.insert(outcome.chatId)
            }
        }

        return refreshedChatIds
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
                priority: .background
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
                messageCount: messages.count
            )
        } catch {
            return RecentSyncOutcome(
                chatId: chat.id,
                chatTitle: chat.title,
                refreshed: false,
                messageCount: 0
            )
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
