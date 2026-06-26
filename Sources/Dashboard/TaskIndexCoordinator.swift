import Combine
import Foundation
import OSLog

@MainActor
final class TaskIndexCoordinator: ObservableObject {
    static let shared = TaskIndexCoordinator()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pidgy.app",
        category: "TaskIndex"
    )

    private struct PendingTaskScan: Sendable {
        let chat: TGChat
        let messages: [TGMessage]
        let latestMessageId: Int64
        let openTasks: [DashboardTask]
        let openTaskEvidenceByTaskId: [Int64: [DashboardTaskSourceMessage]]
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
    /// True while the refresh machinery is busy. Set by every refresh,
    /// including background ticks and the debounced refresh that fires
    /// after message bursts. Other code (e.g. the background pipeline)
    /// uses this to know if work is in flight. The Tasks page UI should
    /// NOT bind to this directly — it makes the button perpetually spin
    /// on active accounts. Use `isUserInitiatedRefreshing` instead.
    @Published private(set) var isRefreshing = false
    /// True only while a user-initiated refresh is running — the button
    /// the user actually clicked. Reset as soon as that specific request
    /// (plus its queued continuations) drains. Background / periodic /
    /// debounced refreshes leave this `false`.
    @Published private(set) var isUserInitiatedRefreshing = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastError: String?

    private var refreshLoopTask: Task<Void, Never>?
    private var lastTopicDiscoveryAt: Date?
    private var includeBotsInAISearch = false
    private weak var filteringTelegramService: TelegramService?
    private weak var filteringAIService: AIService?
    private var queuedRefreshRequest: RefreshRequest?

    /// Debounced trigger fired by `pidgyMessagesUpdatedLocally`. We collapse
    /// a burst of message-arrival notifications into a single refresh after
    /// the burst settles, so a busy chat doesn't drive 50 triages per minute.
    private var debouncedRefreshTask: Task<Void, Never>?
    private var messagesUpdatedObserver: NSObjectProtocol?
    /// Combine subscription to the chat list. Tasks used to refresh only on
    /// new-message bursts + the 8-min tick — so chats streaming into the main
    /// list (a position update, NOT a message) wouldn't trigger a scan until
    /// the next tick. That left the Tasks page empty right after load while the
    /// reply queue (which reacts to `visibleChats`) filled in. Reacting to the
    /// chat list here makes Tasks incremental too, like the reply queue.
    private var chatListCancellable: AnyCancellable?
    private var firstNotifyAtForCurrentBurst: Date?
    private static let debouncedRefreshDelay: Duration = .seconds(20)
    /// If notifications keep resetting the debounce, force a refresh anyway
    /// after this much wall-clock time has elapsed since the burst's first
    /// notification. Without this, sustained MajorChatCoverage backfills
    /// (which keep posting notifications every few seconds for hours) would
    /// starve the Tasks refresh forever.
    private static let debouncedRefreshMaxWait: Duration = .seconds(60)

    private init() {}

    deinit {
        if let messagesUpdatedObserver {
            NotificationCenter.default.removeObserver(messagesUpdatedObserver)
        }
    }

    func start(
        telegramService: TelegramService,
        aiService: AIService,
        includeBotsInAISearch: Bool
    ) {
        self.includeBotsInAISearch = includeBotsInAISearch
        filteringTelegramService = telegramService
        filteringAIService = aiService

        // Subscribe once to the new-message notification so we refresh
        // right after a sync batch lands instead of waiting up to 8 min for
        // the next periodic tick. Debounced so a burst of messages = one
        // refresh after the burst settles.
        if messagesUpdatedObserver == nil {
            messagesUpdatedObserver = NotificationCenter.default.addObserver(
                forName: .pidgyMessagesUpdatedLocally,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedRefresh()
                }
            }
        }

        // React to the chat list itself, not just message bursts: when chats
        // stream into the main list, fire the (debounced) refresh so Tasks
        // fills incrementally as the list loads — same reactivity the reply
        // queue gets for free from observing `visibleChats` in the view.
        if chatListCancellable == nil {
            chatListCancellable = telegramService.$chats
                .map { $0.filter(\.isInMainList).count }
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.scheduleDebouncedRefresh()
                    }
                }
        }

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

        logger.info("TaskIndex starting refresh loop (interval=\(Int(AppConstants.Dashboard.taskRefreshIntervalSeconds))s)")
        refreshLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.logger.info("TaskIndex first-run loadFromStore")
            await self.loadFromStore(
                telegramService: telegramService,
                includeBotsInAISearch: self.includeBotsInAISearch
            )
            self.logger.info("TaskIndex first-run refreshNow")
            await self.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: self.includeBotsInAISearch
            )
            self.logger.info("TaskIndex first-run finished, entering periodic loop")

            var cycle = 1
            while !Task.isCancelled {
                self.logger.info("TaskIndex cycle \(cycle, privacy: .public): sleeping \(Int(AppConstants.Dashboard.taskRefreshIntervalSeconds))s")
                try? await Task.sleep(
                    for: .seconds(AppConstants.Dashboard.taskRefreshIntervalSeconds)
                )
                guard !Task.isCancelled else { return }
                self.logger.info("TaskIndex cycle \(cycle, privacy: .public): refreshNow firing")
                await self.refreshNow(
                    telegramService: telegramService,
                    aiService: aiService,
                    includeBotsInAISearch: self.includeBotsInAISearch
                )
                self.logger.info("TaskIndex cycle \(cycle, privacy: .public): refreshNow returned (tasks=\(self.tasks.count, privacy: .public), lastError=\(self.lastError ?? "nil", privacy: .public))")
                cycle += 1
            }
            self.logger.warning("TaskIndex refresh loop exited (cancelled)")
        }
    }

    func stop() {
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
        debouncedRefreshTask?.cancel()
        debouncedRefreshTask = nil
    }

    /// Called from the `pidgyMessagesUpdatedLocally` observer. Coalesces a
    /// burst of message-arrival notifications into a single refreshNow that
    /// fires once the burst settles, OR after `debouncedRefreshMaxWait`
    /// elapsed since the burst's first notification — whichever comes first.
    private func scheduleDebouncedRefresh() {
        guard let telegramService = filteringTelegramService,
              let aiService = filteringAIService
        else { return }

        let now = Date()
        if firstNotifyAtForCurrentBurst == nil {
            firstNotifyAtForCurrentBurst = now
        }
        let burstStart = firstNotifyAtForCurrentBurst ?? now

        // Compute remaining time before the max-wait ceiling kicks in.
        let elapsedSinceBurstStart = now.timeIntervalSince(burstStart)
        let maxWaitSeconds = Double(Self.debouncedRefreshMaxWait.components.seconds)
        let remainingMaxWait = max(0, maxWaitSeconds - elapsedSinceBurstStart)
        // Sleep is the smaller of the trailing-edge debounce window and the
        // remaining max-wait. So a quiet burst fires after 20 s; a busy
        // ongoing burst fires after at most 60 s from its first notification.
        let trailingDelaySeconds = Double(Self.debouncedRefreshDelay.components.seconds)
        let sleepSeconds = min(trailingDelaySeconds, remainingMaxWait)

        debouncedRefreshTask?.cancel()
        debouncedRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(sleepSeconds))
            guard let self, !Task.isCancelled else { return }
            self.firstNotifyAtForCurrentBurst = nil
            self.logger.info("TaskIndex debounced refresh firing (triggered by new messages)")
            await self.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: self.includeBotsInAISearch
            )
        }
    }

    func setBotInclusion(
        _ includeBotsInAISearch: Bool,
        telegramService: TelegramService
    ) async {
        // Early-return when nothing actually changed. This is called from
        // DashboardView's .onChange(of: visibleChatIDs) on every TDLib chat
        // update, and every botMetadataRefreshVersion bump. The toggle
        // genuinely changes ~0 times per session, but each no-op call
        // otherwise fires 3 SQLite reads (topics + tasks + evidence) plus a
        // bot-filter pass over all tasks. Skip when the value matches what
        // we already hold AND we already have a service reference.
        let serviceUnchanged = filteringTelegramService === telegramService
        let inclusionUnchanged = self.includeBotsInAISearch == includeBotsInAISearch
        if serviceUnchanged && inclusionUnchanged && !tasks.isEmpty {
            return
        }

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

        // Context layer (#48): tasks are a VIEW over open-loop facts, not the
        // separately-extracted dashboard_tasks table. Project the live facts
        // (bot-filtered the same way) and synthesize evidence from each fact's
        // own source snippet so the existing Tasks UI works unchanged.
        if ContextLayer.enabled {
            let chatTitles: [Int64: String]
            if let telegramService {
                chatTitles = Dictionary(
                    telegramService.visibleChats.map { ($0.id, $0.title) },
                    uniquingKeysWith: { a, _ in a }
                )
            } else {
                chatTitles = [:]
            }
            let openFacts = await DatabaseManager.shared.loadOpenFacts()
            let factTasks = FactProjection.tasks(from: openFacts, chatTitles: chatTitles)
            let visibleTasks = await botFilteredTasks(
                factTasks,
                telegramService: telegramService,
                includeBotsInAISearch: includeBotsInAISearch
            )
            let visibleIds = Set(visibleTasks.map(\.id))
            var evidence: [Int64: [DashboardTaskSourceMessage]] = [:]
            for f in openFacts where visibleIds.contains(f.id) && !f.sourceText.isEmpty {
                evidence[f.id] = [DashboardTaskSourceMessage(
                    chatId: f.sourceChatId,
                    messageId: f.sourceMessageId,
                    senderName: f.senderName,
                    text: f.sourceText,
                    date: f.validFrom
                )]
            }
            topics = loadedTopics
            tasks = visibleTasks
            evidenceByTaskId = evidence
            return
        }

        var loadedTasks = await DatabaseManager.shared.loadDashboardTasks()

        // Stale-task reconciliation: open AI-extracted tasks whose chat
        // produced no fresh evidence for the configured window quietly
        // move to Done (the arch doc's "old open tasks linger forever"
        // launch blocker). Keys off evidence timestamps — a code-level
        // signal — never off task text. Only untouched .open tasks
        // qualify; setByUser: false keeps the auto-close from looking
        // like a user touch, and a user re-opening a task stamps it so
        // it won't be auto-closed again for a full quiet window.
        let dueForExpiry = Self.tasksDueForExpiry(
            loadedTasks,
            expireAfterDays: Self.autoExpireDays()
        )
        if !dueForExpiry.isEmpty {
            for task in dueForExpiry {
                await DatabaseManager.shared.updateDashboardTaskStatus(
                    taskId: task.id,
                    status: .done,
                    setByUser: false
                )
            }
            loadedTasks = await DatabaseManager.shared.loadDashboardTasks()
        }
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
        forceRescan: Bool = false,
        userInitiated: Bool = false
    ) async {
        let includeBotsInAISearch = includeBotsInAISearch ?? self.includeBotsInAISearch
        let request = RefreshRequest(
            telegramService: telegramService,
            aiService: aiService,
            includeBotsInAISearch: includeBotsInAISearch,
            forceRescan: forceRescan
        )

        // Flip the user-facing flag eagerly so the button shows feedback
        // even if the request gets queued behind a background tick. We
        // clear it in the deferred block below — but only this caller is
        // responsible for clearing it (using shouldClearUserFlag) so two
        // overlapping user-initiated clicks don't fight.
        let shouldClearUserFlag = userInitiated && !isUserInitiatedRefreshing
        if userInitiated {
            isUserInitiatedRefreshing = true
        }

        guard !isRefreshing else {
            queueRefresh(request)
            // If we set the flag but are queuing, the queued runner won't
            // know it was user-initiated and won't clear our flag. Clear
            // it here — the active refresh will sweep the queued work in
            // a moment and the UI will update to the fresh state.
            if shouldClearUserFlag {
                isUserInitiatedRefreshing = false
            }
            return
        }

        isRefreshing = true

        defer {
            isRefreshing = false
            if shouldClearUserFlag {
                isUserInitiatedRefreshing = false
            }
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

        // Context layer (#48): tasks are maintained by FactExtractionCoordinator
        // (which crawls facts incrementally). loadFromStore already projected
        // them, so skip the old AI task extraction entirely — no double-work.
        if ContextLayer.enabled {
            lastRefreshAt = Date()
            return
        }

        guard aiService.isConfigured else {
            lastError = "Connect an AI provider to extract tasks from Telegram."
            logger.warning("refreshNow: AI not configured")
            return
        }

        guard telegramService.authState == .ready else {
            lastError = "Telegram is not ready yet."
            logger.warning("refreshNow: Telegram not ready (state=\(String(describing: telegramService.authState), privacy: .public))")
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
        let openTasks = await DatabaseManager.shared.loadDashboardTasks(status: .open, limit: 1_000)
        let openTaskEvidenceByTaskId = await DatabaseManager.shared.loadDashboardTaskEvidence(
            taskIds: openTasks.map(\.id)
        )
        let openTasksByChatId = Dictionary(grouping: openTasks, by: \.chatId)
        let scanChats = Self.scanChats(from: candidateChats, openTasks: openTasks)
        let forceRescan = request.forceRescan || Self.needsTriageContextVersionRescan()
        let pendingScans = await Self.pendingTaskScans(
            from: scanChats,
            openTasksByChatId: openTasksByChatId,
            openTaskEvidenceByTaskId: openTaskEvidenceByTaskId,
            forceRescan: forceRescan
        )

        logger.info("refreshNow: candidates=\(candidateChats.count, privacy: .public) scanChats=\(scanChats.count, privacy: .public) pendingScans=\(pendingScans.count, privacy: .public)")
        guard !pendingScans.isEmpty else {
            lastRefreshAt = Date()
            if forceRescan {
                Self.markTriageContextVersionScanned()
            }
            logger.info("refreshNow: no pending scans, exiting cleanly")
            return
        }

        let triageByChatId: [Int64: DashboardTaskTriageResultDTO]
        do {
            triageByChatId = try await Self.triagePendingTaskScans(
                pendingScans,
                aiService: aiService,
                myUserId: myUserId
            )
            logger.info("refreshNow: triage returned \(triageByChatId.count, privacy: .public) decisions")
        } catch {
            lastError = "Task triage failed: \(error.localizedDescription)"
            logger.error("refreshNow: triage threw \(error.localizedDescription, privacy: .public)")
            return
        }

        for pending in pendingScans {
            guard !Task.isCancelled else { return }

            guard let triage = triageByChatId[pending.chat.id] else { continue }
            if triage.route == .completedTask {
                // Prompt-injection defense (issue #30): force-completing real
                // tasks is driven by AI output over attacker-controlled message
                // text. Only honor it when corroborated by a genuine outgoing
                // message from the user in this window — "from me" is derived
                // structurally from isOutgoing / the sender id, never from
                // message content, so a crafted inbound message cannot spoof it.
                // An uncorroborated completion is advisory only: leave the task
                // open for the user and just advance the sync cursor.
                let corroboratedByMe = pending.messages.contains { msg in
                    if msg.isOutgoing { return true }
                    if case .user(let uid) = msg.senderId { return myUserId > 0 && uid == myUserId }
                    return false
                }
                if corroboratedByMe {
                    await DatabaseManager.shared.completeOpenDashboardTasks(
                        chatId: pending.chat.id,
                        matchingTaskIds: triage.completedTaskIds,
                        matchingSourceMessageIds: triage.supportingMessageIds
                    )
                } else {
                    logger.warning("refreshNow: completed_task for chat \(pending.chat.id, privacy: .public) lacks an outgoing [ME] message; treating as advisory (task left open)")
                }
                await DatabaseManager.shared.updateDashboardTaskSyncState(
                    chatId: pending.chat.id,
                    latestMessageId: pending.latestMessageId
                )
                continue
            }

            guard triage.route == .effortTask else {
                // Prompt-injection defense (issue #30, suppression half): a crafted
                // inbound message can reliably force a non-effort route, and the old
                // blanket matchingTaskIds wiped every open task in the chat. Honor
                // the suppression per task only when the triage decision cites that
                // task's OWN stored source evidence in supportingMessageIds — the
                // flow the system prompt prescribes for legitimate stale cleanup.
                // A new attacker message can never cite the old evidence rows, so
                // uncited tasks stay open (advisory); the sync cursor still advances.
                let supporting = Set(triage.supportingMessageIds)
                let citedTaskIds = pending.openTasks.compactMap { task -> Int64? in
                    let evidence = pending.openTaskEvidenceByTaskId[task.id] ?? []
                    guard evidence.contains(where: { supporting.contains($0.messageId) }) else { return nil }
                    return task.id
                }
                if !citedTaskIds.isEmpty {
                    await DatabaseManager.shared.ignoreOpenDashboardTasks(
                        chatId: pending.chat.id,
                        matchingTaskIds: citedTaskIds,
                        matchingSourceMessageIds: []
                    )
                } else if !pending.openTasks.isEmpty {
                    logger.warning("refreshNow: \(String(describing: triage.route), privacy: .public) for chat \(pending.chat.id, privacy: .public) cites no open-task source evidence; leaving \(pending.openTasks.count, privacy: .public) task(s) open (advisory)")
                }
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
                let evidencedCandidates = candidates.filter {
                    !$0.sourceMessages.isEmpty && DashboardTaskOwnership.isKnownOwner($0.ownerName)
                }
                if !evidencedCandidates.isEmpty {
                    _ = await DatabaseManager.shared.upsertDashboardTasks(evidencedCandidates)
                }
                let retainedFingerprints = Set(evidencedCandidates.map(\.stableFingerprint))
                let retainedCitedMessageIds = Set(evidencedCandidates.flatMap { $0.sourceMessages.map(\.messageId) })
                // If extraction returns the same source under a corrected owner/fingerprint,
                // retire the stale row instead of leaving duplicate "Me" ownership behind.
                // Prompt-injection defense (issue #30, suppression half): retire ONLY when
                // a retained candidate cites the stale task's own evidence — a genuine
                // correction of the same underlying ask. An attacker message that fools
                // extraction into returning nothing (or unrelated tasks) cites none of the
                // old evidence rows, so real tasks survive. The corrected-owner flow keeps
                // working because the replacement re-cites the same source messages.
                let staleOpenTaskIds = pending.openTasks.compactMap { task -> Int64? in
                    guard !retainedFingerprints.contains(task.stableFingerprint) else { return nil }
                    let evidence = pending.openTaskEvidenceByTaskId[task.id] ?? []
                    guard !evidence.isEmpty else { return nil }
                    guard evidence.contains(where: { retainedCitedMessageIds.contains($0.messageId) }) else { return nil }
                    return task.id
                }
                if !staleOpenTaskIds.isEmpty {
                    await DatabaseManager.shared.ignoreOpenDashboardTasks(
                        chatId: pending.chat.id,
                        matchingTaskIds: staleOpenTaskIds,
                        matchingSourceMessageIds: []
                    )
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
        if forceRescan {
            Self.markTriageContextVersionScanned()
        }
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
        // Context layer (#48): a fact-derived task closes by INVALIDATING its
        // underlying fact (done/ignored). Snooze isn't modeled on facts yet, so
        // it's a no-op here for now (the loop stays open).
        if ContextLayer.enabled {
            if status == .done || status == .ignored {
                await DatabaseManager.shared.invalidateFacts(fingerprints: [task.stableFingerprint])
            }
            await loadFromStore()
            return
        }
        await DatabaseManager.shared.updateDashboardTaskStatus(
            taskId: task.id,
            status: status,
            snoozedUntil: snoozedUntil
        )
        await loadFromStore()
    }

    func addTopic(named name: String) async -> DashboardTopic? {
        let added = await DatabaseManager.shared.addDashboardTopic(name: name)
        await loadFromStore()
        guard let added else { return nil }
        return topics.first { $0.id == added.id } ?? added
    }

    func removeTopic(id: Int64) async {
        await DatabaseManager.shared.deleteDashboardTopic(id: id)
        await loadFromStore()
    }

    private func refreshTopicsIfNeeded(
        telegramService: TelegramService,
        aiService: AIService,
        includeBotsInAISearch: Bool
    ) async -> [DashboardTopic] {
        // Topics are now exclusively user-curated. The previous behavior
        // ran AI topic discovery whenever the stored set was empty (and
        // periodically refreshed it), which silently pre-filled the
        // sidebar with chat-derived names like "First Dollar" / "Inner
        // Circle" — surprising for a tester who hadn't asked for any of
        // those, and impossible to reproduce without burning AI credits.
        //
        // Tasks still extract correctly without topics; the chip strip
        // on the Tasks page just doesn't auto-categorize by topic until
        // the user adds one via the sidebar's "+" button.
        let stored = await DatabaseManager.shared.loadDashboardTopics()
        topics = stored
        return stored
    }

    /// Run AI-powered topic discovery on demand. Surfaced from the sidebar
    /// "+" sheet's "Suggest from chats" affordance so the user can opt in
    /// to a one-shot suggestion sweep instead of getting prefilled topics
    /// they never asked for.
    func discoverTopicsOnDemand(
        telegramService: TelegramService,
        aiService: AIService,
        includeBotsInAISearch: Bool
    ) async -> [DashboardTopic] {
        let stored = await DatabaseManager.shared.loadDashboardTopics()

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

    /// Current auto-expire window from Preferences. 0 means never.
    /// Unset means the 30-day default — `object(forKey:)` (not
    /// `integer(forKey:)`) so "never set" and "user chose 0/Never"
    /// are distinguishable.
    nonisolated static func autoExpireDays() -> Int {
        UserDefaults.standard.object(
            forKey: AppConstants.Preferences.dashboardTaskAutoExpireDaysKey
        ) as? Int ?? AppConstants.Preferences.dashboardTaskAutoExpireDaysDefault
    }

    /// Pure expiry policy, separated for tests: open tasks whose most
    /// recent evidence (falling back to creation time when a task
    /// somehow has no sourced message) is older than the window.
    /// `expireAfterDays <= 0` disables expiry entirely.
    nonisolated static func tasksDueForExpiry(
        _ tasks: [DashboardTask],
        expireAfterDays: Int,
        now: Date = Date()
    ) -> [DashboardTask] {
        guard expireAfterDays > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(expireAfterDays) * 86_400)
        return tasks.filter { task in
            guard task.status == .open else { return false }
            guard (task.latestSourceDate ?? task.createdAt) < cutoff else { return false }
            // A recent manual touch (e.g. restoring an expired task)
            // resets the clock: without this, Restore was undone on the
            // very next load pass because the task's evidence is, by
            // definition, still older than the window.
            if let touched = task.statusSetByUserAt, touched >= cutoff { return false }
            return true
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
        // Drop user-archived chats before any task extraction —
        // mirrors the reply-queue eligibility filter so archiving a
        // chat removes it from BOTH surfaces.
        let archivedIds = ArchivedChatsStore.archivedIds()
        let sorted = chats
            .filter { $0.isInMainList && !$0.chatType.isChannel && !archivedIds.contains($0.id) }
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

    private static func scanChats(
        from candidateChats: [TGChat],
        openTasks: [DashboardTask]
    ) -> [TGChat] {
        var seenChatIds = Set(candidateChats.map(\.id))
        var scanChats = candidateChats

        let staleTaskChats = openTasks
            .sorted {
                let lhsDate = $0.latestSourceDate ?? $0.updatedAt
                let rhsDate = $1.latestSourceDate ?? $1.updatedAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return $0.chatTitle.localizedCaseInsensitiveCompare($1.chatTitle) == .orderedAscending
            }

        for task in staleTaskChats where !seenChatIds.contains(task.chatId) {
            seenChatIds.insert(task.chatId)
            scanChats.append(TGChat(
                id: task.chatId,
                title: task.chatTitle.isEmpty ? "Chat \(task.chatId)" : task.chatTitle,
                chatType: fallbackChatType(for: task.chatId),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 0,
                isInMainList: false,
                smallPhotoFileId: nil
            ))
        }

        return scanChats
    }

    private static func fallbackChatType(for chatId: Int64) -> TGChat.ChatType {
        if chatId > 0 {
            return .privateChat(userId: chatId)
        }
        return .basicGroup(groupId: abs(chatId))
    }

    private static func pendingTaskScans(
        from chats: [TGChat],
        openTasksByChatId: [Int64: [DashboardTask]],
        openTaskEvidenceByTaskId: [Int64: [DashboardTaskSourceMessage]],
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
            let openTasks = openTasksByChatId[chat.id] ?? []
            let evidenceForOpenTasks = Dictionary(
                uniqueKeysWithValues: openTasks.map {
                    ($0.id, openTaskEvidenceByTaskId[$0.id] ?? [])
                }
            )
            pending.append(PendingTaskScan(
                chat: chat,
                messages: messages,
                latestMessageId: latestMessageId,
                openTasks: openTasks,
                openTaskEvidenceByTaskId: evidenceForOpenTasks
            ))
        }

        return pending
    }

    private static func triagePendingTaskScans(
        _ pending: [PendingTaskScan],
        aiService: AIService,
        myUserId: Int64
    ) async throws -> [Int64: DashboardTaskTriageResultDTO] {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.pidgy.app",
            category: "TaskIndex"
        )
        var triageByChatId: [Int64: DashboardTaskTriageResultDTO] = [:]
        var batchCount = 0
        var failureCount = 0
        var lastBatchError: Error?

        for batch in pending.chunked(into: AppConstants.Dashboard.taskTriageBatchSize) {
            batchCount += 1
            let candidates = batch.map {
                DashboardTaskTriageCandidate(
                    chat: $0.chat,
                    messages: $0.messages,
                    openTasks: $0.openTasks,
                    openTaskEvidenceByTaskId: $0.openTaskEvidenceByTaskId
                )
            }
            // Catch per batch: one failing batch must not abort the whole
            // refresh. Aborting used to skip markTriageContextVersionScanned(),
            // leaving forceRescan stuck on — so every chat-list change re-fired
            // a full rescan, retrying the same failure and burning spend.
            do {
                let decisions = try await aiService.triageDashboardTaskCandidates(
                    candidates,
                    myUserId: myUserId
                )
                for decision in decisions {
                    triageByChatId[decision.chatId] = decision
                }
            } catch {
                failureCount += 1
                lastBatchError = error
                logger.error("triage batch failed (\(failureCount, privacy: .public)/\(batchCount, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Only a TOTAL failure (e.g. provider down / daily cap) propagates, so
        // the caller leaves the context-version cursor unadvanced and retries
        // on the next refresh. Partial success returns normally: the missed
        // chats keep their state and get re-triaged incrementally on change.
        if batchCount > 0, failureCount == batchCount, let lastBatchError {
            throw lastBatchError
        }

        return triageByChatId
    }

    private static func needsTriageContextVersionRescan() -> Bool {
        UserDefaults.standard.integer(
            forKey: AppConstants.Preferences.dashboardTaskTriageContextVersionKey
        ) < AppConstants.Dashboard.taskTriageContextVersion
    }

    private static func markTriageContextVersionScanned() {
        UserDefaults.standard.set(
            AppConstants.Dashboard.taskTriageContextVersion,
            forKey: AppConstants.Preferences.dashboardTaskTriageContextVersionKey
        )
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
