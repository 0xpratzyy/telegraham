import SwiftUI

struct ChatCardView: View {
    let chat: TGChat
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            AvatarView(initials: chat.initials, colorIndex: chat.colorIndex)

            // Chat info
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(chat.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    if let date = chat.lastMessage?.date {
                        Text(DateFormatting.compactRelativeTime(from: date))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack {
                    // Chat type tag
                    Text(chat.chatType.displayName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.3))
                        .cornerRadius(4)

                    // Last message preview
                    if let lastMessage = chat.lastMessage {
                        Text(lastMessage.displayText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Unread badge
                    if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(isSelected ? 1.0 : 0.5)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: isSelected
                            ? [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0.1)]
                            : [.white.opacity(0.15), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .contentShape(Rectangle())
    }

}
