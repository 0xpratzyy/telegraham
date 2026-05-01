import SwiftUI

let dashboardUncategorizedTopicId: Int64 = Int64.min

struct DashboardView: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var aiService: AIService
    @StateObject private var attentionStore = AttentionStore.shared
    @StateObject private var taskIndex = TaskIndexCoordinator.shared
    @StateObject private var navigation = DashboardNavigationStore.shared
    @AppStorage(AppConstants.Preferences.includeBotsInAISearchKey) private var includeBotsInAISearch = false

    @State private var selectedTaskId: Int64?
    @State private var selectedReplyChatId: Int64?
    @State private var selectedPersonId: Int64?
    @State private var selectedTopicId: Int64?
    @State private var isAddingTopic = false
    @State private var topContacts: [RelationGraph.Node] = []
    @State private var staleContacts: [RelationGraph.Node] = []
    @State private var allContacts: [RelationGraph.Node] = []
    @State private var sidebarTopicItems: [DashboardSidebarTopicSummary] = []

    var body: some View {
        let currentPage = navigation.selectedPage ?? .dashboard
        let chromePolicy = DashboardChromePolicy.policy(for: currentPage)

        HStack(spacing: 0) {
            if chromePolicy.showsDashboardSidebar {
                DashboardSidebar(
                    selection: $navigation.selectedPage,
                    selectedTopicId: $selectedTopicId,
                    topicItems: sidebarTopicItems,
                    replyCount: attentionStore.followUpItems.filter { $0.category == .onMe }.count,
                    openTaskCount: myOpenTaskCount,
                    peopleCount: allContacts.count,
                    visibleChatCount: telegramService.visibleChats.count,
                    lastRefreshAt: taskIndex.lastRefreshAt,
                    accountUser: telegramService.currentUser,
                    accountName: telegramService.currentUser?.displayName ?? "You",
                    canLogOut: telegramService.currentUser != nil,
                    onAddTopic: { isAddingTopic = true },
                    onOpenPreferences: { navigation.selectedPage = .preferences },
                    onRefresh: refreshDashboard,
                    onLogOut: {
                        Task { try? await telegramService.logOut() }
                    }
                )
            }

            VStack(spacing: 0) {
                if chromePolicy.showsDashboardTopBar {
                    DashboardTopBar(
                        page: currentPage,
                        lastRefreshAt: taskIndex.lastRefreshAt,
                        isRefreshing: taskIndex.isRefreshing,
                        onRefresh: refreshDashboard
                    )
                }

                selectedPageView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PidgyDashboardTheme.paper)
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1120, minHeight: 720)
        .sheet(isPresented: $isAddingTopic) {
            DashboardAddTopicSheet(
                suggestions: addTopicSuggestions,
                onCancel: { isAddingTopic = false },
                onAdd: addTopic
            )
            .preferredColorScheme(.dark)
            .presentationBackground(PidgyDashboardTheme.paper)
        }
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
            async let peopleLoad: Void = loadPeople()
            await taskIndex.loadFromStore(
                telegramService: telegramService,
                includeBotsInAISearch: includeBotsInAISearch
            )
            await peopleLoad
        }
        .task(id: sidebarTopicRefreshKey) {
            await rebuildSidebarTopicItems()
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

    private var myTasks: [DashboardTask] {
        DashboardTaskFilter.apply(
            taskIndex.tasks,
            ownerFilter: .mine,
            currentUser: telegramService.currentUser
        )
    }

    private var myOpenTaskCount: Int {
        myTasks.filter { $0.status == .open }.count
    }

    private var sidebarTopicRefreshKey: String {
        let topicKey = taskIndex.topics
            .map { "\($0.id):\($0.name):\($0.rank):\($0.score):\($0.updatedAt.timeIntervalSince1970)" }
            .joined(separator: "|")
        let chatKey = telegramService.visibleChats
            .map { "\($0.id):\($0.title):\($0.lastMessage?.id ?? 0)" }
            .joined(separator: "|")
        return "\(topicKey)#\(chatKey)"
    }

    private var addTopicSuggestions: [DashboardTopicSuggestion] {
        var suggestionsByName: [String: (name: String, count: Int, score: Double, seed: Int64)] = [:]
        let groupChatIds = Set((telegramService.visibleChats + telegramService.chats).compactMap { chat -> Int64? in
            if case .privateChat = chat.chatType { return nil }
            return chat.id
        })

        func add(_ rawName: String?, count: Int, score: Double, seed: Int64) {
            guard let rawName else { return }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedTopicSuggestionName(name)
            guard !name.isEmpty, !key.isEmpty, !genericTopicSuggestionNames.contains(key) else { return }

            if let existing = suggestionsByName[key] {
                suggestionsByName[key] = (
                    name: existing.name,
                    count: max(existing.count, count),
                    score: max(existing.score, score),
                    seed: existing.seed
                )
            } else {
                suggestionsByName[key] = (name: name, count: count, score: score, seed: seed)
            }
        }

        for item in sidebarTopicItems {
            add(item.name, count: item.chatCount, score: 10_000 + Double(item.chatCount), seed: item.id)
        }

        for topic in taskIndex.topics.prefix(24) {
            let rankBoost = Double(max(0, 200 - topic.rank))
            add(topic.name, count: 0, score: topic.score + rankBoost, seed: topic.id)
        }

        var taskChatCounts: [String: (name: String, count: Int, seed: Int64)] = [:]
        for task in taskIndex.tasks where !task.chatTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard task.status != .ignored else { continue }
            guard groupChatIds.contains(task.chatId) || task.chatTitle.contains("<>") || task.chatTitle.contains("|") else { continue }
            let name = task.chatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedTopicSuggestionName(name)
            guard !key.isEmpty, !genericTopicSuggestionNames.contains(key) else { continue }
            let current = taskChatCounts[key] ?? (name: name, count: 0, seed: task.chatId)
            taskChatCounts[key] = (name: current.name, count: current.count + 1, seed: current.seed)
        }

        for chat in taskChatCounts.values where chat.count >= 2 {
            add(chat.name, count: chat.count, score: Double(chat.count) * 100, seed: chat.seed)
        }

        return suggestionsByName.values
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .prefix(8)
            .map {
                DashboardTopicSuggestion(
                    name: $0.name,
                    count: $0.count,
                    tintSeed: $0.seed
                )
            }
    }

    private var genericTopicSuggestionNames: Set<String> {
        [
            "uncategorized",
            "airdrops",
            "web3",
            "crypto deals",
            "crypto markets",
            "crypto payments",
            "web3 jobs",
            "web3 build",
            "predictions",
            "revenue sharing",
            "launches",
            "partnerships",
            "talent network",
            "payments",
            "nft tools",
            "ai tools",
            "product launches",
            "ugc campaigns"
        ]
    }

    @ViewBuilder
    private var selectedPageView: some View {
        switch navigation.selectedPage ?? .dashboard {
        case .dashboard:
            DashboardHomePage(
                tasks: myTasks,
                followUpItems: attentionStore.followUpItems,
                isLoading: attentionStore.isFollowUpsLoading || taskIndex.isRefreshing,
                aiConfigured: aiService.isConfigured,
                onOpenTask: { task in
                    navigation.selectedPage = .tasks
                    selectedTaskId = task.id
                },
                onOpenReply: { item in
                    navigation.selectedPage = .replyQueue
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
                evidenceByTaskId: taskIndex.evidenceByTaskId,
                ownerPeople: allContacts,
                currentUser: telegramService.currentUser,
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

        case .topics:
            DashboardTopicsPage(
                topics: taskIndex.topics,
                tasks: taskIndex.tasks,
                followUpItems: attentionStore.followUpItems,
                selectedTopicId: $selectedTopicId,
                onOpenTask: { task in
                    navigation.selectedPage = .tasks
                    selectedTaskId = task.id
                },
                onOpenReply: { item in
                    navigation.selectedPage = .replyQueue
                    selectedReplyChatId = item.chat.id
                },
                onOpenChat: { chatId in openChat(chatId: chatId) }
            )

        case .people:
            DashboardPeoplePage(
                topContacts: topContacts,
                staleContacts: staleContacts,
                allContacts: allContacts,
                tasks: taskIndex.tasks,
                followUpItems: attentionStore.followUpItems,
                selectedPersonId: $selectedPersonId,
                onOpenTask: { task in
                    navigation.selectedPage = .tasks
                    selectedTaskId = task.id
                },
                onOpenChat: { chat in openChat(chat) }
            )

        case .preferences:
            DashboardPreferencesPage(
                onBackToDashboard: {
                    navigation.selectedPage = .dashboard
                },
                onRefreshDashboard: refreshDashboard,
                onRefreshUsage: {
                    Task {
                        await taskIndex.loadFromStore(
                            telegramService: telegramService,
                            includeBotsInAISearch: includeBotsInAISearch
                        )
                    }
                }
            )
        }
    }

    private func addTopic(_ name: String) {
        Task { @MainActor in
            if let topic = await taskIndex.addTopic(named: name) {
                selectedTopicId = topic.id
                navigation.selectedPage = .topics
            }
            isAddingTopic = false
        }
    }

    private func loadPeople() async {
        async let top = RelationGraph.shared.topContacts(category: nil, limit: 200)
        async let stale = RelationGraph.shared.staleContacts(
            olderThan: AppConstants.FollowUp.staleThresholdSeconds,
            category: nil
        )
        async let grouped = RelationGraph.shared.contactsByCategory()
        let topLoaded = await top
        let staleLoaded = Array(await stale.prefix(120))
        let groupedLoaded = await grouped
        let groupedContacts = groupedLoaded.values.flatMap { $0 }
        topContacts = topLoaded
        staleContacts = staleLoaded
        allContacts = mergeContacts(topLoaded + staleLoaded + groupedContacts)
    }

    private func mergeContacts(_ contacts: [RelationGraph.Node]) -> [RelationGraph.Node] {
        var seen = Set<Int64>()
        return contacts.filter { contact in
            seen.insert(contact.entityId).inserted
        }
    }

    private func normalizedTopicSuggestionName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rebuildSidebarTopicItems() async {
        let topics = taskIndex.topics
        let snapshots = telegramService.visibleChats.map {
            DashboardTopicMatcher.ChatSnapshot(
                id: $0.id,
                title: $0.title,
                preview: $0.lastMessage?.displayText
            )
        }
        let items = await Task.detached(priority: .utility) {
            DashboardTopicMatcher.sidebarItems(topics: topics, chats: snapshots)
        }.value

        guard !Task.isCancelled else { return }
        sidebarTopicItems = items
    }

    private func refreshDashboard() {
        attentionStore.loadFollowUps(
            telegramService: telegramService,
            aiService: aiService,
            includeBots: includeBotsInAISearch,
            force: true
        )

        Task {
            async let peopleRefresh: Void = loadPeople()
            await taskIndex.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: includeBotsInAISearch,
                forceRescan: true
            )
            await peopleRefresh
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

@MainActor
final class DashboardNavigationStore: ObservableObject {
    static let shared = DashboardNavigationStore()

    @Published var selectedPage: DashboardPage? = .dashboard

    private init() {}

    func show(_ page: DashboardPage) {
        selectedPage = page
    }
}

enum DashboardPage: String, CaseIterable, Identifiable, Hashable {
    case dashboard = "Dashboard"
    case replyQueue = "Reply queue"
    case tasks = "Tasks"
    case topics = "Topics"
    case people = "People"
    case preferences = "Preferences"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dashboard:
            return "house"
        case .replyQueue:
            return "tray"
        case .tasks:
            return "checkmark.square"
        case .topics:
            return "folder"
        case .people:
            return "person.2"
        case .preferences:
            return "gearshape"
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
        case .topics:
            return "Workspaces and recent context"
        case .people:
            return "Contacts and context"
        case .preferences:
            return "Setup, privacy, and diagnostics"
        }
    }
}

enum DashboardChromePolicy: Equatable {
    case standard
    case focusedPreferences

    static func policy(for page: DashboardPage?) -> DashboardChromePolicy {
        (page ?? .dashboard) == .preferences ? .focusedPreferences : .standard
    }

    var showsDashboardSidebar: Bool {
        self == .standard
    }

    var showsDashboardTopBar: Bool {
        self == .standard
    }
}

struct DashboardTopBar: View {
    let page: DashboardPage
    let lastRefreshAt: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(page.rawValue)
                    .font(PidgyDashboardTheme.metadataMediumFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text("· \(page.subtitle)")
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let lastRefreshAt {
                Text("Updated \(DateFormatting.compactRelativeTime(from: lastRefreshAt)) ago")
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }

            Button(action: onRefresh) {
                HStack(spacing: 7) {
                    Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(PidgyDashboardTheme.metadataMediumFont)
                    Text(isRefreshing ? "Refreshing" : "Refresh")
                        .font(PidgyDashboardTheme.metadataMediumFont)
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

struct DashboardSidebar: View {
    @Binding var selection: DashboardPage?
    @Binding var selectedTopicId: Int64?
    let topicItems: [DashboardSidebarTopicSummary]
    let replyCount: Int
    let openTaskCount: Int
    let peopleCount: Int
    let visibleChatCount: Int
    let lastRefreshAt: Date?
    let accountUser: TGUser?
    let accountName: String
    let canLogOut: Bool
    let onAddTopic: () -> Void
    let onOpenPreferences: () -> Void
    let onRefresh: () -> Void
    let onLogOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 20)

            VStack(spacing: 2) {
                ForEach(DashboardPage.allCases.filter { $0 != .topics && $0 != .preferences }) { page in
                    sidebarButton(page, count: count(for: page))
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            sidebarTopicsSection
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 12) {
                Rectangle()
                    .fill(PidgyDashboardTheme.rule)
                    .frame(height: 1)

                accountMenu
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

    private var brandHeader: some View {
        HStack(spacing: 12) {
            PidgyMascotMark(size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(PidgyBranding.appName)
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                Text(PidgyBranding.dashboardTagline)
                    .font(PidgyDashboardTheme.captionMediumFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func sidebarButton(_ page: DashboardPage, count: Int?) -> some View {
        Button {
            selection = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .font(PidgyDashboardTheme.metadataMediumFont)
                    .frame(width: 18)
                Text(page.rawValue)
                    .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(PidgyDashboardTheme.monoCaptionFont)
                        .foregroundStyle(selection == page ? PidgyDashboardTheme.brand : PidgyDashboardTheme.secondary)
                }
            }
            .foregroundStyle(selection == page ? PidgyDashboardTheme.brand : PidgyDashboardTheme.primary)
            .padding(.horizontal, 10)
            .frame(height: PidgyDashboardTheme.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection == page ? PidgyDashboardTheme.brand.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sidebarTopicsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MAIN TOPICS")
                    .font(PidgyDashboardTheme.captionMediumFont)
                    .tracking(0.8)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                Spacer()
                Button(action: onAddTopic) {
                    Image(systemName: "plus")
                        .font(PidgyDashboardTheme.captionMediumFont)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .help("Add topic")
            }

            if mainTopicItems.isEmpty {
                Button(action: onAddTopic) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(PidgyDashboardTheme.captionMediumFont)
                        Text("Add topic")
                            .font(PidgyDashboardTheme.metadataMediumFont)
                    }
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 1) {
                    ForEach(mainTopicItems) { item in
                        Button {
                            selectedTopicId = item.id
                            selection = .topics
                        } label: {
                            HStack(spacing: 9) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(item.tint)
                                    .frame(width: 8, height: 8)
                                Text(item.name)
                                    .font(PidgyDashboardTheme.metadataMediumFont)
                                    .foregroundStyle(isTopicSelected(item) ? PidgyDashboardTheme.brand : PidgyDashboardTheme.primary)
                                    .lineLimit(1)
                                Spacer()
                                if item.chatCount > 0 {
                                    Text("\(item.chatCount)")
                                        .font(PidgyDashboardTheme.monoCaptionFont)
                                        .foregroundStyle(isTopicSelected(item) ? PidgyDashboardTheme.brand : PidgyDashboardTheme.secondary)
                                }
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isTopicSelected(item) ? PidgyDashboardTheme.brand.opacity(0.14) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var accountMenu: some View {
        Menu {
            Button(action: onOpenPreferences) {
                Label("Settings", systemImage: "gearshape")
            }
            Button(action: onRefresh) {
                Label("Refresh dashboard", systemImage: "arrow.clockwise")
            }
            if canLogOut {
                Divider()
                Button(role: .destructive, action: onLogOut) {
                    Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            HStack(spacing: 17) {
                DashboardTelegramUserAvatar(
                    user: accountUser,
                    fallbackTitle: accountName,
                    size: UserPhotoManager.accountMenuThumbnailSide
                )

                HStack(spacing: 4) {
                    Text(accountTitle)
                        .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    private var accountTitle: String {
        accountUser?.username ?? accountName
    }

    private func count(for page: DashboardPage) -> Int? {
        switch page {
        case .dashboard:
            return nil
        case .replyQueue:
            return replyCount
        case .tasks:
            return openTaskCount
        case .topics:
            return nil
        case .people:
            return peopleCount
        case .preferences:
            return nil
        }
    }

    private var syncText: String {
        guard let lastRefreshAt else { return "not synced" }
        return "synced \(DateFormatting.compactRelativeTime(from: lastRefreshAt)) ago"
    }

    private var mainTopicItems: [DashboardSidebarTopicItem] {
        topicItems.map {
            DashboardSidebarTopicItem(
                id: $0.id,
                name: $0.name,
                chatCount: $0.chatCount,
                rank: $0.rank,
                tint: PidgyDashboardTheme.topicTint($0.id),
                isPinned: $0.isPinned
            )
        }
    }

    private func isTopicSelected(_ item: DashboardSidebarTopicItem) -> Bool {
        selection == .topics && selectedTopicId == item.id
    }

}

struct DashboardSidebarTopicItem: Identifiable {
    let id: Int64
    let name: String
    let chatCount: Int
    let rank: Int
    let tint: Color
    let isPinned: Bool
}

struct DashboardTopicSuggestion: Identifiable {
    let name: String
    let count: Int
    let tintSeed: Int64

    var id: String { name.lowercased() }
}

struct DashboardAddTopicSheet: View {
    let suggestions: [DashboardTopicSuggestion]
    let onCancel: () -> Void
    let onAdd: (String) -> Void

    @State private var topicName = ""

    private var trimmedName: String {
        topicName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add topic")
                    .font(PidgyDashboardTheme.displayTitleFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text("Pin a company, project, community, or workspace.")
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }

            TextField("First Dollar", text: $topicName)
                .textFieldStyle(.plain)
                .font(PidgyDashboardTheme.detailBodyFont)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(DashboardCapsuleBackground())
                .onSubmit(save)

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Suggestions")
                        .font(PidgyDashboardTheme.captionMediumFont)
                        .tracking(0.7)
                        .foregroundStyle(PidgyDashboardTheme.tertiary)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 138), spacing: 8, alignment: .leading)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(suggestions) { suggestion in
                            Button {
                                topicName = suggestion.name
                            } label: {
                                DashboardTopicSuggestionChip(suggestion: suggestion)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .frame(width: 78, height: 34)
                        .background(DashboardCapsuleBackground())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: save) {
                    Text("Add")
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(trimmedName.isEmpty ? PidgyDashboardTheme.secondary : Color.white)
                        .frame(width: 72, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(trimmedName.isEmpty ? PidgyDashboardTheme.raised : PidgyDashboardTheme.brand)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 470)
        .background(PidgyDashboardTheme.paper)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        onAdd(trimmedName)
    }
}

struct DashboardTopicSuggestionChip: View {
    let suggestion: DashboardTopicSuggestion

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(PidgyDashboardTheme.topicTint(suggestion.tintSeed))
                .frame(width: 9, height: 9)

            Text(suggestion.name)
                .font(PidgyDashboardTheme.metadataMediumFont)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .lineLimit(1)

            Spacer(minLength: 2)

            if suggestion.count > 0 {
                Text("\(suggestion.count)")
                    .font(PidgyDashboardTheme.monoCaptionFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(DashboardCapsuleBackground())
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
