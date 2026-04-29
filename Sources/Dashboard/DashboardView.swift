import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var aiService: AIService
    @StateObject private var attentionStore = AttentionStore.shared
    @StateObject private var taskIndex = TaskIndexCoordinator.shared
    @AppStorage(AppConstants.Preferences.includeBotsInAISearchKey) private var includeBotsInAISearch = false

    @State private var selectedPage: DashboardPage? = .dashboard
    @State private var selectedTaskId: Int64?
    @State private var selectedReplyChatId: Int64?
    @State private var selectedPersonId: Int64?
    @State private var topContacts: [RelationGraph.Node] = []
    @State private var staleContacts: [RelationGraph.Node] = []

    var body: some View {
        HStack(spacing: 0) {
            DashboardSidebar(
                selection: $selectedPage,
                topics: taskIndex.topics,
                tasks: taskIndex.tasks,
                replyCount: attentionStore.followUpItems.filter { $0.category == .onMe }.count,
                openTaskCount: taskIndex.tasks.filter { $0.status == .open }.count,
                peopleCount: topContacts.count,
                visibleChatCount: telegramService.visibleChats.count,
                lastRefreshAt: taskIndex.lastRefreshAt
            )

            VStack(spacing: 0) {
                DashboardTopBar(
                    page: selectedPage ?? .dashboard,
                    lastRefreshAt: taskIndex.lastRefreshAt,
                    isRefreshing: taskIndex.isRefreshing,
                    onRefresh: refreshDashboard
                )

                selectedPageView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PidgyDashboardTheme.paper)
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1120, minHeight: 720)
        .task {
            attentionStore.loadFollowUps(
                telegramService: telegramService,
                aiService: aiService,
                includeBots: includeBotsInAISearch
            )
            telegramService.scheduleBotMetadataWarm(
                for: telegramService.visibleChats,
                includeBots: includeBotsInAISearch
            )
            await taskIndex.loadFromStore(
                telegramService: telegramService,
                includeBotsInAISearch: includeBotsInAISearch
            )
            await loadPeople()
        }
        .onChange(of: includeBotsInAISearch) {
            telegramService.scheduleBotMetadataWarm(
                for: telegramService.visibleChats,
                includeBots: includeBotsInAISearch
            )
            Task {
                await taskIndex.setBotInclusion(
                    includeBotsInAISearch,
                    telegramService: telegramService
                )
                attentionStore.loadFollowUps(
                    telegramService: telegramService,
                    aiService: aiService,
                    includeBots: includeBotsInAISearch
                )
            }
        }
        .onChange(of: telegramService.botMetadataRefreshVersion) {
            Task {
                await taskIndex.setBotInclusion(
                    includeBotsInAISearch,
                    telegramService: telegramService
                )
            }
        }
        .onChange(of: visibleChatIDs) {
            telegramService.scheduleBotMetadataWarm(
                for: telegramService.visibleChats,
                includeBots: includeBotsInAISearch
            )
            Task {
                await taskIndex.setBotInclusion(
                    includeBotsInAISearch,
                    telegramService: telegramService
                )
                attentionStore.loadFollowUps(
                    telegramService: telegramService,
                    aiService: aiService,
                    includeBots: includeBotsInAISearch
                )
            }
        }
    }

    private var visibleChatIDs: [Int64] {
        telegramService.visibleChats.map(\.id).sorted()
    }

    @ViewBuilder
    private var selectedPageView: some View {
        switch selectedPage ?? .dashboard {
        case .dashboard:
            DashboardHomePage(
                tasks: taskIndex.tasks,
                followUpItems: attentionStore.followUpItems,
                aiConfigured: aiService.isConfigured,
                onOpenTask: { task in
                    selectedPage = .tasks
                    selectedTaskId = task.id
                },
                onOpenReply: { item in
                    selectedPage = .replyQueue
                    selectedReplyChatId = item.chat.id
                }
            )

        case .replyQueue:
            DashboardReplyQueuePage(
                items: attentionStore.followUpItems,
                isLoading: attentionStore.isFollowUpsLoading,
                processedCount: attentionStore.pipelineProcessedCount,
                totalCount: attentionStore.pipelineTotalCount,
                selectedChatId: $selectedReplyChatId,
                onRefresh: {
                    attentionStore.loadFollowUps(
                        telegramService: telegramService,
                        aiService: aiService,
                        includeBots: includeBotsInAISearch,
                        force: true
                    )
                },
                onOpenChat: { chat in openChat(chat) }
            )

        case .tasks:
            DashboardTasksPage(
                tasks: taskIndex.tasks,
                topics: taskIndex.topics,
                evidenceByTaskId: taskIndex.evidenceByTaskId,
                isRefreshing: taskIndex.isRefreshing,
                aiConfigured: aiService.isConfigured,
                selectedTaskId: $selectedTaskId,
                onRefresh: {
                    Task {
                        await taskIndex.refreshNow(
                            telegramService: telegramService,
                            aiService: aiService,
                            includeBotsInAISearch: includeBotsInAISearch,
                            forceRescan: true
                        )
                    }
                },
                onUpdateStatus: { task, status, snoozedUntil in
                    Task {
                        await taskIndex.updateStatus(
                            task: task,
                            status: status,
                            snoozedUntil: snoozedUntil
                        )
                    }
                },
                onOpenChat: { chatId in openChat(chatId: chatId) }
            )

        case .people:
            DashboardPeoplePage(
                topContacts: topContacts,
                staleContacts: staleContacts,
                tasks: taskIndex.tasks,
                followUpItems: attentionStore.followUpItems,
                selectedPersonId: $selectedPersonId,
                onOpenTask: { task in
                    selectedPage = .tasks
                    selectedTaskId = task.id
                },
                onOpenChat: { chat in openChat(chat) }
            )
        }
    }

    private func loadPeople() async {
        async let top = RelationGraph.shared.topContacts(category: nil, limit: 40)
        async let stale = RelationGraph.shared.staleContacts(
            olderThan: AppConstants.FollowUp.staleThresholdSeconds,
            category: nil
        )
        topContacts = await top
        staleContacts = Array(await stale.prefix(24))
    }

    private func refreshDashboard() {
        attentionStore.loadFollowUps(
            telegramService: telegramService,
            aiService: aiService,
            includeBots: includeBotsInAISearch,
            force: true
        )

        Task {
            await loadPeople()
            await taskIndex.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: includeBotsInAISearch,
                forceRescan: true
            )
        }
    }

    private func openChat(chatId: Int64) {
        guard let chat = (telegramService.visibleChats.first { $0.id == chatId }
            ?? telegramService.chats.first { $0.id == chatId }) else {
            return
        }
        openChat(chat)
    }

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
            if !opened, let fallback = URL(string: "tg://resolve?domain=telegram") {
                _ = DeepLinkGenerator.openInTelegram(fallback)
            }
        }
    }
}

