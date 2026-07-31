//
//  FactExtractionCoordinator.swift
//  Pidgy — #48 context layer
//
//  "Maintain, don't re-extract." Walks the active chats, and for each one feeds
//  only the messages NEW since its cursor (fact_extraction_state) into the fold,
//  folding in that chat's current open loops so the model can close the ones the
//  new messages answered. Incremental: every message is read exactly once.
//
//  Lives entirely behind ContextLayer.enabled — start() is a no-op when off, so
//  the whole feature is clean to keep or scrap.
//

import Combine
import Foundation
import OSLog

@MainActor
final class FactExtractionCoordinator: ObservableObject {
    static let shared = FactExtractionCoordinator()

    private weak var telegramService: TelegramService?
    private weak var aiService: AIService?
    private var passTask: Task<Void, Never>?
    /// The 15s "backlog remains, continue shortly" continuation — tracked so
    /// stop() can cancel it (an untracked Task survived shutdown and kicked
    /// a fresh pass onto a freshly-reset database).
    private var backlogTask: Task<Void, Never>?
    /// Lifecycle latch: stop() flips it, start() resets it. Guards every
    /// pass entry AND the write sites — cancellation alone can't cover
    /// caller-owned runs (the inspector's runPassNow awaits runPass outside
    /// passTask, so passTask.cancel() never reaches it).
    nonisolated(unsafe) private var stopped = false
    private var timer: Timer?
    private var chatListCancellable: AnyCancellable?
    private var contactDirectory: FactContactDirectory?
    private var directoryBuiltAt: Date?
    private var isRunning = false
    private var didBackfillLoopKinds = false
    /// Consecutive unparseable-reply failures per chat at a given cursor — after
    /// 3 the poison window is skipped so one bad window can't wedge the crawl.
    private var extractFailures: [Int64: (cursor: Int64, count: Int)] = [:]

