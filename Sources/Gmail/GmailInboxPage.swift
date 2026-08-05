import SwiftUI

private enum GmailInboxSplit: String, CaseIterable, Identifiable {
    case focused = "Focused"
    case needsReply = "Needs Reply"
    case waiting = "Waiting"
    case newsletters = "Newsletters"
    case later = "Later"
    case done = "Done"
    case all = "All"

    var id: String { rawValue }
}

private struct GmailThreadIntelligence: Equatable {
    let summary: String?
    let facts: [Fact]
}

/// Read-only, keyboard-first Gmail surface. The dashboard sidebar is the first
/// column; this view supplies the thread list and reader, giving Pidgy the
/// compact three-column rhythm of Superhuman without pretending it can mutate
/// the mailbox.
struct GmailInboxPage: View {
    @EnvironmentObject private var sourceRegistry: SourceRegistry
    @ObservedObject private var gmail = GmailConnectionManager.shared
    @StateObject private var triage = GmailTriageStore.shared

    @State private var searchText = ""
    @State private var selectedSplit = GmailInboxSplit.focused
    @State private var selectedChatID: Int64?
    @State private var messageCache: [Int64: [TGMessage]] = [:]
    @State private var loadingChatIDs: Set<Int64> = []
    @State private var intelligenceByChatID: [Int64: GmailThreadIntelligence] = [:]
    @State private var openFactsByChatID: [Int64: [Fact]] = [:]
    @State private var undoDismissTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private var gmailChats: [TGChat] {
        sourceRegistry.visibleChats
            .filter { $0.source.kind == .gmail }
            .sorted { ($0.lastActivityDate ?? .distantPast) > ($1.lastActivityDate ?? .distantPast) }
    }

