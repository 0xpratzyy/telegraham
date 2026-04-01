import SwiftUI
import Combine
import TDLibKit

struct LauncherView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService
    @ObservedObject var photoManager = ChatPhotoManager.shared
    private let queryInterpreter: QueryInterpreting = QueryInterpreter()
    @AppStorage(AppConstants.Preferences.includeBotsInAISearchKey) private var includeBotsInAISearch = false

    // Search & filter
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    // Message search results (from TDLib)
    @State private var searchResultChatIds: Set<Int64> = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    // AI search state
    @State private var aiResults: [AISearchResult] = []
    @State private var aiSearchMode: QueryIntent? = nil
    @State private var isAISearching = false
    @State private var aiSearchError: String?
    @State private var currentQuerySpec: QuerySpec?
    @State private var agenticDebugInfo: AgenticDebugInfo?

    // Semantic search lazy loading
    @State private var semanticBatchOffset: Int = 0
    @State private var hasMoreSemanticBatches: Bool = true
    @State private var isLoadingMoreSemantic: Bool = false
    @State private var currentSemanticQuery: String = ""
    @State private var totalChatsToScan: Int = 0

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

    enum AISearchResult: Identifiable {
        case semanticResult(SemanticSearchResult)
        case agenticResult(AgenticSearchResult)

        var id: String {
            switch self {
            case .semanticResult(let result): return "sem-\(result.id)"
            case .agenticResult(let result): return "ag-\(result.id)"
            }
        }

        /// The chat that should be opened when this result is tapped (if any).
        func linkedChat(in chats: [TGChat]) -> TGChat? {
            switch self {
            case .semanticResult(let result):
                return chats.first(where: { $0.id == result.chatId })
            case .agenticResult(let result):
                return chats.first(where: { $0.id == result.chatId })
            }
        }
    }

    struct AgenticDebugInfo {
        var scopedChats: Int
        var maxScanChats: Int
        var providerName: String = ""
        var providerModel: String = ""
        var scannedChats: Int = 0
        var inRangeChats: Int = 0
        var replyOwedChats: Int = 0
        var matchedChats: Int = 0
        var candidatesSentToAI: Int = 0
        var aiReturned: Int = 0
        var rankedBeforeValidation: Int = 0
        var droppedByValidation: Int = 0
        var finalCount: Int = 0
        var stopReason: String = "unknown"
    }

    // MARK: - Computed

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

    // MARK: - Pipeline Helpers

    private func pipelineCategory(for chatId: Int64) -> FollowUpItem.Category? {
        followUpItems.first(where: { $0.chat.id == chatId })?.category
    }

    private func pipelineSuggestion(for chatId: Int64) -> String? {
        followUpItems.first(where: { $0.chat.id == chatId })?.suggestedAction
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
        if aiSearchMode == .semanticSearch && (!aiResults.isEmpty || hasMoreSemanticBatches) {
            return titleMatchedChats.count + aiResults.count
        }
        if aiSearchMode == .agenticSearch && !aiResults.isEmpty {
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
            triggerSearch()
        }
        .onChange(of: activeFilter) {
            selectedIndex = 0
            // Clear AI state when switching filters
            aiSearchMode = nil
            aiResults = []
            aiSearchError = nil
            currentQuerySpec = nil
            agenticDebugInfo = nil
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
            if aiSearchMode == .semanticSearch && (!aiResults.isEmpty || !titleMatchedChats.isEmpty) {
                // AI mode: title matches first, then AI results
                let titleMatches = titleMatchedChats
                if selectedIndex < titleMatches.count {
                    openChat(titleMatches[selectedIndex])
                } else {
                    let aiIndex = selectedIndex - titleMatches.count
                    if aiIndex < aiResults.count {
                        openAISearchResult(aiResults[aiIndex])
                    }
                }
            } else if aiSearchMode == .agenticSearch && selectedIndex < aiResults.count {
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
                    searchResultChatIds = []
                    aiResults = []
                    aiSearchMode = nil
                    aiSearchError = nil
                    currentQuerySpec = nil
                    agenticDebugInfo = nil
                    semanticBatchOffset = 0
                    hasMoreSemanticBatches = true
                    isLoadingMoreSemantic = false
                    currentSemanticQuery = ""
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
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                Text(aiModeLabel(intent: intent))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if intent == .agenticSearch,
               let querySpec = currentQuerySpec {
                let chips = agenticConstraintChips(from: querySpec)
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

    private func aiModeLabel(intent: QueryIntent) -> String {
        switch intent {
        case .semanticSearch:
            if isAISearching {
                return "Scanning chats..."
            } else if hasMoreSemanticBatches && totalChatsToScan > 0 {
                return "Scanned \(semanticBatchOffset) of \(totalChatsToScan) chats"
            } else if totalChatsToScan > 0 {
                return "Scanned all \(totalChatsToScan) chats"
            } else {
                return "Finding chats about this topic..."
            }
        case .agenticSearch:
            if isAISearching {
                if totalChatsToScan > 0 {
                    return "Scanning \(semanticBatchOffset) of \(totalChatsToScan), ranking intent..."
                }
                return "Ranking warm, reply-ready chats..."
            }
            if let querySpec = currentQuerySpec, !querySpec.unsupportedFragments.isEmpty {
                return "Agentic ranking (partial parse)"
            }
            return "Agentic ranking ready"
        case .messageSearch:
            return "Searching messages..."
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
                "reading chat context",
                "matching query intent",
                "scoring relevance",
                "deduplicating results",
                "preparing top matches"
            ]
        case .messageSearch:
            return [
                "searching messages"
            ]
        }
    }

    private func aiLoadingProgressText(for intent: QueryIntent) -> String? {
        guard totalChatsToScan > 0 else { return nil }
        switch intent {
        case .agenticSearch, .semanticSearch:
            return "Scanned \(semanticBatchOffset) of \(totalChatsToScan) chats"
        case .messageSearch:
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
            "scoped \(debug.scopedChats) • scanCap \(debug.maxScanChats) • scanned \(debug.scannedChats)",
            "inRange \(debug.inRangeChats) • replyOwed \(debug.replyOwedChats) • queryMatch \(debug.matchedChats)",
            "toAI \(debug.candidatesSentToAI) • aiReturned \(debug.aiReturned) • ranked \(debug.rankedBeforeValidation)",
            "dropped \(debug.droppedByValidation) • final \(debug.finalCount) • reason \(debug.stopReason)"
        ])
        return lines
    }

    private var agenticEmptyStateView: some View {
        let content = agenticEmptyStateContent()
        let debugLines = agenticDebugLines()

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

            if !debugLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ForEach(Array(debugLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 4)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Results List

    @ViewBuilder
    private var resultsList: some View {
        if isAISearching {
            aiLoadingStateView
        } else if let error = aiSearchError {
            ErrorStateView(message: error) {
                triggerSearch()
            }
        } else if aiSearchMode == .semanticSearch && (!aiResults.isEmpty || hasMoreSemanticBatches) {
            aiResultsList
        } else if aiSearchMode == .agenticSearch && !aiResults.isEmpty {
            aiResultsList
        } else if aiSearchMode == .semanticSearch && aiResults.isEmpty && !hasMoreSemanticBatches {
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

    /// Chats whose title matches the search text (shown above AI results for direct matches).
    private var titleMatchedChats: [TGChat] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        // Exclude chats already in AI results to avoid duplicates.
        let aiChatIds = Set(aiResults.compactMap { result -> Int64? in
            if case .semanticResult(let r) = result { return r.chatId }
            return nil
        })
        return aiSearchSourceChats.filter {
            $0.title.lowercased().contains(query) && !aiChatIds.contains($0.id)
        }
    }

    private var aiResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    let titleMatches = aiSearchMode == .semanticSearch ? titleMatchedChats : []
                    let totalCount = titleMatches.count + aiResults.count

                    Text("\(totalCount) result\(totalCount == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)

                    if aiSearchMode == .semanticSearch {
                        // Direct title matches first
                        ForEach(Array(titleMatches.enumerated()), id: \.element.id) { index, chat in
                            ChatRowView(
                                chat: chat,
                                isHighlighted: index == selectedIndex,
                                onOpen: { openChat(chat) }
                            )
                            .id(chat.id)
                        }
                    }

                    // AI semantic/agentic results
                    ForEach(Array(aiResults.enumerated()), id: \.element.id) { index, result in
                        aiResultRow(result: result, index: titleMatches.count + index)
                            .id(result.id)
                    }

                    // Lazy loading sentinel for semantic search
                    if hasMoreSemanticBatches && aiSearchMode == .semanticSearch {
                        HStack(spacing: 6) {
                            if isLoadingMoreSemantic {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            }
                            Text(isLoadingMoreSemantic ? "Scanning more chats..." : "Loading more...")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear { loadNextSemanticBatch() }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                if aiSearchMode == .semanticSearch {
                    let titleMatches = titleMatchedChats
                    if newIndex < titleMatches.count {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(titleMatches[newIndex].id, anchor: .center)
                        }
                    } else {
                        let aiIndex = newIndex - titleMatches.count
                        if aiIndex < aiResults.count {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(aiResults[aiIndex].id, anchor: .center)
                            }
                        }
                    }
                } else {
                    if newIndex < aiResults.count {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(aiResults[newIndex].id, anchor: .center)
                        }
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
        }
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
        let fallbackCategoryHint = resolvePipelineCategory(
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
        searchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchResultChatIds = []
            aiResults = []
            aiSearchMode = nil
            isSearching = false
            isAISearching = false
            aiSearchError = nil
            currentQuerySpec = nil
            agenticDebugInfo = nil
            semanticBatchOffset = 0
            hasMoreSemanticBatches = true
            isLoadingMoreSemantic = false
            currentSemanticQuery = ""
            totalChatsToScan = 0
            return
        }

        searchTask = Task {
            // Debounce: wait 300ms
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            // Step 1: Classify intent via QueryRouter
            let activeScope = queryScope(for: activeFilter)
            let parsedSpec = queryInterpreter.parse(
                query: query,
                now: Date(),
                timezone: .current,
                activeFilter: activeScope
            )
            let intent = await aiService.queryRouter.route(
                query: query,
                querySpec: parsedSpec,
                activeFilter: activeScope,
                timezone: .current,
                now: Date()
            )
            guard !Task.isCancelled else { return }

            if intent != .messageSearch && aiService.isConfigured {
                // AI mode: run the AI pipeline
                await MainActor.run {
                    aiSearchMode = intent
                    isAISearching = true
                    aiSearchError = nil
                    currentQuerySpec = parsedSpec
                    agenticDebugInfo = nil
                    searchResultChatIds = []
                }

                do {
                    let results = try await executeAISearch(intent: intent, querySpec: parsedSpec)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        aiResults = results
                        isAISearching = false
                        selectedIndex = 0
                        // If first batch returned empty but more chats exist, auto-load next batch
                        if intent == .semanticSearch && results.isEmpty && hasMoreSemanticBatches {
                            loadNextSemanticBatch()
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        aiSearchError = error.localizedDescription
                        isAISearching = false
                    }
                }
            } else {
                // Keyword mode: SQLite FTS first, TDLib fallback only for chats with no local index yet
                await MainActor.run {
                    aiSearchMode = nil
                    aiResults = []
                    currentQuerySpec = nil
                    agenticDebugInfo = nil
                    isSearching = true
                }

                do {
                    let scopedChats: [TGChat]
                    switch activeFilter {
                    case .all:
                        scopedChats = telegramService.visibleChats
                    case .dms:
                        scopedChats = telegramService.visibleChats.filter { $0.chatType.isPrivate }
                    case .groups:
                        scopedChats = telegramService.visibleChats.filter { $0.chatType.isGroup }
                    }

                    let scopedChatIds = Set(scopedChats.map(\.id))
                    let localMessages = await telegramService.localSearch(
                        query: query,
                        chatIds: scopedChats.map(\.id),
                        limit: 50
                    )
                    let unindexedChatIds = await DatabaseManager.shared.unindexedChatIds(in: scopedChats.map(\.id))

                    var mergedMessages = Dictionary(
                        uniqueKeysWithValues: localMessages.map { message in
                            ("\(message.chatId):\(message.id)", message)
                        }
                    )

                    if !unindexedChatIds.isEmpty {
                        let chatTypeFilter: SearchMessagesChatTypeFilter?
                        switch activeFilter {
                        case .all:
                            chatTypeFilter = nil
                        case .dms:
                            chatTypeFilter = .searchMessagesChatTypeFilterPrivate
                        case .groups:
                            chatTypeFilter = .searchMessagesChatTypeFilterGroup
                        }

                        let fallbackMessages = try await telegramService.searchMessages(
                            query: query,
                            limit: 50,
                            chatTypeFilter: chatTypeFilter
                        )

                        for message in fallbackMessages
                        where scopedChatIds.contains(message.chatId) && unindexedChatIds.contains(message.chatId) {
                            mergedMessages["\(message.chatId):\(message.id)"] = message
                        }
                    }

                    guard !Task.isCancelled else { return }
                    let chatIds = Set(mergedMessages.values.map(\.chatId))
                    await MainActor.run {
                        searchResultChatIds = chatIds
                        isSearching = false
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { isSearching = false }
                }
            }
        }
    }

    // MARK: - AI Search Execution

    private func executeAISearch(intent: QueryIntent, querySpec: QuerySpec?) async throws -> [AISearchResult] {
        switch intent {
        case .semanticSearch:
            await MainActor.run { agenticDebugInfo = nil }
            let concurrentBatches = 3
            let batchSize = 10
            let allChats = aiSearchSourceChats
            let query = searchText
            guard !allChats.isEmpty else { return [] }

            await MainActor.run { totalChatsToScan = allChats.count }

            var allResults: [AISearchResult] = []

            await withTaskGroup(of: [SemanticSearchResult].self) { group in
                for i in 0..<concurrentBatches {
                    let start = i * batchSize
                    let batchChats = Array(allChats.dropFirst(start).prefix(batchSize))
                    guard !batchChats.isEmpty else { continue }

                    group.addTask { [telegramService, aiService] in
                        do {
                            let messages = try await telegramService.getRecentMessagesAcrossChats(
                                chatIds: batchChats.map(\.id), perChatLimit: 15
                            )
                            return try await aiService.semanticSearch(query: query, messages: messages)
                        } catch {
                            return []
                        }
                    }
                }

                for await batchResults in group {
                    allResults.append(contentsOf: batchResults.map { .semanticResult($0) })
                }
            }

            let totalScanned = min(concurrentBatches * batchSize, allChats.count)
            let deduplicated = deduplicateResults(allResults)
            await MainActor.run {
                semanticBatchOffset = totalScanned
                hasMoreSemanticBatches = allChats.count > totalScanned
                currentSemanticQuery = query
            }
            return deduplicated

        case .agenticSearch:
            return try await executeAgenticSearch(query: searchText, querySpec: querySpec)

        case .messageSearch:
            return [] // Handled by keyword path
        }
    }

    private func executeAgenticSearch(query: String, querySpec: QuerySpec?) async throws -> [AISearchResult] {
        let constants = AppConstants.AI.AgenticSearch.self
        let resolvedQuerySpec = querySpec ?? queryInterpreter.parse(
            query: query,
            now: Date(),
            timezone: .current,
            activeFilter: queryScope(for: activeFilter)
        )
        let rawScopedChats = await collectAgenticCandidateChats(scope: resolvedQuerySpec.scope)
        let allChats = prioritizeAgenticChats(rawScopedChats, query: query)
        let maxScanChats = min(allChats.count, constants.maxAdaptiveScanChats)
        var debug = AgenticDebugInfo(
            scopedChats: allChats.count,
            maxScanChats: maxScanChats,
            providerName: aiService.providerType.rawValue,
            providerModel: aiService.providerModel
        )
        guard !allChats.isEmpty else {
            debug.stopReason = "no chats after scope/type prefilters"
            await MainActor.run { agenticDebugInfo = debug }
            return []
        }

        let chatById = Dictionary(uniqueKeysWithValues: allChats.map { ($0.id, $0) })
        let myUserId = telegramService.currentUser?.id ?? 0

        await MainActor.run {
            totalChatsToScan = maxScanChats
            hasMoreSemanticBatches = false
            isLoadingMoreSemantic = false
            semanticBatchOffset = 0
            currentSemanticQuery = query
            currentQuerySpec = resolvedQuerySpec
        }

        var candidateByChatId: [Int64: AgenticSearchCandidate] = [:]
        var latestRanked: [AgenticSearchResult] = []
        var scanOffset = 0
        var round = 0
        var previousTopIds: [Int64] = []
        var stableRounds = 0
        var providerFailed = false

        while scanOffset < maxScanChats && round < constants.maxAdaptiveRounds {
            let scanThisRound = round == 0 ? constants.initialScanChats : constants.adaptiveExpansionStep
            let remaining = maxScanChats - scanOffset
            let takeCount = min(scanThisRound, remaining)
            guard takeCount > 0 else { break }

            let roundChats = Array(allChats.dropFirst(scanOffset).prefix(takeCount))
            scanOffset += roundChats.count
            guard !roundChats.isEmpty else { break }

            for chat in roundChats {
                debug.scannedChats += 1
                let rawMessages = await cachedFirstMessages(
                    for: chat,
                    desiredCount: constants.initialMessagesPerChat,
                    timeRange: resolvedQuerySpec.timeRange
                )
                let messages = applyTimeRange(rawMessages, timeRange: resolvedQuerySpec.timeRange)
                guard !messages.isEmpty else { continue }
                debug.inRangeChats += 1

                let pipelineHint = await pipelineCategoryHint(for: chat.id)
                let effectivePipelineCategory = resolvePipelineCategory(
                    for: chat,
                    hint: pipelineHint,
                    messages: messages,
                    myUserId: myUserId
                )
                let replyOwed = isReplyOwed(
                    for: chat,
                    messages: messages,
                    myUserId: myUserId
                )
                if replyOwed {
                    debug.replyOwedChats += 1
                }

                guard chatLikelyMatchesAgenticQuery(
                    chat: chat,
                    messages: messages,
                    query: query,
                    pipelineHint: effectivePipelineCategory,
                    replyOwed: replyOwed,
                    querySpec: resolvedQuerySpec
                ) else { continue }
                debug.matchedChats += 1

                candidateByChatId[chat.id] = AgenticSearchCandidate(
                    chat: chat,
                    pipelineCategory: replyOwed ? "on_me" : effectivePipelineCategory,
                    messages: messages
                )
            }

            await MainActor.run { semanticBatchOffset = scanOffset }

            let candidates = allChats
                .compactMap { candidateByChatId[$0.id] }
                .prefix(constants.maxCandidateChats)
                .map { $0 }
            debug.candidatesSentToAI = max(debug.candidatesSentToAI, candidates.count)

            if candidates.isEmpty {
                round += 1
                continue
            }

            let ranked: [AgenticSearchResult]
            do {
                ranked = try await aiService.agenticSearch(
                    query: query,
                    querySpec: resolvedQuerySpec,
                    candidates: candidates,
                    myUserId: myUserId
                )
            } catch {
                providerFailed = true
                let reason = compactAIErrorReason(error)
                debug.stopReason = reason.isEmpty
                    ? "agentic provider call failed"
                    : "agentic provider call failed: \(reason)"

                let fallbackRanked = heuristicAgenticFallbackRanking(
                    query: query,
                    querySpec: resolvedQuerySpec,
                    candidates: candidates,
                    myUserId: myUserId
                )
                latestRanked = fallbackRanked
                debug.aiReturned = max(debug.aiReturned, fallbackRanked.count)
                if !fallbackRanked.isEmpty {
                    debug.stopReason += " • using local fallback"
                }
                break
            }

            latestRanked = ranked
            debug.aiReturned = max(debug.aiReturned, ranked.count)
            let topIds = Array(ranked.prefix(5).map(\.chatId))
            let topCount = min(5, ranked.count)
            let avgTopConfidence: Double
            if topCount > 0 {
                avgTopConfidence = ranked.prefix(topCount).map(\.confidence).reduce(0, +) / Double(topCount)
            } else {
                avgTopConfidence = 0
            }

            if !topIds.isEmpty {
                if topIds == previousTopIds {
                    stableRounds += 1
                } else {
                    stableRounds = 0
                    previousTopIds = topIds
                }
            }

            let foundEnoughCandidates = candidates.count >= constants.maxCandidateChats
            let confidenceGood = avgTopConfidence >= constants.confidentTopAverageThreshold && ranked.count >= 5
            if confidenceGood || stableRounds >= 1 || (foundEnoughCandidates && round > 0) {
                break
            }

            round += 1
        }

        guard !latestRanked.isEmpty else {
            if debug.candidatesSentToAI == 0 {
                debug.stopReason = "no candidates reached AI reranker"
            } else {
                debug.stopReason = "AI reranker returned empty list"
            }
            await MainActor.run { agenticDebugInfo = debug }
            return []
        }
        var rankedByChatId = Dictionary(uniqueKeysWithValues: latestRanked.map { ($0.chatId, $0) })

        // Low-confidence top-up (+4 older messages, max 12, top 2 chats).
        let lowConfidence = latestRanked
            .filter { $0.confidence < constants.lowConfidenceThreshold }
            .prefix(constants.maxLowConfidenceTopUps)

        if !providerFailed, !lowConfidence.isEmpty {
            var topUpCandidates: [AgenticSearchCandidate] = []
            for result in lowConfidence {
                guard let chat = chatById[result.chatId] else { continue }
                let baseMessages = await cachedFirstMessages(
                    for: chat,
                    desiredCount: constants.initialMessagesPerChat,
                    timeRange: resolvedQuerySpec.timeRange
                )
                let filteredBase = applyTimeRange(baseMessages, timeRange: resolvedQuerySpec.timeRange)
                guard !filteredBase.isEmpty else { continue }
                let pipelineHint = await pipelineCategoryHint(for: chat.id)
                let effectivePipelineCategory = resolvePipelineCategory(
                    for: chat,
                    hint: pipelineHint,
                    messages: filteredBase,
                    myUserId: myUserId
                )
                let replyOwed = isReplyOwed(
                    for: chat,
                    messages: filteredBase,
                    myUserId: myUserId
                )

                let expanded = await topUpOlderMessages(
                    for: chat,
                    existingMessages: filteredBase,
                    additionalCount: constants.topUpAdditionalMessages,
                    maxTotal: constants.maxMessagesPerChat,
                    timeRange: resolvedQuerySpec.timeRange
                )
                let filteredExpanded = applyTimeRange(expanded, timeRange: resolvedQuerySpec.timeRange)
                guard filteredExpanded.count > filteredBase.count else { continue }

                let topUpCandidate = AgenticSearchCandidate(
                    chat: chat,
                    pipelineCategory: replyOwed ? "on_me" : effectivePipelineCategory,
                    messages: filteredExpanded
                )
                candidateByChatId[chat.id] = topUpCandidate
                topUpCandidates.append(topUpCandidate)
            }

            if !topUpCandidates.isEmpty,
               let refined = try? await aiService.agenticSearch(
                    query: query,
                    querySpec: resolvedQuerySpec,
                    candidates: topUpCandidates,
                    myUserId: myUserId
               ) {
                debug.aiReturned = max(debug.aiReturned, refined.count)
                for item in refined {
                    rankedByChatId[item.chatId] = item
                }
            }
        }

        let rankedBeforeValidation = rankedByChatId.values
            .sorted { $0.score > $1.score }
        debug.rankedBeforeValidation = rankedBeforeValidation.count

        let validatedRanked = rankedBeforeValidation
            .filter { result in
                satisfiesHardConstraints(
                    result: result,
                    candidateByChatId: candidateByChatId,
                    querySpec: resolvedQuerySpec
                )
            }
        debug.droppedByValidation = max(0, rankedBeforeValidation.count - validatedRanked.count)

        let finalRanked = validatedRanked
            .prefix(constants.maxCandidateChats)
            .map { $0 }
        debug.finalCount = finalRanked.count

        if finalRanked.isEmpty {
            if debug.rankedBeforeValidation > 0 {
                debug.stopReason = "all ranked results failed hard constraints"
            } else {
                debug.stopReason = "no ranked results before validation"
            }
            await MainActor.run { agenticDebugInfo = debug }
            return []
        }

        debug.stopReason = "ok"
        await MainActor.run { agenticDebugInfo = debug }
        return finalRanked.map { .agenticResult($0) }
    }

    private func prioritizeAgenticChats(_ chats: [TGChat], query: String) -> [TGChat] {
        let normalizedQuery = query.lowercased()
        let tokens = normalizedQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
        let now = Date()

        return chats.sorted { a, b in
            func score(_ chat: TGChat) -> Int {
                let title = chat.title.lowercased()
                let preview = chat.lastMessage?.displayText.lowercased() ?? ""
                var total = 0

                if title.contains(normalizedQuery) { total += 30 }
                for token in tokens {
                    if title.contains(token) { total += 8 }
                    if preview.contains(token) { total += 5 }
                }

                if let status = pipelineCategory(for: chat.id) {
                    switch status {
                    case .onMe: total += 12
                    case .onThem: total += 4
                    case .quiet: break
                    }
                }

                if chat.unreadCount > 0 { total += 6 }

                if let lastDate = chat.lastMessage?.date {
                    let age = now.timeIntervalSince(lastDate)
                    if age <= 86_400 { total += 8 }         // 24h
                    else if age <= 259_200 { total += 4 }   // 3d
                }

                return total
            }

            let left = score(a)
            let right = score(b)
            if left != right { return left > right }
            return a.order > b.order
        }
    }

    private func chatLikelyMatchesAgenticQuery(
        chat: TGChat,
        messages: [TGMessage],
        query: String,
        pipelineHint: String,
        replyOwed: Bool,
        querySpec: QuerySpec
    ) -> Bool {
        if querySpec.replyConstraint == .pipelineOnMeOnly && pipelineHint == "on_me" {
            return true
        }

        let normalizedQuery = query.lowercased()
        let stopWords: Set<String> = [
            "who", "what", "when", "where", "why", "how", "have", "has", "had",
            "with", "that", "this", "from", "your", "you", "for", "the", "and",
            "are", "was", "were", "can", "could", "would", "should", "about"
        ]
        let tokens = normalizedQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }

        let corpus = (
            [chat.title.lowercased(), chat.lastMessage?.displayText.lowercased() ?? ""]
            + messages.prefix(8).map { $0.displayText.lowercased() }
        ).joined(separator: " ")

        let tokenMatches = tokens.filter { corpus.contains($0) }.count
        if tokenMatches >= max(1, min(2, tokens.count)) {
            return true
        }

        let isReplyIntent =
            normalizedQuery.contains("reply")
            || normalizedQuery.contains("respond")
            || normalizedQuery.contains("follow up")
            || normalizedQuery.contains("follow-up")
            || normalizedQuery.contains("waiting on me")
            || normalizedQuery.contains("who do i")
            || normalizedQuery.contains("who should i")
            || normalizedQuery.contains("have to reply")

        if isReplyIntent {
            if pipelineHint == "on_me" {
                return true
            }
            if replyOwed { return true }
        }

        if normalizedQuery.contains("intro") || normalizedQuery.contains("connect") {
            if corpus.contains("intro") || corpus.contains("connect") {
                return true
            }
        }

        return false
    }

    private func applyTimeRange(_ messages: [TGMessage], timeRange: TimeRangeConstraint?) -> [TGMessage] {
        guard let timeRange else { return messages }
        return messages.filter { timeRange.contains($0.date) }
    }

    private func chatMatchesScope(_ chat: TGChat, scope: QueryScope) -> Bool {
        switch scope {
        case .all:
            return chat.chatType.isPrivate || chat.chatType.isGroup
        case .dms:
            return chat.chatType.isPrivate
        case .groups:
            return chat.chatType.isGroup
        }
    }

    private func satisfiesHardConstraints(
        result: AgenticSearchResult,
        candidateByChatId: [Int64: AgenticSearchCandidate],
        querySpec: QuerySpec
    ) -> Bool {
        guard let candidate = candidateByChatId[result.chatId] else { return false }

        if !chatMatchesScope(candidate.chat, scope: querySpec.scope) {
            return false
        }

        if querySpec.replyConstraint == .pipelineOnMeOnly {
            let satisfiesPipeline = candidate.pipelineCategory == "on_me"
            let satisfiesReplySignal = result.replyability == .replyNow
            if !satisfiesPipeline && !satisfiesReplySignal {
                return false
            }
        }

        if let timeRange = querySpec.timeRange,
           !candidate.messages.contains(where: { timeRange.contains($0.date) }) {
            return false
        }

        return true
    }

    private func collectAgenticCandidateChats(scope: QueryScope) async -> [TGChat] {
        let now = Date()
        let maxAge = AppConstants.FollowUp.maxPipelineAgeSeconds

        let scoped = aiSearchSourceChats.filter { chat in
            guard let lastMessage = chat.lastMessage else { return false }
            guard !chat.chatType.isChannel else { return false }
            switch scope {
            case .all:
                guard chat.chatType.isPrivate || chat.chatType.isGroup else { return false }
            case .dms:
                guard chat.chatType.isPrivate else { return false }
            case .groups:
                guard chat.chatType.isGroup else { return false }
            }

            let age = now.timeIntervalSince(lastMessage.date)
            guard age <= maxAge else { return false }

            if chat.chatType.isGroup {
                if let count = chat.memberCount, count > AppConstants.FollowUp.maxGroupMembers { return false }
                if chat.unreadCount > AppConstants.FollowUp.maxGroupUnread { return false }
            }
            return true
        }

        guard !includeBotsInAISearch else { return scoped }

        var filtered: [TGChat] = []
        filtered.reserveCapacity(scoped.count)
        for chat in scoped {
            if await telegramService.isBotChat(chat) {
                continue
            }
            filtered.append(chat)
        }
        return filtered
    }

    private func pipelineCategoryHint(for chatId: Int64) async -> String {
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

    private func resolvePipelineCategory(
        for chat: TGChat,
        hint: String,
        messages: [TGMessage],
        myUserId: Int64
    ) -> String {
        let normalizedHint = hint.lowercased()
        let hasReplySignal = hasPendingReplySignal(
            chat: chat,
            messages: messages,
            myUserId: myUserId
        )
        if hasReplySignal { return "on_me" }

        let latestTextMessage = messages
            .filter { ($0.textContent?.isEmpty == false) }
            .sorted { $0.date > $1.date }
            .first

        guard let latestTextMessage else {
            if normalizedHint == "on_them" || normalizedHint == "quiet" {
                return normalizedHint
            }
            return chat.unreadCount > 0 ? "on_me" : "quiet"
        }

        let latestFromMe = messageIsFromMe(latestTextMessage, myUserId: myUserId)

        if latestFromMe {
            return "on_them"
        }

        if normalizedHint == "on_them" || normalizedHint == "quiet" {
            return normalizedHint
        }

        return "quiet"
    }

    private func isReplyOwed(
        for chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64
    ) -> Bool {
        hasPendingReplySignal(chat: chat, messages: messages, myUserId: myUserId)
    }

    private func hasPendingReplySignal(
        chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64
    ) -> Bool {
        let sorted = messages.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return chat.unreadCount > 0 }

        let lastIndexFromMe = sorted.lastIndex(where: { messageIsFromMe($0, myUserId: myUserId) })
        let inboundTail: [TGMessage]
        if let index = lastIndexFromMe {
            inboundTail = Array(sorted[(index + 1)...].filter { !messageIsFromMe($0, myUserId: myUserId) })
        } else {
            inboundTail = sorted.filter { !messageIsFromMe($0, myUserId: myUserId) }
        }

        guard !inboundTail.isEmpty else { return false }
        if inboundTail.contains(where: inboundMessageLikelyNeedsReply) {
            return true
        }

        // If the sampled window has no outbound message from me, avoid assuming pending by default.
        // This prevents false "on_me" tags when the window only captured inbound acknowledgements.
        if lastIndexFromMe == nil {
            return chat.unreadCount > 0 && inboundTail.count >= 2
        }

        // Weak unread signal: only trust it when multiple inbound messages stacked up.
        if chat.unreadCount > 0 && inboundTail.count >= 2 {
            return true
        }

        return false
    }

    private func messageIsFromMe(_ message: TGMessage, myUserId: Int64) -> Bool {
        if case .user(let senderId) = message.senderId {
            return senderId == myUserId
        }
        return false
    }

    private func normalizePipelineCategory(
        proposed: FollowUpItem.Category,
        suggestedAction: String?,
        chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64
    ) -> FollowUpItem.Category {
        guard myUserId > 0 else { return proposed }

        let textMessages = messages.filter { ($0.textContent?.isEmpty == false) }
        guard !textMessages.isEmpty else { return proposed }

        if hasPendingReplySignal(chat: chat, messages: textMessages, myUserId: myUserId) {
            return .onMe
        }

        let latestText = textMessages.sorted { $0.date > $1.date }.first
        guard let latestText else { return proposed }

        if messageIsFromMe(latestText, myUserId: myUserId) {
            return .onThem
        }

        let compact = normalizedSignalText(latestText.textContent)
        if inboundMessageImpliesContactOwnsNextStep(compact) {
            return .onThem
        }

        if let suggestion = suggestedAction?.lowercased(),
           suggestion.contains("wait for") || suggestion.contains("waiting on") {
            return .onThem
        }

        if proposed == .onThem || proposed == .quiet {
            return proposed
        }

        return .quiet
    }

    private func normalizedSignalText(_ rawText: String?) -> String {
        guard let rawText else { return "" }
        return rawText
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-z0-9\\s?]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inboundMessageImpliesContactOwnsNextStep(_ compact: String) -> Bool {
        guard !compact.isEmpty else { return false }

        let exactSignals: Set<String> = [
            "on it", "will do", "i will", "i ll", "working on it",
            "let me do it", "let me check", "will share", "will send",
            "done", "completed"
        ]
        if exactSignals.contains(compact) {
            return true
        }

        let phraseSignals = [
            "on it", "will do", "i will", "i ll", "working on",
            "let me", "will share", "will send", "sending", "share soon"
        ]
        return phraseSignals.contains(where: { compact.contains($0) })
    }

    private func inboundMessageLikelyNeedsReply(_ message: TGMessage) -> Bool {
        let compact = normalizedSignalText(message.textContent)
        guard !compact.isEmpty else { return false }

        if compact.contains("?") { return true }

        let requestSignals = [
            "please", "pls", "can you", "could you", "let me know", "update",
            "when", "where", "why", "what", "how", "share", "send",
            "review", "check", "approve", "eta", "follow up", "follow-up", "reply"
        ]
        if requestSignals.contains(where: { compact.contains($0) }) {
            return true
        }

        let acknowledgementSignals: Set<String> = [
            "ok", "okay", "kk", "k", "cool", "great", "done", "noted", "got it",
            "thanks", "thank you", "sure", "hmm", "hmmm", "hmmmm", "haha", "lol",
            "on it", "will do", "dekh rhe", "dekh rahe", "dekh rha", "dekh rahi"
        ]
        if acknowledgementSignals.contains(compact) {
            return false
        }

        let wordCount = compact.split(separator: " ").count
        if wordCount <= 3 && compact.count <= 24 {
            return false
        }

        return compact.count >= 28
    }

    private func compactAIErrorReason(_ error: Swift.Error) -> String {
        let raw: String

        if let aiError = error as? AIError {
            switch aiError {
            case .httpError(let code, let body):
                let compactBody = body
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = compactBody.isEmpty ? "" : " \(String(compactBody.prefix(140)))"
                raw = "HTTP \(code)\(suffix)"
            case .parsingError(let detail):
                raw = "parse error \(String(detail.prefix(140)))"
            case .networkError(let err):
                raw = "network \(String(err.localizedDescription.prefix(120)))"
            case .noAPIKey:
                raw = "no API key configured"
            case .providerNotConfigured:
                raw = "provider not configured"
            case .invalidResponse:
                raw = "invalid provider response"
            }
        } else {
            let localized = error.localizedDescription
            if !localized.isEmpty {
                raw = localized
            } else {
                raw = String(describing: error)
            }
        }

        return raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func heuristicAgenticFallbackRanking(
        query: String,
        querySpec: QuerySpec,
        candidates: [AgenticSearchCandidate],
        myUserId: Int64
    ) -> [AgenticSearchResult] {
        let now = Date()
        let stopWords: Set<String> = [
            "who", "what", "when", "where", "why", "how", "have", "has", "had",
            "with", "that", "this", "from", "your", "you", "for", "the", "and",
            "are", "was", "were", "can", "could", "would", "should", "about",
            "only", "last", "week", "month", "reply", "replied", "responded"
        ]
        let queryTokens = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }

        return candidates.compactMap { candidate in
            guard chatMatchesScope(candidate.chat, scope: querySpec.scope) else { return nil }

            let rangedMessages = applyTimeRange(candidate.messages, timeRange: querySpec.timeRange)
            guard !rangedMessages.isEmpty else { return nil }

            let replyOwed = isReplyOwed(for: candidate.chat, messages: rangedMessages, myUserId: myUserId)
            if querySpec.replyConstraint == .pipelineOnMeOnly,
               !replyOwed,
               candidate.pipelineCategory != "on_me" {
                return nil
            }

            let newestFirst = rangedMessages.sorted { $0.date > $1.date }
            let inboundMessages = newestFirst.filter { message in
                if case .user(let senderId) = message.senderId {
                    return senderId != myUserId
                }
                return true
            }
            let outboundMessages = newestFirst.filter { message in
                if case .user(let senderId) = message.senderId {
                    return senderId == myUserId
                }
                return false
            }
            let latestInboundText = inboundMessages.first(where: { ($0.textContent?.isEmpty == false) })
            let latestOutboundText = outboundMessages.first(where: { ($0.textContent?.isEmpty == false) })

            let messageTexts = rangedMessages.compactMap(\.textContent)
            let corpus = ([candidate.chat.title.lowercased()] + messageTexts.map { $0.lowercased() })
                .joined(separator: " ")
            let matchedTokens = queryTokens.filter { corpus.contains($0) }
            let tokenHits = matchedTokens.count

            var score = 24
            if replyOwed { score += 20 }
            if candidate.chat.unreadCount > 0 { score += 4 }
            switch candidate.pipelineCategory {
            case "on_me":
                score += 9
            case "on_them":
                score += 3
            default:
                break
            }
            score += min(18, tokenHits * 6)

            if let latestInboundDate = inboundMessages.map(\.date).max() {
                let age = now.timeIntervalSince(latestInboundDate)
                if age <= 86_400 {
                    score += 12
                } else if age <= 3 * 86_400 {
                    score += 8
                } else if age <= 7 * 86_400 {
                    score += 4
                }
            }

            let boundedScore = max(1, min(99, score))
            let warmth: AgenticSearchResult.Warmth
            if boundedScore >= 74 {
                warmth = .hot
            } else if boundedScore >= 54 {
                warmth = .warm
            } else {
                warmth = .cold
            }

            let replyability: AgenticSearchResult.Replyability
            if replyOwed {
                replyability = .replyNow
            } else if latestOutboundText != nil {
                replyability = .waitingOnThem
            } else {
                replyability = .unclear
            }

            let inboundSender = latestInboundText?.senderName?
                .split(separator: " ")
                .first
                .map(String.init) ?? "them"
            let inboundSnippet = compactFallbackSnippet(latestInboundText?.textContent)
            let outboundSnippet = compactFallbackSnippet(latestOutboundText?.textContent)

            let suggestedAction: String
            switch replyability {
            case .replyNow:
                if !inboundSnippet.isEmpty {
                    suggestedAction = "Reply to \(inboundSender) on \"\(inboundSnippet)\" with a concrete next step."
                } else {
                    suggestedAction = "Send a quick reply and lock in the next step."
                }
            case .waitingOnThem:
                if !outboundSnippet.isEmpty, let latestOutboundText {
                    suggestedAction = "You already replied (\(latestOutboundText.relativeDate)); nudge only if \"\(outboundSnippet)\" is urgent."
                } else {
                    suggestedAction = "No immediate reply owed; keep this warm and nudge only if it is priority."
                }
            case .unclear:
                if tokenHits > 0 {
                    suggestedAction = "Re-open this thread with a short context check tied to your query."
                } else {
                    suggestedAction = "Review the latest context before deciding whether to engage."
                }
            }

            let reason: String
            if replyability == .replyNow, let latestInboundText {
                if tokenHits > 0 {
                    reason = "Inbound \(latestInboundText.relativeDate) ago and matched \(tokenHits) query term\(tokenHits == 1 ? "" : "s")."
                } else {
                    reason = "Inbound \(latestInboundText.relativeDate) ago suggests this thread is waiting on you."
                }
            } else if tokenHits > 0, let topToken = matchedTokens.first {
                reason = "Recent context matches \"\(topToken)\" but reply urgency is lower."
            } else if let latestOutboundText {
                reason = "Last outbound was \(latestOutboundText.relativeDate); waiting on their response."
            } else {
                reason = "Thread is relevant but currently lacks a clear open loop."
            }

            let tokenMatchedIds = newestFirst.compactMap { message -> Int64? in
                guard let text = message.textContent?.lowercased() else { return nil }
                return queryTokens.contains(where: { text.contains($0) }) ? message.id : nil
            }

            var supportingMessageIds: [Int64] = []
            if let inboundId = latestInboundText?.id {
                supportingMessageIds.append(inboundId)
            }
            if let outboundId = latestOutboundText?.id, !supportingMessageIds.contains(outboundId) {
                supportingMessageIds.append(outboundId)
            }
            for id in tokenMatchedIds where !supportingMessageIds.contains(id) {
                supportingMessageIds.append(id)
                if supportingMessageIds.count >= 2 { break }
            }
            if supportingMessageIds.isEmpty {
                supportingMessageIds = newestFirst.prefix(2).map(\.id)
            } else {
                supportingMessageIds = Array(supportingMessageIds.prefix(2))
            }

            let confidence = min(
                0.74,
                0.46 + (replyOwed ? 0.10 : 0) + min(0.12, Double(tokenHits) * 0.04)
            )

            return AgenticSearchResult(
                chatId: candidate.chat.id,
                chatTitle: candidate.chat.title,
                score: boundedScore,
                warmth: warmth,
                replyability: replyability,
                reason: reason,
                suggestedAction: suggestedAction,
                confidence: confidence,
                supportingMessageIds: supportingMessageIds
            )
        }
        .sorted { $0.score > $1.score }
    }

    private func compactFallbackSnippet(_ raw: String?, maxLength: Int = 70) -> String {
        guard let raw else { return "" }
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        if cleaned.count <= maxLength { return cleaned }

        let index = cleaned.index(cleaned.startIndex, offsetBy: maxLength)
        let prefix = String(cleaned[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)…"
    }

    private func cachedFirstMessages(
        for chat: TGChat,
        desiredCount: Int,
        timeRange: TimeRangeConstraint?
    ) async -> [TGMessage] {
        let cache = MessageCacheService.shared
        let step = AppConstants.AI.AgenticSearch.dateProbeStep
        let maxProbe = AppConstants.AI.AgenticSearch.maxDateProbeMessagesPerChat
        var deduped: [Int64: TGMessage] = [:]

        if let cached = await cache.getMessages(chatId: chat.id) {
            for message in cached {
                deduped[message.id] = message
            }
        }

        func textMessagesDescending() -> [TGMessage] {
            deduped.values
                .filter { ($0.textContent?.isEmpty == false) }
                .sorted { $0.date > $1.date }
        }

        func inRangeCount(from messages: [TGMessage]) -> Int {
            applyTimeRange(messages, timeRange: timeRange).count
        }

        var textMessages = textMessagesDescending()
        let requiresDateProbe = timeRange != nil

        // Always fetch at least one Telegram slice when cache is thin.
        if textMessages.count < desiredCount || (requiresDateProbe && inRangeCount(from: textMessages) < desiredCount) {
            let firstFetchLimit = requiresDateProbe ? max(desiredCount, step) : desiredCount
            if let fetched = try? await telegramService.getChatHistory(chatId: chat.id, limit: firstFetchLimit),
               !fetched.isEmpty {
                await cache.cacheMessages(chatId: chat.id, messages: fetched)
                for message in fetched {
                    deduped[message.id] = message
                }
                textMessages = textMessagesDescending()
            }
        }

        // For date-bounded queries, probe older history (within hard cap) until we find enough in-range text.
        if let timeRange {
            while inRangeCount(from: textMessages) < desiredCount && textMessages.count < maxProbe {
                if let oldestDate = textMessages.last?.date, oldestDate <= timeRange.startDate {
                    break
                }

                let oldestKnownId = textMessages.last?.id ?? 0
                guard oldestKnownId != 0 else { break }

                let remaining = maxProbe - textMessages.count
                let fetchLimit = min(step, remaining)
                guard fetchLimit > 0 else { break }

                guard let older = try? await telegramService.getChatHistory(
                    chatId: chat.id,
                    fromMessageId: oldestKnownId,
                    limit: fetchLimit
                ), !older.isEmpty else {
                    break
                }

                let previousCount = textMessages.count
                await cache.cacheMessages(chatId: chat.id, messages: older, append: true)
                for message in older {
                    deduped[message.id] = message
                }
                textMessages = textMessagesDescending()
                if textMessages.count <= previousCount {
                    break
                }
            }
        }

        let filtered = applyTimeRange(textMessages, timeRange: timeRange)
        return Array(filtered.prefix(desiredCount))
    }

    private func topUpOlderMessages(
        for chat: TGChat,
        existingMessages: [TGMessage],
        additionalCount: Int,
        maxTotal: Int,
        timeRange: TimeRangeConstraint?
    ) async -> [TGMessage] {
        var deduped: [Int64: TGMessage] = [:]
        for message in existingMessages {
            deduped[message.id] = message
        }

        let currentCount = deduped.values.filter { ($0.textContent?.isEmpty == false) }.count
        guard currentCount < maxTotal else {
            let messages = deduped.values
                .filter { ($0.textContent?.isEmpty == false) }
                .sorted { $0.date > $1.date }
                .prefix(maxTotal)
                .map { $0 }
            return applyTimeRange(messages, timeRange: timeRange)
        }

        let toFetch = min(additionalCount, maxTotal - currentCount)
        guard toFetch > 0 else {
            let messages = deduped.values
                .filter { ($0.textContent?.isEmpty == false) }
                .sorted { $0.date > $1.date }
                .prefix(maxTotal)
                .map { $0 }
            return applyTimeRange(messages, timeRange: timeRange)
        }

        let oldestKnownId = deduped.values.sorted { $0.date > $1.date }.last?.id ?? 0
        guard oldestKnownId != 0 else {
            let messages = deduped.values
                .filter { ($0.textContent?.isEmpty == false) }
                .sorted { $0.date > $1.date }
                .prefix(maxTotal)
                .map { $0 }
            return applyTimeRange(messages, timeRange: timeRange)
        }

        if let older = try? await telegramService.getChatHistory(
            chatId: chat.id,
            fromMessageId: oldestKnownId,
            limit: toFetch
        ), !older.isEmpty {
            await MessageCacheService.shared.cacheMessages(chatId: chat.id, messages: older, append: true)
            for message in older {
                deduped[message.id] = message
            }
        }

        let messages = deduped.values
            .filter { ($0.textContent?.isEmpty == false) }
            .sorted { $0.date > $1.date }
            .prefix(maxTotal)
            .map { $0 }
        return applyTimeRange(messages, timeRange: timeRange)
    }

    /// Deduplicate AI results by chat ID, keeping the higher-relevance entry.
    private func deduplicateResults(_ results: [AISearchResult]) -> [AISearchResult] {
        var seen: [Int64: AISearchResult] = [:]
        for result in results {
            if case .semanticResult(let r) = result {
                if let existing = seen[r.chatId], case .semanticResult(let e) = existing {
                    // Keep the higher-relevance version
                    if r.relevance == .high && e.relevance != .high {
                        seen[r.chatId] = result
                    }
                } else {
                    seen[r.chatId] = result
                }
            }
        }
        // Sort: high relevance first, then medium
        return seen.values.sorted { a, b in
            if case .semanticResult(let ra) = a, case .semanticResult(let rb) = b {
                if ra.relevance == .high && rb.relevance != .high { return true }
                if ra.relevance != .high && rb.relevance == .high { return false }
            }
            return false
        }
    }

    // MARK: - Semantic Search Lazy Loading

    private func loadNextSemanticBatch() {
        guard hasMoreSemanticBatches, !isLoadingMoreSemantic, aiSearchMode == .semanticSearch else { return }
        isLoadingMoreSemantic = true

        Task {
            let concurrentBatches = 3
            let batchSize = 10
            let allChats = aiSearchSourceChats
            let query = currentSemanticQuery
            let startOffset = semanticBatchOffset

            var newResults: [AISearchResult] = []

            await withTaskGroup(of: [SemanticSearchResult].self) { group in
                for i in 0..<concurrentBatches {
                    let start = startOffset + i * batchSize
                    let batchChats = Array(allChats.dropFirst(start).prefix(batchSize))
                    guard !batchChats.isEmpty else { continue }

                    group.addTask { [telegramService, aiService] in
                        do {
                            let messages = try await telegramService.getRecentMessagesAcrossChats(
                                chatIds: batchChats.map(\.id), perChatLimit: 15
                            )
                            return try await aiService.semanticSearch(query: query, messages: messages)
                        } catch {
                            return []
                        }
                    }
                }

                for await batchResults in group {
                    newResults.append(contentsOf: batchResults.map { .semanticResult($0) })
                }
            }

            let totalNewlyScanned = min(concurrentBatches * batchSize, max(0, allChats.count - startOffset))
            await MainActor.run {
                let combined = aiResults + newResults
                aiResults = deduplicateResults(combined)
                semanticBatchOffset = startOffset + totalNewlyScanned
                hasMoreSemanticBatches = semanticBatchOffset < allChats.count
                isLoadingMoreSemantic = false
            }
        }
    }

}
