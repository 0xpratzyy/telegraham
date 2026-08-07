import SwiftUI
import Combine
import TDLibKit

struct LauncherView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService
    @EnvironmentObject var registry: SourceRegistry
    @ObservedObject var photoManager = ChatPhotoManager.shared
    @StateObject private var searchCoordinator = SearchCoordinator()
    @StateObject private var attentionStore = AttentionStore.shared
    @StateObject private var taskIndex = TaskIndexCoordinator.shared
    @AppStorage(AppConstants.Preferences.includeBotsInAISearchKey) private var includeBotsInAISearch = false

    // Search & filter
    @State private var searchText = ""
    // True for a beat right after the query changes — covers the debounce/gate
    // gap BEFORE isAISearching flips, so the results area shows a skeleton
    // immediately instead of flashing "0 results" and then loading.
    @State private var searchSettling = false
    @State private var searchSettleTask: Task<Void, Never>?
    // Context layer (#48): the fact-grounded answer engine ("Ask Pidgy"),
    // presented as a chat thread — user bubbles + Pidgy replies, follow-ups
    // typed into the (repurposed) search field. Esc returns to search.
    // Engine + thread UI live in AskPidgyChat.swift (shared with dashboard).
    @StateObject private var askChat = AskPidgyChatModel()
    @State private var chatMode = false
    @State private var answeredQuery = ""   // dedups the planner auto-trigger
    @State private var lastEnterAt = Date.distantPast
    @FocusState private var isSearchFocused: Bool

    // Filter tags
    enum Filter: String, CaseIterable {
        case all = "All"
        case dms = "DMs"
        case groups = "Groups"
    }

    @State private var activeFilter: Filter = .all
    @State private var activeSource: MessageSourceKind?

    // Opacity that pulses between 1.0 and ~0.55 while an AI search is
    // in flight. Lights up the search input so the user has a visible
    // "engine is thinking" cue right where they're looking. Driven by
    // an .onChange(isAISearching) below; idle stays at 1.0.
    @State private var inputPulseOpacity: Double = 1.0

    // Keyboard navigation
    @State private var selectedIndex: Int = 0

    // Follow-ups state
    @State private var pipelineSubFilter: FollowUpItem.Category? = nil

    // Background pipeline refresh
    @State private var pipelineAutoLoaded = false
    @State private var chatPreviewById: [Int64: String] = [:]
    @State private var chatPreviewTask: Task<Void, Never>?


    // MARK: - AI Search Result Types
    // MARK: - Computed

    private var searchResultChatIds: Set<Int64> { searchCoordinator.searchResultChatIds }
    private var isSearching: Bool { searchCoordinator.isSearching }
    private var aiResults: [AISearchResult] { searchCoordinator.aiResults }
    private var aiSearchMode: QueryIntent? { searchCoordinator.aiSearchMode }
    private var isAISearching: Bool { searchCoordinator.isAISearching }
    private var aiSearchError: String? { searchCoordinator.aiSearchError }
    private var currentQuerySpec: QuerySpec? { searchCoordinator.currentQuerySpec }
    private var routingSnapshot: SearchRoutingSnapshot? { searchCoordinator.routingSnapshot }
    private var summaryOutput: SummarySearchOutput? { searchCoordinator.summaryOutput }
    private var semanticMatchedChats: Int { searchCoordinator.semanticMatchedChats }
    private var totalChatsToScan: Int { searchCoordinator.totalChatsToScan }
    private var searchStartedAt: Foundation.Date? { searchCoordinator.searchStartedAt }
    private var lastSearchDuration: TimeInterval? { searchCoordinator.lastSearchDuration }
    private var followUpItems: [FollowUpItem] { attentionStore.followUpItems }
    private var showLauncherDebugOverlays: Bool { false }

    private var proactiveGmailChatIds: Set<Int64> {
        Set(followUpItems
            .filter { $0.chat.source.kind == .gmail }
            .map(\.chat.id))
            .union(taskIndex.tasks.compactMap { task in
                registry.chat(id: task.chatId)?.source.kind == .gmail ? task.chatId : nil
            })
    }

    private var proactiveVisibleChats: [TGChat] {
        registry.visibleChats.filter { chat in
            chat.source.kind != .gmail || proactiveGmailChatIds.contains(chat.id)
        }
    }

    private var displayedChats: [TGChat] {
        let pipelineMatchingIds = pipelineSubFilter.map { subFilter in
            Set(followUpItems.filter { $0.category == subFilter }.map(\.chat.id))
        }

        let filtered = LauncherVisibleChatsFilter.filterChats(
            from: proactiveVisibleChats.filter { activeSource == nil || $0.source.kind == activeSource },
            scope: queryScope(for: activeFilter),
            pipelineMatchingIds: pipelineMatchingIds,
            searchText: searchText,
            searchResultChatIds: searchResultChatIds,
            includeBots: includeBotsInAISearch,
            isLikelyBot: { registry.isLikelyBot(chat: $0) }
        )
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return filtered }
        return filtered.sorted { ($0.lastActivityDate ?? .distantPast) > ($1.lastActivityDate ?? .distantPast) }
    }

    private var aiSearchSourceChats: [TGChat] {
        proactiveVisibleChats.filter { chat in
            (activeSource == nil || chat.source.kind == activeSource)
                && (includeBotsInAISearch || !registry.isLikelyBot(chat: chat))
        }
    }

    private var scopedAISearchSourceChats: [TGChat] {
        switch activeFilter {
        case .all:
            return aiSearchSourceChats
        case .dms:
            return aiSearchSourceChats.filter { $0.chatType.isPrivate }
        case .groups:
            return aiSearchSourceChats.filter { $0.chatType.isGroup }
        }
    }

    // MARK: - Pipeline Helpers

    private func pipelineCategory(for chatId: Int64) -> FollowUpItem.Category? {
        attentionStore.pipelineCategory(for: chatId)
    }

    private func pipelineSuggestion(for chatId: Int64) -> String? {
        attentionStore.pipelineSuggestion(for: chatId)
    }

    private func messagePreview(for chat: TGChat) -> String? {
        if let preview = chatPreviewById[chat.id] {
            return preview
        }
        return LauncherChatPreviewResolver.resolvePreview(
            for: chat,
            recentMessages: []
        ).text
    }

    private func refreshChatPreviews(for chats: [TGChat]? = nil) {
        let targetChats = chats ?? displayedChats
        let targetIds = Set(targetChats.map(\.id))

        chatPreviewTask?.cancel()

        guard !targetChats.isEmpty else {
            chatPreviewById.removeAll()
            return
        }

        chatPreviewTask = Task {
            let cache = MessageCacheService.shared
            var updates: [Int64: String] = [:]

            for chat in targetChats {
                if Task.isCancelled { return }

                var recentMessages = await cache.getMessages(chatId: chat.id) ?? []
                var resolution = LauncherChatPreviewResolver.resolvePreview(
                    for: chat,
                    recentMessages: recentMessages
                )

                if LauncherChatPreviewResolver.shouldFetchRecentContext(
                    for: chat,
                    recentMessages: recentMessages,
                    currentResolution: resolution,
                    cachedMessageCount: recentMessages.count
                ),
                   let fetched = try? await telegramService.getChatHistory(
                    chatId: chat.id,
                    limit: LauncherChatPreviewResolver.contextMessageLimit
                   ),
                   !fetched.isEmpty {
                    recentMessages = fetched
                    await cache.cacheMessages(chatId: chat.id, messages: fetched)
                    resolution = LauncherChatPreviewResolver.resolvePreview(
                        for: chat,
                        recentMessages: recentMessages
                    )
                }

                updates[chat.id] = resolution.text
            }

            if Task.isCancelled { return }

            await MainActor.run {
                chatPreviewById = chatPreviewById.filter { targetIds.contains($0.key) }
                for (chatId, preview) in updates {
                    chatPreviewById[chatId] = preview
                }
            }
        }
    }

    /// Total navigable items (either AI results or chat rows depending on mode).
    private var navigableCount: Int {
        if let aiSearchMode,
           aiSearchMode != .unsupported,
           !aiResults.isEmpty {
            return aiResults.count
        }
        return displayedChats.count
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if telegramService.authState == .ready {
                if chatMode {
                    // Chat layout: thread on top, composer at the bottom —
                    // like any messaging app.
                    Group {
                        if askChat.thread.isEmpty && !askChat.isAnswering {
                            askChatEmptyState
                        } else {
                            AskPidgyThreadView(model: askChat)
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: 10)))
                    Divider()
                    searchBar
                } else {
                    searchBar

                    // AI mode banner
                    if let mode = aiSearchMode, !searchText.isEmpty {
                        aiModeBanner(intent: mode)
                    }

                    filterTags

                    Divider()

                    resultsList
                }
            } else {
                // Auth happens inside the dedicated OnboardingFlow window
                // now — don't double up the QR / phone UI here. Send the
                // user there so they see one consistent surface.
                LauncherOnboardingHandoff()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(PidgyMotion.easeOut, value: chatMode)
        .background(Color.Pidgy.bg1)
        .ignoresSafeArea()
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
            telegramService.scheduleBotMetadataWarm(
                for: telegramService.visibleChats,
                includeBots: includeBotsInAISearch
            )
            refreshChatPreviews()
            Task { await IndexScheduler.shared.pause() }
        }
        .onDisappear {
            telegramService.cancelBotMetadataWarm()
            chatPreviewTask?.cancel()
            Task { await IndexScheduler.shared.resume() }
        }
        .task {
            // Auto-load pipeline on startup so menu bar badge works even before user opens Pipeline tab
            guard !pipelineAutoLoaded else { return }
            // Wait for Telegram auth + chats to load
            for _ in 0..<60 {  // 30s max (60 × 0.5s)
                if telegramService.authState == .ready,
                   !telegramService.chats.isEmpty {
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !telegramService.chats.isEmpty else { return }

            await telegramService.ensureBotFilterMetadataReady(
                for: telegramService.visibleChats,
                includeBots: includeBotsInAISearch,
                priority: .background
            )

            pipelineAutoLoaded = true
            loadFollowUps()
        }
        .onReceive(
            telegramService.$chats
                .dropFirst()
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        ) { _ in
            refreshChatPreviews()
        }
        .onReceive(
            telegramService.$chats
                .dropFirst()  // Skip initial load (handled by .task above)
                .debounce(for: .seconds(10), scheduler: RunLoop.main)
        ) { _ in
            telegramService.scheduleBotMetadataWarm(
                for: telegramService.visibleChats,
                includeBots: includeBotsInAISearch
            )
            loadFollowUps()
        }
        .onChange(of: telegramService.botMetadataRefreshVersion) {
            refreshBotFilteredUI()
        }
        .onChange(of: searchText) {
            // In chat mode the field is the chat composer — typing must not
            // drive the search machinery.
            guard !chatMode else { return }
            selectedIndex = 0
            refreshChatPreviews()
            let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                if trimmedQuery.isEmpty && !isSearchFocused {
                    await IndexScheduler.shared.resume()
                } else {
                    await IndexScheduler.shared.pause()
                }
            }
            triggerSearch()
            // Loading turant: while the search machinery is deciding what to
            // run (debounce → gate → planner), an empty list means "pending",
            // not "no results". Settles to the truth after 1.2s if nothing
            // deeper starts (isAISearching takes over from there).
            searchSettleTask?.cancel()
            if trimmedQuery.isEmpty {
                searchSettling = false
            } else {
                searchSettling = true
                searchSettleTask = Task { @MainActor in
                    // Long enough to cover debounce + gate + planner before
                    // isAISearching takes over — 1.2s expired mid-pipeline and
                    // flashed "No results" before the deep search began.
                    try? await Task.sleep(for: .milliseconds(3000))
                    guard !Task.isCancelled else { return }
                    searchSettling = false
                }
            }
        }
        // When the AI query planner (already running for chat search) parses
        // out WHO the query is about, a person-question auto-opens the Ask
        // Pidgy chat: the question becomes the first user bubble and the fast
        // answer engine (rolling summaries + open loops, ~1.5s) replies. The
        // router routes these to local semantic ranking, so the chat is the
        // ONLY summary surface. Reply-queue questions ("who do I owe replies")
        // take the same path — the answer engine holds the open loops.
        // Observes resolvedQuerySpec (post-planner), NEVER currentQuerySpec:
        // the deterministic parse publishes per keystroke, which would open
        // the chat mid-typing on a truncated query — and firing from inside
        // the search task means enterChat's cancelSearch() genuinely stops
        // the underlying search instead of racing it.
        .onReceive(searchCoordinator.$resolvedQuerySpec) { spec in
            guard ContextLayer.enabled, aiService.isConfigured, !chatMode,
                  let spec, spec.isAnswerEngineQuestion,
                  spec.rawQuery == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            let q = spec.rawQuery
            if answeredQuery != q, !askChat.isAnswering {
                answeredQuery = q
                enterChat(with: q)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherEscape)) { _ in
            exitChat()
        }
        // Dashboard's "Ask anything…" (and its ⌘K) — straight into an empty
        // chat with the composer focused; first Enter starts the conversation.
        // Without an AI provider (or with the memory engine killed) the chat
        // can't answer, so degrade to plain focused search — the field must
        // still get focus, or ⌘K opens a panel with a dead input.
        .onReceive(NotificationCenter.default.publisher(for: .requestLauncherAsk)) { _ in
            if ContextLayer.enabled, aiService.isConfigured, !chatMode {
                chatMode = true
                LauncherChatSession.isActive = true
                askChat.reset()
                searchText = ""
                searchCoordinator.cancelSearch()
                searchCoordinator.clearAIState()
            }
            isSearchFocused = true
        }
        // Esc lands HERE when the text field is focused (the field editor
        // consumes the key before the panel's keyDown sees it) — same story
        // as Return/.onSubmit. The panel notification covers the rest.
        .onExitCommand {
            if chatMode { exitChat() }
        }
        .onChange(of: isSearchFocused) { _, focused in
            Task {
                let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if focused || !trimmedQuery.isEmpty {
                    await IndexScheduler.shared.pause()
                } else {
                    await IndexScheduler.shared.resume()
                }
            }
        }
        .onChange(of: activeFilter) {
            selectedIndex = 0
            refreshChatPreviews()
            // Clear AI state when switching filters
            searchCoordinator.cancelSearch()
            searchCoordinator.clearAIState()
            pipelineSubFilter = nil
        }
        .onChange(of: includeBotsInAISearch) {
            telegramService.scheduleBotMetadataWarm(
                for: telegramService.visibleChats,
                includeBots: includeBotsInAISearch
            )
            refreshChatPreviews()
            refreshBotFilteredUI()
        }
        .onChange(of: pipelineSubFilter) {
            refreshChatPreviews()
        }
        // Keyboard navigation from FloatingPanel
        .onReceive(NotificationCenter.default.publisher(for: .launcherArrowDown)) { _ in
            if !chatMode, selectedIndex < navigableCount - 1 {
                selectedIndex += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherArrowUp)) { _ in
            if !chatMode, selectedIndex > 0 {
                selectedIndex -= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherEnter)) { _ in
            handleEnter()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            if !chatMode {
                Image(systemName: "magnifyingglass")
                    .font(.custom("Inter", size: 17))
                    .foregroundStyle(Color.Pidgy.fg3)
            }

            TextField(
                chatMode
                    ? (askChat.thread.isEmpty ? "Ask anything…" : "Ask a follow-up… (esc to go back)")
                    : "Search or ask anything…",
                text: $searchText
            )
                .textFieldStyle(.plain)
                .font(.custom("Inter", size: 17))
                .focused($isSearchFocused)
                // Return lands HERE while the field is focused (the field
                // editor consumes the key before the panel's keyDown sees
                // it); the panel notification covers the unfocused case.
                // handleEnter dedupes if both ever fire.
                .onSubmit { handleEnter() }
                // Pulsating "I'm thinking" cue. Only dims the visible
                // text — typing is uninterrupted because the field
                // itself stays active. Never pulses in chat mode (the
                // thread has its own thinking indicator).
                .opacity(isAISearching && !chatMode ? inputPulseOpacity : 1.0)

            if !searchText.isEmpty || chatMode {
                Button {
                    if chatMode {
                        exitChat()
                    } else {
                        searchText = ""
                        searchCoordinator.clearAllState()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Font.Pidgy.bodySm)
                        .foregroundStyle(Color.Pidgy.fg3)
                }
                .buttonStyle(.plain)
            }

        }
        .padding(.horizontal, PidgySpace.s3)
        .padding(.vertical, 14)
        .background(Color.clear)
        .onChange(of: isAISearching) { _, isSearching in
            // Kick off / cancel the pulsing-input animation when the
            // engine starts or finishes searching. Use a smooth
            // ease-in-out that auto-reverses forever; resetting back
            // to 1.0 when idle uses a short fade so the field doesn't
            // pop awkwardly to full opacity mid-pulse.
            if isSearching {
                inputPulseOpacity = 1.0
                withAnimation(
                    .easeInOut(duration: 0.95).repeatForever(autoreverses: true)
                ) {
                    inputPulseOpacity = 0.55
                }
            } else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    inputPulseOpacity = 1.0
                }
            }
        }
    }

    // MARK: - Filter Tags

    private var filterTags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Filter.allCases, id: \.self) { filter in
                    Button {
                        activeFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.custom("Inter", size: 13).weight(activeFilter == filter ? .semibold : .regular))
                            .foregroundStyle(activeFilter == filter ? Color.Pidgy.fg1 : Color.Pidgy.fg3)
                            .padding(.horizontal, PidgySpace.s2)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }

                Divider().frame(height: 16).padding(.horizontal, 5)

                Menu {
                    Button("All sources") { activeSource = nil }
                    ForEach(availableSources) { source in
                        Button(source.displayName) { activeSource = source }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: activeSource?.systemImage ?? "square.stack.3d.up")
                        Text(activeSource?.displayName ?? "Sources")
                    }
                    .font(.custom("Inter", size: 12).weight(.medium))
                    .foregroundStyle(Color.Pidgy.fg2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.Pidgy.bg3, in: Capsule())
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, PidgySpace.s2)
            .padding(.vertical, 2)
        }
    }

    private var availableSources: [MessageSourceKind] {
        let connected = Set(registry.sources.map(\.kind))
        return MessageSourceKind.allCases.filter { connected.contains($0) }
    }

    // MARK: - AI Mode Banner

    /// Witty status messages that rotate while a search is in flight.
    /// Tone leans into Claude's playbook — short quirky verbs (mostly
    /// single-word, slightly archaic, never robot-speak) with a sprinkle
    /// of chat-context riffs so it's still on-brand for a Telegram
    /// CRM. Each list has 8-12 entries so a 30s search doesn't loop
    /// back to the same word awkwardly.
    private static let summaryWittyMessages: [String] = [
        "cogitating…",
        "marinating…",
        "rummaging through receipts…",
        "eavesdropping on past you…",
        "pondering…",
        "sleuthing…",
        "noodling…",
        "triangulating…",
        "spelunking the archive…",
        "putting on the detective hat…",
        "percolating…",
        "almost there…"
    ]
    private static let semanticWittyMessages: [String] = [
        "scanning the corpus…",
        "matching vibes…",
        "ranking the contenders…",
        "putting on the glasses…",
        "polishing matches…",
        "consulting the vectors…",
        "skimming…"
    ]
    private static let messageWittyMessages: [String] = [
        "hunting the exact phrase…",
        "scrolling back…",
        "checking the wording…",
        "double-tapping the receipts…"
    ]

    /// Rotating banner label. Pulls from the witty pool while searching,
    /// then snaps to the static "ready/done" label once results land.
    /// `now` is supplied by the TimelineView ticker so this re-renders
    /// every 0.1s — pick a new message every ~2.4s based on elapsed
    /// search time so the user sees the engine "thinking out loud".
    private func bannerStatusText(intent: QueryIntent, now: Foundation.Date) -> String {
        guard isAISearching, let startedAt = searchStartedAt else {
            return aiModeLabel(intent: intent)
        }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let pool: [String]
        switch intent {
        case .summarySearch:
            pool = Self.summaryWittyMessages
        case .semanticSearch:
            pool = Self.semanticWittyMessages
        case .messageSearch:
            pool = Self.messageWittyMessages
        case .unsupported:
            return aiModeLabel(intent: intent)
        }
        let rotationSeconds: Double = 2.4
        let index = Int(elapsed / rotationSeconds) % pool.count
        return pool[index]
    }

    private func aiModeBanner(intent: QueryIntent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(Font.Pidgy.meta)
                        .foregroundStyle(Color.Pidgy.accent)

                    Text(bannerStatusText(intent: intent, now: context.date))
                        .font(Font.Pidgy.meta)
                        .foregroundStyle(Color.Pidgy.fg2)
                        .animation(.easeInOut(duration: 0.25), value: bannerStatusText(intent: intent, now: context.date))

                    Spacer()

                    if let duration = searchDurationText(at: context.date) {
                        Text(duration)
                            .font(Font.Pidgy.monoSm)
                            .foregroundStyle(Color.Pidgy.fg2)
                    }
                }
            }

        }
        .padding(.horizontal, PidgySpace.s3)
        .padding(.vertical, 5)
    }

    private func searchDurationText(at now: Foundation.Date) -> String? {
        if isAISearching, let startedAt = searchStartedAt {
            return formatDuration(now.timeIntervalSince(startedAt))
        }
        if let lastSearchDuration {
            return formatDuration(lastSearchDuration)
        }
        return nil
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let clamped = max(0, duration)
        if clamped < 10 {
            return String(format: "%.1fs", clamped)
        }
        return String(format: "%.0fs", clamped)
    }

    /// Quiet footer under finished AI answers: a one-line invitation
    /// to flag a wrong answer, with the privacy promise spelled out
    /// right where the user reads it.
    private var flagAnswerFooter: some View {
        HStack(spacing: 6) {
            Spacer()
            Text("Answer wrong or unhelpful?")
                .font(Font.Pidgy.meta)
                .foregroundStyle(Color.Pidgy.fg2.opacity(0.7))
            Button(action: flagCurrentAnswer) {
                HStack(spacing: 4) {
                    Image(systemName: "flag")
                        .font(Font.Pidgy.meta)
                    Text("Flag this answer")
                        .font(Font.Pidgy.meta)
                }
                .foregroundStyle(Color.Pidgy.fg2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.Pidgy.bg4.opacity(0.55))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Opens Send Feedback prefilled with this query and answer — you review and edit everything before anything is sent. A copy is always saved locally.")
        }
        .padding(.horizontal, PidgySpace.s3)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// "Flag answer": always saves a local fixture (raw material for
    /// the eval-oracle refresh loop), then hands a fully-visible
    /// prefill to the dashboard feedback sheet — the user reviews and
    /// edits everything before any send. Nothing is shared silently;
    /// see FlaggedAnswerFixture for the privacy model.
    private func flagCurrentAnswer() {
        let fixture = FlaggedAnswerFixture(
            query: searchCoordinator.currentQuerySpec?.rawQuery ?? searchText,
            route: (aiSearchMode ?? searchCoordinator.routedQueryIntent)
                .map { String(describing: $0) } ?? "unknown",
            resultTitle: summaryOutput?.title,
            resultText: summaryOutput?.summaryText,
            supportingSnippets: aiResults.prefix(5).map(flaggedSnippet(for:))
        )
        fixture.submitToFeedbackSheetPresentingDashboard()
    }

    private func flaggedSnippet(for result: AISearchResult) -> String {
        switch result {
        case .semanticResult(let r):
            return "\(r.chatTitle): \(r.matchingMessages.first ?? r.reason)"
        case .patternResult(let r):
            return "\(r.chatTitle): \(r.snippet)"
        }
    }

    private func aiModeLabel(intent: QueryIntent) -> String {
        switch intent {
        case .semanticSearch:
            if isAISearching {
                if totalChatsToScan > 0 {
                    return "Searching \(totalChatsToScan) local chat matches..."
                }
                return "Searching local index..."
            } else if totalChatsToScan > 0 {
                return "Ranked \(semanticMatchedChats) chats from \(totalChatsToScan) local matches"
            } else {
                return "Searching local index..."
            }
        case .messageSearch:
            return isAISearching ? "Searching exact matches..." : "Exact lookup ready"
        case .summarySearch:
            return isAISearching ? "Preparing summary..." : "Summary ready"
        case .unsupported:
            return "Unsupported in MVP"
        }
    }

    private func loadingKeywords(for intent: QueryIntent) -> [String] {
        switch intent {
        case .semanticSearch:
            return [
                "searching local keywords",
                "matching semantic vectors",
                "merging local signals",
                "grouping by chat",
                "preparing top matches"
            ]
        case .messageSearch:
            return [
                "checking exact phrases",
                "verifying entities",
                "ranking sent messages"
            ]
        case .summarySearch:
            return [
                "retrieving relevant chats",
                "gathering recent context",
                "drafting summary"
            ]
        case .unsupported:
            return [
                "waiting"
            ]
        }
    }

    private func aiLoadingProgressText(for intent: QueryIntent) -> String? {
        guard totalChatsToScan > 0 else { return nil }
        switch intent {
        case .semanticSearch:
            return "Scanned \(semanticMatchedChats) of \(totalChatsToScan) chats"
        case .messageSearch:
            return nil
        case .summarySearch:
            return "Ranked \(totalChatsToScan) local chat matches"
        case .unsupported:
            return nil
        }
    }

    @ViewBuilder
    private var aiLoadingStateView: some View {
        let intent = aiSearchMode ?? .messageSearch
        AISearchLoadingView(
            message: aiModeLabel(intent: intent),
            keywords: loadingKeywords(for: intent),
            progressText: aiLoadingProgressText(for: intent)
        )
    }

    private func queryScope(for filter: Filter) -> QueryScope {
        switch filter {
        case .all: return .all
        case .dms: return .dms
        case .groups: return .groups
        }
    }

    private var queryRoutingDebugLines: [String] {
        guard let snapshot = routingSnapshot else { return [] }
        let querySpec = snapshot.spec
        var lines: [String] = [
            "family \(querySpec.family.rawValue) • engine \(querySpec.preferredEngine.rawValue)",
            "route \(snapshot.runtimeIntent.rawValue) • mode \(querySpec.mode.rawValue) • scope \(querySpec.scope.rawValue)",
            "replyConstraint \(querySpec.replyConstraint.rawValue) • confidence \(String(format: "%.2f", querySpec.parseConfidence))"
        ]

        if !querySpec.unsupportedFragments.isEmpty {
            lines.append("unsupported \(querySpec.unsupportedFragments.joined(separator: " • "))")
        }

        return lines
    }

    private var queryRoutingDebugSection: some View {
        let lines = queryRoutingDebugLines

        return VStack(alignment: .leading, spacing: 6) {
            Text("Routing")
                .font(Font.Pidgy.monoSm)
                .foregroundStyle(Color.Pidgy.fg2)

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Font.Pidgy.monoSm)
                    .foregroundStyle(Color.Pidgy.fg2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.Pidgy.bg3)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Results List

    @ViewBuilder
    private var resultsList: some View {
        VStack(spacing: 0) {
            if showLauncherDebugOverlays && !queryRoutingDebugLines.isEmpty {
                queryRoutingDebugSection
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }

            // Ask Pidgy has no manual affordance — a person-question
            // auto-opens the chat (see the resolvedQuerySpec onReceive).
            searchResultsBody
        }
    }

    // The AI/chat results.
    @ViewBuilder
    private var searchResultsBody: some View {
        if isAISearching {
            VStack(spacing: 0) {
                if !aiResults.isEmpty {
                    aiResultsList
                } else if aiSearchMode == .summarySearch, let summaryOutput {
                    summaryOnlyStateView(summaryOutput)
                } else {
                    aiLoadingStateView
                }
            }
        } else if let error = aiSearchError {
            ErrorStateView(message: error) {
                triggerSearch()
            }
        } else if let aiSearchMode, aiSearchMode != .unsupported, !aiResults.isEmpty {
            aiResultsList
            flagAnswerFooter
        } else if aiSearchMode == .summarySearch, let summaryOutput {
            summaryOnlyStateView(summaryOutput)
            flagAnswerFooter
        } else if aiSearchMode == .messageSearch && aiResults.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No exact matches found",
                subtitle: "Try a more specific phrase or identifier"
            )
        } else if aiSearchMode == .summarySearch && aiResults.isEmpty {
            EmptyStateView(
                icon: "text.book.closed",
                title: "No summary context found",
                subtitle: "Try a narrower person, topic, or time window"
            )
        } else if aiSearchMode == .semanticSearch && aiResults.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No relevant chats found",
                subtitle: "Try a different search query"
            )
        } else if telegramService.isLoading && telegramService.chats.isEmpty {
            LoadingStateView(message: "Loading chats...")
        } else {
            chatResultsList
        }
    }

    // MARK: - Chat Results List (standard mode)

    private var chatResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    // Pipeline sub-filter bar
                    pipelineSubFilterBar

                    // Hide the count while the search is still settling/running
                    // with nothing to show — "0 results" mid-flight reads as a
                    // verdict, not a status.
                    if !searchText.isEmpty && !(displayedChats.isEmpty && (isAISearching || searchSettling)) {
                        Text("\(displayedChats.count) result\(displayedChats.count == 1 ? "" : "s")")
                            .font(Font.Pidgy.monoSm)
                            .foregroundStyle(Color.Pidgy.fg3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.top, 2)
                    }

                    if displayedChats.isEmpty {
                        if pipelineSubFilter != nil {
                            EmptyStateView(
                                icon: "checkmark.circle",
                                title: "No \(pipelineSubFilter!.rawValue.lowercased()) chats",
                                subtitle: "All caught up!"
                            )
                        } else if !searchText.isEmpty {
                            // While the AI is still ranking OR the query just
                            // changed and the machinery is deciding (settling),
                            // "no local title matches" is NOT "no results" —
                            // show a loading state instead of flashing an
                            // empty one that the AI list then replaces.
                            if isAISearching || searchSettling {
                                aiLoadingStateView
                            } else {
                                EmptyStateView(
                                    icon: "magnifyingglass",
                                    title: "No results for \"\(searchText)\""
                                )
                            }
                        } else {
                            EmptyStateView(
                                icon: "tray",
                                title: "No \(activeFilter == .all ? "chats" : activeFilter.rawValue.lowercased()) found"
                            )
                        }
                    } else {
                        ForEach(Array(displayedChats.enumerated()), id: \.element.id) { index, chat in
                            ChatRowView(
                                chat: chat,
                                isHighlighted: index == selectedIndex,
                                pipelineStatus: pipelineCategory(for: chat.id),
                                pipelineSuggestion: pipelineSuggestion(for: chat.id),
                                messagePreview: messagePreview(for: chat),
                                onOpen: { openChat(chat) }
                            )
                            .id(chat.id)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                if newIndex < displayedChats.count {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(displayedChats[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - AI Results List

    private var aiResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    let totalCount = aiResults.count

                    Text("\(totalCount) result\(totalCount == 1 ? "" : "s")")
                        .font(Font.Pidgy.monoSm)
                        .foregroundStyle(Color.Pidgy.fg3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)

                    if aiSearchMode == .summarySearch, let summaryOutput {
                        summaryCardView(summaryOutput)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                    }

                    // AI semantic results
                    ForEach(Array(aiResults.enumerated()), id: \.element.id) { index, result in
                        aiResultRow(result: result, index: index)
                            .id(result.id)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                if newIndex < aiResults.count {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(aiResults[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - AI Result Row

    @ViewBuilder
    private func aiResultRow(result: AISearchResult, index: Int) -> some View {
        switch result {
        case .semanticResult(let result):
            semanticResultRow(result: result, index: index)
        case .patternResult(let result):
            patternResultRow(result: result, index: index)
        }
    }

    private func chatForSemanticResult(_ result: SemanticSearchResult) -> TGChat? {
        registry.chats.first(where: { $0.id == result.chatId })
    }

    private func resolvedChatTitle(chatId: Int64, preferredTitle: String, linkedChat: TGChat?) -> String {
        let trimmedPreferred = preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPreferred = trimmedPreferred.lowercased()
        if !trimmedPreferred.isEmpty && normalizedPreferred != "unknown" {
            return trimmedPreferred
        }
        if let linkedTitle = linkedChat?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !linkedTitle.isEmpty,
           linkedTitle.lowercased() != "unknown" {
            return linkedTitle
        }
        if let chatTitle = telegramService.chats.first(where: { $0.id == chatId })?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !chatTitle.isEmpty,
           chatTitle.lowercased() != "unknown" {
            return chatTitle
        }
        return trimmedPreferred.isEmpty ? "Chat \(chatId)" : trimmedPreferred
    }

    /// Example prompts for the empty Ask chat.
    ///
    /// The third one names a real person from THIS user's chats. It used to be
    /// hardcoded to a contact of the developer's, which every other install
    /// would have seen — a stranger's name as your example question. Deriving
    /// it also makes the example worth tapping: the answer is about someone
    /// the user actually talks to.
    ///
    /// Falls back to a person-free prompt when no DM qualifies yet (a fresh
    /// install mid-first-sync), so the row is never a dangling "with ".
    private var askChatExamples: [String] {
        var examples = ["What should I reply to first?", "Who owes me something right now?"]
        if let name = mostRecentDMFirstName {
            examples.append("what's the latest with \(name)")
        } else {
            examples.append("what did I miss this week?")
        }
        return examples
    }

    /// First name of the most recently active one-on-one chat. First name
    /// only — it reads like how the user would actually type the question,
    /// and full names in this corpus carry handles and emoji.
    private var mostRecentDMFirstName: String? {
        registry.visibleChats
            .filter { chat in
                guard case .privateChat = chat.chatType, chat.isInMainList else { return false }
                return !chat.title.trimmingCharacters(in: .whitespaces).isEmpty
            }
            .max { ($0.lastMessage?.date ?? .distantPast) < ($1.lastMessage?.date ?? .distantPast) }
            .flatMap { chat in
                chat.title
                    .split(separator: " ")
                    .first
                    .map(String.init)
                    .flatMap { first in
                        let cleaned = first.filter { $0.isLetter || $0.isNumber }
                        return cleaned.count >= 2 ? cleaned : nil
                    }
            }
    }

    /// Empty chat (opened via "Ask anything…"): tappable example prompts
    /// instead of a blank thread.
    private var askChatEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ASK PIDGY")
                .font(Font.Pidgy.monoSm)
                .foregroundStyle(Color.Pidgy.accent)
                .padding(.bottom, 2)
            ForEach(askChatExamples, id: \.self) { example in
                Button {
                    askChat.start(with: example, aiService: aiService)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right")
                            .font(Font.Pidgy.meta)
                            .foregroundStyle(Color.Pidgy.fg4)
                        Text(example)
                            .font(.custom("Inter", size: 13))
                            .foregroundStyle(Color.Pidgy.fg2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.white.opacity(0.03))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pidgyPress)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Open the Ask Pidgy chat with `question` as the first user bubble.
    /// The search field becomes the follow-up composer; search state clears.
    private func enterChat(with question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        chatMode = true
        LauncherChatSession.isActive = true
        searchText = ""
        searchSettleTask?.cancel()
        searchSettling = false
        searchCoordinator.cancelSearch()
        searchCoordinator.clearAIState()
        askChat.start(with: q, aiService: aiService)
    }

    /// Single Enter handler for both delivery paths — the TextField's
    /// .onSubmit (field focused) and the panel's keyDown notification
    /// (field not focused). Deduped in case a Return ever reaches both.
    private func handleEnter() {
        let now = Date()
        guard now.timeIntervalSince(lastEnterAt) > 0.15 else { return }
        lastEnterAt = now
        if chatMode {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty, !askChat.isAnswering else { return }
            searchText = ""
            askChat.send(q, aiService: aiService)
        } else if let aiSearchMode,
           aiSearchMode != .unsupported,
           selectedIndex < aiResults.count {
            openAISearchResult(aiResults[selectedIndex])
        } else if selectedIndex < displayedChats.count {
            openChat(displayedChats[selectedIndex])
        } else if ContextLayer.enabled, aiService.isConfigured,
                  !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Nothing to open (no results, or none selected) — Enter hands the
            // query to the chat instead of dying on an empty screen.
            enterChat(with: searchText)
        }
    }

    /// Esc / ✕: leave the chat and return to normal search.
    private func exitChat() {
        guard chatMode else { return }
        askChat.reset()
        chatMode = false
        LauncherChatSession.isActive = false
        answeredQuery = ""
        searchText = ""
        isSearchFocused = true
    }

    private func openChatById(_ chatId: Int64, preferredChat: TGChat?) {
        if let preferredChat {
            openChat(preferredChat)
            return
        }
        if let cached = telegramService.chats.first(where: { $0.id == chatId }) {
            openChat(cached)
            return
        }

        Task {
            if let fetched = try? await telegramService.getChat(id: chatId) {
                await MainActor.run { openChat(fetched) }
            }
        }
    }

    private func openAISearchResult(_ result: AISearchResult) {
        switch result {
        case .semanticResult(let semantic):
            openChatById(semantic.chatId, preferredChat: chatForSemanticResult(semantic))
        case .patternResult(let pattern):
            openChatById(pattern.message.chatId, preferredChat: pattern.chat)
        }
    }

    /// Look up a chat by ID and return its avatar with photo, or generate a fallback.
    @ViewBuilder
    private func avatarForChat(chat: TGChat?, fallbackTitle: String) -> some View {
        if let chat {
            AvatarView(
                initials: chat.initials,
                colorIndex: chat.colorIndex,
                size: 26,
                photo: photoManager.photos[chat.id]
            )
            .onAppear {
                requestPhoto(for: chat)
            }
            .onChange(of: chat.avatarURL) {
                requestPhoto(for: chat)
            }
        } else {
            // Fallback: generate initials from title
            let words = fallbackTitle.split(separator: " ")
            let initials: String = {
                if words.count >= 2 {
                    return "\(words[0].prefix(1))\(words[1].prefix(1))".uppercased()
                } else if let first = words.first {
                    return String(first.prefix(2)).uppercased()
                }
                return "?"
            }()
            AvatarView(initials: initials, colorIndex: abs(fallbackTitle.hashValue % 8), size: 26)
        }
    }

    private func requestPhoto(for chat: TGChat) {
        if let fileId = chat.smallPhotoFileId {
            photoManager.requestPhoto(chatId: chat.id, fileId: fileId, telegramService: telegramService)
        } else if let avatarURL = chat.avatarURL {
            photoManager.requestPhoto(chatId: chat.id, avatarURL: avatarURL)
        }
    }

    private func semanticResultRow(result: SemanticSearchResult, index: Int) -> some View {
        let linkedChat = chatForSemanticResult(result)
        let displayTitle = resolvedChatTitle(
            chatId: result.chatId,
            preferredTitle: result.chatTitle,
            linkedChat: linkedChat
        )

        return Button {
            openChatById(result.chatId, preferredChat: linkedChat)
        } label: {
            HStack(spacing: 8) {
                avatarForChat(chat: linkedChat, fallbackTitle: displayTitle)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(displayTitle)
                            .font(Font.Pidgy.bodyMd)
                            .foregroundStyle(Color.Pidgy.fg1)
                            .lineLimit(1)

                        Text(result.relevance.rawValue.uppercased())
                            .font(Font.Pidgy.eyebrow)
                            .foregroundStyle(result.relevance.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(result.relevance.color.opacity(0.12))
                            .clipShape(Capsule())

                        Spacer()
                    }

                    // Reason or first matching message as subtitle
                    if let firstExcerpt = result.matchingMessages.first {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.Pidgy.avPurple.opacity(0.3))
                                .frame(width: 2, height: 12)
                            Text(firstExcerpt)
                                .font(Font.Pidgy.bodySm)
                                .foregroundStyle(Color.Pidgy.fg2)
                                .lineLimit(1)
                        }
                    } else {
                        Text(result.reason)
                            .font(Font.Pidgy.bodySm)
                            .foregroundStyle(Color.Pidgy.fg2)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(index == selectedIndex ? Color.Pidgy.bg4 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func patternResultRow(result: PatternSearchResult, index: Int) -> some View {
        Button {
            openChatById(result.message.chatId, preferredChat: result.chat)
        } label: {
            HStack(spacing: 8) {
                avatarForChat(chat: result.chat, fallbackTitle: result.chatTitle)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(result.chatTitle)
                            .font(Font.Pidgy.bodyMd)
                            .foregroundStyle(Color.Pidgy.fg1)
                            .lineLimit(1)

                        Text(result.matchKind.label)
                            .font(Font.Pidgy.eyebrow)
                            .foregroundStyle(result.matchKind.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(result.matchKind.color.opacity(0.14))
                            .clipShape(Capsule())

                        if result.message.isOutgoing {
                            Text("YOU")
                                .font(Font.Pidgy.eyebrow)
                                .foregroundStyle(Color.Pidgy.success)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.Pidgy.success.opacity(0.14))
                                .clipShape(Capsule())
                        }

                        Spacer()

                        Text(DateFormatting.compactRelativeTime(from: result.message.date))
                            .font(Font.Pidgy.monoSm)
                            .foregroundStyle(Color.Pidgy.fg2)
                    }

                    Text(result.snippet)
                        .font(Font.Pidgy.bodySm)
                        .foregroundStyle(Color.Pidgy.fg2)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(index == selectedIndex ? Color.Pidgy.bg4 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func summaryCardView(_ output: SummarySearchOutput) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(output.title)
                .font(Font.Pidgy.bodyMd)
                .foregroundStyle(Color.Pidgy.fg1)

            // The AI returns per-chat sections as `**Chat name** — recap.`
            // separated by blank lines. Build one Text per paragraph so
            // `**bold**` parses to actual bold and so the spacing between
            // chats reads as visual breaks rather than wrapped prose.
            ForEach(summaryParagraphs(in: output.summaryText), id: \.self) { paragraph in
                Text(LocalizedStringKey(paragraph))
                    .font(Font.Pidgy.bodySm)
                    .foregroundStyle(Color.Pidgy.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.Pidgy.bg3)
        )
    }

    /// Splits the AI's summary into per-chat paragraphs so each renders as
    /// its own block (with proper bold-name parsing). Falls back to the raw
    /// string when there are no blank-line separators (older outputs or
    /// short fallbacks).
    private func summaryParagraphs(in text: String) -> [String] {
        let parts = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text] : parts
    }

    private func summaryOnlyStateView(_ output: SummarySearchOutput) -> some View {
        ScrollView {
            summaryCardView(output)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    // MARK: - Pipeline Sub-Filter

    private var pipelineSubFilterBar: some View {
        HStack(spacing: 6) {
            pipelineSubFilterButton(label: "All", filter: nil)
            pipelineSubFilterButton(label: "On Me", filter: .onMe, color: Color.Pidgy.warning)
            pipelineSubFilterButton(label: "On Them", filter: .onThem, color: Color.Pidgy.accent)
            pipelineSubFilterButton(label: "Quiet", filter: .quiet, color: Color.Pidgy.fg2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private func pipelineSubFilterButton(label: String, filter: FollowUpItem.Category?, color: Color = Color.Pidgy.fg1) -> some View {
        let isActive = pipelineSubFilter == filter
        let count: Int? = {
            guard let f = filter else { return nil }
            return followUpItems.filter { $0.category == f }.count
        }()

        return Button {
            pipelineSubFilter = filter
        } label: {
            HStack(spacing: 4) {
                if let c = count, c > 0 {
                    Text("\(c)")
                        .font(Font.Pidgy.mono)
                        .foregroundStyle(isActive ? Color.white : color)
                }
                Text(label)
                    .font(.custom("Inter", size: 13).weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color.white : Color.Pidgy.fg2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isActive ? color.opacity(0.8) : Color.Pidgy.bg4.opacity(0.55))
            )
            .overlay(
                Capsule()
                    .stroke(isActive ? Color.clear : Color.Pidgy.border2, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pipeline Data Logic

    private func refreshBotFilteredUI() {
        selectedIndex = 0
        loadFollowUps()

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            triggerSearch()
        }
    }

    private func loadFollowUps() {
        attentionStore.loadFollowUps(
            telegramService: telegramService,
            includeBots: includeBotsInAISearch
        )
    }

    // MARK: - Actions

    private func openChat(_ chat: TGChat) {
        Task { @MainActor in
            if chat.source.kind != .telegram {
                _ = await DeepLinkGenerator.openExternalChat(chat)
                NSApp.keyWindow?.orderOut(nil)
                return
            }
            ChatOpenState.shared.openingChatId = chat.id
            defer { ChatOpenState.shared.openingChatId = nil }
            Task {
                await IndexScheduler.shared.prioritize(chatId: chat.id)
                await RecentSyncCoordinator.shared.prioritize(chatId: chat.id)
            }
            let hints = await telegramService.getDeepLinkHints(for: chat)
            let opened = DeepLinkGenerator.openChat(
                chat,
                username: hints.username,
                phoneNumber: hints.phoneNumber
            )

            // If no deep-link strategy succeeds, at least open Telegram home.
            if !opened, let fallback = URL(string: "tg://resolve?domain=telegram") {
                _ = DeepLinkGenerator.openInTelegram(fallback)
            }

            NSApp.keyWindow?.orderOut(nil)
        }
    }

    /// Debounced search: waits 300ms, then classifies via QueryRouter.
    /// If AI intent detected → runs AI pipeline. Otherwise → local FTS first, TDLib fallback for unindexed chats only.
    private func triggerSearch() {
        searchCoordinator.triggerSearch(
            query: searchText,
            activeScope: queryScope(for: activeFilter),
            aiSearchSourceChats: aiSearchSourceChats,
            scopedAISearchSourceChats: scopedAISearchSourceChats,
            includeBotsInAISearch: includeBotsInAISearch,
            telegramService: telegramService,
            aiService: aiService
        )
    }

}