private enum DashboardPage: String, CaseIterable, Identifiable, Hashable {
    case dashboard = "Dashboard"
    case replyQueue = "Reply queue"
    case tasks = "Tasks"
    case people = "People"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dashboard:
            return "house"
        case .replyQueue:
            return "tray"
        case .tasks:
            return "checkmark.square"
        case .people:
            return "person.2"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard:
            return "What to do now"
        case .replyQueue:
            return "Chats that need attention"
        case .tasks:
            return "Extracted from chat"
        case .people:
            return "Contacts and context"
        }
    }
}

private struct DashboardTopBar: View {
    let page: DashboardPage
    let lastRefreshAt: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(page.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text("· \(page.subtitle)")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let lastRefreshAt {
                Text("Updated \(DateFormatting.compactRelativeTime(from: lastRefreshAt)) ago")
                    .font(.system(size: 12))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }

            Button(action: onRefresh) {
                HStack(spacing: 7) {
                    Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                    Text(isRefreshing ? "Refreshing" : "Refresh")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(height: 30)
                .padding(.horizontal, 12)
                .background(DashboardCapsuleBackground())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .help(refreshHelp)
        }
        .padding(.horizontal, PidgyDashboardTheme.pageHorizontalPadding)
        .frame(height: 50)
        .background(PidgyDashboardTheme.paper)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(height: 1)
        }
    }

    private var refreshHelp: String {
        if let lastRefreshAt {
            return "Last refreshed \(DateFormatting.compactRelativeTime(from: lastRefreshAt)) ago"
        }
        return "Refresh dashboard"
    }
}

private struct DashboardSidebar: View {
    @Binding var selection: DashboardPage?
    let topics: [DashboardTopic]
    let tasks: [DashboardTask]
    let replyCount: Int
    let openTaskCount: Int
    let peopleCount: Int
    let visibleChatCount: Int
    let lastRefreshAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PidgyMascotMark(size: 26)
                Text("Pidgy")
                    .font(.system(size: 19, weight: .semibold, design: .serif))
                    .foregroundStyle(PidgyDashboardTheme.primary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 20)

            VStack(spacing: 2) {
                ForEach(DashboardPage.allCases) { page in
                    sidebarButton(page, count: count(for: page))
                }
            }
            .padding(.horizontal, 10)

