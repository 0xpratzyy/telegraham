import SwiftUI
import Combine
import TDLibKit

struct LauncherView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService
    @ObservedObject var photoManager = ChatPhotoManager.shared
    @StateObject private var searchCoordinator = SearchCoordinator()
    @AppStorage(AppConstants.Preferences.includeBotsInAISearchKey) private var includeBotsInAISearch = false

    // Search & filter
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    // Filter tags
    enum Filter: String, CaseIterable {
        case all = "All"
        case dms = "DMs"
        case groups = "Groups"
    }

    @State private var activeFilter: Filter = .all

    // Keyboard navigation
    @State private var selectedIndex: Int = 0

    // Follow-ups state
    @State private var followUpItems: [FollowUpItem] = []
    @State private var isFollowUpsLoading = false
    @State private var pipelineProcessedCount = 0
    @State private var pipelineTotalCount = 0
    @State private var pipelineSubFilter: FollowUpItem.Category? = nil

    // Background pipeline refresh
    @State private var pipelineAutoLoaded = false
    @State private var backgroundRefreshTask: Task<Void, Never>?

    // Settings callback
    var onOpenSettings: () -> Void = {}

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
    private var agenticDebugInfo: AgenticDebugInfo? { searchCoordinator.agenticDebugInfo }
    private var summaryOutput: SummarySearchOutput? { searchCoordinator.summaryOutput }
    private var semanticMatchedChats: Int { searchCoordinator.semanticMatchedChats }
    private var totalChatsToScan: Int { searchCoordinator.totalChatsToScan }
    private var searchStartedAt: Foundation.Date? { searchCoordinator.searchStartedAt }
    private var lastSearchDuration: TimeInterval? { searchCoordinator.lastSearchDuration }
    private var agenticUsedLocalFallback: Bool {
        agenticDebugInfo?.stopReason.contains("using local fallback") == true
    }
    private var showLauncherDebugOverlays: Bool { false }

    private var displayedChats: [TGChat] {
        var chats: [TGChat]

        switch activeFilter {
        case .all:
            chats = telegramService.visibleChats
        case .groups:
            chats = telegramService.visibleChats.filter { $0.chatType.isGroup }
        case .dms:
            chats = telegramService.visibleChats.filter { $0.chatType.isPrivate }
        }

        // Apply pipeline sub-filter
        if let subFilter = pipelineSubFilter {
            let matchingIds = Set(followUpItems.filter { $0.category == subFilter }.map(\.chat.id))
            chats = chats.filter { matchingIds.contains($0.id) }
        }

        if !searchText.isEmpty {
            // Combine: chats matching by title OR by message content search
            chats = chats.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                || searchResultChatIds.contains($0.id)
            }
        }

        return chats
    }

    private var aiSearchSourceChats: [TGChat] {
        telegramService.visibleChats.filter { chat in
            includeBotsInAISearch || !telegramService.isLikelyBotChat(chat)
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
        followUpItems.first(where: { $0.chat.id == chatId })?.category
    }

    private func pipelineSuggestion(for chatId: Int64) -> String? {
        followUpItems.first(where: { $0.chat.id == chatId })?.suggestedAction
    }

    private func pipelineHintForSearch(chatId: Int64) async -> String {
        if let category = pipelineCategory(for: chatId) {
            switch category {
            case .onMe: return "on_me"
            case .onThem: return "on_them"
            case .quiet: return "quiet"
            }
        }
        if let cached = await MessageCacheService.shared.getPipelineCategory(chatId: chatId) {
            return cached.category
        }
        return "unknown"
    }

    private func pipelineCategoryString(_ category: FollowUpItem.Category) -> String {
        switch category {
        case .onMe: return "on_me"
        case .onThem: return "on_them"
        case .quiet: return "quiet"
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
                searchBar

                // AI mode banner
                if let mode = aiSearchMode, !searchText.isEmpty {
                    aiModeBanner(intent: mode)
                }

                filterTags

                Divider()

                resultsList
            } else {
                AuthView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
            Task { await IndexScheduler.shared.pause() }
        }
        .onDisappear {
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
            pipelineAutoLoaded = true
            loadFollowUps()
        }
        .onReceive(
            telegramService.$chats
                .dropFirst()  // Skip initial load (handled by .task above)
                .debounce(for: .seconds(10), scheduler: RunLoop.main)
        ) { _ in
            backgroundRefreshPipeline()
        }
        .onChange(of: searchText) {
            selectedIndex = 0
            let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                if trimmedQuery.isEmpty && !isSearchFocused {
                    await IndexScheduler.shared.resume()
                } else {
                    await IndexScheduler.shared.pause()
                }
            }
            triggerSearch()
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
            // Clear AI state when switching filters
            searchCoordinator.cancelSearch()
            searchCoordinator.clearAIState()
            pipelineSubFilter = nil
        }
        // Keyboard navigation from FloatingPanel
        .onReceive(NotificationCenter.default.publisher(for: .launcherArrowDown)) { _ in
            if selectedIndex < navigableCount - 1 {
                selectedIndex += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherArrowUp)) { _ in
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherEnter)) { _ in
            if let aiSearchMode,
               aiSearchMode != .unsupported,
               selectedIndex < aiResults.count {
                openAISearchResult(aiResults[selectedIndex])
            } else if selectedIndex < displayedChats.count {
                openChat(displayedChats[selectedIndex])
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)

            TextField("Search Telegram...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchCoordinator.clearAllState()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            // Connection status
            HStack(spacing: 4) {
                StatusDot(isConnected: telegramService.authState == .ready)
                if let user = telegramService.currentUser {
                    Text(user.firstName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.clear)
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
                            .font(.system(size: 11, weight: activeFilter == filter ? .semibold : .regular))
                            .foregroundStyle(activeFilter == filter ? .primary : .tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
    }

    // MARK: - AI Mode Banner

    private func aiModeBanner(intent: QueryIntent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)

                    Text(aiModeLabel(intent: intent))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let duration = searchDurationText(at: context.date) {
                        Text(duration)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if intent == .agenticSearch,
               let querySpec = currentQuerySpec {
                let chips = agenticConstraintChips(from: querySpec)
                    + (agenticUsedLocalFallback ? ["Local Fallback"] : [])
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
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
        case .agenticSearch:
            if isAISearching {
                if !aiResults.isEmpty {
                    if agenticUsedLocalFallback {
                        return "Showing \(aiResults.count) likely chats • degraded mode • still scanning \(semanticMatchedChats) of \(totalChatsToScan)"
                    }
                    return "Showing \(aiResults.count) confident chats • still scanning \(semanticMatchedChats) of \(totalChatsToScan)"
                }
                if totalChatsToScan > 0 {
                    if agenticUsedLocalFallback {
                        return "Using limited local fallback • scanning \(semanticMatchedChats) of \(totalChatsToScan)"
                    }
                    return "Scanning \(semanticMatchedChats) of \(totalChatsToScan), ranking intent..."
                }
                return "Ranking warm, reply-ready chats..."
            }
            if agenticUsedLocalFallback {
                return "Agentic fallback ranking"
            }
            if let querySpec = currentQuerySpec, !querySpec.unsupportedFragments.isEmpty {
                return "Agentic ranking (partial parse)"
            }
            return "Agentic ranking ready"
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
        case .agenticSearch:
            return [
                "detecting open loops",
                "checking on-me threads",
                "ranking warm leads",
                "validating date filters",
                "crafting next actions"
            ]
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
        case .agenticSearch, .semanticSearch:
            if intent == .agenticSearch, !aiResults.isEmpty {
                return "Scanned \(semanticMatchedChats) of \(totalChatsToScan) chats • showing \(aiResults.count) confident results"
            }
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

    private func agenticConstraintChips(from querySpec: QuerySpec) -> [String] {
        var chips: [String] = []
        if querySpec.scope != .all {
            chips.append(querySpec.scope.label)
        }
        if let timeRange = querySpec.timeRange {
            chips.append(timeRange.label)
        }
        if querySpec.replyConstraint == .pipelineOnMeOnly {
            chips.append("Pipeline: On Me")
        }
        if !querySpec.unsupportedFragments.isEmpty {
            chips.append("Partial Parse")
        }
        return chips
    }

    private func agenticEmptyStateContent() -> (title: String, subtitle: String) {
        guard let querySpec = currentQuerySpec else {
            return (
                title: "No warm, reply-ready chats found",
                subtitle: "Try a more specific intent query"
            )
        }

        let chips = agenticConstraintChips(from: querySpec)
        if !chips.isEmpty {
            let subtitle: String
            if !querySpec.unsupportedFragments.isEmpty {
                subtitle = "No chats matched \(chips.joined(separator: " • ")). Try simpler wording or widen constraints."
            } else {
                subtitle = "No chats matched \(chips.joined(separator: " • ")). Try widening scope or date range."
            }
            return (
                title: "No chats matched your constraints",
                subtitle: subtitle
            )
        }

        return (
            title: "No warm, reply-ready chats found",
            subtitle: "Try a more specific intent query"
        )
    }

    private func agenticDebugLines() -> [String] {
        guard let debug = agenticDebugInfo else { return [] }
        var lines: [String] = []
        if !debug.providerName.isEmpty {
            if debug.providerModel.isEmpty {
                lines.append("provider \(debug.providerName)")
            } else {
                lines.append("provider \(debug.providerName) • model \(debug.providerModel)")
            }
        }
        lines.append(contentsOf: [
            "scoped \(debug.scopedChats) • eligibleDMs \(debug.eligiblePrivateChats) • eligibleGroups \(debug.eligibleGroupChats)",
            "scanCap \(debug.maxScanChats) • cappedDMs \(debug.cappedPrivateChats) • cappedGroups \(debug.cappedGroupChats) • scanned \(debug.scannedChats)",
            "inRange \(debug.inRangeChats) • replyOwed \(debug.replyOwedChats) • queryMatch \(debug.matchedChats)",
            "matchedDMs \(debug.matchedPrivateChats) • matchedGroups \(debug.matchedGroupChats) • finalDMs \(debug.finalPrivateChats) • finalGroups \(debug.finalGroupChats)",
            "toAI \(debug.candidatesSentToAI) • aiReturned \(debug.aiReturned) • ranked \(debug.rankedBeforeValidation)",
            "dropped \(debug.droppedByValidation) • final \(debug.finalCount) • reason \(debug.stopReason)"
        ])
        return lines
    }

    private var agenticDebugBuckets: [AgenticDebugExclusionBucket] {
        guard let debug = agenticDebugInfo else { return [] }
        return debug.exclusionBuckets.sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.reason < rhs.reason
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
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var agenticDebugSection: some View {
        let debugLines = agenticDebugLines()
        let buckets = agenticDebugBuckets

        return VStack(alignment: .leading, spacing: 6) {
            Text("Debug")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            ForEach(Array(debugLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !buckets.isEmpty {
                Divider()
                    .overlay(Color.secondary.opacity(0.15))

                Text("Excluded")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                ForEach(buckets.prefix(6)) { bucket in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(bucket.reason) • \(bucket.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if !bucket.sampleChats.isEmpty {
                            Text(bucket.sampleChats.joined(separator: ", "))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var agenticEmptyStateView: some View {
        let content = agenticEmptyStateContent()
        let hasDebug = showLauncherDebugOverlays && (!agenticDebugLines().isEmpty || !agenticDebugBuckets.isEmpty)

        return VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text(content.title)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(content.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            if hasDebug {
                agenticDebugSection
                    .padding(.top, 4)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
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
            } else if aiSearchMode == .summarySearch, let summaryOutput {
                summaryOnlyStateView(summaryOutput)
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
            } else if aiSearchMode == .agenticSearch && aiResults.isEmpty {
                agenticEmptyStateView
            } else if telegramService.isLoading && telegramService.chats.isEmpty {
                LoadingStateView(message: "Loading chats...")
            } else {
                chatResultsList
            }
        }
    }

    // MARK: - Chat Results List (standard mode)

    private var chatResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    // Pipeline sub-filter bar
                    pipelineSubFilterBar

                    // Pipeline loading indicator
                    if isFollowUpsLoading {
                        HStack(spacing: 5) {
                            ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                            if pipelineTotalCount > 0 {
                                Text("Analyzing \(pipelineProcessedCount)/\(pipelineTotalCount) chats...")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("Loading pipeline...")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                    }

                    if !searchText.isEmpty {
                        Text("\(displayedChats.count) result\(displayedChats.count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
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
                            EmptyStateView(
                                icon: "magnifyingglass",
                                title: "No results for \"\(searchText)\""
                            )
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
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)

                    if aiSearchMode == .summarySearch, let summaryOutput {
                        summaryCardView(summaryOutput)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                    }

                    // AI semantic/agentic results
                    ForEach(Array(aiResults.enumerated()), id: \.element.id) { index, result in
                        if let sectionTitle = replyQueueSectionHeaderTitle(for: result, at: index) {
                            replyQueueSectionHeader(title: sectionTitle)
                        }
                        aiResultRow(result: result, index: index)
                            .id(result.id)
                    }

                    if showLauncherDebugOverlays,
                       aiSearchMode == .agenticSearch,
                       (!agenticDebugLines().isEmpty || !agenticDebugBuckets.isEmpty) {
                        agenticDebugSection
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 6)
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
        case .agenticResult(let result):
            agenticResultRow(result: result, index: index)
        case .patternResult(let result):
            patternResultRow(result: result, index: index)
        case .replyQueueResult(let result):
            replyQueueResultRow(result: result, index: index)
        }
    }

    private func replyQueueSectionHeaderTitle(for result: AISearchResult, at index: Int) -> String? {
        guard case .replyQueueResult(let replyResult) = result,
              replyResult.classification == .worthChecking else {
            return nil
        }
        guard index > 0 else { return "Worth checking" }
        guard case .replyQueueResult(let previousResult) = aiResults[index - 1] else {
            return "Worth checking"
        }
        return previousResult.classification == .worthChecking ? nil : "Worth checking"
    }

    private func replyQueueSectionHeader(title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func chatForSemanticResult(_ result: SemanticSearchResult) -> TGChat? {
        telegramService.chats.first(where: { $0.id == result.chatId })
    }

    private func chatForAgenticResult(_ result: AgenticSearchResult) -> TGChat? {
        telegramService.chats.first(where: { $0.id == result.chatId })
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
        case .agenticResult(let agentic):
            openChatById(agentic.chatId, preferredChat: chatForAgenticResult(agentic))
        case .patternResult(let pattern):
            openChatById(pattern.message.chatId, preferredChat: pattern.chat)
        case .replyQueueResult(let replyQueue):
            openChatById(replyQueue.chatId, preferredChat: telegramService.chats.first(where: { $0.id == replyQueue.chatId }))
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
                if let fileId = chat.smallPhotoFileId {
                    photoManager.requestPhoto(chatId: chat.id, fileId: fileId, telegramService: telegramService)
                }
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
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(result.relevance.rawValue.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                                .fill(Color.purple.opacity(0.3))
                                .frame(width: 2, height: 12)
                            Text(firstExcerpt)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(result.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(index == selectedIndex ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func agenticResultRow(result: AgenticSearchResult, index: Int) -> some View {
        let linkedChat = chatForAgenticResult(result)
        let displayTitle = resolvedChatTitle(
            chatId: result.chatId,
            preferredTitle: result.chatTitle,
            linkedChat: linkedChat
        )
        let subtitle = agenticSubtitleText(for: result)

        return Button {
            openChatById(result.chatId, preferredChat: linkedChat)
        } label: {
            HStack(spacing: 8) {
                avatarForChat(chat: linkedChat, fallbackTitle: displayTitle)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(displayTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(result.warmth.rawValue.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(result.warmth.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(result.warmth.color.opacity(0.14))
                            .clipShape(Capsule())

                        Text(result.replyability.label)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(result.replyability.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(result.replyability.color.opacity(0.14))
                            .clipShape(Capsule())

                        Spacer()

                        Text("\(result.score)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Text("→ \(subtitle)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(index == selectedIndex ? Color.accentColor.opacity(0.12) : Color.clear)
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
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(result.matchKind.label)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(result.matchKind.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(result.matchKind.color.opacity(0.14))
                            .clipShape(Capsule())

                        if result.message.isOutgoing {
                            Text("YOU")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.14))
                                .clipShape(Capsule())
                        }

                        Spacer()

                        Text(DateFormatting.compactRelativeTime(from: result.message.date))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Text(result.snippet)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(index == selectedIndex ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func replyQueueResultRow(result: ReplyQueueResult, index: Int) -> some View {
        let linkedChat = telegramService.chats.first(where: { $0.id == result.chatId })
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
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(result.urgency.warmth.rawValue.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(result.urgency.warmth.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(result.urgency.warmth.color.opacity(0.14))
                            .clipShape(Capsule())

                        Text(result.replyability.label)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(result.replyability.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(result.replyability.color.opacity(0.14))
                            .clipShape(Capsule())

                        Spacer()

                        Text(DateFormatting.compactRelativeTime(from: result.latestMessageDate))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Text("→ \(result.suggestedAction)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(index == selectedIndex ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func summaryCardView(_ output: SummarySearchOutput) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(output.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Text(output.summaryText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func summaryOnlyStateView(_ output: SummarySearchOutput) -> some View {
        ScrollView {
            summaryCardView(output)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    private func agenticSubtitleText(for result: AgenticSearchResult) -> String {
        let action = result.suggestedAction.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = result.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { return reason }

        let normalized = action.lowercased()
        let genericPhrases = [
            "reply to the latest inbound message",
            "move the thread forward",
            "no immediate reply owed"
        ]

        if genericPhrases.contains(where: { normalized.contains($0) }), !reason.isEmpty {
            return reason
        }
        return action
    }

    // MARK: - Pipeline Sub-Filter

    private var pipelineSubFilterBar: some View {
        HStack(spacing: 6) {
            pipelineSubFilterButton(label: "All", filter: nil)
            pipelineSubFilterButton(label: "On Me", filter: .onMe, color: .orange)
            pipelineSubFilterButton(label: "On Them", filter: .onThem, color: .blue)
            pipelineSubFilterButton(label: "Quiet", filter: .quiet, color: .gray)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private func pipelineSubFilterButton(label: String, filter: FollowUpItem.Category?, color: Color = .primary) -> some View {
        let isActive = pipelineSubFilter == filter
        let count: Int? = {
            guard let f = filter else { return nil }
            return followUpItems.filter { $0.category == f }.count
        }()

        return Button {
            pipelineSubFilter = filter
        } label: {
            HStack(spacing: 3) {
                if let c = count, c > 0 {
                    Text("\(c)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(isActive ? .white : color)
                }
                Text(label)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .white : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isActive ? color.opacity(0.8) : Color.secondary.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(isActive ? Color.clear : Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pipeline Data Logic

    /// Collect candidate chats for the pipeline (filtering only, no categorization).
    private func collectPipelineCandidates() -> [TGChat] {
        let now = Date()
        let maxAge = AppConstants.FollowUp.maxPipelineAgeSeconds

        return telegramService.visibleChats.filter { chat in
            guard chat.lastMessage != nil else { return false }
            guard !chat.chatType.isChannel else { return false }
            let age = now.timeIntervalSince(chat.lastMessage!.date)
            guard age <= maxAge else { return false }

            if chat.chatType.isGroup {
                if let count = chat.memberCount, count > AppConstants.FollowUp.maxGroupMembers { return false }
                if chat.unreadCount > AppConstants.FollowUp.maxGroupUnread { return false }
            }
            return true
        }
    }

    /// Rule-based fallback when AI is not configured.
    private func buildRuleBasedFallbackItems(from candidates: [TGChat]) -> [FollowUpItem] {
        guard let myUserId = telegramService.currentUser?.id else { return [] }
        let now = Date()

        return candidates.compactMap { chat -> FollowUpItem? in
            guard let lastMsg = chat.lastMessage else { return nil }
            let age = now.timeIntervalSince(lastMsg.date)

            let isFromMe: Bool
            if case .user(let uid) = lastMsg.senderId { isFromMe = uid == myUserId }
            else { isFromMe = false }

            if !isFromMe && chat.unreadCount > 0 {
                return FollowUpItem(chat: chat, category: .onMe, lastMessage: lastMsg, timeSinceLastActivity: age)
            } else if isFromMe && age > AppConstants.FollowUp.followUpThresholdSeconds {
                return FollowUpItem(chat: chat, category: .onThem, lastMessage: lastMsg, timeSinceLastActivity: age)
            } else if age > AppConstants.FollowUp.staleThresholdSeconds {
                return FollowUpItem(chat: chat, category: .quiet, lastMessage: lastMsg, timeSinceLastActivity: age)
            }
            return nil
        }
        .sorted { a, b in
            if abs(a.timeSinceLastActivity - b.timeSinceLastActivity) > 3600 {
                return a.timeSinceLastActivity < b.timeSinceLastActivity
            }
            let order: [FollowUpItem.Category] = [.onMe, .onThem, .quiet]
            return (order.firstIndex(of: a.category) ?? 2) < (order.firstIndex(of: b.category) ?? 2)
        }
    }

    /// AI-powered categorization for a single chat with bounded two-pass context expansion.
    /// Pass 1 uses the initial window. Pass 2 (optional) fetches more context once.
    private func categorizeSingleChat(
        chat: TGChat,
        myUserId: Int64
    ) async -> FollowUpItem? {
        guard let lastMsg = chat.lastMessage else { return nil }
        let age = Date().timeIntervalSince(lastMsg.date)
        let initialWindowSize = AppConstants.FollowUp.messagesPerChat
        let progressiveStep = AppConstants.FollowUp.progressiveFetchStep
        let maxMessages = AppConstants.FollowUp.maxMessagesForAIClassification
        let maxAIAttempts = 2
        let defaultNeedMoreMessages = 20
        let cache = MessageCacheService.shared

        var allMessages: [TGMessage] = []

        // Try message cache first
        if let cached = await cache.getMessages(chatId: chat.id) {
            allMessages = cached
        }

        // If cache empty or insufficient, fetch from Telegram
        if allMessages.count < initialWindowSize {
            do {
                let fetched = try await telegramService.getChatHistory(chatId: chat.id, limit: initialWindowSize)
                allMessages = fetched
                await cache.cacheMessages(chatId: chat.id, messages: fetched)
            } catch {
                if allMessages.isEmpty { return nil }
            }
        }

        allMessages.sort { $0.date > $1.date }

        var currentWindowSize = min(initialWindowSize, min(allMessages.count, maxMessages))
        guard currentWindowSize > 0 else { return nil }

        func expandWindow(toAtLeast targetSize: Int) async -> Bool {
            let target = min(maxMessages, targetSize)
            guard target > currentWindowSize else { return false }

            while allMessages.count < target {
                let remaining = target - allMessages.count
                let fetchLimit = min(max(progressiveStep, 1), remaining)
                guard fetchLimit > 0 else { break }

                let oldestId = allMessages.last?.id ?? 0
                guard oldestId != 0 else { break }

                do {
                    let moreMsgs = try await telegramService.getChatHistory(
                        chatId: chat.id,
                        fromMessageId: oldestId,
                        limit: fetchLimit
                    )
                    guard !moreMsgs.isEmpty else { break }
                    allMessages.append(contentsOf: moreMsgs)
                    allMessages.sort { $0.date > $1.date }
                    await cache.cacheMessages(chatId: chat.id, messages: moreMsgs, append: true)
                } catch {
                    break
                }
            }

            let updatedWindowSize = min(target, allMessages.count)
            guard updatedWindowSize > currentWindowSize else { return false }
            currentWindowSize = updatedWindowSize
            return true
        }

        var attempt = 0
        while attempt < maxAIAttempts {
            attempt += 1
            let messagesToSend = Array(allMessages.prefix(currentWindowSize))

            do {
                let myUser = telegramService.currentUser
                let triage = try await aiService.categorizePipelineChat(
                    chat: chat,
                    messages: messagesToSend,
                    myUserId: myUserId,
                    myUser: myUser
                )

                switch triage.status {
                case .needMore:
                    guard attempt == 1 else { break }
                    let requested = triage.additionalMessages ?? defaultNeedMoreMessages
                    let boundedAdditional = max(10, min(defaultNeedMoreMessages, requested))
                    let targetWindowSize = min(maxMessages, currentWindowSize + boundedAdditional)
                    let expanded = await expandWindow(toAtLeast: targetWindowSize)
                    guard expanded else { break }
                    continue

                case .decision:
                    let normalizedCategory = normalizePipelineCategory(
                        proposed: triage.category,
                        suggestedAction: triage.suggestedAction,
                        chat: chat,
                        messages: messagesToSend,
                        myUserId: myUserId
                    )
                    let finalSuggestion = triage.suggestedAction.trimmingCharacters(in: .whitespacesAndNewlines)

                    let needsConfidenceRetry = !triage.confident && attempt == 1 && currentWindowSize < maxMessages
                    if needsConfidenceRetry {
                        let targetWindowSize = min(maxMessages, currentWindowSize + defaultNeedMoreMessages)
                        let expanded = await expandWindow(toAtLeast: targetWindowSize)
                        guard expanded else { break }
                        continue
                    }

                    await cache.cachePipelineCategory(
                        chatId: chat.id,
                        category: pipelineCategoryString(normalizedCategory),
                        suggestedAction: finalSuggestion,
                        lastMessageId: lastMsg.id
                    )

                    return FollowUpItem(
                        chat: chat,
                        category: normalizedCategory,
                        lastMessage: lastMsg,
                        timeSinceLastActivity: age,
                        suggestedAction: finalSuggestion.isEmpty ? nil : finalSuggestion
                    )
                }
            } catch {
                break
            }
        }

        // Deterministic fallback so this chat never silently disappears.
        let fallbackWindow = Array(allMessages.prefix(currentWindowSize))
        let fallbackCategoryHint = ConversationReplyHeuristics.resolvePipelineCategory(
            for: chat,
            hint: "quiet",
            messages: fallbackWindow,
            myUserId: myUserId
        )
        let fallbackCategory: FollowUpItem.Category
        switch fallbackCategoryHint {
        case "on_me":
            fallbackCategory = .onMe
        case "on_them":
            fallbackCategory = .onThem
        default:
            fallbackCategory = .quiet
        }
        let fallbackSuggestion: String
        switch fallbackCategory {
        case .onMe:
            fallbackSuggestion = "Reply with a concrete next step."
        case .onThem:
            fallbackSuggestion = age > 24 * 3600 ? "Send a short nudge for an update." : "Wait for their update."
        case .quiet:
            fallbackSuggestion = ""
        }

        await cache.cachePipelineCategory(
            chatId: chat.id,
            category: pipelineCategoryString(fallbackCategory),
            suggestedAction: fallbackSuggestion,
            lastMessageId: lastMsg.id
        )

        return FollowUpItem(
            chat: chat,
            category: fallbackCategory,
            lastMessage: lastMsg,
            timeSinceLastActivity: age,
            suggestedAction: fallbackSuggestion.isEmpty ? nil : fallbackSuggestion
        )
    }

    private func loadFollowUps() {
        guard !isFollowUpsLoading else { return }  // Prevent concurrent loads
        let candidates = collectPipelineCandidates()

        // No AI? Fall back to rule-based categorization
        guard aiService.isConfigured else {
            followUpItems = buildRuleBasedFallbackItems(from: candidates)
            postOnMeBadge()
            return
        }

        Task {
            let myUserId = telegramService.currentUser?.id ?? 0
            let cache = MessageCacheService.shared

            // ── PASS 1: Load from pipeline category cache (instant) ──
            var cachedItems: [FollowUpItem] = []
            var staleChats: [TGChat] = []

            for chat in candidates {
                guard let lastMsg = chat.lastMessage else { continue }

                if let cached = await cache.getPipelineCategory(chatId: chat.id),
                   cached.lastMessageId == lastMsg.id {
                    // Cache hit
                    let cachedCategory: FollowUpItem.Category
                    switch cached.category {
                    case "on_me": cachedCategory = .onMe
                    case "on_them": cachedCategory = .onThem
                    default: cachedCategory = .quiet
                    }

                    let recentMessages = (await cache.getMessages(chatId: chat.id)) ?? []
                    let normalizedCategory = normalizePipelineCategory(
                        proposed: cachedCategory,
                        suggestedAction: cached.suggestedAction,
                        chat: chat,
                        messages: recentMessages,
                        myUserId: myUserId
                    )
                    if normalizedCategory != cachedCategory {
                        await cache.cachePipelineCategory(
                            chatId: chat.id,
                            category: pipelineCategoryString(normalizedCategory),
                            suggestedAction: cached.suggestedAction,
                            lastMessageId: lastMsg.id
                        )
                    }

                    let age = Date().timeIntervalSince(lastMsg.date)
                    cachedItems.append(FollowUpItem(
                        chat: chat,
                        category: normalizedCategory,
                        lastMessage: lastMsg,
                        timeSinceLastActivity: age,
                        suggestedAction: cached.suggestedAction.isEmpty ? nil : cached.suggestedAction
                    ))
                } else {
                    staleChats.append(chat)
                }
            }

            // Show cached items immediately (no flash of empty state)
            await MainActor.run {
                followUpItems = cachedItems
                sortPipelineItems()
            }

            // If nothing stale, we're done — no loading indicator needed
            guard !staleChats.isEmpty else {
                await MainActor.run { isFollowUpsLoading = false }
                return
            }

            // ── PASS 2: AI-analyze ONLY stale chats ──
            await MainActor.run {
                pipelineProcessedCount = 0
                pipelineTotalCount = staleChats.count
                isFollowUpsLoading = true
            }

            let maxConcurrency = AppConstants.FollowUp.maxAIConcurrency

            await withTaskGroup(of: FollowUpItem?.self) { group in
                var queued = 0

                for chat in staleChats {
                    if queued >= maxConcurrency {
                        if let result = await group.next() {
                            await MainActor.run {
                                pipelineProcessedCount += 1
                                if let item = result {
                                    followUpItems.removeAll { $0.chat.id == item.chat.id }
                                    followUpItems.append(item)
                                    sortPipelineItems()
                                }
                            }
                        }
                        queued -= 1
                    }

                    group.addTask { [self] in
                        await self.categorizeSingleChat(chat: chat, myUserId: myUserId)
                    }
                    queued += 1
                }

                for await result in group {
                    await MainActor.run {
                        pipelineProcessedCount += 1
                        if let item = result {
                            followUpItems.removeAll { $0.chat.id == item.chat.id }
                            followUpItems.append(item)
                            sortPipelineItems()
                        }
                    }
                }
            }

            await MainActor.run { isFollowUpsLoading = false }
        }
    }

    private func sortPipelineItems() {
        followUpItems.sort { a, b in
            let order: [FollowUpItem.Category] = [.onMe, .onThem, .quiet]
            let aIdx = order.firstIndex(of: a.category) ?? 2
            let bIdx = order.firstIndex(of: b.category) ?? 2
            if aIdx != bIdx { return aIdx < bIdx }
            return a.timeSinceLastActivity < b.timeSinceLastActivity
        }
        postOnMeBadge()
    }

    /// Update menu bar badge with "On Me" count
    private func postOnMeBadge() {
        let count = followUpItems.filter { $0.category == .onMe }.count
        NotificationCenter.default.post(
            name: .onMeCountChanged,
            object: nil,
            userInfo: ["count": count]
        )
    }

    // MARK: - Background Pipeline Refresh

    /// Incrementally re-analyze only pipeline chats whose lastMessage changed since last categorization.
    private func backgroundRefreshPipeline() {
        // Guard: need existing items, AI configured, not doing a full load
        guard !followUpItems.isEmpty, aiService.isConfigured, !isFollowUpsLoading else { return }

        // Cancel any previous background refresh in flight
        backgroundRefreshTask?.cancel()

        backgroundRefreshTask = Task {
            let myUserId = telegramService.currentUser?.id ?? 0

            // Find chats with new messages since last categorization
            var staleChats: [TGChat] = []
            for item in followUpItems {
                guard let currentChat = telegramService.visibleChats.first(where: { $0.id == item.chat.id }),
                      let currentLastMsg = currentChat.lastMessage else { continue }
                if currentLastMsg.id != item.lastMessage.id {
                    staleChats.append(currentChat)
                }
            }

            // Also detect new pipeline candidates not yet in followUpItems
            let existingIds = Set(followUpItems.map(\.chat.id))
            let newCandidates = collectPipelineCandidates().filter { !existingIds.contains($0.id) }

            guard !staleChats.isEmpty || !newCandidates.isEmpty else { return }

            // Re-analyze stale chats one at a time (gentle on API)
            for chat in staleChats {
                guard !Task.isCancelled else { return }
                if let updatedItem = await categorizeSingleChat(chat: chat, myUserId: myUserId) {
                    await MainActor.run {
                        followUpItems.removeAll { $0.chat.id == chat.id }
                        followUpItems.append(updatedItem)
                        sortPipelineItems()
                    }
                }
            }

            // Categorize new candidates
            for chat in newCandidates {
                guard !Task.isCancelled else { return }
                if let newItem = await categorizeSingleChat(chat: chat, myUserId: myUserId) {
                    await MainActor.run {
                        followUpItems.append(newItem)
                        sortPipelineItems()
                    }
                }
            }

            // Prune chats no longer eligible for pipeline
            let candidateIds = Set(collectPipelineCandidates().map(\.id))
            let hasStale = followUpItems.contains { !candidateIds.contains($0.chat.id) }
            if hasStale {
                await MainActor.run {
                    followUpItems.removeAll { !candidateIds.contains($0.chat.id) }
                    sortPipelineItems()
                }
            }

        }
    }

    // MARK: - Actions

    private func openChat(_ chat: TGChat) {
        Task { @MainActor in
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
            visibleChats: telegramService.visibleChats,
            aiSearchSourceChats: aiSearchSourceChats,
            scopedAISearchSourceChats: scopedAISearchSourceChats,
            includeBotsInAISearch: includeBotsInAISearch,
            telegramService: telegramService,
            aiService: aiService,
            pipelineCategoryProvider: { chatId in
                pipelineCategory(for: chatId)
            },
            pipelineHintProvider: { chatId in
                await pipelineHintForSearch(chatId: chatId)
            }
        )
    }

    private func normalizePipelineCategory(
        proposed: FollowUpItem.Category,
        suggestedAction: String?,
        chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64
    ) -> FollowUpItem.Category {
        ConversationReplyHeuristics.normalizePipelineCategory(
            proposed: proposed,
            suggestedAction: suggestedAction,
            chat: chat,
            messages: messages,
            myUserId: myUserId
        )
    }
}
