import SwiftUI

struct DashboardTopicsPage: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var aiService: AIService

    let topics: [DashboardTopic]
    let tasks: [DashboardTask]
    let followUpItems: [FollowUpItem]
    @Binding var selectedTopicId: Int64?
    let onOpenTask: (DashboardTask) -> Void
    let onOpenReply: (FollowUpItem) -> Void
    let onOpenChat: (Int64) -> Void

    @State private var searchText = ""
    @State private var selectedCommand: DashboardTopicCommand = .allChats
    @State private var cachedTopicChatSignals: [DashboardTopicChatSignal] = []
    @State private var recentMessages: [DashboardPersonRecentMessage] = []
    @State private var isLoadingRecentMessages = false
    @State private var semanticResults: [DashboardTopicSemanticSearchResult] = []
    @State private var semanticSummary: String?
    @State private var semanticSearchError: String?
    @State private var isLoadingSemanticResults = false

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
        guard let selectedTopic else { return [] }
        return tasks.filter { task in
            if selectedTopic.isUncategorized {
                return task.topicId == nil
            }
            return task.topicId == selectedTopic.id
                || task.topicName?.caseInsensitiveCompare(selectedTopic.name) == .orderedSame
        }
    }

    private var topicReplies: [FollowUpItem] {
        guard let selectedTopic else { return [] }
        return followUpItems.filter { item in
            matchesTopic(selectedTopic, text: item.chat.title)
                || matchesTopic(selectedTopic, text: item.suggestedAction)
                || matchesTopic(selectedTopic, text: item.lastMessage.displayText)
        }
    }

    private var topicChatSignals: [DashboardTopicChatSignal] {
        cachedTopicChatSignals
    }

    private var isSemanticSearchActive: Bool {
        selectedCommand == .catchUp || (selectedCommand == .allChats && !trimmedSearchText.isEmpty)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var semanticQuery: String {
        if !trimmedSearchText.isEmpty {
            return trimmedSearchText
        }
        guard let selectedTopic else { return "" }
        return "recent important updates decisions asks open loops \(selectedTopic.name)"
    }

    private var semanticSearchKey: String {
        let chatKey = semanticScopeChatSignals.prefix(120).map(\.chatId).sorted().map(String.init).joined(separator: ",")
        let recentKey = recentMessages.prefix(20).map { "\($0.chatId):\($0.date.timeIntervalSince1970)" }.joined(separator: "|")
        return "\(selectedTopic?.id ?? 0):\(selectedCommand.rawValue):\(searchText):\(chatKey):\(recentKey):\(tasks.count):\(followUpItems.count)"
    }

    private var semanticScopeChatSignals: [DashboardTopicChatSignal] {
        buildTopicChatSignals(applyCommandFilter: false, applySearchFilter: false)
    }

    private var chatTitleById: [Int64: String] {
        Dictionary(uniqueKeysWithValues: semanticScopeChatSignals.map { ($0.chatId, $0.title) })
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

    private var semanticSummaryBullets: [DashboardCatchUpBullet] {
        DashboardCatchUpBullet.parse(semanticSummary ?? "")
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
        applyCommandFilter: Bool = true,
        applySearchFilter: Bool = true
    ) -> [DashboardTopicChatSignal] {
        guard let selectedTopic else { return [] }
        let chats = allChats
        let chatById = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        let tasksByChatId = Dictionary(grouping: topicTasks.filter(\.isActionableNow), by: \.chatId)
        let repliesByChatId = Dictionary(grouping: topicReplies, by: { $0.chat.id })

        var chatIds = Set<Int64>()
        chatIds.formUnion(tasksByChatId.keys)
        chatIds.formUnion(repliesByChatId.keys)
        for chat in chats where matchesTopic(selectedTopic, text: chat.title)
            || matchesTopic(selectedTopic, text: chat.lastMessage?.displayText) {
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

    private var filteredRecentMessages: [DashboardPersonRecentMessage] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return recentMessages }
        return recentMessages.filter {
            $0.chatTitle.lowercased().contains(trimmed)
                || $0.senderName.lowercased().contains(trimmed)
                || $0.text.lowercased().contains(trimmed)
        }
    }

    private var activeTaskCount: Int {
        topicTasks.filter(\.isActionableNow).count
    }

    private var activeReplyCount: Int {
        topicReplies.filter { $0.category == .onMe }.count
    }

    private var recentReloadKey: String {
        "\(selectedTopic?.id ?? 0):\(semanticScopeChatSignals.prefix(60).map(\.chatId).sorted().map(String.init).joined(separator: ","))"
    }

    private var topicSignalRefreshKey: String {
        let topicKey = "\(selectedTopic?.id ?? 0):\(selectedTopic?.name ?? ""):\(selectedCommand.rawValue):\(searchText)"
        let taskKey = tasks
            .map { "\($0.id):\($0.status.rawValue):\($0.topicId ?? 0):\($0.chatId):\($0.updatedAt.timeIntervalSince1970)" }
            .joined(separator: "|")
        let replyKey = followUpItems
            .map { "\($0.chat.id):\($0.category.rawValue):\($0.lastMessage.id)" }
            .joined(separator: "|")
        let chatKey = allChats
            .map { "\($0.id):\($0.title):\($0.lastMessage?.id ?? 0)" }
            .joined(separator: "|")
        return "\(topicKey)#\(taskKey)#\(replyKey)#\(chatKey)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let selectedTopic {
                    topicHero(selectedTopic)
                    searchBox(selectedTopic)
                    commandRow

                    contentSections
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
            .frame(maxWidth: 760)
            .padding(.top, 70)
            .padding(.horizontal, PidgyDashboardTheme.pageHorizontalPadding)
            .padding(.bottom, PidgyDashboardTheme.pageBottomPadding)
            .frame(maxWidth: .infinity)
        }
        .background(PidgyDashboardTheme.paper)
        .task {
            selectDefaultTopicIfNeeded()
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
    }

    private func topicHero(_ topic: DashboardTopicOption) -> some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(topic.tint.opacity(0.18))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "folder.fill")
                        .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                        .foregroundStyle(topic.tint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(topic.tint.opacity(0.30))
                )

            Text(topic.name)
                .font(PidgyDashboardTheme.topicDisplayTitleFont)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            HStack(spacing: 8) {
                Image(systemName: "person.2")
                    .font(PidgyDashboardTheme.metadataMediumFont)
                Text(summaryLine(for: topic))
                    .font(PidgyDashboardTheme.metadataMediumFont)
            }
            .foregroundStyle(PidgyDashboardTheme.secondary)
            .lineLimit(1)

            if !topic.rationale.isEmpty {
                Text(topic.rationale)
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 560)
            }
        }
    }

    private func searchBox(_ topic: DashboardTopicOption) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(PidgyDashboardTheme.metadataMediumFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
            TextField("Search \(topic.name)", text: $searchText)
                .font(PidgyDashboardTheme.rowTitleFont)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: 620)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(PidgyDashboardTheme.raised.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
    }

    private var commandRow: some View {
        HStack(spacing: 8) {
            ForEach(DashboardTopicCommand.allCases) { command in
                Button {
                    selectedCommand = command
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: command.systemImage)
                            .font(PidgyDashboardTheme.metadataMediumFont)
                        Text(command.label)
                            .font(PidgyDashboardTheme.metadataMediumFont)
                        if let count = commandCount(command), count > 0 {
                            Text("\(count)")
                                .font(PidgyDashboardTheme.monoCaptionFont)
                        }
                    }
                    .foregroundStyle(selectedCommand == command ? PidgyDashboardTheme.blue : PidgyDashboardTheme.secondary)
                    .padding(.horizontal, 4)
                    .frame(height: 28)
                    .background(Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 620)
    }

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 26) {
            switch selectedCommand {
            case .allChats:
                if isSemanticSearchActive {
                    semanticResultsSection(title: "Matches")
                } else {
                    chatSection
                    recentSection
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

            if !semanticSummaryBullets.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(semanticSummaryBullets) { bullet in
                        DashboardCatchUpBulletRow(
                            bullet: bullet,
                            highlightEntities: semanticHighlightEntities,
                            chatById: chatById,
                            onOpenChat: onOpenChat
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            } else if isLoadingSemanticResults {
                DashboardSkeletonTextBlock(lineCount: 5)
                    .padding(.top, 4)
            } else if let semanticSearchError {
                DashboardSmallEmptyText(semanticSearchError)
            }

            semanticResultsSection(title: "Evidence", emptyText: "No indexed context found for this topic yet.")
        }
    }

    private var topicTasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionLabel("Open tasks")
            if displayedTopicTasks.isEmpty {
                DashboardSmallEmptyText(trimmedSearchText.isEmpty ? "No open tasks for this topic." : "No tasks matched this search.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayedTopicTasks.prefix(80)) { task in
                        Button {
                            onOpenTask(task)
                        } label: {
                            DashboardMiniTaskRow(task: task)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var topicRepliesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionLabel("Needs reply")
            if displayedTopicReplies.isEmpty {
                DashboardSmallEmptyText(trimmedSearchText.isEmpty ? "No reply queue items for this topic." : "No replies matched this search.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayedTopicReplies.prefix(80), id: \.chat.id) { item in
                        Button {
                            onOpenReply(item)
                        } label: {
                            DashboardMiniReplyRow(item: item)
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
        VStack(alignment: .leading, spacing: 6) {
            DashboardSectionLabel("Chats")

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

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DashboardSectionLabel("Recent context")
                Spacer()
                if isLoadingRecentMessages {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("\(filteredRecentMessages.count)")
                        .font(PidgyDashboardTheme.monoCaptionFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }
            }

            if filteredRecentMessages.isEmpty && isLoadingRecentMessages {
                DashboardSkeletonRows(count: 5, showTimestamp: false)
            } else if filteredRecentMessages.isEmpty {
                DashboardSmallEmptyText("No indexed recent messages for this topic yet.")
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filteredRecentMessages.prefix(12)) { snippet in
                        DashboardPersonSnippetRow(snippet: snippet)
                    }
                }
            }
        }
    }

    private var allChats: [TGChat] {
        var seen = Set<Int64>()
        return (telegramService.visibleChats + telegramService.chats).filter {
            seen.insert($0.id).inserted
        }
    }

    private func summaryLine(for topic: DashboardTopicOption) -> String {
        let chatCount = semanticScopeChatSignals.count
        let parts = [
            chatCount == 1 ? "1 chat" : "\(chatCount) chats",
            activeTaskCount == 1 ? "1 task" : "\(activeTaskCount) tasks",
            activeReplyCount == 1 ? "1 reply" : "\(activeReplyCount) replies"
        ]
        return parts.joined(separator: " · ")
    }

    private func selectDefaultTopicIfNeeded() {
        guard selectedTopicId == nil || !topicOptions.contains(where: { $0.id == selectedTopicId }) else { return }
        selectedTopicId = topicOptions.first?.id
    }

    private func rebuildTopicChatSignals() async {
        let signals = buildTopicChatSignals()
        guard !Task.isCancelled else { return }
        cachedTopicChatSignals = signals
    }

    private func taskCount(for option: DashboardTopicOption) -> Int {
        tasks.filter { task in
            task.isActionableNow && taskBelongsToTopic(task, option: option)
        }.count
    }

    private func replyCount(for option: DashboardTopicOption) -> Int {
        followUpItems.filter { item in
            item.category == .onMe && (
                matchesTopic(option, text: item.chat.title)
                    || matchesTopic(option, text: item.suggestedAction)
                    || matchesTopic(option, text: item.lastMessage.displayText)
            )
        }.count
    }

    private func taskBelongsToTopic(_ task: DashboardTask, option: DashboardTopicOption) -> Bool {
        if option.isUncategorized {
            return task.topicId == nil
        }
        return task.topicId == option.id
            || task.topicName?.caseInsensitiveCompare(option.name) == .orderedSame
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
            return topicTasks.filter(\.isActionableNow).count
        case .needsReply:
            return topicReplies.filter { $0.category == .onMe }.count
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

    private func matchesTopic(_ topic: DashboardTopicOption, text: String?) -> Bool {
        guard let text else { return false }
        let normalizedText = normalizedTopicText(text)
        guard !normalizedText.isEmpty else { return false }
        let normalizedName = normalizedTopicText(topic.name)
        if normalizedText.contains(normalizedName) {
            return true
        }
        let terms = topicTerms(for: topic)
        if terms.count > 1 {
            return terms.allSatisfy { normalizedText.contains($0) }
        }
        return terms.first.map { normalizedText.contains($0) } ?? false
    }

    private func topicTerms(for topic: DashboardTopicOption) -> [String] {
        let terms = normalizedTopicText(topic.name)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 }
        return terms.isEmpty ? [normalizedTopicText(topic.name)].filter { !$0.isEmpty } : terms
    }

    private func normalizedTopicText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadRecentMessages() async {
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
        guard isSemanticSearchActive, let selectedTopic else {
            semanticResults = []
            semanticSummary = nil
            semanticSearchError = nil
            isLoadingSemanticResults = false
            return
        }

        if !trimmedSearchText.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !Task.isCancelled else { return }

        let scopeSignals = semanticScopeChatSignals
        let chatIds = Array(scopeSignals.prefix(220).map(\.chatId))
        guard !chatIds.isEmpty else {
            semanticResults = []
            semanticSummary = nil
            semanticSearchError = "No chats are attached to this topic yet."
            return
        }

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
        defer { isLoadingSemanticResults = false }

        let ftsHits = await telegramService.localScoredSearch(
            query: query,
            chatIds: chatIds,
            limit: 70
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
            chatTitles: Dictionary(uniqueKeysWithValues: scopeSignals.map { ($0.chatId, $0.title) }),
            ftsHits: ftsHits,
            vectorHits: vectorHits,
            recentMessages: recentMessages,
            tasks: topicTasks,
            replies: topicReplies,
            limit: selectedCommand == .catchUp ? 18 : 36
        )

        semanticResults = results
        if selectedCommand == .catchUp {
            semanticSummary = await makeCatchUpSummary(topic: selectedTopic, results: results)
        }
    }

    private func makeCatchUpSummary(
        topic: DashboardTopicOption,
        results: [DashboardTopicSemanticSearchResult]
    ) async -> String? {
        guard !results.isEmpty else { return nil }
        guard aiService.isConfigured else {
            return localCatchUpSummary(results)
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
        Summarize only the provided evidence for the topic "\(topic.name)".
        Return 3-5 compact plain-text bullets covering important updates, asks, decisions, and open loops.
        Each bullet should mention the relevant person and group/chat name when the evidence contains them.
        Do not use Markdown syntax, bold markers, headings, or labels.
        Do not invent facts. If evidence is thin, say what is thin.
        """

        do {
            return try await aiService.provider.summarize(messages: snippets, prompt: prompt)
        } catch {
            semanticSearchError = "AI recap failed, showing local evidence."
            return localCatchUpSummary(results)
        }
    }

    private func localCatchUpSummary(_ results: [DashboardTopicSemanticSearchResult]) -> String {
        results.prefix(5).map { result in
            "- \(result.senderName) in \(result.chatTitle): \(result.title) - \(result.snippet)"
        }
        .joined(separator: "\n")
    }
}
