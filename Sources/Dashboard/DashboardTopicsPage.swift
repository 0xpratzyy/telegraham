import SwiftUI

struct DashboardTopicsPage: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var aiService: AIService

    let topics: [DashboardTopic]
    let tasks: [DashboardTask]
    let followUpItems: [FollowUpItem]
    let sourceChats: [TGChat]
    @Binding var selectedTopicId: Int64?
    let onOpenTask: (DashboardTask) -> Void
    let onOpenReply: (FollowUpItem) -> Void
    let onOpenChat: (Int64) -> Void

    @State private var searchText = ""
    @State private var selectedCommand: DashboardTopicCommand = .allChats
    @State private var cachedTopicTasks: [DashboardTask] = []
    @State private var cachedTopicReplies: [FollowUpItem] = []
    @State private var cachedTopicChatSignals: [DashboardTopicChatSignal] = []
    @State private var cachedActiveTaskCount = 0
    @State private var cachedActiveReplyCount = 0
    @State private var recentMessages: [DashboardPersonRecentMessage] = []
    @State private var isLoadingRecentMessages = false
    @State private var semanticResults: [DashboardTopicSemanticSearchResult] = []
    @State private var semanticSummary: String?
    @State private var semanticSearchError: String?
    @State private var isLoadingSemanticResults = false
    /// Monotonic ticket for the semantic search/catch-up pipeline. SwiftUI
    /// cancels the old .task on topic switch, but cancellation surfaces as a
    /// generic error inside the AI call — without generation ownership the
    /// OLD topic's fallback summary published over the NEW topic, and the old
    /// task's defer cleared the new request's loading spinner.
    @State private var semanticRequestGeneration = 0
    /// True once we've waited long enough that an empty `topics` array
    /// almost certainly means "no topics" rather than "still loading".
    /// Drives the skeleton-vs-empty-state choice in `body` below — the
    /// page used to flash "No topics yet" for a beat on first open even
    /// when topics were about to populate, which read as broken.
    @State private var topicLoadGracePeriodElapsed = false

    private var topicOptions: [DashboardTopicOption] {
        var options = topics
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.score > rhs.score
            }
            .map {
                DashboardTopicOption(
                    id: $0.id,
                    name: $0.name,
                    rationale: $0.rationale,
                    tint: PidgyDashboardTheme.topicTint($0.id),
                    isUncategorized: false
                )
            }

        if tasks.contains(where: { $0.topicId == nil }) {
            options.append(
                DashboardTopicOption(
                    id: dashboardUncategorizedTopicId,
                    name: "Uncategorized",
                    rationale: "Work that Pidgy has not confidently assigned yet.",
                    tint: PidgyDashboardTheme.tertiary,
                    isUncategorized: true
                )
            )
        }
        return options
    }

    private var selectedTopic: DashboardTopicOption? {
        if let selectedTopicId,
           let option = topicOptions.first(where: { $0.id == selectedTopicId }) {
            return option
        }
        return topicOptions.first
    }

    private var topicTasks: [DashboardTask] {
        cachedTopicTasks
    }

    private var topicReplies: [FollowUpItem] {
        cachedTopicReplies
    }

    private var topicChatSignals: [DashboardTopicChatSignal] {
        cachedTopicChatSignals
            .filter(commandAllows)
            .filter(matchesSearch)
    }

    private var isSemanticSearchActive: Bool {
        selectedCommand == .catchUp
            || (selectedCommand == .allChats && !trimmedSearchText.isEmpty)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var semanticQuery: String {
        guard let selectedTopic else { return "" }
        let description = selectedTopic.rationale == "Added manually." ? "" : selectedTopic.rationale
        let topicDefinition = "\(selectedTopic.name) \(description)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearchText.isEmpty {
            return "\(topicDefinition) \(trimmedSearchText)"
        }
        if selectedCommand == .catchUp {
            return "recent important updates decisions asks open loops \(topicDefinition)"
        }
        return topicDefinition
    }

    private var semanticSearchKey: String {
        let chatKey = cachedTopicChatSignals.prefix(120).map(\.chatId).sorted().map(String.init).joined(separator: ",")
        let recentKey = recentMessages.prefix(20).map { "\($0.chatId):\($0.date.timeIntervalSince1970)" }.joined(separator: "|")
        return "\(selectedTopic?.id ?? 0):\(selectedCommand.rawValue):\(searchText):\(chatKey):\(recentKey):\(tasks.count):\(followUpItems.count)"
    }

    private var semanticScopeChatSignals: [DashboardTopicChatSignal] {
        cachedTopicChatSignals
    }

    private var chatTitleById: [Int64: String] {
        Dictionary(uniqueKeysWithValues: allChats.map { ($0.id, $0.title) })
    }

    private var displayedTopicTasks: [DashboardTask] {
        topicTasks
            .filter(\.isActionableNow)
            .filter { task in
                guard !trimmedSearchText.isEmpty else { return true }
                return matchesQuery(fields: [task.title, task.summary, task.suggestedAction, task.personName, task.chatTitle])
            }
            .sorted {
                let lhsDate = $0.latestSourceDate ?? $0.updatedAt
                let rhsDate = $1.latestSourceDate ?? $1.updatedAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    private var displayedTopicReplies: [FollowUpItem] {
        topicReplies
            .filter { $0.category == .onMe }
            .filter { item in
                guard !trimmedSearchText.isEmpty else { return true }
                return matchesQuery(fields: [item.chat.title, item.suggestedAction ?? "", item.lastMessage.displayText, item.lastMessage.senderName ?? ""])
            }
            .sorted { $0.lastMessage.date > $1.lastMessage.date }
    }

    private var semanticCatchUpSections: [DashboardCatchUpSection] {
        DashboardCatchUpSection.parse(semanticSummary ?? "")
    }

    private var chatById: [Int64: TGChat] {
        Dictionary(uniqueKeysWithValues: allChats.map { ($0.id, $0) })
    }

    private var semanticHighlightEntities: [DashboardEntityHighlight] {
        let chats = allChats
        let normalizedChatByTitle = Dictionary(
            chats.map { (normalizedTopicText($0.title), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let normalizedPrivateChatByTitle = Dictionary(
            chats.compactMap { chat -> (String, TGChat)? in
                guard chat.chatType.isPrivate else { return nil }
                return (normalizedTopicText(chat.title), chat)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let fallbackTopicChatId = semanticScopeChatSignals.first?.chatId
        var entitiesByKey: [String: DashboardEntityHighlight] = [:]

        func add(_ rawTerm: String?, kind: DashboardEntityHighlight.Kind, preferredChatId: Int64?) {
            guard let rawTerm else { return }
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizedTopicText(term)
            let isShortAcronym = term.count == 2 && term == term.uppercased()
            guard normalized.count >= 3 || isShortAcronym else { return }
            guard !["unknown", "task", "reply", "recent", "message", "group", "chat", "supergroup", "channel", "dm", "ai"].contains(normalized) else { return }

            let resolvedChatId: Int64? = {
                switch kind {
                case .person:
                    return normalizedPrivateChatByTitle[normalized]?.id ?? preferredChatId
                case .chat:
                    return preferredChatId ?? normalizedChatByTitle[normalized]?.id
                case .topic:
                    return normalizedChatByTitle[normalized]?.id ?? preferredChatId ?? fallbackTopicChatId
                }
            }()

            let entity = DashboardEntityHighlight(
                label: term,
                normalizedLabel: normalized,
                chatId: resolvedChatId,
                kind: kind
            )

            if let existing = entitiesByKey[normalized] {
                let shouldReplace = (existing.chatId == nil && entity.chatId != nil)
                    || entity.kind.rawValue > existing.kind.rawValue
                if shouldReplace {
                    entitiesByKey[normalized] = entity
                }
            } else {
                entitiesByKey[normalized] = entity
            }
        }

        add(selectedTopic?.name, kind: .topic, preferredChatId: nil)
        for result in semanticResults.prefix(24) {
            add(result.chatTitle, kind: .chat, preferredChatId: result.chatId)
            add(result.senderName, kind: .person, preferredChatId: result.chatId)
        }
        for task in topicTasks.prefix(16) {
            add(task.personName, kind: .person, preferredChatId: task.chatId)
            add(task.chatTitle, kind: .chat, preferredChatId: task.chatId)
        }
        for item in topicReplies.prefix(16) {
            add(item.chat.title, kind: .chat, preferredChatId: item.chat.id)
            add(item.lastMessage.senderName, kind: .person, preferredChatId: item.chat.id)
        }

        return entitiesByKey.values
            .sorted { lhs, rhs in
                if lhs.label.count != rhs.label.count { return lhs.label.count > rhs.label.count }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            .prefix(24)
            .map { $0 }
    }

    private func buildTopicChatSignals(
        query: DashboardTopicMatchQuery,
        matchingTasks: [DashboardTask],
        matchingReplies: [FollowUpItem],
        applyCommandFilter: Bool = true,
        applySearchFilter: Bool = true
    ) -> [DashboardTopicChatSignal] {
        let chats = allChats
        let chatById = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        let tasksByChatId = Dictionary(grouping: matchingTasks.filter(\.isActionableNow), by: \.chatId)
        let repliesByChatId = Dictionary(grouping: matchingReplies, by: { $0.chat.id })

        var chatIds = Set<Int64>()
        chatIds.formUnion(tasksByChatId.keys)
        chatIds.formUnion(repliesByChatId.keys)
        for chat in chats where matchesTopic(query, text: chat.title)
            || matchesTopic(query, text: chat.lastMessage?.displayText) {
            chatIds.insert(chat.id)
        }

        return chatIds.compactMap { chatId -> DashboardTopicChatSignal? in
            let chat = chatById[chatId]
            let chatTasks = tasksByChatId[chatId] ?? []
            let chatReplies = repliesByChatId[chatId] ?? []
            let title = chat?.title ?? chatTasks.first?.chatTitle ?? chatReplies.first?.chat.title ?? "Chat \(chatId)"
            let latestTaskDate = chatTasks.compactMap { $0.latestSourceDate ?? $0.updatedAt }.max()
            let latestReplyDate = chatReplies.map(\.lastMessage.date).max()
            let latestDate = [chat?.lastMessage?.date, latestTaskDate, latestReplyDate].compactMap { $0 }.max()
            let snippet = chatReplies.first?.suggestedAction
                ?? chatReplies.first?.lastMessage.displayText
                ?? chat?.lastMessage?.displayText
                ?? chatTasks.first?.summary
                ?? "No recent preview available."

            return DashboardTopicChatSignal(
                chatId: chatId,
                chat: chat,
                title: title,
                typeLabel: chat?.chatType.displayName ?? "Chat",
                snippet: snippet,
                lastActivityAt: latestDate,
                openTaskCount: chatTasks.count,
                replyCount: chatReplies.filter { $0.category == .onMe }.count
            )
        }
        .filter { applyCommandFilter ? commandAllows($0) : true }
        .filter { applySearchFilter ? matchesSearch($0) : true }
        .sorted {
            if $0.lastActivityAt != $1.lastActivityAt {
                return ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
            }
            if $0.openTaskCount + $0.replyCount != $1.openTaskCount + $1.replyCount {
                return $0.openTaskCount + $0.replyCount > $1.openTaskCount + $1.replyCount
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private var activeTaskCount: Int {
        cachedActiveTaskCount
    }

    private var activeReplyCount: Int {
        cachedActiveReplyCount
    }

    private var recentReloadKey: String {
        "\(selectedTopic?.id ?? 0):\(selectedCommand.rawValue):\(semanticScopeChatSignals.prefix(60).map(\.chatId).sorted().map(String.init).joined(separator: ","))"
    }

    private var topicSignalRefreshKey: Int {
        var hasher = Hasher()
        hasher.combine(selectedTopic?.id)
        hasher.combine(selectedTopic?.name)
        hasher.combine(selectedTopic?.rationale)
        for task in tasks {
            hasher.combine(task.id)
            hasher.combine(task.status.rawValue)
            hasher.combine(task.topicId)
            hasher.combine(task.chatId)
            hasher.combine(task.updatedAt)
        }
        for item in followUpItems {
            hasher.combine(item.chat.id)
            hasher.combine(item.category.rawValue)
            hasher.combine(item.lastMessage.id)
        }
        for chat in allChats {
            hasher.combine(chat.id)
            hasher.combine(chat.title)
            hasher.combine(chat.lastMessage?.id)
        }
        return hasher.finalize()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let selectedTopic {
                    topicHeader(selectedTopic)
                    controlsRow(selectedTopic)
                    contentSections
                } else if topics.isEmpty && !topicLoadGracePeriodElapsed {
                    // First-load skeleton — the indexer typically
                    // populates `topics` within a second or two on
                    // launch, but the empty-state copy read as
                    // "broken" during that window. Show placeholders
                    // until the grace period elapses or topics arrive.
                    topicsLoadingSkeleton
                        .padding(.top, 32)
                } else {
                    DashboardEmptyState(
                        systemImage: "folder",
                        title: "No topics yet",
                        subtitle: "Refresh after recent sync to discover your recurring workspaces."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                }
            }
            .frame(maxWidth: PidgyDashboardTheme.pageMaxWidth, alignment: .leading)
            .padding(.top, PidgyDashboardTheme.pageTopPadding)
            .padding(.horizontal, PidgyDashboardTheme.pageHorizontalPadding)
            .padding(.bottom, PidgyDashboardTheme.pageBottomPadding)
            .frame(maxWidth: .infinity)
        }
        .background(PidgyDashboardTheme.paper)
        .task {
            selectDefaultTopicIfNeeded()
            // Wait long enough that an empty topics array reasonably
            // means "no topics exist" rather than "still loading".
            // 2.5s comfortably covers the indexer's typical cold-start
            // population time.
            try? await Task.sleep(for: .seconds(2.5))
            topicLoadGracePeriodElapsed = true
        }
        .task(id: topicSignalRefreshKey) {
            await rebuildTopicChatSignals()
        }
        .task(id: recentReloadKey) {
            await loadRecentMessages()
        }
        .task(id: semanticSearchKey) {
            await runSemanticSearchIfNeeded()
        }
        .onChange(of: topics.map(\.id)) {
            selectDefaultTopicIfNeeded()
        }
        // Hot-swap on topic change: the semantic task re-runs via its key,
        // but the PREVIOUS topic's digest/results stayed on screen until the
        // new call landed — clear immediately so the skeleton takes over.
        .onChange(of: selectedTopicId) {
            semanticSummary = nil
            semanticResults = []
            semanticSearchError = nil
        }
    }

    /// Skeleton placeholder rendered before any topic is selected
    /// AND while the first-load grace period is still running. Mimics
    /// the populated layout — title block, compact controls, search,
    /// and a few content rows — so the page doesn't appear to
    /// pop content in from a blank canvas.
    private var topicsLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                DashboardSkeletonBlock(width: 260, height: 28, cornerRadius: 7)
                DashboardSkeletonBlock(width: 180, height: 12, cornerRadius: 5)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    DashboardSkeletonBlock(width: 82, height: 28, cornerRadius: 7)
                    DashboardSkeletonBlock(width: 92, height: 28, cornerRadius: 7)
                    DashboardSkeletonBlock(width: 82, height: 28, cornerRadius: 7)
                    DashboardSkeletonBlock(width: 90, height: 28, cornerRadius: 7)
                }
                Spacer(minLength: 12)
                DashboardSkeletonBlock(width: 220, height: 28, cornerRadius: 8)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)

            DashboardSkeletonRows(count: 6)
        }
        .frame(maxWidth: .infinity)
    }

    private func topicHeader(_ topic: DashboardTopicOption) -> some View {
        Text(topic.name)
            .font(PidgyDashboardTheme.pageTitleFont)
            .tracking(-0.6)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 10, trailing: 8))
    }

    private func controlsRow(_ topic: DashboardTopicOption) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(DashboardTopicCommand.allCases) { command in
                    Button {
                        selectedCommand = command
                    } label: {
                        HStack(spacing: 5) {
                            Text(command.label)
                            if let count = commandCount(command), count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(selectedCommand == command ? PidgyDashboardTheme.secondary : PidgyDashboardTheme.tertiary)
                            }
                        }
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .foregroundStyle(selectedCommand == command ? PidgyDashboardTheme.primary : PidgyDashboardTheme.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedCommand == command ? PidgyDashboardTheme.raised : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pidgyHoverRow(cornerRadius: 7)
                }
            }

            Spacer(minLength: 12)

            DashboardSearchField(
                placeholder: "Search \(topic.name)",
                text: $searchText,
                size: .compact
            )
            .frame(width: 220)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 22, trailing: 8))
    }

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch selectedCommand {
            case .allChats:
                if isSemanticSearchActive {
                    semanticResultsSection(title: "Matches")
                } else {
                    chatSection
                }
            case .catchUp:
                catchUpSection
            case .openTasks:
                topicTasksSection
            case .needsReply:
                topicRepliesSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var catchUpSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                DashboardSectionLabel("Catch me up")
                Spacer()
                if isLoadingSemanticResults {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !semanticCatchUpSections.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(semanticCatchUpSections.enumerated()), id: \.element.id) { index, section in
                        if index > 0 {
                            Divider()
                                .overlay(PidgyDashboardTheme.rule.opacity(0.6))
                                .padding(.vertical, 14)
                        }
                        DashboardCatchUpSectionRow(
                            section: section,
                            chatById: chatById,
                            onOpenChat: onOpenChat,
                            onExplore: {
                                // Dig into this theme: switch to search mode
                                // with the headline as the query — the fused
                                // FTS+vector search surfaces its messages
                                // and evidence in this topic's scope.
                                selectedCommand = .allChats
                                searchText = section.headline
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            } else if isLoadingSemanticResults {
                DashboardCatchUpSkeleton()
                    .padding(.top, 4)
            } else if let semanticSearchError {
                DashboardSmallEmptyText(semanticSearchError)
            }

            semanticResultsSection(title: "Evidence", emptyText: "No indexed context found for this topic yet.")
        }
    }

    private var topicTasksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if displayedTopicTasks.isEmpty {
                DashboardSmallEmptyText(trimmedSearchText.isEmpty ? "No open tasks for this topic." : "No tasks matched this search.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayedTopicTasks.prefix(80)) { task in
                        Button {
                            onOpenTask(task)
                        } label: {
                            DashboardTaskRow(task: task, isSelected: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var topicRepliesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if displayedTopicReplies.isEmpty {
                DashboardSmallEmptyText(trimmedSearchText.isEmpty ? "No reply queue items for this topic." : "No replies matched this search.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayedTopicReplies.prefix(80), id: \.chat.id) { item in
                        Button {
                            onOpenReply(item)
                        } label: {
                            DashboardAttentionRow(item: item, isSelected: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func semanticResultsSection(
        title: String,
        emptyText: String = "No semantic matches for this search yet."
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DashboardSectionLabel(title)
                Spacer()
                if isLoadingSemanticResults && selectedCommand != .catchUp {
                    ProgressView()
                        .controlSize(.small)
                } else if !semanticResults.isEmpty {
                    Text("\(semanticResults.count)")
                        .font(PidgyDashboardTheme.monoCaptionFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }
            }

            if semanticResults.isEmpty && isLoadingSemanticResults {
                DashboardSkeletonRows(count: selectedCommand == .catchUp ? 4 : 7)
            } else if semanticResults.isEmpty {
                DashboardSmallEmptyText(semanticSearchError ?? emptyText)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(semanticResults.prefix(36)) { result in
                        Button {
                            onOpenChat(result.chatId)
                        } label: {
                            DashboardTopicSemanticResultRow(
                                result: result,
                                chat: allChats.first { $0.id == result.chatId }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if topicChatSignals.isEmpty {
                DashboardSmallEmptyText("No matching chats for this filter.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(topicChatSignals.prefix(80)) { signal in
                        Button {
                            onOpenChat(signal.chatId)
                        } label: {
                            DashboardTopicChatRow(signal: signal)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var allChats: [TGChat] {
        var seen = Set<Int64>()
        return sourceChats.filter {
            seen.insert($0.id).inserted
        }
    }

    private func selectDefaultTopicIfNeeded() {
        guard selectedTopicId == nil || !topicOptions.contains(where: { $0.id == selectedTopicId }) else { return }
        selectedTopicId = topicOptions.first?.id
    }

    private func rebuildTopicChatSignals() async {
        guard let topic = selectedTopic else {
            cachedTopicTasks = []
            cachedTopicReplies = []
            cachedTopicChatSignals = []
            cachedActiveTaskCount = 0
            cachedActiveReplyCount = 0
            return
        }

        let query = topicMatchQuery(for: topic)
        let matchingTasks = tasks.filter { task in
            if topic.isUncategorized {
                return task.topicId == nil
            }
            return task.topicId == topic.id
                || task.topicName?.caseInsensitiveCompare(topic.name) == .orderedSame
                || matchesTopic(
                    query,
                    text: [task.title, task.summary, task.suggestedAction, task.chatTitle]
                        .joined(separator: " ")
                )
        }
        let matchingReplies = followUpItems.filter { item in
            matchesTopic(query, text: item.chat.title)
                || matchesTopic(query, text: item.suggestedAction)
                || matchesTopic(query, text: item.lastMessage.displayText)
        }
        let signals = buildTopicChatSignals(
            query: query,
            matchingTasks: matchingTasks,
            matchingReplies: matchingReplies,
            applyCommandFilter: false,
            applySearchFilter: false
        )
        guard !Task.isCancelled else { return }
        cachedTopicTasks = matchingTasks
        cachedTopicReplies = matchingReplies
        cachedTopicChatSignals = signals
        cachedActiveTaskCount = matchingTasks.lazy.filter(\.isActionableNow).count
        cachedActiveReplyCount = matchingReplies.lazy.filter { $0.category == .onMe }.count
    }

    private func commandAllows(_ signal: DashboardTopicChatSignal) -> Bool {
        switch selectedCommand {
        case .allChats, .catchUp:
            return true
        case .openTasks:
            return signal.openTaskCount > 0
        case .needsReply:
            return signal.replyCount > 0
        }
    }

    private func commandCount(_ command: DashboardTopicCommand) -> Int? {
        switch command {
        case .allChats:
            return semanticScopeChatSignals.count
        case .catchUp:
            return nil
        case .openTasks:
            return cachedActiveTaskCount
        case .needsReply:
            return cachedActiveReplyCount
        }
    }

    private func matchesSearch(_ signal: DashboardTopicChatSignal) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return signal.title.lowercased().contains(query)
            || signal.snippet.lowercased().contains(query)
            || signal.typeLabel.lowercased().contains(query)
    }

    private func matchesQuery(fields: [String]) -> Bool {
        let query = normalizedTopicText(trimmedSearchText)
        guard !query.isEmpty else { return true }
        let terms = query.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !terms.isEmpty else { return true }
        let haystack = normalizedTopicText(fields.joined(separator: " "))
        return terms.contains { haystack.contains($0) }
    }

    private func topicMatchQuery(for topic: DashboardTopicOption) -> DashboardTopicMatchQuery {
        DashboardTopicMatchQuery(name: topic.name, rationale: topic.rationale)
    }

    private func matchesTopic(_ query: DashboardTopicMatchQuery, text: String?) -> Bool {
        text.map(query.matches) ?? false
    }

    private func normalizedTopicText(_ text: String) -> String {
        var normalized = ""
        normalized.reserveCapacity(text.utf8.count)
        var needsSeparator = false

        for byte in text.lowercased().utf8 {
            let isASCIILetter = byte >= 97 && byte <= 122
            let isASCIIDigit = byte >= 48 && byte <= 57
            if isASCIILetter || isASCIIDigit {
                if needsSeparator, !normalized.isEmpty {
                    normalized.append(" ")
                }
                normalized.unicodeScalars.append(UnicodeScalar(byte))
                needsSeparator = false
            } else if !normalized.isEmpty {
                needsSeparator = true
            }
        }

        return normalized
    }

    private func loadRecentMessages() async {
        guard selectedCommand == .catchUp else {
            recentMessages = []
            return
        }

        let chatIds = Array(semanticScopeChatSignals.prefix(60).map(\.chatId))
        guard !chatIds.isEmpty else {
            recentMessages = []
            return
        }

        isLoadingRecentMessages = true
        defer { isLoadingRecentMessages = false }

        let startDate = Calendar.current.date(byAdding: .day, value: -14, to: Date())
        let records = await DatabaseManager.shared.loadSearchableMessages(
            chatIds: chatIds,
            limit: 140,
            startDate: startDate
        )
        let titleByChatId = Dictionary(uniqueKeysWithValues: topicChatSignals.map { ($0.chatId, $0.title) })
        var seen = Set<String>()
        recentMessages = records
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.id > $1.id
            }
            .compactMap { record -> DashboardPersonRecentMessage? in
                let key = "\(record.chatId):\(record.id)"
                guard seen.insert(key).inserted else { return nil }
                let text = (record.textContent ?? record.mediaTypeRaw.map { "[\($0)]" } ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return DashboardPersonRecentMessage(
                    chatId: record.chatId,
                    chatTitle: titleByChatId[record.chatId] ?? "Chat \(record.chatId)",
                    senderName: record.isOutgoing ? "You" : (record.senderName ?? "Unknown"),
                    text: text,
                    date: record.date,
                    isOutgoing: record.isOutgoing
                )
            }
    }

    private func runSemanticSearchIfNeeded() async {
        semanticRequestGeneration += 1
        let generation = semanticRequestGeneration
        // Installed IMMEDIATELY after taking the ticket, before ANY early
        // return: if this (newest) request exits on a guard while an older
        // request had set the spinner, the older one's stale-generation defer
        // refuses to clear it — only the current owner can, so it must always
        // do so on the way out, whichever path it takes.
        defer {
            if generation == semanticRequestGeneration {
                isLoadingSemanticResults = false
            }
        }
        guard isSemanticSearchActive, let selectedTopic else {
            semanticResults = []
            semanticSummary = nil
            semanticSearchError = nil
            return
        }

        if !trimmedSearchText.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !Task.isCancelled else { return }

        // Topic discovery must search the whole local index. Restricting this
        // call to chats that already matched the topic name made semantic
        // topics circular: "Billing problems" could never discover a card
        // decline unless that chat had already been labelled Billing.
        // The topic definition remains part of typed searches, so those can
        // also discover relevant chats that were never labelled beforehand.
        let chatIds: [Int64]? = nil

        let query = semanticQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            semanticResults = []
            semanticSummary = nil
            semanticSearchError = nil
            return
        }

        isLoadingSemanticResults = true
        semanticSearchError = nil
        if selectedCommand != .catchUp {
            semanticSummary = nil
        }

        let ftsHits = await runFTSVariantsFused(
            rawQuery: query,
            chatIds: chatIds,
            limit: 70,
            telegramService: telegramService
        )
        guard !Task.isCancelled else { return }

        let vectorHits = await telegramService.localVectorSearch(
            query: query,
            chatIds: chatIds,
            limit: 70
        )
        guard !Task.isCancelled else { return }

        let results = DashboardTopicSemanticSearchEngine.results(
            query: selectedCommand == .catchUp ? trimmedSearchText : query,
            mode: selectedCommand == .catchUp ? .catchUp : .search,
            topicName: selectedTopic.name,
            chatTitles: chatTitleById,
            ftsHits: ftsHits,
            vectorHits: vectorHits,
            recentMessages: recentMessages,
            tasks: topicTasks,
            replies: topicReplies,
            limit: selectedCommand == .catchUp ? 18 : 36
        )

        guard generation == semanticRequestGeneration, !Task.isCancelled else { return }
        semanticResults = results
        if selectedCommand == .catchUp {
            let outcome = await makeCatchUpSummary(topic: selectedTopic, results: results)
            // The AI call is the longest await — re-check before publishing so
            // a topic switched mid-summary never shows the OLD topic's recap
            // (or its error banner). makeCatchUpSummary returns outcome as
            // DATA; only the generation owner here mutates UI state.
            guard generation == semanticRequestGeneration, !Task.isCancelled else { return }
            if outcome.aiFailed {
                semanticSearchError = "AI recap failed, showing local evidence."
            }
            semanticSummary = outcome.text
        }
    }

    private func makeCatchUpSummary(
        topic: DashboardTopicOption,
        results: [DashboardTopicSemanticSearchResult]
    ) async -> (text: String?, aiFailed: Bool) {
        guard !results.isEmpty else { return (nil, false) }
        guard aiService.isConfigured else {
            return (localCatchUpSummary(results), false)
        }

        let snippets = results.prefix(16).enumerated().map { index, result in
            MessageSnippet(
                messageId: result.messageId ?? Int64(index + 1),
                senderFirstName: result.senderName.split(separator: " ").first.map(String.init) ?? result.senderName,
                text: "\(result.source.rawValue) | person: \(result.senderName) | chat/group: \(result.chatTitle) | \(result.title) - \(result.snippet)",
                relativeTimestamp: result.date.map(DateFormatting.compactRelativeTime(from:)) ?? "unknown",
                chatId: result.chatId,
                chatName: result.chatTitle
            )
        }

        let prompt = """
        You are Pidgy, a concise Telegram workspace copilot.
        Summarize only the provided evidence for the topic "\(topic.name)" as 2-4 THEMED sections.
        Return one section per line, EXACTLY this pipe-separated format, nothing else:
        CATEGORY | Headline | KeyPerson | Detail
        - CATEGORY: a 1-2 word ALL-CAPS theme (e.g. PLANS, PARTNERSHIP, DECISIONS, ASKS, LAUNCH, LOGISTICS, OTHER)
        - Headline: a short editorial line, max 8 words, sentence case, no trailing period (e.g. "Road trip plans, but light on specifics")
        - KeyPerson: the main person's first name for this theme, or "-" if none
        - Detail: ONE sentence of what happened; mention people and the chat naturally
        Group related evidence under the same theme. No markdown, no bullets, no extra lines.
        Do not invent facts. If evidence is thin, say so in a Detail.
        """

        do {
            return (try await aiService.summarizeSnippets(snippets, prompt: prompt), false)
        } catch is CancellationError {
            // Topic switched mid-call — not a failure. Publishing the local
            // fallback here is exactly the stale-overwrite bug; stay silent
            // and let the newer request own the UI.
            return (nil, false)
        } catch let error as URLError where error.code == .cancelled {
            // URLSession surfaces a cancelled task as NSURLErrorCancelled,
            // not CancellationError — same situation, same silence.
            return (nil, false)
        } catch {
            // Genuine failure — but this helper never touches UI state; the
            // caller publishes the error only if its generation still owns
            // the screen.
            return (localCatchUpSummary(results), true)
        }
    }

    private func localCatchUpSummary(_ results: [DashboardTopicSemanticSearchResult]) -> String {
        results.prefix(5).map { result in
            "- \(result.senderName) in \(result.chatTitle): \(result.title) - \(result.snippet)"
        }
        .joined(separator: "\n")
    }
}
