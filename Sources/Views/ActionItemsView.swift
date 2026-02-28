import SwiftUI

struct ActionItemsView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService
    @State private var items: [ActionItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                Text("Action Items")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Content
            if isLoading {
                LoadingStateView(message: "Finding items needing your attention...")
            } else if let error = errorMessage {
                ErrorStateView(message: error) {
                    Task { await loadActionItems() }
                }
            } else if items.isEmpty {
                EmptyStateView(
                    icon: "checkmark.circle",
                    title: "All caught up!",
                    subtitle: "No conversations need your attention right now"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        // Summary bar
                        HStack(spacing: 12) {
                            urgencyCount(.high)
                            urgencyCount(.medium)
                            urgencyCount(.low)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)

                        ForEach(items) { item in
                            ActionCard(item: item)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .task { await loadActionItems() }
    }

    @ViewBuilder
    private func urgencyCount(_ urgency: ActionItem.Urgency) -> some View {
        let count = items.filter { $0.urgency == urgency }.count
        if count > 0 {
            HStack(spacing: 4) {
                Circle()
                    .fill(urgency.color)
                    .frame(width: 8, height: 8)
                Text("\(count) \(urgency.rawValue)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadActionItems() async {
        guard aiService.isConfigured else {
            errorMessage = "Add an AI API key in Settings to find action items"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let messages = try await telegramService.getRecentMessagesAcrossChats(
                chatIds: telegramService.chats.prefix(AppConstants.Fetch.actionItemChatCount).map(\.id),
                perChatLimit: AppConstants.Fetch.actionItemPerChat
            )
            items = try await aiService.actionItems(messages: messages)
            // Sort by urgency: high first
            items.sort { a, b in
                let order: [ActionItem.Urgency] = [.high, .medium, .low]
                let aIdx = order.firstIndex(of: a.urgency) ?? 2
                let bIdx = order.firstIndex(of: b.urgency) ?? 2
                return aIdx < bIdx
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
