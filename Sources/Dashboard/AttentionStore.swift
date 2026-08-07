import Combine
import Foundation

/// Owns the reply queue: a VIEW over open-loop facts (i_owe .reply → ON ME,
/// owes_me → ON THEM, else QUIET), plus the user's hide-from-queue choices.
/// Extraction lives in FactExtractionCoordinator — this store only projects.
@MainActor
final class AttentionStore: ObservableObject {
    static let shared = AttentionStore()

    /// Backing storage for `followUpItems`. The published projection
    /// below filters out excluded chats so any view consuming the
    /// store gets the user's hide-from-queue choices for free.
    private var allFollowUpItems: [FollowUpItem] = []

    @Published private(set) var followUpItems: [FollowUpItem] = []
    /// Chat IDs the user explicitly hid from the reply queue via the
    /// "Hide from queue" context menu action. Persisted in UserDefaults
    /// so the choice survives launches.
    @Published private(set) var excludedChatIds: Set<Int64> = {
        let raw = UserDefaults.standard.array(forKey: AppConstants.Preferences.excludedFromReplyQueueKey) ?? []
        return Set(raw.compactMap { ($0 as? NSNumber)?.int64Value })
    }()
    /// Stamp set when the most recent reply-queue projection finishes. Used by
    /// DashboardTopBar to render the "Updated Nm ago" label on the Reply
    /// Queue page.
    @Published private(set) var lastFollowUpsRefreshAt: Date?
    /// True while a projection is actually running — the top bar's Refresh
    /// button binds to this so a manual refresh visibly does something even
    /// when the resulting content is unchanged.
    @Published private(set) var isProjecting = false

    private init() {}

    func pipelineCategory(for chatId: Int64) -> FollowUpItem.Category? {
        allFollowUpItems.first(where: { $0.chat.id == chatId })?.category
    }

    func pipelineSuggestion(for chatId: Int64) -> String? {
        allFollowUpItems.first(where: { $0.chat.id == chatId })?.suggestedAction
    }

    /// Hide a chat from the reply queue. The projection for the chat stays
    /// in memory so we can restore it later; we just stop including it in
    /// the published view.
    func excludeChat(id: Int64) {
        guard !excludedChatIds.contains(id) else { return }
        excludedChatIds.insert(id)
        persistExcludedChatIds()
        republishFiltered()
    }

    /// Restore a previously-hidden chat to the reply queue.
    func unexcludeChat(id: Int64) {
        guard excludedChatIds.remove(id) != nil else { return }
        persistExcludedChatIds()
        republishFiltered()
    }

    /// Drop a chat from the in-memory queue without persisting an
    /// exclusion. Used after archiving a chat in Telegram: the chat
    /// leaves the main list so the next refresh won't surface it
    /// anyway, but this gives immediate feedback. If the user
    /// unarchives in Telegram, it returns on the next refresh —
    /// unlike `excludeChat`, which is a sticky user preference.
    func dropChat(id: Int64) {
        guard allFollowUpItems.contains(where: { $0.chat.id == id }) else { return }
        allFollowUpItems.removeAll { $0.chat.id == id }
        // The published list no longer matches the last projected signature —
        // reset it, or an unarchived chat whose re-projection hashes identically
        // would hit the "unchanged" guard and never return to the queue.
        lastFactReplySignature = ""
        republishFiltered()
    }

    private func persistExcludedChatIds() {
        let raw = excludedChatIds.map { NSNumber(value: $0) }
        UserDefaults.standard.set(raw, forKey: AppConstants.Preferences.excludedFromReplyQueueKey)
    }

    private func republishFiltered() {
        followUpItems = allFollowUpItems.filter { !excludedChatIds.contains($0.chat.id) }
        postOnMeBadge()
    }

    // Last published fact-reply signature (content hash) — guards against
    // redundant republishes that flicker the list on startup.
    private var lastFactReplySignature = ""

    /// Flips true after the FIRST settled fact projection completes. The reply
    /// view shows a skeleton until then, so the user sees one finished list
    /// instead of watching it assemble from the streaming chat list + facts.
    @Published private(set) var hasLoadedFactReplies = false

