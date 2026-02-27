import SwiftUI

struct ChatHistoryView: View {
    @EnvironmentObject var telegramService: TelegramService
    let chat: TGChat
    @State private var messages: [TGMessage] = []
    @State private var isLoading = false
    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            // Chat header
            HStack(spacing: 12) {
                AvatarView(initials: chat.initials, colorIndex: chat.colorIndex, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(white: 0.89))

                    HStack(spacing: 6) {
                        Text(chat.chatType.displayName)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(white: 0.45))

                        if chat.unreadCount > 0 {
                            Text("\(chat.unreadCount) unread")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(red: 0.39, green: 0.40, blue: 0.95))
                        }
                    }
                }

                Spacer()

                // Open in Telegram
                Button {
                    if let url = DeepLinkGenerator.chatURL(chatId: chat.id) {
                        DeepLinkGenerator.openInTelegram(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12))
                        Text("Open")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.39, green: 0.40, blue: 0.95))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.39, green: 0.40, blue: 0.95).opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Color.white.opacity(0.02))

            Divider()
                .background(Color.white.opacity(0.06))

            // Search within chat
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.45))

                TextField("Search in this chat...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.89))
                    .onSubmit {
                        Task { await searchInChat() }
                    }
            }
            .padding(10)
            .background(Color.white.opacity(0.02))

            Divider()
                .background(Color.white.opacity(0.06))

            // Messages
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading messages...")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "message")
                        .font(.system(size: 32))
                        .foregroundColor(Color(white: 0.25))
                    Text("No messages found")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(messages) { message in
                            MessageCardView(
                                message: message,
                                highlightQuery: searchQuery.isEmpty ? nil : searchQuery
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .task {
            await loadHistory()
        }
    }

    private func loadHistory() async {
        isLoading = true
        defer { isLoading = false }

        do {
            messages = try await telegramService.getChatHistory(chatId: chat.id, limit: 50)
        } catch {
            print("[ChatHistory] Error: \(error)")
        }
    }

    private func searchInChat() async {
        guard !searchQuery.isEmpty else {
            await loadHistory()
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            messages = try await telegramService.searchChatMessages(chatId: chat.id, query: searchQuery)
        } catch {
            print("[ChatHistory] Search error: \(error)")
        }
    }
}
