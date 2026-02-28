import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var telegramService: TelegramService
    @Binding var selectedChat: TGChat?
    @State private var filterText = ""

    var filteredChats: [TGChat] {
        if filterText.isEmpty {
            return telegramService.chats
        }
        return telegramService.chats.filter {
            $0.title.localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter input
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)

                TextField("Filter chats...", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial)

            Divider()

            // Chat list
            if telegramService.isLoading && telegramService.chats.isEmpty {
                LoadingStateView(message: "Loading chats...")
            } else if filteredChats.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: filterText.isEmpty ? "No chats found" : "No matches for \"\(filterText)\""
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredChats) { chat in
                            ChatCardView(chat: chat, isSelected: selectedChat?.id == chat.id)
                                .onTapGesture {
                                    selectedChat = chat
                                }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}
