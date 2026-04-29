import Combine
import Foundation

@MainActor
final class TaskIndexCoordinator: ObservableObject {
    static let shared = TaskIndexCoordinator()

    private struct PendingTaskScan: Sendable {
        let chat: TGChat
        let messages: [TGMessage]
        let latestMessageId: Int64
    }

    private struct RefreshRequest {
        let telegramService: TelegramService
        let aiService: AIService
        let includeBotsInAISearch: Bool
        let forceRescan: Bool
    }

    @Published private(set) var topics: [DashboardTopic] = []
    @Published private(set) var tasks: [DashboardTask] = []
    @Published private(set) var evidenceByTaskId: [Int64: [DashboardTaskSourceMessage]] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastError: String?

    private var refreshLoopTask: Task<Void, Never>?
    private var lastTopicDiscoveryAt: Date?
    private var includeBotsInAISearch = false
    private weak var filteringTelegramService: TelegramService?
    private var queuedRefreshRequest: RefreshRequest?

    private init() {}

    func start(
        telegramService: TelegramService,
        aiService: AIService,
        includeBotsInAISearch: Bool
    ) {
        self.includeBotsInAISearch = includeBotsInAISearch
        filteringTelegramService = telegramService
        if refreshLoopTask != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await loadFromStore(
                    telegramService: telegramService,
                    includeBotsInAISearch: includeBotsInAISearch
                )
                await refreshNow(
                    telegramService: telegramService,
                    aiService: aiService,
                    includeBotsInAISearch: includeBotsInAISearch
                )
            }
            return
        }

        refreshLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadFromStore(
                telegramService: telegramService,
                includeBotsInAISearch: self.includeBotsInAISearch
            )
            await refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: self.includeBotsInAISearch
            )

            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(AppConstants.Dashboard.taskRefreshIntervalSeconds)
                )
                guard !Task.isCancelled else { return }
                await refreshNow(
                    telegramService: telegramService,
                    aiService: aiService,
                    includeBotsInAISearch: self.includeBotsInAISearch
                )
            }
        }
    }

    func stop() {
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
    }

    func setBotInclusion(
        _ includeBotsInAISearch: Bool,
        telegramService: TelegramService
    ) async {
        self.includeBotsInAISearch = includeBotsInAISearch
        filteringTelegramService = telegramService
        await loadFromStore(
            telegramService: telegramService,
            includeBotsInAISearch: includeBotsInAISearch
        )
    }

    func loadFromStore(
        telegramService: TelegramService? = nil,
        includeBotsInAISearch: Bool? = nil
    ) async {
        let includeBotsInAISearch = includeBotsInAISearch ?? self.includeBotsInAISearch
        let telegramService = telegramService ?? filteringTelegramService
        let loadedTopics = await DatabaseManager.shared.loadDashboardTopics()
        let loadedTasks = await DatabaseManager.shared.loadDashboardTasks()
        let visibleTasks = await botFilteredTasks(
            loadedTasks,
            telegramService: telegramService,
            includeBotsInAISearch: includeBotsInAISearch
        )
        let loadedEvidence = await DatabaseManager.shared.loadDashboardTaskEvidence(
            taskIds: visibleTasks.map(\.id)
        )

        topics = loadedTopics
        tasks = visibleTasks
        evidenceByTaskId = loadedEvidence
    }

    func refreshNow(
        telegramService: TelegramService,
        aiService: AIService,
        includeBotsInAISearch: Bool? = nil,
        forceRescan: Bool = false
    ) async {
        let includeBotsInAISearch = includeBotsInAISearch ?? self.includeBotsInAISearch
        let request = RefreshRequest(
            telegramService: telegramService,
            aiService: aiService,
            includeBotsInAISearch: includeBotsInAISearch,
            forceRescan: forceRescan
        )

        guard !isRefreshing else {
            queueRefresh(request)
            return
        }

        isRefreshing = true

        defer {
            isRefreshing = false
        }

        var nextRequest: RefreshRequest? = request
        while let activeRequest = nextRequest {
            nextRequest = nil
            await performRefresh(activeRequest)

            if let queuedRefreshRequest {
                self.queuedRefreshRequest = nil
                nextRequest = queuedRefreshRequest
            }
        }
    }

    private func queueRefresh(_ request: RefreshRequest) {
        let forceRescan = request.forceRescan || queuedRefreshRequest?.forceRescan == true
        queuedRefreshRequest = RefreshRequest(
            telegramService: request.telegramService,
            aiService: request.aiService,
            includeBotsInAISearch: request.includeBotsInAISearch,
            forceRescan: forceRescan
        )
    }

    private func performRefresh(_ request: RefreshRequest) async {
        let telegramService = request.telegramService
        let aiService = request.aiService
        let includeBotsInAISearch = request.includeBotsInAISearch

        self.includeBotsInAISearch = includeBotsInAISearch
        filteringTelegramService = telegramService
        lastError = nil

        await loadFromStore(
            telegramService: telegramService,
            includeBotsInAISearch: includeBotsInAISearch
        )

        guard aiService.isConfigured else {
            lastError = "Connect an AI provider to extract tasks from Telegram."
            return
        }

        guard telegramService.authState == .ready else {
            lastError = "Telegram is not ready yet."
            return
        }

        await telegramService.ensureBotFilterMetadataReady(
            for: telegramService.visibleChats,
            includeBots: includeBotsInAISearch,
            priority: .background
        )

        let activeTopics = await refreshTopicsIfNeeded(
            telegramService: telegramService,
            aiService: aiService,
            includeBotsInAISearch: includeBotsInAISearch
        )
        let myUserId = telegramService.currentUser?.id ?? 0
        let candidateChats = await Self.candidateChats(
            from: telegramService.visibleChats,
            telegramService: telegramService,
            includeBotsInAISearch: includeBotsInAISearch
        )
        let pendingScans = await Self.pendingTaskScans(
            from: candidateChats,
            forceRescan: request.forceRescan
        )

        guard !pendingScans.isEmpty else {
            lastRefreshAt = Date()
            return
        }

        let triageByChatId: [Int64: DashboardTaskTriageResultDTO]
        do {
            triageByChatId = try await Self.triagePendingTaskScans(
                pendingScans,
                aiService: aiService,
                myUserId: myUserId
            )
        } catch {
            lastError = "Task triage failed: \(error.localizedDescription)"
            return
        }

        for pending in pendingScans {
            guard !Task.isCancelled else { return }

            guard let triage = triageByChatId[pending.chat.id] else { continue }
            guard triage.route == .effortTask else {
                await DatabaseManager.shared.ignoreOpenDashboardTasks(
                    chatId: pending.chat.id,
                    matchingSourceMessageIds: triage.supportingMessageIds
                )
                await DatabaseManager.shared.updateDashboardTaskSyncState(
                    chatId: pending.chat.id,
                    latestMessageId: pending.latestMessageId
                )
                continue
            }

            do {
                let resolvedMemberCount = await telegramService.resolvedMemberCount(for: pending.chat)
                let effectiveChat = pending.chat.updating(memberCount: resolvedMemberCount ?? pending.chat.memberCount)
                let candidates = try await aiService.extractDashboardTasks(
                    chat: effectiveChat,
                    messages: pending.messages,
                    topics: activeTopics,
                    myUserId: myUserId
                )
                let evidencedCandidates = candidates.filter { !$0.sourceMessages.isEmpty }
                if !evidencedCandidates.isEmpty {
                    _ = await DatabaseManager.shared.upsertDashboardTasks(evidencedCandidates)
                }
                await DatabaseManager.shared.updateDashboardTaskSyncState(
                    chatId: pending.chat.id,
                    latestMessageId: pending.latestMessageId
                )
            } catch {
                lastError = "Task extraction failed for \(pending.chat.title): \(error.localizedDescription)"
                continue
            }
        }

        lastRefreshAt = Date()
        await loadFromStore(
            telegramService: telegramService,
            includeBotsInAISearch: includeBotsInAISearch
        )
    }

    func updateStatus(
        task: DashboardTask,
        status: DashboardTaskStatus,
        snoozedUntil: Date? = nil
    ) async {
        await DatabaseManager.shared.updateDashboardTaskStatus(
            taskId: task.id,
            status: status,
            snoozedUntil: snoozedUntil
        )
        await loadFromStore()
    }

    private func refreshTopicsIfNeeded(
        telegramService: TelegramService,
        aiService: AIService,
        includeBotsInAISearch: Bool
    ) async -> [DashboardTopic] {
        let stored = await DatabaseManager.shared.loadDashboardTopics()
        let shouldDiscover = stored.isEmpty || lastTopicDiscoveryAt.map {
            Date().timeIntervalSince($0) > AppConstants.Dashboard.taskRefreshIntervalSeconds * 6
        } ?? true

        guard shouldDiscover else {
            topics = stored
            return stored
        }

        let excludedChatIds = await Self.botChatIds(
            in: telegramService.visibleChats,
            telegramService: telegramService,
            includeBotsInAISearch: includeBotsInAISearch
        )
        let records = await DatabaseManager.shared.loadSearchableMessages(
            limit: AppConstants.Dashboard.topicDiscoveryMessageLimit
        ).filter { !excludedChatIds.contains($0.chatId) }
        guard !records.isEmpty else {
            topics = stored
            return stored
        }

        let titleByChatId = Dictionary(
            uniqueKeysWithValues: telegramService.visibleChats.map { ($0.id, $0.title) }
        )
        let messages = records.map { record in
            Self.tgMessage(
                from: record,
                chatTitle: titleByChatId[record.chatId]
            )
        }

        do {
            let discovered = try await aiService.discoverDashboardTopics(messages: messages)
            lastTopicDiscoveryAt = Date()
            let updated = await DatabaseManager.shared.upsertDashboardTopics(discovered)
            topics = updated
            return updated
        } catch {
            lastError = "Topic discovery failed: \(error.localizedDescription)"
            topics = stored
            return stored
        }
    }

    private func botFilteredTasks(
        _ loadedTasks: [DashboardTask],
        telegramService: TelegramService?,
        includeBotsInAISearch: Bool
    ) async -> [DashboardTask] {
        guard let telegramService else { return loadedTasks }
        let taskChatIds = Set(loadedTasks.map(\.chatId))
        var relevantChats = telegramService.visibleChats.filter { taskChatIds.contains($0.id) }
        var resolvedChatIds = Set(relevantChats.map(\.id))

        for chatId in taskChatIds.subtracting(resolvedChatIds) {
            guard let chat = try? await telegramService.getChat(id: chatId) else { continue }
            relevantChats.append(chat)
            resolvedChatIds.insert(chat.id)
        }

        let excludedChatIds = await Self.botChatIds(
            in: relevantChats,
            telegramService: telegramService,
            includeBotsInAISearch: includeBotsInAISearch
        )
        return DashboardTaskFilter.excludingChatIds(loadedTasks, excludedChatIds)
    }

    private static func botChatIds(
        in chats: [TGChat],
        telegramService: TelegramService,
        includeBotsInAISearch: Bool
    ) async -> Set<Int64> {
        guard !includeBotsInAISearch else { return [] }

        var excludedChatIds = Set<Int64>()
        for chat in chats where await telegramService.isBotChat(chat) {
            excludedChatIds.insert(chat.id)
        }
        return excludedChatIds
    }

    private static func candidateChats(
        from chats: [TGChat],
        telegramService: TelegramService,
        includeBotsInAISearch: Bool
    ) async -> [TGChat] {
        let sorted = chats
            .filter { $0.isInMainList && !$0.chatType.isChannel }
            .sorted {
                let lhsDate = $0.lastMessage?.date ?? .distantPast
                let rhsDate = $1.lastMessage?.date ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }

        guard !includeBotsInAISearch else {
            return Array(sorted.prefix(AppConstants.Dashboard.taskTriageChatLimit))
        }

        var filtered: [TGChat] = []
        filtered.reserveCapacity(min(sorted.count, AppConstants.Dashboard.taskTriageChatLimit))

        for chat in sorted {
            guard filtered.count < AppConstants.Dashboard.taskTriageChatLimit else { break }
            if await telegramService.isBotChat(chat) { continue }
            filtered.append(chat)
        }

        return filtered
    }

    private static func pendingTaskScans(
        from chats: [TGChat],
        forceRescan: Bool = false
    ) async -> [PendingTaskScan] {
        var pending: [PendingTaskScan] = []
        pending.reserveCapacity(chats.count)

        for chat in chats {
            guard !Task.isCancelled else { break }

            let records = await DatabaseManager.shared.loadMessages(
                chatId: chat.id,
                limit: AppConstants.Dashboard.taskExtractionMessagesPerChat
            )
            guard let latestMessageId = records.map(\.id).max() else {
                continue
            }

            let syncState = await DatabaseManager.shared.loadDashboardTaskSyncState(chatId: chat.id)
            guard DashboardTaskRefreshPolicy.shouldScan(
                latestMessageId: latestMessageId,
                syncedLatestMessageId: syncState?.latestMessageId,
                forceRescan: forceRescan
            ) else {
                continue
            }

            let messages = records.map { Self.tgMessage(from: $0, chat: chat) }
            guard !messages.isEmpty else { continue }
            pending.append(PendingTaskScan(
                chat: chat,
                messages: messages,
                latestMessageId: latestMessageId
            ))
        }

        return pending
    }

    private static func triagePendingTaskScans(
        _ pending: [PendingTaskScan],
        aiService: AIService,
        myUserId: Int64
    ) async throws -> [Int64: DashboardTaskTriageResultDTO] {
        var triageByChatId: [Int64: DashboardTaskTriageResultDTO] = [:]

        for batch in pending.chunked(into: AppConstants.Dashboard.taskTriageBatchSize) {
            let candidates = batch.map {
                DashboardTaskTriageCandidate(chat: $0.chat, messages: $0.messages)
            }
            let decisions = try await aiService.triageDashboardTaskCandidates(
                candidates,
                myUserId: myUserId
            )
            for decision in decisions {
                triageByChatId[decision.chatId] = decision
            }
        }

        return triageByChatId
    }

    private static func tgMessage(from record: DatabaseManager.MessageRecord, chat: TGChat) -> TGMessage {
        tgMessage(from: record, chatTitle: chat.title)
    }

    private static func tgMessage(
        from record: DatabaseManager.MessageRecord,
        chatTitle: String?
    ) -> TGMessage {
        let senderId: TGMessage.MessageSenderId = record.senderUserId.map { .user($0) } ?? .chat(record.chatId)
        return TGMessage(
            id: record.id,
            chatId: record.chatId,
            senderId: senderId,
            date: record.date,
            textContent: record.textContent,
            mediaType: record.mediaTypeRaw.flatMap(TGMessage.MediaType.init(rawValue:)),
            isOutgoing: record.isOutgoing,
            chatTitle: chatTitle,
            senderName: record.senderName
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count / size) + 1)

        var index = startIndex
        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }

        return chunks
    }
}
