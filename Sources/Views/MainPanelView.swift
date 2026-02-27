import SwiftUI

struct MainPanelView: View {
    @EnvironmentObject var telegramService: TelegramService
    @State private var selectedChat: TGChat?
    @State private var selectedTab: Tab = .search

    enum Tab {
        case search
        case chats
    }

    var body: some View {
        VStack(spacing: 0) {
            if telegramService.authState == .ready {
                // Tab bar
                HStack(spacing: 0) {
                    tabButton(title: "Search", icon: "magnifyingglass", tab: .search)
                    tabButton(title: "Chats", icon: "bubble.left.and.bubble.right", tab: .chats)

                    Spacer()

                    // Connection status
                    HStack(spacing: 6) {
                        StatusDot(isConnected: telegramService.authState == .ready)
                        if let user = telegramService.currentUser {
                            Text(user.firstName)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(white: 0.45))
                        }
                    }
                    .padding(.trailing, 14)
                }
                .background(Color.white.opacity(0.02))

                Divider()
                    .background(Color.white.opacity(0.06))

                // Content
                switch selectedTab {
                case .search:
                    if let chat = selectedChat {
                        VStack(spacing: 0) {
                            // Back button
                            HStack {
                                Button {
                                    selectedChat = nil
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chevron.left")
                                            .font(.system(size: 12))
                                        Text("Back")
                                            .font(.system(size: 12))
                                    }
                                    .foregroundColor(Color(red: 0.39, green: 0.40, blue: 0.95))
                                }
                                .buttonStyle(.plain)
                                .padding(8)

                                Spacer()
                            }

                            ChatHistoryView(chat: chat)
                        }
                    } else {
                        SearchView()
                    }

                case .chats:
                    if let chat = selectedChat {
                        VStack(spacing: 0) {
                            HStack {
                                Button {
                                    selectedChat = nil
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chevron.left")
                                            .font(.system(size: 12))
                                        Text("Back")
                                            .font(.system(size: 12))
                                    }
                                    .foregroundColor(Color(red: 0.39, green: 0.40, blue: 0.95))
                                }
                                .buttonStyle(.plain)
                                .padding(8)

                                Spacer()
                            }

                            ChatHistoryView(chat: chat)
                        }
                    } else {
                        ChatListView(selectedChat: $selectedChat)
                    }
                }
            } else {
                AuthView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.04, green: 0.04, blue: 0.06))
        .preferredColorScheme(.dark)
    }

    private func tabButton(title: String, icon: String, tab: Tab) -> some View {
        Button {
            selectedChat = nil
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(selectedTab == tab ? Color(red: 0.39, green: 0.40, blue: 0.95) : Color(white: 0.45))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(selectedTab == tab ? Color(red: 0.39, green: 0.40, blue: 0.95).opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
