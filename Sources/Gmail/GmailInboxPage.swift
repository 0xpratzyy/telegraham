import SwiftUI

/// Read-only, keyboard-first Gmail surface. The dashboard sidebar is the first
/// column; this view supplies the thread list and reader, giving Pidgy the
/// compact three-column rhythm of Superhuman without pretending it can mutate
/// the mailbox.
struct GmailInboxPage: View {
    @EnvironmentObject private var sourceRegistry: SourceRegistry
    @ObservedObject private var gmail = GmailConnectionManager.shared

    @State private var searchText = ""
    @State private var selectedChatID: Int64?
    @State private var messages: [TGMessage] = []
    @State private var isLoadingThread = false
    @FocusState private var isSearchFocused: Bool

    private var gmailChats: [TGChat] {
        sourceRegistry.visibleChats
            .filter { $0.source.kind == .gmail }
            .sorted { ($0.lastActivityDate ?? .distantPast) > ($1.lastActivityDate ?? .distantPast) }
    }

    private var filteredChats: [TGChat] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return gmailChats }
        return gmailChats.filter { chat in
            [
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
        .background {
            keyboardShortcuts
        }
    }

    private var inbox: some View {
        HSplitView {
            VStack(spacing: 0) {
                listToolbar
                Divider().overlay(PidgyDashboardTheme.rule)
                threadList
            }
            .frame(minWidth: 330, idealWidth: 380, maxWidth: 470)

            reader
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                TextField("Search inbox", text: $searchText)
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
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(PidgyDashboardTheme.paper)
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

                if isLoadingThread {
                    ProgressView("Reading thread…")
                        .controlSize(.small)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if messages.isEmpty {
                    ContentUnavailableView(
                        "Email unavailable",
                        systemImage: "envelope.open",
                        description: Text("Run Read now to refresh the local copy.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(messages.sorted(by: GmailInboxFormatter.oldestFirst)) { message in
                                GmailMessageCard(message: message, subject: chat.title)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .background(PidgyDashboardTheme.paper)
        } else {
            ContentUnavailableView(
                "Select an email",
                systemImage: "envelope.open",
                description: Text("Use J and K to move through the inbox.")
            )
            .foregroundStyle(PidgyDashboardTheme.secondary)
        }
    }

    private func readerHeader(_ chat: TGChat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(chat.title)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .tracking(-0.35)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Text("READ ONLY")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .overlay(Capsule().stroke(PidgyDashboardTheme.rule))
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
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionOrEmptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(PidgyDashboardTheme.sidebar)
                    .frame(width: 68, height: 68)
                Image("GmailGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
            }

            VStack(spacing: 6) {
                Text(gmail.isConnected ? "Inbox is clear" : "Connect Gmail")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text(emptyStateDetail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 440)
            }

            HStack(spacing: 10) {
                if gmail.isSyncing || gmail.isConnecting {
                    ProgressView().controlSize(.small)
                } else if gmail.isConnected {
                    Button("Read now") {
                        Task { await gmail.sync() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Connect Gmail") {
                        Task { await gmail.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(gmail.state == .unavailable)
                }
            }

            if case .failed(let message) = gmail.state {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Pidgy.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateDetail: String {
        switch gmail.state {
        case .unavailable:
            return "Gmail isn't configured in this build yet. Pidgy requests read-only access and keeps the imported copy on this Mac."
        case .disconnected, .failed:
            return "Read threads, search locally, and extract tasks without sending or changing anything in Gmail."
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
        if let selectedChatID, gmailChats.contains(where: { $0.id == selectedChatID }) { return }
        selectedChatID = filteredChats.first?.id ?? gmailChats.first?.id
    }

    private func moveSelection(by delta: Int) {
        guard !isSearchFocused, !filteredChats.isEmpty else { return }
        let current = selectedChatID.flatMap { id in filteredChats.firstIndex { $0.id == id } } ?? 0
        let next = min(max(0, current + delta), filteredChats.count - 1)
        selectedChatID = filteredChats[next].id
    }

    private func loadSelectedThread() async {
        guard let chat = selectedChat else {
            messages = []
            return
        }
        isLoadingThread = true
        defer { isLoadingThread = false }
        messages = (try? await sourceRegistry.chatHistory(for: chat, limit: 100)) ?? []
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
                .keyboardShortcut("f", modifiers: [.command])
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
                    .frame(width: 30, height: 30)
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
                        .lineLimit(2)
                        .lineSpacing(1)
                }

                if chat.unreadCount > 0 {
                    Circle()
                        .fill(Color.Pidgy.accentFg)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
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

private struct GmailMessageCard: View {
    let message: TGMessage
    let subject: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.isOutgoing ? "You" : GmailInboxFormatter.senderName(message.senderName))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Spacer()
                Text(GmailInboxFormatter.longDate(message.date))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
            }

            Text(GmailInboxFormatter.body(for: message, subject: subject))
                .font(.system(size: 13))
                .foregroundStyle(PidgyDashboardTheme.primary.opacity(0.92))
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 20)
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
