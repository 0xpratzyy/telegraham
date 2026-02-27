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
                        .foregroundColor(Color(white: 0.89))
                        .lineLimit(1)

                    Spacer()

                    if let date = chat.lastMessage?.date {
                        Text(relativeTime(from: date))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(white: 0.35))
                    }
                }

                HStack {
                    // Chat type tag
                    Text(chat.chatType.displayName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(white: 0.45))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(4)

                    // Last message preview
                    if let lastMessage = chat.lastMessage {
                        Text(lastMessage.displayText)
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.59))
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
                            .background(Color(red: 0.39, green: 0.40, blue: 0.95))
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.white.opacity(0.06) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected ? Color(red: 0.39, green: 0.40, blue: 0.95).opacity(0.3) : Color.white.opacity(0.06),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
    }

    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
