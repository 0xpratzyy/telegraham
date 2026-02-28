import SwiftUI

/// Controls concurrent AI summary requests to avoid overwhelming the API.
private actor AISemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func wait() async {
        if available > 0 {
            available -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct GroupDiscoveryView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService
    @State private var summaries: [Int64: String] = [:]
    @State private var summaryErrors: [Int64: String] = [:]
    @State private var loadingChats: Set<Int64> = []
    @State private var filter = ""

    private static let semaphore = AISemaphore(limit: 3)

    private var filteredGroups: [TGChat] {
        let groups = telegramService.groupChats
        if filter.isEmpty { return groups }
        return groups.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Groups & Channels")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(filteredGroups.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Filter
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("Filter groups...", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            // Group list
            if filteredGroups.isEmpty {
                EmptyStateView(icon: "person.3", title: "No groups found")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredGroups) { chat in
                            groupCard(chat: chat)
                                .task { await loadSummary(for: chat) }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    @ViewBuilder
    private func groupCard(chat: TGChat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                AvatarView(initials: chat.initials, colorIndex: chat.colorIndex, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(chat.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        if chat.unreadCount > 0 {
                            Text("\(chat.unreadCount)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue)
                                .clipShape(Capsule())
                        }
                    }

                    Text(chat.chatType.displayName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            // AI Summary
            if let summary = summaries[chat.id] {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple)
                    TypingTextView(fullText: summary, speed: 60)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.leading, 44)
            } else if loadingChats.contains(chat.id) {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Analyzing...")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 44)
            } else if let error = summaryErrors[chat.id] {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Button {
                        summaryErrors.removeValue(forKey: chat.id)
                        Task { await loadSummary(for: chat) }
                    } label: {
                        Text("Retry")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 44)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

    private func loadSummary(for chat: TGChat) async {
        guard aiService.isConfigured,
              summaries[chat.id] == nil,
              summaryErrors[chat.id] == nil,
              !loadingChats.contains(chat.id) else { return }

        loadingChats.insert(chat.id)

        // Throttle: wait for a slot (max 3 concurrent AI calls)
        await Self.semaphore.wait()

        do {
            let messages = try await telegramService.getChatHistory(
                chatId: chat.id,
                limit: AppConstants.Fetch.groupSummaryPerChat
            )
            let summary = try await aiService.summarizeGroup(messages: messages, chatTitle: chat.title)
            summaries[chat.id] = summary
        } catch {
            summaryErrors[chat.id] = "Summary failed"
        }

        await Self.semaphore.signal()
        loadingChats.remove(chat.id)
    }
}
