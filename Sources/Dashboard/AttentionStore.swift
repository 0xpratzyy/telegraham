import Combine
import Foundation

@MainActor
final class AttentionStore: ObservableObject {
    static let shared = AttentionStore()

    @Published private(set) var followUpItems: [FollowUpItem] = []
    @Published private(set) var isFollowUpsLoading = false
    @Published private(set) var pipelineProcessedCount = 0
    @Published private(set) var pipelineTotalCount = 0
    /// Stamp set when the most recent reply-queue refresh finishes. Used by
    /// DashboardTopBar to render the "Updated Nm ago" label on the Reply
    /// Queue page. Tasks-page refreshes use TaskIndexCoordinator.lastRefreshAt
    /// instead — these two refreshes have wildly different durations and
    /// can't share one timestamp without confusing the UI.
    @Published private(set) var lastFollowUpsRefreshAt: Date?

    private var backgroundRefreshTask: Task<Void, Never>?
    private var cachedHydrationTask: Task<Void, Never>?
    private var queuedRefreshRequest: RefreshRequest?
    /// Non-published lock so `loadFollowUps` calls overlap-coalesce
    /// correctly even when no AI work needs to run. `isFollowUpsLoading`
    /// stays decoupled — it only flips when AI is genuinely active, so
    /// the Refresh button doesn't flicker on every cache-hit refresh.
    private var isExecuting = false

    private init() {}

    private struct RefreshRequest {
        let telegramService: TelegramService
        let aiService: AIService
        let includeBots: Bool
        let force: Bool
    }

    func pipelineCategory(for chatId: Int64) -> FollowUpItem.Category? {
        followUpItems.first(where: { $0.chat.id == chatId })?.category
    }

    func pipelineSuggestion(for chatId: Int64) -> String? {
        followUpItems.first(where: { $0.chat.id == chatId })?.suggestedAction
    }