    @Published private(set) var lastPassAt: Date?
    @Published private(set) var lastPassNewFacts = 0
    /// True while the crawl has BACKLOG left to read (cursor behind the 30-day
    /// window on some chat) — surfaces show a playful loader instead of a bare
    /// empty state. Backlog-based, NOT "did the last pass add facts": a steady
    /// stream of new facts on a caught-up account must not pin the loader, and a
    /// closes-only pass mid-crawl must not drop it. Cleared when Telegram can't
    /// run a pass (auth lost) so the loader always yields to a real state.
    @Published private(set) var isCrawling = false

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pidgy.app",
        category: "FactExtraction"
    )

    private init() {}

    /// Wire up the coordinator: an initial pass once Telegram is ready, then a
    /// periodic refresh. No-op unless the context layer is enabled.
    func start(telegramService: TelegramService, aiService: AIService) {
        guard ContextLayer.enabled else { return }
        stopped = false
        PhotoOCRIndexer.shared.resume()
        // Arm the loader from launch so an empty surface shows the pigeon (not a
        // bare empty state) during the window before the first pass resolves.
        isCrawling = true
        self.telegramService = telegramService
        self.aiService = aiService

        // Re-run as TDLib streams the chat list in over time (debounced), so
        // coverage grows from the first few chats to the full active set.
        chatListCancellable = telegramService.$chats
            .debounce(for: .seconds(8), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.triggerPass() }
            }

        passTask?.cancel()
        passTask = Task { @MainActor [weak self] in
            // Wait for auth + a populated chat list. Generous cap (~10 min):
            // a fresh onboarding legitimately takes minutes (invite code, QR
            // scan, 2FA) — the old 60s window expired mid-onboarding, dropped
            // the loader, and the entire first crawl then ran behind bare
            // empty states.
            for _ in 0..<300 {
                guard !Task.isCancelled else { return }
                if let ts = self?.telegramService, ts.authState == .ready, !ts.visibleChats.isEmpty { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard !Task.isCancelled else { return }
            // Auth never arrived: yield the loader to the real empty state
            // instead of a pigeon that can never finish.
            if let self, self.telegramService?.authState != .ready, self.isCrawling {
                self.isCrawling = false
            }
            await self?.runPass()
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.triggerPass() }
        }
    }

    /// Tear down every write source: the in-flight pass, the periodic timer,
    /// and the chat-list subscription. MUST run before "Reset all local data"
    /// closes/deletes the database (and on app termination) — otherwise a
    /// suspended extraction/OCR pass resumes mid-wipe and writes into (or
    /// reopens) the database being destroyed.
    func stop() async {
        stopped = true
        passTask?.cancel()
        passTask = nil
        backlogTask?.cancel()
        backlogTask = nil
        ocrDrainTask?.cancel()
        ocrDrainTask = nil
        timer?.invalidate()
        timer = nil
        chatListCancellable = nil
        PhotoOCRIndexer.shared.stop()
        // AWAIT the in-flight pass draining out through its stopped/cancelled
        // checkpoints — reset closes and deletes SQLite right after this, so
        // returning while a writer is suspended mid-await would let it write
        // into (or reopen) the dying handle. Bounded so quit can never wedge.
        for _ in 0..<100 where isRunning {   // ≤ ~5s
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        isCrawling = false
    }

    /// Kick a pass if one isn't already running (used by the timer + any manual refresh).
    func triggerPass() {
        guard ContextLayer.enabled, !stopped, !isRunning else { return }
        passTask?.cancel()
        passTask = Task { @MainActor [weak self] in await self?.runPass() }
    }

    /// Run a pass and return when it finishes — lets the inspector's "Run pass
    /// now" reload on real completion instead of guessing a delay. No-op if a
    /// pass is already in flight (runPass self-guards on isRunning).
    func runPassNow() async {
        guard ContextLayer.enabled, !stopped else { return }
        await runPass()
    }

    private func runPass() async {
        guard ContextLayer.enabled, !stopped, !isRunning, let telegramService, let aiService else { return }
        guard telegramService.authState == .ready else {
            // Can't crawl without Telegram (session revoked / signed out): drop
            // the loader so surfaces settle to their real states; the next
            // successful pass re-arms it if backlog remains.
            if isCrawling { isCrawling = false }
            return
        }
        guard !Task.isCancelled else { return }
        if firstAuthReadyAt == nil { firstAuthReadyAt = Date() }
        isRunning = true
        defer { isRunning = false }

        // Belt for the wait-loop cap above: the FIRST real pass of the
        // session re-arms the loader in case the auth wait dropped it (an
        // extra-slow onboarding). Pass end recomputes from actual backlog,
        // so a caught-up account clears it right back.
        if lastPassAt == nil, !isCrawling { isCrawling = true }

        let myUserId = telegramService.currentUser?.id ?? 0
        let myUser = telegramService.currentUser
        let archived = ArchivedChatsStore.archivedIds()
        let cutoff = Date().addingTimeInterval(-ContextLayer.maxChatAgeSeconds)

        // Same eligibility as the task/reply surfaces: in the main list, not a
        // channel, not archived, small enough, and active within the window.
        let visibleEligible = telegramService.visibleChats
            .filter { chat in
                guard chat.isInMainList, !chat.chatType.isChannel, !archived.contains(chat.id) else { return false }
                if let members = chat.memberCount, members > AppConstants.Indexing.maxIndexedGroupMembers { return false }
                return (chat.lastMessage?.date ?? .distantPast) >= cutoff
            }
            .sorted { ($0.lastMessage?.date ?? .distantPast) > ($1.lastMessage?.date ?? .distantPast) }

        // Bots are excluded HERE, before extraction spends anything on them.
        //
        // The Tasks page and the Reply queue each filtered bots at projection
        // time, and Ask Pidgy did not — so a bot's chatter reached exactly one
        // surface, which is how this was found. Filtering at the source fixes
        // every surface at once, including ones not written yet, and stops the
        // spend: one bot ("Poke") held 49 of ~192 stored facts and 42 of 143
        // open loops, every one of them extracted by a paid call and then
        // hidden by two of the three views.
        //
        // Cost of doing it here instead: the setting stops being instant. The
        // projection filters could hide and re-show rows on toggle; skipping
        // extraction means turning bots back ON has nothing to show until the
        // next pass re-reads those chats. `purgeFacts` clears their cursor for
        // exactly that reason, so the toggle heals itself rather than needing
        // a manual re-extract.
        let eligible: [TGChat]
        if includeBotsInAISearch() {
            eligible = visibleEligible
        } else {
            var kept: [TGChat] = []
            for chat in visibleEligible where !(await telegramService.isBotChat(chat)) {
                kept.append(chat)
            }
            eligible = kept
            await purgeStoredBotFacts(telegramService: telegramService)
        }
        // No prefix — iterate newest-active first and cap on chats actually
        // worked (those with fresh messages), so the backlog is covered across
        // passes instead of re-selecting the same newest 40 every time.

        // Sync-coverage gate: extraction must not run on a chat whose 30-day
        // window isn't fully local yet. The cursor is a high-water mark —
        // extracting a partially-synced chat stamps it at the few newest
        // messages, and everything backfilled BELOW it is silently never
        // read (fresh-install data loss). A not-ready chat first fetches its
        // own window from TDLib inside crawlChat (legacy-pipeline speed:
        // first results in minutes instead of waiting hours on the general
        // backfill), and only extracts once the window is COMPLETE.
        let readyIds = await DatabaseManager.shared.syncReadyChatIdsForExtraction(
            chatIds: eligible.map(\.id), cutoff: cutoff
        )
        var syncGateSkipped = 0
        // Crawl order: READY chats first (extraction is pure AI speed), then
        // the not-ready ones with DMs before groups and small before large —
        // a DM bootstraps in 1-3 pages, so each pass converts several chats,
        // while a big group eats the whole page budget for one. Replies and
        // tasks overwhelmingly live in DMs, so this is also value-first.
        #if DEBUG
        print("[FactCrawl] pass start: eligible=\(eligible.count) ready=\(readyIds.count)")
        #endif
        func isDM(_ chat: TGChat) -> Bool {
            if case .privateChat = chat.chatType { return true }
            return false
        }
        let eligibleOrdered = eligible.sorted { a, b in
            let aReady = readyIds.contains(a.id), bReady = readyIds.contains(b.id)
            if aReady != bReady { return aReady }
            if isDM(a) != isDM(b) { return isDM(a) }
            let aSize = a.memberCount ?? 2, bSize = b.memberCount ?? 2
            if aSize != bSize { return aSize < bSize }
            return (a.lastMessage?.date ?? .distantPast) > (b.lastMessage?.date ?? .distantPast)
        }

        // Global contact directory (cached ~5 min): lets the resolver reach
        // people only MENTIONED in a chat + unify the same person across chats.
        let directory: FactContactDirectory
        if let cached = contactDirectory, let at = directoryBuiltAt, Date().timeIntervalSince(at) < 300 {
            directory = cached
        } else {
            let rows = await DatabaseManager.shared.loadContactDirectory()
            let dmContacts: [(id: Int64, name: String)] = telegramService.visibleChats.compactMap { chat in
                if case .privateChat(let uid) = chat.chatType, uid != myUserId { return (uid, chat.title) }
                return nil
            }
            directory = FactContactDirectory.build(rows: rows, dmContacts: dmContacts)
            contactDirectory = directory
            directoryBuiltAt = Date()
        }

        var newFacts = 0
        var closedLoops = 0
        var chasedLoops = 0
        var scannedWindows = 0
        var workedChats = 0
        // Structural sweep (#48): reply-kind loops with an outgoing message
        // after their ask are answered pings — close them without depending
        // on the model emitting resolvedLoops. One global sweep per pass also
        // heals loops stuck from before this rule (a loop born in the same
        // window as the user's reply could NEVER close via resolvedLoops: it
        // wasn't in the OPEN LOOPS list yet, and later passes never see the
        // ask+reply together again).
        closedLoops += await DatabaseManager.shared.closeAnsweredReplyLoops()

        // On-device OCR batch runs CONCURRENTLY with the crawl. It used to
        // run BEFORE the windows so a payment screenshot could close its
        // loop in the same pass — but on a fresh install the 24 photo
        // downloads sit behind the initial-sync flood in the rate limiter
        // and wedged the entire pass for minutes before the FIRST
        // extraction call. Concurrent keeps extraction (the user-visible
        // value) first; a screenshot OCR'd this pass closes next pass.
        // Awaited before the pass stamps below so stop()'s drain still
        // covers this writer.
        let ocrTask = Task { [telegramService] in
            await PhotoOCRIndexer.shared.runPass(telegramService: telegramService)
        }
        // Backlog detection: true when this pass stopped for BUDGET reasons
        // (per-chat window cap, per-pass chat cap) rather than catching up —
        // that's what keeps the loader up, independent of how many facts the
        // pass happened to add.
        var backlogRemains = false
        // Parallel crawl: chats are independent (a chat's windows must stay
        // sequential — cursor + open-loops feed the next window — but there is
        // no cross-chat state). Five chats in flight overlap their AI calls,
        // which is where all the time goes; the @MainActor hops between
        // awaits are negligible. Newest-active chats still start first.
        // AI extraction runs far below provider capacity — 10 concurrent
        // chats keeps the model busy while the (much slower) TDLib fetch
        // side stays capped separately at maxBootstrapInFlight.
        let maxConcurrentChats = 10
        var chatIterator = eligibleOrdered.makeIterator()
        var ranOutOfChats = false
        await withTaskGroup(of: ChatCrawlOutcome.self) { group in
            var inFlight = 0
            func launchNext() -> Bool {
                guard !Task.isCancelled, !stopped,
                      workedChats + inFlight < ContextLayer.maxChatsPerPass else { return false }
                guard let chat = chatIterator.next() else {
                    ranOutOfChats = true
                    return false
                }
                group.addTask {
                    await self.crawlChat(
                        chat,
                        syncReady: readyIds.contains(chat.id),
                        cutoff: cutoff,
                        myUserId: myUserId,
                        myUser: myUser,
                        directory: directory,
                        aiService: aiService,
                        telegramService: telegramService
                    )
                }
                inFlight += 1
                return true
            }
            while inFlight < maxConcurrentChats, launchNext() {}
            for await outcome in group {
                inFlight -= 1
                newFacts += outcome.newFacts
                closedLoops += outcome.closedLoops
                chasedLoops += outcome.chasedLoops
                scannedWindows += outcome.scannedWindows
                if outcome.didWork { workedChats += 1 }
                if outcome.hitWindowCap || outcome.cancelled { backlogRemains = true }
                if outcome.waitingOnSync { syncGateSkipped += 1; backlogRemains = true }
                while inFlight < maxConcurrentChats, launchNext() {}
            }
        }
        // Stopped on budget/cancel with chats unvisited → backlog remains
        // (same semantics as the old cap-break). Chats waiting on the
        // sync-coverage gate are backlog too — the loader must not clear
        // while their history is still downloading.
        if !ranOutOfChats || syncGateSkipped > 0 { backlogRemains = true }
        // "Not ready yet" is not "nothing to do". The first pass after launch
        // fires before TDLib has published the chat list, so it sees zero
        // eligible chats, concludes there is no backlog, and both drops the
        // loader — surfaces then claim "All clear here" while the app is very
        // much still working — and stops chaining the next pass, leaving the
        // crawl idle until the periodic timer happens to fire. An empty chat
        // list is the tell: a genuinely caught-up account still HAS chats.
        if telegramService.visibleChats.isEmpty { backlogRemains = true }
        if syncGateSkipped > 0 {
            logger.info("sync gate: \(syncGateSkipped, privacy: .public) chats waiting on 30-day backfill")
        }

        // Do NOT await the OCR batch — even a bounded (60s) drain chained
        // every pass to the slowest photo download and capped the crawl at
        // ~1 chat/min during backlog. OCR is fully self-guarding: its
        // stopped latch blocks post-shutdown writes, and runPass skips
        // while a batch is already in flight. Track it only so stop() can
        // cancel promptly.
        ocrDrainTask = ocrTask


        // A cancelled task must not stamp pass state — its replacement runs the
        // real pass (a cancelled tail once cleared the loader mid-crawl).
        guard !Task.isCancelled else { return }

        lastPassAt = Date()
        if lastPassNewFacts != newFacts { lastPassNewFacts = newFacts }
        if isCrawling != backlogRemains { isCrawling = backlogRemains }
        logger.info("fact pass done: \(scannedWindows, privacy: .public) windows over \(workedChats, privacy: .public) chats, \(newFacts, privacy: .public) new facts, \(closedLoops, privacy: .public) closed, \(chasedLoops, privacy: .public) chased")
        #if DEBUG
        print("[Meter] pass done: \(scannedWindows) windows, \(workedChats) chats worked, +\(newFacts) facts, skippedOnSync=\(syncGateSkipped), backlog=\(backlogRemains)")
        #endif

        // One-time backfill: tag pre-existing i_owe loops reply/action so the
        // Reply queue / Tasks split applies to facts created before loop_kind.
        // Runs BEFORE the change notification so its reclassification (it moves
        // items between Tasks and the Reply queue) is included in the re-project.
        let backfillUpdated = await backfillLoopKindsIfNeeded(aiService: aiService)

        // Tell the Tasks + Reply queue views to re-project now (closed loops,
        // new loops, chases, reclassified kinds) instead of waiting for the
        // next tick.
        if newFacts > 0 || closedLoops > 0 || chasedLoops > 0 || backfillUpdated {
            NotificationCenter.default.post(name: .contextFactsChanged, object: nil)
        }

        // Backlog left (window/chat caps hit)? Continue almost immediately —
        // cursor-gated, so finished chats are skipped cheaply, and the rate
        // limiter (not this delay) is the real pacing for TDLib. When
        // nothing remains, backlogRemains goes false and the chain stops.
        if backlogRemains, !stopped {
            backlogTask?.cancel()
            backlogTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, !self.stopped else { return }
                self.triggerPass()
            }
        }
    }

    /// One-time per launch: classify open i_owe loops that predate the loop_kind
    /// tag so the Reply queue / Tasks split applies to existing facts without
    /// waiting for every chat to re-extract. The model decides reply vs action —
    /// no keyword heuristics. Returns whether any loop_kind actually changed so
    /// the caller can include the reclassification in its change notification.

    /// Everything the pass does for ONE chat — windows walked sequentially
    /// (cursor + open-loop state feed the next window), returning deltas the
    /// pass aggregates. Runs inside a task group; only AI/network awaits
    /// overlap across chats.
    /// Chats whose bootstrap fetch hit the PAGE CAP this session — genuinely
    /// huge chats that the coverage coordinator should finish instead of
    /// re-fetching from scratch every 15s pass. Transient failures (rate
    /// limit, network, timeout) do NOT land here — those retry next pass.
    private var bootstrapFetchCapped: Set<Int64> = []

    /// Per-chat bootstrap pagination resume point. History calls serialize
    /// globally at the rate limiter, so pages are precious — restarting
    /// from page 1 every 15s pass threw the progress away and no chat ever
    /// reached the cutoff. Survives across passes; cleared on completion.
    private struct BootstrapProgress {
        var fromMessageId: Int64 = 0
        var oldestDate: Date?
        var oldestId: Int64 = 0
        var latestId: Int64 = 0
        var pagesFetched = 0
    }
    private var bootstrapProgress: [Int64: BootstrapProgress] = [:]

    /// Matches `RateLimiter.maxHistoryCallsInFlight` — that constant is the
    /// real width of the history lane, and anything more here just queues
    /// against it. Both moved 2 → 4 → 8 together; raising only this one would
    /// have changed nothing, which is worth knowing before trying it.
    ///
    /// The original 2 came from a real failure: five concurrent bootstraps
    /// parked hung calls in both slots and froze the whole history lane,
    /// RecentSync included. TDLibKit calls still can't be cancelled, so that
    /// mode isn't gone — but the 90s `withBootstrapTimeout` bounds the wait,
    /// and eight slots mean one parked call leaves seven working.
    private var bootstrapInFlightCount = 0
    private static let maxBootstrapInFlight = 8
    /// The most recent pass's OCR batch — NOT awaited at pass end (it must
    /// not gate crawl cadence); tracked so stop() can cancel it.
    private var ocrDrainTask: Task<Void, Never>?

    /// PER-CHAT cooldown after a bootstrap page times out. A timeout on one
    /// big group must only pause THAT chat — the first version used one
    /// global cooldown and a single slow supergroup froze the entire tail
    /// (22 other chats fail-fasted in a loop for minutes). The hung
    /// underlying call still drains inside the rate limiter's serialized
    /// slot, which is what actually protects the lane.
    private var bootstrapChatCooldownUntil: [Int64: Date] = [:]
    /// Short hold-off after auth so the initial dialog sync gets the history
    /// lane to itself for a moment. This was 180s while the member-count
    /// leak (23k getSupergroupFullInfo calls) was starving the rate limiter
    /// and making every early history call hang; with that fixed the lane is
    /// free, so a fresh install no longer pays 3 dead minutes before its
    /// first facts.
    private var firstAuthReadyAt: Date?
    private static let postAuthBootstrapGrace: TimeInterval = 45

    private struct BootstrapTimeoutError: Error {}

    /// Once-latched continuation resume (same shape as the coverage
    /// coordinator's TimeoutRace — a class can't nest in a generic func).
    private final class BootstrapRace<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func resume(_ result: Result<T, Error>, _ c: CheckedContinuation<T, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            c.resume(with: result)
        }
    }

    /// Timeout race for one bootstrap history page. Mirrors the coverage
    /// coordinator's withHistoryFetchTimeout: detached tasks + a
    /// once-latched continuation, NOT a task group — a hung TDLib call
    /// ignores cancellation and a group would wait for it on scope exit,
    /// which is exactly the wedge this exists to break. The losing call
    /// keeps running inside TDLibKit; the rate limiter serializes the next
    /// history call behind it, so nothing piles up.
    private static func withBootstrapTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let operationTask = Task<T, Error> { try await operation() }
        let timeoutTask = Task<T, Error> {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw BootstrapTimeoutError()
        }
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }
        return try await withCheckedThrowingContinuation { continuation in
            let race = BootstrapRace<T>()
            Task {
                do { race.resume(.success(try await operationTask.value), continuation) }
                catch { race.resume(.failure(error), continuation) }
            }
            Task {
                do { race.resume(.success(try await timeoutTask.value), continuation) }
                catch { race.resume(.failure(error), continuation) }
            }
        }
    }

    /// Legacy-pipeline speed for fresh installs: a chat whose 30-day window
    /// isn't synced yet fetches its OWN history from TDLib (newest → oldest,
    /// background priority, through the shared rate limiter) and persists it
    /// via the normal message path. Returns true only when the window is
    /// COMPLETE locally (reached the cutoff, or history exhausted) — a
    /// partial window must not be extracted, because the cursor is a
    /// high-water mark and later backfill below it would never be read.
    private func bootstrapWindowFetch(
        chat: TGChat,
        cutoff: Date,
        telegramService: TelegramService
    ) async -> Bool {
        guard !bootstrapFetchCapped.contains(chat.id) else { return false }
        guard bootstrapInFlightCount < Self.maxBootstrapInFlight else { return false } // chat retries next pass
        if let cooldown = bootstrapChatCooldownUntil[chat.id], cooldown > Date() { return false }
        // Post-auth grace: let the initial dialog sync breathe first.
        if let readyAt = firstAuthReadyAt,
           Date().timeIntervalSince(readyAt) < Self.postAuthBootstrapGrace { return false }
        bootstrapInFlightCount += 1
        defer { bootstrapInFlightCount -= 1 }
        #if DEBUG
        print("[FactCrawl] bootstrap start: chat=\(chat.id) '\(chat.title.prefix(18))' resumePages=\(bootstrapProgress[chat.id]?.pagesFetched ?? 0)")
        defer { print("[FactCrawl] bootstrap end: chat=\(chat.id) pages=\(bootstrapProgress[chat.id]?.pagesFetched ?? -1)") }
        #endif

        // Resume where the last pass left off — pages are serialized at the
        // rate limiter, so refetching them is the difference between a crawl
        // that converges and one that grinds page-1s forever.
        var progress = bootstrapProgress[chat.id] ?? BootstrapProgress()
        var reachedCutoff = (progress.oldestDate ?? .distantFuture) <= cutoff
        var historyExhausted = false
        // ≤ ~3000 messages per chat TOTAL (across passes) — only truly huge
        // chats fall through to the coverage coordinator.
        while !reachedCutoff, !historyExhausted, progress.pagesFetched < 30 {
            guard !Task.isCancelled, !stopped else {
                bootstrapProgress[chat.id] = progress
                return false
            }
            let page: [TGMessage]
            do {
                let pageFrom = progress.fromMessageId
                // Local-first (free, separate rate bucket — TDLib serves its
                // own cache): only when the local slice runs dry does the
                // page go to the network at userInitiated priority, with a
                // timeout so one hung call can't wedge the pass (that froze
                // extraction for 9+ minutes before).
                let localPage = (try? await telegramService.getChatHistory(
                    chatId: chat.id, fromMessageId: pageFrom, limit: 100,
                    onlyLocal: true, priority: .userInitiated
                )) ?? []
                if !localPage.isEmpty {
                    page = localPage
                } else {
                    page = try await Self.withBootstrapTimeout(seconds: 90) {
                        try await telegramService.getChatHistory(
                            chatId: chat.id, fromMessageId: pageFrom, limit: 100,
                            onlyLocal: false, priority: .userInitiated
                        )
                    }
                }
            } catch {
                bootstrapProgress[chat.id] = progress // transient — resume next pass
                if error is BootstrapTimeoutError {
                    // This chat's history is slow right now — pause IT, not
                    // the whole tail. The abandoned call drains inside its
                    // serialized rate-limiter slot regardless.
                    bootstrapChatCooldownUntil[chat.id] = Date().addingTimeInterval(120)
                }
                return false
            }
            guard !Task.isCancelled, !stopped else {
                bootstrapProgress[chat.id] = progress
                return false
            }
            if page.isEmpty {
                historyExhausted = true // no older messages exist
                break
            }
            progress.pagesFetched += 1
            #if DEBUG
            print("[FactCrawl] bootstrap page: chat=\(chat.id) n=\(page.count) oldest=\(page.map(\.date).min().map { ISO8601DateFormatter().string(from: $0) } ?? "?")")
            #endif
            await MessageCacheService.shared.cacheMessages(chatId: chat.id, messages: page, append: true)
            if let pageOldest = page.min(by: { $0.date < $1.date }) {
                progress.oldestDate = min(progress.oldestDate ?? .distantFuture, pageOldest.date)
                progress.oldestId = pageOldest.id
                progress.fromMessageId = pageOldest.id
            }
            progress.latestId = max(progress.latestId, page.map(\.id).max() ?? 0)
            if let oldest = progress.oldestDate, oldest <= cutoff {
                reachedCutoff = true
            }
        }

        guard reachedCutoff || historyExhausted else {
            // Page cap across passes — a genuinely huge chat. Latch it so
            // the pass chain moves on; the coverage coordinator finishes it.
            bootstrapFetchCapped.insert(chat.id)
            bootstrapProgress[chat.id] = nil
            return false
        }
        bootstrapProgress[chat.id] = nil
        let oldestDate = progress.oldestDate
        let oldestId = progress.oldestId
        let latestId = progress.latestId
        // Exhausted history on a young chat: everything that exists is local,
        // so the whole window counts as covered (boundary = cutoff).
        let boundary = reachedCutoff ? (oldestDate ?? cutoff) : cutoff
        // Stamp coverage so the readiness query passes from now on (and the
        // next session doesn't re-fetch). is_major=0 + version 0: the
        // coverage coordinator remains free to re-verify and overwrite with
        // its own authoritative row.
        await DatabaseManager.shared.saveChatCoverageState(
            DatabaseManager.ChatCoverageStateRecord(
                chatId: chat.id,
                oldestCoveredAt: boundary,
                oldestCoveredMessageId: oldestId,
                latestSeenMessageId: latestId,
                lastCheckedAt: Date(),
                isMajor: false,
                lastError: nil,
                failureCount: 0,
                nextRetryAt: nil,
                coverageVersion: 0
            )
        )
        return true
    }

    private struct ChatCrawlOutcome {
        var newFacts = 0
        var closedLoops = 0
        var chasedLoops = 0
        var scannedWindows = 0
        var didWork = false
        var hitWindowCap = false
        var cancelled = false
        /// This chat's 30-day window isn't locally complete yet (bootstrap
        /// fetch pending/failed) — no extraction ran, keep the loader up.
        var waitingOnSync = false
    }

    private func crawlChat(
        _ chat: TGChat,
        syncReady: Bool,
        cutoff: Date,
        myUserId: Int64,
        myUser: TGUser?,
        directory: FactContactDirectory,
        aiService: AIService,
        telegramService: TelegramService
    ) async -> ChatCrawlOutcome {
        var out = ChatCrawlOutcome()

            if !syncReady {
                let complete = await bootstrapWindowFetch(
                    chat: chat, cutoff: cutoff, telegramService: telegramService
                )
                guard complete else {
                    out.waitingOnSync = true
                    return out
                }
            }
            var cursor = await DatabaseManager.shared.factExtractionCursor(chatId: chat.id)
            var windows = 0
            var didWork = false
            // Forward crawl: walk this chat's 30-day window oldest-first in
            // chunks, a few per pass. The cursor persists, so a deep chat catches
            // up over subsequent passes rather than being read all at once.
            while windows < ContextLayer.maxWindowsPerChatPerPass {
                // stopped covers caller-owned runs (runPassNow) that task
                // cancellation can't reach — no window may start, and no
                // write below may land, once shutdown began.
                guard !Task.isCancelled, !stopped else { out.cancelled = true; break }
                let records = await DatabaseManager.shared.loadMessagesForward(
                    chatId: chat.id,
                    afterMessageId: cursor,
                    since: cutoff,
                    limit: ContextLayer.extractionWindow
                )
                guard !records.isEmpty else { break }
                didWork = true

                // Records are id ASC (chronological); extractFacts re-sorts by date too.
                let tgMessages = records.map { Self.tgMessage(from: $0, chatTitle: chat.title) }
                // Trailing context: the last few ALREADY-processed messages, so a
                // tiny window (one terse ping after a long thread) isn't judged
                // blind — that produced invented connections and re-emissions.
                let contextRecords = cursor > 0
                    ? await DatabaseManager.shared.loadMessagesBefore(chatId: chat.id, throughMessageId: cursor, limit: 8)
                    : []
                let contextMessages = contextRecords.map { Self.tgMessage(from: $0, chatTitle: chat.title) }
                let openLoops = await DatabaseManager.shared
                    .loadOpenFacts(chatId: chat.id)
                    .filter { $0.predicate.isOpenLoop }

                do {
                    let aiStart = Date()
                    let result = try await aiService.extractFacts(
                        chat: chat,
                        newMessages: tgMessages,
                        contextMessages: contextMessages,
                        openLoops: openLoops,
                        myUserId: myUserId,
                        myUser: myUser
                    )
                    #if DEBUG
                    print("[Meter] AI extract: '\(chat.title.prefix(16))' \(records.count) msgs → \(String(format: "%.1f", Date().timeIntervalSince(aiStart)))s, \(result.drafts.count) facts")
                    #endif
                    // The AI call is the LONG await — stop() can outlive its
                    // bounded drain while we're suspended here. Recheck before
                    // any write may land: after this guard the only writes are
                    // the single atomic commit below.
                    guard !Task.isCancelled, !stopped else { out.cancelled = true; break }
                    extractFailures[chat.id] = nil
                    // Structural gates for closing loops — never message content,
                    // so crafted text alone can't forge a closure:
                    //  - i_owe closes only when a genuine outgoing/[ME] message
                    //    exists in the window (the user acted);
                    //  - owes_me closes only when a genuine INBOUND message exists
                    //    (the other side acted — they delivered/answered). Worst
                    //    case for a malicious sender is hiding a reminder about
                    //    what THEY owe, never the user's own tasks.
                    // The model is the targeting check on top: resolvedLoops must
                    // name the specific loop the new messages addressed.
                    let myOutgoingId = records
                        .filter { $0.isOutgoing || (myUserId > 0 && $0.senderUserId == myUserId) }
                        .map(\.id).max()
                    let hasInbound = records.contains {
                        !$0.isOutgoing && !(myUserId > 0 && $0.senderUserId == myUserId)
                    }
                    // Resolve each subject to a canonical person id (DM
                    // counterparty / chat-sender match) so name variants collapse
                    // and facts join the People graph. Then the stillborn gate:
                    // a reply-kind loop whose ask the user ALREADY answered in
                    // this same window must not be born — resolvedLoops can only
                    // target pre-existing loops, so it could never close later.
                    let resolved = result.drafts.map { draft -> FactDraft in
                        var d = draft
                        let (pid, name) = FactEntityResolver.resolve(
                            subject: draft.subjectEntity,
                            predicate: draft.predicate,
                            chat: chat,
                            myUserId: myUserId,
                            directory: directory
                        )
                        d.subjectPersonId = pid
                        d.subjectEntity = name
                        return d
                    }
                    .filter { d in
                        guard d.predicate == .iOwe, d.loopKind == .reply,
                              let out = myOutgoingId else { return true }
                        return out <= d.sourceMessageId
                    }

                    // Structural close gates (see above) applied to the model's
                    // resolvedLoops. Close-before-upsert ordering lives inside
                    // the atomic commit.
                    let resolvedSet = Set(result.resolvedFingerprints)
                    let safeCloses = openLoops
                        .filter { f in
                            guard resolvedSet.contains(f.fingerprint) else { return false }
                            switch f.predicate {
                            case .iOwe: return myOutgoingId != nil
                            case .owesMe: return hasInbound
                            default: return false
                            }
                        }
                        .map(\.fingerprint)
                    // Chases: a follow-up ping bumps the existing loop to the
                    // chase message (date + evidence), gated like owes_me closes
                    // on a genuine inbound message — [ME]'s own text can't bump.
                    let chases = hasInbound ? result.chasedLoops : []
                    // ONE transaction: closes + upserts + chases + cursor
                    // advance land together or not at all. A throw leaves the
                    // cursor behind so the whole window retries next pass —
                    // the old fire-and-forget writes let a transient DB error
                    // skip a window forever.
                    let windowMax = records.map(\.id).max() ?? cursor
                    try await DatabaseManager.shared.applyExtractionWindow(
                        chatId: chat.id,
                        closeFingerprints: safeCloses,
                        upserts: resolved,
                        chases: chases,
                        advanceCursorTo: windowMax
                    )
                    out.closedLoops += safeCloses.count
                    out.newFacts += resolved.count
                    out.chasedLoops += chases.count
                    cursor = windowMax
                    // Structural sweep: this window's outgoing messages answer
                    // any older reply-kind loop of this chat, whether or not
                    // the model emitted resolvedLoops for it. Outside the
                    // transaction on purpose — it re-runs every pass, so a
                    // failure here loses nothing.
                    if myOutgoingId != nil {
                        out.closedLoops += await DatabaseManager.shared.closeAnsweredReplyLoops(chatId: chat.id)
                    }
                } catch {
                    logger.error("extractFacts failed for chat \(chat.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    // A window whose CONTENT deterministically breaks the model
                    // (unparseable reply every time) must not wedge this chat's
                    // crawl forever: after 3 failed attempts on the SAME cursor,
                    // skip past the poison window. Transient provider/network
                    // errors don't count — they retry indefinitely and self-heal.
                    if case FactExtractionError.unparseableResponse = error {
                        let windowMax = records.map(\.id).max() ?? cursor
                        var entry = extractFailures[chat.id] ?? (cursor: cursor, count: 0)
                        if entry.cursor != cursor { entry = (cursor: cursor, count: 0) }
                        entry.count += 1
                        extractFailures[chat.id] = entry
                        // Post-await shutdown guard: this catch runs right
                        // after the failed AI await, and the skip below is a
                        // WRITE. If shutdown began, leave the failure count —
                        // the poison window just skips on a later pass.
                        if entry.count >= 3, !Task.isCancelled, !stopped {
                            logger.error("skipping poison window for chat \(chat.id, privacy: .public) after \(entry.count, privacy: .public) unparseable replies")
                            cursor = windowMax
                            await DatabaseManager.shared.updateFactExtractionCursor(chatId: chat.id, throughMessageId: cursor)
                            extractFailures[chat.id] = nil
                        }
                    }
                    break
                }

                windows += 1
                out.scannedWindows += 1
                if records.count < ContextLayer.extractionWindow { break } // caught up to now
            }
            // Exited on the per-chat window cap (not the caught-up break) →
            // this chat still has unread backlog.
            if windows >= ContextLayer.maxWindowsPerChatPerPass { out.hitWindowCap = true }
            out.didWork = didWork

            // Entity memory (M1): fold ACCUMULATED unfolded messages into the
            // chat's rolling summary — but only once enough conversation has
            // built up. Folding every pass ran the priciest AI stage hundreds
            // of times a day for 2-message drips (90% of the AI bill). Below
            // the threshold the summary's through-cursor stays put, so those
            // messages simply fold later, nothing is lost. Non-fatal — a
            // failed fold retries next pass. NOT gated on didWork: the
            // extraction cursor advances BEFORE folding, so after a failed
            // fold the next pass sees no new extraction work — a didWork
            // gate left quiet chats stale until another message arrived.
            // The threshold check below is two cheap local reads.
            if !Task.isCancelled, !stopped {
                let current = await DatabaseManager.shared.loadCurrentChatSummary(chatId: chat.id)
                let foldedThrough = current?.throughMessageId ?? 0
                // FORWARD from the summary's own cursor (oldest unfolded
                // first), capped per fold — and the cursor advances only to
                // the last message actually folded. Loading the NEWEST 60
                // and stamping the crawl cursor silently dropped everything
                // between the two on deep backlogs; now a >60 backlog just
                // takes extra folds on later passes, losing nothing.
                let unfoldedRecords = await DatabaseManager.shared
                    .loadMessagesForward(chatId: chat.id, afterMessageId: foldedThrough, since: cutoff, limit: 60)
                    .filter { $0.id <= cursor }
                let bootstrap = current == nil && unfoldedRecords.count >= 2
                if bootstrap || unfoldedRecords.count >= 6 {
                    let unfolded = unfoldedRecords.map { Self.tgMessage(from: $0, chatTitle: chat.title) }
                    do {
                        let updated = try await aiService.foldChatSummary(
                            chat: chat,
                            oldSummary: current?.summary,
                            newMessages: unfolded,
                            myUserId: myUserId,
                            myUser: myUser
                        )
                        // Same long-await rule as extraction: no write may
                        // land once shutdown began during the AI call.
                        guard !Task.isCancelled, !stopped else { return out }
                        await DatabaseManager.shared.saveChatSummary(
                            chatId: chat.id,
                            title: chat.title,
                            summary: updated,
                            throughMessageId: unfoldedRecords.map(\.id).max() ?? foldedThrough
                        )
                    } catch {
                        logger.error("summary fold failed for chat \(chat.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        return out
    }

    /// Read fresh each pass rather than cached at start: the user can flip
    /// the toggle mid-session, and the next pass is where that has to take
    /// effect.
    private func includeBotsInAISearch() -> Bool {
        UserDefaults.standard.bool(forKey: AppConstants.Preferences.includeBotsInAISearchKey)
    }

    /// Delete facts already stored for bot chats.
    ///
    /// Driven from the fact store rather than the eligible set, because a bot
    /// chat that has gone quiet or been archived drops out of eligibility
    /// while its rows stay — and those are exactly the ones nobody would
    /// notice. Chats the client can't currently see are left alone: an
    /// unresolvable id is far more likely to be a chat TDLib hasn't loaded yet
    /// than a bot, and deleting on that guess is unrecoverable.
    private func purgeStoredBotFacts(telegramService: TelegramService) async {
        let storedIds = Set(await DatabaseManager.shared.factChatIds())
        guard !storedIds.isEmpty else { return }
        var botChatIds: [Int64] = []
        for chat in telegramService.visibleChats where storedIds.contains(chat.id) {
            if await telegramService.isBotChat(chat) { botChatIds.append(chat.id) }
        }
        let purged = await DatabaseManager.shared.purgeFacts(chatIds: botChatIds)
        guard purged > 0 else { return }
        #if DEBUG
        print("[FactCrawl] purged \(purged) fact(s) from \(botChatIds.count) bot chat(s)")
        #endif
        NotificationCenter.default.post(name: .contextFactsChanged, object: nil)
    }

    private func backfillLoopKindsIfNeeded(aiService: AIService) async -> Bool {
        guard !didBackfillLoopKinds else { return false }
        let pending = await DatabaseManager.shared.loadUnclassifiedIOweLoops(limit: 500)
        guard !pending.isEmpty else { didBackfillLoopKinds = true; return false }
        var classified = 0
        for batch in pending.chunked(into: 40) {
            do {
                let kinds = try await aiService.classifyLoops(batch)
                // Post-await shutdown guard, same rule as every writer: the
                // classify call can outlive stop()'s bounded drain.
                guard !Task.isCancelled, !stopped else { return classified > 0 }
                await DatabaseManager.shared.updateLoopKinds(kinds)
                classified += kinds.count
            } catch {
                logger.error("loop_kind backfill failed: \(error.localizedDescription, privacy: .public)")
                // Leave the flag false so the next pass retries the rest —
                // classifyLoops THROWS on an unparseable reply (it never silently
                // returns empty), so a failed batch can't mark the backfill done.
                return classified > 0
            }
        }
        // Only a run that classified something (or had nothing to do) is done —
        // 0/N classified with no error would otherwise never retry this session.
        didBackfillLoopKinds = classified > 0 || pending.isEmpty
        logger.info("loop_kind backfill: classified \(classified, privacy: .public)/\(pending.count, privacy: .public) loops")
        return classified > 0
    }

    private static func tgMessage(from record: DatabaseManager.MessageRecord, chatTitle: String?) -> TGMessage {
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