    // Stashed service + observer so the reply queue re-projects the instant the
    // fact store changes (a loop closed by a reply, the cleanup) — not only when
    // the chat list ticks.
    private weak var lastTelegramService: TelegramService?
    private var lastIncludeBots = false
    private var factsChangedObserver: NSObjectProtocol?
    private var factReplyDebounceTask: Task<Void, Never>?
    private var lastFactProjectionAt: Date = .distantPast
    /// The RUNNING projection. Never cancelled by newer loadFollowUps calls
    /// (only the sleeping debounce task is) — cancelling mid-DB-read made a
    /// sustained event storm starve the queue: every leading-edge run died
    /// inside loadOpenFacts and nothing ever published. Instead, a request
    /// that arrives mid-projection queues ONE coalesced rerun.
    private var projectionTask: Task<Void, Never>?
    private var rerunAfterProjection: (service: TelegramService, includeBots: Bool)?

    /// Project the reply queue from open-loop facts. Lane routing lives in
    /// FactProjection.replyLanes — ONE definition shared with the inspector.
    /// The signature guard skips redundant republishes so the list doesn't
    /// re-render for identical content.
    private func projectFactReplyQueue(telegramService: TelegramService, includeBots: Bool) async {
        let candidates = collectPipelineCandidates(telegramService: telegramService, includeBots: includeBots)
        let openFacts = await DatabaseManager.shared.loadOpenFacts()
        // A debounce-cancelled run resumes here with an EMPTY fact read (the DB
        // layer swallows CancellationError) — publishing it would flash every
        // lane to QUIET for ~400ms until the newer projection heals it.
        guard !Task.isCancelled else { return }
        let lanes = FactProjection.replyLanes(from: openFacts)
        var items: [FollowUpItem] = []
        for chat in candidates {
            guard let lastMessage = chat.lastMessage else { continue }
            let hit: (loop: Fact, category: FollowUpItem.Category)? =
                lanes.onMe[chat.id].map { ($0, .onMe) } ?? lanes.onThem[chat.id].map { ($0, .onThem) }
            if chat.source.kind == .gmail {
                // Gmail has no QUIET lane. It is a signal source, not an inbox
                // mirror: only fact-backed reply debt/waiting survives, and
                // known machine noise stays hidden even if an older model
                // accidentally persisted a loop for it.
                guard let hit else { continue }
                let evidence = hit.loop.sourceText.isEmpty
                    ? lastMessage.displayText
                    : hit.loop.sourceText
                guard GmailEligibilityPolicy.shouldSurface(
                    subject: chat.title,
                    sender: hit.loop.senderName.isEmpty ? lastMessage.senderName : hit.loop.senderName,
                    body: evidence,
                    hasActionableLoop: true
                ) else { continue }
            }
            // ON ME / ON THEM rank + timestamp by the AGE OF THE ASK (the loop's
            // date), so an old pending ask doesn't ride a recent unrelated
            // message to the top. QUIET falls back to the chat's last message.
            let refDate = hit?.loop.validFrom ?? lastMessage.date
            items.append(FollowUpItem(
                chat: chat,
                category: hit?.category ?? .quiet,
                lastMessage: lastMessage,
                timeSinceLastActivity: Date().timeIntervalSince(refDate),
                suggestedAction: hit.flatMap { $0.loop.action.isEmpty ? nil : $0.loop.action },
                loopSourceMessageId: hit?.loop.sourceMessageId,
                loopEvidence: hit?.loop.sourceText,
                loopDate: hit?.loop.validFrom,
                loopPersonName: hit?.loop.subjectEntity
            ))
        }
        // "Loaded" means projected over a REAL chat snapshot — an empty candidate
        // list before TDLib streams chats must keep the skeleton up, or the view
        // flashes an empty state and then assembles row by row (the exact
        // flicker this flag exists to prevent). Once Telegram is ready, even a
        // genuinely-empty account settles.
        if !candidates.isEmpty || SourceRegistry.shared.anyReady || telegramService.authState == .ready {
            if !hasLoadedFactReplies { hasLoadedFactReplies = true }
        }
        // Signature includes the loop anchor + ask date: a projection whose only
        // change is a re-anchored/refreshed loop must still republish.
        let signature = items
            .map { "\($0.chat.id)|\($0.category.rawValue)|\($0.lastMessage.id)|\($0.loopSourceMessageId ?? 0)|\(Int($0.loopDate?.timeIntervalSince1970 ?? 0))|\($0.suggestedAction ?? "")" }
            .sorted()
            .joined(separator: ";")
        // Every completed projection is a refresh — the "Updated Nm ago"
        // label must advance even when nothing changed. But the stamp is
        // @Published on this store: stamping every 400ms projection tick
        // fires objectWillChange for every observer and defeats the
        // signature guard's whole point. The label renders minutes, so
        // 30s granularity is invisible; content changes stamp immediately.
        let now = Date()
        if signature != lastFactReplySignature
            || lastFollowUpsRefreshAt.map({ now.timeIntervalSince($0) > 30 }) ?? true {
            lastFollowUpsRefreshAt = now
        }
        guard signature != lastFactReplySignature else { return }
        lastFactReplySignature = signature
        allFollowUpItems = items
        sortPipelineItems()
    }