    private var filteredChats: [TGChat] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return gmailChats.filter { chat in
            guard selectedSplitIncludes(chat) else { return false }
            guard !query.isEmpty else { return true }
            return [
                chat.title,
                chat.lastMessage?.senderName,
                chat.lastMessage?.normalizedTextContent
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var selectedChat: TGChat? {
        guard let selectedChatID else { return nil }
        return gmailChats.first { $0.id == selectedChatID }
    }

    var body: some View {
        Group {
            if gmailChats.isEmpty {
                connectionOrEmptyState
            } else {
                inbox
            }
        }
        .background(PidgyDashboardTheme.paper)
        .onAppear {
            selectFirstThreadIfNeeded()
        }
        .onChange(of: gmailChatIDs) {
            selectFirstThreadIfNeeded()
        }
        .task(id: selectedChatID) {
            await loadSelectedThread()
        }
        .task {
            await triage.load()
            await loadInboxMetadata()
            selectFirstThreadIfNeeded()
        }
        .onChange(of: selectedSplit) {
            selectFirstThreadIfNeeded()
        }
        .onChange(of: triage.states) {
            selectFirstThreadIfNeeded()
        }
        .background {
            keyboardShortcuts
        }
        .overlay(alignment: .bottom) {
            undoToast
        }
    }

    private var inbox: some View {
        HSplitView {
            VStack(spacing: 0) {
                listToolbar
                Divider().overlay(PidgyDashboardTheme.rule)
                splitPicker
                Divider().overlay(PidgyDashboardTheme.rule)
                threadList
            }
            .frame(minWidth: 340, idealWidth: 390, maxWidth: 480)

            reader
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                TextField("Search inbox  /", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isSearchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(PidgyDashboardTheme.sidebar)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(PidgyDashboardTheme.rule, lineWidth: 0.5)
                    }
            )

            Button {
                Task { await gmail.sync() }
            } label: {
                if gmail.isSyncing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .foregroundStyle(PidgyDashboardTheme.secondary)
            .help("Read Gmail now")
            .disabled(gmail.isSyncing)

            if gmail.isSyncing {
                Text(gmail.syncProgress?.title ?? "Syncing")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 118, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(PidgyDashboardTheme.paper)
    }

    private var splitPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(GmailInboxSplit.allCases) { split in
                    Button {
                        selectedSplit = split
                    } label: {
                        HStack(spacing: 5) {
                            Text(split.rawValue)
                            let count = splitCount(split)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(
                                        selectedSplit == split
                                            ? Color.white.opacity(0.76)
                                            : PidgyDashboardTheme.tertiary
                                    )
                            }
                        }
                        .font(.system(size: 11.5, weight: selectedSplit == split ? .semibold : .medium))
                        .foregroundStyle(selectedSplit == split ? Color.white : PidgyDashboardTheme.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selectedSplit == split ? Color.Pidgy.bg4 : Color.clear)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 40)
        .background(PidgyDashboardTheme.sidebar.opacity(0.26))
    }

    private var threadList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if filteredChats.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20, weight: .light))
                        Text("No matching email")
                            .font(.system(size: 12.5, weight: .medium))
                        Text(searchText.isEmpty ? "Nothing in \(selectedSplit.rawValue)" : "Try a different search")
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 72)
                } else {
                    ForEach(filteredChats) { chat in
                        GmailThreadRow(
                            chat: chat,
                            isSelected: selectedChatID == chat.id
                        ) {
                            selectedChatID = chat.id
                            isSearchFocused = false
                        }
                    }
                }
            }
        }
        .background(PidgyDashboardTheme.sidebar.opacity(0.34))
    }

    @ViewBuilder
    private var reader: some View {
        if let chat = selectedChat {
            VStack(spacing: 0) {
                readerHeader(chat)
                Divider().overlay(PidgyDashboardTheme.rule)

                if selectedMessages.isEmpty, loadingChatIDs.contains(chat.id) {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Opening conversation")
                            .font(.system(size: 12))
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if selectedMessages.isEmpty {
                    ContentUnavailableView(
                        "Email unavailable",
                        systemImage: "envelope.open",
                        description: Text("Run Read now to refresh the local copy.")
                    )
                } else {
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(orderedSelectedMessages) { message in
                                    GmailMessageCard(
                                        message: message,
                                        subject: chat.title,
                                        isLatest: message.id == orderedSelectedMessages.last?.id
                                    )
                                }
                            }
                            .padding(.horizontal, 28)
                            .padding(.top, 10)
                            .padding(.bottom, 82)
                            .frame(maxWidth: 820, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center)
                        }

                        triageBar(chat)
                            .padding(.bottom, 18)
                    }
                }
            }
            .background(PidgyDashboardTheme.paper)
        } else {
            ContentUnavailableView(
                "Select an email",
                systemImage: "envelope.open",
                description: Text("Choose a conversation to see its context and next action.")
            )
            .foregroundStyle(PidgyDashboardTheme.secondary)
        }
    }

    private func readerHeader(_ chat: TGChat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(chat.title)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.35)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .help("Read only — Pidgy never changes Gmail")
            }

            HStack(spacing: 6) {
                Text(GmailInboxFormatter.senderName(for: chat.lastMessage))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                Text("·")
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                Text(chat.lastActivityDate.map(GmailInboxFormatter.longDate) ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
            }

            if let summary = intelligenceByChatID[chat.id]?.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.Pidgy.accentFg)
                        .padding(.top, 2)
                    Text(summary)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PidgyDashboardTheme.primary.opacity(0.9))
                        .lineLimit(2)
                        .lineSpacing(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(PidgyDashboardTheme.sidebar.opacity(0.72))
                )
            }

            if let facts = intelligenceByChatID[chat.id]?.facts, !facts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(facts.prefix(4)) { fact in
                            GmailInsightChip(fact: fact)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionOrEmptyState: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(PidgyDashboardTheme.sidebar)
                        .frame(width: 64, height: 64)
                    Image("GmailGlyph")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                }

                VStack(spacing: 7) {
                    Text(emptyStateTitle)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                    Text(emptyStateDetail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 430)
                }

                if gmail.isSyncing {
                    VStack(spacing: 8) {
                        if let fraction = gmail.syncProgress?.fraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .tint(Color.Pidgy.accentFg)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(gmail.syncProgress?.title ?? "Preparing your inbox")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                    }
                    .frame(maxWidth: 360)
                } else if gmail.isConnecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Google")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                    }
                } else if gmail.isConnected {
                    Button("Read Gmail now") {
                        Task { await gmail.sync() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Connect Gmail") {
                        Task { await gmail.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(gmail.state == .unavailable)
                }

                if case .failed(let message) = gmail.state {
                    VStack(spacing: 10) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.Pidgy.danger)
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            Task { await gmail.connect() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .frame(maxWidth: 440)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.Pidgy.danger.opacity(0.08))
                    )
                }

                Label("Read only · Pidgy never sends, deletes, or changes Gmail", systemImage: "lock.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
            }
            .padding(34)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(PidgyDashboardTheme.sidebar.opacity(0.52))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(PidgyDashboardTheme.rule, lineWidth: 0.5)
                    }
            )
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        switch gmail.state {
        case .unavailable: return "Gmail is unavailable"
        case .disconnected, .failed: return "Bring Gmail into Pidgy"
        case .connecting: return "Finish connecting in your browser"
        case .syncing: return "Building your focused inbox"
        case .connected: return "Inbox is clear"
        }
    }

    private var emptyStateDetail: String {
        switch gmail.state {
        case .unavailable:
            return "Gmail isn't configured in this build yet. Pidgy requests read-only access and keeps the imported copy on this Mac."
        case .disconnected:
            return "See what matters, surface replies and tasks, and search locally without changing anything in Gmail."
        case .failed:
            return "The connection did not finish. Your Gmail data has not been changed."
        case .connecting:
            return "Finish Google sign-in in your browser."
        case .syncing(let detail):
            return detail
        case .connected:
            return "There are no Inbox threads in the local copy yet."
        }
    }

    private var gmailChatIDs: [Int64] {
        gmailChats.map(\.id)
    }

    private func selectFirstThreadIfNeeded() {
        if let selectedChatID, filteredChats.contains(where: { $0.id == selectedChatID }) { return }
        selectedChatID = filteredChats.first?.id
    }

    private func moveSelection(by delta: Int) {
        guard !isSearchFocused, !filteredChats.isEmpty else { return }
        let current = selectedChatID.flatMap { id in filteredChats.firstIndex { $0.id == id } } ?? 0
        let next = min(max(0, current + delta), filteredChats.count - 1)
        selectedChatID = filteredChats[next].id
    }

    private func loadSelectedThread() async {
        guard let chat = selectedChat else { return }
        if messageCache[chat.id] == nil {
            loadingChatIDs.insert(chat.id)
        }

        async let history = sourceRegistry.chatHistory(for: chat, limit: 100)
        async let storedSummary = DatabaseManager.shared.loadCurrentChatSummary(chatId: chat.id)
        let loadedMessages = (try? await history) ?? []
        let summary = await storedSummary
        messageCache[chat.id] = loadedMessages
        loadingChatIDs.remove(chat.id)
        intelligenceByChatID[chat.id] = GmailThreadIntelligence(
            summary: summary?.summary,
            facts: openFactsByChatID[chat.id] ?? []
        )
        await prefetchFollowingThreads(after: chat.id)
    }

    private var selectedMessages: [TGMessage] {
        guard let selectedChatID else { return [] }
        return messageCache[selectedChatID] ?? []
    }

    private var orderedSelectedMessages: [TGMessage] {
        selectedMessages.sorted(by: GmailInboxFormatter.oldestFirst)
    }

    private func loadInboxMetadata() async {
        let facts = await DatabaseManager.shared.loadOpenFacts(limit: 1_000)
        openFactsByChatID = Dictionary(grouping: facts, by: \.sourceChatId)
        if let selectedChatID {
            let existingSummary = intelligenceByChatID[selectedChatID]?.summary
            intelligenceByChatID[selectedChatID] = GmailThreadIntelligence(
                summary: existingSummary,
                facts: openFactsByChatID[selectedChatID] ?? []
            )
        }
    }

    private func prefetchFollowingThreads(after chatID: Int64) async {
        guard let index = filteredChats.firstIndex(where: { $0.id == chatID }) else { return }
        let end = min(filteredChats.count, index + 3)
        guard index + 1 < end else { return }
        for chat in filteredChats[(index + 1)..<end] where messageCache[chat.id] == nil {
            messageCache[chat.id] = (try? await sourceRegistry.chatHistory(for: chat, limit: 100)) ?? []
        }
    }

    private func selectedSplitIncludes(_ chat: TGChat) -> Bool {
        let localState = triage.state(for: chat.id).state
        let facts = openFactsByChatID[chat.id] ?? []
        switch selectedSplit {
        case .focused:
            return localState == .inbox && !isNewsletter(chat)
        case .needsReply:
            return localState == .needsReply
                || facts.contains { $0.predicate == .iOwe && $0.loopKind == .reply }
        case .waiting:
            return localState == .waiting || facts.contains { $0.predicate == .owesMe }
        case .newsletters:
            return ![GmailTriageState.done, .later].contains(localState) && isNewsletter(chat)
        case .later:
            return localState == .later
        case .done:
            return localState == .done
        case .all:
            return true
        }
    }

    private func splitCount(_ split: GmailInboxSplit) -> Int {
        gmailChats.filter { includes($0, in: split) }.count
    }

    private func includes(_ chat: TGChat, in split: GmailInboxSplit) -> Bool {
        let localState = triage.state(for: chat.id).state
        let facts = openFactsByChatID[chat.id] ?? []
        switch split {
        case .focused: return localState == .inbox && !isNewsletter(chat)
        case .needsReply:
            return localState == .needsReply || facts.contains { $0.predicate == .iOwe && $0.loopKind == .reply }
        case .waiting: return localState == .waiting || facts.contains { $0.predicate == .owesMe }
        case .newsletters: return ![GmailTriageState.done, .later].contains(localState) && isNewsletter(chat)
        case .later: return localState == .later
        case .done: return localState == .done
        case .all: return true
        }
    }

    private func isNewsletter(_ chat: TGChat) -> Bool {
        GmailInboxClassifier.isNewsletter(
            sender: chat.lastMessage?.senderName ?? "",
            subject: chat.title,
            body: chat.lastMessage?.normalizedTextContent ?? ""
        )
    }

    private func triageBar(_ chat: TGChat) -> some View {
        let state = triage.state(for: chat.id).state
        return HStack(spacing: 4) {
            triageButton("Done", icon: "checkmark", shortcut: "E", isActive: state == .done) {
                performTriage(.done, chat: chat)
            }
            triageButton("Later", icon: "clock", shortcut: "H", isActive: state == .later) {
                performTriage(.later, chat: chat)
            }
            triageButton("Needs reply", icon: "arrowshape.turn.up.left", shortcut: "R", isActive: state == .needsReply) {
                performTriage(.needsReply, chat: chat)
            }
            triageButton("Waiting", icon: "hourglass", shortcut: "W", isActive: state == .waiting) {
                performTriage(.waiting, chat: chat)
            }

            if intelligenceByChatID[chat.id]?.facts.contains(where: { $0.predicate == .iOwe && $0.loopKind != .reply }) == true {
                Divider().frame(height: 18).padding(.horizontal, 2)
                Button {
                    DashboardNavigationStore.shared.show(.tasks)
                } label: {
                    Label("Open task", systemImage: "checkmark.square")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .padding(.horizontal, 9)
                .frame(height: 28)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PidgyDashboardTheme.rule, lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.24), radius: 16, y: 8)
    }

    private func triageButton(
        _ title: String,
        icon: String,
        shortcut: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Label(title, systemImage: icon)
                Text(shortcut)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? Color.white.opacity(0.66) : PidgyDashboardTheme.tertiary)
                    .frame(minWidth: 14, minHeight: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(isActive ? 0.08 : 0.045))
                    )
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(isActive ? Color.white : PidgyDashboardTheme.secondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.Pidgy.bg4 : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func performTriage(_ state: GmailTriageState, chat: TGChat) {
        let currentIndex = filteredChats.firstIndex(where: { $0.id == chat.id }) ?? 0
        let nextID = filteredChats.dropFirst(currentIndex + 1).first?.id
            ?? filteredChats.prefix(currentIndex).last?.id
        let snoozedUntil = state == .later
            ? Calendar.current.date(byAdding: .day, value: 1, to: Date())
            : nil

        Task {
            await triage.set(state, for: chat.id, snoozedUntil: snoozedUntil)
            selectedChatID = nextID
            scheduleUndoDismissal()
        }
    }

    private func performSelectedTriage(_ state: GmailTriageState) {
        guard !isSearchFocused,
              let selectedChatID,
              let chat = gmailChats.first(where: { $0.id == selectedChatID })
        else { return }
        performTriage(state, chat: chat)
    }

    @ViewBuilder
    private var undoToast: some View {
        if let action = triage.undoAction {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.Pidgy.accentFg)
                Text(action.message)
                    .font(.system(size: 12, weight: .medium))
                Button("Undo") {
                    undoDismissTask?.cancel()
                    Task { await triage.undo() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.Pidgy.accentFg)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(PidgyDashboardTheme.rule, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func scheduleUndoDismissal() {
        undoDismissTask?.cancel()
        undoDismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            triage.dismissUndo()
        }
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("Next email") { moveSelection(by: 1) }
                .keyboardShortcut("j", modifiers: [])
                .disabled(isSearchFocused)
            Button("Previous email") { moveSelection(by: -1) }
                .keyboardShortcut("k", modifiers: [])
                .disabled(isSearchFocused)
            Button("Search Gmail") { isSearchFocused = true }
                .keyboardShortcut("/", modifiers: [])
            Button("Search Gmail with Command-F") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: [.command])
            Button("Mark email done") { performSelectedTriage(.done) }
                .keyboardShortcut("e", modifiers: [])
                .disabled(isSearchFocused || selectedChatID == nil)
            Button("Move email to later") { performSelectedTriage(.later) }
                .keyboardShortcut("h", modifiers: [])
                .disabled(isSearchFocused || selectedChatID == nil)
            Button("Mark email needs reply") { performSelectedTriage(.needsReply) }
                .keyboardShortcut("r", modifiers: [])
                .disabled(isSearchFocused || selectedChatID == nil)
            Button("Mark email waiting") { performSelectedTriage(.waiting) }
                .keyboardShortcut("w", modifiers: [])
                .disabled(isSearchFocused || selectedChatID == nil)
            Button("Undo last Gmail action") {
                undoDismissTask?.cancel()
                Task { await triage.undo() }
            }
            .keyboardShortcut("z", modifiers: [])
            .disabled(isSearchFocused || triage.undoAction == nil)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GmailThreadRow: View {
    let chat: TGChat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Text(GmailInboxFormatter.initials(for: GmailInboxFormatter.senderName(for: chat.lastMessage)))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(avatarColor))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(GmailInboxFormatter.senderName(for: chat.lastMessage))
                            .font(.system(size: 12.5, weight: chat.unreadCount > 0 ? .semibold : .medium))
                            .foregroundStyle(PidgyDashboardTheme.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(chat.lastActivityDate.map(GmailInboxFormatter.shortDate) ?? "")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(PidgyDashboardTheme.tertiary)
                    }

                    Text(chat.title)
                        .font(.system(size: 12, weight: chat.unreadCount > 0 ? .semibold : .regular))
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)

                    Text(GmailInboxFormatter.preview(for: chat.lastMessage, subject: chat.title))
                        .font(.system(size: 11.5))
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                        .lineLimit(1)
                }

                if chat.unreadCount > 0 {
                    Circle()
                        .fill(Color.Pidgy.accentFg)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.Pidgy.bg4.opacity(0.78) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(height: 0.5)
                .padding(.leading, 53)
        }
    }

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo]
        return colors[abs(Int(chat.id % Int64(colors.count)))]
    }
}

