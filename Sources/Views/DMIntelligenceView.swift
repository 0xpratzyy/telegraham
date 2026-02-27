import SwiftUI

struct DMIntelligenceView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService
    @State private var categorizedMessages: [CategorizedMessage] = []
    @State private var selectedCategory: DMCategory? = nil
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var displayedMessages: [CategorizedMessage] {
        if let cat = selectedCategory {
            return categorizedMessages.filter { $0.category == cat }
        }
        return categorizedMessages
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Direct Messages")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !categorizedMessages.isEmpty {
                    Text("\(categorizedMessages.count) messages")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Category tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    categoryTab(nil, label: "All", count: categorizedMessages.count)
                    ForEach(DMCategory.allCases, id: \.self) { cat in
                        categoryTab(cat, label: cat.rawValue,
                                    count: categorizedMessages.filter { $0.category == cat }.count)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            Divider()

            // Content
            if isLoading {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("Analyzing your DMs...")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if displayedMessages.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text(selectedCategory == nil ? "No DMs to display" : "No messages in this category")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(displayedMessages) { catMsg in
                            dmCard(catMsg)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .task { await loadCategorizedDMs() }
    }

    @ViewBuilder
    private func categoryTab(_ category: DMCategory?, label: String, count: Int) -> some View {
        Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 4) {
                if let cat = category {
                    Image(systemName: cat.icon)
                        .font(.system(size: 10))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(selectedCategory == category ? .primary : .secondary)
            .background {
                if selectedCategory == category {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        selectedCategory == category ? .clear : Color.secondary.opacity(0.2),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func dmCard(_ catMsg: CategorizedMessage) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(catMsg.category.color)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(catMsg.chatTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(catMsg.category.rawValue)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(catMsg.category.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(catMsg.category.color.opacity(0.1))
                        .clipShape(Capsule())
                }

                if let text = catMsg.message.textContent {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(catMsg.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func loadCategorizedDMs() async {
        guard aiService.isConfigured else {
            errorMessage = "Add an AI API key in Settings to categorize DMs"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let messages = try await telegramService.getUnreadDMs()
            if messages.isEmpty {
                // Fall back to recent DMs
                let recentDMs = try await telegramService.getRecentMessagesAcrossChats(
                    chatIds: telegramService.dmChats.prefix(10).map(\.id),
                    perChatLimit: 5
                )
                categorizedMessages = try await aiService.categorizedDMs(messages: recentDMs, chats: telegramService.dmChats)
            } else {
                categorizedMessages = try await aiService.categorizedDMs(messages: messages, chats: telegramService.dmChats)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
