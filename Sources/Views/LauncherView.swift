import SwiftUI
import Combine

struct LauncherView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService
    @ObservedObject var photoManager = ChatPhotoManager.shared

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

    // Semantic search lazy loading
    @State private var semanticBatchOffset: Int = 0
    @State private var hasMoreSemanticBatches: Bool = true
    @State private var isLoadingMoreSemantic: Bool = false
    @State private var currentSemanticQuery: String = ""
    @State private var totalChatsToScan: Int = 0

    // Filter tags
    enum Filter: String, CaseIterable {
        case all = "All"
        case groups = "Groups"
        case dms = "DMs"
        case unread = "Unread"
        case pipeline = "Pipeline"
        case priority = "Priority"

        var icon: String? {
            switch self {
            case .all: return nil
            case .groups: return "person.3"
            case .dms: return "envelope"
            case .unread: return "circle.badge.fill"
            case .pipeline: return "arrow.triangle.branch"
            case .priority: return "sparkles"
            }
        }
    }

    @State private var activeFilter: Filter = .all

    // Keyboard navigation
    @State private var selectedIndex: Int = 0

    // Priority AI state
    @State private var priorityItems: [ActionItem] = []
    @State private var isPriorityLoading = false
    @State private var priorityError: String?
    @State private var priorityFetchedAt: Date?

    // Follow-ups state
    @State private var followUpItems: [FollowUpItem] = []
    @State private var isFollowUpsLoading = false
    @State private var pipelineProcessedCount = 0
    @State private var pipelineTotalCount = 0
    @State private var pipelineSubFilter: FollowUpItem.Category? = nil

    // Settings callback
    var onOpenSettings: () -> Void = {}

    // MARK: - AI Search Result Types

    enum AISearchResult: Identifiable {
        case semanticResult(SemanticSearchResult)

        var id: String {
            switch self {
            case .semanticResult(let result): return "sem-\(result.id)"
            }
        }

        /// The chat that should be opened when this result is tapped (if any).
        func linkedChat(in chats: [TGChat]) -> TGChat? {
            switch self {
            case .semanticResult(let result):
                return chats.first(where: { $0.title == result.chatTitle })
            }
        }
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
        case .unread:
            chats = telegramService.visibleChats.filter { $0.unreadCount > 0 }
        case .pipeline:
            return followUpItems.map(\.chat)
        case .priority:
            return priorityOrderedChats
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

    /// Priority tab: AI-ranked chats first (by urgency), then all remaining chats.
    private var priorityOrderedChats: [TGChat] {
        var prioritized: [TGChat] = []
        var matchedIds: Set<Int64> = []

        for item in priorityItems {
            if let chat = telegramService.visibleChats.first(where: { $0.title == item.chatTitle }) {
                if !matchedIds.contains(chat.id) {
                    prioritized.append(chat)
                    matchedIds.insert(chat.id)
                }
            }
        }

        let remaining = telegramService.visibleChats.filter { !matchedIds.contains($0.id) }
        var result = prioritized + remaining

        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                || searchResultChatIds.contains($0.id)
            }
        }

        return result
    }

    private func priorityReason(for chat: TGChat) -> String? {
        guard activeFilter == .priority else { return nil }
        return priorityItems.first(where: { $0.chatTitle == chat.title })?.summary
    }

    // MARK: - Pipeline Sections

    /// Groups followUpItems into sections by category, with sub-filter and search filtering.
    private var pipelineSections: [PipelineSection] {
        let categoryOrder: [FollowUpItem.Category] = [.onMe, .onThem, .quiet]
        var filtered = followUpItems

        if let subFilter = pipelineSubFilter {
            filtered = filtered.filter { $0.category == subFilter }
        }
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.chat.title.localizedCaseInsensitiveContains(searchText)
            }
        }
        return categoryOrder.compactMap { cat in
            let items = filtered.filter { $0.category == cat }
            guard !items.isEmpty else { return nil }
            return PipelineSection(category: cat, items: items)
        }
    }

    /// Flattened pipeline items with indices for continuous keyboard navigation across sections.
    private var flatPipelineItems: [FollowUpItem] {
        pipelineSections.flatMap(\.items)
    }

    /// Total navigable items (either AI results, priority items, pipeline, or chat rows depending on mode).
    private var navigableCount: Int {
        if activeFilter == .pipeline {
            return flatPipelineItems.count
        }
        if activeFilter == .priority {
            return priorityItems.count
        }
        if aiSearchMode == .semanticSearch && (!aiResults.isEmpty || hasMoreSemanticBatches) {
            return titleMatchedChats.count + aiResults.count
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
            if activeFilter == .priority {
                Task { await loadPriority() }
            } else if activeFilter == .pipeline {
                loadFollowUps()
            }
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
            pipelineSubFilter = nil
            if activeFilter == .priority {
                Task { await loadPriority() }
            } else if activeFilter == .pipeline {
                loadFollowUps()
            }
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
            if activeFilter == .pipeline {
                // Pipeline mode: open chat from flat index across sections
                let flat = flatPipelineItems
                if selectedIndex < flat.count {
                    openChat(flat[selectedIndex].chat)
                }
            } else if activeFilter == .priority {
                // Priority mode: open linked chat from priority item
                if selectedIndex < priorityItems.count,
                   let chat = telegramService.visibleChats.first(where: { $0.title == priorityItems[selectedIndex].chatTitle }) {
                    openChat(chat)
                }
            } else if aiSearchMode == .semanticSearch && (!aiResults.isEmpty || !titleMatchedChats.isEmpty) {
                // AI mode: title matches first, then AI results
                let titleMatches = titleMatchedChats
                if selectedIndex < titleMatches.count {
                    openChat(titleMatches[selectedIndex])
                } else {
                    let aiIndex = selectedIndex - titleMatches.count
                    if aiIndex < aiResults.count,
                       let chat = aiResults[aiIndex].linkedChat(in: telegramService.visibleChats) {
                        openChat(chat)
                    }
                }
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

            if isSearching || isAISearching {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResultChatIds = []
                    aiResults = []
                    aiSearchMode = nil
                    aiSearchError = nil
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

    private func filterLabel(for filter: Filter) -> String {
        switch filter {
        case .unread:
            let count = telegramService.visibleChats.filter { $0.unreadCount > 0 }.count
            return count > 0 ? "Unread (\(count))" : "Unread"
        case .pipeline:
            let total = pipelineSections.flatMap(\.items).count
            return total > 0 ? "Pipeline (\(total))" : "Pipeline"
        case .priority:
            return priorityItems.isEmpty ? "Priority" : "Priority (\(priorityItems.count))"
        default:
            return filter.rawValue
        }
    }

    private var filterTags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Filter.allCases, id: \.self) { filter in
                    Button {
                        activeFilter = filter
                    } label: {
                        Text(filterLabel(for: filter))
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
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 9))
                .foregroundStyle(.purple)

            Text(aiModeLabel(intent: intent))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.purple.opacity(0.8))

            Spacer()

            if isAISearching {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.purple.opacity(0.06))
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
        case .messageSearch:
            return "Searching messages..."
        }
    }

    // MARK: - Results List

    @ViewBuilder
    private var resultsList: some View {
        if activeFilter == .pipeline {
            pipelineResultsList
        } else if activeFilter == .priority && !aiService.isConfigured {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(.purple.opacity(0.4))
                Text("Add an AI API key in Settings to use Priority")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button("Open Settings", action: onOpenSettings)
                    .font(.system(size: 12))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if activeFilter == .priority && isPriorityLoading {
            LoadingStateView(message: "Analyzing priority...")
        } else if activeFilter == .priority, let error = priorityError {
            ErrorStateView(message: error) {
                Task { await loadPriority(force: true) }
            }
        } else if activeFilter == .priority {
            priorityResultsList
        } else if isAISearching {
            LoadingStateView(message: aiModeLabel(intent: aiSearchMode ?? .messageSearch))
        } else if let error = aiSearchError {
            ErrorStateView(message: error) {
                triggerSearch()
            }
        } else if aiSearchMode == .semanticSearch && (!aiResults.isEmpty || hasMoreSemanticBatches) {
            // AI results mode (show even when empty if more batches can load)
            aiResultsList
        } else if aiSearchMode == .semanticSearch && aiResults.isEmpty && !hasMoreSemanticBatches {
            // All batches scanned, nothing found
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No relevant chats found",
                subtitle: "Try a different search query"
            )
        } else if telegramService.isLoading && telegramService.chats.isEmpty {
            LoadingStateView(message: "Loading chats...")
        } else if displayedChats.isEmpty && !searchText.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No results for \"\(searchText)\""
            )
        } else if displayedChats.isEmpty {
            EmptyStateView(
                icon: "tray",
                title: "No \(activeFilter == .all ? "chats" : activeFilter.rawValue.lowercased()) found"
            )
        } else {
            // Standard chat list mode
            chatResultsList
        }
    }

    // MARK: - Chat Results List (standard mode)

    private var chatResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if !searchText.isEmpty || activeFilter == .priority {
                        Text("\(displayedChats.count) result\(displayedChats.count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.top, 2)
                    }

                    ForEach(Array(displayedChats.enumerated()), id: \.element.id) { index, chat in
                        ChatRowView(
                            chat: chat,
                            isHighlighted: index == selectedIndex,
                            priorityReason: priorityReason(for: chat),
                            onOpen: { openChat(chat) }
                        )
                        .id(chat.id)
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
        // Exclude chats already in AI results to avoid duplicates
        let aiChatTitles = Set(aiResults.compactMap { result -> String? in
            if case .semanticResult(let r) = result { return r.chatTitle }
            return nil
        })
        return telegramService.visibleChats.filter {
            $0.title.lowercased().contains(query) && !aiChatTitles.contains($0.title)
        }
    }

    private var aiResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    let titleMatches = titleMatchedChats
                    let totalCount = titleMatches.count + aiResults.count

                    Text("\(totalCount) result\(totalCount == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)

                    // Direct title matches first
                    ForEach(Array(titleMatches.enumerated()), id: \.element.id) { index, chat in
                        ChatRowView(
                            chat: chat,
                            isHighlighted: index == selectedIndex,
                            onOpen: { openChat(chat) }
                        )
                        .id(chat.id)
                    }

                    // AI semantic results after title matches
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
            }
        }
    }

    // MARK: - Priority Results List

    private var priorityResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    // Refresh header with cache age
                    if !priorityItems.isEmpty {
                        HStack {
                            if let fetchedAt = priorityFetchedAt {
                                Text("Updated \(DateFormatting.compactRelativeTime(from: fetchedAt))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                Task { await loadPriority(force: true) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }

                    ForEach(Array(priorityItems.enumerated()), id: \.element.id) { index, item in
                        if let chat = telegramService.visibleChats.first(where: { $0.title == item.chatTitle }) {
                            priorityResultRow(item: item, chat: chat, index: index)
                                .id(item.id)
                        }
                    }

                    if priorityItems.isEmpty {
                        EmptyStateView(
                            icon: "checkmark.circle",
                            title: "All caught up!",
                            subtitle: "No action items found"
                        )
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                if newIndex < priorityItems.count {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(priorityItems[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func priorityResultRow(item: ActionItem, chat: TGChat, index: Int) -> some View {
        Button {
            openChat(chat)
        } label: {
            HStack(spacing: 8) {
                avatarForChat(title: item.chatTitle)

                VStack(alignment: .leading, spacing: 2) {
                    // Line 1: chat title + urgency badge
                    HStack(spacing: 5) {
                        Text(item.chatTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(item.urgency.rawValue.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(item.urgency.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(item.urgency.color.opacity(0.12))
                            .clipShape(Capsule())

                        Spacer()
                    }

                    // Line 2: summary
                    Text(item.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    // Line 3: suggested action
                    Text(item.suggestedAction)
                        .font(.system(size: 10))
                        .italic()
                        .foregroundStyle(.purple.opacity(0.7))
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

    // MARK: - AI Result Row

    @ViewBuilder
    private func aiResultRow(result: AISearchResult, index: Int) -> some View {
        switch result {
        case .semanticResult(let result):
            semanticResultRow(result: result, index: index)
        }
    }

    /// Look up a chat by title and return its avatar with photo, or generate a fallback.
    @ViewBuilder
    private func avatarForChat(title: String) -> some View {
        if let chat = telegramService.visibleChats.first(where: { $0.title == title }) {
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
            let words = title.split(separator: " ")
            let initials: String = {
                if words.count >= 2 {
                    return "\(words[0].prefix(1))\(words[1].prefix(1))".uppercased()
                } else if let first = words.first {
                    return String(first.prefix(2)).uppercased()
                }
                return "?"
            }()
            AvatarView(initials: initials, colorIndex: abs(title.hashValue % 8), size: 26)
        }
    }

    private func semanticResultRow(result: SemanticSearchResult, index: Int) -> some View {
        Button {
            if let chat = telegramService.visibleChats.first(where: { $0.title == result.chatTitle }) {
                openChat(chat)
            }
        } label: {
            HStack(spacing: 8) {
                avatarForChat(title: result.chatTitle)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(result.chatTitle)
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

    // MARK: - Pipeline Results List (Sectioned CRM View)

    private var pipelineResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    let sections = pipelineSections
                    let flat = flatPipelineItems

                    // Sub-filter bar
                    pipelineSubFilterBar

                    // AI loading indicator with progress
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

                    // Sectioned items
                    ForEach(sections) { section in
                        pipelineSectionHeader(section: section)

                        ForEach(section.items) { item in
                            let flatIndex = flat.firstIndex(where: { $0.id == item.id }) ?? 0
                            ChatRowView(
                                chat: item.chat,
                                isHighlighted: flatIndex == selectedIndex,
                                pipelineStatus: item.category,
                                pipelineSuggestion: item.suggestedAction,
                                onOpen: { openChat(item.chat) }
                            )
                            .id(item.id)
                        }
                    }

                    if flat.isEmpty && !isFollowUpsLoading {
                        EmptyStateView(
                            icon: "checkmark.circle",
                            title: "All caught up!",
                            subtitle: "No conversations need attention"
                        )
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                let flat = flatPipelineItems
                if newIndex < flat.count {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(flat[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    /// Compact one-line summary: "📬 3 need reply · 📤 5 waiting · 💤 2 quiet"
    private var pipelineSummaryBar: some View {
        let sections = pipelineSections
        return HStack(spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Text(" · ")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
                HStack(spacing: 3) {
                    Image(systemName: section.icon)
                        .font(.system(size: 8))
                        .foregroundStyle(section.category.color)
                    Text("\(section.items.count) \(section.title.lowercased())")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.04))
    }

    /// Clean section divider with icon + label in category color.
    private func pipelineSectionHeader(section: PipelineSection) -> some View {
        HStack(spacing: 4) {
            Image(systemName: section.icon)
                .font(.system(size: 9))
                .foregroundStyle(section.category.color)

            Text("\(section.title) (\(section.items.count))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(section.category.color.opacity(0.8))

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func isFromMe(_ message: TGMessage) -> Bool {
        if case .user(let uid) = message.senderId {
            return uid == telegramService.currentUser?.id
        }
        return false
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

    /// AI-powered categorization for a single chat with progressive message fetching.
    /// Caches results to disk so re-analysis only happens when new messages arrive.
    private func categorizeSingleChat(
        chat: TGChat,
        myUserId: Int64
    ) async -> FollowUpItem? {
        guard let lastMsg = chat.lastMessage else { return nil }
        let age = Date().timeIntervalSince(lastMsg.date)
        let batchSize = AppConstants.FollowUp.messagesPerChat
        let maxRounds = AppConstants.FollowUp.maxProgressiveFetches
        let cache = MessageCacheService.shared

        var allMessages: [TGMessage] = []

        // Try message cache first
        if let cached = await cache.getMessages(chatId: chat.id) {
            allMessages = cached
        }

        // If cache empty or insufficient, fetch from Telegram
        if allMessages.count < batchSize {
            do {
                let fetched = try await telegramService.getChatHistory(chatId: chat.id, limit: batchSize)
                allMessages = fetched
                await cache.cacheMessages(chatId: chat.id, messages: fetched)
            } catch {
                if allMessages.isEmpty { return nil }
            }
        }

        // Progressive categorization loop
        for round in 0..<maxRounds {
            let messagesToSend = Array(allMessages.prefix((round + 1) * batchSize))

            do {
                let myUser = telegramService.currentUser
                let (category, suggestion, confident) = try await aiService.categorizePipelineChat(
                    chat: chat,
                    messages: messagesToSend,
                    myUserId: myUserId,
                    myUser: myUser
                )

                if confident || round == maxRounds - 1 {
                    // Cache the AI result for next time
                    let categoryStr: String
                    switch category {
                    case .onMe: categoryStr = "on_me"
                    case .onThem: categoryStr = "on_them"
                    case .quiet: categoryStr = "quiet"
                    }
                    await cache.cachePipelineCategory(
                        chatId: chat.id,
                        category: categoryStr,
                        suggestedAction: suggestion,
                        lastMessageId: lastMsg.id
                    )

                    return FollowUpItem(
                        chat: chat,
                        category: category,
                        lastMessage: lastMsg,
                        timeSinceLastActivity: age,
                        suggestedAction: suggestion.isEmpty ? nil : suggestion
                    )
                }

                // Not confident — fetch more messages
                let oldestId = allMessages.last?.id ?? 0
                guard oldestId != 0 else { break }

                do {
                    let moreMsgs = try await telegramService.getChatHistory(
                        chatId: chat.id,
                        fromMessageId: oldestId,
                        limit: AppConstants.FollowUp.progressiveFetchStep
                    )
                    guard !moreMsgs.isEmpty else { break }
                    allMessages.append(contentsOf: moreMsgs)
                    await cache.cacheMessages(chatId: chat.id, messages: moreMsgs, append: true)
                } catch {
                    break
                }
            } catch {
                break
            }
        }

        return nil
    }

    private func loadFollowUps() {
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
                    let category: FollowUpItem.Category
                    switch cached.category {
                    case "on_me": category = .onMe
                    case "on_them": category = .onThem
                    default: category = .quiet
                    }
                    let age = Date().timeIntervalSince(lastMsg.date)
                    cachedItems.append(FollowUpItem(
                        chat: chat,
                        category: category,
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

    // MARK: - Actions

    private func openChat(_ chat: TGChat) {
        if let url = DeepLinkGenerator.chatURL(chat: chat) {
            DeepLinkGenerator.openInTelegram(url)
        }
        NSApp.keyWindow?.orderOut(nil)
    }

    /// Debounced search: waits 300ms, then classifies via QueryRouter.
    /// If AI intent detected → runs AI pipeline. Otherwise → TDLib keyword search.
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
            let intent = await aiService.queryRouter.route(query: query)
            guard !Task.isCancelled else { return }

            if intent != .messageSearch && aiService.isConfigured {
                // AI mode: run the AI pipeline
                await MainActor.run {
                    aiSearchMode = intent
                    isAISearching = true
                    aiSearchError = nil
                    searchResultChatIds = []
                }

                do {
                    let results = try await executeAISearch(intent: intent)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        aiResults = results
                        isAISearching = false
                        selectedIndex = 0
                        // If first batch returned empty but more chats exist, auto-load next batch
                        if results.isEmpty && hasMoreSemanticBatches {
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
                // Keyword mode: TDLib message content search
                await MainActor.run {
                    aiSearchMode = nil
                    aiResults = []
                    isSearching = true
                }

                do {
                    let messages = try await telegramService.searchMessages(query: query, limit: 50)
                    guard !Task.isCancelled else { return }
                    let chatIds = Set(messages.map(\.chatId))
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

    private func executeAISearch(intent: QueryIntent) async throws -> [AISearchResult] {
        switch intent {
        case .semanticSearch:
            let concurrentBatches = 3
            let batchSize = 10
            let allChats = telegramService.visibleChats
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

        case .messageSearch:
            return [] // Handled by keyword path
        }
    }

    /// Deduplicate AI results by chat title, keeping the higher-relevance entry.
    private func deduplicateResults(_ results: [AISearchResult]) -> [AISearchResult] {
        var seen: [String: AISearchResult] = [:]
        for result in results {
            if case .semanticResult(let r) = result {
                if let existing = seen[r.chatTitle], case .semanticResult(let e) = existing {
                    // Keep the higher-relevance version
                    if r.relevance == .high && e.relevance != .high {
                        seen[r.chatTitle] = result
                    }
                } else {
                    seen[r.chatTitle] = result
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
            let allChats = telegramService.visibleChats
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

    private func loadPriority(force: Bool = false) async {
        if !force, let fetchedAt = priorityFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 300 {
            return
        }

        guard aiService.isConfigured else {
            priorityError = "Add an AI API key in Settings"
            return
        }

        isPriorityLoading = true
        priorityError = nil
        defer { isPriorityLoading = false }

        do {
            let chatIds = telegramService.visibleChats
                .prefix(AppConstants.Fetch.actionItemChatCount)
                .map(\.id)
            let messages = try await telegramService.getRecentMessagesAcrossChats(
                chatIds: chatIds,
                perChatLimit: AppConstants.Fetch.actionItemPerChat
            )
            var items = try await aiService.actionItems(messages: messages)
            items.sort { a, b in
                let order: [ActionItem.Urgency] = [.high, .medium, .low]
                let aIdx = order.firstIndex(of: a.urgency) ?? 2
                let bIdx = order.firstIndex(of: b.urgency) ?? 2
                return aIdx < bIdx
            }
            priorityItems = items
            priorityFetchedAt = Date()
        } catch {
            priorityError = error.localizedDescription
        }
    }
}