private struct GmailInsightChip: View {
    let fact: Fact

    private var label: String {
        if fact.predicate == .owesMe { return "Waiting · \(fact.action.nilIfBlank ?? fact.objectText)" }
        if fact.loopKind == .reply { return "Reply · \(fact.action.nilIfBlank ?? fact.objectText)" }
        return "Task · \(fact.action.nilIfBlank ?? fact.objectText)"
    }

    private var icon: String {
        if fact.predicate == .owesMe { return "hourglass" }
        if fact.loopKind == .reply { return "arrowshape.turn.up.left" }
        return "checkmark.square"
    }

    var body: some View {
        Label(label, systemImage: icon)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(PidgyDashboardTheme.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(PidgyDashboardTheme.sidebar)
                    .overlay(Capsule().stroke(PidgyDashboardTheme.rule, lineWidth: 0.5))
            )
    }
}

private struct GmailMessageCard: View {
    let message: TGMessage
    let subject: String
    let isLatest: Bool
    @State private var isExpanded = false

    private var expanded: Bool { isLatest || isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 12 : 7) {
            Button {
                guard !isLatest else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.isOutgoing ? "You" : GmailInboxFormatter.senderName(message.senderName))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                    Spacer()
                    Text(GmailInboxFormatter.longDate(message.date))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                    if !isLatest {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(PidgyDashboardTheme.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(GmailInboxFormatter.body(for: message, subject: subject))
                    .font(.system(size: 13))
                    .foregroundStyle(PidgyDashboardTheme.primary.opacity(0.92))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else {
                Text(GmailInboxFormatter.preview(for: message, subject: subject))
                    .font(.system(size: 12))
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, expanded ? 18 : 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PidgyDashboardTheme.rule).frame(height: 0.5)
        }
    }
}

enum GmailInboxFormatter {
    static func senderName(for message: TGMessage?) -> String {
        guard let message else { return "Unknown sender" }
        return message.isOutgoing ? "You" : senderName(message.senderName)
    }

