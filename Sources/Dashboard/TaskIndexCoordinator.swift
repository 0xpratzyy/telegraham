import Combine
import Foundation
import OSLog

/// Projects the context layer's open-loop facts into the Tasks page model.
/// Extraction itself lives in FactExtractionCoordinator — this coordinator
/// only LOADS (facts → DashboardTask projection), reacts to change
/// notifications, and applies user status changes back onto facts.
@MainActor
final class TaskIndexCoordinator: ObservableObject {
    static let shared = TaskIndexCoordinator()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pidgy.app",
        category: "TaskIndex"
    )

    @Published private(set) var topics: [DashboardTopic] = []
    @Published private(set) var tasks: [DashboardTask] = []
    @Published private(set) var evidenceByTaskId: [Int64: [DashboardTaskSourceMessage]] = [:]
    /// True while a load is in flight. The Tasks page UI should NOT bind to
    /// this directly — use `isUserInitiatedRefreshing` for button feedback.
    @Published private(set) var isRefreshing = false
    /// True only while a user-initiated refresh is running — the button
    /// the user actually clicked.
    @Published private(set) var isUserInitiatedRefreshing = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastError: String?

    private var includeBotsInAISearch = false
    private weak var filteringTelegramService: TelegramService?

    /// Debounced trigger fired by `pidgyMessagesUpdatedLocally`. We collapse
    /// a burst of message-arrival notifications into a single reload after
    /// the burst settles.
    private var debouncedRefreshTask: Task<Void, Never>?
    private var messagesUpdatedObserver: NSObjectProtocol?
    private var factsChangedObserver: NSObjectProtocol?
    /// Combine subscription to the chat list: chats streaming into the main
    /// list (a position update, NOT a message) refresh the projection too, so
    /// the Tasks page fills incrementally right after load.
    private var chatListCancellable: AnyCancellable?
    private var firstNotifyAtForCurrentBurst: Date?
    private static let debouncedRefreshDelay: Duration = .seconds(20)
    /// If notifications keep resetting the debounce, force a refresh anyway
    /// after this much wall-clock time since the burst's first notification —
    /// sustained backfills must not starve the Tasks refresh forever.
    private static let debouncedRefreshMaxWait: Duration = .seconds(60)

    private init() {}

    deinit {
        if let messagesUpdatedObserver {
            NotificationCenter.default.removeObserver(messagesUpdatedObserver)
        }
        if let factsChangedObserver {
            NotificationCenter.default.removeObserver(factsChangedObserver)
        }
    }

    func start(
        telegramService: TelegramService,
        includeBotsInAISearch: Bool
    ) {
        self.includeBotsInAISearch = includeBotsInAISearch
        filteringTelegramService = telegramService

        // Refresh right after a sync batch lands instead of waiting for the
        // next fact-extraction pass. Debounced so a burst = one reload.
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

        // Re-project immediately when the fact store changes (a loop closed by a
        // reply, Mark Done elsewhere) — don't wait for a message burst.
        if factsChangedObserver == nil {
            factsChangedObserver = NotificationCenter.default.addObserver(
                forName: .contextFactsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let ts = self.filteringTelegramService else { return }
                    await self.loadFromStore(
                        telegramService: ts,
                        includeBotsInAISearch: self.includeBotsInAISearch
                    )
                }
            }
        }

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

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadFromStore(
                telegramService: telegramService,
                includeBotsInAISearch: includeBotsInAISearch
            )
        }
    }

    func stop() {
        debouncedRefreshTask?.cancel()
        debouncedRefreshTask = nil
        // Full teardown, not just the debounce: the observers and the chat
        // subscription each fire loadFromStore, and a reset that closes the
        // DB mid-read would have it reopened by the very next notification.
        if let messagesUpdatedObserver {
            NotificationCenter.default.removeObserver(messagesUpdatedObserver)
            self.messagesUpdatedObserver = nil
        }
        if let factsChangedObserver {
            NotificationCenter.default.removeObserver(factsChangedObserver)
            self.factsChangedObserver = nil
        }
        chatListCancellable = nil
        // Invalidate any in-flight load so its publish guards drop it.
        loadGeneration += 1
    }

    /// Coalesces a burst of message-arrival notifications into a single
    /// reload once the burst settles, OR after `debouncedRefreshMaxWait`
    /// since the burst's first notification — whichever comes first.
    private func scheduleDebouncedRefresh() {
        guard let telegramService = filteringTelegramService else { return }

        let now = Date()
        if firstNotifyAtForCurrentBurst == nil {
            firstNotifyAtForCurrentBurst = now
        }
        let burstStart = firstNotifyAtForCurrentBurst ?? now

        let elapsedSinceBurstStart = now.timeIntervalSince(burstStart)
        let maxWaitSeconds = Double(Self.debouncedRefreshMaxWait.components.seconds)
        let remainingMaxWait = max(0, maxWaitSeconds - elapsedSinceBurstStart)
        let trailingDelaySeconds = Double(Self.debouncedRefreshDelay.components.seconds)
        let sleepSeconds = min(trailingDelaySeconds, remainingMaxWait)

        debouncedRefreshTask?.cancel()
        debouncedRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(sleepSeconds))
            guard let self, !Task.isCancelled else { return }
            self.firstNotifyAtForCurrentBurst = nil
            await self.loadFromStore(
                telegramService: telegramService,
                includeBotsInAISearch: self.includeBotsInAISearch
            )
        }
    }

    func setBotInclusion(
        _ includeBotsInAISearch: Bool,
        telegramService: TelegramService
    ) async {
        // Early-return when nothing actually changed — this is called from
        // DashboardView's .onChange(of: visibleChatIDs) on every TDLib chat
        // update, and each no-op call otherwise fires SQLite reads plus a
        // bot-filter pass over all tasks. Keyed on "has a load completed",
        // NOT on !tasks.isEmpty: an empty account would otherwise re-run the
        // full projection on every one of the hundreds of chat-position
        // updates during initial sync.
        let serviceUnchanged = filteringTelegramService === telegramService
        let inclusionUnchanged = self.includeBotsInAISearch == includeBotsInAISearch
        if serviceUnchanged && inclusionUnchanged && hasCompletedInitialLoad {
            return
        }

        self.includeBotsInAISearch = includeBotsInAISearch
        filteringTelegramService = telegramService
        await loadFromStore(
            telegramService: telegramService,
            includeBotsInAISearch: includeBotsInAISearch
        )
    }

    /// Monotonic ticket for loadFromStore: several triggers (facts changed,
    /// message bursts, chat-list ticks, user refresh) can overlap because the
    /// load suspends at DB/TDLib awaits. Only the NEWEST load may publish —
    /// otherwise a slow load that read facts before a Mark Done finishes
    /// after it and resurrects the just-closed task until the next trigger.
    private var loadGeneration = 0
    /// True after the first COMPLETED projection — the setBotInclusion
    /// early-return keys on this, not on task count.
    private var hasCompletedInitialLoad = false
    /// Ticket for user-initiated refreshes: only the NEWEST one may clear
    /// the spinner (a first click finishing must not stop it while a second
    /// overlapping click's load is still in flight — and vice versa).
    private var userRefreshGeneration = 0
    /// Chats whose getChat lookup failed this session (left/deleted chats
    /// whose facts outlive them). Without this, every reload retries the
    /// same failing rate-limited TDLib calls forever.
    private var unresolvableChatIds: Set<Int64> = []

    /// Tasks are a VIEW over open-loop facts. Project the live facts
    /// (bot-filtered) and synthesize evidence from each fact's own source
    /// snippet so the Tasks UI works unchanged. When the memory engine is
    /// killed via Preferences, this keeps showing the last-known facts —
    /// only extraction stops.
    func loadFromStore(
        telegramService: TelegramService? = nil,
        includeBotsInAISearch: Bool? = nil
    ) async {
        let includeBotsInAISearch = includeBotsInAISearch ?? self.includeBotsInAISearch
        let telegramService = telegramService ?? filteringTelegramService
        loadGeneration += 1
        let generation = loadGeneration
        isRefreshing = true
        var didPublish = false
        defer {
            // Only the latest load owns the shared flags — an overlapping
            // older load must not clear the spinner mid-flight. And only a
            // load that actually PUBLISHED stamps "Updated Nm ago": a
            // cancelled bail-out publishing nothing must not claim freshness.
            if generation == loadGeneration {
                isRefreshing = false
                if didPublish { lastRefreshAt = Date() }
            }
        }

        // The three reads are independent — overlap them on the pool's
        // reader connections instead of paying sum-of-latencies on the
        // hottest reload path in the app.
        async let topicsRead = DatabaseManager.shared.loadDashboardTopics()
        async let openFactsRead = DatabaseManager.shared.loadOpenFacts()
        // USER-closed loops (done/ignored) stay browsable in the status tabs
        // and reopenable — Mark Done must not erase all history.
        async let closedFactsRead = DatabaseManager.shared.loadUserClosedFacts()
        let chatTitles: [Int64: String]
        if let telegramService {
            chatTitles = Dictionary(
                telegramService.visibleChats.map { ($0.id, $0.title) },
                uniquingKeysWith: { a, _ in a }
            )
        } else {
            chatTitles = [:]
        }
        let loadedTopics = await topicsRead
        let openFacts = await openFactsRead
        let closedFacts = await closedFactsRead
        // A debounce-cancelled run resumes with EMPTY fact reads (the DB
        // layer swallows CancellationError) — and it may still be the newest
        // generation, because its replacement sleeps 20s before loading.
        // Publishing would blank the Tasks page for the whole window.
        guard !Task.isCancelled else { return }
        let factTasks = FactProjection.tasks(from: openFacts, chatTitles: chatTitles)
        let closedTasks = FactProjection.closedTasks(from: closedFacts, chatTitles: chatTitles)
        let visibleTasks = await botFilteredTasks(
            factTasks + closedTasks,
            telegramService: telegramService,
            includeBotsInAISearch: includeBotsInAISearch
        )
        let visibleIds = Set(visibleTasks.map(\.id))
        var evidence: [Int64: [DashboardTaskSourceMessage]] = [:]
        for f in openFacts + closedFacts where visibleIds.contains(f.id) && !f.sourceText.isEmpty {
            evidence[f.id] = [DashboardTaskSourceMessage(
                chatId: f.sourceChatId,
                messageId: f.sourceMessageId,
                senderName: f.senderName,
                text: f.sourceText,
                date: f.validFrom
            )]
        }
        // A newer load started while we were suspended — its snapshot is
        // fresher; publishing ours would go back in time. Re-check
        // cancellation too: botFilteredTasks' TDLib lookups can be cut
        // mid-loop, leaving a partially bot-filtered list.
        guard generation == loadGeneration, !Task.isCancelled else { return }
        topics = loadedTopics
        tasks = visibleTasks
        evidenceByTaskId = evidence
        hasCompletedInitialLoad = true
        didPublish = true
    }

    /// Reload the projection. Extraction is FactExtractionCoordinator's job —
    /// this only re-reads the store (the refresh button's contract is "show me
    /// the latest known state now").
    func refreshNow(
        telegramService: TelegramService,
        includeBotsInAISearch: Bool? = nil,
        userInitiated: Bool = false
    ) async {
        // Generation-owned spinner: each user click takes a ticket; only the
        // newest clears the flag, so overlapping clicks can't stop the
        // spinner while another user load is still in flight.
        var myUserGeneration = 0
        if userInitiated {
            userRefreshGeneration += 1
            myUserGeneration = userRefreshGeneration
            isUserInitiatedRefreshing = true
        }
        defer {
            if userInitiated, myUserGeneration == userRefreshGeneration {
                isUserInitiatedRefreshing = false
            }
        }
        await loadFromStore(
            telegramService: telegramService,
            includeBotsInAISearch: includeBotsInAISearch ?? self.includeBotsInAISearch
        )
    }

    func updateStatus(
        task: DashboardTask,
        status: DashboardTaskStatus,
        snoozedUntil: Date? = nil
    ) async {
        // A fact-derived task closes by INVALIDATING its underlying fact with
        // a USER reason (browsable in Done/Ignored, and reopenable — the undo
        // path). Snooze isn't modeled on facts yet, so it's a no-op (the loop
        // stays open).
        switch status {
        case .done:
            await DatabaseManager.shared.invalidateFacts(fingerprints: [task.stableFingerprint], reason: .userDone)
        case .ignored:
            await DatabaseManager.shared.invalidateFacts(fingerprints: [task.stableFingerprint], reason: .userIgnored)
        case .open where task.status != .open:
            await DatabaseManager.shared.reopenFact(fingerprint: task.stableFingerprint)
        default:
            break
        }
        // Other fact surfaces (reply queue, launcher) must see the close /
        // reopen too — mutations notify, not only the extraction pass. Our
        // own factsChangedObserver reloads the projection off this same
        // notification, so a direct loadFromStore here would double the work.
        NotificationCenter.default.post(name: .contextFactsChanged, object: nil)
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

    private func botFilteredTasks(
        _ loadedTasks: [DashboardTask],
        telegramService: TelegramService?,
        includeBotsInAISearch: Bool
    ) async -> [DashboardTask] {
        guard let telegramService else { return loadedTasks }
        let taskChatIds = Set(loadedTasks.map(\.chatId))
        var relevantChats = telegramService.visibleChats.filter { taskChatIds.contains($0.id) }
        var resolvedChatIds = Set(relevantChats.map(\.id))

        for chatId in taskChatIds.subtracting(resolvedChatIds) where !unresolvableChatIds.contains(chatId) {
            do {
                guard let chat = try await telegramService.getChat(id: chatId) else {
                    // A definitive nil from TDLib = chat genuinely not found
                    // (left/deleted) — the ONLY case worth a session
                    // blacklist, so the failing lookup isn't retried on
                    // every reload.
                    unresolvableChatIds.insert(chatId)
                    continue
                }
                relevantChats.append(chat)
                resolvedChatIds.insert(chat.id)
            } catch is CancellationError {
                // A newer load superseded us mid-loop — bail; the caller's
                // publish guards drop this run. Crucially, do NOT blacklist:
                // these chats are resolvable, the lookup was just cut short.
                break
            } catch {
                // Transient (network / rate-limit / TDLib not ready): skip
                // this pass only. Blacklisting here made a valid chat's
                // tasks vanish for the whole session over one flaky call.
                continue
            }
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
}
