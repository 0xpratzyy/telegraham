import Combine
import Foundation

@MainActor
final class AttentionStore: ObservableObject {
    static let shared = AttentionStore()

    @Published private(set) var followUpItems: [FollowUpItem] = []
    @Published private(set) var isFollowUpsLoading = false
    @Published private(set) var pipelineProcessedCount = 0
    @Published private(set) var pipelineTotalCount = 0

    private var backgroundRefreshTask: Task<Void, Never>?
    private var queuedRefreshRequest: RefreshRequest?

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
        guard !isFollowUpsLoading else {
            queueRefresh(
                telegramService: telegramService,
                aiService: aiService,
                includeBots: includeBots,
                force: force
            )
            return
        }

        let candidates = collectPipelineCandidates(
            telegramService: telegramService,
            includeBots: includeBots
        )

        guard aiService.isConfigured else {
            followUpItems = FollowUpPipelineAnalyzer.buildRuleBasedFallbackItems(
                from: candidates,
                myUserId: telegramService.currentUser?.id
            )
            pipelineProcessedCount = followUpItems.count
            pipelineTotalCount = followUpItems.count
            postOnMeBadge()
            return
        }

        pipelineProcessedCount = 0
        pipelineTotalCount = 0
        isFollowUpsLoading = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isFollowUpsLoading = false
                self.runQueuedRefreshIfNeeded()
            }

            let myUserId = telegramService.currentUser?.id ?? 0
            let cache = MessageCacheService.shared

            var cachedItems: [FollowUpItem] = []
            var staleChats: [TGChat] = []

            for chat in candidates {
                guard let lastMessage = chat.lastMessage else { continue }

                if let cached = await cache.getPipelineCategory(chatId: chat.id),
                   cached.lastMessageId == lastMessage.id {
                    let cachedCategory: FollowUpItem.Category
                    switch cached.category {
                    case "on_me":
                        cachedCategory = .onMe
                    case "on_them":
                        cachedCategory = .onThem
                    default:
                        cachedCategory = .quiet
                    }

                    cachedItems.append(FollowUpItem(
                        chat: chat,
                        category: cachedCategory,
                        lastMessage: lastMessage,
                        timeSinceLastActivity: Date().timeIntervalSince(lastMessage.date),
                        suggestedAction: cached.suggestedAction.isEmpty ? nil : cached.suggestedAction
                    ))

                    if force {
                        staleChats.append(chat)
                    }
                } else {
                    staleChats.append(chat)
                }
            }

            followUpItems = cachedItems
            sortPipelineItems()

            guard !staleChats.isEmpty else {
                return
            }

            pipelineProcessedCount = 0
            pipelineTotalCount = staleChats.count

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
        guard !followUpItems.isEmpty, aiService.isConfigured, !isFollowUpsLoading else { return }

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

            for chat in newCandidates {
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
