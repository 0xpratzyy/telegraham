import SwiftUI

struct LauncherView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService

    // Search & filter
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    // Filter tags
    enum Filter: String, CaseIterable {
        case all = "All"
        case groups = "Groups"
        case dms = "DMs"
        case unread = "Unread"
        case priority = "Priority"

        var icon: String? {
            switch self {
            case .all: return nil
            case .groups: return "person.3"
            case .dms: return "envelope"
            case .unread: return "circle.badge.fill"
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

    // Settings callback
    var onOpenSettings: () -> Void = {}

    // MARK: - Computed

    private var displayedChats: [TGChat] {
        var chats: [TGChat]

        switch activeFilter {
        case .all:
            chats = telegramService.chats
        case .groups:
            chats = telegramService.groupChats
        case .dms:
            chats = telegramService.dmChats
        case .unread:
            chats = telegramService.chats.filter { $0.unreadCount > 0 }
        case .priority:
            return priorityOrderedChats
        }

        if !searchText.isEmpty {
            chats = chats.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
            }
        }

        return chats
    }

    private var priorityOrderedChats: [TGChat] {
        // Map priority items back to chats
        var ordered: [TGChat] = []
        var matchedIds: Set<Int64> = []

        for item in priorityItems {
            if let chat = telegramService.chats.first(where: { $0.title == item.chatTitle }) {
                if !matchedIds.contains(chat.id) {
                    ordered.append(chat)
                    matchedIds.insert(chat.id)
                }
            }
        }

        // Apply search filter if active
        if !searchText.isEmpty {
            ordered = ordered.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
            }
        }

        return ordered
    }

    private func priorityReason(for chat: TGChat) -> String? {
        guard activeFilter == .priority else { return nil }
        return priorityItems.first(where: { $0.chatTitle == chat.title })?.summary
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if telegramService.authState == .ready {
                searchBar
                filterTags

                Divider()

                resultsList
            } else {
                AuthView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
        .onChange(of: searchText) {
            selectedIndex = 0
        }
        .onChange(of: activeFilter) {
            selectedIndex = 0
            if activeFilter == .priority {
                Task { await loadPriority() }
            }
        }
        // Keyboard navigation from FloatingPanel
        .onReceive(NotificationCenter.default.publisher(for: .launcherArrowDown)) { _ in
            if selectedIndex < displayedChats.count - 1 {
                selectedIndex += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherArrowUp)) { _ in
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherEnter)) { _ in
            if selectedIndex < displayedChats.count {
                openChat(displayedChats[selectedIndex])
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(.tertiary)

            TextField("Search Telegram...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
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
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Filter Tags

    private var filterTags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Filter.allCases, id: \.self) { filter in
                    Button {
                        activeFilter = filter
                    } label: {
                        HStack(spacing: 4) {
                            if let icon = filter.icon {
                                Image(systemName: icon)
                                    .font(.system(size: 10))
                            }
                            Text(filter.rawValue)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(activeFilter == filter ? .primary : .secondary)
                        .background {
                            if activeFilter == filter {
                                Capsule().fill(Color.accentColor.opacity(0.15))
                            }
                        }
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    activeFilter == filter
                                        ? Color.clear
                                        : Color.secondary.opacity(0.2),
                                    lineWidth: 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Results List

    @ViewBuilder
    private var resultsList: some View {
        if activeFilter == .priority && !aiService.isConfigured {
            // AI not configured banner
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(.purple.opacity(0.4))
                Text("Add an AI API key in Settings to use Priority")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Button("Open Settings", action: onOpenSettings)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if activeFilter == .priority && isPriorityLoading {
            LoadingStateView(message: "Analyzing priority...")
        } else if activeFilter == .priority, let error = priorityError {
            ErrorStateView(message: error) {
                Task { await loadPriority(force: true) }
            }
        } else if telegramService.isLoading && telegramService.chats.isEmpty {
            LoadingStateView(message: "Loading chats...")
        } else if displayedChats.isEmpty {
            EmptyStateView(
                icon: searchText.isEmpty ? "tray" : "magnifyingglass",
                title: searchText.isEmpty
                    ? "No \(activeFilter == .all ? "chats" : activeFilter.rawValue.lowercased()) found"
                    : "No results for \"\(searchText)\""
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // Result count
                        if !searchText.isEmpty || activeFilter == .priority {
                            Text("\(displayedChats.count) result\(displayedChats.count == 1 ? "" : "s")")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.top, 4)
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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
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
    }

    // MARK: - Actions

    private func openChat(_ chat: TGChat) {
        if let url = DeepLinkGenerator.chatURL(chatId: chat.id) {
            DeepLinkGenerator.openInTelegram(url)
        }
        // Dismiss the panel
        NSApp.keyWindow?.orderOut(nil)
    }

    private func loadPriority(force: Bool = false) async {
        // Skip if recently fetched (within 5 minutes) unless forced
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
            let messages = try await telegramService.getRecentMessagesAcrossChats(
                chatIds: telegramService.chats.prefix(AppConstants.Fetch.actionItemChatCount).map(\.id),
                perChatLimit: AppConstants.Fetch.actionItemPerChat
            )
            var items = try await aiService.actionItems(messages: messages)
            // Sort by urgency: high first
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