    static func senderName(_ raw: String?) -> String {
        guard let raw else { return "Unknown sender" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let angle = trimmed.firstIndex(of: "<") {
            let name = trimmed[..<angle]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            if !name.isEmpty { return name }
        }
        if let at = trimmed.firstIndex(of: "@") {
            return String(trimmed[..<at]).replacingOccurrences(of: ".", with: " ").capitalized
        }
        return trimmed.isEmpty ? "Unknown sender" : trimmed
    }

    static func initials(for name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        if parts.count > 1 {
            return String(parts.prefix(2).compactMap(\.first)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    static func preview(for message: TGMessage?, subject: String) -> String {
        guard let message else { return "" }
        return body(for: message, subject: subject)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func body(for message: TGMessage, subject: String) -> String {
        let text = message.textContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subjectPrefix = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subjectPrefix.isEmpty, text.hasPrefix(subjectPrefix) else {
            return text.isEmpty ? "No text content" : text
        }
        let remainder = text.dropFirst(subjectPrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? "No text content" : remainder
    }

    static func oldestFirst(_ lhs: TGMessage, _ rhs: TGMessage) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id < rhs.id
    }

    static func shortDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    static func longDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension GmailConnectionManager {
    var isConnected: Bool {
        switch state {
        case .connected, .syncing: return true
        default: return false
        }
    }

    var isConnecting: Bool {
        if case .connecting = state { return true }
        return false
    }

    var isSyncing: Bool {
        if case .syncing = state { return true }
        return false
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