    private func setupFactsChangedObserverIfNeeded() {
        guard factsChangedObserver == nil else { return }
        factsChangedObserver = NotificationCenter.default.addObserver(
            forName: .contextFactsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let ts = self.lastTelegramService else { return }
                self.loadFollowUps(telegramService: ts, includeBots: self.lastIncludeBots)
            }
        }
    }

    /// Re-project the reply queue from open-loop facts. Leading + trailing
    /// debounce: project IMMEDIATELY when idle (first render never waits),
    /// coalesce bursts on a 400ms trailing edge — and because "elapsed since
    /// last projection" gates the leading edge, a sustained chat-stream storm
    /// still projects every ~400ms instead of being starved by endless re-arms.
    func loadFollowUps(
        telegramService: TelegramService,
        includeBots: Bool
    ) {
        lastTelegramService = telegramService
        lastIncludeBots = includeBots
        setupFactsChangedObserverIfNeeded()

        factReplyDebounceTask?.cancel()
        let elapsed = Date().timeIntervalSince(lastFactProjectionAt)
        let delayMs = elapsed > 0.4 ? 0 : 400
        factReplyDebounceTask = Task { @MainActor [weak self] in
            if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
            guard !Task.isCancelled, let self else { return }
            self.lastFactProjectionAt = Date()
            self.startProjection(telegramService: telegramService, includeBots: includeBots)
        }
    }

    /// Runs the projection to COMPLETION in its own task — see projectionTask.
    private func startProjection(telegramService: TelegramService, includeBots: Bool) {
        if projectionTask != nil {
            rerunAfterProjection = (telegramService, includeBots)
            return
        }
        isProjecting = true
        projectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.projectFactReplyQueue(telegramService: telegramService, includeBots: includeBots)
            self.projectionTask = nil
            if let rerun = self.rerunAfterProjection {
                self.rerunAfterProjection = nil
                self.startProjection(telegramService: rerun.service, includeBots: rerun.includeBots)
            } else {
                self.isProjecting = false
            }
        }
    }

    private func collectPipelineCandidates(
        telegramService: TelegramService,
        includeBots: Bool
    ) -> [TGChat] {
        let base = SearchChatEligibilityFilter.collectCandidateChats(
            from: SourceRegistry.shared.visibleChats,
            scope: .all
        )
        return SearchChatEligibilityFilter.applyingLikelyBotFilter(
            to: base,
            includeBots: includeBots,
            isLikelyBot: { SourceRegistry.shared.isLikelyBot(chat: $0) }
        ).included
    }

    /// Canonical sort: priority categories first (ON ME → ON THEM →
    /// QUIET), then newest-activity-first within each. After
    /// resorting, republish the filtered view so any UI bound to
    /// `followUpItems` sees the new order with excluded chats hidden.
    private func sortPipelineItems() {
        allFollowUpItems.sort { a, b in
            let order: [FollowUpItem.Category] = [.onMe, .onThem, .quiet]
            let aIndex = order.firstIndex(of: a.category) ?? 2
            let bIndex = order.firstIndex(of: b.category) ?? 2
            if aIndex != bIndex {
                return aIndex < bIndex
            }
            return a.timeSinceLastActivity < b.timeSinceLastActivity
        }
        republishFiltered()
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