    func loadFollowUps(
        telegramService: TelegramService,
        aiService: AIService,
        includeBots: Bool,
        force: Bool = false
    ) {
        guard !isExecuting else {
            queueRefresh(
                telegramService: telegramService,
                aiService: aiService,
                includeBots: includeBots,
                force: force
            )
            return
        }
        isExecuting = true

        let candidates = collectPipelineCandidates(
            telegramService: telegramService,
            includeBots: includeBots
        )

        pipelineProcessedCount = 0
        pipelineTotalCount = 0
        // NOTE: Don't set isFollowUpsLoading = true here. The auto-refresh
        // on visibleChatIDs changes fires constantly (every TDLib chat
        // update), and most of those firings find every candidate already
        // cached → no AI work needed. Flipping the loading bit before
        // knowing if there's work caused the "Refreshing" button to flicker
        // on/off every time TDLib pushed an update. Defer to the Task below
        // where we know whether staleChats is non-empty.

        Task { @MainActor [weak self] in
            guard let self else { return }
            // We only mark as "Refreshing" when AI work is actually queued.
            // The completion arm below mirrors the entry — it only clears
            // the loading bit if we set it.
            var didFlipLoadingFlag = false
            defer {
                if didFlipLoadingFlag {
                    self.isFollowUpsLoading = false
                }
                self.lastFollowUpsRefreshAt = Date()
                self.isExecuting = false
                self.runQueuedRefreshIfNeeded()
            }

            let myUserId = telegramService.currentUser?.id ?? 0
            let cache = MessageCacheService.shared

            // First pass: prefer cached AI categories for every candidate.
            // The previous code had a synchronous `guard aiService.isConfigured
            // else { followUpItems = ruleBased(...); return }` early-return
            // that wholesale-replaced followUpItems with rule-based items.
            // That fought with hydrateCachedFollowUps (which writes cached
            // AI categories) every time .onChange(visibleChatIDs) fired
            // during the AIService init window, ping-ponging rows between
            // feed sections for ~20s after launch. Hoisting cache reads
            // ahead of both branches makes cached values authoritative; rule-
            // based only fills gaps.
            var initialItems: [FollowUpItem] = []
            var staleChats: [TGChat] = []

            for chat in candidates {
                if let cachedItem = await cachedPipelineItem(for: chat, cache: cache) {
                    initialItems.append(cachedItem)
                    if force {
                        staleChats.append(chat)
                    }
                } else {
                    staleChats.append(chat)
                }
            }

            if !aiService.isConfigured {
                // Fill cache misses with rule-based heuristics so brand-new
                // chats still appear. Existing cached categories are left
                // intact — they're strictly higher-quality than the rules.
                let cachedIds = Set(initialItems.map(\.chat.id))
                let chatsWithoutCache = candidates.filter { !cachedIds.contains($0.id) }
                if !chatsWithoutCache.isEmpty {
                    let ruleBasedItems = FollowUpPipelineAnalyzer.buildRuleBasedFallbackItems(
                        from: chatsWithoutCache,
                        myUserId: telegramService.currentUser?.id
                    )
                    initialItems.append(contentsOf: ruleBasedItems)
                }
                self.followUpItems = initialItems
                self.sortPipelineItems()
                self.pipelineProcessedCount = initialItems.count
                self.pipelineTotalCount = initialItems.count
                self.postOnMeBadge()
                return
            }

            self.followUpItems = initialItems
            self.sortPipelineItems()

            guard !staleChats.isEmpty else {
                return
            }

            // Flip the loading bit now that we know there's real AI work
            // queued. Anything reaching this point will run `categorizeChat`
            // for each entry in staleChats, which takes seconds-to-minutes.
            self.isFollowUpsLoading = true
            didFlipLoadingFlag = true

            self.pipelineProcessedCount = 0
            self.pipelineTotalCount = staleChats.count

            let maxConcurrency = AppConstants.FollowUp.maxAIConcurrency

            await withTaskGroup(of: FollowUpItem?.self) { group in
                var queued = 0

                for chat in staleChats {
                    if queued >= maxConcurrency {
                        if let result = await group.next() {
                            self.pipelineProcessedCount += 1
                            if let item = result {
                                self.upsertPipelineItem(item)
                            }
                        }
                        queued -= 1
                    }

                    group.addTask {
                        await FollowUpPipelineAnalyzer.categorizeChat(
                            chat: chat,
                            myUserId: myUserId,
                            telegramService: telegramService,
                            aiService: aiService
                        )
                    }
                    queued += 1
                }

                for await result in group {
                    self.pipelineProcessedCount += 1
                    if let item = result {
                        self.upsertPipelineItem(item)
                    }
                }
            }

        }
    }