            if !topics.isEmpty || uncategorizedCount > 0 {
                Text("TOPICS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .padding(.horizontal, 22)
                    .padding(.top, 30)
                    .padding(.bottom, 8)

                VStack(spacing: 1) {
                    ForEach(topics.sorted { $0.rank < $1.rank }.prefix(6)) { topic in
                        topicRow(
                            title: topic.name,
                            count: openTaskCount(topicId: topic.id),
                            tint: PidgyDashboardTheme.topicTint(topic.id)
                        )
                    }

                    if uncategorizedCount > 0 {
                        topicRow(
                            title: "Uncategorized",
                            count: uncategorizedCount,
                            tint: PidgyDashboardTheme.tertiary
                        )
                    }
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Rectangle()
                    .fill(PidgyDashboardTheme.rule)
                    .frame(height: 1)

                HStack(spacing: 10) {
                    DashboardInitialsAvatar(label: "You", size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PidgyDashboardTheme.primary)
                        Text("\(visibleChatCount) chats indexed · \(syncText)")
                            .font(.system(size: 12))
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .background(PidgyDashboardTheme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(width: 1)
        }
    }

    private func sidebarButton(_ page: DashboardPage, count: Int?) -> some View {
        Button {
            selection = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(page.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(selection == page ? PidgyDashboardTheme.brand : PidgyDashboardTheme.secondary)
                }
            }
            .foregroundStyle(selection == page ? PidgyDashboardTheme.brand : PidgyDashboardTheme.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selection == page ? PidgyDashboardTheme.brand.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func topicRow(title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PidgyDashboardTheme.primary)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(PidgyDashboardTheme.secondary)
        }
        .frame(height: 30)
    }

    private func count(for page: DashboardPage) -> Int? {
        switch page {
        case .dashboard:
            return nil
        case .replyQueue:
            return replyCount
        case .tasks:
            return openTaskCount
        case .people:
            return peopleCount
        }
    }

    private var syncText: String {
        guard let lastRefreshAt else { return "not synced" }
        return "synced \(DateFormatting.compactRelativeTime(from: lastRefreshAt)) ago"
    }

    private var uncategorizedCount: Int {
        tasks.filter { $0.status == .open && $0.topicId == nil }.count
    }

    private func openTaskCount(topicId: Int64) -> Int {
        tasks.filter { $0.status == .open && $0.topicId == topicId }.count
    }
}

private struct DashboardHomePage: View {
    let tasks: [DashboardTask]
    let followUpItems: [FollowUpItem]
    let aiConfigured: Bool
    let onOpenTask: (DashboardTask) -> Void
    let onOpenReply: (FollowUpItem) -> Void

    private var feedItems: [DashboardFeedItem] {
        let taskItems = tasks
            .filter(\.isActionableNow)
            .map(DashboardFeedItem.task)
        let replyItems = followUpItems.map(DashboardFeedItem.reply)
        return (taskItems + replyItems)
            .sorted {
                if $0.section.rank != $1.section.rank {
                    return $0.section.rank < $1.section.rank
                }
                return $0.date > $1.date
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What to do now")
                        .font(PidgyDashboardTheme.pageTitleFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                    Text("\(feedItems.count) active item\(feedItems.count == 1 ? "" : "s")")
                        .font(PidgyDashboardTheme.pageSubtitleFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }
                .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
                .padding(.bottom, PidgyDashboardTheme.headerBottomPadding)

                if feedItems.isEmpty {
                    DashboardEmptyState(
                        systemImage: aiConfigured ? "checkmark.circle" : "sparkles",
                        title: aiConfigured ? "Nothing urgent right now" : "Task extraction is off",
                        subtitle: aiConfigured
                            ? "Reply queue and tasks will appear here when Pidgy finds active work."
                            : "Reply queue still works. Connect an AI provider to fill tasks."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                } else {
                    ForEach(DashboardFeedSection.allCases) { section in
                        let items = feedItems.filter { $0.section == section }
                        if !items.isEmpty {
                            DashboardSectionLabel(section.title)
                                .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
                                .padding(.top, section == .onFire ? 0 : 24)
                                .padding(.bottom, 6)

                            VStack(spacing: 0) {
                                ForEach(items.prefix(section == .onFire ? 5 : 10)) { item in
                                    Button {
                                        switch item.kind {
                                        case .task(let task):
                                            onOpenTask(task)
                                        case .reply(let reply):
                                            onOpenReply(reply)
                                        }
                                    } label: {
                                        DashboardFeedRow(item: item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: PidgyDashboardTheme.pageMaxWidth, alignment: .leading)
            .padding(.top, PidgyDashboardTheme.pageTopPadding)
            .padding(.horizontal, PidgyDashboardTheme.pageHorizontalPadding)
            .padding(.bottom, PidgyDashboardTheme.pageBottomPadding)
            .frame(maxWidth: .infinity)
        }
        .background(PidgyDashboardTheme.paper)
    }
}

private struct DashboardReplyQueuePage: View {
    let items: [FollowUpItem]
    let isLoading: Bool
    let processedCount: Int
    let totalCount: Int
    @Binding var selectedChatId: Int64?
    let onRefresh: () -> Void
    let onOpenChat: (TGChat) -> Void

    @State private var filter: DashboardReplyFilter = .needsYou

    private var filteredItems: [FollowUpItem] {
        switch filter {
        case .needsYou:
            return items.filter { $0.category == .onMe }
        case .allOpen:
            return items
        case .muted:
            return items.filter { $0.category == .quiet }
        }
    }

    private var selectedItem: FollowUpItem? {
        selectedChatId.flatMap { id in filteredItems.first { $0.chat.id == id } }
    }

    var body: some View {
        if let selectedItem {
            HStack(spacing: 0) {
                compactList
                    .frame(minWidth: 460)

                DashboardReplyDetail(
                    item: selectedItem,
                    onRefresh: onRefresh,
                    onOpenChat: onOpenChat,
                    onClose: { selectedChatId = nil }
                )
                .frame(width: 420)
            }
        } else {
            centeredList
        }
    }

    private var centeredList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                queueRows
            }
            .frame(maxWidth: PidgyDashboardTheme.pageMaxWidth, alignment: .leading)
            .padding(.top, PidgyDashboardTheme.pageTopPadding)
            .padding(.horizontal, PidgyDashboardTheme.pageHorizontalPadding)
            .padding(.bottom, PidgyDashboardTheme.pageBottomPadding)
            .frame(maxWidth: .infinity)
        }
    }

    private var compactList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 14)

            ScrollView {
                queueRows
                    .padding(.horizontal, 14)
                    .padding(.bottom, 28)
            }
        }
        .background(PidgyDashboardTheme.paper)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reply queue")
                    .font(PidgyDashboardTheme.pageTitleFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                if isLoading, totalCount > 0 {
                    Text("Analyzing \(processedCount)/\(totalCount) chats")
                        .font(PidgyDashboardTheme.pageSubtitleFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }
            }

            Spacer()

            DashboardSegmentedReplyFilter(
                selection: $filter,
                needsCount: items.filter { $0.category == .onMe }.count,
                allCount: items.count,
                mutedCount: items.filter { $0.category == .quiet }.count
            )
        }
        .padding(selectedItem == nil ? EdgeInsets(top: 0, leading: 8, bottom: 22, trailing: 8) : EdgeInsets())
    }

    private var queueRows: some View {
        VStack(spacing: 0) {
            if filteredItems.isEmpty {
                DashboardEmptyState(
                    systemImage: isLoading ? "arrow.triangle.2.circlepath" : "checkmark.circle",
                    title: isLoading ? "Loading reply queue" : "No matching chats",
                    subtitle: isLoading ? "Pidgy is checking recent conversations." : "Try a different tab or refresh."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            } else {
                ForEach(filteredItems, id: \.chat.id) { item in
                    Button {
                        selectedChatId = item.chat.id
                    } label: {
                        DashboardAttentionRow(
                            item: item,
                            isSelected: selectedChatId == item.chat.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct DashboardTasksPage: View {
    private static let uncategorizedTopicId: Int64 = Int64.min

    let tasks: [DashboardTask]
    let topics: [DashboardTopic]
    let evidenceByTaskId: [Int64: [DashboardTaskSourceMessage]]
    let isRefreshing: Bool
    let aiConfigured: Bool
    @Binding var selectedTaskId: Int64?
    let onRefresh: () -> Void
    let onUpdateStatus: (DashboardTask, DashboardTaskStatus, Date?) -> Void
    let onOpenChat: (Int64) -> Void

    @State private var statusFilter: DashboardStatusFilter = .open
    @State private var selectedTopicId: Int64?
    @State private var selectedChatId: Int64?
    @State private var personQuery = ""

    private var filteredTasks: [DashboardTask] {
        let matching = tasks.filter { task in
            if let status = statusFilter.status, task.status != status {
                return false
            }
            if selectedTopicId == Self.uncategorizedTopicId, task.topicId != nil {
                return false
            }
            if let selectedTopicId, selectedTopicId != Self.uncategorizedTopicId, task.topicId != selectedTopicId {
                return false
            }
            if let selectedChatId, task.chatId != selectedChatId {
                return false
            }
            if !personQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let query = personQuery.lowercased()
                return task.personName.lowercased().contains(query)
                    || task.ownerName.lowercased().contains(query)
                    || task.chatTitle.lowercased().contains(query)
            }
            return true
        }
        return DashboardTaskFilter.sortByRecentActivity(matching)
    }

    private var selectedTask: DashboardTask? {
        selectedTaskId.flatMap { id in tasks.first { $0.id == id } }
    }

    private var chatOptions: [DashboardChatOption] {
        let grouped = Dictionary(grouping: tasks, by: \.chatId)
        return grouped.map { chatId, tasks in
            DashboardChatOption(chatId: chatId, title: tasks.first?.chatTitle ?? "Chat \(chatId)")
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var openCount: Int { tasks.filter { $0.status == .open }.count }
    private var snoozedCount: Int { tasks.filter { $0.status == .snoozed }.count }
    private var doneCount: Int { tasks.filter { $0.status == .done }.count }
    private var ignoredCount: Int { tasks.filter { $0.status == .ignored }.count }

    var body: some View {
        if let selectedTask {
            HStack(spacing: 0) {
                compactList
                    .frame(minWidth: 500)

                DashboardTaskDetail(
                    task: selectedTask,
                    evidence: evidenceByTaskId[selectedTask.id] ?? [],
                    isRefreshing: isRefreshing,
                    onRefresh: onRefresh,
                    onUpdateStatus: onUpdateStatus,
                    onOpenChat: onOpenChat,
                    onClose: { selectedTaskId = nil }
                )
                .frame(width: 420)
            }
        } else {
            centeredList
        }
    }

    private var centeredList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                filterBar
                    .padding(.bottom, 10)
                taskRows
            }
            .frame(maxWidth: PidgyDashboardTheme.pageMaxWidth, alignment: .leading)
            .padding(.top, PidgyDashboardTheme.pageTopPadding)
            .padding(.horizontal, PidgyDashboardTheme.pageHorizontalPadding)
            .padding(.bottom, PidgyDashboardTheme.pageBottomPadding)
            .frame(maxWidth: .infinity)
        }
    }

    private var compactList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Spacer()
                Text("\(filteredTasks.count) shown")
                    .font(.system(size: 12))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 12)

            filterBar
                .padding(.horizontal, 28)
                .padding(.bottom, 10)

            ScrollView {
                taskRows
                    .padding(.horizontal, 14)
                    .padding(.bottom, 28)
            }
        }
        .background(PidgyDashboardTheme.paper)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tasks")
                    .font(PidgyDashboardTheme.pageTitleFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text(aiConfigured ? "\(filteredTasks.count) matching tasks" : "Connect AI to extract tasks")
                    .font(PidgyDashboardTheme.pageSubtitleFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            Spacer()
            Button(action: onRefresh) {
                Label(isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: 30)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .background(DashboardCapsuleBackground())
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 14)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            DashboardStatusSegments(
                selection: $statusFilter,
                openCount: openCount,
                snoozedCount: snoozedCount,
                doneCount: doneCount,
                ignoredCount: ignoredCount,
                allCount: tasks.count
            )

            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(width: 1, height: 20)
                .padding(.horizontal, 2)

            Menu {
                Button("All topics") { selectedTopicId = nil }
                Button("Uncategorized") { selectedTopicId = Self.uncategorizedTopicId }
                ForEach(topics) { topic in
                    Button(topic.name) { selectedTopicId = topic.id }
                }
            } label: {
                DashboardFilterCapsule(title: "Topic", value: selectedTopicLabel)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)

            Menu {
                Button("All chats") { selectedChatId = nil }
                ForEach(chatOptions) { option in
                    Button(option.title) { selectedChatId = option.chatId }
                }
            } label: {
                DashboardFilterCapsule(title: "Chat", value: selectedChatLabel)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Image(systemName: "person")
                    .font(.system(size: 11))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                TextField("Person", text: $personQuery)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .frame(width: 90)
            }
            .frame(height: 28)
            .padding(.horizontal, 9)
            .background(DashboardCapsuleBackground())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var taskRows: some View {
        VStack(spacing: 0) {
            if filteredTasks.isEmpty {
                DashboardEmptyState(
                    systemImage: aiConfigured ? "tray" : "sparkles",
                    title: aiConfigured ? "No tasks match" : "AI task extraction is off",
                    subtitle: aiConfigured
                        ? "Change a filter or refresh after recent sync catches up."
                        : "Connect an AI provider in Settings to populate this page."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            } else {
                ForEach(filteredTasks) { task in
                    Button {
                        selectedTaskId = task.id
                    } label: {
                        DashboardTaskRow(
                            task: task,
                            isSelected: selectedTaskId == task.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var selectedTopicLabel: String {
        if selectedTopicId == nil { return "All topics" }
        if selectedTopicId == Self.uncategorizedTopicId { return "Uncategorized" }
        return topics.first { $0.id == selectedTopicId }?.name ?? "Topic"
    }

    private var selectedChatLabel: String {
        guard let selectedChatId else { return "All chats" }
        return chatOptions.first { $0.chatId == selectedChatId }?.title ?? "Chat"
    }
}

private struct DashboardPeoplePage: View {
    let topContacts: [RelationGraph.Node]
    let staleContacts: [RelationGraph.Node]
    let tasks: [DashboardTask]
    let followUpItems: [FollowUpItem]
    @Binding var selectedPersonId: Int64?
    let onOpenTask: (DashboardTask) -> Void
    let onOpenChat: (TGChat) -> Void

    @State private var filter: DashboardPeopleFilter = .top

    private var visibleContacts: [RelationGraph.Node] {
        switch filter {
        case .top:
            return topContacts
        case .youOwe:
            return allContacts.filter { !replies(for: $0).isEmpty }
        case .stale:
            return staleContacts
        }
    }

    private var allContacts: [RelationGraph.Node] {
        var seen = Set<Int64>()
        return (topContacts + staleContacts).filter { contact in
            seen.insert(contact.entityId).inserted
        }
    }

    private var selectedContact: RelationGraph.Node? {
        selectedPersonId.flatMap { id in allContacts.first { $0.entityId == id } }
    }

    var body: some View {
        if let selectedContact {
            HStack(spacing: 0) {
                peopleList
                    .frame(width: 340)

                DashboardPersonDetail(
                    contact: selectedContact,
                    tasks: tasksForSelectedContact,
                    followUpItems: repliesForSelectedContact,
                    onOpenTask: onOpenTask,
                    onOpenChat: onOpenChat,
                    onClose: { selectedPersonId = nil }
                )
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    centeredHeader
                    peopleRows
                }
                .frame(maxWidth: PidgyDashboardTheme.pageMaxWidth, alignment: .leading)
                .padding(.top, PidgyDashboardTheme.pageTopPadding)
                .padding(.horizontal, PidgyDashboardTheme.pageHorizontalPadding)
                .padding(.bottom, PidgyDashboardTheme.pageBottomPadding)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var peopleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardPeopleTabs(
                selection: $filter,
                topCount: topContacts.count,
                owedCount: allContacts.filter { !replies(for: $0).isEmpty }.count,
                staleCount: staleContacts.count
            )
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PidgyDashboardTheme.rule.opacity(0.7))
                    .frame(height: 1)
            }

            ScrollView {
                peopleRows
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }
        }
        .background(PidgyDashboardTheme.paper)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(width: 1)
        }
    }

    private var centeredHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("People")
                .font(PidgyDashboardTheme.pageTitleFont)
                .foregroundStyle(PidgyDashboardTheme.primary)
            Spacer()
            DashboardPeopleTabs(
                selection: $filter,
                topCount: topContacts.count,
                owedCount: allContacts.filter { !replies(for: $0).isEmpty }.count,
                staleCount: staleContacts.count
            )
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 22)
    }

    private var peopleRows: some View {
        VStack(spacing: 0) {
            if visibleContacts.isEmpty {
                DashboardEmptyState(
                    systemImage: "person.2",
                    title: "No people here yet",
                    subtitle: "People context appears after recent chats are indexed."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            } else {
                ForEach(visibleContacts, id: \.entityId) { contact in
                    Button {
                        selectedPersonId = contact.entityId
                    } label: {
                        DashboardPersonRow(
                            contact: contact,
                            replyCount: replies(for: contact).count,
                            taskCount: tasks(for: contact).count,
                            isSelected: selectedPersonId == contact.entityId
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var tasksForSelectedContact: [DashboardTask] {
        guard let selectedContact else { return [] }
        return tasks(for: selectedContact)
    }

    private var repliesForSelectedContact: [FollowUpItem] {
        guard let selectedContact else { return [] }
        return replies(for: selectedContact)
    }

    private func tasks(for contact: RelationGraph.Node) -> [DashboardTask] {
        let name = contact.bestDisplayName.lowercased()
        return tasks.filter { task in
            task.personName.lowercased().contains(name)
                || task.ownerName.lowercased().contains(name)
                || task.chatTitle.lowercased().contains(name)
        }
    }

    private func replies(for contact: RelationGraph.Node) -> [FollowUpItem] {
        followUpItems.filter { item in
            switch item.chat.chatType {
            case .privateChat(let userId):
                if userId == contact.entityId { return true }
            default:
                break
            }
            let name = contact.bestDisplayName.lowercased()
            return item.chat.title.lowercased().contains(name)
                || (item.lastMessage.senderName?.lowercased().contains(name) ?? false)
        }
    }
}

private struct DashboardReplyDetail: View {
    let item: FollowUpItem?
    let onRefresh: () -> Void
    let onOpenChat: (TGChat) -> Void
    let onClose: () -> Void

    var body: some View {
        DashboardDetailPane(onClose: onClose) {
            if let item {
                DashboardDetailCover {
                    DashboardTopicChip(text: item.category.rawValue, tint: categoryTint(item.category))
                    Text(item.chat.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(item.chat.chatType.displayName)
                        Text("·")
                        Text(item.lastMessage.relativeDate)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                }

                DashboardDetailSection(title: "Suggested action") {
                    Text(item.suggestedAction ?? "No suggested action.")
                        .font(.system(size: 13))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineSpacing(3)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PidgyDashboardTheme.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(PidgyDashboardTheme.rule)
                        )
                }

                DashboardDetailSection(title: "Latest message") {
                    Text(item.lastMessage.displayText)
                        .font(.system(size: 13))
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(8)
                        .lineSpacing(3)
                }
            } else {
                DashboardEmptyState(
                    systemImage: "arrowshape.turn.up.left",
                    title: "Nothing selected",
                    subtitle: "Choose a conversation to inspect its latest context."
                )
            }
        } actions: {
            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.primary)

            Button {
                if let item { onOpenChat(item.chat) }
            } label: {
                Label("Open in chat", systemImage: "paperplane")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(DashboardCapsuleBackground())
        }
    }
}

private struct DashboardTaskDetail: View {
    let task: DashboardTask?
    let evidence: [DashboardTaskSourceMessage]
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onUpdateStatus: (DashboardTask, DashboardTaskStatus, Date?) -> Void
    let onOpenChat: (Int64) -> Void
    let onClose: () -> Void

    var body: some View {
        DashboardDetailPane(onClose: onClose) {
            if let task {
                DashboardDetailCover {
                    DashboardTopicChip(text: task.topicName ?? "Uncategorized", tint: topicTint(for: task))
                    Text(task.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        DashboardPriorityDot(priority: task.priority)
                        Text("\(task.priority.label) priority")
                            .font(.system(size: 12, weight: .medium))
                        Text("·")
                        Text(task.chatTitle)
                        if !displayPerson(for: task).isEmpty {
                            Text("·")
                            Text(displayPerson(for: task))
                                .fontWeight(.medium)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                }

                if !task.suggestedAction.isEmpty {
                    DashboardDetailSection(
                        title: "Suggested action",
                        trailing: "conf \(Int((task.confidence * 100).rounded()))%"
                    ) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Pidgy says")
                                .font(.system(size: 13, weight: .regular))
                                .italic()
                                .foregroundStyle(PidgyDashboardTheme.blue)
                            Text(task.suggestedAction)
                                .font(.system(size: 13))
                                .foregroundStyle(PidgyDashboardTheme.primary)
                                .lineSpacing(3)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PidgyDashboardTheme.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(PidgyDashboardTheme.rule)
                        )
                    }
                }

                DashboardDetailSection(title: "Summary") {
                    Text(task.summary.isEmpty ? "No summary available." : task.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineSpacing(3)
                }

                DashboardDetailSection(title: "Evidence", trailing: "\(evidence.count) snippet\(evidence.count == 1 ? "" : "s")") {
                    VStack(spacing: 8) {
                        if evidence.isEmpty {
                            Text("No source snippets were stored for this task.")
                                .font(.system(size: 13))
                                .foregroundStyle(PidgyDashboardTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(evidence, id: \.self) { source in
                                DashboardEvidenceRow(source: source)
                            }
                        }
                    }
                }
            } else {
                DashboardEmptyState(
                    systemImage: isRefreshing ? "arrow.triangle.2.circlepath" : "tray",
                    title: isRefreshing ? "Refreshing tasks" : "No task selected",
                    subtitle: isRefreshing ? "Pidgy is extracting current work from indexed messages." : "Choose a task to inspect evidence and act on it."
                )
            }
        } actions: {
            if let task {
                Button {
                    onUpdateStatus(task, .done, nil)
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.plain)

                Button {
                    onUpdateStatus(task, .snoozed, Date().addingTimeInterval(24 * 3600))
                } label: {
                    Label("Snooze", systemImage: "moon")
                }
                .buttonStyle(.plain)

                Button {
                    onUpdateStatus(task, .ignored, nil)
                } label: {
                    Label("Ignore", systemImage: "xmark")
                }
                .buttonStyle(.plain)

                Button {
                    onOpenChat(task.chatId)
                } label: {
                    Label("Open", systemImage: "paperplane")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(DashboardCapsuleBackground())
            } else {
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .foregroundStyle(PidgyDashboardTheme.primary)
    }

    private func displayPerson(for task: DashboardTask) -> String {
        task.personName.isEmpty ? task.ownerName : task.personName
    }
}

private struct DashboardPersonDetail: View {
    @EnvironmentObject private var telegramService: TelegramService

    let contact: RelationGraph.Node?
    let tasks: [DashboardTask]
    let followUpItems: [FollowUpItem]
    let onOpenTask: (DashboardTask) -> Void
    let onOpenChat: (TGChat) -> Void
    let onClose: () -> Void

    var body: some View {
        DashboardDetailPane(onClose: onClose) {
            if let contact {
                DashboardDetailCover {
                    HStack(alignment: .top, spacing: 14) {
                        DashboardTelegramAvatar(
                            chat: privateChat(for: contact),
                            fallbackTitle: contact.bestDisplayName,
                            size: 44
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            Text(contact.bestDisplayName)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(PidgyDashboardTheme.primary)
                            Text("\(contact.category) · score \(Int(contact.interactionScore.rounded()))")
                                .font(.system(size: 12))
                                .foregroundStyle(PidgyDashboardTheme.secondary)
                            Text("last touched \(contact.lastInteractionAt.map(DateFormatting.compactRelativeTime(from:)) ?? "never") ago")
                                .font(.system(size: 12))
                                .foregroundStyle(PidgyDashboardTheme.secondary)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 0) {
                    DashboardPersonColumn(title: "Tasks", count: tasks.count) {
                        if tasks.isEmpty {
                            DashboardSmallEmptyText("No open tasks tied to this person.")
                        } else {
                            ForEach(tasks.prefix(8)) { task in
                                Button {
                                    onOpenTask(task)
                                } label: {
                                    DashboardMiniTaskRow(task: task)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Rectangle()
                        .fill(PidgyDashboardTheme.rule)
                        .frame(width: 1)

                    DashboardPersonColumn(title: "Reply queue", count: followUpItems.count) {
                        if followUpItems.isEmpty {
                            DashboardSmallEmptyText("Nothing pending.")
                        } else {
                            ForEach(followUpItems.prefix(8), id: \.chat.id) { item in
                                Button {
                                    onOpenChat(item.chat)
                                } label: {
                                    DashboardMiniReplyRow(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

            } else {
                DashboardEmptyState(
                    systemImage: "person.2",
                    title: "No people yet",
                    subtitle: "Relation graph data appears here after indexing."
                )
            }
        } actions: {
            if let item = followUpItems.first {
                Button {
                    onOpenChat(item.chat)
                } label: {
                    Label("Open latest chat", systemImage: "paperplane")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(DashboardCapsuleBackground())
            }
        }
        .foregroundStyle(PidgyDashboardTheme.primary)
    }

    private func privateChat(for contact: RelationGraph.Node) -> TGChat? {
        let allChats = telegramService.visibleChats + telegramService.chats
        return allChats.first { chat in
            guard case .privateChat(let userId) = chat.chatType else { return false }
            return userId == contact.entityId
        }
    }
}

private enum PidgyDashboardTheme {
    static let paper = Color(red: 0.068, green: 0.071, blue: 0.078)
    static let sidebar = Color(red: 0.045, green: 0.049, blue: 0.058)
    static let raised = Color(red: 0.100, green: 0.108, blue: 0.124)
    static let deep = Color(red: 0.054, green: 0.059, blue: 0.070)
    static let primary = Color(red: 0.918, green: 0.934, blue: 0.960)
    static let secondary = Color(red: 0.596, green: 0.640, blue: 0.700)
    static let tertiary = Color(red: 0.386, green: 0.426, blue: 0.486)
    static let rule = Color(red: 0.918, green: 0.934, blue: 0.960).opacity(0.085)
    static let brand = Color(red: 0.338, green: 0.611, blue: 1.000)
    static let blue = Color(red: 0.560, green: 0.728, blue: 1.000)
    static let green = Color(red: 0.500, green: 0.742, blue: 0.596)
    static let red = Color(red: 0.875, green: 0.408, blue: 0.408)
    static let yellow = Color(red: 0.810, green: 0.715, blue: 0.392)
    static let purple = Color(red: 0.644, green: 0.560, blue: 0.900)

    static let pageMaxWidth: CGFloat = 860
    static let pageTopPadding: CGFloat = 42
    static let pageHorizontalPadding: CGFloat = 28
    static let pageBottomPadding: CGFloat = 44
    static let headerBottomPadding: CGFloat = 22
    static let rowHorizontalPadding: CGFloat = 10
    static let rowAvatarSize: CGFloat = 28
    static let pageTitleFont = Font.system(size: 28, weight: .semibold)
    static let pageSubtitleFont = Font.system(size: 13)

    static func topicTint(_ seed: Int64) -> Color {
        let palette = [
            Color(red: 0.560, green: 0.728, blue: 1.000),
            Color(red: 0.440, green: 0.780, blue: 0.900),
            Color(red: 0.500, green: 0.742, blue: 0.596),
            Color(red: 0.644, green: 0.560, blue: 0.900),
            Color(red: 0.820, green: 0.520, blue: 0.780),
            Color(red: 0.640, green: 0.690, blue: 0.760)
        ]
        return palette[abs(Int(seed % Int64(palette.count)))]
    }
}

private struct PidgyMascotMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.82, green: 0.90, blue: 1.0),
                            Color(red: 0.58, green: 0.53, blue: 0.84)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.92))
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(Color.white.opacity(0.35))
        )
    }
}

private struct DashboardInitialsAvatar: View {
    let label: String
    let size: CGFloat

    var body: some View {
        Text(initials)
            .font(.system(size: max(9, size * 0.34), weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                avatarColor.opacity(0.95),
                                avatarColor.opacity(0.62)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(Circle().stroke(Color.white.opacity(0.12)))
    }

    private var avatarColor: Color {
        PidgyDashboardTheme.topicTint(Int64(abs(label.hashValue % 997)))
    }

    private var initials: String {
        let words = label.split(separator: " ")
        if words.count >= 2 {
            return "\(words[0].prefix(1))\(words[1].prefix(1))".uppercased()
        }
        return String(label.prefix(2)).uppercased()
    }
}

private struct DashboardTelegramAvatar: View {
    @EnvironmentObject private var telegramService: TelegramService
    @ObservedObject private var photoManager = ChatPhotoManager.shared

    let chat: TGChat?
    let fallbackTitle: String
    var size = PidgyDashboardTheme.rowAvatarSize

    var body: some View {
        AvatarView(
            initials: chat?.initials ?? fallbackInitials,
            colorIndex: chat?.colorIndex ?? abs(fallbackTitle.hashValue % 8),
            size: size,
            photo: chat.flatMap { photoManager.photos[$0.id] }
        )
        .onAppear(perform: requestPhotoIfNeeded)
    }

    private var fallbackInitials: String {
        let words = fallbackTitle.split(separator: " ")
        if words.count >= 2 {
            return "\(words[0].prefix(1))\(words[1].prefix(1))".uppercased()
        }
        return String(fallbackTitle.prefix(2)).uppercased()
    }

    private func requestPhotoIfNeeded() {
        guard let chat, let fileId = chat.smallPhotoFileId else { return }
        photoManager.requestPhoto(chatId: chat.id, fileId: fileId, telegramService: telegramService)
    }
}

private struct DashboardFeedRow: View {
    @EnvironmentObject private var telegramService: TelegramService

    let item: DashboardFeedItem

    var body: some View {
        HStack(spacing: 12) {
            DashboardTelegramAvatar(
                chat: chat,
                fallbackTitle: item.avatarLabel,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.person)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PidgyDashboardTheme.primary.opacity(0.78))
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                    Text(item.chat)
                        .font(.system(size: 12))
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                    if let topic = item.topic {
                        Text("·")
                            .foregroundStyle(PidgyDashboardTheme.tertiary)
                        Text(topic)
                            .font(.system(size: 12))
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 14)

            Text(DateFormatting.compactRelativeTime(from: item.date))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(item.section == .onFire ? PidgyDashboardTheme.brand : PidgyDashboardTheme.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: 54)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule.opacity(0.8))
                .frame(height: 1)
                .padding(.leading, PidgyDashboardTheme.rowAvatarSize + 14)
        }
    }

    private var chat: TGChat? {
        switch item.kind {
        case .reply(let reply):
            return reply.chat
        case .task(let task):
            return telegramService.visibleChats.first { $0.id == task.chatId }
                ?? telegramService.chats.first { $0.id == task.chatId }
        }
    }
}

private struct DashboardAttentionRow: View {
    let item: FollowUpItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(categoryTint(item.category))
                .frame(width: 6, height: 6)

            DashboardTelegramAvatar(
                chat: item.chat,
                fallbackTitle: personName,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(personName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                    Text(item.chat.title)
                        .font(.system(size: 13))
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                    Text("· \(item.chat.chatType.displayName)")
                        .font(.system(size: 13))
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }

                Text(item.suggestedAction ?? item.lastMessage.displayText)
                    .font(.system(size: 13))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(DateFormatting.compactRelativeTime(from: item.lastMessage.date))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(item.category == .onMe ? PidgyDashboardTheme.brand : PidgyDashboardTheme.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: 62)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? PidgyDashboardTheme.brand.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var personName: String {
        item.chat.chatType.isPrivate ? item.chat.title : (item.lastMessage.senderName ?? item.chat.title)
    }
}

private struct DashboardTaskRow: View {
    @EnvironmentObject private var telegramService: TelegramService

    let task: DashboardTask
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DashboardTelegramAvatar(
                chat: chat,
                fallbackTitle: avatarLabel,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(task.status == .done ? PidgyDashboardTheme.secondary : PidgyDashboardTheme.primary)
                    .lineLimit(1)
                    .strikethrough(task.status == .done)

                HStack(spacing: 7) {
                    Text(displayPerson)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                    Text("· \(task.chatTitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(DateFormatting.dashboardListTimestamp(from: task.latestSourceDate ?? task.updatedAt))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? PidgyDashboardTheme.brand.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var chat: TGChat? {
        telegramService.visibleChats.first { $0.id == task.chatId }
            ?? telegramService.chats.first { $0.id == task.chatId }
    }

    private var avatarLabel: String {
        task.personName.isEmpty ? task.chatTitle : task.personName
    }

    private var displayPerson: String {
        task.personName.isEmpty ? task.ownerName : task.personName
    }
}

private struct DashboardPersonRow: View {
    @EnvironmentObject private var telegramService: TelegramService

    let contact: RelationGraph.Node
    let replyCount: Int
    let taskCount: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            DashboardTelegramAvatar(
                chat: privateChat,
                fallbackTitle: contact.bestDisplayName,
                size: PidgyDashboardTheme.rowAvatarSize
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.bestDisplayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                Text(contact.lastInteractionAt.map { "last \(DateFormatting.compactRelativeTime(from: $0)) ago" } ?? contact.category)
                    .font(.system(size: 12))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if replyCount > 0 {
                HStack(spacing: 5) {
                    DashboardPriorityDot(color: PidgyDashboardTheme.yellow)
                    Text("\(replyCount) owed")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(PidgyDashboardTheme.yellow)
            } else {
                Text("\(taskCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? PidgyDashboardTheme.brand.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var privateChat: TGChat? {
        let allChats = telegramService.visibleChats + telegramService.chats
        return allChats.first { chat in
            guard case .privateChat(let userId) = chat.chatType else { return false }
            return userId == contact.entityId
        }
    }
}

private struct DashboardMiniTaskRow: View {
    let task: DashboardTask

    var body: some View {
        HStack(spacing: 10) {
            DashboardPriorityDot(priority: task.priority)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                Text(task.status.label)
                    .font(.system(size: 11))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            Spacer()
            Text(task.latestSourceDate.map(DateFormatting.compactRelativeTime(from:)) ?? "-")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(PidgyDashboardTheme.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct DashboardMiniReplyRow: View {
    let item: FollowUpItem

    var body: some View {
        HStack(spacing: 10) {
            DashboardPriorityDot(color: categoryTint(item.category))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.suggestedAction ?? item.lastMessage.displayText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                Text(item.chat.title)
                    .font(.system(size: 11))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(DateFormatting.compactRelativeTime(from: item.lastMessage.date))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(PidgyDashboardTheme.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct DashboardEvidenceRow: View {
    let source: DashboardTaskSourceMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(source.senderName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                Text(DateFormatting.compactRelativeTime(from: source.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                Spacer()
                Text("#\(source.messageId)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
            }
            Text(source.text)
                .font(.system(size: 13))
                .italic()
                .foregroundStyle(PidgyDashboardTheme.primary)
                .lineLimit(4)
                .lineSpacing(2)
        }
        .padding(10)
        .background(PidgyDashboardTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
    }
}

private struct DashboardDetailPane<Content: View, Actions: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if !(Actions.self == EmptyView.self) {
                HStack(spacing: 8) {
                    actions
                }
                .font(.system(size: 12, weight: .medium))
                .padding(16)
                .background(PidgyDashboardTheme.deep)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(PidgyDashboardTheme.rule)
                        .frame(height: 1)
                }
            }
        }
        .background(PidgyDashboardTheme.raised)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(width: 1)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.secondary)
            .padding(10)
        }
    }
}

private struct DashboardDetailCover<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(PidgyDashboardTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(height: 1)
        }
    }
}

private struct DashboardDetailSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }
            }
            content
        }
        .padding(22)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(height: 1)
        }
    }
}

private struct DashboardPersonColumn<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text("\(count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(18)
    }
}

private struct DashboardTopicChip: View {
    let text: String
    let tint: Color
    var small = false

    var body: some View {
        Text(text)
            .font(.system(size: small ? 10.5 : 11, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, small ? 7 : 8)
            .padding(.vertical, small ? 2 : 3)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.32)))
    }
}

private struct DashboardPriorityDot: View {
    var priority: DashboardTaskPriority?
    var color: Color?

    var body: some View {
        Circle()
            .fill(color ?? priority.map(priorityColor) ?? PidgyDashboardTheme.secondary)
            .frame(width: 6, height: 6)
    }
}

private struct DashboardSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(PidgyDashboardTheme.secondary)
    }
}

private struct DashboardEmptyState: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(PidgyDashboardTheme.tertiary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PidgyDashboardTheme.primary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(28)
    }
}

private struct DashboardSmallEmptyText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(PidgyDashboardTheme.secondary)
            .padding(.vertical, 6)
    }
}

private struct DashboardCapsuleBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(PidgyDashboardTheme.raised)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PidgyDashboardTheme.rule)
            )
    }
}

private struct DashboardFilterCapsule: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
            Text("\(title):")
                .font(.system(size: 12, weight: .medium))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(PidgyDashboardTheme.secondary)
        .frame(height: 28)
        .padding(.horizontal, 10)
        .background(DashboardCapsuleBackground())
    }
}

private struct DashboardSegmentedReplyFilter: View {
    @Binding var selection: DashboardReplyFilter
    let needsCount: Int
    let allCount: Int
    let mutedCount: Int

    var body: some View {
        HStack(spacing: 2) {
            segment(.needsYou, count: needsCount)
            segment(.allOpen, count: allCount)
            segment(.muted, count: mutedCount)
        }
    }

    private func segment(_ filter: DashboardReplyFilter, count: Int) -> some View {
        Button {
            selection = filter
        } label: {
            HStack(spacing: 6) {
                Text(filter.label)
                Text("\(count)")
                    .foregroundStyle(selection == filter ? PidgyDashboardTheme.secondary : PidgyDashboardTheme.tertiary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .foregroundStyle(selection == filter ? PidgyDashboardTheme.primary : PidgyDashboardTheme.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection == filter ? PidgyDashboardTheme.raised : Color.clear)
                    .shadow(color: selection == filter ? Color.black.opacity(0.22) : Color.clear, radius: 6, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardStatusSegments: View {
    @Binding var selection: DashboardStatusFilter
    let openCount: Int
    let snoozedCount: Int
    let doneCount: Int
    let ignoredCount: Int
    let allCount: Int

    var body: some View {
        HStack(spacing: 2) {
            segment(.open, count: openCount)
            segment(.snoozed, count: snoozedCount)
            segment(.done, count: doneCount)
            segment(.ignored, count: ignoredCount)
            segment(.all, count: allCount)
        }
    }

    private func segment(_ filter: DashboardStatusFilter, count: Int) -> some View {
        Button {
            selection = filter
        } label: {
            HStack(spacing: 5) {
                Text(filter.label)
                Text("\(count)")
                    .foregroundStyle(selection == filter ? PidgyDashboardTheme.secondary : PidgyDashboardTheme.tertiary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .foregroundStyle(selection == filter ? PidgyDashboardTheme.primary : PidgyDashboardTheme.secondary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selection == filter ? PidgyDashboardTheme.raised : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardPeopleTabs: View {
    @Binding var selection: DashboardPeopleFilter
    let topCount: Int
    let owedCount: Int
    let staleCount: Int

    var body: some View {
        HStack(spacing: 0) {
            tab(.top, count: topCount)
            tab(.youOwe, count: owedCount)
            tab(.stale, count: staleCount)
        }
    }

    private func tab(_ filter: DashboardPeopleFilter, count: Int) -> some View {
        Button {
            selection = filter
        } label: {
            HStack(spacing: 5) {
                Text(filter.label)
                Text("\(count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selection == filter ? PidgyDashboardTheme.primary : PidgyDashboardTheme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selection == filter ? PidgyDashboardTheme.blue : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }
}

private enum DashboardReplyFilter: String, CaseIterable, Identifiable {
    case needsYou
    case allOpen
    case muted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .needsYou:
            return "Needs you"
        case .allOpen:
            return "All open"
        case .muted:
            return "Muted"
        }
    }
}

private enum DashboardStatusFilter: String, CaseIterable, Identifiable {
    case open
    case snoozed
    case done
    case ignored
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:
            return "All"
        case .open:
            return "Open"
        case .snoozed:
            return "Snoozed"
        case .done:
            return "Done"
        case .ignored:
            return "Ignored"
        }
    }

    var status: DashboardTaskStatus? {
        switch self {
        case .all:
            return nil
        case .open:
            return .open
        case .snoozed:
            return .snoozed
        case .done:
            return .done
        case .ignored:
            return .ignored
        }
    }
}

private enum DashboardPeopleFilter: String, CaseIterable, Identifiable {
    case top
    case youOwe
    case stale

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top:
            return "Top"
        case .youOwe:
            return "You owe"
        case .stale:
            return "Going stale"
        }
    }
}

private enum DashboardFeedSection: String, CaseIterable, Identifiable {
    case onFire
    case thisWeek
    case later

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onFire:
            return "On fire"
        case .thisWeek:
            return "This week"
        case .later:
            return "Later"
        }
    }

    var rank: Int {
        switch self {
        case .onFire:
            return 0
        case .thisWeek:
            return 1
        case .later:
            return 2
        }
    }
}

private enum DashboardFeedKind {
    case task(DashboardTask)
    case reply(FollowUpItem)
}

private struct DashboardFeedItem: Identifiable {
    let id: String
    let title: String
    let person: String
    let chat: String
    let topic: String?
    let avatarLabel: String
    let date: Date
    let section: DashboardFeedSection
    let kind: DashboardFeedKind

    static func task(_ task: DashboardTask) -> DashboardFeedItem {
        DashboardFeedItem(
            id: "task-\(task.id)",
            title: task.title,
            person: task.personName.isEmpty ? task.ownerName : task.personName,
            chat: task.chatTitle,
            topic: task.topicName ?? "Uncategorized",
            avatarLabel: task.personName.isEmpty ? task.chatTitle : task.personName,
            date: task.latestSourceDate ?? task.updatedAt,
            section: section(for: task.priority),
            kind: .task(task)
        )
    }

    static func reply(_ item: FollowUpItem) -> DashboardFeedItem {
        let person = item.chat.chatType.isPrivate ? item.chat.title : item.lastMessage.senderName ?? item.chat.title
        return DashboardFeedItem(
            id: "reply-\(item.chat.id)",
            title: item.suggestedAction ?? item.lastMessage.displayText,
            person: person,
            chat: item.chat.chatType.displayName,
            topic: nil,
            avatarLabel: person,
            date: item.lastMessage.date,
            section: section(for: item.category),
            kind: .reply(item)
        )
    }

    private static func section(for priority: DashboardTaskPriority) -> DashboardFeedSection {
        switch priority {
        case .high:
            return .onFire
        case .medium:
            return .thisWeek
        case .low:
            return .later
        }
    }

    private static func section(for category: FollowUpItem.Category) -> DashboardFeedSection {
        switch category {
        case .onMe:
            return .onFire
        case .onThem:
            return .thisWeek
        case .quiet:
            return .later
        }
    }
}

private struct DashboardChatOption: Identifiable {
    let chatId: Int64
    let title: String

    var id: Int64 { chatId }
}

private extension RelationGraph.Node {
    var bestDisplayName: String {
        displayName?.isEmpty == false ? displayName! : (username ?? "Unknown")
    }
}

private func categoryTint(_ category: FollowUpItem.Category) -> Color {
    switch category {
    case .onMe:
        return PidgyDashboardTheme.brand
    case .onThem:
        return PidgyDashboardTheme.blue
    case .quiet:
        return PidgyDashboardTheme.secondary
    }
}

private func topicTint(for task: DashboardTask) -> Color {
    if let topicId = task.topicId {
        return PidgyDashboardTheme.topicTint(topicId)
    }
    return PidgyDashboardTheme.secondary
}

private func priorityColor(_ priority: DashboardTaskPriority) -> Color {
    switch priority {
    case .high:
        return PidgyDashboardTheme.red
    case .medium:
        return PidgyDashboardTheme.yellow
    case .low:
        return PidgyDashboardTheme.secondary
    }
}
