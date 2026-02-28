import SwiftUI

/// Compact two-line chat row for the launcher results list.
struct ChatRowView: View {
    let chat: TGChat
    let isHighlighted: Bool
    var priorityReason: String? = nil
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                AvatarView(initials: chat.initials, colorIndex: chat.colorIndex, size: 28)

                VStack(alignment: .leading, spacing: 3) {
                    // Line 1: Title + type badge + unread + time
                    HStack(spacing: 6) {
                        Text(chat.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(chat.chatType.displayName)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())

                        if chat.unreadCount > 0 {
                            Text("\(chat.unreadCount)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }

                        Spacer()

                        if let date = chat.lastActivityDate {
                            Text(DateFormatting.compactRelativeTime(from: date))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Line 2: Preview or priority reason
                    if let reason = priorityReason {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                                .foregroundStyle(.purple)
                            Text(reason)
                                .font(.system(size: 12))
                                .foregroundStyle(.purple.opacity(0.8))
                                .lineLimit(1)
                        }
                    } else if let lastMessage = chat.lastMessage {
                        Text(lastMessage.displayText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