    func hydrateCachedFollowUps(
        telegramService: TelegramService,
        includeBots: Bool
    ) {
        let candidates = collectPipelineCandidates(
            telegramService: telegramService,
            includeBots: includeBots
        )
        guard !candidates.isEmpty else { return }

        cachedHydrationTask?.cancel()
        cachedHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let cache = MessageCacheService.shared

            for chat in candidates {
                guard !Task.isCancelled else { return }
                if let cachedItem = await self.cachedPipelineItem(for: chat, cache: cache) {
                    self.upsertPipelineItem(cachedItem)
                }
            }
        }
    }

    private func queueRefresh(
        telegramService: TelegramService,
        aiService: AIService,
        includeBots: Bool,
        force: Bool
    ) {
        let force = force || queuedRefreshRequest?.force == true
        queuedRefreshRequest = RefreshRequest(
            telegramService: telegramService,
            aiService: aiService,
            includeBots: includeBots,
            force: force
        )
    }

    private func runQueuedRefreshIfNeeded() {
        guard let request = queuedRefreshRequest else { return }
        queuedRefreshRequest = nil
        loadFollowUps(
            telegramService: request.telegramService,
            aiService: request.aiService,
            includeBots: request.includeBots,
            force: request.force
        )
    }

    func backgroundRefreshPipeline(
        telegramService: TelegramService,
        aiService: AIService,
        includeBots: Bool
    ) {
        guard !followUpItems.isEmpty, aiService.isConfigured, !isExecuting else { return }

        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let myUserId = telegramService.currentUser?.id ?? 0

            var staleChats: [TGChat] = []
            for item in followUpItems {
                guard let currentChat = telegramService.visibleChats.first(where: { $0.id == item.chat.id }),
                      let currentLastMessage = currentChat.lastMessage else {
                    continue
                }
                if currentLastMessage.id != item.lastMessage.id {
                    staleChats.append(currentChat)
                }
            }

            let existingIds = Set(followUpItems.map(\.chat.id))
            let newCandidates = collectPipelineCandidates(
                telegramService: telegramService,
                includeBots: includeBots
            )
            .filter { !existingIds.contains($0.id) }

            guard !staleChats.isEmpty || !newCandidates.isEmpty else { return }
            let cache = MessageCacheService.shared

            for chat in staleChats {
                guard !Task.isCancelled else { return }
                if let updatedItem = await FollowUpPipelineAnalyzer.categorizeChat(
                    chat: chat,
                    myUserId: myUserId,
                    telegramService: telegramService,
                    aiService: aiService
                ) {
                    upsertPipelineItem(updatedItem)
                }
            }

            var uncachedNewCandidates: [TGChat] = []
            for chat in newCandidates {
                guard !Task.isCancelled else { return }
                if let cachedItem = await cachedPipelineItem(for: chat, cache: cache) {
                    upsertPipelineItem(cachedItem)
                } else {
                    uncachedNewCandidates.append(chat)
                }
            }

            for chat in uncachedNewCandidates {
                guard !Task.isCancelled else { return }
                if let newItem = await FollowUpPipelineAnalyzer.categorizeChat(
                    chat: chat,
                    myUserId: myUserId,
                    telegramService: telegramService,
                    aiService: aiService
                ) {
                    upsertPipelineItem(newItem)
                }
            }

            let candidateIds = Set(collectPipelineCandidates(
                telegramService: telegramService,
                includeBots: includeBots
            ).map(\.id))
            if followUpItems.contains(where: { !candidateIds.contains($0.chat.id) }) {
                followUpItems.removeAll { !candidateIds.contains($0.chat.id) }
                sortPipelineItems()
            }
        }
    }

    private func cachedPipelineItem(
        for chat: TGChat,
        cache: MessageCacheService
    ) async -> FollowUpItem? {
        guard let lastMessage = chat.lastMessage,
              let cached = await cache.getPipelineCategory(chatId: chat.id),
              cached.lastMessageId == lastMessage.id else {
            return nil
        }

        let cachedCategory: FollowUpItem.Category
        switch cached.category {
        case "on_me":
            cachedCategory = .onMe
        case "on_them":
            cachedCategory = .onThem
        default:
            cachedCategory = .quiet
        }

        return FollowUpItem(
            chat: chat,
            category: cachedCategory,
            lastMessage: lastMessage,
            timeSinceLastActivity: Date().timeIntervalSince(lastMessage.date),
            suggestedAction: cached.suggestedAction.isEmpty ? nil : cached.suggestedAction
        )
    }

    private func collectPipelineCandidates(
        telegramService: TelegramService,
        includeBots: Bool
    ) -> [TGChat] {
        FollowUpPipelineAnalyzer.collectCandidateChats(
            from: telegramService.visibleChats,
            includeBots: includeBots,
            isLikelyBot: { telegramService.isLikelyBotChat($0) }
        )
    }

    private func upsertPipelineItem(_ item: FollowUpItem) {
        followUpItems.removeAll { $0.chat.id == item.chat.id }
        followUpItems.append(item)
        sortPipelineItems()
    }

    private func sortPipelineItems() {
        followUpItems.sort { a, b in
            let order: [FollowUpItem.Category] = [.onMe, .onThem, .quiet]
            let aIndex = order.firstIndex(of: a.category) ?? 2
            let bIndex = order.firstIndex(of: b.category) ?? 2
            if aIndex != bIndex {
                return aIndex < bIndex
            }
            return a.timeSinceLastActivity < b.timeSinceLastActivity
        }
        postOnMeBadge()
    }

    private func postOnMeBadge() {
        let count = followUpItems.filter { $0.category == .onMe }.count
        NotificationCenter.default.post(
            name: .onMeCountChanged,
            object: nil,
            userInfo: ["count": count]
        )
    }
}
